// sfc_keys.cuh
//
// Space-filling-curve math copied from the original implementation by Cornerstone
#pragma once

#include <cuda_runtime.h>
#include <thrust/device_vector.h>

#include <cassert>
#include <cmath>
#include <cstdint>

#include "helpers.cuh"

namespace adaptive_octree::detail
{
  // -------------------------------------------------------------------------
  // key-width traits -- add a specialization here to support another KeyType
  // -------------------------------------------------------------------------
  template <class KeyType>
  struct maxTreeLevel;
  template <>
  struct maxTreeLevel<unsigned>
  {
    HOST_DEVICE_FUN constexpr operator unsigned() const { return 10; }
  };
  template <>
  struct maxTreeLevel<unsigned long>
  {
    HOST_DEVICE_FUN constexpr operator unsigned() const { return 21; }
  };
  template <>
  struct maxTreeLevel<unsigned long long>
  {
    HOST_DEVICE_FUN constexpr operator unsigned() const { return 21; }
  };

  template <class KeyType>
  struct unusedBits;
  template <>
  struct unusedBits<unsigned>
  {
    HOST_DEVICE_FUN constexpr operator unsigned() const { return 2; }
  };
  template <>
  struct unusedBits<unsigned long>
  {
    HOST_DEVICE_FUN constexpr operator unsigned() const { return 1; }
  };
  template <>
  struct unusedBits<unsigned long long>
  {
    HOST_DEVICE_FUN constexpr operator unsigned() const { return 1; }
  };

  // -------------------------------------------------------------------------
  // bit counting (used to derive tree level / octal digit from a key range)
  // -------------------------------------------------------------------------
  // dispatch on size, not the exact type, so this works for whichever 32- or
  // 64-bit unsigned type KeyType happens to be (unsigned/unsigned long/
  // unsigned long long are 3 distinct types even when some are same-size).
  template <class T>
  HOST_DEVICE_FUN inline int countLeadingZeros(T x)
  {
    if constexpr (sizeof(T) == 4)
    {
#ifdef __CUDA_ARCH__
      return __clz(int(x));
#else
      if (x == 0)
        return 32;
      return __builtin_clz(static_cast<unsigned>(x));
#endif
    }
    else
    {
#ifdef __CUDA_ARCH__
      return __clzll(static_cast<long long>(x));
#else
      if (x == 0)
        return 64;
      return __builtin_clzll(static_cast<unsigned long long>(x));
#endif
    }
  }

  // -------------------------------------------------------------------------
  // SFC key <-> octree-level helpers
  // -------------------------------------------------------------------------

  //! @brief SFC key range covered by a node at the given octree subdivision level
  template <class KeyType>
  HOST_DEVICE_FUN constexpr KeyType nodeRange(unsigned level)
  {
    unsigned shifts = maxTreeLevel<KeyType>{} - level;
    return KeyType(1ul << (3u * shifts));
  }

  //! @brief octree subdivision level corresponding to a (power-of-8) key range
  template <class KeyType>
  HOST_DEVICE_FUN constexpr unsigned treeLevel(KeyType range)
  {
    return (countLeadingZeros(range - 1) - unusedBits<KeyType>{}) / 3;
  }

  //! @brief extract the n-th octal digit from an SFC key, counting from the most
  //! significant
  template <class KeyType>
  HOST_DEVICE_FUN constexpr unsigned octalDigit(KeyType code, unsigned position)
  {
    return unsigned(code >> (3u * (maxTreeLevel<KeyType>{} - position))) & 7u;
  }

  //! @brief ceil(log8(n))
  template <class KeyType>
  HOST_DEVICE_FUN constexpr unsigned log8ceil(KeyType n)
  {
    if (n == 0)
      return 0;
    unsigned lz = countLeadingZeros(n - 1);
    return maxTreeLevel<KeyType>{} - (lz - unusedBits<KeyType>{}) / 3;
  }

  //! @brief convert a plain SFC key into Warren-Salmon placeholder-bit format
  template <class KeyType>
  HOST_DEVICE_FUN constexpr KeyType encodePlaceholderBit(KeyType code,
                                                         int prefixLength)
  {
    int nShifts = 3 * maxTreeLevel<KeyType>{} - prefixLength;
    KeyType placeHolderMask = KeyType(1) << prefixLength;
    return placeHolderMask | (code >> nShifts);
  }

