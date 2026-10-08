#include <catch2/catch_test_macros.hpp>

#include "adaptive_octree/tree.hpp"
#include "particle_io.hpp"

#include <cuda_runtime.h>
#include <thrust/copy.h>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <limits>
#include <memory>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

namespace test
{
void requireCuda(cudaError_t status)
{
    INFO(cudaGetErrorString(status));
    REQUIRE(status == cudaSuccess);
}

struct Stream
{
    Stream() { requireCuda(cudaStreamCreateWithFlags(&value, cudaStreamNonBlocking)); }
    ~Stream() { cudaStreamDestroy(value); }
    cudaStream_t value{};
};

struct Graph
{
    template <class Tree>
    Graph(Tree &tree, cudaStream_t stream) : stream(stream)
    {
        requireCuda(cudaStreamBeginCapture(stream, cudaStreamCaptureModeGlobal));
        tree.update();
        requireCuda(cudaStreamEndCapture(stream, &graph));
        requireCuda(cudaGraphInstantiate(&executable, graph, 0));
    }
    ~Graph()
    {
        cudaGraphExecDestroy(executable);
        cudaGraphDestroy(graph);
    }
    void replay() { requireCuda(cudaGraphLaunch(executable, stream)); }
    cudaStream_t stream{};
    cudaGraph_t graph{};
    cudaGraphExec_t executable{};
};

template <class T>
void requireSame(const thrust::device_vector<T> &a, const thrust::device_vector<T> &b,
                 const char *name = "array")
{
    INFO(name);
    const thrust::host_vector<T> left = a, right = b;
    REQUIRE(left.size() == right.size());
    for (std::size_t i = 0; i < left.size(); ++i)
    {
        INFO("index: " << i);
        REQUIRE(left[i] == right[i]);
    }
}
} // namespace test

// Octree reference arrays, escaped slots, NFCount, Hilbert, and views.
namespace octree_tests
{
using namespace test;

const std::filesystem::path testDataDir =
    std::filesystem::path(__FILE__).parent_path() / "verification_data";
const std::filesystem::path referenceDir = testDataDir / "reference_output";

// Reads a single-column "value\n<numbers>" reference CSV. Parsed as
// uint64_t (not long long): KeyType values can reach 2^63 (the root's
// sentinel upper bound), which overflows a signed 64-bit read.
std::vector<std::uint64_t> loadReferenceColumn(const std::string &name)
{
    std::ifstream in(referenceDir / (name + ".csv"));
    REQUIRE(in.is_open());

    std::string header;
    std::getline(in, header);

    std::vector<std::uint64_t> values;
    std::uint64_t v;
    while (in >> v)
        values.push_back(v);

    return values;
}

long long loadReferenceScalar(const std::string &name)
{
    std::ifstream in(referenceDir / "scalars.csv");
    REQUIRE(in.is_open());

    std::string header;
    std::getline(in, header);

    std::string line;
    while (std::getline(in, line))
    {
        const auto comma = line.find(',');
        if (line.substr(0, comma) == name)
            return std::stoll(line.substr(comma + 1));
    }

    FAIL("scalar not found in reference: " + name);
    return 0;
}

// Two's-complement reinterpretation so signed sentinels (e.g. NodeIndex's
// -1) compare equal to the wrapped-around unsigned value read from CSV.
template <class T>
std::uint64_t toU64(T v)
{
    if constexpr (std::is_signed_v<T>)
        return static_cast<std::uint64_t>(static_cast<std::int64_t>(v));
    else
        return static_cast<std::uint64_t>(v);
}

template <class T>
void compareArray(const std::string &name, const thrust::device_vector<T> &actual_d)
{
    const thrust::host_vector<T> actual = actual_d;
    const std::vector<std::uint64_t> expected = loadReferenceColumn(name);

    INFO("array: " << name);
    REQUIRE(actual.size() == expected.size());

    for (std::size_t i = 0; i < actual.size(); ++i)
    {
        INFO("index: " << i);
        REQUIRE(toU64(actual[i]) == expected[i]);
    }
}

TEST_CASE("Octree build+update matches known-good reference", "[regression]")
{
    auto [x0, y0, z0] = particle_io::readParticles(
        (testDataDir / "snapshot_0000.dat").string(), particle_io::Layout::ChargeXYZ);
    auto [x1, y1, z1] = particle_io::readParticles(
        (testDataDir / "snapshot_1000.dat").string(), particle_io::Layout::ChargeXYZ);

    REQUIRE(x1.size() == x0.size());

    thrust::device_vector<double> x_d(x0.begin(), x0.end());
    thrust::device_vector<double> y_d(y0.begin(), y0.end());
    thrust::device_vector<double> z_d(z0.begin(), z0.end());

    adaptive_octree::Octree<double> tree(
        thrust::raw_pointer_cast(x_d.data()),
        thrust::raw_pointer_cast(y_d.data()),
        thrust::raw_pointer_cast(z_d.data()),
        x0.size(),
        {.maxParticlesPerLeaf = 64 * 64 * 27,
         .splitCriterion = adaptive_octree::Octree<double>::SplitCriterion::NFCount,
         .views = {.treeStructure = true,
                   .particleCountsPerBox = true,
                   .particleMapping = true},
         .interactive = false});

    tree.build();

    thrust::copy(x1.begin(), x1.end(), x_d.begin());
    thrust::copy(y1.begin(), y1.end(), y_d.begin());
    thrust::copy(z1.begin(), z1.end(), z_d.begin());

    tree.update();
    unsigned resizeAttempts = 0;
    while (tree.doBuffersNeedResize())
    {
        REQUIRE(++resizeAttempts < 64);
        tree.resizeBuffers();
        tree.update();
    }

    compareArray("particleKeys_d", tree.particleKeys_d());
    compareArray("perm_d", tree.perm_d());
    compareArray("cornerstone_d", tree.cornerstone_d());
    compareArray("sfcBoxIndex_d", tree.sfcBoxIndex_d());
    compareArray("particleBeginIndex_d", tree.particleBeginIndex_d());
    compareArray("particleCounts_d", tree.particleCounts_d());
    compareArray("hasBoxSplit_d", tree.hasBoxSplit_d());
    compareArray("boxDepth_d", tree.boxDepth_d());
    compareArray("parentIndex_d", tree.parentIndex_d());
    compareArray("childIndex_d", tree.childIndex_d());
    compareArray("sfcParticleIndex_d", tree.sfcParticleIndex_d());
    compareArray("levelOffset_d", tree.levelOffset_d());

    REQUIRE(static_cast<long long>(tree.maxAchievedDepth()) == loadReferenceScalar("maxAchievedDepth"));
}

class TemporaryParticleFile
{
public:
    explicit TemporaryParticleFile(const std::string &contents)
    {
        static unsigned sequence = 0;
        const auto timestamp = std::chrono::steady_clock::now().time_since_epoch().count();
        path_ = std::filesystem::temp_directory_path() /
                ("octree-escaped-" + std::to_string(timestamp) + "-" +
                 std::to_string(sequence++) + ".dat");
        std::ofstream out(path_);
        REQUIRE(out.is_open());
        out << contents;
        REQUIRE(out.good());
    }

    ~TemporaryParticleFile()
    {
        std::error_code error;
        std::filesystem::remove(path_, error);
    }

