// helpers.cuh
#pragma once

#include <thrust/device_vector.h>

#include <cstddef>
#include <cassert>

#include "adaptive_octree/config.hpp"

namespace adaptive_octree::detail
{
  namespace execution
  {
    struct Gpu
    {
      operator cudaStream_t() const { return stream; }
      cudaStream_t stream;
    };

    constexpr inline Gpu gpuDefaultStream{nullptr};
  } // namespace execution

  using TreeNodeIndex = NodeIndex;

  template <class T, class Alloc>
  T *rawPtr(thrust::device_vector<T, Alloc> &v)
  {
    return thrust::raw_pointer_cast(v.data());
  }

  template <class T, class Alloc>
  const T *rawPtr(const thrust::device_vector<T, Alloc> &v)
  {
    return thrust::raw_pointer_cast(v.data());
  }

  //! @brief a vector of N+1 SFC keys describes a tree with N leaf nodes
  template <class Vector>
  std::size_t nNodes(const Vector &tree)
  {
    assert(tree.size());
    return tree.size() - 1;
  }

  //! @brief ceil(n / b), used to size kernel launch grids
  inline unsigned iceil(std::size_t n, unsigned b)
  {
    return unsigned((n + b - 1) / b);
  }

  template <class T>
  HOST_DEVICE_FUN constexpr T cmin(T a, T b)
  {
    return a < b ? a : b;
  }

  template <class T>
  HOST_DEVICE_FUN constexpr T cmax(T a, T b)
  {
    return a > b ? a : b;
  }

  //! @brief std::lower_bound/upper_bound equivalents usable in device code
  template <class T>
  HOST_DEVICE_FUN const T *lowerBound(const T *first, const T *last,
                                      const T &value)
  {
    std::size_t count = last - first;
    while (count > 0)
    {
      std::size_t step = count / 2;
      const T *it = first + step;
      if (*it < value)
      {
        first = it + 1;
        count -= step + 1;
      }
      else
      {
        count = step;
      }
    }
    return first;
  }

  template <class T>
  HOST_DEVICE_FUN const T *upperBound(const T *first, const T *last,
                                      const T &value)
  {
    std::size_t count = last - first;
    while (count > 0)
    {
      std::size_t step = count / 2;
      const T *it = first + step;
      if (!(value < *it))
      {
        first = it + 1;
        count -= step + 1;
      }
      else
      {
        count = step;
      }
    }
    return first;
  }

    // Active sizes live on the GPU so a recorded graph can change topology.
    struct RebalanceState
    {
        int changed = 0;
        int converged = 0;
        int numLeaves = 1;
        int newNumLeaves = 1;
        int needsResize = 0;
        int numNodes = 0;
        int activeBuffer = 0;
        unsigned numActiveParticles = 0;
    };

    template <class T>
    void resizeWithHeadroom(thrust::device_vector<T> &buffer,
                            std::size_t required)
    {
        if (required > buffer.capacity())
        {
            const auto extra = required / defaults::bufferGrowthDivisor;
            const auto limit = buffer.max_size();

            // Add 25% without overflowing; reserve handles oversized requests.
            const auto capacity =
                required <= limit && extra <= limit - required
                    ? required + extra
                    : required;

            buffer.reserve(capacity);
        }

        buffer.resize(required, thrust::no_init);
    }
}
