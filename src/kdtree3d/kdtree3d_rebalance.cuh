#pragma once

#include <cub/device/device_scan.cuh>

#include <cstdint>
#include <span>

#include "binary_node.cuh"
#include "helpers.cuh"

namespace adaptive_octree::detail::kdtree3d
{
    __global__ void resetRebalanceStateKernel(RebalanceState *state,
                                              const KeyType *keys, std::size_t numSlots)
    {
        state->changed = 0;
        state->converged = 0;
        state->numActiveParticles = numSlots ? unsigned(lowerBound(keys, keys + numSlots,
                                                                  KeyType(maxKey)) - keys) : 0;
    }

    inline void resetRebalanceStateGpu(cudaStream_t stream, RebalanceState *state,
                                       std::span<const KeyType> keys)
    {
        resetRebalanceStateKernel<<<1, 1, 0, stream>>>(state, keys.data(), keys.size());
    }

    __global__ void binaryLeafCountsKernel(
        const KeyType *treeA, const KeyType *treeB, const KeyType *keys,
        unsigned *countsA, unsigned *countsB, const RebalanceState *state)
    {
        const TreeNodeIndex node = blockIdx.x * blockDim.x + threadIdx.x;
        if (state->converged || node >= state->numLeaves) return;
        const KeyType *tree = state->activeBuffer ? treeB : treeA;
        unsigned *counts = state->activeBuffer ? countsB : countsA;
        const unsigned numParticles = state->numActiveParticles;
        counts[node] = numParticles ? unsigned(lowerBound(keys, keys + numParticles, tree[node + 1]) -
                                               lowerBound(keys, keys + numParticles, tree[node])) : 0;
    }

    inline void refreshBinaryCountsGpu(
        execution::Gpu exec, std::span<const KeyType> keys, TreeNodeIndex leafCapacity,
        const KeyType *treeA, const KeyType *treeB, unsigned *countsA,
        unsigned *countsB, RebalanceState *state)
    {
        constexpr unsigned threads = defaults::blockThreads;
        binaryLeafCountsKernel<<<iceil(leafCapacity, threads), threads, 0, exec>>>(
            treeA, treeB, keys.data(), countsA, countsB, state);
        checkGpuErrors(cudaGetLastError());
    }

    inline std::size_t graphNodeOpsScanBytes(TreeNodeIndex leafCapacity)
    {
        std::size_t bytes = 0;
        std::int64_t *offsets = nullptr;
        checkGpuErrors(cub::DeviceScan::ExclusiveSum(nullptr, bytes, offsets, offsets,
                                                     std::size_t(leafCapacity) + 1));
        return bytes;
    }

    __global__ void binaryDecisionKernel(
        const KeyType *treeA, const KeyType *treeB, const unsigned *countsA,
        const unsigned *countsB, TreeNodeIndex leafCapacity, unsigned bucketSize,
        unsigned maxDepth, std::int64_t *nodeOps, RebalanceState *state)
    {
        const std::size_t node = std::size_t(blockIdx.x) * blockDim.x + threadIdx.x;
        if (node > std::size_t(leafCapacity)) return;
        int op = 0;
        if (!state->converged && !state->needsResize && node < std::size_t(state->numLeaves))
        {
            const KeyType *tree = state->activeBuffer ? treeB : treeA;
            const unsigned *counts = state->activeBuffer ? countsB : countsA;
            // Remove only the boundary between equal-sized, aligned siblings.
            const bool merge = node && binarySiblings(tree, state->numLeaves, TreeNodeIndex(node - 1)) &&
                               static_cast<unsigned long long>(counts[node - 1]) + counts[node] <= bucketSize;
            op = merge ? 0 : (counts[node] > bucketSize &&
                             binaryDepth(tree[node], tree[node + 1]) < maxDepth ? 2 : 1);
            if (op != 1) atomicExch(&state->changed, 1);
        }
        nodeOps[node] = op;
    }

    __global__ void binaryCheckCapacityKernel(const std::int64_t *nodeOps,
                                               TreeNodeIndex leafCapacity,
                                               RebalanceState *state)
    {
        if (state->converged) return;
        if (state->needsResize || !state->changed)
        {
            state->converged = 1;
            return;
        }
        const auto proposed = nodeOps[leafCapacity];
        if (proposed > leafCapacity)
        {
            state->needsResize = 1;
            state->converged = 1;
            return;
        }
        state->newNumLeaves = TreeNodeIndex(proposed);
    }

