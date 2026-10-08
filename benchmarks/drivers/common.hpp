// Shared benchmark harness for every version driver: identical input, phase
// boundaries, structural metrics, and CSV output. Each driver supplies only an
// adapter around its version's API.
#pragma once

#include <cuda_runtime.h>
#include <thrust/binary_search.h>
#include <thrust/device_vector.h>
#include <thrust/execution_policy.h>
#include <thrust/host_vector.h>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <bit>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <limits>
#include <new>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace bench
{
using Key = std::uint64_t;
using Clock = std::chrono::steady_clock;
// Same marker as adaptive_octree::escapedParticleCoordinate<double> (v3 ESC rows).
constexpr double escapedCoordinate = std::numeric_limits<double>::max();
constexpr Key rootKeyEnd = Key(1) << 63;
constexpr int oomExitCode = 3;

inline void check(cudaError_t e, const char *what)
{
    if (e != cudaSuccess)
        throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(e));
}
#define BENCH_CUDA(x) ::bench::check((x), #x)

// ---------------------------------------------------------------- input ----

struct Frame
{
    int index;
    long id;
    std::string format; // cxyz | xyzc | bin
    std::string path;
};

struct Manifest
{
    std::string dataset;
    std::size_t slots = 0;
    double box[6]{}; // xmin xmax ymin ymax zmin zmax (shared by all versions)
    std::vector<Frame> frames;
};

inline Manifest readManifest(const std::string &path)
{
    std::ifstream in(path);
    if (!in) throw std::runtime_error("cannot open manifest " + path);
    Manifest m;
    std::string line;
    while (std::getline(in, line))
    {
        std::istringstream ss(line);
        std::string tag;
        ss >> tag;
        if (tag == "dataset") ss >> m.dataset;
        else if (tag == "slots") ss >> m.slots;
        else if (tag == "box") for (double &b : m.box) ss >> b;
        else if (tag == "frame")
        {
            Frame f;
            ss >> f.index >> f.id >> f.format;
            std::getline(ss >> std::ws, f.path);
            const std::filesystem::path framePath(f.path);
            if (framePath.is_relative())
                f.path = (std::filesystem::path(path).parent_path() / framePath).lexically_normal().string();
            m.frames.push_back(f);
        }
    }
    if (m.frames.empty() || m.slots == 0) throw std::runtime_error("invalid manifest " + path);
    return m;
}

struct MappedFile
{
    explicit MappedFile(const std::string &path)
    {
        fd = ::open(path.c_str(), O_RDONLY);
        if (fd < 0) throw std::runtime_error("cannot open " + path);
        struct stat st{};
        ::fstat(fd, &st);
        size = std::size_t(st.st_size);
        data = static_cast<const char *>(size ? ::mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0) : nullptr);
        if (size && data == MAP_FAILED) throw std::runtime_error("cannot mmap " + path);
        if (size) ::madvise(const_cast<char *>(data), size, MADV_SEQUENTIAL);
    }
    ~MappedFile()
    {
        if (size) ::munmap(const_cast<char *>(data), size);
        if (fd >= 0) ::close(fd);
    }
    int fd = -1;
    std::size_t size = 0;
    const char *data = nullptr;
};

// Rows: four numeric columns, or "ESC" (escaped slot). Blank and '#' lines are skipped.
inline void readFrame(const Frame &f, std::vector<double> &x, std::vector<double> &y, std::vector<double> &z)
{
    x.clear(); y.clear(); z.clear();
    MappedFile file(f.path);
    if (f.format == "bin")
    {
        const std::size_t n = file.size / (3 * sizeof(double));
        if (n * 3 * sizeof(double) != file.size) throw std::runtime_error("bad binary frame " + f.path);
        x.resize(n); y.resize(n); z.resize(n);
        const double *v = reinterpret_cast<const double *>(file.data);
        for (std::size_t i = 0; i < n; ++i)
        {
            const bool esc = std::isnan(v[3 * i]);
            x[i] = esc ? escapedCoordinate : v[3 * i];
            y[i] = esc ? escapedCoordinate : v[3 * i + 1];
            z[i] = esc ? escapedCoordinate : v[3 * i + 2];
        }
        return;
    }
    const int offset = f.format == "cxyz" ? 1 : 0;
    if (f.format != "cxyz" && f.format != "xyzc") throw std::runtime_error("unknown frame format " + f.format);
    const char *p = file.data, *end = file.data + file.size;
    std::size_t line = 0;
    while (p < end)
    {
        const char *eol = static_cast<const char *>(std::memchr(p, '\n', end - p));
        if (!eol) eol = end;
        ++line;
        const char *q = p;
        while (q < eol && std::isspace(static_cast<unsigned char>(*q))) ++q;
        if (q < eol && *q != '#')
        {
            if (eol - q >= 3 && std::strncmp(q, "ESC", 3) == 0)
            {
                x.push_back(escapedCoordinate); y.push_back(escapedCoordinate); z.push_back(escapedCoordinate);
            }
            else
            {
                double v[4];
                for (double &c : v)
                {
                    while (q < eol && std::isspace(static_cast<unsigned char>(*q))) ++q;
                    if (q < eol && *q == '+') ++q;
                    auto r = std::from_chars(q, eol, c);
                    if (r.ec != std::errc()) throw std::runtime_error(f.path + ":" + std::to_string(line) + ": bad row");
                    q = r.ptr;
                }
                x.push_back(v[offset]); y.push_back(v[offset + 1]); z.push_back(v[offset + 2]);
            }
        }
        p = eol + 1;
    }
}

