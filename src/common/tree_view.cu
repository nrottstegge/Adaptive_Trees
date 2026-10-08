// tree_view.cu
#include <cuda_runtime.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cub/device/device_radix_sort.cuh>
#include <cub/device/device_scan.cuh>
#include <cub/device/device_select.cuh>

#include "adaptive_octree/config.hpp"
#include "helpers.cuh"
#include "tree_view.hpp"
#include "sfc_keys.cuh"

namespace adaptive_octree
{
    using namespace detail;
    namespace
    {
        // =====================================================================
        // Basic helpers
        // =====================================================================
        template<unsigned LevelBits>
        constexpr unsigned kMaxTreeLevel = maxBinaryDepth / LevelBits;
        template<unsigned LevelBits>
        constexpr unsigned kNumChildren = 1u << LevelBits;

        template<unsigned LevelBits>
        __host__ __device__ inline KeyType viewNodeRange(unsigned level)
        {
            return maxKey >> (LevelBits * level);
        }
        template<unsigned LevelBits>
        __host__ __device__ inline unsigned viewTreeLevel(KeyType range)
        {
            return unsigned(countLeadingZeros(range)) / LevelBits;
        }
        __device__ inline int activeLeaves(int capacity, const RebalanceState *state)
        {
            return state ? (state->numLeaves <= capacity ? state->numLeaves : 0)
                         : capacity;
        }
        template<unsigned LevelBits>
        __device__ inline int activeInternals(int capacity,
                                              const RebalanceState *state)
        {
            const int count = state
                                  ? (state->numLeaves - 1) / (kNumChildren<LevelBits> - 1)
                                  : capacity;
            return count <= capacity ? count : 0;
        }
        __global__ void flagViewCapacityKernel(RebalanceState *state)
        {
            state->needsResize = 1;
        }
        struct LeafCountInput
        {
            const unsigned *a;
            const unsigned *b;
            const RebalanceState *state;
            __host__ __device__ unsigned operator()(int i) const
            {
                if (state && i >= state->numLeaves)
                    return 0;
                return state && state->activeBuffer ? b[i] : a[i];
            }
        };
        auto leafCountInput(const unsigned *a, const unsigned *b,
                            const RebalanceState *state)
        {
            return thrust::make_transform_iterator(thrust::make_counting_iterator<int>(0),
                                                   LeafCountInput{a, b, state});
        }
        struct InternalCandidate
        {
            KeyType start;
            std::uint8_t level;
        };
        template<unsigned LevelBits>
        __host__ __device__ inline KeyType nodeStartAtLevel(KeyType key,
                                                            unsigned level)
        {
            const KeyType range = viewNodeRange<LevelBits>(level);
            return (key / range) * range;
        }

        // Lowest common ancestor level of two SFC positions.
        //
        // This intentionally uses node ranges rather than raw clz() so it
        // remains consistent with Cornerstone's nodeRange representation.
        template<unsigned LevelBits>
        __host__ __device__ inline unsigned lcaLevel(KeyType a, KeyType b)
        {
            unsigned result = 0;
            for (unsigned level = 1; level <= kMaxTreeLevel<LevelBits>; ++level)
            {
                if (nodeStartAtLevel<LevelBits>(a, level) !=
                    nodeStartAtLevel<LevelBits>(b, level))
                {
                    break;
                }
                result = level;
            }
            return result;
        }
        template<unsigned LevelBits>
        __host__ __device__ inline unsigned childSlotAtLevel(KeyType childStart,
                                                             KeyType parentStart,
                                                             unsigned childLevel)
        {
            const KeyType childRange = viewNodeRange<LevelBits>(childLevel);
            return unsigned((childStart - parentStart) / childRange);
        }

