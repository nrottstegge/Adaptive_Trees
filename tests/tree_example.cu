// Usage: tree_example [particles.dat], with rows: charge x y z (or ESC).
#include "adaptive_octree/tree.hpp"
#include "particle_io.hpp"

#include <algorithm>
#include <filesystem>
#include <iostream>
#include <thrust/device_vector.h>

int main(int argc, char **argv)
{
    using Tree = adaptive_octree::Tree<double, adaptive_octree::TreeType::Binary>;

    ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Read Particles");
    const std::string path = argc > 1 ? argv[1] :
        (std::filesystem::path(__FILE__).parent_path() /
         "verification_data/snapshot_0000.dat").string();
    auto [x, y, z] = particle_io::readParticles(path, particle_io::Layout::ChargeXYZ);
    ADAPTIVE_OCTREE_NVTX_RANGE_POP();
    std::cout << "Read " << x.size() << " particle slots\n";

    thrust::device_vector<double> x_d(x.begin(), x.end());
    thrust::device_vector<double> y_d(y.begin(), y.end());
    thrust::device_vector<double> z_d(z.begin(), z.end());

    // Change the template argument above to use an octree with the same views.
    Tree::Config config;
    config.maxParticlesPerLeaf = 64;
    config.splitCriterion = Tree::SplitCriterion::LeafCount;
    config.views = {.treeStructure = true,
                    .particleCountsPerBox = true,
                    .particleMapping = true};

    // Keep a fixed rectangular domain covering all active input particles.
    for (std::size_t i = 0; i < x.size(); ++i)
    {
        if (adaptive_octree::isEscapedParticle(x[i], y[i], z[i])) continue;
        config.box.xmin = std::min(config.box.xmin, x[i]);
        config.box.xmax = std::max(config.box.xmax, x[i]);
        config.box.ymin = std::min(config.box.ymin, y[i]);
        config.box.ymax = std::max(config.box.ymax, y[i]);
        config.box.zmin = std::min(config.box.zmin, z[i]);
        config.box.zmax = std::max(config.box.zmax, z[i]);
    }

    ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Init Tree");
    Tree tree(thrust::raw_pointer_cast(x_d.data()),
              thrust::raw_pointer_cast(y_d.data()),
              thrust::raw_pointer_cast(z_d.data()), x.size(), config);
    ADAPTIVE_OCTREE_NVTX_RANGE_POP();

    ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Build Tree");
    tree.build();
    ADAPTIVE_OCTREE_NVTX_RANGE_POP();

    // Access existing device arrays without copying them.
    ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Retrieve Device Vectors");
    const auto &particleKeys = tree.particleKeys_d();
    const auto &permutation = tree.perm_d();
    const auto &cornerstone = tree.cornerstone_d();
    const auto &leafCounts = tree.leafCounts_d();
    const auto &boxKeys = tree.sfcBoxIndex_d();
    const auto &particleBegin = tree.particleBeginIndex_d();
    const auto &particleCounts = tree.particleCounts_d();
    const auto &boxSplit = tree.hasBoxSplit_d();
    const auto &boxDepth = tree.boxDepth_d();
    const auto &parents = tree.parentIndex_d();
    const auto &children = tree.childIndex_d();
    const auto &particleBoxes = tree.sfcParticleIndex_d();
    const auto &levelOffsets = tree.levelOffset_d();
    ADAPTIVE_OCTREE_NVTX_RANGE_POP();

    std::cout << "Built " << cornerstone.size() - 1 << " leaves and "
              << boxKeys.size() << " view nodes (depth " << tree.maxAchievedDepth() << ")\n";

    // Your simulation changes x_d, y_d, z_d in place here, within config.box.
    ADAPTIVE_OCTREE_NVTX_RANGE_PUSH("Update Tree");
    tree.update();
    while (tree.doBuffersNeedResize())
    {
        tree.resizeBuffers();
        tree.update();
    }
    ADAPTIVE_OCTREE_NVTX_RANGE_POP();

    // Reacquire arrays after update: the active tree buffer may have changed.
    const auto &updatedCornerstone = tree.cornerstone_d();
    const auto &updatedCounts = tree.leafCounts_d();
    std::cout << "Updated " << updatedCornerstone.size() - 1 << " leaves and "
              << tree.numActiveParticles() << " active particles\n";
    return 0;
}
