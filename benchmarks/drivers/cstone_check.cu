// Correctness check: for identical keys (v3's sorted Morton keys P) and bucket size 64,
// Cornerstone's converged leaf array must equal the v3 Octree/LeafCount leaf array K.
// Writes one row per snapshot.
#include "common.hpp"

#include <thrust/execution_policy.h>

#include "cstone/cuda/thrust_util.cuh"
#include "cstone/tree/update_gpu.cuh"
#undef HOST_DEVICE_FUN
#include "adaptive_octree/tree.hpp"

namespace ao = adaptive_octree;
using Key = std::uint64_t;
static_assert(sizeof(ao::KeyType) == sizeof(Key));

// A converged LeafCount octree is unique: every leaf <= bucket (unless at max depth) and no
// group of 8 sibling leaves with total <= bucket. Count violations of both conditions.
struct Violations
{
    std::size_t overfull = 0, mergeable = 0;
};

Violations leafCountViolations(const thrust::host_vector<Key> &K, const Key *P_d, std::size_t nP, unsigned bucket)
{
    thrust::device_vector<Key> K_d(K);
    thrust::device_vector<std::size_t> pos(K.size());
    thrust::lower_bound(thrust::device, P_d, P_d + nP, K_d.begin(), K_d.end(), pos.begin());
    const thrust::host_vector<std::size_t> h = pos;
    Violations v;
    const std::size_t L = K.size() - 1;
    for (std::size_t i = 0; i < L; ++i)
    {
        const Key range = K[i + 1] - K[i];
        if (h[i + 1] - h[i] > bucket && range > 1) ++v.overfull;
        const Key parent = range << 3;
        // 8 leaves spanning one aligned parent are exactly its 8 children
        if (range < bench::rootKeyEnd && K[i] % parent == 0 && i + 8 <= L && K[i + 8] - K[i] == parent &&
            h[i + 8] - h[i] <= bucket)
            ++v.mergeable;
    }
    return v;
}

int main(int argc, char **argv)
{
    try
    {
        const bench::Args a = bench::parseArgs(argc, argv);
        BENCH_CUDA(cudaFree(0));
        const bench::Manifest m = bench::readManifest(a.manifest);
        std::vector<double> x, y, z;
        bench::readFrame(m.frames.front(), x, y, z);
        const std::size_t n = x.size();
        thrust::device_vector<double> x_d(x), y_d(y), z_d(z);
        cudaStream_t s;
        BENCH_CUDA(cudaStreamCreateWithFlags(&s, cudaStreamNonBlocking));

        ao::Tree<double, ao::TreeType::Octree>::Config cfg;
        cfg.maxParticlesPerLeaf = 64;
        cfg.splitCriterion = ao::SplitCriterion::LeafCount;
        cfg.sfcKind = ao::SfcKind::Morton;
        cfg.box = {m.box[0], m.box[1], m.box[2], m.box[3], m.box[4], m.box[5]};
        cfg.stream = s;
        ao::Tree<double, ao::TreeType::Octree> tree(thrust::raw_pointer_cast(x_d.data()),
                                                     thrust::raw_pointer_cast(y_d.data()),
                                                     thrust::raw_pointer_cast(z_d.data()), n, cfg);
        tree.build();

        std::ofstream out(a.out);
        out << "dataset,snapshot,frame_id,v3_leaves,cstone_leaves,leaf_arrays_identical,cstone_iterations,"
               "particles_active,v3_overfull_leaves,v3_mergeable_groups,cstone_overfull_leaves,cstone_mergeable_groups\n";
        const std::size_t last =
            a.maxSnapshots > 0 ? std::min<std::size_t>(a.maxSnapshots, m.frames.size()) : m.frames.size();
        thrust::device_vector<Key> cs, tmp;
        thrust::device_vector<unsigned> counts;
        thrust::device_vector<cstone::TreeNodeIndex> work;
        for (std::size_t k = 0; k < last; ++k)
        {
            if (k > 0)
            {
                bench::readFrame(m.frames[k], x, y, z);
                if (x.size() != n) throw std::runtime_error("slot count changed");
                thrust::copy(x.begin(), x.end(), x_d.begin());
                thrust::copy(y.begin(), y.end(), y_d.begin());
                thrust::copy(z.begin(), z.end(), z_d.begin());
                tree.update();
            }
            while (tree.doBuffersNeedResize())
            {
                tree.resizeBuffers();
                tree.update();
            }
            BENCH_CUDA(cudaStreamSynchronize(s));
            const Key *P = reinterpret_cast<const Key *>(thrust::raw_pointer_cast(tree.particleKeys_d().data()));
            const std::size_t active =
                thrust::lower_bound(thrust::device, P, P + tree.particleKeys_d().size(), bench::rootKeyEnd) - P;

            cs = std::vector<Key>{0, cstone::nodeRange<Key>(0)};
            counts = std::vector<unsigned>{unsigned(active)};
            int it = 0;
            while (!cstone::updateOctreeGpu<Key>(cstone::execution::gpuDefaultStream, {P, active}, 64u, cs, counts,
                                                 tmp, work) &&
                   ++it < 64)
                ;
            const thrust::host_vector<Key> a3(tree.cornerstone_d().begin(), tree.cornerstone_d().end());
            const thrust::host_vector<Key> ac = cs;
            const bool same = a3.size() == ac.size() && std::equal(a3.begin(), a3.end(), ac.begin());
            const Violations v3v = leafCountViolations(a3, P, active, 64), csv = leafCountViolations(ac, P, active, 64);
            out << m.dataset << ',' << m.frames[k].index << ',' << m.frames[k].id << ',' << a3.size() - 1 << ','
                << ac.size() - 1 << ',' << (same ? 1 : 0) << ',' << it + 1 << ',' << active << ',' << v3v.overfull
                << ',' << v3v.mergeable << ',' << csv.overfull << ',' << csv.mergeable << '\n';
            if (k % 500 == 0 || k + 1 == last)
                std::cerr << "checked " << k + 1 << '/' << last << " snapshots\n";
        }
        return 0;
    }
    catch (const std::exception &e)
    {
        const std::string what = e.what();
        std::cerr << "cstone_check: " << what << '\n';
        return what.find("out of memory") != std::string::npos ? bench::oomExitCode : 1;
    }
}
