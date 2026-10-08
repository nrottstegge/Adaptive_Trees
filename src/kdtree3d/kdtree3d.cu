// Adaptive binary tree over contiguous key intervals.
#include <cuda_runtime.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

#include <algorithm>
#include <cub/device/device_radix_sort.cuh>
#include <limits>
#include <stdexcept>

#include "adaptive_octree/config.hpp"
#include "adaptive_octree/kdtree3d.hpp"
#include "helpers.cuh"
#include "tree_view.hpp"
#include "kdtree3d_rebalance.cuh"

namespace adaptive_octree
{
    using namespace detail;
    using namespace detail::kdtree3d;

    namespace detail::kdtree3d
    {
        __global__ void initBinaryRootKernel(KeyType *tree, RebalanceState *state)
        {
            tree[0] = 0;
            tree[1] = maxKey;
            *state = RebalanceState{};
            state->numNodes = 1;
        }
    }

    template <class Real>
    struct KDTree3D<Real>::Impl
    {
        ~Impl()
        {
            cudaFree(rebalanceState_d);
            cudaFreeHost(state_h);
        }

        Config config;
        BinaryGeometry geometry;
        execution::Gpu exec = execution::gpuDefaultStream;
        std::size_t leafCapacity = 0;
        bool built = false;
        int activeBuffer = 0;
        const Real *x_d = nullptr, *y_d = nullptr, *z_d = nullptr;
        std::size_t numParticles = 0, numActiveParticles = 0, numNodes = 0;

        thrust::device_vector<KeyType> P_d, P_sorted_d;
        thrust::device_vector<PermIndex> Perm_d, Perm_sorted_d;
        thrust::device_vector<KeyType> K_d, tmpTree;
        thrust::device_vector<unsigned> N_d, tmpCounts;
        thrust::device_vector<std::int64_t> graphNodeOps;
        thrust::device_vector<std::uint8_t> sortTempStorage_d, nodeOpsScanTempStorage;
        std::size_t sortTempStorageBytes = 0;
        RebalanceState *rebalanceState_d = nullptr, *state_h = nullptr;
        TreeView<1> treeView;
        ViewConfig preparedViews{};
        std::unique_ptr<CudaContext> viewCuda;

        void prepareViews()
        {
            if (!preparedViews.treeStructure && !preparedViews.particleCountsPerBox &&
                !preparedViews.particleMapping)
                return;
            if (!viewCuda)
                viewCuda = std::make_unique<CudaContext>();
            treeView.prepare(leafCapacity, numParticles, preparedViews, exec);
        }

        void buildTreeView(ViewConfig views)
        {
            preparedViews.treeStructure |= views.treeStructure;
            preparedViews.particleCountsPerBox |= views.particleCountsPerBox;
            preparedViews.particleMapping |= views.particleMapping;
            treeView.build(exec, viewCuda.get(), K_d, P_d, N_d, numParticles,
                           views, rebalanceState_d, rawPtr(tmpTree), rawPtr(tmpCounts));
        }