    std::string path() const { return path_.string(); }

private:
    std::filesystem::path path_;
};

using EscapedTree = adaptive_octree::Octree<double>;
constexpr unsigned slotCount = 8;
constexpr unsigned allSlots = (1u << slotCount) - 1;

struct SlotCoordinates
{
    std::vector<double> x, y, z;
};

SlotCoordinates coordinatesForMask(unsigned activeSlots, bool compact = false)
{
    SlotCoordinates coordinates;
    for (unsigned slot = 0; slot < slotCount; ++slot)
    {
        const bool active = (activeSlots & (1u << slot)) != 0;
        if (!active && compact)
            continue;
        const double escaped = adaptive_octree::escapedParticleCoordinate<double>;
        coordinates.x.push_back(active ? ((slot & 1u) ? 0.75 : 0.25) : escaped);
        coordinates.y.push_back(active ? ((slot & 2u) ? 0.75 : 0.25) : escaped);
        coordinates.z.push_back(active ? ((slot & 4u) ? 0.75 : 0.25) : escaped);
    }
    return coordinates;
}

EscapedTree::Config escapedConfig(EscapedTree::SfcKind sfc,
                                  EscapedTree::SplitCriterion criterion,
                                  cudaStream_t stream)
{
    EscapedTree::Config config;
    config.sfcKind = sfc;
    config.splitCriterion = criterion;
    config.maxParticlesPerLeaf = criterion == EscapedTree::SplitCriterion::NFCount ? 27 : 1;
    config.updateIterations = 4;
    config.views = {true, true, true};
    config.stream = stream;
    config.interactive = false;
    return config;
}

void requireSameTree(const EscapedTree &a, const EscapedTree &b, bool compareParticles)
{
    requireSame(a.cornerstone_d(), b.cornerstone_d(), "cornerstone");
    requireSame(a.leafCounts_d(), b.leafCounts_d(), "leaf counts");
    if (a.splitCriterion() == EscapedTree::SplitCriterion::NFCount)
        requireSame(a.nearFieldCounts_d(), b.nearFieldCounts_d(), "near-field counts");
    requireSame(a.sfcBoxIndex_d(), b.sfcBoxIndex_d(), "box SFC");
    requireSame(a.particleCounts_d(), b.particleCounts_d(), "box counts");
    requireSame(a.particleBeginIndex_d(), b.particleBeginIndex_d(), "box begin");
    requireSame(a.hasBoxSplit_d(), b.hasBoxSplit_d(), "split flags");
    requireSame(a.boxDepth_d(), b.boxDepth_d(), "depth");
    requireSame(a.parentIndex_d(), b.parentIndex_d(), "parents");
    requireSame(a.childIndex_d(), b.childIndex_d(), "children");
    requireSame(a.levelOffset_d(), b.levelOffset_d(), "level offsets");
    requireSame(a.sfcParticleIndex_d(), b.sfcParticleIndex_d(), "particle mapping");
    if (compareParticles)
    {
        requireSame(a.particleKeys_d(), b.particleKeys_d(), "particle keys");
        requireSame(a.perm_d(), b.perm_d(), "permutation");
    }
}

void requireEscapedState(EscapedTree &tree, unsigned activeSlots)
{
    REQUIRE_FALSE(tree.doBuffersNeedResize());
    const unsigned activeCount = std::popcount(activeSlots);
    REQUIRE(tree.numParticles() == slotCount);
    REQUIRE(tree.numActiveParticles() == activeCount);
    using ActiveCount = std::remove_cv_t<std::remove_pointer_t<decltype(tree.numActiveParticles_d())>>;
    ActiveCount deviceActiveCount{};
    requireCuda(cudaMemcpy(&deviceActiveCount, tree.numActiveParticles_d(),
                           sizeof(deviceActiveCount), cudaMemcpyDeviceToHost));
    REQUIRE(deviceActiveCount == activeCount);

    const thrust::host_vector<adaptive_octree::KeyType> keys = tree.particleKeys_d();
    const thrust::host_vector<adaptive_octree::PermIndex> permutation = tree.perm_d();
    const thrust::host_vector<unsigned> counts = tree.particleCounts_d();
    const thrust::host_vector<unsigned> begins = tree.particleBeginIndex_d();
    const thrust::host_vector<unsigned> leafCounts = tree.leafCounts_d();
    const thrust::host_vector<std::uint8_t> split = tree.hasBoxSplit_d();
    const thrust::host_vector<adaptive_octree::KeyType> mapping = tree.sfcParticleIndex_d();
    REQUIRE(keys.size() == slotCount);
    REQUIRE(permutation.size() == slotCount);
    REQUIRE(mapping.size() == activeCount);
    REQUIRE(counts.size() == tree.numNodes() + 1);
    REQUIRE(counts.front() == activeCount);
    REQUIRE(counts.back() == activeCount);
    REQUIRE(std::accumulate(leafCounts.begin(), leafCounts.end(), 0u) == activeCount);
    REQUIRE(std::is_sorted(keys.begin(), keys.end()));

    std::array<bool, slotCount> seen{};
    for (unsigned p = 0; p < slotCount; ++p)
    {
        INFO("sorted particle: " << p);
        const auto slot = permutation[p];
        REQUIRE(slot < slotCount);
        REQUIRE_FALSE(seen[slot]);
        seen[slot] = true;
        if (p < activeCount)
        {
            REQUIRE((activeSlots & (1u << slot)) != 0);
            REQUIRE(keys[p] < (adaptive_octree::KeyType{1} << 63));
            const auto node = mapping[p];
            REQUIRE(node < tree.numNodes());
            REQUIRE(split[node] == 0);
            REQUIRE(begins[node] <= p);
            REQUIRE(p < begins[node] + counts[node]);
        }
        else
        {
            REQUIRE((activeSlots & (1u << slot)) == 0);
            REQUIRE(keys[p] == adaptive_octree::invalidParticleKey);
        }
    }

    // The public mapping is trimmed, but captured kernels retain its original
    // allocation and write a sentinel into every inactive backing slot.
    REQUIRE(tree.sfcParticleIndex_d().capacity() >= slotCount);
    std::array<adaptive_octree::KeyType, slotCount> backing{};
    requireCuda(cudaMemcpy(backing.data(),
                           thrust::raw_pointer_cast(tree.sfcParticleIndex_d().data()),
                           sizeof(backing), cudaMemcpyDeviceToHost));
    for (unsigned p = activeCount; p < slotCount; ++p)
        REQUIRE(backing[p] == adaptive_octree::invalidParticleNodeIndex);
}

TEST_CASE("ESC input rows preserve slots in both particle layouts", "[escaped][reader]")
{
    for (const auto layout : {particle_io::Layout::ChargeXYZ, particle_io::Layout::XYZCharge})
    {
        INFO("layout: " << int(layout));
        const std::string first = layout == particle_io::Layout::ChargeXYZ ? "7 0.1 0.2 0.3" : "0.1 0.2 0.3 7";
        const std::string last = layout == particle_io::Layout::ChargeXYZ ? "9 0.4 0.5 0.6" : "0.4 0.5 0.6 9";
        TemporaryParticleFile input("# coordinates\r\n\n" + first + "\r\n \tESC # escaped\r\n" + last + "\nESC");
        const auto [x, y, z] = particle_io::readParticles(input.path(), layout);
        REQUIRE(x.size() == 4);
        REQUIRE(y.size() == x.size());
        REQUIRE(z.size() == x.size());
        REQUIRE(x[0] == 0.1);
        REQUIRE(y[0] == 0.2);
        REQUIRE(z[0] == 0.3);
        REQUIRE(x[2] == 0.4);
        REQUIRE(y[2] == 0.5);
        REQUIRE(z[2] == 0.6);
        for (const unsigned slot : {1u, 3u})
        {
            REQUIRE(x[slot] == std::numeric_limits<double>::max());
            REQUIRE(y[slot] == std::numeric_limits<double>::max());
            REQUIRE(z[slot] == std::numeric_limits<double>::max());
        }

        for (const std::string malformed : {"ESCX", "ESC 1", "1 2 3"})
        {
            INFO("malformed row: " << malformed);
            TemporaryParticleFile invalid(first + "\n" + malformed + "\nESC\n" + last);
            REQUIRE_THROWS_AS(particle_io::readParticles(invalid.path(), layout), std::runtime_error);
        }

        std::ostringstream numericMarker;
        numericMarker << std::setprecision(std::numeric_limits<double>::max_digits10);
        const double escaped = adaptive_octree::escapedParticleCoordinate<double>;
        if (layout == particle_io::Layout::ChargeXYZ)
            numericMarker << "1 " << escaped << ' ' << escaped << ' ' << escaped;
        else
            numericMarker << escaped << ' ' << escaped << ' ' << escaped << " 1";
        TemporaryParticleFile numeric(numericMarker.str());
        const auto [nx, ny, nz] = particle_io::readParticles(numeric.path(), layout);
        REQUIRE(nx.size() == 1);
        REQUIRE(adaptive_octree::isEscapedParticle(nx[0], ny[0], nz[0]));
    }
}

TEST_CASE("Octree build excludes escaped slots before the first split", "[escaped][gpu]")
{
    for (const auto sfc : {EscapedTree::SfcKind::Morton, EscapedTree::SfcKind::Hilbert})
        for (const auto criterion : {EscapedTree::SplitCriterion::LeafCount, EscapedTree::SplitCriterion::NFCount})
            for (const unsigned activeSlots : {0u, 0x08u, 0xb7u})
            {
                INFO("SFC: " << int(sfc) << ", criterion: " << int(criterion) << ", mask: " << activeSlots);
                Stream stream;
                const auto coordinates = coordinatesForMask(activeSlots);
                thrust::device_vector<double> x(coordinates.x), y(coordinates.y), z(coordinates.z);
                auto config = escapedConfig(sfc, criterion, stream.value);
                EscapedTree tree(thrust::raw_pointer_cast(x.data()), thrust::raw_pointer_cast(y.data()),
                                 thrust::raw_pointer_cast(z.data()), slotCount, config);
                tree.build();
                requireEscapedState(tree, activeSlots);

                if (std::popcount(activeSlots) <= 1)
                {
                    REQUIRE(tree.leafCounts_d().size() == 1);
                    if (criterion == EscapedTree::SplitCriterion::NFCount)
                    {
                        const thrust::host_vector<unsigned> nf = tree.nearFieldCounts_d();
                        REQUIRE(nf[0] == 27u * std::popcount(activeSlots));
                    }
                }
                if (activeSlots == 0)
                    continue;

                const auto compact = coordinatesForMask(activeSlots, true);
                thrust::device_vector<double> cx(compact.x), cy(compact.y), cz(compact.z);
                EscapedTree reference(thrust::raw_pointer_cast(cx.data()), thrust::raw_pointer_cast(cy.data()),
                                      thrust::raw_pointer_cast(cz.data()), compact.x.size(), config);
                reference.build();
                REQUIRE_FALSE(reference.doBuffersNeedResize());
                requireSameTree(tree, reference, false);
                const thrust::host_vector<adaptive_octree::KeyType> keys = tree.particleKeys_d();
                const thrust::host_vector<adaptive_octree::KeyType> expectedKeys = reference.particleKeys_d();
                REQUIRE(std::equal(expectedKeys.begin(), expectedKeys.end(), keys.begin()));
                const thrust::host_vector<adaptive_octree::PermIndex> perm = tree.perm_d();
                const thrust::host_vector<adaptive_octree::PermIndex> expectedPerm = reference.perm_d();
                std::vector<unsigned> activeIds;
                for (unsigned slot = 0; slot < slotCount; ++slot)
                    if (activeSlots & (1u << slot))
                        activeIds.push_back(slot);
                for (std::size_t p = 0; p < expectedPerm.size(); ++p)
                    REQUIRE(perm[p] == activeIds[expectedPerm[p]]);
            }
}

TEST_CASE("One captured octree update handles escape and reactivation", "[escaped][gpu][graph]")
{
    for (const auto sfc : {EscapedTree::SfcKind::Morton, EscapedTree::SfcKind::Hilbert})
        for (const auto criterion : {EscapedTree::SplitCriterion::LeafCount, EscapedTree::SplitCriterion::NFCount})
        {
            INFO("SFC: " << int(sfc) << ", criterion: " << int(criterion));
            Stream stream;
            const auto initial = coordinatesForMask(allSlots);
            thrust::device_vector<double> x(initial.x), y(initial.y), z(initial.z);
            auto config = escapedConfig(sfc, criterion, stream.value);
            const auto xPointer = thrust::raw_pointer_cast(x.data());
            const auto yPointer = thrust::raw_pointer_cast(y.data());
            const auto zPointer = thrust::raw_pointer_cast(z.data());
            EscapedTree ordinary(xPointer, yPointer, zPointer, slotCount, config);
            EscapedTree captured(xPointer, yPointer, zPointer, slotCount, config);
            ordinary.build();
            captured.build();
            requireEscapedState(ordinary, allSlots);
            requireEscapedState(captured, allSlots);
            const auto mappingPointer = thrust::raw_pointer_cast(captured.sfcParticleIndex_d().data());
            const auto keysPointer = thrust::raw_pointer_cast(captured.particleKeys_d().data());
            const auto permutationPointer = thrust::raw_pointer_cast(captured.perm_d().data());
            Graph graph(captured, stream.value);

            for (const unsigned activeSlots : {allSlots, allSlots ^ 0x08u, 0x91u, 0u, 0x04u, allSlots, 0u, allSlots})
            {
                INFO("active slot mask: " << activeSlots);
                const auto next = coordinatesForMask(activeSlots);
                requireCuda(cudaMemcpyAsync(xPointer, next.x.data(), slotCount * sizeof(double), cudaMemcpyHostToDevice, stream.value));
                requireCuda(cudaMemcpyAsync(yPointer, next.y.data(), slotCount * sizeof(double), cudaMemcpyHostToDevice, stream.value));
                requireCuda(cudaMemcpyAsync(zPointer, next.z.data(), slotCount * sizeof(double), cudaMemcpyHostToDevice, stream.value));
                ordinary.update();
                graph.replay();
                requireEscapedState(ordinary, activeSlots);
                requireEscapedState(captured, activeSlots);
                requireSameTree(ordinary, captured, true);
                REQUIRE(thrust::raw_pointer_cast(captured.sfcParticleIndex_d().data()) == mappingPointer);
                REQUIRE(thrust::raw_pointer_cast(captured.particleKeys_d().data()) == keysPointer);
                REQUIRE(thrust::raw_pointer_cast(captured.perm_d().data()) == permutationPointer);
                REQUIRE(thrust::raw_pointer_cast(x.data()) == xPointer);
                REQUIRE(thrust::raw_pointer_cast(y.data()) == yPointer);
                REQUIRE(thrust::raw_pointer_cast(z.data()) == zPointer);
            }
        }
}
} // namespace octree_tests