  //! @brief cut an SFC key down to the start of its enclosing node at the given
  //! level
  template <class KeyType>
  HOST_DEVICE_FUN constexpr KeyType enclosingBoxCode(KeyType key,
                                                     unsigned level)
  {
    KeyType mask = nodeRange<KeyType>(level) - 1;
    return key & ~mask;
  }

  // -------------------------------------------------------------------------
  // Morton encode/decode
  // -------------------------------------------------------------------------
  namespace bits
  {
    //! @brief spread the low 10 bits of v so each occupies every 3rd bit (3D Morton
    //! interleaving)
    HOST_DEVICE_FUN constexpr std::uint32_t expandBits(std::uint32_t v)
    {
      v &= 0x000003ffu;
      v = (v * 0x00010001u) & 0xFF0000FFu;
      v = (v * 0x00000101u) & 0x0F00F00Fu;
      v = (v * 0x00000011u) & 0xC30C30C3u;
      v = (v * 0x00000005u) & 0x49249249u;
      return v;
    }

    //! @brief inverse of expandBits(uint32_t)
    HOST_DEVICE_FUN constexpr std::uint32_t compactBits(std::uint32_t v)
    {
      v &= 0x09249249u;
      v = (v ^ (v >> 2u)) & 0x030c30c3u;
      v = (v ^ (v >> 4u)) & 0x0300f00fu;
      v = (v ^ (v >> 8u)) & 0xff0000ffu;
      v = (v ^ (v >> 16u)) & 0x000003ffu;
      return v;
    }

    //! @brief spread the low 21 bits of v so each occupies every 3rd bit (3D Morton
    //! interleaving)
    HOST_DEVICE_FUN constexpr std::uint64_t expandBits(std::uint64_t v)
    {
      std::uint64_t x = v & 0x1fffffull;
      x = (x | x << 32u) & 0x001f00000000ffffull;
      x = (x | x << 16u) & 0x001f0000ff0000ffull;
      x = (x | x << 8u) & 0x100f00f00f00f00full;
      x = (x | x << 4u) & 0x10c30c30c30c30c3ull;
      x = (x | x << 2u) & 0x1249249249249249ull;
      return x;
    }

    //! @brief inverse of expandBits(uint64_t)
    HOST_DEVICE_FUN constexpr std::uint64_t compactBits(std::uint64_t v)
    {
      v &= 0x1249249249249249ull;
      v = (v ^ (v >> 2u)) & 0x10c30c30c30c30c3ull;
      v = (v ^ (v >> 4u)) & 0x100f00f00f00f00full;
      v = (v ^ (v >> 8u)) & 0x001f0000ff0000ffull;
      v = (v ^ (v >> 16u)) & 0x001f00000000ffffull;
      v = (v ^ (v >> 32u)) & 0x00000000001fffffull;
      return v;
    }
  } // namespace bits

  template <class KeyType>
  HOST_DEVICE_FUN KeyType iMorton(unsigned ix, unsigned iy, unsigned iz)
  {
    if constexpr (sizeof(KeyType) == 4)
    {
      std::uint32_t xx = bits::expandBits(std::uint32_t(ix));
      std::uint32_t yy = bits::expandBits(std::uint32_t(iy));
      std::uint32_t zz = bits::expandBits(std::uint32_t(iz));
      return KeyType(xx * 4 + yy * 2 + zz);
    }
    else
    {
      std::uint64_t xx = bits::expandBits(std::uint64_t(ix));
      std::uint64_t yy = bits::expandBits(std::uint64_t(iy));
      std::uint64_t zz = bits::expandBits(std::uint64_t(iz));
      return KeyType(xx * 4 + yy * 2 + zz);
    }
  }

  struct Coord3
  {
    unsigned x, y, z;
  };

