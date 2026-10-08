// octree_rebalance.cuh
//
// Split/merge decision logic + the full rebalance loop
#pragma once

#include <cooperative_groups.h>
#include <thrust/device_vector.h>
#include <thrust/iterator/counting_iterator.h>

#include <algorithm>
#include <cstdint>
#include <cub/device/device_scan.cuh>
#include <cub/device/device_select.cuh>
#include <limits>
#include <span>

#include "helpers.cuh"
#include "sfc_keys.cuh"

namespace adaptive_octree::detail
{
    namespace cg = cooperative_groups;

    //! @brief sibling index [0:8) if all 8 siblings of nodeIdx are present at the
    //! same level, else -1
    template <class KeyType>
    HOST_DEVICE_FUN int siblingIndexAndLevel(const KeyType *tree,
                                             TreeNodeIndex numNodes,
                                             TreeNodeIndex nodeIdx,
                                             unsigned &levelOut)
    {
        KeyType thisNode = tree[nodeIdx];
        KeyType range = tree[nodeIdx + 1] - thisNode;
        unsigned level = treeLevel(range);
        levelOut = level;

        if (level == 0)
            return -1; // root: no siblings, and nodeIdx-siblingIdx+8 would be out of
                       // bounds

        int siblingIdx = int(octalDigit(thisNode, level));
        const TreeNodeIndex firstSibling = nodeIdx - siblingIdx;
        if (firstSibling < 0 || firstSibling > numNodes - 8)
            return -1;
        bool haveSiblings =
            (tree[nodeIdx - siblingIdx + 8] ==
             tree[nodeIdx - siblingIdx] + nodeRange<KeyType>(level - 1));

        return haveSiblings ? siblingIdx : -1;
    }

    struct IsDirtyNFNode
    {
        const std::uint8_t *nfDirty;

        __device__ bool operator()(TreeNodeIndex nodeIdx) const
        {
            return nfDirty[nodeIdx] != 0;
        }
    };

    template <class KeyType>
    __global__ void resetRebalanceStateKernel(RebalanceState *state,
                                               const KeyType *keys, std::size_t numSlots)
    {
        if (blockIdx.x == 0 && threadIdx.x == 0)
        {
            state->changed = 0;
            state->converged = 0;
            state->numActiveParticles = numSlots == 0 ? 0u : static_cast<unsigned>(
                lowerBound(keys, keys + numSlots, nodeRange<KeyType>(0)) - keys);
        }
    }

    template <class KeyType>
    inline void resetRebalanceStateGpu(cudaStream_t stream, RebalanceState *state,
                                       std::span<const KeyType> keys)
    {
        resetRebalanceStateKernel<<<1, 1, 0, stream>>>(state, keys.data(), keys.size());
    }

    template <class KeyType>
    struct IsDirtyGroupLeader
    {
        const KeyType *tree;
        const std::uint8_t *groupDirty;
        TreeNodeIndex numNodes;

        __device__ bool operator()(TreeNodeIndex firstSibling) const
        {
            // Need room for all 8 children.
            if (firstSibling + 8 > numNodes)
                return false;

            // Cached result is still valid.
            if (groupDirty && !groupDirty[firstSibling])
                return false;

            unsigned siblingLevel = 0;
            const int siblingIdx =
                siblingIndexAndLevel(tree, numNodes, firstSibling, siblingLevel);

            return siblingIdx == 0 && siblingLevel > 0;
        }
    };

    // -------------------------------------------------------------------------
    // split/merge decision for a single node
    // -------------------------------------------------------------------------

    void compactDirtyNFNodesGpu(cudaStream_t stream, TreeNodeIndex numNodes,
                                const std::uint8_t *nfDirty,
                                TreeNodeIndex *dirtyNFIndices,
                                TreeNodeIndex *numDirtyNFNodes,
                                thrust::device_vector<std::uint8_t> &tempStorage)
    {
        auto indices = thrust::make_counting_iterator<TreeNodeIndex>(0);

        IsDirtyNFNode predicate{nfDirty};

        std::size_t requiredBytes = 0;

        cub::DeviceSelect::If(nullptr, requiredBytes, indices, dirtyNFIndices,
                              numDirtyNFNodes, numNodes, predicate, stream);

        if (requiredBytes > tempStorage.size())
            resizeWithHeadroom(tempStorage, requiredBytes);

        std::size_t tempStorageBytes = tempStorage.size();

        cub::DeviceSelect::If(rawPtr(tempStorage), tempStorageBytes, indices,
                              dirtyNFIndices, numDirtyNFNodes, numNodes, predicate,
                              stream);
    }

    template <class KeyType>
    void compactDirtyGroupsGpu(cudaStream_t stream, const KeyType *tree,
                               TreeNodeIndex numNodes,
                               const std::uint8_t *groupDirty,
                               TreeNodeIndex *dirtyGroupIndices,
                               TreeNodeIndex *numDirtyGroups,
                               thrust::device_vector<std::uint8_t> &tempStorage)
    {
        auto indices = thrust::make_counting_iterator<TreeNodeIndex>(0);

        IsDirtyGroupLeader<KeyType> predicate{tree, groupDirty, numNodes};

        std::size_t requiredBytes = 0;

        cub::DeviceSelect::If(nullptr, requiredBytes, indices, dirtyGroupIndices,
                              numDirtyGroups, numNodes, predicate, stream);

        if (requiredBytes > tempStorage.size())
            resizeWithHeadroom(tempStorage, requiredBytes);

        std::size_t tempStorageBytes = tempStorage.size();

        cub::DeviceSelect::If(rawPtr(tempStorage), tempStorageBytes, indices,
                              dirtyGroupIndices, numDirtyGroups, numNodes, predicate,
                              stream);
    }

    // helper function so a nodeOp can be recovered after it has been transformed
    // into a prefix-sum array already
    template <class Offset>
    HOST_DEVICE_FUN TreeNodeIndex getNodeOp(const Offset *nodeOps,
                                            TreeNodeIndex nodeIdx)
    {
        return nodeOps[nodeIdx + 1] - nodeOps[nodeIdx];
    }