// Independent physical-bisection oracle and binary update invariants.
namespace binary_tests
{
using namespace test;

using Tree = adaptive_octree::KDTree3D<double>;
using Key = adaptive_octree::KeyType;
using Point = std::array<double, 3>;
constexpr Key rootEnd = Key{1} << 63;

struct Coordinates
{
    explicit Coordinates(std::size_t count) : x(count), y(count), z(count) {}
    void upload(const std::vector<Point> &points, cudaStream_t stream)
    {
        std::vector<double> hx, hy, hz;
        for (const auto &p : points)
        {
            hx.push_back(p[0]); hy.push_back(p[1]); hz.push_back(p[2]);
        }
        REQUIRE(points.size() == x.size());
        if (points.empty()) return;
        requireCuda(cudaMemcpyAsync(thrust::raw_pointer_cast(x.data()), hx.data(), hx.size() * sizeof(double), cudaMemcpyHostToDevice, stream));
        requireCuda(cudaMemcpyAsync(thrust::raw_pointer_cast(y.data()), hy.data(), hy.size() * sizeof(double), cudaMemcpyHostToDevice, stream));
        requireCuda(cudaMemcpyAsync(thrust::raw_pointer_cast(z.data()), hz.data(), hz.size() * sizeof(double), cudaMemcpyHostToDevice, stream));
        requireCuda(cudaStreamSynchronize(stream));
    }
    std::unique_ptr<Tree> tree(const Tree::Config &config)
    {
        return std::make_unique<Tree>(thrust::raw_pointer_cast(x.data()), thrust::raw_pointer_cast(y.data()),
                                      thrust::raw_pointer_cast(z.data()), x.size(), config);
    }
    thrust::device_vector<double> x, y, z;
};

Tree::Config configuration(cudaStream_t stream)
{
    Tree::Config c;
    c.stream = stream;
    c.maxParticlesPerLeaf = 3;
    return c;
}

Point escaped()
{
    const double e = adaptive_octree::escapedParticleCoordinate<double>;
    return {e, e, e};
}

std::vector<Point> particles(const adaptive_octree::Box<double> &box, int count = 65)
{
    std::vector<Point> result;
    for (int i = 0; i < count; ++i)
    {
        const double x = ((i * 173) % 1024) / 1024.0;
        const double y = ((i * 317) % 1024) / 1024.0;
        const double z = ((i * 563) % 1024) / 1024.0;
        result.push_back({box.xmin + x * (box.xmax - box.xmin),
                          box.ymin + y * (box.ymax - box.ymin),
                          box.zmin + z * (box.zmax - box.zmin)});
    }
    return result;
}

// Physical boxes and direct midpoint tests are independent of the production
// key encoder, axis schedule, and key-interval split/merge helpers.
struct Cell
{
    std::array<long double, 3> lower, upper;
    Key begin = 0, end = rootEnd;
    unsigned depth = 0;
};

Cell root(const adaptive_octree::Box<double> &box)
{
    return {{box.xmin, box.ymin, box.zmin}, {box.xmax, box.ymax, box.zmax}};
}

int longestAxis(const Cell &cell)
{
    int longest = 0;
    for (int axis = 1; axis < 3; ++axis)
        if (cell.upper[axis] - cell.lower[axis] > cell.upper[longest] - cell.lower[longest]) longest = axis;
    return longest;
}

std::array<Cell, 2> split(const Cell &cell)
{
    const int axis = longestAxis(cell);
    const long double middle = (cell.lower[axis] + cell.upper[axis]) / 2;
    const Key keyMiddle = cell.begin + (cell.end - cell.begin) / 2;
    Cell left = cell, right = cell;
    left.upper[axis] = right.lower[axis] = middle;
    left.end = right.begin = keyMiddle;
    ++left.depth; ++right.depth;
    return {left, right};
}

bool contains(const Cell &cell, const Point &point)
{
    for (int axis = 0; axis < 3; ++axis)
        if (point[axis] < cell.lower[axis] || point[axis] >= cell.upper[axis]) return false;
    return true;
}

unsigned count(const Cell &cell, const std::vector<Point> &points)
{
    return std::count_if(points.begin(), points.end(), [&](const auto &p) { return contains(cell, p); });
}

Key particleKey(const Point &point, const adaptive_octree::Box<double> &box)
{
    if (adaptive_octree::isEscapedParticle(point[0], point[1], point[2]))
        return adaptive_octree::invalidParticleKey;
    Cell cell = root(box);
    while (cell.depth < 63)
    {
        const int axis = longestAxis(cell);
        const auto children = split(cell);
        cell = children[point[axis] >= children[1].lower[axis]];
    }
    return cell.begin;
}

void expectedLeaves(const Cell &cell, const std::vector<Point> &points,
                    const Tree::Config &config, std::vector<Cell> &result)
{
    if (count(cell, points) <= config.maxParticlesPerLeaf || cell.depth >= config.maxDepth)
    {
        result.push_back(cell);
        return;
    }
    for (const auto &child : split(cell)) expectedLeaves(child, points, config, result);
}

template <class T>
void requireArray(const thrust::device_vector<T> &actual, const std::vector<T> &expected,
                  const char *name)
{
    INFO(name);
    const thrust::host_vector<T> host = actual;
    REQUIRE(host.size() == expected.size());
    for (std::size_t i = 0; i < expected.size(); ++i)
    {
        INFO("index " << i);
        REQUIRE(host[i] == expected[i]);
    }
}

// A CPU breadth-first traversal, independent of the GPU's direct ancestor
// extraction and sorting. The cornerstone is also checked against the physical
// bisection oracle below; using it here permits validation of intermediate
// split/merge states during graph replay, before the topology has converged.
template <class BinaryTree>
void requireViews(const BinaryTree &tree, adaptive_octree::ViewConfig views)
{
    if (!views.treeStructure && !views.particleCountsPerBox && !views.particleMapping)
    {
        REQUIRE(tree.sfcBoxIndex_d().empty());
        REQUIRE(tree.hasBoxSplit_d().empty());
        REQUIRE(tree.boxDepth_d().empty());
        REQUIRE(tree.parentIndex_d().empty());
        REQUIRE(tree.childIndex_d().empty());
        REQUIRE(tree.levelOffset_d().empty());
        REQUIRE(tree.particleBeginIndex_d().empty());
        REQUIRE(tree.particleCounts_d().empty());
        REQUIRE(tree.sfcParticleIndex_d().empty());
        return;
    }

    using Index = adaptive_octree::NodeIndex;
    const thrust::host_vector<Key> boundaries = tree.cornerstone_d();
    const thrust::host_vector<Key> keys = tree.particleKeys_d();
    struct Node
    {
        Key begin, end;
        std::uint8_t depth;
        Index parent = adaptive_octree::invalidNodeIndex;
        Index firstChild = adaptive_octree::invalidNodeIndex;
    };
    std::vector<Node> nodes{{0, rootEnd, 0}};
    std::vector<Index> offsets(65);
    std::size_t levelBegin = 0, levelEnd = 1;
    for (unsigned depth = 0; depth <= 63; ++depth)
    {
        offsets[depth] = Index(levelBegin);
        std::vector<Index> parents;
        for (std::size_t i = levelBegin; i < levelEnd; ++i)
        {
            const auto boundary = std::lower_bound(boundaries.begin(), boundaries.end(), nodes[i].begin);
            REQUIRE(boundary != boundaries.end());
            REQUIRE(*boundary == nodes[i].begin);
            REQUIRE(boundary + 1 != boundaries.end());
            if (nodes[i].end != *(boundary + 1))
            {
                REQUIRE(depth < 63);
                nodes[i].firstChild = Index(levelEnd + parents.size());
                parents.push_back(Index(i));
            }
        }
        // The public layout groups child slots: all child-0 nodes in parent
        // order, then all child-1 nodes in the same order.
        for (unsigned child = 0; child < 2; ++child)
            for (Index parent : parents)
            {
                const Node p = nodes[parent];
                const Key half = (p.end - p.begin) / 2;
                const Key begin = p.begin + child * half;
                nodes.push_back({begin, begin + half, std::uint8_t(depth + 1), parent});
            }
        levelBegin = levelEnd;
        levelEnd = nodes.size();
    }
    offsets.back() = Index(nodes.size());
    REQUIRE(nodes.size() == 2 * (boundaries.size() - 1) - 1);
    REQUIRE(tree.numNodes() == nodes.size());
    Index deviceNodes = -1;
    requireCuda(cudaMemcpy(&deviceNodes, tree.numNodes_d(), sizeof(deviceNodes), cudaMemcpyDeviceToHost));
    REQUIRE(deviceNodes == nodes.size());
    REQUIRE(tree.maxAchievedDepth() == nodes.back().depth);

    const auto active = std::lower_bound(keys.begin(), keys.end(), rootEnd) - keys.begin();
    REQUIRE(tree.numActiveParticles() == active);
    std::vector<Key> boxKeys, mapping(active, adaptive_octree::invalidParticleNodeIndex);
    std::vector<std::uint8_t> splitFlags, depths;
    std::vector<Index> parents, children;
    std::vector<unsigned> begins, counts;
    for (std::size_t i = 0; i < nodes.size(); ++i)
    {
        const Node &node = nodes[i];
        boxKeys.push_back((Key{1} << node.depth) | (node.begin >> (63 - node.depth)));
        splitFlags.push_back(node.firstChild != adaptive_octree::invalidNodeIndex);
        depths.push_back(node.depth);
        parents.push_back(node.parent);
        children.push_back(node.firstChild);
        const auto begin = std::lower_bound(keys.begin(), keys.end(), node.begin) - keys.begin();
        const auto end = std::lower_bound(keys.begin(), keys.end(), node.end) - keys.begin();
        begins.push_back(unsigned(begin));
        counts.push_back(unsigned(end - begin));
        if (node.firstChild == adaptive_octree::invalidNodeIndex)
            std::fill(mapping.begin() + begin, mapping.begin() + end, Key(i));
    }
    requireArray(tree.sfcBoxIndex_d(), boxKeys, "binary box keys");
    requireArray(tree.hasBoxSplit_d(), splitFlags, "binary split flags");
    requireArray(tree.boxDepth_d(), depths, "binary depths");
    requireArray(tree.parentIndex_d(), parents, "binary parents");
    requireArray(tree.childIndex_d(), children, "binary first children");
    requireArray(tree.levelOffset_d(), offsets, "binary level offsets");
    if (views.particleCountsPerBox)
    {
        counts.push_back(unsigned(active));
        requireArray(tree.particleBeginIndex_d(), begins, "binary particle begins");
        requireArray(tree.particleCounts_d(), counts, "binary particle counts and sentinel");
    }
    else
    {
        REQUIRE(tree.particleBeginIndex_d().empty());
        REQUIRE(tree.particleCounts_d().empty());
    }
    if (views.particleMapping)
    {
        requireArray(tree.sfcParticleIndex_d(), mapping, "binary particle mapping");
        REQUIRE(tree.sfcParticleIndex_d().capacity() >= tree.numParticles());
        std::vector<Key> backing(tree.numParticles());
        if (!backing.empty())
            requireCuda(cudaMemcpy(backing.data(), thrust::raw_pointer_cast(tree.sfcParticleIndex_d().data()),
                                   backing.size() * sizeof(Key), cudaMemcpyDeviceToHost));
        for (std::size_t i = active; i < backing.size(); ++i)
            REQUIRE(backing[i] == adaptive_octree::invalidParticleNodeIndex);
    }
    else REQUIRE(tree.sfcParticleIndex_d().empty());
}

void requireOracle(Tree &tree, const std::vector<Point> &points, const Tree::Config &config,
                   bool converged = true)
{
    const thrust::host_vector<Key> boundaries = tree.cornerstone_d(), keys = tree.particleKeys_d();
    const thrust::host_vector<unsigned> counts = tree.leafCounts_d();
    const thrust::host_vector<adaptive_octree::PermIndex> perm = tree.perm_d();
    const auto activeCount = count(root(config.box), points);
    REQUIRE(boundaries.size() == counts.size() + 1);
    REQUIRE(boundaries.front() == 0);
    REQUIRE(boundaries.back() == rootEnd);
    REQUIRE(tree.numParticles() == points.size());
    REQUIRE(tree.numActiveParticles() == activeCount);
    REQUIRE(std::accumulate(counts.begin(), counts.end(), 0u) == activeCount);
    REQUIRE(keys.size() == points.size());
    REQUIRE(perm.size() == points.size());
    REQUIRE(std::is_sorted(keys.begin(), keys.end()));
    std::vector<bool> seen(points.size());
    for (std::size_t i = 0; i < keys.size(); ++i)
    {
        REQUIRE(perm[i] < points.size());
        REQUIRE_FALSE(seen[perm[i]]);
        seen[perm[i]] = true;
        REQUIRE(keys[i] == particleKey(points[perm[i]], config.box));
    }
    unsigned active = ~0u;
    requireCuda(cudaMemcpy(&active, tree.numActiveParticles_d(), sizeof(active), cudaMemcpyDeviceToHost));
    REQUIRE(active == activeCount);
    adaptive_octree::NodeIndex leaves = -1;
    requireCuda(cudaMemcpy(&leaves, tree.numLeaves_d(), sizeof(leaves), cudaMemcpyDeviceToHost));
    REQUIRE(leaves == counts.size());
    for (std::size_t i = 0; i < counts.size(); ++i)
    {
        const Key begin = boundaries[i], end = boundaries[i + 1], width = end - begin;
        REQUIRE(end > begin);
        REQUIRE((width & (width - 1)) == 0);
        REQUIRE(begin % width == 0);
        REQUIRE(counts[i] == std::lower_bound(keys.begin(), keys.end(), end) -
                             std::lower_bound(keys.begin(), keys.end(), begin));
    }

    requireViews(tree, config.views);
    if (!converged) return;
    std::vector<Cell> expected;
    expectedLeaves(root(config.box), points, config, expected);
    REQUIRE(counts.size() == expected.size());
    unsigned maxDepth = 0;
    for (std::size_t i = 0; i < expected.size(); ++i)
    {
        INFO("leaf " << i);
        REQUIRE(boundaries[i] == expected[i].begin);
        REQUIRE(boundaries[i + 1] == expected[i].end);
        REQUIRE(counts[i] == count(expected[i], points));
        maxDepth = std::max(maxDepth, expected[i].depth);
    }
    REQUIRE(tree.maxAchievedDepth() == maxDepth);
}

void requireSameTree(const Tree &a, const Tree &b)
{
    requireSame(a.cornerstone_d(), b.cornerstone_d());
    requireSame(a.leafCounts_d(), b.leafCounts_d());
    requireSame(a.particleKeys_d(), b.particleKeys_d());
    requireSame(a.perm_d(), b.perm_d());
    REQUIRE(a.numActiveParticles() == b.numActiveParticles());
}

TEST_CASE("Binary intervals match independent longest-side geometry and counts", "[binary][gpu]")
{
    for (const auto box : {adaptive_octree::Box<double>{}, adaptive_octree::Box<double>{-0.5, 0.5, 1, 2.25, -2, -0.25},
                           adaptive_octree::Box<double>{0, 1, 0, 1, 0, 64},
                           adaptive_octree::Box<double>{0, 1, 0, 1, 0, 0x1p40}})
    {
        INFO("box zmax " << box.zmax);
        Stream stream;
        auto config = configuration(stream.value);
        config.box = box;
        config.views = {true, true, true};
        auto points = particles(box);
        points[7] = escaped();
        Coordinates coordinates(points.size());
        coordinates.upload(points, stream.value);
        auto tree = coordinates.tree(config);
        tree->build();
        REQUIRE_FALSE(tree->doBuffersNeedResize());
        requireOracle(*tree, points, config);
    }
}

TEST_CASE("Key bits directly follow longest-side order without a coordinate depth cap", "[binary][gpu]")
{
    Stream stream;
    auto config = configuration(stream.value);
    config.box = {0, 1, 0, 1, 0, 0x1p40};
    config.maxParticlesPerLeaf = 1;
    const std::vector<Point> points{{0, 0, 0}, {0, 0, 1}, {0, 0, 0x1p39}};
    Coordinates coordinates(points.size());
    coordinates.upload(points, stream.value);
    config.maxDepth = 1;
    auto shallow = coordinates.tree(config);
    shallow->build();
    requireOracle(*shallow, points, config);
    const thrust::host_vector<Key> keys = shallow->particleKeys_d();
    REQUIRE(keys[0] == 0);
    REQUIRE(keys[1] == (Key{1} << 23)); // 40th Z bit, beyond the former 21-bit cap.
    REQUIRE(keys[2] == (Key{1} << 62)); // Longest axis is Z, so Z supplies the first bit.
    config.maxDepth = 63;
    auto deep = coordinates.tree(config);
    deep->build();
    requireOracle(*deep, points, config);
    REQUIRE(deep->maxAchievedDepth() == 40);
    requireSame(shallow->particleKeys_d(), deep->particleKeys_d());
}

TEST_CASE("Binary depth limits preserve duplicate particles through depth 63", "[binary][gpu]")
{
    for (unsigned depth : {0u, 1u, 2u, 63u})
    {
        INFO("depth " << depth);
        Stream stream;
        auto config = configuration(stream.value);
        config.maxDepth = depth;
        config.maxParticlesPerLeaf = 1;
        config.views = {true, true, true};
        const std::vector<Point> points(3, Point{0.5, 0.5, 0.5});
        Coordinates coordinates(points.size());
        coordinates.upload(points, stream.value);
        auto tree = coordinates.tree(config);
        tree->build();
        requireOracle(*tree, points, config);
        REQUIRE(tree->leafCounts_d().size() == depth + 1);
    }
}

TEST_CASE("Domain edges clamp to valid keys and escaped slots sort after the domain", "[binary][escaped][gpu]")
{
    Stream stream;
    auto config = configuration(stream.value);
    config.box = {0, 1, 0, 1, 0, 0x1p80}; // All 63 splits choose Z.
    config.maxDepth = 0;
    config.views = {true, true, true};
    const std::vector<Point> points{{0, 0, 0}, {1, 1, 0x1p80}, {-1, -1, -1},
                                    {2, 2, 0x1p81}, escaped()};
    Coordinates coordinates(points.size());
    coordinates.upload(points, stream.value);
    auto tree = coordinates.tree(config);
    tree->build();
    const thrust::host_vector<Key> keys = tree->particleKeys_d();
    REQUIRE(keys[0] == 0);
    REQUIRE(keys[1] == 0);
    REQUIRE(keys[2] == rootEnd - 1);
    REQUIRE(keys[3] == rootEnd - 1);
    REQUIRE(keys[4] == adaptive_octree::invalidParticleKey);
    REQUIRE(tree->numActiveParticles() == 4);
    REQUIRE(tree->leafCounts_d().size() == 1);
    REQUIRE(tree->leafCounts_d()[0] == 4);
    requireViews(*tree, config.views);
}

TEST_CASE("Empty and escaped inputs retain one zero-count binary root", "[binary][escaped][gpu]")
{
    for (unsigned slots : {0u, 9u})
    {
        Stream stream;
        auto config = configuration(stream.value);
        config.views = {true, true, true};
        const std::vector<Point> points(slots, escaped());
        Coordinates coordinates(slots);
        coordinates.upload(points, stream.value);
        auto tree = coordinates.tree(config);
        tree->build();
        requireOracle(*tree, points, config);
        for (int update = 0; update < 3; ++update)
        {
            tree->update();
            REQUIRE_FALSE(tree->doBuffersNeedResize());
            requireOracle(*tree, points, config);
        }
    }
}

TEST_CASE("Captured updates match direct updates through resize split merge and reactivation", "[binary][gpu][graph]")
{
    for (unsigned iterations : {1u, 2u})
    {
        INFO("iterations " << iterations);
        Stream stream;
        auto config = configuration(stream.value);
        config.updateIterations = iterations;
        config.maxDepth = 9;
        config.maxParticlesPerLeaf = 1;
        config.box = {0, 1, 0, 1.25, 0, 1.75};
        config.views = {true, true, true};
        const std::vector<Point> empty(65, escaped());
        Coordinates coordinates(empty.size());
        coordinates.upload(empty, stream.value);
        auto direct = coordinates.tree(config), captured = coordinates.tree(config);
        direct->build(); captured->build();
        auto graph = std::make_unique<Graph>(*captured, stream.value);
        bool resized = false;
        const auto distributed = particles(config.box);
        auto partial = distributed;
        for (std::size_t i = 0; i < partial.size(); i += 3) partial[i] = escaped();
        const std::vector<Point> clustered(empty.size(), Point{0.25, 0.25, 0.25});
        for (const auto &points : {distributed, partial, clustered, empty, distributed})
        {
            coordinates.upload(points, stream.value);
            // Capacity rejection and one-level split/merge steps need repeated
            // updates; the same captured graph must also remain safe when stable.
            for (unsigned pass = 0; pass < 4 * config.maxDepth + 16; ++pass)
            {
                direct->update();
                graph->replay();
                const bool growDirect = direct->doBuffersNeedResize();
                const bool growCaptured = captured->doBuffersNeedResize();
                REQUIRE(growDirect == growCaptured);
                requireSameTree(*direct, *captured);
                requireOracle(*direct, points, config, false);
                requireViews(*captured, config.views);
                if (growCaptured)
                {
                    resized = true;
                    graph.reset();
                    direct->resizeBuffers(); captured->resizeBuffers();
                    graph = std::make_unique<Graph>(*captured, stream.value);
                }
            }
            requireOracle(*direct, points, config);
            requireOracle(*captured, points, config);
        }
        REQUIRE(resized);
    }
}

TEST_CASE("Binary view flags independently build the requested arrays", "[binary][views][gpu]")
{
    for (auto views : {Tree::ViewConfig{}, Tree::ViewConfig{true, false, false},
                       Tree::ViewConfig{false, true, false}, Tree::ViewConfig{false, false, true},
                       Tree::ViewConfig{true, true, true}})
    {
        INFO("structure " << views.treeStructure << " counts " << views.particleCountsPerBox
                           << " mapping " << views.particleMapping);
        for (unsigned slots : {0u, 9u, 19u})
        {
            INFO("slots " << slots);
            Stream stream;
            auto config = configuration(stream.value);
            config.box = {0, 1, -2, 0, 0, 8};
            config.views = views;
            auto points = slots == 19 ? particles(config.box, slots) : std::vector<Point>(slots, escaped());
            if (slots == 19) points[5] = escaped();
            Coordinates coordinates(slots);
            coordinates.upload(points, stream.value);
            auto tree = coordinates.tree(config);
            tree->build();
            requireOracle(*tree, points, config);
            tree->computeViews();
            REQUIRE_FALSE(tree->doBuffersNeedResize());
            requireOracle(*tree, points, config);
        }
    }
}

TEST_CASE("Binary views can be enabled after building without views", "[binary][views][gpu]")
{
    Stream stream;
    auto config = configuration(stream.value);
    auto points = particles(config.box, 31);
    points[7] = escaped();
    Coordinates coordinates(points.size());
    coordinates.upload(points, stream.value);
    auto tree = coordinates.tree(config);
    tree->build();
    requireOracle(*tree, points, config);
    for (auto views : {Tree::ViewConfig{true, false, false}, Tree::ViewConfig{true, true, false},
                       Tree::ViewConfig{true, true, true}})
    {
        tree->computeViews(views);
        REQUIRE(tree->doBuffersNeedResize());
        tree->resizeBuffers();
        tree->computeViews(views);
        REQUIRE_FALSE(tree->doBuffersNeedResize());
        requireViews(*tree, views);
    }

    // Explicit requests do not change Config::views. A later update leaves
    // those views stale, but the depth query must still describe the new tree.
    REQUIRE(tree->maxAchievedDepth() > 0);
    coordinates.upload(std::vector<Point>(points.size(), escaped()), stream.value);
    tree->update();
    unsigned resizeAttempts = 0;
    while (tree->doBuffersNeedResize())
    {
        REQUIRE(++resizeAttempts < 64);
        tree->resizeBuffers();
        tree->update();
    }
    REQUIRE(tree->leafCounts_d().size() == 1);
    REQUIRE(tree->maxAchievedDepth() == 0);
    const Tree::ViewConfig views{true, true, true};
    tree->computeViews(views);
    REQUIRE_FALSE(tree->doBuffersNeedResize());
    requireViews(*tree, views);
}

TEST_CASE("Binary configuration rejects invalid depth and domains", "[binary][gpu]")
{
    Stream stream;
    Coordinates coordinates(0);
    auto config = configuration(stream.value);
    config.maxDepth = 64;
    REQUIRE_THROWS_AS(coordinates.tree(config), std::invalid_argument);
    config = configuration(stream.value);
    config.box.xmax = config.box.xmin;
    REQUIRE_THROWS_AS(coordinates.tree(config), std::invalid_argument);
}
} // namespace binary_tests