        // Reverse the child path so sorting reproduces the child-centric BFS rank.
        template<unsigned LevelBits>
        __host__ __device__ inline KeyType childCentricLayoutKey(KeyType start,
                                                                 unsigned level)
        {
            KeyType result = 0;
            for (unsigned depth = level; depth > 0; --depth)
            {
                const KeyType parentRange = viewNodeRange<LevelBits>(depth - 1);
                const KeyType childRange = viewNodeRange<LevelBits>(depth);
                const KeyType parentStart = (start / parentRange) * parentRange;
                const unsigned digit =
                    unsigned((start - parentStart) / childRange) % kNumChildren<LevelBits>;
                result = result * KeyType(kNumChildren<LevelBits>) + KeyType(digit);
            }
            return result;
        }
        // =====================================================================
        // Stage 1
        //
        // One pass over K:
        //
        //   - classify each cornerstone leaf level
        //   - histogram leavesPerLevel
        //   - identify exactly one canonical boundary per internal node
        //
        // Canonical internal boundary:
        //
        //     child-0 subtree | child-1 subtree
        //
        // For every internal node there is exactly one such adjacent-leaf
        // boundary.
        // =====================================================================
        template<unsigned LevelBits>
        __global__ void classifyLeavesAndInternalsKernel(
            const KeyType *K, int numLeaves, std::uint8_t *leafLevel,
            NodeIndex *leavesPerLevel, std::uint8_t *internalFlag,
            InternalCandidate *internalCandidate, RebalanceState *state,
            const KeyType *K_alt)
        {
            if (state && state->activeBuffer)
                K = K_alt;
            const int capacity = numLeaves;
            numLeaves = activeLeaves(capacity, state);
            const int i = int(blockIdx.x * blockDim.x + threadIdx.x);
            if (i == 0 && state)
            {
                if (state->numLeaves > capacity)
                    state->needsResize = 1;
                else
                    state->numNodes =
                        numLeaves + (numLeaves - 1) / (kNumChildren<LevelBits> - 1);
            }
            if (i < capacity - 1)
            {
                internalFlag[i] = 0;
                internalCandidate[i] = {};
            }
            // level of the leave
            if (i < numLeaves)
            {
                const KeyType range = K[i + 1] - K[i];
                const unsigned level = viewTreeLevel<LevelBits>(range);
                leafLevel[i] = std::uint8_t(level);
                atomicAdd(&leavesPerLevel[level], NodeIndex(1));
            }
            // check every border in K
            if (i < numLeaves - 1)
            {
                const KeyType leftStart = K[i];
                const KeyType rightStart = K[i + 1];
                const unsigned level = lcaLevel<LevelBits>(leftStart, rightStart);
                const KeyType parentStart =
                    nodeStartAtLevel<LevelBits>(rightStart, level);
                const unsigned rightChild =
                    childSlotAtLevel<LevelBits>(rightStart, parentStart, level + 1);
                // For either full tree, rightChild == 1 means this
                // boundary is exactly:
                //
                //     child0 subtree | child1 subtree
                const bool canonical = (rightChild == 1);
                internalFlag[i] = canonical ? 1 : 0;
                internalCandidate[i].start = parentStart;
                internalCandidate[i].level = std::uint8_t(level);
            }
        }
        // =====================================================================
        // Stage 2
        //
        // Build all tiny per-level metadata completely on-device.
        //
        // No host readback.
        // =====================================================================
        template<unsigned LevelBits>
        __global__ void buildLevelMetadataKernel(
            const NodeIndex *leavesPerLevel, NodeIndex *internalNodesPerLevel,
            NodeIndex *nodesPerLevel, NodeIndex *levelOffset,
            NodeIndex *levelOffsetInternal, std::uint8_t *maxAchievedDepth,
            int leafCapacity, const RebalanceState *state)
        {
            if (activeLeaves(leafCapacity, state) == 0)
                return;
            if (blockIdx.x != 0 || threadIdx.x != 0)
                return;
            unsigned maxLevel = 0;
            for (unsigned level = 0; level <= kMaxTreeLevel<LevelBits>; ++level)
            {
                if (leavesPerLevel[level] != 0)
                    maxLevel = level;
                internalNodesPerLevel[level] = 0;
                nodesPerLevel[level] = 0;
            }
            *maxAchievedDepth = std::uint8_t(maxLevel);
            // Deepest level has no internal nodes.
            internalNodesPerLevel[maxLevel] = 0;
            nodesPerLevel[maxLevel] = leavesPerLevel[maxLevel];
            // -------------------------------------------------------------
            // Backward recurrence
            //
            // nodes[l+1] == child count * internal[l]
            //
            // nodes[l] = leaves[l] + internal[l]
            // -------------------------------------------------------------
            for (int level = int(maxLevel) - 1; level >= 0; --level)
            {
                internalNodesPerLevel[level] =
                    nodesPerLevel[level + 1] / kNumChildren<LevelBits>;
                nodesPerLevel[level] = leavesPerLevel[level] + internalNodesPerLevel[level];
            }
            // -------------------------------------------------------------
            // Global node offsets
            // -------------------------------------------------------------
            levelOffset[0] = 0;
            for (unsigned level = 0; level <= maxLevel; ++level)
            {
                levelOffset[level + 1] = levelOffset[level] + nodesPerLevel[level];
            }
            const NodeIndex numNodes = levelOffset[maxLevel + 1];

            for (unsigned level = maxLevel + 1; level <= kMaxTreeLevel<LevelBits>; ++level)
            {
                levelOffset[level + 1] = numNodes;
            }
            // -------------------------------------------------------------
            // Dense internal-node offsets
            // -------------------------------------------------------------
            levelOffsetInternal[0] = 0;
            for (unsigned level = 0; level <= maxLevel; ++level)
            {
                levelOffsetInternal[level + 1] =
                    levelOffsetInternal[level] + internalNodesPerLevel[level];
            }
            const NodeIndex numInternal = levelOffsetInternal[maxLevel + 1];
            for (unsigned level = maxLevel + 1; level <= kMaxTreeLevel<LevelBits>; ++level)
            {
                levelOffsetInternal[level + 1] = numInternal;
            }
        }
        // =====================================================================
        // Stage 3/4 helpers
        // =====================================================================
        template<unsigned LevelBits>
        __global__ void unpackInternalCandidatesKernel(
            const InternalCandidate *candidates, int numInternalNodes,
            std::uint8_t *levels, KeyType *starts, const RebalanceState *state)
        {
            const int idx = int(blockIdx.x * blockDim.x + threadIdx.x);
            if (idx >= numInternalNodes)
                return;
            if (idx >= activeInternals<LevelBits>(numInternalNodes, state))
            {
                levels[idx] = 255;
                starts[idx] = 0;
                return;
            }
            levels[idx] = candidates[idx].level;
            starts[idx] = candidates[idx].start;
        }
        // =====================================================================
        // Stage 5
        //
        // Construct exact old-BFS child-centric internal ordering.
        // =====================================================================
        template<unsigned LevelBits>
        __global__ void makeInternalLayoutKeysKernel(
            const std::uint8_t *internalLevelSfc, const KeyType *internalStartSfc,
            int numInternalNodes, KeyType *layoutKey, NodeIndex *layoutValue,
            const RebalanceState *state)
        {
            const int idx = int(blockIdx.x * blockDim.x + threadIdx.x);

            if (idx >= numInternalNodes)
                return;

            if (idx >= activeInternals<LevelBits>(numInternalNodes, state))
            {
                layoutKey[idx] = ~KeyType(0);
                layoutValue[idx] = 0;
                return;
            }
            const unsigned level = internalLevelSfc[idx];

            const KeyType reversedPath =
                childCentricLayoutKey<LevelBits>(internalStartSfc[idx], level);

            // Encode both:
            //
            //     primary key:   level
            //     secondary key: reversed child path
            //
            // reversedPath uses at most LevelBits*level bits:
            //
            //     0 <= reversedPath < 2^(LevelBits*level)
            //
            // Therefore setting bit LevelBits*level gives every level its own
            // non-overlapping numeric interval.
            layoutKey[idx] = (KeyType(1) << (LevelBits * level)) | reversedPath;

            // Position of this internal node in the level-grouped,
            // SFC-ordered representation.
            layoutValue[idx] = NodeIndex(idx);
        }
        template<unsigned LevelBits>
        __global__ void materializeInternalLayoutKernel(
            const NodeIndex *layoutToSfcPosition, int numInternalNodes,
            const std::uint8_t *internalLevelSfc, const KeyType *internalStartSfc,
            const NodeIndex *levelOffsetInternal, std::uint8_t *internalLevelLayout,
            KeyType *internalStartLayout, NodeIndex *internalMBySfcPos,
            const RebalanceState *state)
        {
            numInternalNodes = activeInternals<LevelBits>(numInternalNodes, state);
            const int layoutIdx = int(blockIdx.x * blockDim.x + threadIdx.x);
            if (layoutIdx >= numInternalNodes)
                return;
            const NodeIndex sfcPos = layoutToSfcPosition[layoutIdx];
            const unsigned level = internalLevelSfc[sfcPos];
            internalLevelLayout[layoutIdx] = std::uint8_t(level);
            internalStartLayout[layoutIdx] = internalStartSfc[sfcPos];
            const NodeIndex m = NodeIndex(layoutIdx) - levelOffsetInternal[level];
            internalMBySfcPos[sfcPos] = m;
        }
        // =====================================================================
        // Internal-node lookup
        // =====================================================================
        __device__ inline NodeIndex findInternalM(unsigned level, KeyType start,
                                                  const NodeIndex *levelOffsetInternal,
                                                  const KeyType *internalStartSfc,
                                                  const NodeIndex *internalMBySfcPos)
        {
            const NodeIndex begin = levelOffsetInternal[level];
            const NodeIndex end = levelOffsetInternal[level + 1];
            const KeyType *first = internalStartSfc + begin;
            const KeyType *last = internalStartSfc + end;
            const KeyType *position = lowerBound(first, last, start);
            const NodeIndex sfcPos = begin + NodeIndex(position - first);
            return internalMBySfcPos[sfcPos];
        }
        // =====================================================================
        // Exact final node index
        //
        // This reproduces the old generateChildrenKernel:
        //
        //     firstNewIdx + childSlot * M + parentRank
        //
        // =====================================================================
        template<unsigned LevelBits>
        __device__ inline NodeIndex finalNodeIndex(
            unsigned level, KeyType start, const NodeIndex *levelOffset,
            const NodeIndex *levelOffsetInternal,
            const NodeIndex *internalNodesPerLevel, const KeyType *internalStartSfc,
            const NodeIndex *internalMBySfcPos)
        {
            if (level == 0)
                return 0;
            const KeyType nodeRange = viewNodeRange<LevelBits>(level);
            const KeyType parentRange = viewNodeRange<LevelBits>(level - 1);
            const KeyType parentStart = (start / parentRange) * parentRange;
            const NodeIndex parentM =
                findInternalM(level - 1, parentStart, levelOffsetInternal,
                              internalStartSfc, internalMBySfcPos);
            const unsigned childSlot = unsigned((start - parentStart) / nodeRange);
            const NodeIndex parentCount = internalNodesPerLevel[level - 1];
            return levelOffset[level] + NodeIndex(childSlot) * parentCount + parentM;
        }
        // =====================================================================
        // Stage 6
        //
        // Build all internal nodes.
        // =====================================================================
        template<unsigned LevelBits>
        __global__ void buildInternalNodesKernel(
            const KeyType *P, std::size_t numParticles, int numInternalNodes,
            const std::uint8_t *internalLevelLayout, const KeyType *internalStartLayout,
            const NodeIndex *levelOffset, const NodeIndex *levelOffsetInternal,
            const NodeIndex *internalNodesPerLevel, const KeyType *internalStartSfc,
            const NodeIndex *internalMBySfcPos, bool computeParticleCountsPerBox,
            KeyType *sfcBoxIndex, unsigned *particleBeginIndex,
            unsigned *particleCounts, std::size_t numNodes, std::uint8_t *hasBoxSplit,
            std::uint8_t *boxDepth, NodeIndex *parentIndex, NodeIndex *childIndex,
            const RebalanceState *state)
        {
            numInternalNodes = activeInternals<LevelBits>(numInternalNodes, state);
            if (state)
                numNodes = state->numNodes;
            const int idx = int(blockIdx.x * blockDim.x + threadIdx.x);
            if (idx >= numInternalNodes)
                return;
            const unsigned level = internalLevelLayout[idx];
            const KeyType start = internalStartLayout[idx];
            const KeyType range = viewNodeRange<LevelBits>(level);
            const KeyType end = start + range;
            const NodeIndex nodeIdx = finalNodeIndex<LevelBits>(
                level, start, levelOffset, levelOffsetInternal, internalNodesPerLevel,
                internalStartSfc, internalMBySfcPos);
            // -------------------------------------------------------------
            // Permanent tree-view data
            // -------------------------------------------------------------
            sfcBoxIndex[nodeIdx] = encodePlaceholderBit(start, int(LevelBits * level));
            boxDepth[nodeIdx] = std::uint8_t(level);
            hasBoxSplit[nodeIdx] = 1;
            // Root parent. All non-root parent entries are filled by
            // writeParentPointersKernel.
            if (level == 0)
            {
                parentIndex[nodeIdx] = invalidNodeIndex;
            }
            // -------------------------------------------------------------
            // childIndex
            //
            // Exact old compactKernel semantics:
            //
            //     childIndex[parent] = first child-0 + m
            //
            // -------------------------------------------------------------
            const NodeIndex m = NodeIndex(idx) - levelOffsetInternal[level];

            const NodeIndex M = internalNodesPerLevel[level];

            // First child, same semantics as before.
            childIndex[nodeIdx] = levelOffset[level + 1] + m;

            // Every child has exactly one parent.
            for (unsigned childSlot = 0; childSlot < kNumChildren<LevelBits>; ++childSlot)
            {
                const NodeIndex childNodeIdx =
                    levelOffset[level + 1] + NodeIndex(childSlot) * M + m;

                parentIndex[childNodeIdx] = nodeIdx;
            }
            // -------------------------------------------------------------
            // Particle counts for internal boxes
            //
            // Same binary-search behavior as current classifyKernel.
            // -------------------------------------------------------------
            if (computeParticleCountsPerBox)
            {
                const int b = int(lowerBound(P, P + numParticles, start) - P);
                const int e = int(lowerBound(P, P + numParticles, end) - P);
                particleBeginIndex[nodeIdx] = unsigned(b);
                particleCounts[nodeIdx] = unsigned(e - b);

                if (level == 0)
                    particleCounts[numNodes] = unsigned(e - b);
            }
        }
        // =====================================================================
        // Stage 7
        //
        // Build all real cornerstone leaves.
        // =====================================================================
        template<unsigned LevelBits>
        __global__ void buildLeafNodesKernel(
            const KeyType *K, int numLeaves, const std::uint8_t *leafLevel,
            const NodeIndex *levelOffset, const NodeIndex *levelOffsetInternal,
            const NodeIndex *internalNodesPerLevel, const KeyType *internalStartSfc,
            const NodeIndex *internalMBySfcPos, bool computeParticleCountsPerBox,
            const unsigned *leafBeginIndex, const unsigned *leafCounts,
            KeyType *sfcBoxIndex, unsigned *particleBeginIndex,
            unsigned *particleCounts, std::size_t numNodes, std::size_t numParticles,
            std::uint8_t *hasBoxSplit, std::uint8_t *boxDepth, NodeIndex *parentIndex,
            NodeIndex *childIndex, NodeIndex *leafToNode, const RebalanceState *state,
            const KeyType *K_alt, const unsigned *N_alt)
        {
            if (state && state->activeBuffer)
            {
                K = K_alt;
                leafCounts = N_alt;
            }
            numLeaves = activeLeaves(numLeaves, state);
            if (state)
                numNodes = state->numNodes;
            const int leafIdx = int(blockIdx.x * blockDim.x + threadIdx.x);
            if (leafIdx >= numLeaves)
                return;
            const unsigned level = leafLevel[leafIdx];
            const KeyType start = K[leafIdx];
            const NodeIndex nodeIdx = finalNodeIndex<LevelBits>(
                level, start, levelOffset, levelOffsetInternal, internalNodesPerLevel,
                internalStartSfc, internalMBySfcPos);
            sfcBoxIndex[nodeIdx] = encodePlaceholderBit(start, int(LevelBits * level));
            boxDepth[nodeIdx] = std::uint8_t(level);
            hasBoxSplit[nodeIdx] = 0;
            childIndex[nodeIdx] = invalidNodeIndex;
            leafToNode[leafIdx] = nodeIdx;
            // Single-leaf tree.
            if (level == 0)
            {
                parentIndex[nodeIdx] = invalidNodeIndex;
            }
            // -------------------------------------------------------------
            // Reuse existing leaf counts exactly as current implementation.
            // -------------------------------------------------------------
            if (computeParticleCountsPerBox)
            {
                particleBeginIndex[nodeIdx] = leafBeginIndex[leafIdx];
                particleCounts[nodeIdx] = leafCounts[leafIdx];

                if (level == 0)
                    particleCounts[numNodes] = leafCounts[leafIdx];
            }
        }
        // =====================================================================
        // Particle mapping
        // =====================================================================
        __global__ void fillSfcParticleIndexKernel(
            const KeyType *K, const KeyType *P, std::size_t numParticles, int numLeaves,
            const NodeIndex *leafToNode, KeyType *sfcParticleIndex,
            const RebalanceState *state, const KeyType *K_alt)
        {
            if (state && state->activeBuffer)
                K = K_alt;
            numLeaves = activeLeaves(numLeaves, state);
            if (numLeaves == 0)
                return;
            const std::size_t p = blockIdx.x * std::size_t(blockDim.x) + threadIdx.x;
            if (p >= numParticles)
                return;
            if (P[p] >= maxKey)
            {
                sfcParticleIndex[p] = invalidParticleNodeIndex;
                return;
            }
            const int leafIdx = int(upperBound(K, K + numLeaves, P[p]) - K) - 1;
            sfcParticleIndex[p] = leafToNode[leafIdx];
        }
        // =====================================================================
        // Scratch
        // =====================================================================