    //! @brief returns 0 for merging, 1 for no-change, or a power of 8 (8, 64, 512,
    //! ...) for splitting
    template <class KeyType>
    HOST_DEVICE_FUN int calculateNodeOp(const KeyType *tree, TreeNodeIndex numNodes,
                                        TreeNodeIndex nodeIdx,
                                        const unsigned *particleCounts,
                                        const std::uint8_t *groupCanMerge,
                                        const unsigned *nfCounts,
                                        unsigned bucketSize, bool useNFCounts)
    {
        unsigned level = 0;
        int siblingIdx = siblingIndexAndLevel(tree, numNodes, nodeIdx, level);

        // ---------------------------------------------------------------
        // merge criterion
        // ---------------------------------------------------------------
        if (!useNFCounts)
        {
            if (siblingIdx > 0)
            {
                const unsigned *g = particleCounts + nodeIdx - siblingIdx;
                std::size_t parentCount =
                    std::size_t(g[0]) + g[1] + g[2] + g[3] + g[4] + g[5] + g[6] + g[7];
                if (parentCount <= std::size_t(bucketSize))
                    return 0;
            }
        }
        else if (siblingIdx >= 0)
        {
            // groupCanMerge is precomputed once per sibling group
            TreeNodeIndex firstSibling = nodeIdx - siblingIdx;
            if (firstSibling + 8 <= numNodes && groupCanMerge[firstSibling])
            {
                return siblingIdx == 0 ? 1 : 0;
            }
        }

        // ---------------------------------------------------------------
        // split criterion, with level-jumping
        // ---------------------------------------------------------------
        const unsigned count =
            useNFCounts ? nfCounts[nodeIdx] : particleCounts[nodeIdx];

        if (!useNFCounts)
        {
            if (count > bucketSize * 512 && level + 3 < maxTreeLevel<KeyType>{})
                return 4096;
            if (count > bucketSize * 64 && level + 2 < maxTreeLevel<KeyType>{})
                return 512;
            if (count > bucketSize * 8 && level + 1 < maxTreeLevel<KeyType>{})
                return 64;
            if (count > bucketSize && level < maxTreeLevel<KeyType>{})
                return 8;
        }
        else
        {
            if (std::uint64_t(count) >
                    defaults::splitBufferRatio * std::uint64_t(bucketSize) * 262144 &&
                level + 3 < maxTreeLevel<KeyType>{})
                return 4096;

            if (std::uint64_t(count) >
                    defaults::splitBufferRatio * std::uint64_t(bucketSize) * 4096 &&
                level + 2 < maxTreeLevel<KeyType>{})
                return 512;

            if (std::uint64_t(count) >
                    defaults::splitBufferRatio * std::uint64_t(bucketSize) * 64 &&
                level + 1 < maxTreeLevel<KeyType>{})
                return 64;

            if (std::uint64_t(count) > defaults::splitBufferRatio * std::uint64_t(bucketSize) &&
                level < maxTreeLevel<KeyType>{})
                return 8;
        }

        return 1;
    }

    //! @brief write the new node(s) that opCode ==
    //! nodeOps[nodeIndex+1]-nodeOps[nodeIndex] transforms oldTree[nodeIndex] into
    template <class KeyType, class Offset>
    HOST_DEVICE_FUN void processNode(
        TreeNodeIndex nodeIndex, TreeNodeIndex numOldNodes, const KeyType *oldTree,
        const Offset *nodeOps, KeyType *newTree, const unsigned *oldCounts,
        const unsigned *oldNFCounts, unsigned *newCounts, unsigned *newNFCounts,
        std::uint8_t *nfDirty, const std::uint8_t *oldGroupCanMerge,
        std::uint8_t *newGroupCanMerge, std::uint8_t *groupDirty,
        bool useNFCounts)
    {
        const KeyType thisNode = oldTree[nodeIndex];
        const KeyType range = oldTree[nodeIndex + 1] - thisNode;
        const unsigned level = treeLevel(range);

        const TreeNodeIndex opCode = getNodeOp(nodeOps, nodeIndex);

        const TreeNodeIndex newNodeIndex = nodeOps[nodeIndex];

        // ---------------------------------------------------------
        // No output: sibling disappears due to merge
        // ---------------------------------------------------------
        if (opCode == 0)
            return;

        // ---------------------------------------------------------
        // One output
        // ---------------------------------------------------------
        if (opCode == 1)
        {
            newTree[newNodeIndex] = thisNode;

            if (useNFCounts)
            {
                const bool isMergeLeader =
                    nodeIndex + 1 < numOldNodes && getNodeOp(nodeOps, nodeIndex + 1) == 0;

                if (isMergeLeader)
                {
                    // New parent leaf.
                    nfDirty[newNodeIndex] = 1;

                    // This leaf may participate in a completely different
                    // sibling group at its new level.
                    groupDirty[newNodeIndex] = 1;
                }
                else
                {
                    // Exact same spatial leaf.
                    newCounts[newNodeIndex] = oldCounts[nodeIndex];
                    newNFCounts[newNodeIndex] = oldNFCounts[nodeIndex];
                    nfDirty[newNodeIndex] = 0;

                    // -----------------------------------------------------
                    // Can we also reuse groupCanMerge?
                    // -----------------------------------------------------

                    bool reusableGroup = false;

                    unsigned siblingLevel = 0;
                    const int siblingIdx =
                        siblingIndexAndLevel(oldTree, numOldNodes, nodeIndex, siblingLevel);

                    // Only firstSibling owns a meaningful groupCanMerge value.
                    if (siblingIdx == 0 && nodeIndex + 8 <= numOldNodes)
                    {
                        reusableGroup = true;

                        // The complete group must survive exactly unchanged.
                        for (int s = 0; s < 8; ++s)
                        {
                            if (getNodeOp(nodeOps, nodeIndex + s) != 1)
                            {
                                reusableGroup = false;
                                break;
                            }
                        }
                    }

                    if (reusableGroup)
                    {
                        newGroupCanMerge[newNodeIndex] = oldGroupCanMerge[nodeIndex];

                        groupDirty[newNodeIndex] = 0;
                    }
                    else
                    {
                        groupDirty[newNodeIndex] = 1;
                    }
                }
            }

            return;
        }

        // ---------------------------------------------------------
        // Split
        // ---------------------------------------------------------
        const unsigned levelDiff = (opCode == 8) ? 1 : log8ceil(unsigned(opCode));

        const KeyType newRange = nodeRange<KeyType>(level + levelDiff);

        for (TreeNodeIndex sibling = 0; sibling < opCode; ++sibling)
        {
            const TreeNodeIndex newIdx = newNodeIndex + sibling;

            newTree[newIdx] = thisNode + KeyType(sibling) * newRange;

            if (useNFCounts)
            {
                nfDirty[newIdx] = 1;
                groupDirty[newIdx] = 1;
            }
        }
    }

    //! @brief count sorted particle keys falling in [nodeStart, nodeEnd)
    template <class KeyType>
    HOST_DEVICE_FUN unsigned calculateNodeCount(KeyType nodeStart, KeyType nodeEnd,
                                                const KeyType *codesBegin,
                                                const KeyType *codesEnd,
                                                unsigned maxCount)
    {
        auto rangeStart = lowerBound(codesBegin, codesEnd, nodeStart);
        auto rangeEnd = lowerBound(codesBegin, codesEnd, nodeEnd);

        unsigned count = unsigned(rangeEnd - rangeStart);
        return cmin(count, maxCount);
    }

