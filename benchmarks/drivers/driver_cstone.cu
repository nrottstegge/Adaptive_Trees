// Cornerstone baseline (LeafCount only). "Tree update" = computeSfcKeys + key/permutation
// radix sort + recount + updateOctreeGpu until converged; "view" = OctreeData::resize +
// buildOctreeGpu (internal tree linking, the closest equivalent of a TreeView).
#include "common.hpp"

#include <cub/device/device_radix_sort.cuh>
#include <thrust/execution_policy.h>
#include <thrust/sequence.h>

#include "cstone/cuda/thrust_util.cuh"
#include "cstone/sfc/sfc_gpu.h"
#include "cstone/tree/octree.hpp"
#include "cstone/tree/octree_gpu.h"
#include "cstone/tree/update_gpu.cuh"

using Key = std::uint64_t;
using Sfc = cstone::MortonKey<Key>;
static_assert(sizeof(Key) == 8);

struct Cstone
{
    static const char *pathName() { return "direct"; }
    static constexpr bool supportsEscaped = false;
    static constexpr int maxIterations = 64;

    static bool supports(const bench::RunConfig &c)
    {
        return c.tree == bench::TreeKind::Octree && c.criterion == bench::Criterion::LeafCount;
    }
    static cudaStream_t stream() { return 0; }

    Cstone(const bench::RunConfig &c, const bench::Manifest &m, double *x, double *y, double *z, std::size_t n,
           cudaStream_t s)
        : x_(x), y_(y), z_(z), n_(n), bucket_(c.limit), exec_(cstone::execution::gpuStream(s)),
          box_(m.box[0], m.box[1], m.box[2], m.box[3], m.box[4], m.box[5]), keys_(n), keysAlt_(n), perm_(n),
          permAlt_(n)
    {
        cub::DoubleBuffer<Key> k(cstone::rawPtr(keys_), cstone::rawPtr(keysAlt_));
        cub::DoubleBuffer<unsigned> p(cstone::rawPtr(perm_), cstone::rawPtr(permAlt_));
        cub::DeviceRadixSort::SortPairs(nullptr, sortBytes_, k, p, n_, 0, 64, exec_);
        sortTmp_.resize(sortBytes_);
    }

    void build()
    {
        tree_ = std::vector<Key>{0, cstone::nodeRange<Key>(0)};
        counts_ = std::vector<unsigned>{unsigned(n_)};
        update();
    }
    void views()
    {
        octree_.resize(cstone::nNodes(tree_));
        cstone::buildOctreeGpu(exec_, cstone::rawPtr(tree_), octree_.data());
    }
    void prepare(bench::Events &) {}
    void step(bench::Events &ev)
    {
        BENCH_CUDA(cudaEventRecord(ev.begin, exec_));
        update();
        BENCH_CUDA(cudaEventRecord(ev.treeEnd, exec_));
        views();
        BENCH_CUDA(cudaEventRecord(ev.end, exec_));
    }
    bool needsResize() { return false; }
    void resize(bench::Events &) {}

    const Key *P() { return sorted_; }
    std::size_t nP() { return n_; }
    const Key *K() { return cstone::rawPtr(tree_); }
    std::size_t nK() { return tree_.size(); }
    double libNodes() { return double(octree_.numNodes); }
    int iterations() { return iterations_; }

private:
    void update()
    {
        cstone::computeSfcKeys(exec_, x_, y_, z_, reinterpret_cast<Sfc *>(cstone::rawPtr(keys_)), n_, box_);
        thrust::sequence(thrust::cuda::par.on(exec_), perm_.begin(), perm_.end(), 0u);
        cub::DoubleBuffer<Key> k(cstone::rawPtr(keys_), cstone::rawPtr(keysAlt_));
        cub::DoubleBuffer<unsigned> p(cstone::rawPtr(perm_), cstone::rawPtr(permAlt_));
        cub::DeviceRadixSort::SortPairs(cstone::rawPtr(sortTmp_), sortBytes_, k, p, n_, 0, 64, exec_);
        sorted_ = k.Current();
        const std::span<const Key> keys(sorted_, n_);
        // Counts must describe the new keys before the first rebalance decision.
        counts_.resize(cstone::nNodes(tree_));
        cstone::computeNodeCountsGpu(exec_, cstone::rawPtr(tree_), cstone::rawPtr(counts_), cstone::nNodes(tree_),
                                     keys, std::numeric_limits<unsigned>::max(), true);
        iterations_ = 0;
        bool converged = false;
        while (!converged && iterations_ < maxIterations)
        {
            converged = cstone::updateOctreeGpu<Key>(exec_, keys, bucket_, tree_, counts_, tmpTree_, work_);
            ++iterations_;
        }
        if (!converged) throw std::runtime_error("cstone: no convergence");
    }

    double *x_, *y_, *z_;
    std::size_t n_;
    unsigned bucket_;
    cstone::execution::Gpu exec_;
    cstone::Box<double> box_;
    thrust::device_vector<Key> keys_, keysAlt_;
    thrust::device_vector<unsigned> perm_, permAlt_;
    thrust::device_vector<char> sortTmp_;
    std::size_t sortBytes_ = 0;
    const Key *sorted_ = nullptr;
    thrust::device_vector<Key> tree_, tmpTree_;
    thrust::device_vector<unsigned> counts_;
    thrust::device_vector<cstone::TreeNodeIndex> work_;
    cstone::OctreeData<Key, cstone::execution::Gpu> octree_;
    int iterations_ = 0;
};

int main(int argc, char **argv) { return bench::runDriver<Cstone>(argc, argv); }
