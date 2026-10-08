// kdtree3d.hpp
#pragma once

#include <cstddef>
#include <cstdint>
#include <iosfwd>
#include <memory>

#include <cuda_runtime_api.h>

#include <thrust/device_vector.h>

#include "adaptive_octree/config.hpp"

namespace adaptive_octree
{
    // Adaptive 3D binary tree using longest-side splits and leaf particle counts.
    template <class Real>
    class KDTree3D
    {
    public:
        using KeyType = adaptive_octree::KeyType;
        using NodeIndex = adaptive_octree::NodeIndex;
        using ViewConfig = adaptive_octree::ViewConfig;
        using Config = KDTree3DConfig<Real>;

        // Construct a binary tree for numParticles fixed input slots. Escaped slots
        // have escapedParticleCoordinate<Real> in all three coordinates.
        // The coordinates are not copied by this interface.
        KDTree3D(const Real *x_d,
                 const Real *y_d,
                 const Real *z_d,
                 std::size_t numParticles,
                 Config config = {});

        ~KDTree3D();

        // Movable but not copyable.
        KDTree3D(KDTree3D &&) noexcept;
        KDTree3D &operator=(KDTree3D &&) noexcept;

        KDTree3D(const KDTree3D &) = delete;
        KDTree3D &operator=(const KDTree3D &) = delete;

        // print method
        void print(std::ostream &out) const;

        // Build / update / compute views
        void build();
        void update();
        void computeViews(ViewConfig views);
        void computeViews();

        // Call outside capture, after update or graph replay. Synchronizes the
        // configured stream and refreshes the host-visible vector sizes.
        [[nodiscard]] bool doBuffersNeedResize() const;
        // Grow topology/view storage by 25%, clear the flag, then recapture.
        void resizeBuffers();

        // Device-side active sizes for kernels recorded in the same graph.
        [[nodiscard]] const NodeIndex *numLeaves_d() const;
        [[nodiscard]] const NodeIndex *numNodes_d() const;
        // Active particle count for downstream kernels on the configured stream.
        [[nodiscard]] const unsigned *numActiveParticles_d() const;

        // Getters P, Perm, K, N. After replay, logical vector sizes and
        // numNodes()/numActiveParticles() reflect the last
        // build()/doBuffersNeedResize() call. P and Perm retain every input slot;
        // escaped keys form a suffix of P with value invalidParticleKey.
        // Allocations remain stable until build()/resizeBuffers(); tree/count
        // getters select the active A/B buffer from the last status readback.
        [[nodiscard]]
        const thrust::device_vector<KeyType> &particleKeys_d() const;
        [[nodiscard]]
        const thrust::device_vector<PermIndex> &perm_d() const;
        // Sorted leaf boundaries: size is leafCounts_d().size() + 1.
        // Leaf i covers [K[i], K[i+1]); root boundaries are {0,maxKey}.
        [[nodiscard]]
        const thrust::device_vector<KeyType> &cornerstone_d() const;
        [[nodiscard]]
        const thrust::device_vector<unsigned> &leafCounts_d() const;

        // Structure arrays are built when any view flag is enabled.
        // Box SFC index in Warren-Salmon format: the path's depth bits preceded
        // by a placeholder 1. The root is 1; its children are 2 and 3.
        [[nodiscard]] const thrust::device_vector<KeyType> &sfcBoxIndex_d() const;
        // 0 = leaf, 1 = split/internal node.
        [[nodiscard]] const thrust::device_vector<std::uint8_t> &hasBoxSplit_d() const;
        // Depth/level of each box.
        [[nodiscard]] const thrust::device_vector<std::uint8_t> &boxDepth_d() const;
        // Index of the parent box. Root uses invalidNodeIndex.
        [[nodiscard]] const thrust::device_vector<NodeIndex> &parentIndex_d() const;
        // Index of child 0. Child 1 is offset by half the next level's width.
        [[nodiscard]] const thrust::device_vector<NodeIndex> &childIndex_d() const;
        // levelOffset[level] = starting index of boxes at this level (65 entries).
        // Unused trailing entries equal numNodes().
        [[nodiscard]] const thrust::device_vector<NodeIndex> &levelOffset_d() const;
        // Host query, outside graph capture and after status refresh.
        [[nodiscard]] unsigned maxAchievedDepth() const;

        // Per-box real particle counts (empty unless Config::views.particleCountsPerBox was set)
        // First particle index belonging to this box in particle-SFC order.
        [[nodiscard]] const thrust::device_vector<unsigned> &particleBeginIndex_d() const;
        // Number of particles belonging to this box, plus one trailing sentinel
        // element (index numNodes()) holding the active particle count.
        [[nodiscard]] const thrust::device_vector<unsigned> &particleCounts_d() const;

        // Particle <-> leaf mapping (empty unless Config::views.particleMapping was set)
        // View-node index for each active particle in sorted-key order, stored
        // as KeyType. Length is refreshed by build()/doBuffersNeedResize(); the
        // underlying allocation retains room for all input slots during replay.
        // Entries beyond the active count hold invalidParticleNodeIndex.
        [[nodiscard]] const thrust::device_vector<KeyType> &sfcParticleIndex_d() const;

        // Getters
        // Fixed input slot count, including escaped particles.
        [[nodiscard]] std::size_t numParticles() const;
        // Active count from the last build()/doBuffersNeedResize() call.
        [[nodiscard]] std::size_t numActiveParticles() const;
        [[nodiscard]] std::size_t numNodes() const;

    private:
        struct Impl;
        std::unique_ptr<Impl> impl_;
        
    };

} // namespace adaptive_octree