// Compile-time facade equivalence and configuration checks.
namespace wrapper_tests
{
using namespace test;

using Octree = adaptive_octree::Octree<double>;
using KDTree = adaptive_octree::KDTree3D<double>;
using Type = adaptive_octree::TreeType;
using OctreeTree = adaptive_octree::Tree<double, Type::Octree>;
using BinaryTree = adaptive_octree::Tree<double, Type::Binary>;

static_assert(OctreeTree::type() == Type::Octree);
static_assert(BinaryTree::type() == Type::Binary);
static_assert(!std::is_same_v<OctreeTree, BinaryTree>);

template <class Facade, class Backend>
void requireSameTree(const Facade &tree, const Backend &direct)
{
    requireSame(tree.cornerstone_d(), direct.cornerstone_d());
    requireSame(tree.leafCounts_d(), direct.leafCounts_d());
    requireSame(tree.particleKeys_d(), direct.particleKeys_d());
    requireSame(tree.perm_d(), direct.perm_d());
    REQUIRE(tree.numParticles() == direct.numParticles());
    REQUIRE(tree.numActiveParticles() == direct.numActiveParticles());
    REQUIRE(tree.numNodes() == direct.numNodes());
    unsigned active = 0;
    requireCuda(cudaMemcpy(&active, tree.numActiveParticles_d(), sizeof(active), cudaMemcpyDeviceToHost));
    REQUIRE(active == tree.numActiveParticles());
    adaptive_octree::NodeIndex leaves = 0;
    requireCuda(cudaMemcpy(&leaves, tree.numLeaves_d(), sizeof(leaves), cudaMemcpyDeviceToHost));
    REQUIRE(leaves == tree.leafCounts_d().size());
}

template <Type Kind, class Backend>
void checkCapturedDispatch()
{
    using Tree = adaptive_octree::Tree<double, Kind>;
    constexpr std::size_t count = 129;
    const auto escaped = adaptive_octree::escapedParticleCoordinate<double>;
    Stream stream;
    thrust::device_vector<double> x(count, escaped), y(count, escaped), z(count, escaped);
    const auto xp = thrust::raw_pointer_cast(x.data());
    const auto yp = thrust::raw_pointer_cast(y.data());
    const auto zp = thrust::raw_pointer_cast(z.data());
    typename Tree::Config config;
    config.box = {0, 1, 0, 2, 0, 8};
    config.maxParticlesPerLeaf = 4;
    config.updateIterations = 1;
    config.stream = stream.value;
    if constexpr (Kind == Type::Binary) config.views = {true, true, true};
    typename Backend::Config backendConfig;
    backendConfig.box = config.box;
    backendConfig.maxParticlesPerLeaf = config.maxParticlesPerLeaf;
    backendConfig.updateIterations = config.updateIterations;
    backendConfig.stream = config.stream;
    backendConfig.views = config.views;
    if constexpr (std::is_same_v<Backend, Octree>) backendConfig.interactive = false;
    Backend direct(xp, yp, zp, count, backendConfig);
    Tree tree(xp, yp, zp, count, config);
    REQUIRE(tree.type() == Kind);
    direct.build();
    tree.build();
    requireSameTree(tree, direct);
    if constexpr (Kind == Type::Binary) binary_tests::requireViews(tree, config.views);
    auto graph = std::make_unique<Graph>(tree, stream.value);
    bool resized = false;
    for (int frame : {0, 1, 2, 0})
    {
        std::vector<double> hx(count), hy(count), hz(count);
        for (std::size_t i = 0; i < count; ++i)
        {
            hx[i] = ((i * 173) % 1024) / 1024.0;
            hy[i] = ((i * 317) % 1024) / 512.0;
            hz[i] = ((i * 563) % 1024) / 128.0;
            if (frame == 2 || (frame == 1 && i % 3 == 0)) hx[i] = hy[i] = hz[i] = escaped;
        }
        requireCuda(cudaMemcpyAsync(xp, hx.data(), count * sizeof(double), cudaMemcpyHostToDevice, stream.value));
        requireCuda(cudaMemcpyAsync(yp, hy.data(), count * sizeof(double), cudaMemcpyHostToDevice, stream.value));
        requireCuda(cudaMemcpyAsync(zp, hz.data(), count * sizeof(double), cudaMemcpyHostToDevice, stream.value));
        for (unsigned pass = 0; pass < 40; ++pass)
        {
            direct.update();
            graph->replay();
            const bool grow = tree.doBuffersNeedResize();
            REQUIRE(grow == direct.doBuffersNeedResize());
            requireSameTree(tree, direct);
            if constexpr (Kind == Type::Binary) binary_tests::requireViews(tree, config.views);
            if (grow)
            {
                resized = true;
                graph.reset();
                direct.resizeBuffers();
                tree.resizeBuffers();
                graph = std::make_unique<Graph>(tree, stream.value);
            }
        }
        REQUIRE(tree.numActiveParticles() == (frame == 2 ? 0 : frame == 1 ? 86 : count));
    }
    REQUIRE(resized);
}

TEST_CASE("Template Tree matches both backends through graph replay and resize", "[tree][gpu][graph]")
{
    SECTION("Octree") { checkCapturedDispatch<Type::Octree, Octree>(); }
    SECTION("Binary") { checkCapturedDispatch<Type::Binary, KDTree>(); }
}

TEST_CASE("Tree forwards octree NF Hilbert and views", "[tree][octree][gpu]")
{
    using Tree = OctreeTree;
    Stream stream;
    std::vector<double> host;
    for (unsigned i = 0; i < 32; ++i) host.push_back((i + 0.5) / 32);
    thrust::device_vector<double> positions(host.begin(), host.end());
    const auto p = thrust::raw_pointer_cast(positions.data());
    Tree::Config config;
    config.splitCriterion = Tree::SplitCriterion::NFCount;
    config.sfcKind = Tree::SfcKind::Hilbert;
    config.maxParticlesPerLeaf = 64;
    config.stream = stream.value;
    Octree::Config backendConfig;
    backendConfig.splitCriterion = config.splitCriterion;
    backendConfig.sfcKind = config.sfcKind;
    backendConfig.maxParticlesPerLeaf = config.maxParticlesPerLeaf;
    backendConfig.stream = config.stream;
    backendConfig.interactive = false;
    Octree direct(p, p, p, host.size(), backendConfig);
    Tree tree(p, p, p, host.size(), config);
    direct.build();
    tree.build();
    direct.computeViews({true, true, true});
    tree.computeViews({true, true, true});
    requireSameTree(tree, direct);
    requireSame(tree.nearFieldCounts_d(), direct.nearFieldCounts_d());
    requireSame(tree.sfcBoxIndex_d(), direct.sfcBoxIndex_d());
    requireSame(tree.hasBoxSplit_d(), direct.hasBoxSplit_d());
    requireSame(tree.boxDepth_d(), direct.boxDepth_d());
    requireSame(tree.parentIndex_d(), direct.parentIndex_d());
    requireSame(tree.childIndex_d(), direct.childIndex_d());
    requireSame(tree.levelOffset_d(), direct.levelOffset_d());
    requireSame(tree.particleBeginIndex_d(), direct.particleBeginIndex_d());
    requireSame(tree.particleCounts_d(), direct.particleCounts_d());
    requireSame(tree.sfcParticleIndex_d(), direct.sfcParticleIndex_d());
    REQUIRE(tree.maxAchievedDepth() == direct.maxAchievedDepth());
}

TEST_CASE("Tree rejects unsupported binary options", "[tree][binary][gpu]")
{
    using Tree = BinaryTree;
    Tree::Config config;
    config.splitCriterion = Tree::SplitCriterion::NFCount;
    REQUIRE_THROWS_AS(Tree(nullptr, nullptr, nullptr, 0, config), std::invalid_argument);
    config = {};
    config.sfcKind = Tree::SfcKind::Hilbert;
    REQUIRE_THROWS_AS(Tree(nullptr, nullptr, nullptr, 0, config), std::invalid_argument);
    config = {};
    config.updateIterations = 0;
    REQUIRE_THROWS_AS(Tree(nullptr, nullptr, nullptr, 0, config), std::invalid_argument);
    Tree tree(nullptr, nullptr, nullptr, 0);
    tree.build();
    REQUIRE_THROWS(tree.nearFieldCounts_d());
}

TEST_CASE("Tree forwards late binary view requests", "[tree][binary][views][gpu]")
{
    Stream stream;
    auto backendConfig = binary_tests::configuration(stream.value);
    const auto points = binary_tests::particles(backendConfig.box, 17);
    binary_tests::Coordinates coordinates(points.size());
    coordinates.upload(points, stream.value);
    BinaryTree::Config config;
    config.maxParticlesPerLeaf = backendConfig.maxParticlesPerLeaf;
    config.stream = stream.value;
    BinaryTree tree(thrust::raw_pointer_cast(coordinates.x.data()),
                    thrust::raw_pointer_cast(coordinates.y.data()),
                    thrust::raw_pointer_cast(coordinates.z.data()), points.size(), config);
    tree.build();
    binary_tests::requireViews(tree, {});
    const BinaryTree::ViewConfig views{true, true, true};
    tree.computeViews(views);
    REQUIRE(tree.doBuffersNeedResize());
    tree.resizeBuffers();
    tree.computeViews(views);
    REQUIRE_FALSE(tree.doBuffersNeedResize());
    binary_tests::requireViews(tree, views);
}

TEST_CASE("Tree preserves explicit binary root-only depth", "[tree][binary][gpu]")
{
    using Tree = BinaryTree;
    thrust::device_vector<double> positions(3, 0.5);
    const auto p = thrust::raw_pointer_cast(positions.data());
    Tree::Config config;
    config.maxDepth = 0;
    config.maxParticlesPerLeaf = 1;
    config.views = {true, true, true};
    Tree tree(p, p, p, positions.size(), config);
    tree.build();
    REQUIRE(tree.maxAchievedDepth() == 0);
    REQUIRE(tree.leafCounts_d().size() == 1);
    REQUIRE(tree.leafCounts_d()[0] == positions.size());
    REQUIRE(tree.cornerstone_d().size() == 2);
    binary_tests::requireViews(tree, config.views);
}
} // namespace wrapper_tests
