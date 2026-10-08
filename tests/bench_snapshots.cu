// bench_snapshots.cu

#include <cuda_runtime.h>
#include <thrust/count.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/equal.h>
#include <thrust/functional.h>
#include <thrust/host_vector.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/reduce.h>
#include <thrust/transform_reduce.h>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <future>
#include <iomanip>
#include <iostream>
#include <memory>
#include <map>
#include <regex>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include "adaptive_octree/config.hpp"
#include "adaptive_octree/tree.hpp"
#include "particle_io.hpp"
#include "../src/kdtree3d/binary_node.cuh"

#ifdef ADAPTIVE_OCTREE_BENCH_CSV
#include <fstream>
#endif

using Clock = std::chrono::steady_clock;

// Expand bounds using active particles only. An entirely escaped snapshot
// contributes no bounds, but other snapshots may still establish the domain.
bool extendBoundingBox(const std::vector<double> &x,
                       const std::vector<double> &y,
                       const std::vector<double> &z,
                       adaptive_octree::Box<double> &box)
{
    if (x.empty() || x.size() != y.size() || x.size() != z.size())
        throw std::invalid_argument("Cannot compute bounds for empty or mismatched coordinates");
    bool hasActiveParticles = false;
    for (size_t i = 0; i < x.size(); ++i)
    {
        if (adaptive_octree::isEscapedParticle(x[i], y[i], z[i]))
            continue;
        hasActiveParticles = true;
        box.xmin = std::min(box.xmin, x[i]);
        box.xmax = std::max(box.xmax, x[i]);
        box.ymin = std::min(box.ymin, y[i]);
        box.ymax = std::max(box.ymax, y[i]);
        box.zmin = std::min(box.zmin, z[i]);
        box.zmax = std::max(box.zmax, z[i]);
    }
    return hasActiveParticles;
}

// ============================================================================
// GPU timing
// ============================================================================

template <class F>
double timeGpu(F &&f)
{
    ADAPTIVE_OCTREE_CHECK_CUDA(cudaDeviceSynchronize());

    const auto begin = Clock::now();

    f();

    ADAPTIVE_OCTREE_CHECK_CUDA(cudaDeviceSynchronize());

    const auto end = Clock::now();

    return std::chrono::duration<double, std::milli>(end - begin).count();
}

// ============================================================================
// Snapshot filename
// ============================================================================

struct Dataset
{
    std::string path;
    bool series;
    particle_io::Layout layout = particle_io::Layout::XYZCharge;
    std::string pattern;
    std::map<int, std::string> frames;
    adaptive_octree::Box<double> box;
};

Dataset selectDataset(const std::string &path, int lastSnapshot, int stride)
{
    Dataset dataset{
        std::filesystem::absolute(path).string(),
        std::filesystem::is_directory(path)};

    if (!dataset.series)
    {
        if (!std::filesystem::is_regular_file(path))
            throw std::invalid_argument("Dataset does not exist: " + path);

        dataset.frames.emplace(0, dataset.path);
        return dataset;
    }

    const std::regex simdata(R"(xyz_([0-9]+))");
    const std::regex coulomb(R"(snapshot_([0-9]{6})\.dat)");
    const std::regex cluster(R"(cluster-([0-9]{4})\.dat)");

    for (const auto &entry : std::filesystem::directory_iterator(dataset.path))
    {
        if (!entry.is_regular_file())
            continue;

        const auto name = entry.path().filename().string();

        std::smatch match;
        std::string pattern;

        if (std::regex_match(name, match, simdata))
        {
            pattern = "xyz_{snapshot}";
        }
        else if (std::regex_match(name, match, coulomb))
        {
            pattern = "snapshot_{snapshot:06d}.dat";
        }
        else if (std::regex_match(name, match, cluster))
        {
            pattern = "cluster-{snapshot:04d}.dat";
        }
        else
        {
            continue;
        }

        if (!dataset.pattern.empty() && dataset.pattern != pattern)
            throw std::invalid_argument(
                "Mixed snapshot formats in: " + path);

        dataset.pattern = pattern;

        const int snapshot = std::stoi(match[1].str());

        if (snapshot <= lastSnapshot && snapshot % stride == 0)
            dataset.frames.emplace(snapshot, entry.path().string());
    }

    if (dataset.frames.empty())
        throw std::invalid_argument(
            "No selected snapshot frames in: " + path);

    if (dataset.pattern == "snapshot_{snapshot:06d}.dat" ||
        dataset.pattern == "cluster-{snapshot:04d}.dat")
    {
        dataset.layout = particle_io::Layout::ChargeXYZ;
    }

    return dataset;
}

