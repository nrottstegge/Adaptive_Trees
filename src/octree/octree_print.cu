// octree_print.cu

#include "adaptive_octree/octree.hpp"

#include <algorithm>
#include <cstddef>
#include <iomanip>
#include <limits>
#include <numeric>
#include <ostream>

#include <thrust/host_vector.h>

namespace adaptive_octree
{

    namespace
    {
        // prints size/min/max plus a few head/tail samples of one array, all on a single line
        template <class Vec>
        void printArrayLine(std::ostream &out, const char *name, const Vec &v)
        {
            constexpr std::size_t sampleCount = defaults::octreeVectorPrintSamples;

            out << std::left << std::setw(18) << name << ": size=" << v.size();

            if (!v.empty())
            {
                const auto [minIt, maxIt] = std::minmax_element(v.begin(), v.end());
                out << "  min=" << +(*minIt) << "  max=" << +(*maxIt);
            }

            out << "  samples=[";

            const std::size_t head = std::min(sampleCount, v.size());
            for (std::size_t i = 0; i < head; ++i)
            {
                if (i)
                    out << ", ";
                out << +v[i];
            }

            if (v.size() > 2 * sampleCount)
                out << ", ...";

            if (v.size() > sampleCount)
            {
                const std::size_t tailBegin = std::max(head, v.size() - sampleCount);
                for (std::size_t i = tailBegin; i < v.size(); ++i)
                    out << ", " << +v[i];
            }

            out << "]\n";
        }
    } // namespace