    // -------------------------------------------------------------------------
    // per-leaf particle counts (LeafCount split criterion)
    // -------------------------------------------------------------------------
    template <class KeyType>
    __global__ void computeNodeCountsKernel(const KeyType *tree, unsigned *counts,
                                            TreeNodeIndex numNodes,
                                            const KeyType *codesBegin,
                                            const KeyType *codesEnd,
                                            unsigned maxCount,
                                            RebalanceState *state)
    {
        if (state && state->converged)
            return;
        TreeNodeIndex tid = blockDim.x * blockIdx.x + threadIdx.x;
        if (tid < numNodes)
        {
            counts[tid] = calculateNodeCount(tree[tid], tree[tid + 1], codesBegin,
                                             codesEnd, maxCount);
        }
    }

    template <class KeyType>
    void computeNodeCountsGpu(execution::Gpu exec, const KeyType *tree,
                              unsigned *counts, TreeNodeIndex numNodes,
                              std::span<const KeyType> keys, unsigned maxCount,
                              bool /*useCountsAsGuess*/,
                              RebalanceState *state = nullptr)
    {
        constexpr unsigned nThreads = defaults::blockThreads;
        computeNodeCountsKernel<<<iceil(std::size_t(numNodes), nThreads), nThreads, 0,
                                  exec>>>(tree, counts, numNodes, keys.data(),
                                          keys.data() + keys.size(), maxCount, state);
    }

    // -------------------------------------------------------------------------
    // split/merge decision per node -> node transformation codes (nodeOps)
    // -------------------------------------------------------------------------

    template <class KeyType>
    __global__ void rebalanceDecisionKernel(
        const KeyType *tree, const unsigned *counts, const unsigned *nfCounts,
        const std::uint8_t *groupCanMerge, TreeNodeIndex numNodes,
        unsigned bucketSize, TreeNodeIndex *nodeOps, bool useNFCounts,
        RebalanceState *state)
    {
        TreeNodeIndex tid = blockDim.x * blockIdx.x + threadIdx.x;
        if (tid == 0)
            nodeOps[numNodes] = 0;
        if (tid < numNodes)
        {
            int decision = calculateNodeOp(tree, numNodes, tid, counts, groupCanMerge,
                                           nfCounts, bucketSize, useNFCounts);
            if (decision != 1)
                state->changed = 1;
            nodeOps[tid] = decision;
        }
    }

    __global__ void updateConvergenceKernel(RebalanceState *state)
    {
        if (blockIdx.x == 0 && threadIdx.x == 0)
        {
            if (!state->converged && state->changed == 0)
                state->converged = 1;
        }
    }

    /*! @brief compute per-node split/merge codes and their exclusive-scan offsets
     *
     * @return  the number of nodes the rebalanced tree would have, or -1 if the
     *          tree is already balanced (no node changed)
     */
    template <class KeyType>
    TreeNodeIndex computeNodeOpsGpu(
        execution::Gpu exec, const KeyType *tree, TreeNodeIndex numNodes,
        const unsigned *counts, const unsigned *nfCounts,
        const std::uint8_t *groupCanMerge, unsigned bucketSize,
        TreeNodeIndex *nodeOps,
        thrust::device_vector<std::uint8_t> &scanTempStorage, RebalanceState *state,
        cudaStream_t readbackStream, cudaEvent_t decisionDone, int *changed_h,
        TreeNodeIndex *newNumNodes_h, bool useNFCounts)
    {
        checkGpuErrors(
            cudaMemsetAsync(&state->changed, 0, sizeof(state->changed), exec));

        constexpr unsigned nThreads = defaults::wideBlockThreads;

        rebalanceDecisionKernel<<<iceil(numNodes, nThreads), nThreads, 0, exec>>>(
            tree, counts, nfCounts, groupCanMerge, numNodes, bucketSize, nodeOps,
            useNFCounts, state);

        updateConvergenceKernel<<<1, 1, 0, exec>>>(state);

        checkGpuErrors(cudaGetLastError());

        checkGpuErrors(cudaEventRecord(decisionDone, exec));

        checkGpuErrors(cudaStreamWaitEvent(readbackStream, decisionDone, 0));

        // Tiny DtoH copy on auxiliary stream.
        checkGpuErrors(cudaMemcpyAsync(changed_h, &state->changed, sizeof(int),
                                       cudaMemcpyDeviceToHost, readbackStream));

        // ------------------------------------------------------------
        // Speculatively scan nodeOps on exec while changed is copied
        // back to the CPU.
        // ------------------------------------------------------------

        const std::size_t nodeOpsSize = std::size_t(numNodes) + 1;

        std::size_t requiredBytes = 0;

        cub::DeviceScan::ExclusiveSum(nullptr, requiredBytes, nodeOps, nodeOps,
                                      nodeOpsSize, exec);

        if (requiredBytes > scanTempStorage.size())
            resizeWithHeadroom(scanTempStorage, requiredBytes);

        std::size_t tempStorageBytes = scanTempStorage.size();

        cub::DeviceScan::ExclusiveSum(rawPtr(scanTempStorage), tempStorageBytes,
                                      nodeOps, nodeOps, nodeOpsSize, exec);

        // Wait for the independent "changed" readback.
        checkGpuErrors(cudaStreamSynchronize(readbackStream));

        if (*changed_h == 0)
        {
            // The speculative scan may still be running.
            checkGpuErrors(cudaStreamSynchronize(exec));
            return -1;
        }

        // Only changing iterations need newNumNodes.
        checkGpuErrors(cudaMemcpyAsync(newNumNodes_h, nodeOps + numNodes,
                                       sizeof(TreeNodeIndex), cudaMemcpyDeviceToHost,
                                       exec));

        checkGpuErrors(cudaStreamSynchronize(exec));

        return *newNumNodes_h;
    }

    // -------------------------------------------------------------------------
    // materialize the rebalanced tree from the node transformation codes
    // -------------------------------------------------------------------------
    template <class KeyType>
    __global__ void processNodes(
        const KeyType *oldTree, const TreeNodeIndex *nodeOps,
        TreeNodeIndex numOldNodes, KeyType *newTree, TreeNodeIndex newNumNodes,
        const unsigned *oldCounts, const unsigned *oldNFCounts, unsigned *newCounts,
        unsigned *newNFCounts, std::uint8_t *nfDirty,
        const std::uint8_t *oldGroupCanMerge, std::uint8_t *newGroupCanMerge,
        std::uint8_t *groupDirty, bool useNFCounts, RebalanceState *state)
    {
        if (state && state->converged)
            return;

        const TreeNodeIndex tid = blockDim.x * blockIdx.x + threadIdx.x;

        if (tid < numOldNodes)
        {
            processNode(tid, numOldNodes, oldTree, nodeOps, newTree, oldCounts,
                        oldNFCounts, newCounts, newNFCounts, nfDirty, oldGroupCanMerge,
                        newGroupCanMerge, groupDirty, useNFCounts);

            if (tid == numOldNodes - 1)
                newTree[newNumNodes] = nodeRange<KeyType>(0);
        }
    }