// A captured update keeps its box fixed. Cover every selected snapshot, not
// just the initial cloud, which may expand substantially during the simulation.
adaptive_octree::Box<double> computeSeriesBoundingBox(
    const std::vector<double> &x, const std::vector<double> &y,
    const std::vector<double> &z, const Dataset &dataset)
{
    constexpr double maxCoordinate = std::numeric_limits<double>::max();
    adaptive_octree::Box<double> box{maxCoordinate, -maxCoordinate,
        maxCoordinate, -maxCoordinate, maxCoordinate, -maxCoordinate};
    bool hasActiveParticles = extendBoundingBox(x, y, z, box);
    std::cout << "Scanning bounds for " << dataset.frames.size()
              << " snapshots (outside benchmark timings)...\n" << std::flush;
    for (auto it = std::next(dataset.frames.begin()); it != dataset.frames.end(); ++it)
    {
        const auto &[snapshot, path] = *it;
        auto [sx, sy, sz] = particle_io::readParticles(
            path, dataset.layout);
        if (sx.size() != x.size())
            throw std::runtime_error("Particle slot count changed in snapshot " +
                std::to_string(snapshot) + "; preserve escaped slots with ESC rows");
        hasActiveParticles = extendBoundingBox(sx, sy, sz, box) || hasActiveParticles;
        if (snapshot % 100 == 0)
            std::cout << "  Bounds scanned through snapshot " << snapshot << '\n' << std::flush;
    }
    if (!hasActiveParticles)
        throw std::invalid_argument(
            "Cannot infer bounds: selected snapshots contain no active particles");
    // Pad each axis independently; retain a positive extent for flat clouds.
    const auto pad = [](double &lo, double &hi)
    {
        const double margin = std::max(adaptive_octree::defaults::domainPadding * (hi - lo),
            8 * std::numeric_limits<double>::epsilon() *
                std::max({1.0, std::abs(lo), std::abs(hi)}));
        lo -= margin;
        hi += margin;
    };
    pad(box.xmin, box.xmax);
    pad(box.ymin, box.ymax);
    pad(box.zmin, box.zmax);
    return box;
}

// ============================================================================
// Snapshot statistics
// ============================================================================

const char *treeTypeName(adaptive_octree::TreeType type)
{
    return type == adaptive_octree::TreeType::Binary ? "binary" : "octree";
}

const char *splitCriterionName(adaptive_octree::SplitCriterion criterion)
{
    return criterion == adaptive_octree::SplitCriterion::LeafCount ? "leafcount" : "nfcount";
}

struct SnapshotStats
{
    adaptive_octree::TreeType treeType = adaptive_octree::TreeType::Binary;
    adaptive_octree::SplitCriterion splitCriterion = adaptive_octree::SplitCriterion::LeafCount;
    std::size_t numParticleSlots = 0;
    std::size_t numActiveParticles = 0;
    std::size_t numEscapedParticles = 0;
    std::size_t numNodes = 0;
    std::size_t numLeaves = 0;
    std::size_t numEmptyLeaves = 0;

    double avgParticlesPerLeaf = 0.0;
    unsigned maxDepth = 0;
};

template <adaptive_octree::TreeType Kind>
struct TreeDepth
{
    const adaptive_octree::KeyType *keys;

    __host__ __device__ unsigned operator()(std::size_t leaf) const
    {
        return Kind == adaptive_octree::TreeType::Binary
            ? adaptive_octree::detail::kdtree3d::binaryDepth(keys[leaf], keys[leaf + 1])
            : adaptive_octree::detail::treeLevel(keys[leaf + 1] - keys[leaf]);
    }
};

template <class Real, adaptive_octree::TreeType Kind>
SnapshotStats computeSnapshotStats(const adaptive_octree::Tree<Real, Kind> &tree)
{
    SnapshotStats stats;
    stats.treeType = tree.type();
    stats.splitCriterion = tree.splitCriterion();
    stats.numParticleSlots = tree.numParticles();
    stats.numActiveParticles = tree.numActiveParticles();
    stats.numEscapedParticles = stats.numParticleSlots - stats.numActiveParticles;
    const auto &K = tree.cornerstone_d();
    const auto &N = tree.leafCounts_d();
    stats.numLeaves = N.size();
    const unsigned children = tree.type() == adaptive_octree::TreeType::Binary ? 2 : 8;
    stats.numNodes = stats.numLeaves + (stats.numLeaves - 1) / (children - 1);
    const auto begin = thrust::make_counting_iterator(std::size_t{0});
    stats.maxDepth = thrust::transform_reduce(thrust::device, begin, begin + N.size(),
        TreeDepth<Kind>{thrust::raw_pointer_cast(K.data())}, 0u, thrust::maximum<unsigned>());
    stats.numEmptyLeaves = thrust::count(thrust::device, N.begin(), N.end(), 0u);
    const auto particles = thrust::reduce(thrust::device, N.begin(), N.end(),
        std::uint64_t{0}, thrust::plus<std::uint64_t>());
    if (particles != stats.numActiveParticles)
        throw std::runtime_error("Leaf counts do not match the active particle count");
    if (stats.numLeaves)
        stats.avgParticlesPerLeaf = double(particles) / stats.numLeaves;
    return stats;
}

