// v2 (ea89b79a9d): Octree<double>, direct path on the legacy default stream.
#include "common.hpp"

#include <thrust/execution_policy.h>

#include <memory>

#include "adaptive_octree/octree.hpp"

namespace ao = adaptive_octree;
using Octree = ao::Octree<double>;
static_assert(sizeof(Octree::KeyType) == 8, "64-bit SFC keys required");

struct V2
{
    static const char *pathName() { return "direct"; }
    static constexpr bool supportsEscaped = false;
    static constexpr Octree::ViewConfig allViews{true, true, true};

    static bool supports(const bench::RunConfig &c) { return c.tree == bench::TreeKind::Octree; }
    static cudaStream_t stream() { return 0; } // v2 runs on execution::gpuDefaultStream

    V2(const bench::RunConfig &c, const bench::Manifest &m, double *x, double *y, double *z, std::size_t n,
       cudaStream_t)
    {
        const bool nf = c.criterion == bench::Criterion::NFCount;
        Octree::Config cfg;
        cfg.maxParticlesPerLeaf = c.limit;
        cfg.splitCriterion = nf ? Octree::SplitCriterion::NFCount : Octree::SplitCriterion::LeafCount;
        cfg.sfcKind = Octree::SfcKind::Morton;
        cfg.box = {m.box[0], m.box[1], m.box[2], m.box[3], m.box[4], m.box[5]};
        // v2's constructor always prompts on stdin for criterion and limit; answer
        // "default limit" (64 / 64*64*27), which equals c.limit.
        std::istringstream answers(nf ? "2\nn\n" : "1\nn\n");
        auto *old = std::cin.rdbuf(answers.rdbuf());
        tree_ = std::make_unique<Octree>(x, y, z, n, cfg);
        std::cin.rdbuf(old);
        if (tree_->splitCriterion() != cfg.splitCriterion || tree_->sfcKind() != Octree::SfcKind::Morton)
            throw std::runtime_error("v2: unexpected criterion or SFC");
    }

    void build() { tree_->build(); }
    void views() { tree_->computeViews(allViews); }
    void prepare(bench::Events &) {}
    void step(bench::Events &ev)
    {
        BENCH_CUDA(cudaEventRecord(ev.begin, 0));
        tree_->update();
        BENCH_CUDA(cudaEventRecord(ev.treeEnd, 0));
        tree_->computeViews(allViews);
        BENCH_CUDA(cudaEventRecord(ev.end, 0));
    }
    bool needsResize() { return false; }
    void resize(bench::Events &) {}

    const bench::Key *P() { return reinterpret_cast<const bench::Key *>(thrust::raw_pointer_cast(tree_->particleKeys_d().data())); }
    std::size_t nP() { return tree_->particleKeys_d().size(); }
    const bench::Key *K() { return reinterpret_cast<const bench::Key *>(thrust::raw_pointer_cast(tree_->cornerstone_d().data())); }
    std::size_t nK() { return tree_->cornerstone_d().size(); }
    double libNodes() { return double(tree_->numNodes()); }
    int iterations() { return -1; }

private:
    std::unique_ptr<Octree> tree_;
};

int main(int argc, char **argv) { return bench::runDriver<V2>(argc, argv); }