    // Note: this is only ever called right after computeNodeOpsGpu returned
    // newNumNodes >= 0, i.e. the caller already knows the tree changed -- so
    // there is nothing left to detect here, no host readback needed.
    template <class KeyType>
    void rebalanceTreeGpu(execution::Gpu exec, const KeyType *tree,
                          TreeNodeIndex numNodes, TreeNodeIndex newNumNodes,
                          const TreeNodeIndex *nodeOps, KeyType *newTree,
                          const unsigned *oldCounts, const unsigned *oldNFCounts,
                          unsigned *newCounts, unsigned *newNFCounts,
                          std::uint8_t *nfDirty,
                          const std::uint8_t *oldGroupCanMerge,
                          std::uint8_t *newGroupCanMerge, std::uint8_t *groupDirty,
                          bool useNFCounts, RebalanceState *state)
    {
        constexpr unsigned nThreads = defaults::wideBlockThreads;

        processNodes<<<iceil(numNodes, nThreads), nThreads, 0, exec>>>(
            tree, nodeOps, numNodes, newTree, newNumNodes, oldCounts, oldNFCounts,
            newCounts, newNFCounts, nfDirty, oldGroupCanMerge, newGroupCanMerge,
            groupDirty, useNFCounts, state);
    }

    // -------------------------------------------------------------------------
    // near-field (own + up to 26 same-level neighbor leaves) interaction counts
    // and per-sibling-group merge decision, computed cooperatively by groups of
    // 8 threads (one thread per direction-octant, one tile per node/group).
    // -------------------------------------------------------------------------
    template <class KeyType, class Tile>
    __device__ unsigned long long computeNFCooperative(
        Tile tile, const KeyType *particleKeys, std::size_t numParticles,
        KeyType nodeStart, unsigned level, bool hilbert, unsigned *outOwnCount)
    {
        const IBox ibox = sfcIBox<KeyType>(nodeStart, level, hilbert);
        const KeyType range = nodeRange<KeyType>(level);

        unsigned long long populationSum = 0;
        unsigned long long centerCount = 0;

        // 27 = 3x3x3 same-level neighborhood, including the node itself
        for (int cell = tile.thread_rank(); cell < 27; cell += tile.size())
        {
            int dx = cell % 3 - 1;
            int dy = (cell / 3) % 3 - 1;
            int dz = cell / 9 - 1;

            KeyType cellKey =
                (cell == 13) ? nodeStart
                             : sfcNeighbor<KeyType>(ibox, level, dx, dy, dz, hilbert);

            std::size_t first = std::size_t(
                lowerBound(particleKeys, particleKeys + numParticles, cellKey) -
                particleKeys);
            std::size_t last = std::size_t(
                lowerBound(particleKeys, particleKeys + numParticles, cellKey + range) -
                particleKeys);

            unsigned long long population =
                static_cast<unsigned long long>(last - first);
            populationSum += population;
            if (cell == 13)
                centerCount = population;
        }

        populationSum += tile.shfl_down(populationSum, 4);
        populationSum += tile.shfl_down(populationSum, 2);
        populationSum += tile.shfl_down(populationSum, 1);

        centerCount += tile.shfl_down(centerCount, 4);
        centerCount += tile.shfl_down(centerCount, 2);
        centerCount += tile.shfl_down(centerCount, 1);

        populationSum = tile.shfl(populationSum, 0);
        centerCount = tile.shfl(centerCount, 0);

        // own-leaf particle count -- identical to what computeNodeCountsGpu would
        // compute for this same leaf, so callers that need it (N_d) can just take
        // it here instead of a separate lowerBound pass over all leaves.
        if (outOwnCount && tile.thread_rank() == 0)
            *outOwnCount = unsigned(
                cmin(centerCount, static_cast<unsigned long long>(0xffffffffu)));

        return centerCount * populationSum;
    }

    template <class KeyType>
    __global__ void computeGroupCanMergeKernel(
        const KeyType *tree, const KeyType *particleKeys, std::size_t numParticles,
        const TreeNodeIndex *dirtyGroupIndices, const TreeNodeIndex *numDirtyGroups,
        unsigned bucketSize, std::uint8_t *groupCanMerge, bool hilbert,
        RebalanceState *state)
    {
        if (state && state->converged)
            return;
        constexpr unsigned tileSize = defaults::nearFieldGroupSize;

        auto tile = cg::tiled_partition<tileSize>(cg::this_thread_block());

        const unsigned tilesPerBlock = blockDim.x / tileSize;

        const TreeNodeIndex tileIdx =
            blockIdx.x * tilesPerBlock + threadIdx.x / tileSize;

        const TreeNodeIndex totalTiles = gridDim.x * tilesPerBlock;

        const TreeNodeIndex nGroups = *numDirtyGroups;

        for (TreeNodeIndex groupIdx = tileIdx; groupIdx < nGroups;
             groupIdx += totalTiles)
        {
            const TreeNodeIndex firstSibling = dirtyGroupIndices[groupIdx];

            const unsigned siblingLevel =
                treeLevel(tree[firstSibling + 1] - tree[firstSibling]);

            const unsigned long long parentNF = computeNFCooperative(
                tile, particleKeys, numParticles, tree[firstSibling], siblingLevel - 1,
                hilbert, nullptr);

            if (tile.thread_rank() == 0)
            {
                groupCanMerge[firstSibling] =
                    parentNF <=
                    defaults::mergeBufferRatio * static_cast<unsigned long long>(bucketSize);
            }
        }
    }