// ============================================================================
// Statistics output
// ============================================================================

#ifndef ADAPTIVE_OCTREE_BENCH_CSV

void printSnapshotStats(const SnapshotStats &stats)
{
    const double emptyPercent =
        stats.numLeaves == 0 ? 0.0
                             : 100.0 * static_cast<double>(stats.numEmptyLeaves) /
                                   static_cast<double>(stats.numLeaves);

    std::cout << "  Active particles   : " << stats.numActiveParticles << '\n'
              << "  Escaped particles  : " << stats.numEscapedParticles << '\n'
              << "  Particle slots     : " << stats.numParticleSlots << '\n'
              << "  Nodes              : " << stats.numNodes << '\n'
              << "  Leaves             : " << stats.numLeaves << '\n'
              << "  Empty leaves       : " << stats.numEmptyLeaves << " ("
              << std::fixed << std::setprecision(2) << emptyPercent << "%)\n"
              << "  Avg particles/leaf : " << stats.avgParticlesPerLeaf << '\n'
              << "  Max depth          : " << stats.maxDepth << '\n'
              << std::defaultfloat;
}

#endif

template <adaptive_octree::TreeType Kind>
void exportTreeFrame(int snapshot, const adaptive_octree::Tree<double, Kind> &tree,
                     const adaptive_octree::Box<double> &box,
                     const adaptive_octree::detail::kdtree3d::BinaryGeometry &geometry,
                     const std::string &outputDir, std::ostream &frameSummary)
{
    std::filesystem::create_directories(outputDir);

    std::ostringstream filename;
    filename << outputDir << "/tree_" << std::setw(6) << std::setfill('0')
             << snapshot << ".csv";

    std::ofstream out(filename.str());

    if (!out)
    {
        throw std::runtime_error("Could not open tree frame: " + filename.str());
    }

    // Export leaf bounds from K; view arrays are benchmarked separately.
    const thrust::host_vector<adaptive_octree::KeyType> keys = tree.cornerstone_d();
    const thrust::host_vector<unsigned> counts = tree.leafCounts_d();
    const double lower[] = {box.xmin, box.ymin, box.zmin};
    const double extent[] = {box.xmax - box.xmin, box.ymax - box.ymin, box.zmax - box.zmin};
    double coordinateScale[3]{};
    if constexpr (Kind == adaptive_octree::TreeType::Octree)
    {
        const adaptive_octree::detail::Box<double> sfcBox(
            box.xmin, box.xmax, box.ymin, box.ymax, box.zmin, box.zmax);
        const auto bits = sfcBox.boxDimBits<adaptive_octree::KeyType>();
        coordinateScale[0] = std::ldexp(1.0, -int(bits.x));
        coordinateScale[1] = std::ldexp(1.0, -int(bits.y));
        coordinateScale[2] = std::ldexp(1.0, -int(bits.z));
    }
    const TreeDepth<Kind> depthOf{keys.data()};
    out << std::setprecision(std::numeric_limits<double>::max_digits10)
        << "node,depth,split,particle_count,xmin,xmax,ymin,ymax,zmin,zmax,key_begin,key_end\n";
    for (std::size_t leaf = 0; leaf < counts.size(); ++leaf)
    {
        const unsigned depth = depthOf(leaf);
        adaptive_octree::detail::kdtree3d::BinaryBox bounds;
        if constexpr (Kind == adaptive_octree::TreeType::Binary)
            bounds = adaptive_octree::detail::kdtree3d::binaryBox(keys[leaf], keys[leaf + 1], geometry);
        else
        {
            const auto cell = adaptive_octree::detail::sfcIBox(keys[leaf], depth, false);
            const int lo[] = {cell.xmin(), cell.ymin(), cell.zmin()};
            const int hi[] = {cell.xmax(), cell.ymax(), cell.zmax()};
            for (unsigned axis = 0; axis < 3; ++axis)
            {
                bounds.min[axis] = lo[axis] * coordinateScale[axis];
                bounds.size[axis] = (hi[axis] - lo[axis]) * coordinateScale[axis];
            }
        }
        out << leaf << ',' << depth << ",0," << counts[leaf];
        for (unsigned axis = 0; axis < 3; ++axis)
            out << ',' << lower[axis] + extent[axis] * bounds.min[axis]
                << ',' << lower[axis] + extent[axis] * (bounds.min[axis] + bounds.size[axis]);
        out << ',' << keys[leaf] << ',' << keys[leaf + 1] << '\n';
    }
    // Per-frame totals belong in a small index, rather than being repeated for
    // every node. Always write the current status refreshed after this update.
    frameSummary << snapshot << ',' << tree.numParticles() << ','
                 << tree.numActiveParticles() << ','
                 << tree.numParticles() - tree.numActiveParticles() << '\n';
}