        void prepare()
        {
            P_sorted_d.resize(numParticles, thrust::no_init);
            Perm_sorted_d.resize(numParticles, thrust::no_init);
            checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                nullptr, sortTempStorageBytes, rawPtr(P_sorted_d), rawPtr(P_d),
                rawPtr(Perm_sorted_d), rawPtr(Perm_d), numParticles, 0,
                sizeof(KeyType) * 8, exec));
            resizeWithHeadroom(sortTempStorage_d, sortTempStorageBytes);
            checkGpuErrors(cudaMalloc(&rebalanceState_d, sizeof(RebalanceState)));
            checkGpuErrors(cudaMallocHost(reinterpret_cast<void **>(&state_h),
                                           sizeof(RebalanceState)));
        }

        void prepareGraphBuffers(std::size_t capacity)
        {
            // A full binary tree with L leaves has 2L-1 total nodes.
            constexpr auto maxLeaves = std::size_t(std::numeric_limits<NodeIndex>::max()) / 2 + 1;
            if (capacity > maxLeaves)
                throw std::length_error("adaptive_octree: buffer capacity exceeds node index range");
            const auto leaves = K_d.size() - 1;
            leafCapacity = capacity;
            auto prepare = [](auto &v, std::size_t size) {
                if (v.capacity() < size) v.reserve(size);
                v.resize(size, thrust::no_init);
            };
            prepare(K_d, capacity + 1); prepare(tmpTree, capacity + 1);
            prepare(N_d, capacity); prepare(tmpCounts, capacity);
            graphNodeOps.resize(capacity + 1, thrust::no_init);
            const auto bytes = graphNodeOpsScanBytes(NodeIndex(capacity));
            if (nodeOpsScanTempStorage.size() < bytes)
                resizeWithHeadroom(nodeOpsScanTempStorage, bytes);
            if (built) prepareViews();
            syncSizes(leaves);
        }

        void syncSizes(std::size_t leaves)
        {
            K_d.resize(leaves + 1, thrust::no_init);
            tmpTree.resize(leaves + 1, thrust::no_init);
            N_d.resize(leaves, thrust::no_init);
            tmpCounts.resize(leaves, thrust::no_init);
            treeView.syncSizes(leaves, numActiveParticles);
        }

        const RebalanceState &readState()
        {
            checkGpuErrors(cudaMemcpyAsync(state_h, rebalanceState_d, sizeof(RebalanceState),
                                           cudaMemcpyDeviceToHost, exec));
            checkGpuErrors(cudaStreamSynchronize(exec));
            activeBuffer = state_h->activeBuffer;
            numActiveParticles = state_h->numActiveParticles;
            numNodes = state_h->numNodes;
            syncSizes(state_h->numLeaves);
            return *state_h;
        }

        void refreshCounts()
        {
            resetRebalanceStateGpu(exec, rebalanceState_d,
                                    std::span<const KeyType>{rawPtr(P_d), P_d.size()});
            refreshBinaryCountsGpu(exec, {rawPtr(P_d), P_d.size()}, NodeIndex(leafCapacity),
                rawPtr(K_d), rawPtr(tmpTree), rawPtr(N_d), rawPtr(tmpCounts), rebalanceState_d);
        }

        void rebalancePass()
        {
            updateBinaryGraphGpu(exec, {rawPtr(P_d), P_d.size()}, config.maxParticlesPerLeaf,
                config.maxDepth, NodeIndex(leafCapacity), rawPtr(K_d), rawPtr(N_d),
                rawPtr(tmpTree), rawPtr(tmpCounts), rawPtr(graphNodeOps),
                rawPtr(nodeOpsScanTempStorage), nodeOpsScanTempStorage.size(), rebalanceState_d);
        }

        void growBuffers()
        {
            prepareGraphBuffers(leafCapacity + (leafCapacity + defaults::bufferGrowthDivisor - 1) / defaults::bufferGrowthDivisor);
            checkGpuErrors(cudaMemsetAsync(&rebalanceState_d->needsResize, 0, sizeof(int), exec));
        }

        void computeParticleKeys()
        {
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Compute Particle Keys");
            computeSfcKeysBinary(exec, x_d, y_d, z_d, rawPtr(P_sorted_d), rawPtr(Perm_sorted_d),
                                 numParticles, config.box, geometry);
            ADAPTIVE_OCTREE_NVTX_RANGE_POP();
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Sort Particle Keys");
            checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                rawPtr(sortTempStorage_d), sortTempStorageBytes, rawPtr(P_sorted_d), rawPtr(P_d),
                rawPtr(Perm_sorted_d), rawPtr(Perm_d), numParticles, 0, sizeof(KeyType) * 8, exec));
            ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        }
    };

    template <class Real>
    KDTree3D<Real>::KDTree3D(const Real *x_d, const Real *y_d, const Real *z_d,
                         std::size_t numParticles, Config config)
        : impl_(std::make_unique<Impl>())
    {
        if (numParticles > 0 && (!x_d || !y_d || !z_d))
        {
            throw std::invalid_argument(
                "adaptive_octree: coordinate device pointers must not be null");
        }

        if (config.maxParticlesPerLeaf == 0)
            throw std::invalid_argument(
                "adaptive_octree: particle limit must be positive");
        if (config.updateIterations == 0)
            throw std::invalid_argument(
                "adaptive_octree: updateIterations must be positive");
        impl_->config = config;
        impl_->exec = execution::Gpu{config.stream};
        impl_->preparedViews = config.views;
        impl_->geometry = makeBinaryGeometry(config.box, config.maxDepth);

        impl_->x_d = x_d;
        impl_->y_d = y_d;
        impl_->z_d = z_d;

        impl_->numParticles = numParticles;

        if (numParticles >
            static_cast<std::size_t>(std::numeric_limits<PermIndex>::max()))
        {
            throw std::invalid_argument(
                "adaptive_octree: particle count exceeds 32-bit permutation index "
                "range");
        }

        impl_->P_d.resize(numParticles, thrust::no_init);
        impl_->Perm_d.resize(numParticles, thrust::no_init);

        // Array resizing
        impl_->prepare();
    }

    template <class Real>
    KDTree3D<Real>::~KDTree3D() = default;

    template <class Real>
    KDTree3D<Real>::KDTree3D(KDTree3D &&) noexcept = default;

    template <class Real>
    KDTree3D<Real> &KDTree3D<Real>::operator=(KDTree3D &&) noexcept = default;

    template <class Real>
    void KDTree3D<Real>::build()
    {
        checkGpuErrors(cudaStreamSynchronize(impl_->exec));
        impl_->built = false;
        impl_->K_d.resize(2, thrust::no_init);
        impl_->prepareGraphBuffers(std::max(std::size_t(2), impl_->leafCapacity));
        impl_->computeParticleKeys();
        initBinaryRootKernel<<<1, 1, 0, impl_->exec>>>(
            rawPtr(impl_->K_d), impl_->rebalanceState_d);
        impl_->refreshCounts();
        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Build Binary Tree");
        for (;;)
        {
            impl_->rebalancePass();
            const auto state = impl_->readState();
            if (state.needsResize)
            {
                impl_->growBuffers();
                impl_->refreshCounts();
            }
            else if (state.converged) break;
        }
        ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        impl_->built = true;
        impl_->prepareViews();
        impl_->buildTreeView(impl_->config.views);
        const auto &views = impl_->config.views;
        if (views.treeStructure || views.particleCountsPerBox || views.particleMapping)
            (void)doBuffersNeedResize();
    }

    template <class Real>
    void KDTree3D<Real>::update()
    {
        if (!impl_->built)
            throw std::logic_error("adaptive_octree: call build() before update()");
        impl_->computeParticleKeys();
        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Update Binary Tree");
        impl_->refreshCounts();
        for (unsigned i = 0; i < impl_->config.updateIterations; ++i) impl_->rebalancePass();
        ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        impl_->buildTreeView(impl_->config.views);
    }

    template <class Real>
    void KDTree3D<Real>::computeViews(ViewConfig views)
    {
        if (!impl_->built)
            throw std::logic_error("adaptive_octree: call build() before computeViews()");
        impl_->buildTreeView(views);
    }

    template <class Real>
    void KDTree3D<Real>::computeViews() { computeViews(impl_->config.views); }

    template <class Real>
    bool KDTree3D<Real>::doBuffersNeedResize() const
    {
        return impl_->built && impl_->readState().needsResize != 0;
    }

    template <class Real>
    void KDTree3D<Real>::resizeBuffers()
    {
        if (!impl_->built)
            throw std::logic_error("adaptive_octree: call build() before resizeBuffers()");
        impl_->readState();
        impl_->growBuffers();
        checkGpuErrors(cudaStreamSynchronize(impl_->exec));
    }

    template <class Real>
    const typename KDTree3D<Real>::NodeIndex *KDTree3D<Real>::numLeaves_d() const
    {
        return &impl_->rebalanceState_d->numLeaves;
    }

    template <class Real>
    const typename KDTree3D<Real>::NodeIndex *KDTree3D<Real>::numNodes_d() const
    {
        return &impl_->rebalanceState_d->numNodes;
    }

    template <class Real>
    const unsigned *KDTree3D<Real>::numActiveParticles_d() const
    {
        return &impl_->rebalanceState_d->numActiveParticles;
    }

    template <class Real>
    std::size_t KDTree3D<Real>::numActiveParticles() const
    {
        return impl_->numActiveParticles;
    }

    template <class Real>
    std::size_t KDTree3D<Real>::numParticles() const
    {
        return impl_->numParticles;
    }

    template <class Real>
    std::size_t KDTree3D<Real>::numNodes() const
    {
        return impl_->numNodes;
    }

    // GETTERS
    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::KeyType> &
    KDTree3D<Real>::particleKeys_d() const
    {
        return impl_->P_d;
    }

    // -----------------------------------------------------------------------------
    // Perm
    // -----------------------------------------------------------------------------
    template <class Real>
    const thrust::device_vector<PermIndex> &KDTree3D<Real>::perm_d() const
    {
        return impl_->Perm_d;
    }
    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::KeyType> &
    KDTree3D<Real>::cornerstone_d() const
    {
        return impl_->activeBuffer ? impl_->tmpTree : impl_->K_d;
    }

    template <class Real>
    const thrust::device_vector<unsigned> &KDTree3D<Real>::leafCounts_d() const
    {
        return impl_->activeBuffer ? impl_->tmpCounts : impl_->N_d;
    }

    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::KeyType> &
    KDTree3D<Real>::sfcBoxIndex_d() const
    {
        return impl_->treeView.sfcBoxIndex_d();
    }

    template <class Real>
    const thrust::device_vector<std::uint8_t> &KDTree3D<Real>::hasBoxSplit_d() const
    {
        return impl_->treeView.hasBoxSplit_d();
    }

    template <class Real>
    const thrust::device_vector<std::uint8_t> &KDTree3D<Real>::boxDepth_d() const
    {
        return impl_->treeView.boxDepth_d();
    }

    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::NodeIndex> &
    KDTree3D<Real>::parentIndex_d() const
    {
        return impl_->treeView.parentIndex_d();
    }

    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::NodeIndex> &
    KDTree3D<Real>::childIndex_d() const
    {
        return impl_->treeView.childIndex_d();
    }

    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::NodeIndex> &
    KDTree3D<Real>::levelOffset_d() const
    {
        return impl_->treeView.levelOffset_d();
    }

    template <class Real>
    unsigned KDTree3D<Real>::maxAchievedDepth() const
    {
        const auto &views = impl_->config.views;
        if (views.treeStructure || views.particleCountsPerBox || views.particleMapping)
            return impl_->treeView.maxAchievedDepth();
        const thrust::host_vector<KeyType> keys = cornerstone_d();
        unsigned depth = 0;
        for (std::size_t i = 0; i + 1 < keys.size(); ++i)
            depth = std::max(depth, binaryDepth(keys[i], keys[i + 1]));
        return depth;
    }

    template <class Real>
    const thrust::device_vector<unsigned> &KDTree3D<Real>::particleBeginIndex_d()
        const
    {
        return impl_->treeView.particleBeginIndex_d();
    }

    template <class Real>
    const thrust::device_vector<unsigned> &KDTree3D<Real>::particleCounts_d() const
    {
        return impl_->treeView.particleCounts_d();
    }

    template <class Real>
    const thrust::device_vector<typename KDTree3D<Real>::KeyType> &
    KDTree3D<Real>::sfcParticleIndex_d() const
    {
        return impl_->treeView.sfcParticleIndex_d();
    }

    template class KDTree3D<float>;
    template class KDTree3D<double>;

} // namespace adaptive_octree