    template <class KeyType>
    __global__ void computeNFCountsSelected(
        const KeyType *tree, const KeyType *particleKeys, std::size_t numParticles,
        const TreeNodeIndex *dirtyNFIndices, const TreeNodeIndex *numDirtyNFNodes,
        unsigned *nfCounts, unsigned *counts, bool hilbert, RebalanceState *state)
    {
        if (state->converged)
            return;
        constexpr unsigned tileSize = defaults::nearFieldGroupSize;

        auto tile = cg::tiled_partition<tileSize>(cg::this_thread_block());

        const unsigned tilesPerBlock = blockDim.x / tileSize;

        const TreeNodeIndex tileIdx =
            blockIdx.x * tilesPerBlock + threadIdx.x / tileSize;

        const TreeNodeIndex totalTiles = gridDim.x * tilesPerBlock;

        const TreeNodeIndex nDirty = *numDirtyNFNodes;

        for (TreeNodeIndex dirtyIdx = tileIdx; dirtyIdx < nDirty;
             dirtyIdx += totalTiles)
        {
            const TreeNodeIndex nodeIdx = dirtyNFIndices[dirtyIdx];

            const KeyType nodeStart = tree[nodeIdx];

            const unsigned level = treeLevel(tree[nodeIdx + 1] - nodeStart);

            const unsigned long long nf =
                computeNFCooperative(tile, particleKeys, numParticles, nodeStart, level,
                                     hilbert, counts + nodeIdx);

            if (tile.thread_rank() == 0)
            {
                nfCounts[nodeIdx] =
                    unsigned(cmin(nf, static_cast<unsigned long long>(0xffffffffu)));
            }
        }
    }

    template <class KeyType>
    __global__ void computeNFCountsAll(const KeyType *tree,
                                       const KeyType *particleKeys,
                                       std::size_t numParticles,
                                       TreeNodeIndex numNodes, unsigned *nfCounts,
                                       unsigned *counts, bool hilbert,
                                       RebalanceState *state)
    {
        if (state && state->converged)
            return;
        constexpr unsigned tileSize = defaults::nearFieldGroupSize;

        auto tile = cg::tiled_partition<tileSize>(cg::this_thread_block());

        const unsigned tilesPerBlock = blockDim.x / tileSize;

        const TreeNodeIndex nodeIdx =
            blockIdx.x * tilesPerBlock + threadIdx.x / tileSize;

        if (nodeIdx >= numNodes)
            return;

        const KeyType nodeStart = tree[nodeIdx];

        const unsigned level = treeLevel(tree[nodeIdx + 1] - nodeStart);

        const unsigned long long nf =
            computeNFCooperative(tile, particleKeys, numParticles, nodeStart, level,
                                 hilbert, counts + nodeIdx);

        if (tile.thread_rank() == 0)
        {
            nfCounts[nodeIdx] =
                unsigned(cmin(nf, static_cast<unsigned long long>(0xffffffffu)));
        }
    }

    /*! @brief compute per-leaf NF-counts and per-sibling-group merge decisions
     *
     * The NF-count kernel (depends on tree/particleKeys/counts) and the merge-
     * decision kernel have no data dependency on each other, so they run
     * concurrently on two auxiliary streams instead of both serializing on
     * @p exec; @p exec only waits (via events) for both to finish before
     * returning.
     */
    void computeNFCountsAndGroupCanMergeGpu(
        execution::Gpu exec, const KeyType *tree, const KeyType *particleKeys,
        std::size_t numParticles, TreeNodeIndex numNodes, unsigned bucketSize,
        unsigned *nfCounts, unsigned *counts, const std::uint8_t *nfDirty,
        std::uint8_t *groupCanMerge, const std::uint8_t *groupDirty,

        // NF compaction
        thrust::device_vector<TreeNodeIndex> &dirtyNFIndices,
        thrust::device_vector<TreeNodeIndex> &numDirtyNFNodes,
        thrust::device_vector<std::uint8_t> &nfSelectTempStorage,

        // group compaction
        thrust::device_vector<TreeNodeIndex> &dirtyGroupIndices,
        thrust::device_vector<TreeNodeIndex> &numDirtyGroups,
        thrust::device_vector<std::uint8_t> &groupSelectTempStorage,

        cudaStream_t auxStream1, cudaStream_t auxStream2, cudaEvent_t inputsReady,
        cudaEvent_t nfDone, cudaEvent_t mergeDone, bool hilbert,
        RebalanceState *state = nullptr)
    {
        constexpr unsigned fullNFThreads = defaults::blockThreads;
        constexpr unsigned sparseNFThreads = defaults::wideBlockThreads;
        constexpr unsigned mergeThreads = defaults::mergeBlockThreads;

        constexpr unsigned tileSize = defaults::nearFieldGroupSize;

        constexpr unsigned maxSparseBlocks = defaults::maxSparseNearFieldBlocks;

        cudaEventRecord(inputsReady, exec);

        cudaStreamWaitEvent(auxStream1, inputsReady, 0);
        cudaStreamWaitEvent(auxStream2, inputsReady, 0);

        // -------------------------------------------------------------
        // NF path
        // -------------------------------------------------------------

        if (nfDirty == nullptr)
        {
            // Full refresh: every node must be recomputed.
            computeNFCountsAll<<<iceil(numNodes, fullNFThreads / tileSize),
                                 fullNFThreads, 0, auxStream1>>>(
                tree, particleKeys, numParticles, numNodes, nfCounts, counts, hilbert,
                state);

            checkGpuErrors(cudaGetLastError());
        }
        else
        {
            resizeWithHeadroom(dirtyNFIndices, numNodes);

            if (numDirtyNFNodes.empty())
                numDirtyNFNodes.resize(1);

            compactDirtyNFNodesGpu(auxStream1, numNodes, nfDirty,
                                   rawPtr(dirtyNFIndices), rawPtr(numDirtyNFNodes),
                                   nfSelectTempStorage);

            const unsigned nfBlocks = std::min<unsigned>(
                iceil(numNodes, sparseNFThreads / tileSize), maxSparseBlocks);

            computeNFCountsSelected<<<nfBlocks, sparseNFThreads, 0, auxStream1>>>(
                tree, particleKeys, numParticles, rawPtr(dirtyNFIndices),
                rawPtr(numDirtyNFNodes), nfCounts, counts, hilbert, state);

            checkGpuErrors(cudaGetLastError());
        }
        // -------------------------------------------------------------
        // Merge path
        // -------------------------------------------------------------

        const TreeNodeIndex maxPossibleGroups = numNodes / 8;

        if (maxPossibleGroups > 0)
        {
            resizeWithHeadroom(dirtyGroupIndices, maxPossibleGroups);

            if (numDirtyGroups.empty())
                numDirtyGroups.resize(1);

            compactDirtyGroupsGpu(auxStream2, tree, numNodes, groupDirty,
                                  rawPtr(dirtyGroupIndices), rawPtr(numDirtyGroups),
                                  groupSelectTempStorage);

            const unsigned mergeBlocks = std::min<unsigned>(
                iceil(maxPossibleGroups, mergeThreads / tileSize), maxSparseBlocks);

            computeGroupCanMergeKernel<<<mergeBlocks, mergeThreads, 0, auxStream2>>>(
                tree, particleKeys, numParticles, rawPtr(dirtyGroupIndices),
                rawPtr(numDirtyGroups), bucketSize, groupCanMerge, hilbert, state);

            checkGpuErrors(cudaGetLastError());
        }

        cudaEventRecord(nfDone, auxStream1);
        cudaEventRecord(mergeDone, auxStream2);

        cudaStreamWaitEvent(exec, nfDone, 0);
        cudaStreamWaitEvent(exec, mergeDone, 0);
    }