// Written once per run so the plotting tools know the tree's bounding box
// and how to locate/parse the particle data (single file vs. snapshot series).
void exportDomainMeta(const adaptive_octree::Box<double> &box,
                      const std::string &outputDir,
                      const Dataset &dataset, adaptive_octree::TreeType treeType,
                      adaptive_octree::SplitCriterion criterion)
{
    std::filesystem::create_directories(outputDir);

    std::ofstream out(outputDir + "/domain.csv");

    if (!out)
    {
        throw std::runtime_error("Could not open domain.csv in: " + outputDir);
    }

    out << std::setprecision(std::numeric_limits<double>::max_digits10)
        << "xmin,xmax,ymin,ymax,zmin,zmax,dataset_kind,particle_path,particle_pattern,particle_layout,snapshots,tree_type,tree_xmin,tree_xmax,tree_ymin,tree_ymax,tree_zmin,tree_zmax,split_criterion\n"
        << box.xmin << ',' << box.xmax << ',' << box.ymin << ',' << box.ymax
        << ',' << box.zmin << ',' << box.zmax << ',' << (dataset.series ? "series" : "single") << ',';
    // CSV quote paths, including embedded quotes and commas.
    out << '"';
    for (char c : dataset.path) { if (c == '"') out << '"'; out << c; }
    out << "\"," << dataset.pattern << ','
        << (dataset.layout == particle_io::Layout::ChargeXYZ ? "charge_xyz" : "xyz_charge") << ',';
    bool first = true;
    for (const auto &[snapshot, path] : dataset.frames)
    {
        if (snapshot != dataset.frames.begin()->first && snapshot % adaptive_octree::defaults::frameStride != 0) continue;
        if (!first) out << ';';
        out << snapshot;
        first = false;
    }
    out << ',' << treeTypeName(treeType);
    double scale[3] = {1, 1, 1};
    if (treeType == adaptive_octree::TreeType::Octree)
    {
        const adaptive_octree::detail::Box<double> sfcBox(
            box.xmin, box.xmax, box.ymin, box.ymax, box.zmin, box.zmax);
        const auto bits = sfcBox.boxDimBits<adaptive_octree::KeyType>();
        scale[0] = std::ldexp(1.0, 21 - int(bits.x));
        scale[1] = std::ldexp(1.0, 21 - int(bits.y));
        scale[2] = std::ldexp(1.0, 21 - int(bits.z));
    }
    const double lo[] = {box.xmin, box.ymin, box.zmin};
    const double hi[] = {box.xmax, box.ymax, box.zmax};
    for (unsigned axis = 0; axis < 3; ++axis)
        out << ',' << lo[axis] << ',' << lo[axis] + (hi[axis] - lo[axis]) * scale[axis];
    out << ',' << splitCriterionName(criterion) << '\n';
}

template <adaptive_octree::TreeType Kind>
using Tree = adaptive_octree::Tree<double, Kind>;


struct Timings
{
    double tree = 0, view = 0, total = 0, maintenance = 0;
    bool needsResize = false;

    void add(const Timings &other)
    {
        tree += other.tree;
        view += other.view;
        total += other.total;
        maintenance += other.maintenance;
    }
};

// Identical event markers and work for both paths. Wall time includes launching,
// completion, and the status readback; phase times use GPU events. Resizing and
// graph recording are reported separately, never hidden inside replay timings.
template <adaptive_octree::TreeType Kind>
class UpdateBenchmark
{
public:
    UpdateBenchmark(Tree<Kind> &tree, cudaStream_t stream, bool useGraph)
        : tree_(tree), stream_(stream), useGraph_(useGraph)
    {
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventCreate(&begin_));
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventCreate(&treeEnd_));
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventCreate(&end_));
    }
    ~UpdateBenchmark()
    {
        discardGraph();
        cudaEventDestroy(begin_);
        cudaEventDestroy(treeEnd_);
        cudaEventDestroy(end_);
    }

    double record()
    {
        return timeGpu([&]
        {
            ADAPTIVE_OCTREE_CHECK_CUDA(cudaStreamBeginCapture(stream_, cudaStreamCaptureModeGlobal));
            enqueue();
            ADAPTIVE_OCTREE_CHECK_CUDA(cudaStreamEndCapture(stream_, &graph_));
            ADAPTIVE_OCTREE_CHECK_CUDA(cudaGraphInstantiate(&executable_, graph_, 0));
            ADAPTIVE_OCTREE_CHECK_CUDA(cudaGraphUpload(executable_, stream_));
        });
    }

    Timings run()
    {
        Timings result;
        result.total = timeGpu([&]
        {
            if (useGraph_)
                ADAPTIVE_OCTREE_CHECK_CUDA(cudaGraphLaunch(executable_, stream_));
            else
                enqueue();
            result.needsResize = tree_.doBuffersNeedResize();
        });
        float treeMs, viewMs;
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventElapsedTime(&treeMs, begin_, treeEnd_));
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventElapsedTime(&viewMs, treeEnd_, end_));
        result.tree = treeMs;
        result.view = viewMs;
        return result;
    }

    double resize()
    {
        const double growth = timeGpu([&]
        {
            discardGraph();
            tree_.resizeBuffers();
        });
        return growth + (useGraph_ ? record() : 0.0);
    }