inline std::size_t countEscaped(const std::vector<double> &x)
{
    return std::count(x.begin(), x.end(), escapedCoordinate);
}

// ---------------------------------------------------------------- config ---

enum class TreeKind { Octree, KDTree3D };
enum class Criterion { LeafCount, NFCount };

struct RunConfig
{
    std::string name;
    TreeKind tree;
    Criterion criterion;
    unsigned limit;
    unsigned levelBits() const { return tree == TreeKind::Octree ? 3u : 1u; }
};

inline RunConfig parseConfig(const std::string &name)
{
    if (name == "octree_leafcount") return {name, TreeKind::Octree, Criterion::LeafCount, 64};
    if (name == "octree_nfcount") return {name, TreeKind::Octree, Criterion::NFCount, 64u * 64u * 27u};
    if (name == "kdtree3d_leafcount") return {name, TreeKind::KDTree3D, Criterion::LeafCount, 64};
    throw std::invalid_argument("unknown config " + name);
}

struct Args
{
    std::string manifest, config, mode = "steps", version, commit, out;
    int run = 0;
    int maxSnapshots = -1;
};

inline Args parseArgs(int argc, char **argv)
{
    Args a;
    for (int i = 1; i + 1 < argc; i += 2)
    {
        const std::string k = argv[i], v = argv[i + 1];
        if (k == "--manifest") a.manifest = v;
        else if (k == "--config") a.config = v;
        else if (k == "--mode") a.mode = v;
        else if (k == "--version") a.version = v;
        else if (k == "--commit") a.commit = v;
        else if (k == "--run") a.run = std::stoi(v);
        else if (k == "--out") a.out = v;
        else if (k == "--max-snapshots") a.maxSnapshots = std::stoi(v);
        else throw std::invalid_argument("unknown option " + k);
    }
    if (a.manifest.empty() || a.config.empty() || a.out.empty() || (a.mode != "steps" && a.mode != "cold"))
        throw std::invalid_argument("usage: --manifest M --config C --mode steps|cold --version V --commit H "
                                    "--run R --out FILE [--max-snapshots N]");
    return a;
}

// ------------------------------------------------------------ structure ----

struct Structure
{
    std::size_t leaves = 0, nodes = 0, emptyLeaves = 0, active = 0, slots = 0;
    unsigned maxDepth = 0;
};

// Identical for every version: recount leaf populations from sorted keys P and
// leaf boundaries K instead of trusting each version's N array.
inline Structure structure(const Key *P, std::size_t nP, const Key *K, std::size_t nK, unsigned levelBits)
{
    Structure s;
    s.slots = nP;
    s.leaves = nK - 1;
    thrust::device_vector<std::size_t> pos(nK);
    thrust::lower_bound(thrust::device, P, P + nP, K, K + nK, pos.begin());
    const thrust::host_vector<std::size_t> h = pos;
    std::vector<Key> keys(nK);
    BENCH_CUDA(cudaMemcpy(keys.data(), K, nK * sizeof(Key), cudaMemcpyDeviceToHost));
    if (keys.front() != 0 || keys.back() != rootKeyEnd) throw std::runtime_error("K does not span the root");
    s.active = h.back() - h.front();
    for (std::size_t i = 0; i + 1 < nK; ++i)
    {
        s.emptyLeaves += h[i + 1] == h[i];
        const unsigned rangeBits = unsigned(std::bit_width(keys[i + 1] - keys[i]) - 1);
        s.maxDepth = std::max(s.maxDepth, (63u - rangeBits) / levelBits);
    }
    s.nodes = s.leaves + (s.leaves - 1) / ((1u << levelBits) - 1);
    return s;
}

// --------------------------------------------------------------- timing ----

