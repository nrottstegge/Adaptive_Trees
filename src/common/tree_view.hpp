// tree_view.hpp
//
// Shared BFS view of a finished octree or binary cornerstone tree K

#pragma once

#include <thrust/device_vector.h>

#include <cstddef>
#include <cstdint>
#include <memory>

#include "adaptive_octree/config.hpp"
#include "cuda_context.hpp"
#include "sfc_keys.cuh"

namespace adaptive_octree
{
    namespace detail { struct RebalanceState; }
    template<unsigned LevelBits>
    class TreeView
    {
        static_assert(LevelBits == 1 || LevelBits == 3);
    public:
        using Config = ViewConfig;

        TreeView();
        ~TreeView();

        // Allocate before capture; capacities remain fixed until the next prepare.
        void prepare(std::size_t leafCapacity, std::size_t numParticles,
                     Config config, detail::execution::Gpu exec);
        void syncSizes(std::size_t numLeaves, std::size_t numActiveParticles);

        // Rebuilds the view for the given (converged) K/P/N arrays. No-op if
        // config has all three flags false. The stream context must exist once
        // the requested view buffers have been prepared.
        void build(detail::execution::Gpu exec, detail::CudaContext *cudaContext,
                   const thrust::device_vector<KeyType> &K_d,
                   const thrust::device_vector<KeyType> &P_d,
                   const thrust::device_vector<unsigned> &N_d,
                   std::size_t numParticles, Config config,
                   detail::RebalanceState *state = nullptr,
                   const KeyType *K_alt = nullptr, const unsigned *N_alt = nullptr);

        std::size_t numNodes() const { return numNodes_; }

        const thrust::device_vector<KeyType> &sfcBoxIndex_d() const
        {
            return sfcBoxIndex_d_;
        }
        const thrust::device_vector<std::uint8_t> &hasBoxSplit_d() const
        {
            return hasBoxSplit_d_;
        }
        const thrust::device_vector<std::uint8_t> &boxDepth_d() const
        {
            return boxDepth_d_;
        }
        const thrust::device_vector<NodeIndex> &parentIndex_d() const
        {
            return parentIndex_d_;
        }
        const thrust::device_vector<NodeIndex> &childIndex_d() const
        {
            return childIndex_d_;
        }
        const thrust::device_vector<NodeIndex> &levelOffset_d() const
        {
            return levelOffset_d_;
        }
        unsigned maxAchievedDepth() const;

        const thrust::device_vector<unsigned> &particleBeginIndex_d() const
        {
            return particleBeginIndex_d_;
        }
        const thrust::device_vector<unsigned> &particleCounts_d() const
        {
            return particleCounts_d_;
        }

        const thrust::device_vector<KeyType> &sfcParticleIndex_d() const
        {
            return sfcParticleIndex_d_;
        }
        const thrust::device_vector<unsigned> &particleCountsLeaf_d() const
        {
            return particleCountsLeaf_d_;
        }

    private:
        struct Scratch;
        std::unique_ptr<Scratch> scratch_;
        std::size_t leafCapacity_ = 0;
        std::size_t particleCapacity_ = 0;
        Config preparedConfig_{};
        thrust::device_vector<KeyType> sfcBoxIndex_d_;
        thrust::device_vector<unsigned> particleBeginIndex_d_;
        thrust::device_vector<unsigned> particleCounts_d_;
        thrust::device_vector<std::uint8_t> hasBoxSplit_d_;
        thrust::device_vector<std::uint8_t> boxDepth_d_;
        thrust::device_vector<NodeIndex> parentIndex_d_;
        thrust::device_vector<NodeIndex> childIndex_d_;
        thrust::device_vector<KeyType> sfcParticleIndex_d_;
        thrust::device_vector<unsigned> particleCountsLeaf_d_;
        thrust::device_vector<NodeIndex> levelOffset_d_;

        // cornerstone leaf index -> assigned node index; internal bookkeeping only,
        // no getter
        thrust::device_vector<NodeIndex> leafToNode_d_;

        std::uint8_t *maxAchievedDepth_d_ = nullptr;
        std::size_t numNodes_ = 0;
    };

} // namespace adaptive_octree