  template <class KeyType>
  HOST_DEVICE_FUN Coord3 decodeMorton(KeyType code)
  {
    if constexpr (sizeof(KeyType) == 4)
    {
      return {bits::compactBits(std::uint32_t(code >> 2)),
              bits::compactBits(std::uint32_t(code >> 1)),
              bits::compactBits(std::uint32_t(code))};
    }
    else
    {
      return {unsigned(bits::compactBits(std::uint64_t(code >> 2))),
              unsigned(bits::compactBits(std::uint64_t(code >> 1))),
              unsigned(bits::compactBits(std::uint64_t(code)))};
    }
  }

  // -------------------------------------------------------------------------
  // Hilbert encode/decode (cubic, i.e. all 3 axes use the full KeyType bit
  // budget -- this project's non-cubic boxes just leave an axis's unused
  // high bits at 0, same as decodeMorton/iMorton above, so no separate
  // mixed-bit-width Hilbert variant is needed)
  // -------------------------------------------------------------------------

  // maps a Morton-style octant index (bit2=x, bit1=y, bit0=z) to the order in
  // which the Hilbert curve visits that octant
  HOST_DEVICE_FUN constexpr unsigned mortonToHilbertOctant(unsigned octant)
  {
    constexpr unsigned char table[8] = {0, 1, 3, 2, 7, 6, 4, 5};
    return table[octant];
  }

  template <class KeyType>
  HOST_DEVICE_FUN KeyType iHilbert(unsigned px, unsigned py, unsigned pz)
  {
    KeyType key = 0;

    for (int level = int(maxTreeLevel<KeyType>{}) - 1; level >= 0; --level)
    {
      unsigned xi = (px >> level) & 1u;
      unsigned yi = (py >> level) & 1u;
      unsigned zi = (pz >> level) & 1u;

      unsigned octant = (xi << 2) | (yi << 1) | zi;
      key = (key << 3) + mortonToHilbertOctant(octant);

      // rotate/reflect (px, py, pz) into the orientation of the sub-cube
      // that was just entered, so the next iteration recurses correctly
      px ^= 0u - (xi & ((!yi) | zi));
      py ^= 0u - ((xi & (yi | zi)) | (yi & (!zi)));
      pz ^= 0u - ((xi & (!yi) & (!zi)) | (yi & (!zi)));

      if (zi)
      {
        unsigned t = px;
        px = py;
        py = pz;
        pz = t;
      }
      else if (!yi)
      {
        unsigned t = px;
        px = pz;
        pz = t;
      }
    }

    return key;
  }

  //! @brief inverse of iHilbert
  template <class KeyType>
  HOST_DEVICE_FUN Coord3 decodeHilbert(KeyType key)
  {
    unsigned px = 0, py = 0, pz = 0;
    const unsigned order = maxTreeLevel<KeyType>{};

    for (unsigned level = 0; level < order; ++level)
    {
      unsigned octant = unsigned(key >> (3 * level)) & 7u;
      unsigned xi = octant >> 2;
      unsigned yi = (octant >> 1) & 1u;
      unsigned zi = octant & 1u;

      if (yi ^ zi)
      {
        unsigned t = px;
        px = pz;
        pz = py;
        py = t;
      }
      else if ((!xi & !yi & !zi) || (xi & yi & zi))
      {
        unsigned t = px;
        px = pz;
        pz = t;
      }

      unsigned mask = (1u << level) - 1;
      px ^= mask & (0u - (xi & (yi | zi)));
      py ^= mask & (0u - ((xi & ((!yi) | (!zi))) | ((!xi) & yi & zi)));
      pz ^= mask & (0u - ((xi & (!yi) & (!zi)) | (yi & zi)));

      px |= xi << level;
      py |= (xi ^ yi) << level;
      pz |= (yi ^ zi) << level;
    }

    return {px, py, pz};
  }

  //! @brief encode a coordinate as either a Morton or a Hilbert key,
  //! runtime-selected
  template <class KeyType>
  HOST_DEVICE_FUN KeyType sfcEncode(unsigned ix, unsigned iy, unsigned iz,
                                    bool hilbert)
  {
    return hilbert ? iHilbert<KeyType>(ix, iy, iz) : iMorton<KeyType>(ix, iy, iz);
  }