private:
    void enqueue()
    {
        // External event nodes retain actual timestamps during graph replay.
        const unsigned flags = useGraph_ ? cudaEventRecordExternal : cudaEventRecordDefault;
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventRecordWithFlags(begin_, stream_, flags));
        tree_.update();
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventRecordWithFlags(treeEnd_, stream_, flags));
        tree_.computeViews({true, true, true});
        ADAPTIVE_OCTREE_CHECK_CUDA(cudaEventRecordWithFlags(end_, stream_, flags));
    }
    void discardGraph()
    {
        if (executable_) cudaGraphExecDestroy(executable_);
        if (graph_) cudaGraphDestroy(graph_);
        executable_ = nullptr;
        graph_ = nullptr;
    }
    Tree<Kind> &tree_;
    cudaStream_t stream_;
    bool useGraph_;
    cudaEvent_t begin_{}, treeEnd_{}, end_{};
    cudaGraph_t graph_{};
    cudaGraphExec_t executable_{};
};

struct Comparison
{
    Timings direct, graph;
};

void printTimings(const Comparison &timings)
{
    std::cout << "  Ordinary: tree " << timings.direct.tree << " ms, view "
              << timings.direct.view << " ms, total " << timings.direct.total << " ms\n"
              << "  Graph:    tree " << timings.graph.tree << " ms, view "
              << timings.graph.view << " ms, total " << timings.graph.total << " ms\n"
              << "  Maintenance (ordinary / graph): " << timings.direct.maintenance
              << " / " << timings.graph.maintenance << " ms\n";
}

template <adaptive_octree::TreeType Kind>
Comparison compareUpdates(UpdateBenchmark<Kind> &direct, UpdateBenchmark<Kind> &graph, bool graphFirst)
{
    Comparison total;
    for (;;)
    {
        Timings a, b;
        // Alternate order to avoid giving either mode every warm-cache run.
        if (graphFirst) { b = graph.run(); a = direct.run(); }
        else { a = direct.run(); b = graph.run(); }
        total.direct.add(a);
        total.graph.add(b);
        if (a.needsResize != b.needsResize)
            throw std::runtime_error("Graph and ordinary update disagree on capacity");
        if (!a.needsResize) return total;
        // Both trees advance through the same capacities and retry count.
        total.direct.maintenance += direct.resize();
        total.graph.maintenance += graph.resize();
    }
}

template <adaptive_octree::TreeType Kind>
void checkMatchingTrees(const Tree<Kind> &a, const Tree<Kind> &b)
{
    // Exact checks outside the measurements; topology/statistics plots are shared.
    auto same = [](const auto &x, const auto &y)
    {
        return x.size() == y.size() && thrust::equal(thrust::device, x.begin(), x.end(), y.begin());
    };
    if (a.numParticles() != b.numParticles() || a.numActiveParticles() != b.numActiveParticles() ||
        !same(a.particleKeys_d(), b.particleKeys_d()) || !same(a.perm_d(), b.perm_d()) ||
        !same(a.cornerstone_d(), b.cornerstone_d()) || !same(a.leafCounts_d(), b.leafCounts_d()))
        throw std::runtime_error("Graph and ordinary update produced different trees");
    if constexpr (Kind == adaptive_octree::TreeType::Octree)
    {
        if (a.splitCriterion() == adaptive_octree::SplitCriterion::NFCount &&
            !same(a.nearFieldCounts_d(), b.nearFieldCounts_d()))
            throw std::runtime_error("Graph and ordinary update produced different near-field counts");
    }
    if (a.numNodes() != b.numNodes() ||
        !same(a.sfcBoxIndex_d(), b.sfcBoxIndex_d()) ||
        !same(a.hasBoxSplit_d(), b.hasBoxSplit_d()) ||
        !same(a.boxDepth_d(), b.boxDepth_d()) ||
        !same(a.parentIndex_d(), b.parentIndex_d()) ||
        !same(a.childIndex_d(), b.childIndex_d()) ||
        !same(a.levelOffset_d(), b.levelOffset_d()) ||
        !same(a.particleBeginIndex_d(), b.particleBeginIndex_d()) ||
        !same(a.particleCounts_d(), b.particleCounts_d()) ||
        !same(a.sfcParticleIndex_d(), b.sfcParticleIndex_d()))
        throw std::runtime_error("Graph and ordinary update produced different views");
}

