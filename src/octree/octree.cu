// octree.cu
//
#include <cuda_runtime.h>
#include <thrust/device_vector.h>

#include <algorithm>
#include <cub/device/device_radix_sort.cuh>
#include <limits>
#include <stdexcept>
#include <vector>

#include "adaptive_octree/config.hpp"
#include "adaptive_octree/octree.hpp"
#include "helpers.cuh"
#include "cuda_context.hpp"
#include "tree_view.hpp"
#include "octree_rebalance.cuh" // updateOctreeGpu, computeSfcKeys, computeNodeCountsGpu, computeNFCountsAndGroupCanMergeGpu

namespace adaptive_octree
{
    using namespace detail;

    template <class KeyType>
    __global__ void initRootOctreeKernel(KeyType *K, unsigned *N, unsigned *NF,
                                         const KeyType *P, std::size_t numSlots)
    {
        if (threadIdx.x == 0)
        {
            K[0] = KeyType(0);
            K[1] = nodeRange<KeyType>(0);
            const unsigned long long active = numSlots == 0 ? 0ULL :
                static_cast<unsigned long long>(lowerBound(P, P + numSlots, K[1]) - P);
            N[0] = static_cast<unsigned>(active);
            constexpr unsigned cap = ~0u;
            const auto square = active * active;
            NF[0] = square > cap / 27ULL ? cap : static_cast<unsigned>(27ULL * square);
        }
    }

    __global__ void finishBuildStateKernel(RebalanceState *state, NodeIndex leaves)
    {
        // Preserve the active particle count computed on the GPU during build.
        state->numLeaves = state->newNumLeaves = leaves;
        state->changed = state->converged = state->needsResize = 0;
        state->numNodes = 0;
        state->activeBuffer = 0;
    }

    template <class Real>
    struct Octree<Real>::Impl
    {
        ~Impl()
        {
            if (rebalanceState_d)
                cudaFree(rebalanceState_d);
        }

        Config config;
        CudaContext octreeCuda;
        ViewConfig preparedViews{};
        std::size_t leafCapacity = 0;
        bool built = false;
        int activeBuffer = 0;

        // one stream used by all GPU work of this Octree
        execution::Gpu exec = execution::gpuDefaultStream;

        // particle coordinates
        const Real *x_d = nullptr;
        const Real *y_d = nullptr;
        const Real *z_d = nullptr;

        // -------------------------------------------------------------------------
        // Paper representation
        // -------------------------------------------------------------------------

        // P
        mutable thrust::device_vector<KeyType> P_d;

        // Permutation vector
        mutable thrust::device_vector<PermIndex> Perm_d;

        // K
        mutable thrust::device_vector<KeyType> K_d;

        // N
        mutable thrust::device_vector<unsigned> N_d;

        // NF
        mutable thrust::device_vector<unsigned> NF_d;

        // -------------------------------------------------------------------------
        // Temporary construction data required by updateOctreeGpu / buildOctreeGpu
        // -------------------------------------------------------------------------

        thrust::device_vector<KeyType> tmpTree;
        thrust::device_vector<NodeIndex> workArray;
        thrust::device_vector<std::int64_t> graphNodeOps;
        thrust::device_vector<unsigned> tmpCounts;
        thrust::device_vector<unsigned> tmpNFCounts;
        thrust::device_vector<std::uint8_t> nfDirty;

        thrust::device_vector<std::uint8_t> groupCanMerge;
        thrust::device_vector<std::uint8_t> tmpGroupCanMerge;
        thrust::device_vector<std::uint8_t> groupDirty;

        thrust::device_vector<TreeNodeIndex> dirtyNFIndices;
        thrust::device_vector<TreeNodeIndex> numDirtyNFNodes;
        thrust::device_vector<std::uint8_t> nfSelectTempStorage;

        thrust::device_vector<TreeNodeIndex> dirtyGroupIndices;
        thrust::device_vector<TreeNodeIndex> numDirtyGroups;
        thrust::device_vector<std::uint8_t> groupSelectTempStorage;

        RebalanceState *rebalanceState_d = nullptr;

        // -------------------------------------------------------------------------
        // Temporary data structures for CUB radix sort
        // -------------------------------------------------------------------------

        thrust::device_vector<KeyType> P_sorted_d;
        thrust::device_vector<std::uint8_t> sortTempStorage_d;
        thrust::device_vector<PermIndex> Perm_sorted_d;