        struct DirectScratch
        {
            // -------------------------------------------------------------
            // Per-leaf
            // -------------------------------------------------------------
            thrust::device_vector<std::uint8_t> leafLevel;
            thrust::device_vector<unsigned> leafBeginIndex;
            // -------------------------------------------------------------
            // Tiny per-level arrays
            // -------------------------------------------------------------
            thrust::device_vector<NodeIndex> leavesPerLevel;
            thrust::device_vector<NodeIndex> internalNodesPerLevel;
            thrust::device_vector<NodeIndex> nodesPerLevel;
            thrust::device_vector<NodeIndex> levelOffsetInternal;
            // -------------------------------------------------------------
            // Canonical internal-node extraction
            // -------------------------------------------------------------
            thrust::device_vector<std::uint8_t> internalFlag;
            thrust::device_vector<InternalCandidate> internalCandidate;
            thrust::device_vector<InternalCandidate> internalCandidateCompact;
            thrust::device_vector<int> selectedInternalCount{1};
            // -------------------------------------------------------------
            // Internal nodes:
            //
            // level-grouped, SFC ordered inside each level
            // -------------------------------------------------------------
            thrust::device_vector<std::uint8_t> internalLevelSfc;
            thrust::device_vector<std::uint8_t> internalLevelSfcAlt;
            thrust::device_vector<KeyType> internalStartSfc;
            thrust::device_vector<KeyType> internalStartSfcAlt;
            // -------------------------------------------------------------
            // Exact old-BFS child-centric internal layout
            // -------------------------------------------------------------
            thrust::device_vector<std::uint8_t> internalLevelLayout;
            thrust::device_vector<KeyType> internalStartLayout;
            thrust::device_vector<NodeIndex> internalMBySfcPos;
            // First stable sort:
            //
            //     reversed child-path key
            // -------------------------------------------------------------
            thrust::device_vector<KeyType> layoutKey;
            thrust::device_vector<KeyType> layoutKeyAlt;
            thrust::device_vector<NodeIndex> layoutValue;
            thrust::device_vector<NodeIndex> layoutValueAlt;

