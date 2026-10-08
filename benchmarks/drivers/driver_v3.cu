// v3 (current main): Tree<double, Octree|Binary>, CUDA graph update path.
#include "common.hpp"

#include <thrust/execution_policy.h>

#include <cstdlib>
#include <memory>

#include "adaptive_octree/tree.hpp"

namespace ao = adaptive_octree;
static_assert(sizeof(ao::KeyType) == 8, "64-bit SFC keys required");

template <ao::TreeType Kind>
struct V3
{
    using Tree = ao::Tree<double, Kind>;
    // BENCH_V3_PATH=direct only for verification; benchmarks use the graph path.
    static bool useGraph()
    {
        static const bool g = !(std::getenv("BENCH_V3_PATH") && std::string(std::getenv("BENCH_V3_PATH")) == "direct");
        return g;
    }
    static const char *pathName() { return useGraph() ? "graph" : "direct"; }
    static constexpr bool supportsEscaped = true;
    static constexpr ao::ViewConfig allViews{true, true, true};

    static bool supports(const bench::RunConfig &c)
    {
        return (c.tree == bench::TreeKind::KDTree3D) == (Kind == ao::TreeType::Binary);
    }
    static cudaStream_t stream()
    {
        static cudaStream_t s = []
        {
            cudaStream_t t;
            BENCH_CUDA(cudaStreamCreateWithFlags(&t, cudaStreamNonBlocking));
            return t;
        }();
        return s;
    }

    V3(const bench::RunConfig &c, const bench::Manifest &m, double *x, double *y, double *z, std::size_t n,
       cudaStream_t s)
        : s_(s)
    {
        typename Tree::Config cfg;
        cfg.maxParticlesPerLeaf = c.limit;
        cfg.splitCriterion =
            c.criterion == bench::Criterion::NFCount ? ao::SplitCriterion::NFCount : ao::SplitCriterion::LeafCount;
        cfg.sfcKind = ao::SfcKind::Morton;
        cfg.box = {m.box[0], m.box[1], m.box[2], m.box[3], m.box[4], m.box[5]};
        cfg.stream = s;
        tree_ = std::make_unique<Tree>(x, y, z, n, cfg);
        if constexpr (Kind == ao::TreeType::Octree)
            if (tree_->sfcKind() != ao::SfcKind::Morton) throw std::runtime_error("v3: not Morton");
    }
    ~V3() { discard(); }

    void build() { tree_->build(); }
    void views()
    {
        tree_->computeViews(allViews);
        while (tree_->doBuffersNeedResize())
        {
            tree_->resizeBuffers();
            tree_->computeViews(allViews);
        }
    }
    void prepare(bench::Events &ev)
    {
        if (!useGraph()) return;
        BENCH_CUDA(cudaStreamBeginCapture(s_, cudaStreamCaptureModeGlobal));
        enqueue(ev, cudaEventRecordExternal);
        BENCH_CUDA(cudaStreamEndCapture(s_, &graph_));
        BENCH_CUDA(cudaGraphInstantiate(&exec_, graph_, 0));
        BENCH_CUDA(cudaGraphUpload(exec_, s_));
        BENCH_CUDA(cudaStreamSynchronize(s_));
    }
    void step(bench::Events &ev)
    {
        if (useGraph()) BENCH_CUDA(cudaGraphLaunch(exec_, s_));
        else enqueue(ev, cudaEventRecordDefault);
    }
    bool needsResize() { return tree_->doBuffersNeedResize(); }
    void resize(bench::Events &ev)
    {
        discard();
        tree_->resizeBuffers();
        prepare(ev);
    }

    const bench::Key *P() { return reinterpret_cast<const bench::Key *>(thrust::raw_pointer_cast(tree_->particleKeys_d().data())); }
    std::size_t nP() { return tree_->particleKeys_d().size(); }
    const bench::Key *K() { return reinterpret_cast<const bench::Key *>(thrust::raw_pointer_cast(tree_->cornerstone_d().data())); }
    std::size_t nK() { return tree_->cornerstone_d().size(); }
    double libNodes() { return double(tree_->numNodes()); }
    int iterations() { return -1; }

private:
    // identical event placement for both paths (inside the graph for the graph path)
    void enqueue(bench::Events &ev, unsigned flags)
    {
        BENCH_CUDA(cudaEventRecordWithFlags(ev.begin, s_, flags));
        tree_->update();
        BENCH_CUDA(cudaEventRecordWithFlags(ev.treeEnd, s_, flags));
        tree_->computeViews(allViews);
        BENCH_CUDA(cudaEventRecordWithFlags(ev.end, s_, flags));
    }
    void discard()
    {
        if (exec_) cudaGraphExecDestroy(exec_);
        if (graph_) cudaGraphDestroy(graph_);
        exec_ = nullptr;
        graph_ = nullptr;
    }
    cudaStream_t s_;
    std::unique_ptr<Tree> tree_;
    cudaGraph_t graph_{};
    cudaGraphExec_t exec_{};
};

int main(int argc, char **argv)
{
    for (int i = 1; i + 1 < argc; ++i)
        if (std::string(argv[i]) == "--config" && std::string(argv[i + 1]) == "kdtree3d_leafcount")
            return bench::runDriver<V3<ao::TreeType::Binary>>(argc, argv);
    return bench::runDriver<V3<ao::TreeType::Octree>>(argc, argv);
}