    // -------------------------------------------------------------------------
    // top-level: one rebalance iteration (split/merge decision -> new tree ->
    // refresh counts for the new tree)
    // -------------------------------------------------------------------------
    template <class KeyType>
    bool updateOctreeGpu(
        execution::Gpu exec, std::span<const KeyType> keys, unsigned bucketSize,

        thrust::device_vector<KeyType> &tree,
        thrust::device_vector<unsigned> &counts,
        thrust::device_vector<unsigned> &nfCounts,

        thrust::device_vector<KeyType> &tmpTree,
        thrust::device_vector<TreeNodeIndex> &workArray,

        thrust::device_vector<unsigned> &tmpCounts,
        thrust::device_vector<unsigned> &tmpNFCounts,
        thrust::device_vector<std::uint8_t> &nfDirty,

        thrust::device_vector<std::uint8_t> &groupCanMerge,
        thrust::device_vector<std::uint8_t> &tmpGroupCanMerge,
        thrust::device_vector<std::uint8_t> &groupDirty,

        thrust::device_vector<TreeNodeIndex> &dirtyNFIndices,
        thrust::device_vector<TreeNodeIndex> &numDirtyNFNodes,
        thrust::device_vector<std::uint8_t> &nfSelectTempStorage,

        thrust::device_vector<TreeNodeIndex> &dirtyGroupIndices,
        thrust::device_vector<TreeNodeIndex> &numDirtyGroups,
        thrust::device_vector<std::uint8_t> &groupSelectTempStorage,

        thrust::device_vector<std::uint8_t> &nodeOpsScanTempStorage,

        RebalanceState *rebalanceState,

        cudaStream_t auxStream1, cudaStream_t auxStream2,
        cudaStream_t readbackStream,

        cudaEvent_t inputsReady, cudaEvent_t nfDone, cudaEvent_t mergeDone,
        cudaEvent_t decisionDone,

        int *changed_h, TreeNodeIndex *newNumNodes_h,

        bool useNfCounts = false,
        unsigned maxCount = std::numeric_limits<unsigned>::max(),
        bool hilbert = false)
    {
        resizeWithHeadroom(workArray, tree.size());

        TreeNodeIndex newNumNodes = computeNodeOpsGpu(
            exec, rawPtr(tree), TreeNodeIndex(nNodes(tree)), rawPtr(counts),
            rawPtr(nfCounts), rawPtr(groupCanMerge), bucketSize, rawPtr(workArray),
            nodeOpsScanTempStorage, rebalanceState, readbackStream, decisionDone,
            changed_h, newNumNodes_h, useNfCounts);

        if (newNumNodes < 0)
            return true; // no changes, tree is already balanced

        const TreeNodeIndex oldNumNodes = TreeNodeIndex(nNodes(tree));

        resizeWithHeadroom(tmpTree, newNumNodes + 1);

        if (useNfCounts)
        {
            resizeWithHeadroom(tmpCounts, newNumNodes);
            resizeWithHeadroom(tmpNFCounts, newNumNodes);
            resizeWithHeadroom(nfDirty, newNumNodes);

            resizeWithHeadroom(tmpGroupCanMerge, newNumNodes);
            resizeWithHeadroom(groupDirty, newNumNodes);
        }

        rebalanceTreeGpu(exec, rawPtr(tree), oldNumNodes, newNumNodes,
                         rawPtr(workArray), rawPtr(tmpTree), rawPtr(counts),
                         rawPtr(nfCounts), useNfCounts ? rawPtr(tmpCounts) : nullptr,
                         useNfCounts ? rawPtr(tmpNFCounts) : nullptr,
                         useNfCounts ? rawPtr(nfDirty) : nullptr,
                         useNfCounts ? rawPtr(groupCanMerge) : nullptr,
                         useNfCounts ? rawPtr(tmpGroupCanMerge) : nullptr,
                         useNfCounts ? rawPtr(groupDirty) : nullptr, useNfCounts,
                         rebalanceState);

        tree.swap(tmpTree);

        if (useNfCounts)
        {
            counts.swap(tmpCounts);
            nfCounts.swap(tmpNFCounts);

            groupCanMerge.swap(tmpGroupCanMerge);
        }
        else
        {
            resizeWithHeadroom(counts, nNodes(tree));
        }

        if (useNfCounts)
        {
            const TreeNodeIndex numNodes = TreeNodeIndex(nNodes(tree));

            computeNFCountsAndGroupCanMergeGpu(
                exec, rawPtr(tree), keys.data(), keys.size(), numNodes, bucketSize,
                rawPtr(nfCounts), rawPtr(counts), rawPtr(nfDirty),
                rawPtr(groupCanMerge), rawPtr(groupDirty), dirtyNFIndices,
                numDirtyNFNodes, nfSelectTempStorage, dirtyGroupIndices, numDirtyGroups,
                groupSelectTempStorage, auxStream1, auxStream2, inputsReady, nfDone,
                mergeDone, hilbert, rebalanceState);
        }
        else
        {
            computeNodeCountsGpu(exec, rawPtr(tree), rawPtr(counts),
                                 TreeNodeIndex(nNodes(tree)), keys, maxCount, false,
                                 rebalanceState);
        }

        // reached only when computeNodeOpsGpu reported a change above, so this
        // iteration is by definition never converged.
        return false;
    }

    // Fixed-capacity update path
    inline std::size_t graphNodeOpsScanBytes(TreeNodeIndex leafCapacity)
    {
        std::size_t bytes = 0;
        std::int64_t *offsets = nullptr;
        checkGpuErrors(cub::DeviceScan::ExclusiveSum(nullptr, bytes, offsets, offsets,
                                                     std::size_t(leafCapacity) + 1));
        return bytes;
    }

    template <class KeyType>
    __global__ void graphRefreshLeafCountsKernel(
        const KeyType *treeA, const KeyType *treeB, const KeyType *particleKeys,
        std::size_t numParticles, unsigned *countsA, unsigned *countsB,
        const RebalanceState *state, unsigned maxCount)
    {
        if (state->converged)
            return;

        const KeyType *tree = state->activeBuffer ? treeB : treeA;

        unsigned *counts = state->activeBuffer ? countsB : countsA;

        const TreeNodeIndex nodeIdx = blockIdx.x * blockDim.x + threadIdx.x;

        const TreeNodeIndex numNodes = state->numLeaves;

        if (nodeIdx >= numNodes)
            return;

        counts[nodeIdx] =
            calculateNodeCount(tree[nodeIdx], tree[nodeIdx + 1], particleKeys,
                               particleKeys + numParticles, maxCount);
    }

