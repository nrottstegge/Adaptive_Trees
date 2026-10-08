// v1 (e7bd16a8ad): Octree<double> + buildFMSolvrView, direct path on the legacy default stream.
#include "common.hpp"

#include <thrust/execution_policy.h>

#include <memory>

#include "adaptive_octree/fmsolvr_view.hpp"
#include "adaptive_octree/octree.hpp"

namespace ao = adaptive_octree;
using Octree = ao::Octree<double>;
static_assert(sizeof(Octree::KeyType) == 8, "64-bit SFC keys required (unsigned long on LP64)");

struct V1
{
    static const char *pathName() { return "direct"; }
    static constexpr bool supportsEscaped = false;

    static bool supports(const bench::RunConfig &c) { return c.tree == bench::TreeKind::Octree; }
    static cudaStream_t stream() { return 0; } // v1 runs on cstone::execution::gpuDefaultStream

    V1(const bench::RunConfig &c, const bench::Manifest &m, double *x, double *y, double *z, std::size_t n,
       cudaStream_t)
    {
        Octree::Config cfg;
        const bool nf = c.criterion == bench::Criterion::NFCount;
        cfg.maxParticlesPerLeaf = c.limit;
        cfg.splitCriterion = nf ? Octree::SplitCriterion::NFCount : Octree::SplitCriterion::LeafCount;
        cfg.box = {m.box[0], m.box[1], m.box[2], m.box[3], m.box[4], m.box[5]};
        // v1's constructor prompts on stdin for criterion and limit; answer "default limit" (= c.limit)
        std::istringstream answers(nf ? "2\nn\n" : "1\nn\n");
        auto *old = std::cin.rdbuf(answers.rdbuf());
        tree_ = std::make_unique<Octree>(x, y, z, n, cfg);
        std::cin.rdbuf(old);
        if (tree_->splitCriterion() != cfg.splitCriterion) throw std::runtime_error("v1: unexpected criterion");
    }

    void build() { tree_->build(); }
    void views() { ao::buildFMSolvrView(*tree_, view_); }
    void prepare(bench::Events &) {}
    void step(bench::Events &ev)
    {
        BENCH_CUDA(cudaEventRecord(ev.begin, 0));
        tree_->update();
        BENCH_CUDA(cudaEventRecord(ev.treeEnd, 0));
        ao::buildFMSolvrView(*tree_, view_);
        BENCH_CUDA(cudaEventRecord(ev.end, 0));
    }
    bool needsResize() { return false; }
    void resize(bench::Events &) {}

    const bench::Key *P() { return reinterpret_cast<const bench::Key *>(thrust::raw_pointer_cast(tree_->particleKeys_d().data())); }
    std::size_t nP() { return tree_->particleKeys_d().size(); }
    const bench::Key *K() { return reinterpret_cast<const bench::Key *>(thrust::raw_pointer_cast(tree_->cornerstone_d().data())); }
    std::size_t nK() { return tree_->cornerstone_d().size(); }
    double libNodes() { return double(view_.sfcBoxIndex_d().size()); }
    int iterations() { return -1; }

private:
    std::unique_ptr<Octree> tree_;
    ao::FMSolvrTreeView view_;
};

int main(int argc, char **argv) { return bench::runDriver<V1>(argc, argv); }