    __global__ void binaryProcessNodesKernel(
        KeyType *treeA, KeyType *treeB, const std::int64_t *nodeOps,
        const RebalanceState *state)
    {
        const TreeNodeIndex node = blockIdx.x * blockDim.x + threadIdx.x;
        if (state->converged || node >= state->numLeaves) return;
        const KeyType *tree = state->activeBuffer ? treeB : treeA;
        KeyType *output = state->activeBuffer ? treeA : treeB;
        if (!node) output[state->newNumLeaves] = maxKey;
        const int op = int(nodeOps[node + 1] - nodeOps[node]);
        if (!op) return;
        const auto target = nodeOps[node];
        output[target] = tree[node];
        if (op == 2) output[target + 1] = tree[node] + (tree[node + 1] - tree[node]) / 2;
    }

    __global__ void binaryCommitKernel(RebalanceState *state)
    {
        if (state->converged) return;
        state->numLeaves = state->newNumLeaves;
        state->numNodes = (state->numLeaves - 1) * 2 + 1;
        state->activeBuffer ^= 1;
    }

    inline void updateBinaryGraphGpu(
        execution::Gpu exec, std::span<const KeyType> keys, unsigned bucketSize,
        unsigned maxDepth, TreeNodeIndex leafCapacity, KeyType *treeA,
        unsigned *countsA, KeyType *treeB, unsigned *countsB,
        std::int64_t *nodeOps, void *scanTempStorage, std::size_t scanTempBytes,
        RebalanceState *state)
    {
        constexpr unsigned threads = defaults::blockThreads;
        const auto blocks = iceil(std::size_t(leafCapacity) + 1, threads);
        checkGpuErrors(cudaMemsetAsync(&state->changed, 0, sizeof(state->changed), exec));
        binaryDecisionKernel<<<blocks, threads, 0, exec>>>(
            treeA, treeB, countsA, countsB, leafCapacity, bucketSize, maxDepth, nodeOps, state);
        checkGpuErrors(cub::DeviceScan::ExclusiveSum(scanTempStorage, scanTempBytes,
                                                     nodeOps, nodeOps,
                                                     std::size_t(leafCapacity) + 1, exec));
        binaryCheckCapacityKernel<<<1, 1, 0, exec>>>(nodeOps, leafCapacity, state);
        binaryProcessNodesKernel<<<blocks, threads, 0, exec>>>(treeA, treeB, nodeOps, state);
        binaryCommitKernel<<<1, 1, 0, exec>>>(state);
        refreshBinaryCountsGpu(exec, keys, leafCapacity, treeA, treeB, countsA, countsB, state);
    }

    template <class Perm, class Real>
    __global__ void computeSfcKeysBinaryKernel(
        KeyType *keys, Perm *perm, const Real *x, const Real *y, const Real *z,
        std::size_t numKeys, adaptive_octree::Box<Real> box, BinaryGeometry geometry)
    {
        const std::size_t index = std::size_t(blockIdx.x) * blockDim.x + threadIdx.x;
        if (index >= numKeys) return;
        keys[index] = isEscapedParticle(x[index], y[index], z[index]) ? invalidParticleKey :
            binaryEncode((double(x[index]) - double(box.xmin)) / (double(box.xmax) - double(box.xmin)),
                         (double(y[index]) - double(box.ymin)) / (double(box.ymax) - double(box.ymin)),
                         (double(z[index]) - double(box.zmin)) / (double(box.zmax) - double(box.zmin)), geometry);
        perm[index] = static_cast<Perm>(index);
    }

    template <class Perm, class Real>
    inline void computeSfcKeysBinary(
        execution::Gpu exec, const Real *x, const Real *y, const Real *z,
        KeyType *keys, Perm *perm, std::size_t numKeys, const adaptive_octree::Box<Real> &box,
        const BinaryGeometry &geometry)
    {
        if (!numKeys) return;
        constexpr unsigned threads = defaults::blockThreads;
        computeSfcKeysBinaryKernel<<<iceil(numKeys, threads), threads, 0, exec>>>(
            keys, perm, x, y, z, numKeys, box, geometry);
        checkGpuErrors(cudaGetLastError());
    }
}