  //! @brief inverse of sfcEncode
  template <class KeyType>
  HOST_DEVICE_FUN Coord3 sfcDecode(KeyType code, bool hilbert)
  {
    return hilbert ? decodeHilbert<KeyType>(code) : decodeMorton<KeyType>(code);
  }

  // -------------------------------------------------------------------------
  // integer coordinate box + same-level neighbor lookup
  // -------------------------------------------------------------------------
  struct IBox
  {
    HOST_DEVICE_FUN IBox(int xmin, int xmax, int ymin, int ymax, int zmin,
                         int zmax)
        : xmin_(xmin),
          xmax_(xmax),
          ymin_(ymin),
          ymax_(ymax),
          zmin_(zmin),
          zmax_(zmax) {}

    HOST_DEVICE_FUN int xmin() const { return xmin_; }
    HOST_DEVICE_FUN int xmax() const { return xmax_; }
    HOST_DEVICE_FUN int ymin() const { return ymin_; }
    HOST_DEVICE_FUN int ymax() const { return ymax_; }
    HOST_DEVICE_FUN int zmin() const { return zmin_; }
    HOST_DEVICE_FUN int zmax() const { return zmax_; }

  private:
    int xmin_, xmax_, ymin_, ymax_, zmin_, zmax_;
  };

  //! @brief integer box covering the octree node starting at keyStart with the
  //! given level
  template <class KeyType>
  HOST_DEVICE_FUN IBox sfcIBox(KeyType keyStart, unsigned level, bool hilbert)
  {
    unsigned cubeLength = 1u << (maxTreeLevel<KeyType>{} - level);
    Coord3 c = sfcDecode<KeyType>(keyStart, hilbert);
    return IBox(int(c.x), int(c.x + cubeLength), int(c.y), int(c.y + cubeLength),
                int(c.z), int(c.z + cubeLength));
  }

  //! @brief map x into the periodic range [0:R)
  template <unsigned R>
  HOST_DEVICE_FUN constexpr int pbcAdjust(int x)
  {
    int ret = (x < 0) ? x + int(R) : x;
    return (ret >= int(R)) ? ret - int(R) : ret;
  }

  //! @brief smallest key contained in the same-level box shifted by (dx, dy, dz)
  //! cells
  template <class KeyType>
  HOST_DEVICE_FUN KeyType sfcNeighbor(const IBox &ibox, unsigned level, int dx,
                                      int dy, int dz, bool hilbert)
  {
    constexpr unsigned pbcRange = 1u << maxTreeLevel<KeyType>{};

    unsigned shift = unsigned(ibox.xmax() - ibox.xmin());

    int x = pbcAdjust<pbcRange>(ibox.xmin() + dx * int(shift));
    int y = pbcAdjust<pbcRange>(ibox.ymin() + dy * int(shift));
    int z = pbcAdjust<pbcRange>(ibox.zmin() + dz * int(shift));

    return enclosingBoxCode(
        sfcEncode<KeyType>(unsigned(x), unsigned(y), unsigned(z), hilbert),
        level);
  }

  // -------------------------------------------------------------------------
  // floating-point bounding box + coordinate -> SFC key encoding
  // -------------------------------------------------------------------------
  struct AxesBits
  {
    unsigned x, y, z;
  };

  template <class T>
  class Box
  {
  public:
    // host-only: only ever constructed once on the host, then copied by value
    // into kernels
    Box(T xmin, T xmax, T ymin, T ymax, T zmin, T zmax)
        : xmin_(xmin),
          ymin_(ymin),
          zmin_(zmin),
          ilx_(T(1) / (xmax - xmin)),
          ily_(T(1) / (ymax - ymin)),
          ilz_(T(1) / (zmax - zmin)),
          axesBits_(computeAxesBits(xmax - xmin, ymax - ymin, zmax - zmin)) {}

    HOST_DEVICE_FUN T xmin() const { return xmin_; }
    HOST_DEVICE_FUN T ymin() const { return ymin_; }
    HOST_DEVICE_FUN T zmin() const { return zmin_; }
    HOST_DEVICE_FUN T ilx() const { return ilx_; }
    HOST_DEVICE_FUN T ily() const { return ily_; }
    HOST_DEVICE_FUN T ilz() const { return ilz_; }

