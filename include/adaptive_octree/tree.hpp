#pragma once

#include "adaptive_octree/octree.hpp"
#include "adaptive_octree/kdtree3d.hpp"

#include <type_traits>
#include <stdexcept>

namespace adaptive_octree
{
    template <class Real, TreeType Kind>
    class Tree
    {
        static_assert(Kind == TreeType::Octree || Kind == TreeType::Binary,
                      "TreeType must be Octree or Binary");
        using Backend = std::conditional_t<Kind == TreeType::Octree, Octree<Real>, KDTree3D<Real>>;
    public:
        using KeyType = adaptive_octree::KeyType;
        using NodeIndex = adaptive_octree::NodeIndex;
        using SplitCriterion = adaptive_octree::SplitCriterion;
        using SfcKind = adaptive_octree::SfcKind;
        using ViewConfig = adaptive_octree::ViewConfig;
        using Config = TreeConfig<Real>;

        Tree(const Real *x, const Real *y, const Real *z,
             std::size_t count, Config config = {})
            : backend_(x, y, z, count, backendConfig(config)) {}

        Tree(Tree &&) noexcept = default;
        Tree &operator=(Tree &&) noexcept = default;
        Tree(const Tree &) = delete;
        Tree &operator=(const Tree &) = delete;

        static constexpr TreeType type() { return Kind; }
        void build() { backend_.build(); }
        void update() { backend_.update(); }
        void resizeBuffers() { backend_.resizeBuffers(); }
        void print(std::ostream &out) const { backend_.print(out); }
        void computeViews() { backend_.computeViews(); }
        void computeViews(ViewConfig views)
        {
            backend_.computeViews(views);
        }

        // These preserve the backend's status-refresh and CUDA capture rules.
        bool doBuffersNeedResize() const
        { return backend_.doBuffersNeedResize(); }
        const NodeIndex * numLeaves_d() const
        { return backend_.numLeaves_d(); }
        const NodeIndex * numNodes_d() const
        { return backend_.numNodes_d(); }
        const unsigned * numActiveParticles_d() const
        { return backend_.numActiveParticles_d(); }
        std::size_t numParticles() const
        { return backend_.numParticles(); }
        std::size_t numActiveParticles() const
        { return backend_.numActiveParticles(); }
        std::size_t numNodes() const
        { return backend_.numNodes(); }
        unsigned maxAchievedDepth() const
        { return backend_.maxAchievedDepth(); }
        const thrust::device_vector<KeyType> & particleKeys_d() const
        { return backend_.particleKeys_d(); }
        const thrust::device_vector<PermIndex> & perm_d() const
        { return backend_.perm_d(); }
        const thrust::device_vector<KeyType> & cornerstone_d() const
        { return backend_.cornerstone_d(); }
        const thrust::device_vector<unsigned> & leafCounts_d() const
        { return backend_.leafCounts_d(); }
        const thrust::device_vector<KeyType> & sfcBoxIndex_d() const
        { return backend_.sfcBoxIndex_d(); }
        const thrust::device_vector<std::uint8_t> & hasBoxSplit_d() const
        { return backend_.hasBoxSplit_d(); }
        const thrust::device_vector<std::uint8_t> & boxDepth_d() const
        { return backend_.boxDepth_d(); }
        const thrust::device_vector<NodeIndex> & parentIndex_d() const
        { return backend_.parentIndex_d(); }
        const thrust::device_vector<NodeIndex> & childIndex_d() const
        { return backend_.childIndex_d(); }
        const thrust::device_vector<NodeIndex> & levelOffset_d() const
        { return backend_.levelOffset_d(); }
        const thrust::device_vector<unsigned> & particleBeginIndex_d() const
        { return backend_.particleBeginIndex_d(); }
        const thrust::device_vector<unsigned> & particleCounts_d() const
        { return backend_.particleCounts_d(); }
        const thrust::device_vector<KeyType> & sfcParticleIndex_d() const
        { return backend_.sfcParticleIndex_d(); }

        SplitCriterion splitCriterion() const
        {
            if constexpr (Kind == TreeType::Octree) return backend_.splitCriterion();
            else return SplitCriterion::LeafCount;
        }
        SfcKind sfcKind() const
        {
            if constexpr (Kind == TreeType::Octree) return backend_.sfcKind();
            else throw std::logic_error("Tree: SFC selection requires Octree mode");
        }
        const thrust::device_vector<unsigned> &nearFieldCounts_d() const
        {
            if constexpr (Kind == TreeType::Octree) return backend_.nearFieldCounts_d();
            else throw std::logic_error("Tree: Binary NFCount is not implemented yet");
        }

    private:
        Backend backend_;

        static typename Backend::Config backendConfig(const Config &config)
        {
            if (config.maxDepth < -1 || config.updateIterations < -1)
                throw std::invalid_argument("Tree: use -1 for backend defaults");
            typename Backend::Config c;
            if (config.maxDepth >= 0) c.maxDepth = config.maxDepth;
            if (config.updateIterations >= 0) c.updateIterations = config.updateIterations;
            c.maxParticlesPerLeaf = config.maxParticlesPerLeaf;
            c.box = config.box;
            c.stream = config.stream;
            c.views = config.views;
            if constexpr (Kind == TreeType::Octree)
            {
                c.splitCriterion = config.splitCriterion;
                c.sfcKind = config.sfcKind;
                c.interactive = false;
            }
            else
            {
                if (config.splitCriterion != SplitCriterion::LeafCount)
                    throw std::invalid_argument("Tree: Binary NFCount is not implemented yet");
                if (config.sfcKind != SfcKind::Morton)
                    throw std::invalid_argument("Tree: Binary uses longest-side keys, not Hilbert");
            }
            return c;
        }
    };
}