            // -------------------------------------------------------------
            // Reusable CUB workspaces
            // -------------------------------------------------------------
            thrust::device_vector<std::uint8_t> cubSelectTempStorage;
            thrust::device_vector<std::uint8_t> cubSortTempStorage;
            thrust::device_vector<std::uint8_t> cubScanTempStorage;
            void resize(std::size_t numLeaves, std::size_t numInternalNodes,
                        unsigned numTreeLevels)
            {
                resizeWithHeadroom(leafLevel, numLeaves);
                resizeWithHeadroom(leafBeginIndex, numLeaves);
                resizeWithHeadroom(leavesPerLevel, numTreeLevels);
                resizeWithHeadroom(internalNodesPerLevel, numTreeLevels);
                resizeWithHeadroom(nodesPerLevel, numTreeLevels);
                resizeWithHeadroom(levelOffsetInternal, numTreeLevels + 1);
                const std::size_t numBoundaries = numLeaves > 0 ? numLeaves - 1 : 0;
                resizeWithHeadroom(internalFlag, numBoundaries);
                resizeWithHeadroom(internalCandidate, numBoundaries);
                resizeWithHeadroom(internalCandidateCompact, numInternalNodes);
                resizeWithHeadroom(internalLevelSfc, numInternalNodes);
                resizeWithHeadroom(internalLevelSfcAlt, numInternalNodes);
                resizeWithHeadroom(internalStartSfc, numInternalNodes);
                resizeWithHeadroom(internalStartSfcAlt, numInternalNodes);
                resizeWithHeadroom(internalLevelLayout, numInternalNodes);
                resizeWithHeadroom(internalStartLayout, numInternalNodes);
                resizeWithHeadroom(internalMBySfcPos, numInternalNodes);
                resizeWithHeadroom(layoutKey, numInternalNodes);
                resizeWithHeadroom(layoutKeyAlt, numInternalNodes);
                resizeWithHeadroom(layoutValue, numInternalNodes);
                resizeWithHeadroom(layoutValueAlt, numInternalNodes);
            }
        };
        inline void ensureCubStorage(thrust::device_vector<std::uint8_t> &storage,
                                     std::size_t requiredBytes)
        {
            if (requiredBytes > storage.size())
                storage.resize(requiredBytes, thrust::no_init);
        }