    template <class KeyType>
    __global__ void graphRefreshOwnNFKernel(
        const KeyType *treeA, const KeyType *treeB, const KeyType *particleKeys,
        std::size_t numParticles, unsigned *countsA, unsigned *countsB,
        unsigned *nfCountsA, unsigned *nfCountsB, const std::uint8_t *nfDirty,
        const RebalanceState *state, bool hilbert)
    {
        if (state->converged)
            return;

        const KeyType *tree = state->activeBuffer ? treeB : treeA;

        unsigned *counts = state->activeBuffer ? countsB : countsA;

        unsigned *nfCounts = state->activeBuffer ? nfCountsB : nfCountsA;

        constexpr unsigned tileSize = defaults::nearFieldGroupSize;

        auto tile = cg::tiled_partition<tileSize>(cg::this_thread_block());

        const TreeNodeIndex nodeIdx =
            blockIdx.x * (blockDim.x / tileSize) + threadIdx.x / tileSize;

        const TreeNodeIndex numNodes = state->numLeaves;

        if (nodeIdx >= numNodes)
            return;

        if (nfDirty && !nfDirty[nodeIdx])
            return;

        const KeyType nodeStart = tree[nodeIdx];

        const unsigned level = treeLevel(tree[nodeIdx + 1] - nodeStart);

        const unsigned long long nf =
            computeNFCooperative(tile, particleKeys, numParticles, nodeStart, level,
                                 hilbert, counts + nodeIdx);

        if (tile.thread_rank() == 0)
        {
            nfCounts[nodeIdx] =
                unsigned(cmin(nf, static_cast<unsigned long long>(0xffffffffu)));
        }
    }

    template <class KeyType>
    __global__ void graphRefreshParentNFKernel(
        const KeyType *treeA, const KeyType *treeB, const KeyType *particleKeys,
        std::size_t numParticles, unsigned bucketSize, std::uint8_t *groupA,
        std::uint8_t *groupB, const std::uint8_t *groupDirty,
        const RebalanceState *state, bool hilbert)
    {
        if (state->converged)
            return;

        const KeyType *tree = state->activeBuffer ? treeB : treeA;

        std::uint8_t *groupCanMerge = state->activeBuffer ? groupB : groupA;

        constexpr unsigned tileSize = defaults::nearFieldGroupSize;

        auto tile = cg::tiled_partition<tileSize>(cg::this_thread_block());

        const TreeNodeIndex nodeIdx =
            blockIdx.x * (blockDim.x / tileSize) + threadIdx.x / tileSize;

        const TreeNodeIndex numNodes = state->numLeaves;

        if (nodeIdx >= numNodes)
            return;

        if (!IsDirtyGroupLeader<KeyType>{tree, groupDirty, numNodes}(nodeIdx))
            return;

        const KeyType nodeStart = tree[nodeIdx];

        const unsigned level = treeLevel(tree[nodeIdx + 1] - nodeStart);

        const unsigned long long parentNF = computeNFCooperative(
            tile, particleKeys, numParticles, nodeStart, level - 1, hilbert, nullptr);

        if (tile.thread_rank() == 0)
        {
            groupCanMerge[nodeIdx] =
                parentNF <=
                defaults::mergeBufferRatio * static_cast<unsigned long long>(bucketSize);
        }
    }

    template <class KeyType>
    void refreshGraphCountsGpu(
        execution::Gpu exec, std::span<const KeyType> keys, unsigned bucketSize,
        TreeNodeIndex leafCapacity, const KeyType *treeA, const KeyType *treeB,
        unsigned *countsA, unsigned *countsB, unsigned *nfCountsA,
        unsigned *nfCountsB, std::uint8_t *groupA, std::uint8_t *groupB,
        RebalanceState *state, cudaStream_t nfStream, cudaStream_t parentStream,
        cudaEvent_t inputsReady, cudaEvent_t nfDone, cudaEvent_t parentDone,
        bool useNFCounts = false,
        unsigned maxCount = std::numeric_limits<unsigned>::max(),
        bool hilbert = false, const std::uint8_t *nfDirty = nullptr,
        const std::uint8_t *groupDirty = nullptr)
    {
        {
            constexpr unsigned leafThreads = defaults::blockThreads;
            constexpr unsigned nfThreads = defaults::blockThreads;
            constexpr unsigned parentThreads = defaults::mergeBlockThreads;

            constexpr unsigned tileSize = defaults::nearFieldGroupSize;

            if (!useNFCounts)
            {
                graphRefreshLeafCountsKernel<<<iceil(leafCapacity, leafThreads),
                                               leafThreads, 0, exec>>>(
                    treeA, treeB, keys.data(), keys.size(), countsA, countsB, state,
                    maxCount);

                return;
            }

            // Everything previously submitted to exec must be visible to
            // both NF streams before they start reading the new tree/state.
            checkGpuErrors(cudaEventRecord(inputsReady, exec));

            checkGpuErrors(cudaStreamWaitEvent(nfStream, inputsReady, 0));

            checkGpuErrors(cudaStreamWaitEvent(parentStream, inputsReady, 0));

            // -------------------------------------------------------------
            // Own NF
            // -------------------------------------------------------------

            graphRefreshOwnNFKernel<<<iceil(leafCapacity, nfThreads / tileSize),
                                      nfThreads, 0, nfStream>>>(
                treeA, treeB, keys.data(), keys.size(), countsA, countsB, nfCountsA,
                nfCountsB, nfDirty, state, hilbert);

            // -------------------------------------------------------------
            // Parent NF / groupCanMerge
            // -------------------------------------------------------------

            graphRefreshParentNFKernel<<<iceil(leafCapacity, parentThreads / tileSize),
                                         parentThreads, 0, parentStream>>>(
                treeA, treeB, keys.data(), keys.size(), bucketSize, groupA, groupB,
                groupDirty, state, hilbert);

            checkGpuErrors(cudaEventRecord(nfDone, nfStream));
            checkGpuErrors(cudaEventRecord(parentDone, parentStream));

            // The next graph stage runs on exec and consumes both NF results.
            checkGpuErrors(cudaStreamWaitEvent(exec, nfDone, 0));
            checkGpuErrors(cudaStreamWaitEvent(exec, parentDone, 0));
        }
    }