struct Events
{
    // begin/treeEnd/end bracket the phases (inside the graph for graph paths);
    // outerBegin/outerEnd bracket the whole submission (graph launch <-> completion).
    cudaEvent_t outerBegin{}, begin{}, treeEnd{}, end{}, outerEnd{};
    Events()
    {
        for (auto *e : {&outerBegin, &begin, &treeEnd, &end, &outerEnd}) BENCH_CUDA(cudaEventCreate(e));
    }
    ~Events()
    {
        for (auto e : {outerBegin, begin, treeEnd, end, outerEnd}) cudaEventDestroy(e);
    }
};

inline double elapsed(cudaEvent_t a, cudaEvent_t b)
{
    float ms = 0;
    BENCH_CUDA(cudaEventElapsedTime(&ms, a, b));
    return ms;
}

inline double msSince(Clock::time_point t0)
{
    return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

// ------------------------------------------------------------------ CSV ----

inline std::string num(double v)
{
    if (std::isnan(v)) return "nan";
    std::ostringstream s;
    s << std::setprecision(10) << v;
    return s.str();
}

constexpr const char *stepHeader =
    "version,commit,path,config,dataset,run,snapshot,frame_id,tree_update_ms,view_ms,total_ms,wall_ms,"
    "attempts,maintenance_ms,iterations,num_nodes,num_leaves,max_depth,max_depth_octree_equiv,"
    "num_empty_leaves,empty_leaf_pct,avg_particles_per_leaf,particles_active,particles_escaped,particle_slots,"
    "lib_num_nodes";
constexpr const char *coldHeader =
    "version,commit,path,config,dataset,process_rep,initial_build_ms,initial_tree_gpu_ms,initial_view_gpu_ms,"
    "num_leaves,num_nodes,max_depth";

struct StepTiming
{
    double tree = NAN, view = NAN, total = NAN, wall = NAN, maintenance = 0;
    int attempts = 0, iterations = -1;
};

inline void writeStep(std::ostream &o, const Args &a, const char *path, const RunConfig &c, const Manifest &m,
                      const Frame &f, const StepTiming &t, const Structure &s, double libNodes)
{
    const double maxDepthEquiv = c.tree == TreeKind::KDTree3D ? s.maxDepth / 3.0 : double(s.maxDepth);
    o << a.version << ',' << a.commit << ',' << path << ',' << c.name << ',' << m.dataset << ',' << a.run << ','
      << f.index << ',' << f.id << ',' << num(t.tree) << ',' << num(t.view) << ',' << num(t.total) << ','
      << num(t.wall) << ',' << t.attempts << ',' << num(t.maintenance) << ',' << t.iterations << ',' << s.nodes
      << ',' << s.leaves << ',' << s.maxDepth << ',' << num(maxDepthEquiv) << ',' << s.emptyLeaves << ','
      << num(100.0 * s.emptyLeaves / s.leaves) << ',' << num(double(s.active) / s.leaves) << ',' << s.active << ','
      << s.slots - s.active << ',' << s.slots << ',' << num(libNodes) << '\n';
    o.flush();
}

// ---------------------------------------------------------------- driver ---
//
// Adapter interface (see driver_*.cu):
//   static const char *pathName();                    "graph" | "direct"
//   static bool supports(const RunConfig &);
//   static cudaStream_t stream();                     stream the version computes on
//   Adapter(const RunConfig&, const Manifest&, double *x, double *y, double *z, size_t n, cudaStream_t)
//   void build();  void views();                      initial build from the root + first views
//   void prepare(Events &);                           untimed preparation (graph capture)
//   void step(Events &);                              enqueue one update: begin | tree | treeEnd | views | end
//   bool needsResize();                               host status check after a step (inside wall time)
//   void resize(Events &);                            capacity growth (+ recapture), timed as maintenance
//   const Key *P(); size_t nP(); const Key *K(); size_t nK();
//   double libNodes(); int iterations();

template <class Adapter>
int runDriver(int argc, char **argv)
{
    try
    {
        const Args args = parseArgs(argc, argv);
        const RunConfig config = parseConfig(args.config);
        if (!Adapter::supports(config)) throw std::invalid_argument("config not supported by this version");
        BENCH_CUDA(cudaFree(0)); // context creation, outside every measurement

        const Manifest m = readManifest(args.manifest);
        std::size_t freeB = 0, totalB = 0;
        BENCH_CUDA(cudaMemGetInfo(&freeB, &totalB));
        std::cerr << "GPU memory free/total [MiB]: " << (freeB >> 20) << '/' << (totalB >> 20) << '\n';

        std::vector<double> x, y, z;
        readFrame(m.frames.front(), x, y, z);
        if (x.size() != m.slots) throw std::runtime_error("slot count differs from manifest");
        if (!Adapter::supportsEscaped && countEscaped(x)) throw std::runtime_error("version cannot handle ESC rows");
        const std::size_t n = x.size();
        double *x_d, *y_d, *z_d;
        BENCH_CUDA(cudaMalloc(&x_d, n * sizeof(double)));
        BENCH_CUDA(cudaMalloc(&y_d, n * sizeof(double)));
        BENCH_CUDA(cudaMalloc(&z_d, n * sizeof(double)));
        auto upload = [&]
        {
            BENCH_CUDA(cudaMemcpy(x_d, x.data(), n * sizeof(double), cudaMemcpyHostToDevice));
            BENCH_CUDA(cudaMemcpy(y_d, y.data(), n * sizeof(double), cudaMemcpyHostToDevice));
            BENCH_CUDA(cudaMemcpy(z_d, z.data(), n * sizeof(double), cudaMemcpyHostToDevice));
        };
        upload();

        const cudaStream_t s = Adapter::stream();
        Events ev;
        std::ofstream out(args.out);
        if (!out) throw std::runtime_error("cannot open " + args.out);

        // Initial build: allocation + build from the root + first views. Cold in
        // "cold" mode (first tree work of the process); untimed context in "steps".
        BENCH_CUDA(cudaDeviceSynchronize());
        const auto t0 = Clock::now();
        BENCH_CUDA(cudaEventRecord(ev.begin, s));
        Adapter tree(config, m, x_d, y_d, z_d, n, s);
        tree.build();
        BENCH_CUDA(cudaEventRecord(ev.treeEnd, s));
        tree.views();
        BENCH_CUDA(cudaEventRecord(ev.end, s));
        BENCH_CUDA(cudaDeviceSynchronize());
        const double buildWall = msSince(t0);
        const Structure s0 = structure(tree.P(), tree.nP(), tree.K(), tree.nK(), config.levelBits());
        if (s0.slots != n) throw std::runtime_error("P size differs from slot count");

        if (args.mode == "cold")
        {
            out << coldHeader << '\n'
                << args.version << ',' << args.commit << ',' << Adapter::pathName() << ',' << config.name << ','
                << m.dataset << ',' << args.run << ',' << num(buildWall) << ',' << num(elapsed(ev.begin, ev.treeEnd))
                << ',' << num(elapsed(ev.treeEnd, ev.end)) << ',' << s0.leaves << ',' << s0.nodes << ','
                << s0.maxDepth << '\n';
            return 0;
        }

        out << stepHeader << '\n';
        StepTiming none;
        none.iterations = tree.iterations();
        writeStep(out, args, Adapter::pathName(), config, m, m.frames.front(), none, s0, tree.libNodes());
        tree.prepare(ev);

        const std::size_t last = args.maxSnapshots > 0 ? std::min<std::size_t>(args.maxSnapshots, m.frames.size())
                                                       : m.frames.size();
        for (std::size_t k = 1; k < last; ++k)
        {
            const Frame &f = m.frames[k];
            readFrame(f, x, y, z);
            if (x.size() != n) throw std::runtime_error("slot count changed in " + f.path);
            if (!Adapter::supportsEscaped && countEscaped(x)) throw std::runtime_error("version cannot handle ESC rows");
            upload();

            StepTiming t{0, 0, 0, 0, 0, 0, -1};
            bool resize = false;
            do
            {
                BENCH_CUDA(cudaDeviceSynchronize());
                const auto w0 = Clock::now();
                BENCH_CUDA(cudaEventRecord(ev.outerBegin, s));
                tree.step(ev);
                BENCH_CUDA(cudaEventRecord(ev.outerEnd, s));
                resize = tree.needsResize();
                BENCH_CUDA(cudaDeviceSynchronize());
                t.wall += msSince(w0);
                t.tree += elapsed(ev.begin, ev.treeEnd);
                t.view += elapsed(ev.treeEnd, ev.end);
                t.total += elapsed(ev.outerBegin, ev.outerEnd);
                ++t.attempts;
                if (resize)
                {
                    const auto r0 = Clock::now();
                    tree.resize(ev);
                    BENCH_CUDA(cudaDeviceSynchronize());
                    t.maintenance += msSince(r0);
                }
            } while (resize && t.attempts < 64);
            if (resize) throw std::runtime_error("buffers still need resizing after 64 attempts");
            t.iterations = tree.iterations();
            const Structure st = structure(tree.P(), tree.nP(), tree.K(), tree.nK(), config.levelBits());
            writeStep(out, args, Adapter::pathName(), config, m, f, t, st, tree.libNodes());
        }
        return 0;
    }
    catch (const std::bad_alloc &e)
    {
        std::cerr << "bench_driver: out of memory: " << e.what() << '\n';
        return oomExitCode;
    }
    catch (const std::exception &e)
    {
        const std::string what = e.what();
        std::cerr << "bench_driver: " << what << '\n';
        return what.find("out of memory") != std::string::npos ? oomExitCode : 1;
    }
}
} // namespace bench
