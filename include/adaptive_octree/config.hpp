#pragma once

// Shared public types, settings, and macros. CUDA/Thrust implementation
// helpers live in src/common/helpers.cuh.
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <stdexcept>
#include <string>
#include <cuda_runtime_api.h>

#if defined(__CUDACC__)
#define HOST_DEVICE_FUN __host__ __device__
#else
#define HOST_DEVICE_FUN
#endif

// Profiling is enabled by the ADAPTIVE_OCTREE_PROFILING CMake option.
#ifdef ADAPTIVE_OCTREE_PROFILING
#include <nvtx3/nvToolsExt.h>
#define ADAPTIVE_OCTREE_NVTX_RANGE_PUSH(name) nvtxRangePushA(name)
#define ADAPTIVE_OCTREE_NVTX_RANGE_POP() nvtxRangePop()
#else
#define ADAPTIVE_OCTREE_NVTX_RANGE_PUSH(name)
#define ADAPTIVE_OCTREE_NVTX_RANGE_POP()
#endif

// CUDA error checks: library code terminates; tools can use the throwing check.
#define checkGpuErrors(errcode) \
    ::adaptive_octree::detail::checkErr((errcode), __FILE__, __LINE__, #errcode)
#define ADAPTIVE_OCTREE_CHECK_CUDA(operation) \
    ::adaptive_octree::detail::checkCudaResult((operation), #operation)

namespace adaptive_octree
{
    using KeyType = unsigned long long;
    using NodeIndex = int;
    using PermIndex = std::uint32_t;

    inline constexpr NodeIndex invalidNodeIndex = -1;
    inline constexpr KeyType invalidParticleKey = std::numeric_limits<KeyType>::max();
    inline constexpr KeyType invalidParticleNodeIndex = static_cast<KeyType>(invalidNodeIndex);
    inline constexpr unsigned maxOctreeDepth = std::numeric_limits<KeyType>::digits / 3;
    // 64 levels including the root; the high bit holds its exclusive endpoint.
    inline constexpr unsigned maxBinaryDepth = std::numeric_limits<KeyType>::digits - 1;
    inline constexpr KeyType maxKey = KeyType(1) << maxBinaryDepth;

    enum class TreeType { Octree, Binary };
    enum class SplitCriterion { LeafCount, NFCount };
    enum class SfcKind { Morton, Hilbert };

    namespace defaults
    {
        inline constexpr unsigned maxParticlesPerLeaf = 64;
        inline constexpr unsigned octreeUpdateIterations = 2;
        inline constexpr unsigned binaryUpdateIterations = 6;
        inline constexpr unsigned long long nearFieldLimit =
            1ULL * maxParticlesPerLeaf * maxParticlesPerLeaf * 27;
        inline constexpr std::uint64_t mergeBufferRatio = 1;
        inline constexpr std::uint64_t splitBufferRatio = 1;
        // Add 1/divisor capacity headroom (25%).
        inline constexpr std::size_t bufferGrowthDivisor = 4;

        // Kernel launch tuning; sizes must be multiples of the cooperative group.
        inline constexpr unsigned blockThreads = 256;
        inline constexpr unsigned wideBlockThreads = 512;
        inline constexpr unsigned mergeBlockThreads = 128;
        inline constexpr unsigned nearFieldGroupSize = 8;
        inline constexpr unsigned maxSparseNearFieldBlocks = 120;

        inline constexpr std::size_t printSamples = 4;
        inline constexpr std::size_t octreeVectorPrintSamples = 3;

        // Example and benchmark defaults; command-line options can override them.
        inline constexpr TreeType treeType = TreeType::Binary;
        inline constexpr const char *benchmarkTree = "all";
        inline constexpr const char *benchmarkCriterion = "all";
        inline constexpr unsigned exampleUpdateIterations = 10;
        inline constexpr int snapshotStride = 1;
        inline constexpr int frameStride = 1;
        inline constexpr int snapshotRepeats = 20;
        inline constexpr int buildRepeats = 100;
        inline constexpr double domainPadding = 0.05;

        // The octree NF reduction uses a fixed eight-lane shuffle pattern.
        static_assert(nearFieldGroupSize == 8);
        static_assert(blockThreads % nearFieldGroupSize == 0 &&
                      wideBlockThreads % nearFieldGroupSize == 0 &&
                      mergeBlockThreads % nearFieldGroupSize == 0);
        static_assert(bufferGrowthDivisor > 0);
    }

    template <class Real>
    struct Box
    {
        Real xmin = Real{0}, xmax = Real{1};
        Real ymin = Real{0}, ymax = Real{1};
        Real zmin = Real{0}, zmax = Real{1};
    };

    // Escaped particles retain their input slot and sort after active keys.
    template <class Real>
    inline constexpr Real escapedParticleCoordinate = std::numeric_limits<Real>::max();

    template <class Real>
    HOST_DEVICE_FUN constexpr bool isEscapedParticle(Real x, Real y, Real z)
    {
        return x == escapedParticleCoordinate<Real> &&
               y == escapedParticleCoordinate<Real> &&
               z == escapedParticleCoordinate<Real>;
    }

    struct ViewConfig
    {
        bool treeStructure = false;
        bool particleCountsPerBox = false;
        bool particleMapping = false;
    };

    template <class Real>
    struct OctreeConfig
    {
        unsigned maxDepth = maxOctreeDepth; // Existing octree does not enforce this limit.
        unsigned maxParticlesPerLeaf = defaults::maxParticlesPerLeaf;
        SplitCriterion splitCriterion = SplitCriterion::LeafCount;
        SfcKind sfcKind = SfcKind::Morton;
        Box<Real> box{};
        ViewConfig views{};
        unsigned updateIterations = defaults::octreeUpdateIterations;
        cudaStream_t stream = nullptr;
        bool interactive = true;
    };

    template <class Real>
    struct KDTree3DConfig
    {
        unsigned maxDepth = maxBinaryDepth;
        unsigned maxParticlesPerLeaf = defaults::maxParticlesPerLeaf;
        Box<Real> box{};
        ViewConfig views{};
        unsigned updateIterations = defaults::binaryUpdateIterations;
        cudaStream_t stream = nullptr;
    };

    template <class Real>
    struct TreeConfig
    {
        // -1 uses the backend default; explicit depth zero is valid.
        int maxDepth = -1;
        unsigned maxParticlesPerLeaf = defaults::maxParticlesPerLeaf;
        int updateIterations = -1;
        Box<Real> box{};
        cudaStream_t stream = nullptr;
        SplitCriterion splitCriterion = SplitCriterion::LeafCount;
        // NFCount and Hilbert are currently available only in Octree mode.
        SfcKind sfcKind = SfcKind::Morton;
        ViewConfig views{};
    };

    namespace detail
    {
        inline void checkErr(cudaError_t error, const char *file, int line, const char *expression)
        {
            if (error != cudaSuccess)
            {
                std::fprintf(stderr, "CUDA error at %s:%d. %s returned: %s - %s\n",
                             file, line, expression, cudaGetErrorName(error), cudaGetErrorString(error));
                std::exit(EXIT_FAILURE);
            }
        }

        inline void checkCudaResult(cudaError_t error, const char *operation)
        {
            if (error != cudaSuccess)
                throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(error));
        }
    }
}