    template <class KeyType>
    __global__ void graphRebalanceDecisionKernel(
        const KeyType *treeA, const KeyType *treeB, const unsigned *countsA,
        const unsigned *countsB, const unsigned *nfCountsA,
        const unsigned *nfCountsB, const std::uint8_t *groupA,
        const std::uint8_t *groupB, TreeNodeIndex leafCapacity, unsigned bucketSize,
        std::int64_t *nodeOps, bool useNFCounts, RebalanceState *state)
    {
        const std::size_t tid = std::size_t(blockDim.x) * blockIdx.x + threadIdx.x;

        if (tid > std::size_t(leafCapacity))
            return;

        int decision = 0;

        if (!state->converged && !state->needsResize &&
            tid < std::size_t(state->numLeaves))
        {
            const KeyType *tree = state->activeBuffer ? treeB : treeA;
            const unsigned *counts = state->activeBuffer ? countsB : countsA;
            const unsigned *nfCounts = state->activeBuffer ? nfCountsB : nfCountsA;
            const std::uint8_t *groupCanMerge = state->activeBuffer ? groupB : groupA;

            decision =
                calculateNodeOp(tree, state->numLeaves, TreeNodeIndex(tid), counts,
                                groupCanMerge, nfCounts, bucketSize, useNFCounts);

            if (decision != 1)
                atomicExch(&state->changed, 1);
        }
        // Every inactive entry, including the sentinel, participates as zero.
        nodeOps[tid] = decision;
    }

    __global__ void graphCheckCapacityKernel(const std::int64_t *nodeOps,
                                             TreeNodeIndex leafCapacity,
                                             RebalanceState *state)
    {
        if (state->converged)
            return;
        if (state->needsResize || !state->changed)
        {
            state->converged = 1;
            return;
        }
        const std::int64_t proposedLeaves = nodeOps[leafCapacity];
        if (proposedLeaves > leafCapacity)
        {
            // Reject the complete proposal: the old tree and its freshly
            // computed counts remain valid, with no partially applied splits.
            state->needsResize = 1;
            state->converged = 1;
            return;
        }
        state->newNumLeaves = TreeNodeIndex(proposedLeaves);
    }

    template <class KeyType>
    __global__ void graphProcessNodesKernel(
        KeyType *treeA, const std::int64_t *nodeOps, KeyType *treeB,
        unsigned *countsA, unsigned *nfCountsA, unsigned *countsB,
        unsigned *nfCountsB, std::uint8_t *nfDirty, std::uint8_t *groupA,
        std::uint8_t *groupB, std::uint8_t *groupDirty, bool useNFCounts,
        const RebalanceState *state)
    {
        if (state->converged)
            return;

        const TreeNodeIndex tid = blockDim.x * blockIdx.x + threadIdx.x;

        if (tid >= state->numLeaves)
            return;

        const KeyType *tree = state->activeBuffer ? treeB : treeA;
        KeyType *tmpTree = state->activeBuffer ? treeA : treeB;
        const unsigned *counts = state->activeBuffer ? countsB : countsA;
        const unsigned *nfCounts = state->activeBuffer ? nfCountsB : nfCountsA;
        unsigned *tmpCounts = state->activeBuffer ? countsA : countsB;
        unsigned *tmpNFCounts = state->activeBuffer ? nfCountsA : nfCountsB;
        const std::uint8_t *groupCanMerge = state->activeBuffer ? groupB : groupA;
        std::uint8_t *tmpGroupCanMerge = state->activeBuffer ? groupA : groupB;

        processNode(tid, state->numLeaves, tree, nodeOps, tmpTree, counts, nfCounts,
                    tmpCounts, tmpNFCounts, nfDirty, groupCanMerge, tmpGroupCanMerge,
                    groupDirty, useNFCounts);

        if (tid == 0)
            tmpTree[state->newNumLeaves] = nodeRange<KeyType>(0);
    }

    __global__ void graphCommitNodesKernel(RebalanceState *state)
    {
        if (state->converged)
            return;
        state->numLeaves = state->newNumLeaves;
        state->activeBuffer ^= 1;
    }

    template <class KeyType>
    void updateOctreeGraphGpu(
        execution::Gpu exec, std::span<const KeyType> keys, unsigned bucketSize,
        TreeNodeIndex leafCapacity, KeyType *tree, unsigned *counts,
        unsigned *nfCounts, KeyType *tmpTree, unsigned *tmpCounts,
        unsigned *tmpNFCounts, std::uint8_t *nfDirty, std::uint8_t *groupCanMerge,
        std::uint8_t *tmpGroupCanMerge, std::uint8_t *groupDirty,
        std::int64_t *nodeOps, void *scanTempStorage, std::size_t scanTempBytes,
        RebalanceState *state, cudaStream_t nfStream, cudaStream_t parentStream,
        cudaEvent_t inputsReady, cudaEvent_t nfDone, cudaEvent_t parentDone,
        bool useNFCounts = false,
        unsigned maxCount = std::numeric_limits<unsigned>::max(),
        bool hilbert = false)
    {
        constexpr unsigned nThreads = defaults::blockThreads;
        const auto blocks = iceil(std::size_t(leafCapacity) + 1, nThreads);

        checkGpuErrors(
            cudaMemsetAsync(&state->changed, 0, sizeof(state->changed), exec));

        graphRebalanceDecisionKernel<<<blocks, nThreads, 0, exec>>>(
            tree, tmpTree, counts, tmpCounts, nfCounts, tmpNFCounts, groupCanMerge,
            tmpGroupCanMerge, leafCapacity, bucketSize, nodeOps, useNFCounts, state);

        checkGpuErrors(cub::DeviceScan::ExclusiveSum(
            scanTempStorage, scanTempBytes, nodeOps, nodeOps,
            std::size_t(leafCapacity) + 1, exec));

        graphCheckCapacityKernel<<<1, 1, 0, exec>>>(nodeOps, leafCapacity, state);

        graphProcessNodesKernel<<<blocks, nThreads, 0, exec>>>(
            tree, nodeOps, tmpTree, counts, nfCounts, tmpCounts, tmpNFCounts, nfDirty,
            groupCanMerge, tmpGroupCanMerge, groupDirty, useNFCounts, state);

        graphCommitNodesKernel<<<1, 1, 0, exec>>>(state);

        refreshGraphCountsGpu(exec, keys, bucketSize, leafCapacity, tree, tmpTree,
                              counts, tmpCounts, nfCounts, tmpNFCounts, groupCanMerge,
                              tmpGroupCanMerge, state,

                              nfStream, parentStream, inputsReady, nfDone, parentDone,

                              useNFCounts, maxCount, hilbert, nfDirty, groupDirty);

#ifndef NDEBUG
        checkGpuErrors(cudaGetLastError());
#endif
    }

} // namespace adaptive_octree::detail