        void compactInternalCandidates(execution::Gpu exec, DirectScratch &scratch,
                                       int numBoundaries)
        {
            if (numBoundaries <= 0)
                return;
            std::size_t tempBytes = scratch.cubSelectTempStorage.size();
            checkGpuErrors(cub::DeviceSelect::Flagged(
                rawPtr(scratch.cubSelectTempStorage), tempBytes,
                rawPtr(scratch.internalCandidate), rawPtr(scratch.internalFlag),
                rawPtr(scratch.internalCandidateCompact),
                rawPtr(scratch.selectedInternalCount), numBoundaries, exec));
        }
        // Stable radix sort by level
        void sortInternalsByLevel(execution::Gpu exec, DirectScratch &scratch,
                                  int numInternalNodes)
        {
            if (numInternalNodes <= 1)
                return;
            std::size_t tempBytes = scratch.cubSortTempStorage.size();
            checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                rawPtr(scratch.cubSortTempStorage), tempBytes,
                rawPtr(scratch.internalLevelSfc), rawPtr(scratch.internalLevelSfcAlt),
                rawPtr(scratch.internalStartSfc), rawPtr(scratch.internalStartSfcAlt),
                numInternalNodes, 0, 8, exec));
        }
        void sortInternalLayout(execution::Gpu exec, DirectScratch &scratch,
                                int numInternalNodes)
        {
            if (numInternalNodes <= 1)
                return;

            std::size_t tempBytes = scratch.cubSortTempStorage.size();

            checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                rawPtr(scratch.cubSortTempStorage), tempBytes, rawPtr(scratch.layoutKey),
                rawPtr(scratch.layoutKeyAlt), rawPtr(scratch.layoutValue),
                rawPtr(scratch.layoutValueAlt), numInternalNodes, 0,
                int(sizeof(KeyType) * 8), exec));
        }

        void computeLeafBeginIndex(cudaStream_t stream, DirectScratch &scratch,
                                   const thrust::device_vector<unsigned> &N_d,
                                   std::size_t numLeaves, const unsigned *N_alt,
                                   const RebalanceState *state)
        {
            if (numLeaves == 0)
                return;
            std::size_t tempBytes = scratch.cubScanTempStorage.size();
            checkGpuErrors(cub::DeviceScan::ExclusiveSum(
                rawPtr(scratch.cubScanTempStorage), tempBytes,
                leafCountInput(rawPtr(N_d), N_alt, state), rawPtr(scratch.leafBeginIndex),
                numLeaves, stream));
        }
        void prepareCubStorage(execution::Gpu exec, DirectScratch &scratch,
                               std::size_t leaves, std::size_t internals,
                               bool particleCounts)
        {
            std::size_t bytes = 0;
            if (leaves > 1)
            {
                checkGpuErrors(cub::DeviceSelect::Flagged(
                    nullptr, bytes, rawPtr(scratch.internalCandidate),
                    rawPtr(scratch.internalFlag), rawPtr(scratch.internalCandidateCompact),
                    rawPtr(scratch.selectedInternalCount), int(leaves - 1), exec));
                ensureCubStorage(scratch.cubSelectTempStorage, bytes);
            }
            if (internals > 1)
            {
                bytes = 0;
                checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                    nullptr, bytes, rawPtr(scratch.internalLevelSfc),
                    rawPtr(scratch.internalLevelSfcAlt), rawPtr(scratch.internalStartSfc),
                    rawPtr(scratch.internalStartSfcAlt), int(internals), 0, 8, exec));
                ensureCubStorage(scratch.cubSortTempStorage, bytes);
                bytes = 0;
                checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                    nullptr, bytes, rawPtr(scratch.layoutKey), rawPtr(scratch.layoutKeyAlt),
                    rawPtr(scratch.layoutValue), rawPtr(scratch.layoutValueAlt),
                    int(internals), 0, int(sizeof(KeyType) * 8), exec));
                ensureCubStorage(scratch.cubSortTempStorage, bytes);
            }
            if (particleCounts)
            {
                bytes = 0;
                checkGpuErrors(cub::DeviceScan::ExclusiveSum(
                    nullptr, bytes, leafCountInput(nullptr, nullptr, nullptr),
                    rawPtr(scratch.leafBeginIndex), leaves, exec));
                ensureCubStorage(scratch.cubScanTempStorage, bytes);
            }
        }
    } // namespace
    // =========================================================================
    // TreeView
    // =========================================================================
    template<unsigned LevelBits>
    struct TreeView<LevelBits>::Scratch : DirectScratch
    {
    };

    template<unsigned LevelBits>
    TreeView<LevelBits>::TreeView() = default;
    template<unsigned LevelBits>
    TreeView<LevelBits>::~TreeView() { cudaFree(maxAchievedDepth_d_); }

    template<unsigned LevelBits>
    void TreeView<LevelBits>::prepare(std::size_t leafCapacity,
                                      std::size_t numParticles,
                                      Config config, execution::Gpu exec)
    {
        if (!config.treeStructure && !config.particleCountsPerBox &&
            !config.particleMapping)
            return;
        leafCapacity_ = std::max(leafCapacity_, leafCapacity);
        particleCapacity_ = std::max(particleCapacity_, numParticles);
        preparedConfig_.treeStructure |= config.treeStructure;
        preparedConfig_.particleCountsPerBox |= config.particleCountsPerBox;
        preparedConfig_.particleMapping |= config.particleMapping;
        const std::size_t internals = (leafCapacity_ - 1) / (kNumChildren<LevelBits> - 1);
        const std::size_t nodes = leafCapacity_ + internals;
        if (!scratch_)
            scratch_ = std::make_unique<Scratch>();
        if (!maxAchievedDepth_d_)
            checkGpuErrors(cudaMalloc(&maxAchievedDepth_d_, sizeof(std::uint8_t)));
        resizeWithHeadroom(sfcBoxIndex_d_, nodes);
        resizeWithHeadroom(hasBoxSplit_d_, nodes);
        resizeWithHeadroom(boxDepth_d_, nodes);
        resizeWithHeadroom(parentIndex_d_, nodes);
        resizeWithHeadroom(childIndex_d_, nodes);
        resizeWithHeadroom(leafToNode_d_, leafCapacity_);
        resizeWithHeadroom(levelOffset_d_, kMaxTreeLevel<LevelBits> + 2);
        if (preparedConfig_.particleCountsPerBox)
        {
            resizeWithHeadroom(particleBeginIndex_d_, nodes);
            resizeWithHeadroom(particleCounts_d_, nodes + 1);
        }
        if (preparedConfig_.particleMapping)
            resizeWithHeadroom(sfcParticleIndex_d_, particleCapacity_);
        scratch_->resize(leafCapacity_, internals, kMaxTreeLevel<LevelBits> + 1);
        prepareCubStorage(exec, *scratch_, leafCapacity_, internals,
                          preparedConfig_.particleCountsPerBox);
    }

    template<unsigned LevelBits>
    void TreeView<LevelBits>::syncSizes(std::size_t numLeaves,
                                        std::size_t numActiveParticles)
    {
        if (!scratch_ || numLeaves > leafCapacity_)
            return;
        numNodes_ = numLeaves + (numLeaves - 1) / (kNumChildren<LevelBits> - 1);
        sfcBoxIndex_d_.resize(numNodes_, thrust::no_init);
        hasBoxSplit_d_.resize(numNodes_, thrust::no_init);
        boxDepth_d_.resize(numNodes_, thrust::no_init);
        parentIndex_d_.resize(numNodes_, thrust::no_init);
        childIndex_d_.resize(numNodes_, thrust::no_init);
        leafToNode_d_.resize(numLeaves, thrust::no_init);
        if (preparedConfig_.particleCountsPerBox)
        {
            particleBeginIndex_d_.resize(numNodes_, thrust::no_init);
            particleCounts_d_.resize(numNodes_ + 1, thrust::no_init);
        }
        if (preparedConfig_.particleMapping)
            sfcParticleIndex_d_.resize(numActiveParticles, thrust::no_init);
    }
    template<unsigned LevelBits>
    void TreeView<LevelBits>::build(detail::execution::Gpu exec,
                                    CudaContext *cudaContext,
                                    const thrust::device_vector<KeyType> &K_d,
                                    const thrust::device_vector<KeyType> &P_d,
                                    const thrust::device_vector<unsigned> &N_d,
                                    std::size_t numParticles, Config config,
                                    RebalanceState *state, const KeyType *K_alt,
                                    const unsigned *N_alt)
    {
        if (!config.treeStructure && !config.particleCountsPerBox &&
            !config.particleMapping)
        {
            return;
        }
        if (!state)
        {
            prepare(nNodes(K_d), numParticles, config, exec);
            syncSizes(nNodes(K_d), numParticles);
        }
        else if (!scratch_ ||
                 (config.particleCountsPerBox &&
                  !preparedConfig_.particleCountsPerBox) ||
                 (config.particleMapping && (!preparedConfig_.particleMapping ||
                                             numParticles > particleCapacity_)))
        {
            flagViewCapacityKernel<<<1, 1, 0, exec>>>(state);
#ifndef NDEBUG
            checkGpuErrors(cudaGetLastError());
#endif
            return;
        }

        // ---------------------------------------------------------------------
        // CUDA streams / events used by this build
        // ---------------------------------------------------------------------
        cudaStream_t metadataStream = cudaContext->computeA;
        cudaStream_t leafStream = cudaContext->computeB;
        cudaStream_t particleStream = cudaContext->computeC;

        cudaEvent_t classificationDone = cudaContext->readyA;
        cudaEvent_t layoutDone = cudaContext->readyA; // reused later
        cudaEvent_t metadataDone = cudaContext->readyB;
        cudaEvent_t leafPrefixDone = cudaContext->readyC;
        cudaEvent_t particleMappingDone = cudaContext->readyC; // reused later
        cudaEvent_t leafBuildDone = cudaContext->readyD;

        // ---------------------------------------------------------------------
        // Analytical sizes
        // ---------------------------------------------------------------------
        const std::size_t numLeaves = state ? leafCapacity_ : nNodes(K_d);
        const std::size_t numInternalNodes =
            (numLeaves - 1) / (kNumChildren<LevelBits> - 1);
        const std::size_t numNodes = numLeaves + numInternalNodes;
        const KeyType *K = rawPtr(K_d);
        const KeyType *P = rawPtr(P_d);
        constexpr int nThreads = defaults::blockThreads;
        auto blocks = [](std::size_t n)
        {
            return int((n + nThreads - 1) / nThreads);
        };
        DirectScratch &scratch = *scratch_;
        const auto *internalLevels = numInternalNodes > 1
                                         ? rawPtr(scratch.internalLevelSfcAlt)
                                         : rawPtr(scratch.internalLevelSfc);
        const auto *internalStarts = numInternalNodes > 1
                                         ? rawPtr(scratch.internalStartSfcAlt)
                                         : rawPtr(scratch.internalStartSfc);
        const auto *layoutValues = numInternalNodes > 1
                                       ? rawPtr(scratch.layoutValueAlt)
                                       : rawPtr(scratch.layoutValue);
        // Join the caller stream before the independent scan; this also forks
        // particleStream into the caller's CUDA graph capture.
        checkGpuErrors(cudaEventRecord(leafBuildDone, exec));
        checkGpuErrors(cudaStreamWaitEvent(particleStream, leafBuildDone, 0));
        // ---------------------------------------------------------------------
        // Compute at which index in P_d each leaf's particles begin via exclusive sum
        // ---------------------------------------------------------------------

        if (config.particleCountsPerBox)
        {
            computeLeafBeginIndex(particleStream, scratch, N_d, numLeaves, N_alt,
                                  state);

            checkGpuErrors(cudaEventRecord(leafPrefixDone, particleStream));
        }
        // ---------------------------------------------------------------------
        // STAGE 1
        //
        // We look at K_d. Each interval in K_d describes a leaf. Each border in K_d
        // describes a possible internal node. A root-only tree has two boundaries
        // and one interval. Splitting it produces one interval per child. For each
        // adjacent pair of leaf starts, find their lowest common ancestor and flag
        // the unique boundary between its child-0 and child-1 subtrees.
        // ---------------------------------------------------------------------
        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Classify leaves and internals");
        checkGpuErrors(
            cudaMemsetAsync(rawPtr(scratch.leavesPerLevel), 0,
                            scratch.leavesPerLevel.size() * sizeof(NodeIndex), exec));
        classifyLeavesAndInternalsKernel<LevelBits>
            <<<blocks(numLeaves), nThreads, 0, exec>>>(
            K, int(numLeaves), rawPtr(scratch.leafLevel),
            rawPtr(scratch.leavesPerLevel), rawPtr(scratch.internalFlag),
            rawPtr(scratch.internalCandidate), state, K_alt);
#ifndef NDEBUG
        checkGpuErrors(cudaGetLastError());
#endif
        checkGpuErrors(cudaEventRecord(classificationDone, exec));
        ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        // ---------------------------------------------------------------------
        // STAGE 2
        //
        // The deepest nonempty level contains only leaves. Working backwards,
        // divide each level's node count by the child count to obtain the preceding
        // level's internal count, then add its leaves to obtain its total count.
        // ---------------------------------------------------------------------
        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Build level metadata");
        checkGpuErrors(cudaStreamWaitEvent(metadataStream, classificationDone, 0));

        buildLevelMetadataKernel<LevelBits><<<1, 1, 0, metadataStream>>>(
            rawPtr(scratch.leavesPerLevel), rawPtr(scratch.internalNodesPerLevel),
            rawPtr(scratch.nodesPerLevel), rawPtr(levelOffset_d_),
            rawPtr(scratch.levelOffsetInternal), maxAchievedDepth_d_, int(numLeaves),
            state);
#ifndef NDEBUG
        checkGpuErrors(cudaGetLastError());
#endif

        checkGpuErrors(cudaEventRecord(metadataDone, metadataStream));
        ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        // ---------------------------------------------------------------------
        // STAGES 3-5 only exist if there are internal nodes.
        // ---------------------------------------------------------------------
        if (numInternalNodes > 0)
        {
            // -----------------------------------------------------------------
            // STAGE 3
            //
            // In stage 2 we flagged when there was an internal node at some level and
            // found also the startKey of that internal node. We can now compact that
            // first by deleting all non-flagged entries, then we can seperate the
            // candidate struct into two different arrays giving us internalStartSfc and
            // internalLevelSfs. So first entry reveals there is an internal node at
            // that level with that startSfc. Note that this is completely unsorted.
            // -----------------------------------------------------------------
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Compact internal nodes");
            compactInternalCandidates(exec, scratch, int(numLeaves - 1));
            unpackInternalCandidatesKernel<LevelBits>
                <<<blocks(numInternalNodes), nThreads, 0, exec>>>(
                rawPtr(scratch.internalCandidateCompact), int(numInternalNodes),
                rawPtr(scratch.internalLevelSfc), rawPtr(scratch.internalStartSfc),
                state);
#ifndef NDEBUG
            checkGpuErrors(cudaGetLastError());
#endif
            ADAPTIVE_OCTREE_NVTX_RANGE_POP();
            // -----------------------------------------------------------------
            // STAGE 4
            //
            // We have our list that reveal all internal nodes and startSfc from
            // stage 3. we can now sort by level, so we !BFS ordered! internal nodes.
            // -----------------------------------------------------------------
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Sort internals by level");
            sortInternalsByLevel(exec, scratch, int(numInternalNodes));
            ADAPTIVE_OCTREE_NVTX_RANGE_POP();

            // -----------------------------------------------------------------
            // STAGE 5
            //
            // Construct the exact old-BFS child-centric internal ordering.
            //
            // One combined radix key encodes:
            //
            //     primary:   level
            //     secondary: reversed child path
            // -----------------------------------------------------------------
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Build child-centric internal order");

            makeInternalLayoutKeysKernel<LevelBits>
                <<<blocks(numInternalNodes), nThreads, 0, exec>>>(
                internalLevels, internalStarts, int(numInternalNodes),
                rawPtr(scratch.layoutKey), rawPtr(scratch.layoutValue), state);
#ifndef NDEBUG
            checkGpuErrors(cudaGetLastError());
#endif

            sortInternalLayout(exec, scratch, int(numInternalNodes));

            // Materialization requires the internal-level offsets produced
            // by Stage 2.
            checkGpuErrors(cudaStreamWaitEvent(exec, metadataDone, 0));

            materializeInternalLayoutKernel<LevelBits>
                <<<blocks(numInternalNodes), nThreads, 0, exec>>>(
                layoutValues, int(numInternalNodes), internalLevels, internalStarts,
                rawPtr(scratch.levelOffsetInternal),
                rawPtr(scratch.internalLevelLayout),
                rawPtr(scratch.internalStartLayout), rawPtr(scratch.internalMBySfcPos),
                state);
#ifndef NDEBUG
            checkGpuErrors(cudaGetLastError());
#endif

            checkGpuErrors(cudaEventRecord(layoutDone, exec));

            ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        }
        // ---------------------------------------------------------------------
        // STAGES 6 + 7
        //
        // Flat construction of all permanent tree nodes.
        // ---------------------------------------------------------------------

        // Required also for the root-only case.
        checkGpuErrors(cudaStreamWaitEvent(exec, metadataDone, 0));

        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Build tree-view nodes");

        unsigned *particleBeginIndex =
            config.particleCountsPerBox ? rawPtr(particleBeginIndex_d_) : nullptr;

        unsigned *particleCounts =
            config.particleCountsPerBox ? rawPtr(particleCounts_d_) : nullptr;

        const unsigned *leafBeginIndex =
            config.particleCountsPerBox ? rawPtr(scratch.leafBeginIndex) : nullptr;

        const unsigned *leafCounts =
            config.particleCountsPerBox ? rawPtr(N_d) : nullptr;

        // ---------------------------------------------------------------------
        // Stage 6: internal nodes on exec
        // ---------------------------------------------------------------------
        if (numInternalNodes > 0)
        {
            buildInternalNodesKernel<LevelBits>
                <<<blocks(numInternalNodes), nThreads, 0, exec>>>(
                P, numParticles, int(numInternalNodes),
                rawPtr(scratch.internalLevelLayout),
                rawPtr(scratch.internalStartLayout), rawPtr(levelOffset_d_),
                rawPtr(scratch.levelOffsetInternal),
                rawPtr(scratch.internalNodesPerLevel), internalStarts,
                rawPtr(scratch.internalMBySfcPos), config.particleCountsPerBox,
                rawPtr(sfcBoxIndex_d_), particleBeginIndex, particleCounts, numNodes,
                rawPtr(hasBoxSplit_d_), rawPtr(boxDepth_d_), rawPtr(parentIndex_d_),
                rawPtr(childIndex_d_), state);

#ifndef NDEBUG
            checkGpuErrors(cudaGetLastError());
#endif
        }

        // ---------------------------------------------------------------------
        // Stage 7: leaf nodes on leafStream
        // ---------------------------------------------------------------------

        // Leaf construction needs Stage 2 metadata.
        checkGpuErrors(cudaStreamWaitEvent(leafStream, metadataDone, 0));

        // Nontrivial trees also need Stage 5 materialization.
        if (numInternalNodes > 0)
        {
            checkGpuErrors(cudaStreamWaitEvent(leafStream, layoutDone, 0));
        }

        // Particle begin indices come from the independent prefix scan.
        if (config.particleCountsPerBox)
        {
            checkGpuErrors(cudaStreamWaitEvent(leafStream, leafPrefixDone, 0));
        }

        buildLeafNodesKernel<LevelBits><<<blocks(numLeaves), nThreads, 0, leafStream>>>(
            K, int(numLeaves), rawPtr(scratch.leafLevel), rawPtr(levelOffset_d_),
            rawPtr(scratch.levelOffsetInternal),
            rawPtr(scratch.internalNodesPerLevel), internalStarts,
            rawPtr(scratch.internalMBySfcPos), config.particleCountsPerBox,
            leafBeginIndex, leafCounts, rawPtr(sfcBoxIndex_d_), particleBeginIndex,
            particleCounts, numNodes, numParticles, rawPtr(hasBoxSplit_d_),
            rawPtr(boxDepth_d_), rawPtr(parentIndex_d_), rawPtr(childIndex_d_),
            rawPtr(leafToNode_d_), state, K_alt, N_alt);

        checkGpuErrors(cudaEventRecord(leafBuildDone, leafStream));

        checkGpuErrors(cudaStreamWaitEvent(exec, leafBuildDone, 0));

        checkGpuErrors(cudaStreamWaitEvent(particleStream, leafBuildDone, 0));

        ADAPTIVE_OCTREE_NVTX_RANGE_POP();

        // ---------------------------------------------------------------------
        // Particle mapping
        // ---------------------------------------------------------------------
        if (config.particleMapping)
        {
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Particle Mapping");

            const std::size_t numParticleBlocks =
                (numParticles + nThreads - 1) / nThreads;

            if (numParticleBlocks > 0)
            {
                fillSfcParticleIndexKernel<<<numParticleBlocks, nThreads, 0,
                                             particleStream>>>(
                    K, P, numParticles, int(numLeaves), rawPtr(leafToNode_d_),
                    rawPtr(sfcParticleIndex_d_), state, K_alt);
#ifndef NDEBUG
                checkGpuErrors(cudaGetLastError());
#endif
            }

            checkGpuErrors(cudaEventRecord(particleMappingDone, particleStream));

            checkGpuErrors(cudaStreamWaitEvent(exec, particleMappingDone, 0));
            ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        }
        if (!config.particleMapping)
        {
            checkGpuErrors(cudaEventRecord(particleMappingDone, particleStream));
            checkGpuErrors(cudaStreamWaitEvent(exec, particleMappingDone, 0));
        }
    }
    template<unsigned LevelBits>
    unsigned TreeView<LevelBits>::maxAchievedDepth() const
    {
        if (maxAchievedDepth_d_ == nullptr)
            return 0;
        std::uint8_t value = 0;
        checkGpuErrors(cudaMemcpy(&value, maxAchievedDepth_d_, sizeof(std::uint8_t),
                                  cudaMemcpyDeviceToHost));
        return unsigned(value);
    }
    template class TreeView<3>;
    template class TreeView<1>;
} // namespace adaptive_octree