    template <class Real>
    void Octree<Real>::print(std::ostream &out) const
    {
        constexpr std::size_t sampleCount = defaults::printSamples;

        const thrust::host_vector<KeyType> P = particleKeys_d();
        const thrust::host_vector<KeyType> Perm = perm_d();
        const thrust::host_vector<KeyType> K = cornerstone_d();
        const thrust::host_vector<unsigned> N = leafCounts_d();
        const thrust::host_vector<unsigned> NF = nearFieldCounts_d();

        const auto splitCriterionStr = [&]()
        {
            switch (splitCriterion())
            {
            case SplitCriterion::LeafCount:
                return "LeafCount";
            case SplitCriterion::NFCount:
                return "NFCount";
            default:
                return "Unknown";
            }
        }();

        const auto sfcKindStr = [&]()
        {
            switch (sfcKind())
            {
            case SfcKind::Morton:
                return "Morton";
            case SfcKind::Hilbert:
                return "Hilbert";
            default:
                return "Unknown";
            }
        }();

        auto separator = [&]()
        {
            out << "----------------------------------------------------------------\n";
        };

        auto printSample =
            [&](const auto &v, const char *name)
        {
            out << name << " size = " << v.size() << '\n';

            if (v.empty())
                return;

            const std::size_t head = std::min(sampleCount, v.size());

            for (std::size_t i = 0; i < head; ++i)
                out << "  " << name << "[" << i << "] = " << v[i] << '\n';

            if (v.size() > 2 * sampleCount)
                out << "  ...\n";

            const std::size_t tailBegin =
                v.size() > sampleCount ? std::max(head, v.size() - sampleCount) : head;

            for (std::size_t i = tailBegin; i < v.size(); ++i)
                out << "  " << name << "[" << i << "] = " << v[i] << '\n';
        };

        // -------------------------------------------------------------------------
        // General summary
        // -------------------------------------------------------------------------

        separator();
        out << "Adaptive Octree Summary\n";
        separator();

        const std::size_t nLeaves = K.empty() ? 0 : K.size() - 1;

        out << "Split criterion: " << splitCriterionStr << '\n';
        out << "SFC kind       : " << sfcKindStr << '\n';

        out << "Particles      : " << numActiveParticles() << '\n';
        out << "Input slots    : " << numParticles() << '\n';
        out << "Leaves         : " << nLeaves << '\n';

        out << '\n';

        // -------------------------------------------------------------------------
        // Leaf occupancy statistics
        // -------------------------------------------------------------------------

        separator();
        out << "Leaf occupancy\n";
        separator();

        if (!N.empty())
        {
            const auto [minIt, maxIt] = std::minmax_element(N.begin(), N.end());

            const std::uint64_t totalParticles =
                std::accumulate(
                    N.begin(),
                    N.end(),
                    std::uint64_t{0});

            const double avg =
                static_cast<double>(totalParticles) /
                static_cast<double>(N.size());

            std::size_t emptyLeaves = 0;

            for (auto count : N)
            {
                if (count == 0)
                    ++emptyLeaves;
            }

            out << "Min particles/leaf : " << *minIt << '\n';
            out << "Max particles/leaf : " << *maxIt << '\n';
            out << "Avg particles/leaf : " << std::fixed << std::setprecision(2) << avg << '\n';
            out << "Empty leaves        : " << emptyLeaves
                << " (" << std::fixed << std::setprecision(2)
                << 100.0 * static_cast<double>(emptyLeaves) /
                       static_cast<double>(N.size())
                << "%)\n";

            out << std::defaultfloat;
        }

        out << '\n';

        // -------------------------------------------------------------------------
        // Nearfield statistics
        // -------------------------------------------------------------------------

        separator();
        out << "Nearfield\n";
        separator();

        if (!NF.empty())
        {
            const auto [minIt, maxIt] = std::minmax_element(NF.begin(), NF.end());

            const std::uint64_t totalNFinteractions =
                std::accumulate(
                    NF.begin(),
                    NF.end(),
                    std::uint64_t{0});

            const double avg =
                static_cast<double>(totalNFinteractions) /
                static_cast<double>(NF.size());

            std::size_t emptyLeaves = 0;

            for (auto count : NF)
            {
                if (count == 0)
                    ++emptyLeaves;
            }

            out << "Min interactions/leaf : " << *minIt << '\n';
            out << "Max interactions/leaf : " << *maxIt << '\n';
            out << "Total number interactions   : " << totalNFinteractions << '\n';
            out << "Avg interactions/leaf : " << std::fixed << std::setprecision(2) << avg << '\n';
            out << "Empty leaves           : " << emptyLeaves
                << " (" << std::fixed << std::setprecision(2)
                << 100.0 * static_cast<double>(emptyLeaves) /
                       static_cast<double>(NF.size())
                << "%)\n";

            out << std::defaultfloat;
        }

        out << '\n';

                // -------------------------------------------------------------------------
        // Cornerstone leaf size / depth distribution
        // -------------------------------------------------------------------------

        separator();
        out << "Cornerstone leaf ranges\n";
        separator();

        if (K.size() >= 2)
        {
            KeyType minDelta = std::numeric_limits<KeyType>::max();
            KeyType maxDelta = 0;

            for (std::size_t i = 0; i + 1 < K.size(); ++i)
            {
                const KeyType delta = K[i + 1] - K[i];

                minDelta = std::min(minDelta, delta);
                maxDelta = std::max(maxDelta, delta);
            }

            out << "Smallest key range : " << minDelta << '\n';
            out << "Largest key range  : " << maxDelta << '\n';
        }

        out << '\n';

        // -------------------------------------------------------------------------
        // Samples instead of full dumps
        // -------------------------------------------------------------------------

        separator();
        out << "Array samples\n";
        separator();

        printSample(P, "P");
        out << '\n';

        printSample(Perm, "Perm");
        out << '\n';

        printSample(K, "K");
        out << '\n';

        printSample(N, "N");
        out << '\n';

        printSample(NF, "NF");
        out << '\n';

        out << '\n';

        // -------------------------------------------------------------------------
        // Sample leaf records
        // -------------------------------------------------------------------------

        separator();
        out << "Sample leaves\n";
        separator();

        auto printLeaf = [&](std::size_t i)
        {
            if (i >= N.size() || i + 1 >= K.size())
                return;

            out << "leaf[" << i << "]"
                << "  K=[" << K[i] << ", " << K[i + 1] << ")"
                << "  range=" << (K[i + 1] - K[i])
                << "  particles=" << N[i]
                << '\n';
        };

        const std::size_t leafHead = std::min(sampleCount, nLeaves);

        for (std::size_t i = 0; i < leafHead; ++i)
            printLeaf(i);

        if (nLeaves > 2 * sampleCount)
            out << "...\n";

        if (nLeaves > sampleCount)
        {
            const std::size_t start =
                std::max(leafHead, nLeaves - sampleCount);

            for (std::size_t i = start; i < nLeaves; ++i)
                printLeaf(i);
        }

        out << '\n';

        separator();

        // -------------------------------------------------------------------------
        // Tree-structure view (only computed if Config::views.treeStructure, or one
        // of the other two view flags, was set -- see Octree::Impl::buildTreeView())
        // -------------------------------------------------------------------------

        const thrust::host_vector<KeyType> sfcBoxIndex = sfcBoxIndex_d();

        if (!sfcBoxIndex.empty())
        {
            out << "Tree-structure view\n";
            separator();

            out << "maxAchievedDepth  : " << maxAchievedDepth() << '\n';

            printArrayLine(out, "SFCBoxIndex", sfcBoxIndex);
            printArrayLine(out, "hasBoxSplit", thrust::host_vector<std::uint8_t>(hasBoxSplit_d()));
            printArrayLine(out, "boxDepth", thrust::host_vector<std::uint8_t>(boxDepth_d()));
            printArrayLine(out, "parentIndex", thrust::host_vector<NodeIndex>(parentIndex_d()));
            printArrayLine(out, "childIndex", thrust::host_vector<NodeIndex>(childIndex_d()));
            printArrayLine(out, "levelOffset", thrust::host_vector<NodeIndex>(levelOffset_d()));

            out << '\n';
        }

        // -------------------------------------------------------------------------
        // Per-box particle counts (only if Config::views.particleCountsPerBox)
        // -------------------------------------------------------------------------

        const thrust::host_vector<unsigned> particleCounts = particleCounts_d();

        if (!particleCounts.empty())
        {
            separator();
            out << "Per-box particle counts\n";
            separator();

            printArrayLine(out, "particleBeginIdx", thrust::host_vector<unsigned>(particleBeginIndex_d()));
            printArrayLine(out, "particleCounts", particleCounts);

            out << '\n';
        }

        // -------------------------------------------------------------------------
        // Particle <-> leaf mapping (only if Config::views.particleMapping)
        // -------------------------------------------------------------------------

        const thrust::host_vector<KeyType> sfcParticleIndex = sfcParticleIndex_d();

        if (!sfcParticleIndex.empty())
        {
            separator();
            out << "Particle <-> leaf mapping\n";
            separator();

            printArrayLine(out, "SFCParticleIndex", sfcParticleIndex);

            out << '\n';
        }

        separator();
    }

    template void Octree<float>::print(std::ostream &) const;
    template void Octree<double>::print(std::ostream &) const;

} // namespace adaptive_octree