#ifdef ADAPTIVE_OCTREE_BENCH_CSV

void writeCsvRow(std::ostream &out, int snapshot, double h2d, double initTree,
                 double treeTime, double viewTime, double computeTotal,
                 double totalWithH2D, const SnapshotStats &stats,
                 const Comparison *comparison = nullptr, double initialCapture = 0)
{
    const double emptyPercent = stats.numLeaves == 0 ? 0.0
        : 100.0 * static_cast<double>(stats.numEmptyLeaves) / stats.numLeaves;
    const double missing = std::numeric_limits<double>::quiet_NaN();
    out << snapshot << ',' << h2d << ',' << initTree << ',' << treeTime << ','
        << viewTime << ',' << computeTotal << ',' << totalWithH2D << ','
        << stats.numNodes << ',' << stats.numLeaves << ',' << stats.numEmptyLeaves
        << ',' << emptyPercent << ',' << stats.avgParticlesPerLeaf << ','
        << stats.maxDepth << ','
        << (comparison ? comparison->graph.tree : missing) << ','
        << (comparison ? comparison->graph.view : missing) << ','
        << (comparison ? comparison->graph.total : missing) << ','
        << (comparison ? comparison->direct.maintenance : 0) << ','
        << (comparison ? comparison->graph.maintenance : 0) << ',' << initialCapture << ','
        << stats.numParticleSlots << ',' << stats.numActiveParticles << ','
        << stats.numEscapedParticles << ',' << treeTypeName(stats.treeType) << ','
        << splitCriterionName(stats.splitCriterion) << '\n';
}
#endif

