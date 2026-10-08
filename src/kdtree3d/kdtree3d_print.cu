#include "adaptive_octree/kdtree3d.hpp"
#include "binary_node.cuh"

#include <algorithm>
#include <numeric>
#include <ostream>
#include <thrust/host_vector.h>

namespace adaptive_octree
{
    template <class Real>
    void KDTree3D<Real>::print(std::ostream &out) const
    {
        const thrust::host_vector<KeyType> K = cornerstone_d(), P = particleKeys_d();
        const thrust::host_vector<unsigned> N = leafCounts_d();
        const thrust::host_vector<PermIndex> perm = perm_d();
        out << "Adaptive 3D Binary Tree\n"
            << "LeafCount / longest-side binary keys\nParticles: " << numActiveParticles() << " / " << numParticles()
            << " input slots\nLeaves: " << N.size() << "\nNodes: " << numNodes()
            << "\nMaximum binary depth: " << maxAchievedDepth() << '\n';
        if (!N.empty())
        {
            const auto [lo, hi] = std::minmax_element(N.begin(), N.end());
            const auto sum = std::accumulate(N.begin(), N.end(), std::uint64_t(0));
            out << "N: min=" << *lo << " max=" << *hi << " sum=" << sum
                << " mean=" << double(sum) / N.size()
                << " empty=" << std::count(N.begin(), N.end(), 0u) << '\n';
        }
        auto samples = [&](const char *name, const auto &values) {
            out << name << " size=" << values.size() << " samples=[";
            for (std::size_t i = 0; i < std::min(defaults::printSamples, values.size()); ++i)
                out << (i ? ", " : "") << values[i];
            out << (values.size() > defaults::printSamples ? ", ...]\n" : "]\n");
        };
        samples("P", P);
        samples("Perm", perm);
        out << "K: leaf boundary array (" << K.size() << " keys)\n";
        auto leaf = [&](std::size_t i) {
            out << "  leaf[" << i << "] depth=" << detail::kdtree3d::binaryDepth(K[i], K[i + 1])
                << " K=[" << K[i] << ',' << K[i + 1] << ") N=" << N[i] << '\n';
        };
        const auto head = std::min(defaults::printSamples, N.size());
        for (std::size_t i = 0; i < head; ++i) leaf(i);
        if (N.size() > 2 * defaults::printSamples) out << "  ...\n";
        for (std::size_t i = std::max(head, N.size() > defaults::printSamples ? N.size() - defaults::printSamples : 0); i < N.size(); ++i) leaf(i);
    }

    template void KDTree3D<float>::print(std::ostream &) const;
    template void KDTree3D<double>::print(std::ostream &) const;
}