    // per-axis SFC bit depth for KeyType: shorter box edges get fewer bits so
    // non-cubic (aspect-ratio) boxes still cover their full extent with the
    // same key. Only the ratio between axes matters, not absolute size.
    template <class KeyType>
    HOST_DEVICE_FUN AxesBits boxDimBits() const
    {
      unsigned levels = maxTreeLevel<KeyType>{};
      return {levels - axesBits_.x, levels - axesBits_.y, levels - axesBits_.z};
    }

  private:
    static AxesBits computeAxesBits(T lx, T ly, T lz)
    {
      T maxDim = cmax(cmax(lx, ly), lz);
      constexpr T bias = T(0.5849625007211563); // 1 - log2(1/0.75)
      return {static_cast<unsigned>(std::floor(std::log2(maxDim / lx) + bias)),
              static_cast<unsigned>(std::floor(std::log2(maxDim / ly) + bias)),
              static_cast<unsigned>(std::floor(std::log2(maxDim / lz) + bias))};
    }

    T xmin_, ymin_, zmin_;
    T ilx_, ily_, ilz_;
    AxesBits axesBits_;
  };

  //! @brief encode a coordinate within box as an SFC key (Morton or Hilbert)
  template <class KeyType, class T>
  HOST_DEVICE_FUN KeyType sfc3D(T x, T y, T z, const Box<T> &box, bool hilbert)
  {
    AxesBits bits = box.template boxDimBits<KeyType>();

    const unsigned cubeLengthX = 1u << bits.x;
    const unsigned cubeLengthY = 1u << bits.y;
    const unsigned cubeLengthZ = 1u << bits.z;

    const T mx = T(cubeLengthX) * box.ilx();
    const T my = T(cubeLengthY) * box.ily();
    const T mz = T(cubeLengthZ) * box.ilz();

    // NOTE: floor happens before subtracting {x,y,z}min * m{x,y,z} -- keep this
    // exact order, it is not equivalent to floor((x - xmin) * mx) in general.
    int ix = int(std::floor(x * mx) - box.xmin() * mx);
    int iy = int(std::floor(y * my) - box.ymin() * my);
    int iz = int(std::floor(z * mz) - box.zmin() * mz);

    ix = cmin(ix, int(cubeLengthX) - 1);
    iy = cmin(iy, int(cubeLengthY) - 1);
    iz = cmin(iz, int(cubeLengthZ) - 1);

    assert(ix >= 0);
    assert(iy >= 0);
    assert(iz >= 0);

    return sfcEncode<KeyType>(unsigned(ix), unsigned(iy), unsigned(iz), hilbert);
  }

  // -------------------------------------------------------------------------
  // coordinates -> SFC keys (GPU kernel)
  // -------------------------------------------------------------------------
  template <class KeyType, class PermIndex, class Real>
  __global__ void computeSfcKeysKernel(KeyType *keys, PermIndex *perm,
                                       const Real *x, const Real *y,
                                       const Real *z, std::size_t numKeys,
                                       Box<Real> box, bool hilbert)
  {
    std::size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < numKeys)
    {
      keys[tid] = isEscapedParticle(x[tid], y[tid], z[tid])
                      ? KeyType(-1)
                      : sfc3D<KeyType>(x[tid], y[tid], z[tid], box, hilbert);
      perm[tid] = static_cast<PermIndex>(tid);
    }
  }

  template <class KeyType, class PermIndex, class Real>
  void computeSfcKeys(execution::Gpu exec, const Real *x, const Real *y,
                      const Real *z, KeyType *keys, PermIndex *perm,
                      std::size_t numKeys, const Box<Real> &box, bool hilbert)
  {
    if (numKeys == 0)
      return;

    constexpr int nThreads = defaults::blockThreads;
    computeSfcKeysKernel<<<iceil(numKeys, nThreads), nThreads, 0, exec>>>(
        keys, perm, x, y, z, numKeys, box, hilbert);

#ifndef NDEBUG
    checkGpuErrors(cudaGetLastError());
#endif
  }

} // namespace adaptive_octree::detail