template <adaptive_octree::TreeType Kind>
void runBenchmark(const Dataset &dataset, int repeats, unsigned limit,
                  adaptive_octree::SplitCriterion criterion, std::ostream &csv)
{
    const std::string run = std::string(treeTypeName(Kind)) + "_" + splitCriterionName(criterion);
    const std::string outputDir = "tree_frames/" + run;
    const bool series = dataset.series;
    const int firstSnapshot = dataset.frames.begin()->first;
    auto [x, y, z] = particle_io::readParticles(dataset.frames.begin()->second, dataset.layout);
    std::cout << "Benchmark: " << run << " (limit " << limit << ")\n"
              << "Dataset: " << dataset.path << "\nParticle slots: " << x.size() << '\n';
    typename Tree<Kind>::Config config;
    // Time topology and views separately: request all views explicitly below.
    // Leaving config.views disabled keeps update() limited to the tree phase.
    config.maxParticlesPerLeaf = limit;
    config.splitCriterion = criterion;
    config.box = dataset.box;
    const auto geometry = adaptive_octree::detail::kdtree3d::makeBinaryGeometry(config.box);

    thrust::device_vector<double> x_d, y_d, z_d;
    const double initialUpload = timeGpu([&] { x_d = x; y_d = y; z_d = z; });
    cudaStream_t stream;
    ADAPTIVE_OCTREE_CHECK_CUDA(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));
    config.stream = stream;
    {
        std::unique_ptr<Tree<Kind>> tree, graphTree;
        auto construct = [&](std::unique_ptr<Tree<Kind>> &out)
        {
            out = std::make_unique<Tree<Kind>>(thrust::raw_pointer_cast(x_d.data()),
                thrust::raw_pointer_cast(y_d.data()), thrust::raw_pointer_cast(z_d.data()),
                x.size(), config);
        };
        const double initTime = timeGpu([&] { construct(tree); });
        construct(graphTree);
        const double buildTime = timeGpu([&] { tree->build(); });
        graphTree->build();
        auto buildViews = [](Tree<Kind> &target)
        {
            target.computeViews({true, true, true});
            while (target.doBuffersNeedResize())
            {
                target.resizeBuffers();
                target.computeViews({true, true, true});
            }
        };
        // Prepare every view buffer before graph capture. Initial view time
        // includes allocation; incremental view times measure only GPU work.
        const double viewTime = timeGpu([&] { buildViews(*tree); });
        buildViews(*graphTree);
        checkMatchingTrees(*tree, *graphTree);

        UpdateBenchmark<Kind> direct(*tree, stream, false), graph(*graphTree, stream, true);
        const double initialCapture = graph.record();
        // Discard one warmup of both paths, including the first graph launch.
        compareUpdates(direct, graph, false);
        checkMatchingTrees(*tree, *graphTree);
        std::cout << "Initial " << treeTypeName(Kind) << " build: " << buildTime
                  << " ms; views: " << viewTime << " ms (wall, including preparation)\n"
                  << "Graph capture/instantiate: " << initialCapture << " ms\n"
                  << "Update tree/view phases: GPU time. Total: both phases + launch + completion + status check.\n"
                  << "Resize/recapture costs are reported separately.\n";

#ifdef ADAPTIVE_OCTREE_BENCH_CSV
        if (series)
            writeCsvRow(csv, firstSnapshot, initialUpload, initTime, buildTime,
                viewTime, buildTime + viewTime, initialUpload + initTime + buildTime + viewTime,
                computeSnapshotStats(*tree), nullptr, initialCapture);
#endif
        std::filesystem::create_directories(outputDir);
        std::ofstream frameSummary(outputDir + "/frames.csv");
        if (!frameSummary) throw std::runtime_error("Could not open tree_frames/frames.csv");
        frameSummary << "snapshot,num_particle_slots,num_active_particles,num_escaped_particles\n";
        exportTreeFrame(firstSnapshot, *tree, config.box, geometry, outputDir, frameSummary);

        if (!series)
        {
            Comparison average;
            for (int repeat = 0; repeat < repeats; ++repeat)
            {
                const auto result = compareUpdates(direct, graph, repeat % 2 != 0);
                average.direct.add(result.direct);
                average.graph.add(result.graph);
                checkMatchingTrees(*tree, *graphTree);
            }
            for (auto *timing : {&average.direct, &average.graph})
            {
                timing->tree /= repeats;
                timing->view /= repeats;
                timing->total /= repeats;
                timing->maintenance /= repeats;
            }
            std::cout << "Static dataset, mean of " << repeats << " warm updates:\n";
            printTimings(average);
#ifdef ADAPTIVE_OCTREE_BENCH_CSV
            writeCsvRow(csv, firstSnapshot, initialUpload, initTime, average.direct.tree,
                average.direct.view, average.direct.total, initialUpload + average.direct.total,
                computeSnapshotStats(*tree), &average, initialCapture);
#endif
        }
        else
        {
            auto readSnapshot = [&dataset](const std::string &path)
            {
                return particle_io::readParticles(path, dataset.layout);
            };
            auto frame = std::next(dataset.frames.begin());
            std::future<std::tuple<std::vector<double>, std::vector<double>, std::vector<double>>> nextParticles;
            if (frame != dataset.frames.end())
                nextParticles = std::async(std::launch::async, readSnapshot, frame->second);
            for (int step = 0; frame != dataset.frames.end(); ++frame, ++step)
            {
                const int snapshot = frame->first;
                auto [newX, newY, newZ] = nextParticles.get();
                const auto next = std::next(frame);
                if (next != dataset.frames.end())
                    nextParticles = std::async(std::launch::async, readSnapshot, next->second);
                if (newX.size() != x_d.size())
                    throw std::runtime_error("Particle slot count changed in snapshot " +
                        std::to_string(snapshot) + "; preserve escaped slots with ESC rows");
                const double upload = timeGpu([&] { x_d = newX; y_d = newY; z_d = newZ; });
                const auto result = compareUpdates(direct, graph, step % 2 != 0);
                checkMatchingTrees(*tree, *graphTree);
                const auto stats = computeSnapshotStats(*tree);
                if (snapshot % adaptive_octree::defaults::frameStride == 0)
                    exportTreeFrame(snapshot, *tree, config.box, geometry, outputDir, frameSummary);
#ifdef ADAPTIVE_OCTREE_BENCH_CSV
                writeCsvRow(csv, snapshot, upload, 0, result.direct.tree,
                    result.direct.view, result.direct.total, upload + result.direct.total, stats, &result);
#else
                std::cout << "Snapshot " << snapshot << ":\n";
                printTimings(result);
                printSnapshotStats(stats);
#endif
            }
        }
    }
    exportDomainMeta(config.box, outputDir, dataset, Kind, criterion);
    ADAPTIVE_OCTREE_CHECK_CUDA(cudaStreamDestroy(stream));
}