        std::size_t sortTempStorageBytes = 0;

        // scratch buffer for CUB prefix-sum scan of groupCanMerge
        thrust::device_vector<std::uint8_t> nodeOpsScanTempStorage;

        // derived tree-structure / particle-mapping view, see tree_view.hpp
        TreeView<3> treeView;

        void prepare()
        {
            P_sorted_d.resize(numParticles, thrust::no_init);
            Perm_sorted_d.resize(numParticles, thrust::no_init);

            sortTempStorageBytes = 0;
            checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                nullptr, sortTempStorageBytes, rawPtr(P_sorted_d), rawPtr(P_d),
                rawPtr(Perm_sorted_d), rawPtr(Perm_d), numParticles, 0,
                sizeof(KeyType) * 8, exec));

            resizeWithHeadroom(sortTempStorage_d, sortTempStorageBytes);
            checkGpuErrors(cudaMalloc(&rebalanceState_d, sizeof(RebalanceState)));
            checkGpuErrors(cudaMallocHost(reinterpret_cast<void **>(&octreeCuda.state_h), sizeof(RebalanceState)));
            numDirtyGroups.resize(1);

            K_d.resize(2);
            N_d.resize(1);
            NF_d.resize(1);
        }

        std::size_t numParticles = 0;
        std::size_t numActiveParticles = 0;
        std::size_t numNodes = 0;

        // Build may grow storage and stop as soon as the host sees convergence
        void rebalanceBuild()
        {
            const bool hilbert = config.sfcKind == SfcKind::Hilbert;
            resetRebalanceStateGpu<KeyType>(exec, rebalanceState_d,
                                            {rawPtr(P_d), P_d.size()});
            for (unsigned i = 0; i < config.maxDepth; ++i)
            {
                if (updateOctreeGpu<KeyType>(
                        exec, {rawPtr(P_d), P_d.size()}, config.maxParticlesPerLeaf, K_d,
                        N_d, NF_d, tmpTree, workArray, tmpCounts, tmpNFCounts, nfDirty,
                        groupCanMerge, tmpGroupCanMerge, groupDirty, dirtyNFIndices,
                        numDirtyNFNodes, nfSelectTempStorage, dirtyGroupIndices,
                        numDirtyGroups, groupSelectTempStorage, nodeOpsScanTempStorage,
                        rebalanceState_d, octreeCuda.computeA, octreeCuda.computeB,
                        octreeCuda.computeC, octreeCuda.readyA, octreeCuda.readyB,
                        octreeCuda.readyC, octreeCuda.readyD, octreeCuda.changed_h,
                        octreeCuda.newNumNodes_h,
                        config.splitCriterion == SplitCriterion::NFCount,
                        std::numeric_limits<unsigned>::max(), hilbert))
                    break;
            }
        }

        void prepareGraphBuffers(std::size_t capacity)
        {
            // View node indices must also fit NodeIndex (8 nodes per 7 leaves).
            constexpr auto maxLeaves =
                (std::size_t(std::numeric_limits<NodeIndex>::max()) - 1) / 8 * 7 + 1;
            if (capacity > maxLeaves)
                throw std::length_error(
                    "adaptive_octree: buffer capacity exceeds node index range");

            const auto leaves = K_d.size() - 1;
            leafCapacity = capacity;
            if (K_d.capacity() < capacity + 1)
                K_d.reserve(capacity + 1);
            K_d.resize(capacity + 1, thrust::no_init);
            if (tmpTree.capacity() < capacity + 1)
                tmpTree.reserve(capacity + 1);
            tmpTree.resize(capacity + 1, thrust::no_init);
            if (N_d.capacity() < capacity)
                N_d.reserve(capacity);
            N_d.resize(capacity, thrust::no_init);
            if (NF_d.capacity() < capacity)
                NF_d.reserve(capacity);
            NF_d.resize(capacity, thrust::no_init);
            if (tmpCounts.capacity() < capacity)
                tmpCounts.reserve(capacity);
            tmpCounts.resize(capacity, thrust::no_init);
            if (tmpNFCounts.capacity() < capacity)
                tmpNFCounts.reserve(capacity);
            tmpNFCounts.resize(capacity, thrust::no_init);
            if (nfDirty.capacity() < capacity)
                nfDirty.reserve(capacity);
            nfDirty.resize(capacity, thrust::no_init);
            if (groupCanMerge.capacity() < capacity)
                groupCanMerge.reserve(capacity);
            groupCanMerge.resize(capacity, thrust::no_init);
            if (tmpGroupCanMerge.capacity() < capacity)
                tmpGroupCanMerge.reserve(capacity);
            tmpGroupCanMerge.resize(capacity, thrust::no_init);
            if (groupDirty.capacity() < capacity)
                groupDirty.reserve(capacity);
            groupDirty.resize(capacity, thrust::no_init);
            if (graphNodeOps.capacity() < capacity + 1)
                graphNodeOps.reserve(capacity + 1);
            graphNodeOps.resize(capacity + 1, thrust::no_init);
            const auto scanBytes = graphNodeOpsScanBytes(NodeIndex(capacity));
            if (nodeOpsScanTempStorage.size() < scanBytes)
                resizeWithHeadroom(nodeOpsScanTempStorage, scanBytes);
            treeView.prepare(
                capacity, numParticles,
                {preparedViews.treeStructure, preparedViews.particleCountsPerBox,
                 preparedViews.particleMapping},
                exec);
            K_d.resize(leaves + 1, thrust::no_init);
            N_d.resize(leaves, thrust::no_init);
            NF_d.resize(leaves, thrust::no_init);
            tmpTree.resize(leaves + 1, thrust::no_init);
            tmpCounts.resize(leaves, thrust::no_init);
            tmpNFCounts.resize(leaves, thrust::no_init);
            treeView.syncSizes(leaves, numActiveParticles);
        }

        void rebalanceUpdate()
        {
            const bool useNF = config.splitCriterion == SplitCriterion::NFCount;
            const bool hilbert = config.sfcKind == SfcKind::Hilbert;

            resetRebalanceStateGpu<KeyType>(exec, rebalanceState_d,
                                            {rawPtr(P_d), P_d.size()});

            refreshGraphCountsGpu(
                exec, {rawPtr(P_d), P_d.size()}, config.maxParticlesPerLeaf,
                NodeIndex(leafCapacity), rawPtr(K_d), rawPtr(tmpTree), rawPtr(N_d),
                rawPtr(tmpCounts), rawPtr(NF_d), rawPtr(tmpNFCounts),
                rawPtr(groupCanMerge), rawPtr(tmpGroupCanMerge), rebalanceState_d,

                octreeCuda.computeA, octreeCuda.computeB,

                octreeCuda.readyA, octreeCuda.readyB, octreeCuda.readyC,

                useNF, std::numeric_limits<unsigned>::max(), hilbert);

            for (unsigned i = 0; i < config.updateIterations; ++i)
                updateOctreeGraphGpu(
                    exec, {rawPtr(P_d), P_d.size()}, config.maxParticlesPerLeaf,
                    NodeIndex(leafCapacity),

                    rawPtr(K_d), rawPtr(N_d), rawPtr(NF_d), rawPtr(tmpTree),
                    rawPtr(tmpCounts), rawPtr(tmpNFCounts),

                    rawPtr(nfDirty), rawPtr(groupCanMerge), rawPtr(tmpGroupCanMerge),
                    rawPtr(groupDirty),

                    rawPtr(graphNodeOps), rawPtr(nodeOpsScanTempStorage),
                    nodeOpsScanTempStorage.size(), rebalanceState_d,

                    octreeCuda.computeA, octreeCuda.computeB,

                    octreeCuda.readyA, octreeCuda.readyB, octreeCuda.readyC,

                    useNF, std::numeric_limits<unsigned>::max(), hilbert);
        }

        // coordinates -> P (SFC-encode + sort particle keys)
        void computeParticleKeys()
        {
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Compute Particle Keys");

            detail::Box<Real> box(config.box.xmin, config.box.xmax, config.box.ymin,
                                  config.box.ymax, config.box.zmin, config.box.zmax);

            computeSfcKeys(exec, x_d, y_d, z_d, rawPtr(P_sorted_d),
                           rawPtr(Perm_sorted_d), numParticles, box,
                           config.sfcKind == SfcKind::Hilbert);

            ADAPTIVE_OCTREE_NVTX_RANGE_POP();

            // sort keys
            ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Sort Particle Keys");

            checkGpuErrors(cub::DeviceRadixSort::SortPairs(
                rawPtr(sortTempStorage_d), sortTempStorageBytes, rawPtr(P_sorted_d),
                rawPtr(P_d), rawPtr(Perm_sorted_d), rawPtr(Perm_d), numParticles, 0,
                sizeof(KeyType) * 8, exec));

            ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        }

        void buildTreeView(ViewConfig views)
        {
            preparedViews.treeStructure |= views.treeStructure;
            preparedViews.particleCountsPerBox |= views.particleCountsPerBox;
            preparedViews.particleMapping |= views.particleMapping;
            treeView.build(exec, &octreeCuda, K_d, P_d, N_d, numParticles,
                           {views.treeStructure, views.particleCountsPerBox,
                            views.particleMapping},
                           rebalanceState_d, rawPtr(tmpTree), rawPtr(tmpCounts));
        }
    };

    template <class Real>
    Octree<Real>::Octree(const Real *x_d, const Real *y_d, const Real *z_d,
                         std::size_t numParticles, Config config)
        : impl_(std::make_unique<Impl>())
    {
        if (numParticles > 0 && (!x_d || !y_d || !z_d))
        {
            throw std::invalid_argument(
                "adaptive_octree: coordinate device pointers must not be null");
        }

        if (config.interactive)
        {
            std::cout << "Select split criterion:\n"
                      << "  1 - LeafCount\n"
                      << "  2 - NFCount\n"
                      << "Choice: ";

            int choice = 0;
            std::cin >> choice;

            const auto defaultNFCountLimit = defaults::nearFieldLimit;
            const auto defaultLeafCountLimit = defaults::maxParticlesPerLeaf;

            if (choice == 1)
            {
                config.splitCriterion = SplitCriterion::LeafCount;
                config.maxParticlesPerLeaf = defaultLeafCountLimit;
            }
            else if (choice == 2)
            {
                config.splitCriterion = SplitCriterion::NFCount;
                config.maxParticlesPerLeaf = defaultNFCountLimit;
            }
            else
            {
                throw std::invalid_argument("adaptive_octree: invalid split criterion");
            }

            std::cout << "Use individual particle/interaction limit? (default is "
                      << (choice == 1 ? defaultLeafCountLimit : defaultNFCountLimit)
                      << ") [y/n]: ";

            char customLimit = 'n';
            std::cin >> customLimit;

            if (customLimit == 'y' || customLimit == 'Y')
            {
                std::cout << "Maximum particles per leaf: ";

                std::size_t limit = 0;
                std::cin >> limit;

                if (!std::cin || limit == 0)
                {
                    throw std::invalid_argument("adaptive_octree: invalid particle limit");
                }

                config.maxParticlesPerLeaf = limit;
            }
            else if (customLimit != 'n' && customLimit != 'N')
            {
                throw std::invalid_argument("adaptive_octree: expected y or n");
            }
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

        impl_->x_d = x_d;
        impl_->y_d = y_d;
        impl_->z_d = z_d;

        impl_->numParticles = numParticles;
        impl_->P_d.resize(numParticles, thrust::no_init);

        if (numParticles >
            static_cast<std::size_t>(std::numeric_limits<PermIndex>::max()))
        {
            throw std::invalid_argument(
                "adaptive_octree: particle count exceeds 32-bit permutation index "
                "range");
        }

        impl_->Perm_d.resize(numParticles, thrust::no_init);

        // Array resizing
        impl_->prepare();
    }

    template <class Real>
    Octree<Real>::~Octree() = default;

    template <class Real>
    Octree<Real>::Octree(Octree &&) noexcept = default;

    template <class Real>
    Octree<Real> &Octree<Real>::operator=(Octree &&) noexcept = default;

    template <class Real>
    void Octree<Real>::build()
    {
        checkGpuErrors(cudaStreamSynchronize(impl_->exec));
        impl_->K_d.resize(2, thrust::no_init);
        impl_->N_d.resize(1, thrust::no_init);
        impl_->NF_d.resize(1, thrust::no_init);
        checkGpuErrors(cudaMemsetAsync(impl_->rebalanceState_d, 0,
                                       sizeof(RebalanceState), impl_->exec));
        // coordinates -> P
        impl_->computeParticleKeys();

        // Start from root, counting only valid keys in the sorted input slots.
        initRootOctreeKernel<<<1, 1, 0, impl_->exec>>>(
            rawPtr(impl_->K_d), rawPtr(impl_->N_d), rawPtr(impl_->NF_d),
            rawPtr(impl_->P_d), impl_->numParticles);
#ifndef NDEBUG
        checkGpuErrors(cudaGetLastError());
#endif

        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Rebalance Octree");

        impl_->rebalanceBuild();

        ADAPTIVE_OCTREE_NVTX_RANGE_POP();

        const auto leaves = impl_->K_d.size() - 1;
        impl_->prepareGraphBuffers(std::max(
            {impl_->K_d.capacity() - 1,
             impl_->tmpTree.empty() ? std::size_t(0) : impl_->tmpTree.capacity() - 1,
             leaves + (leaves + defaults::bufferGrowthDivisor - 1) / defaults::bufferGrowthDivisor}));
        finishBuildStateKernel<<<1, 1, 0, impl_->exec>>>(
            impl_->rebalanceState_d, NodeIndex(leaves));
#ifndef NDEBUG
        checkGpuErrors(cudaGetLastError());
#endif

        impl_->built = true;

        impl_->buildTreeView(impl_->config.views);

        (void)doBuffersNeedResize();
    }

    template <class Real>
    void Octree<Real>::update()
    {
        if (!impl_->built)
            throw std::logic_error("adaptive_octree: call build() before update()");
        impl_->computeParticleKeys();
        ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Update Octree");
        impl_->rebalanceUpdate();
        ADAPTIVE_OCTREE_NVTX_RANGE_POP();
        impl_->buildTreeView(impl_->config.views);
    }

    template <class Real>
    void Octree<Real>::computeViews(ViewConfig views)
    {
        if (!impl_->built)
            throw std::logic_error(
                "adaptive_octree: call build() before computeViews()");
        impl_->buildTreeView(views);
    }

    template <class Real>
    void Octree<Real>::computeViews()
    {
        computeViews(impl_->config.views);
    }

    template <class Real>
    bool Octree<Real>::doBuffersNeedResize() const
    {
        if (!impl_->built)
            return false;

        auto &ctx = impl_->octreeCuda;

        // Mark all work already submitted to exec.
        // In the graph benchmark this is after cudaGraphLaunch().
        checkGpuErrors(cudaEventRecord(ctx.stateReady, impl_->exec));

        // Fork the D2H operation from exec.
        checkGpuErrors(cudaStreamWaitEvent(ctx.dToHStream, ctx.stateReady, 0));

        checkGpuErrors(cudaMemcpyAsync(ctx.state_h, impl_->rebalanceState_d,
                                       sizeof(RebalanceState), cudaMemcpyDeviceToHost,
                                       ctx.dToHStream));

        // Wait only for the state transfer, not exec.
        checkGpuErrors(cudaStreamSynchronize(ctx.dToHStream));

        const RebalanceState &state = *ctx.state_h;

        impl_->activeBuffer = state.activeBuffer;

        impl_->K_d.resize(std::size_t(state.numLeaves) + 1, thrust::no_init);
        impl_->tmpTree.resize(std::size_t(state.numLeaves) + 1, thrust::no_init);

        impl_->tmpCounts.resize(state.numLeaves, thrust::no_init);
        impl_->tmpNFCounts.resize(state.numLeaves, thrust::no_init);
        impl_->N_d.resize(state.numLeaves, thrust::no_init);
        impl_->NF_d.resize(state.numLeaves, thrust::no_init);

        impl_->numActiveParticles = state.numActiveParticles;
        impl_->treeView.syncSizes(state.numLeaves, state.numActiveParticles);
        impl_->numNodes = state.numNodes;

        return state.needsResize != 0;
    }

    template <class Real>
    void Octree<Real>::resizeBuffers()
    {
        if (!impl_->built)
            throw std::logic_error(
                "adaptive_octree: call build() before resizeBuffers()");
        (void)doBuffersNeedResize();
        impl_->prepareGraphBuffers(impl_->leafCapacity +
                                   (impl_->leafCapacity + defaults::bufferGrowthDivisor - 1) / defaults::bufferGrowthDivisor);
        checkGpuErrors(cudaMemsetAsync(&impl_->rebalanceState_d->needsResize, 0,
                                       sizeof(int), impl_->exec));
        checkGpuErrors(cudaStreamSynchronize(impl_->exec));
    }

    template <class Real>
    const typename Octree<Real>::NodeIndex *Octree<Real>::numLeaves_d() const
    {
        return &impl_->rebalanceState_d->numLeaves;
    }

    template <class Real>
    const typename Octree<Real>::NodeIndex *Octree<Real>::numNodes_d() const
    {
        return &impl_->rebalanceState_d->numNodes;
    }

    template <class Real>
    const unsigned *Octree<Real>::numActiveParticles_d() const
    {
        return &impl_->rebalanceState_d->numActiveParticles;
    }

    template <class Real>
    std::size_t Octree<Real>::numActiveParticles() const
    {
        return impl_->numActiveParticles;
    }

    template <class Real>
    std::size_t Octree<Real>::numParticles() const
    {
        return impl_->numParticles;
    }

    template <class Real>
    std::size_t Octree<Real>::numNodes() const
    {
        return impl_->numNodes;
    }

    template <class Real>
    typename Octree<Real>::SplitCriterion Octree<Real>::splitCriterion() const
    {
        return impl_->config.splitCriterion;
    }

    template <class Real>
    typename Octree<Real>::SfcKind Octree<Real>::sfcKind() const
    {
        return impl_->config.sfcKind;
    }

    // GETTERS
    // -----------------------------------------------------------------------------
    // P
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::KeyType> &
    Octree<Real>::particleKeys_d() const
    {
        return impl_->P_d;
    }

    // -----------------------------------------------------------------------------
    // Perm
    // -----------------------------------------------------------------------------
    template <class Real>
    const thrust::device_vector<PermIndex> &Octree<Real>::perm_d() const
    {
        return impl_->Perm_d;
    }
    // -----------------------------------------------------------------------------
    // K
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::KeyType> &
    Octree<Real>::cornerstone_d() const
    {
        return impl_->activeBuffer ? impl_->tmpTree : impl_->K_d;
    }

    // -----------------------------------------------------------------------------
    // N
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<unsigned> &Octree<Real>::leafCounts_d() const
    {
        return impl_->activeBuffer ? impl_->tmpCounts : impl_->N_d;
    }

    // -----------------------------------------------------------------------------
    // NF
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<unsigned> &Octree<Real>::nearFieldCounts_d() const
    {
        return impl_->activeBuffer ? impl_->tmpNFCounts : impl_->NF_d;
    }

    // -----------------------------------------------------------------------------
    // Tree-structure view (delegates to Impl::treeView, see tree_view.hpp)
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::KeyType> &
    Octree<Real>::sfcBoxIndex_d() const
    {
        return impl_->treeView.sfcBoxIndex_d();
    }

    template <class Real>
    const thrust::device_vector<std::uint8_t> &Octree<Real>::hasBoxSplit_d() const
    {
        return impl_->treeView.hasBoxSplit_d();
    }

    template <class Real>
    const thrust::device_vector<std::uint8_t> &Octree<Real>::boxDepth_d() const
    {
        return impl_->treeView.boxDepth_d();
    }

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::NodeIndex> &
    Octree<Real>::parentIndex_d() const
    {
        return impl_->treeView.parentIndex_d();
    }

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::NodeIndex> &
    Octree<Real>::childIndex_d() const
    {
        return impl_->treeView.childIndex_d();
    }

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::NodeIndex> &
    Octree<Real>::levelOffset_d() const
    {
        return impl_->treeView.levelOffset_d();
    }

    template <class Real>
    unsigned Octree<Real>::maxAchievedDepth() const
    {
        return impl_->treeView.maxAchievedDepth();
    }

    // -----------------------------------------------------------------------------
    // Per-box particle counts
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<unsigned> &Octree<Real>::particleBeginIndex_d()
        const
    {
        return impl_->treeView.particleBeginIndex_d();
    }

    template <class Real>
    const thrust::device_vector<unsigned> &Octree<Real>::particleCounts_d() const
    {
        return impl_->treeView.particleCounts_d();
    }

    // -----------------------------------------------------------------------------
    // Particle <-> leaf mapping
    // -----------------------------------------------------------------------------

    template <class Real>
    const thrust::device_vector<typename Octree<Real>::KeyType> &
    Octree<Real>::sfcParticleIndex_d() const
    {
        return impl_->treeView.sfcParticleIndex_d();
    }

    template class Octree<float>;
    template class Octree<double>;

} // namespace adaptive_octree
