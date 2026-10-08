#pragma once

#include <cmath>
#include <stdexcept>

#include "adaptive_octree/kdtree3d.hpp"
#include "../common/sfc_keys.cuh"

namespace adaptive_octree::detail::kdtree3d
{
    // Every cell at a given depth has the same shape, so one schedule suffices.
    struct BinaryGeometry
    {
        std::uint8_t axis[maxBinaryDepth]{};
    };

    template <class Real>
    BinaryGeometry makeBinaryGeometry(const adaptive_octree::Box<Real> &box,
                                      unsigned maxDepth = maxBinaryDepth)
    {
        if (maxDepth > maxBinaryDepth)
            throw std::invalid_argument("Binary maxDepth exceeds key precision");
        long double length[3] = {static_cast<long double>(box.xmax) - box.xmin,
                                 static_cast<long double>(box.ymax) - box.ymin,
                                 static_cast<long double>(box.zmax) - box.zmin};
        for (auto side : length)
            if (!(side > 0) || !std::isfinite(side))
                throw std::invalid_argument("Tree box must have finite positive sides");

        BinaryGeometry geometry;
        for (unsigned depth = 0; depth < maxBinaryDepth; ++depth)
        {
            unsigned axis = 0;
            if (length[1] > length[axis]) axis = 1;
            if (length[2] > length[axis]) axis = 2;
            geometry.axis[depth] = std::uint8_t(axis);
            length[axis] *= 0.5L;
        }
        return geometry;
    }

    // Interleave 63-bit fixed-point coordinates in longest-side split order.
    template <class Real>
    HOST_DEVICE_FUN inline KeyType binaryEncode(Real x, Real y, Real z,
                                                 const BinaryGeometry &geometry)
    {
        const auto fixed = [](Real value) {
            return cmin(KeyType(cmax(Real(0), cmin(Real(1), value)) * Real(maxKey)), maxKey - 1);
        };
        KeyType coordinate[3] = {fixed(x), fixed(y), fixed(z)};
        KeyType key = 0;
        for (unsigned depth = 0; depth < maxBinaryDepth; ++depth)
        {
            KeyType &value = coordinate[geometry.axis[depth]];
            key = (key << 1) | ((value >> (maxBinaryDepth - 1)) & 1);
            value <<= 1;
        }
        return key;
    }

    HOST_DEVICE_FUN inline unsigned binaryDepth(KeyType range)
    {
        return unsigned(countLeadingZeros(range));
    }

    HOST_DEVICE_FUN inline unsigned binaryDepth(KeyType start, KeyType end)
    {
        return binaryDepth(end - start);
    }

    struct BinaryBox
    {
        double min[3]{};
        double size[3]{1, 1, 1};
    };

    HOST_DEVICE_FUN inline BinaryBox binaryBox(KeyType start, KeyType end,
                                                const BinaryGeometry &geometry)
    {
        BinaryBox box;
        for (unsigned depth = 0; depth < binaryDepth(start, end); ++depth)
        {
            const unsigned axis = geometry.axis[depth];
            box.size[axis] *= 0.5;
            if ((start >> (maxBinaryDepth - 1 - depth)) & 1)
                box.min[axis] += box.size[axis];
        }
        return box;
    }

    HOST_DEVICE_FUN inline bool binarySiblings(const KeyType *tree,
                                                TreeNodeIndex count,
                                                TreeNodeIndex first)
    {
        if (first < 0 || first + 1 >= count) return false;
        const KeyType range = tree[first + 1] - tree[first];
        return !(tree[first] & range) && tree[first + 2] - tree[first + 1] == range;
    }
}