int main(int argc, char **argv)
{
    try
    {
        const std::string dataDir = std::filesystem::path(__FILE__).parent_path().string() + "/test_data/";
        std::string datasetPath;
        bool series = false;
        int lastSnapshot = std::numeric_limits<int>::max(), stride = adaptive_octree::defaults::snapshotStride, repeats = adaptive_octree::defaults::snapshotRepeats;
        int leafLimit = adaptive_octree::defaults::maxParticlesPerLeaf;
        int nfLimit = adaptive_octree::defaults::nearFieldLimit;
        std::string treeChoice = adaptive_octree::defaults::benchmarkTree;
        std::string criterionChoice = adaptive_octree::defaults::benchmarkCriterion;
        const char *usage = "Usage: bench_snapshots [--dataset FILE_OR_FOLDER] [--series|--halo] "
                            "[--last-snapshot N] [--stride N] [--repeats N] "
                            "[--leaf-limit N] [--nf-limit N] [--tree all|binary|octree] "
                            "[--criterion all|leafcount|nfcount]";
        for (int i = 1; i < argc; ++i)
        {
            const std::string arg = argv[i];
            if (arg == "--help") { std::cout << usage << '\n'; return 0; }
            if (arg == "--series") series = true;
            else if (arg == "--halo") series = false;
            else if (arg == "--tree" && i + 1 < argc)
            {
                treeChoice = argv[++i];
                if (treeChoice != "all" && treeChoice != "binary" && treeChoice != "octree")
                    throw std::invalid_argument("--tree must be all, binary, or octree");
            }
            else if (arg == "--criterion" && i + 1 < argc)
            {
                criterionChoice = argv[++i];
                if (criterionChoice != "all" && criterionChoice != "leafcount" && criterionChoice != "nfcount")
                    throw std::invalid_argument("--criterion must be all, leafcount, or nfcount");
            }
            else if (arg == "--dataset" && i + 1 < argc) datasetPath = argv[++i];
            else if ((arg == "--last-snapshot" || arg == "--stride" || arg == "--repeats" ||
                      arg == "--leaf-limit" || arg == "--nf-limit") && i + 1 < argc)
            {
                const int value = std::stoi(argv[++i]);
                if (arg == "--last-snapshot") lastSnapshot = value;
                else if (arg == "--stride") stride = value;
                else if (arg == "--repeats") repeats = value;
                else if (arg == "--leaf-limit") leafLimit = value;
                else nfLimit = value;
            }
            else throw std::invalid_argument(usage);
        }
        if (stride <= 0 || lastSnapshot < 0 || repeats <= 0 || leafLimit <= 0 || nfLimit <= 0)
            throw std::invalid_argument("Require positive stride/repeats/leaf-limit/nf-limit and nonnegative last-snapshot");
        if (treeChoice == "binary" && criterionChoice == "nfcount")
            throw std::invalid_argument("Binary NFCount is not implemented; use octree or LeafCount");
        if (datasetPath.empty()) datasetPath = dataDir + (series ? "simdata" : "halo_25600000.dat");
        auto dataset = selectDataset(datasetPath, lastSnapshot, stride);
        {
            auto [x, y, z] = particle_io::readParticles(dataset.frames.begin()->second, dataset.layout);
            dataset.box = computeSeriesBoundingBox(x, y, z, dataset);
        }

        std::ofstream csv;
#ifdef ADAPTIVE_OCTREE_BENCH_CSV
        csv.open("bench_snapshots.csv");
        if (!csv) throw std::runtime_error("Could not open bench_snapshots.csv");
        csv << "snapshot,h2d_ms,init_tree_ms,tree_ms,view_ms,compute_total_ms,total_with_h2d_ms,"
               "num_nodes,num_leaves,num_empty_leaves,empty_leaf_percent,avg_particles_per_leaf,"
               "max_depth,graph_tree_ms,graph_view_ms,"
               "graph_compute_total_ms,maintenance_ms,graph_maintenance_ms,graph_initial_capture_ms,"
               "num_particle_slots,num_active_particles,num_escaped_particles,tree_type,split_criterion\n";
#endif
        std::filesystem::create_directories("tree_frames");
        std::ofstream runs("tree_frames/runs.csv");
        if (!runs) throw std::runtime_error("Could not open tree_frames/runs.csv");
        runs << "run,tree_type,split_criterion\n";
        using adaptive_octree::SplitCriterion;
        using adaptive_octree::TreeType;
        if (treeChoice != "octree" && criterionChoice != "nfcount")
        {
            runBenchmark<TreeType::Binary>(dataset, repeats, unsigned(leafLimit), SplitCriterion::LeafCount, csv);
            runs << "binary_leafcount,binary,leafcount\n";
        }
        if (treeChoice != "binary")
        {
            for (auto criterion : {SplitCriterion::LeafCount, SplitCriterion::NFCount})
            {
                const std::string name = splitCriterionName(criterion);
                if (criterionChoice != "all" && criterionChoice != name) continue;
                const unsigned limit = criterion == SplitCriterion::LeafCount ? leafLimit : nfLimit;
                runBenchmark<TreeType::Octree>(dataset, repeats, limit, criterion, csv);
                runs << "octree_" << name << ",octree," << name << '\n';
            }
        }
    }
    catch (const std::exception &error)
    {
        std::cerr << "bench_snapshots: " << error.what() << '\n';
        return 1;
    }
}
