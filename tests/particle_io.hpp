// particle_io.hpp
//
// Shared particle-file reader for tree_test, tree_example, and bench_snapshots.
// Reads whitespace-separated numeric columns
// from a text file, skipping blank lines and lines starting with '#' (e.g. a
// header/comment line), then picks out x, y, z according to the requested
// column layout. An ESC row preserves its particle slot and maps its
// coordinates to the escaped-particle marker.
#pragma once

#include <adaptive_octree/config.hpp>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

namespace particle_io
{
    // Column order of the particle files used in this project.
    enum class Layout
    {
        ChargeXYZ, // charge, x, y, z (coulomb-explosion snapshot format)
        XYZCharge, // x, y, z, charge (halo dataset format)
    };

    // Reads `numColumns` whitespace-separated doubles per line from path.
    // Lines that are empty or start with '#' are skipped. An ESC row fills
    // every column with the marker so either coordinate layout preserves it.
    inline std::vector<std::vector<double>> readColumns(const std::string &path, int numColumns)
    {
        if (numColumns <= 0 || numColumns > 16)
            throw std::invalid_argument("particle_io::readColumns: expected 1 to 16 columns");

        std::FILE *fp = std::fopen(path.c_str(), "rb");
        if (!fp)
            throw std::runtime_error("Could not open input file: " + path);

        std::fseek(fp, 0, SEEK_END);
        const long size = std::ftell(fp);
        std::fseek(fp, 0, SEEK_SET);

        std::vector<char> buf(static_cast<size_t>(size) + 1);
        const size_t nread = std::fread(buf.data(), 1, static_cast<size_t>(size), fp);
        std::fclose(fp);
        if (nread != static_cast<size_t>(size))
            throw std::runtime_error("Short read on file: " + path);
        buf[nread] = '\0';

        // Reserve based on line count so large files (e.g. 25M+ particles) don't
        // repeatedly reallocate/copy during push_back.
        const size_t numLines = static_cast<size_t>(
                                    std::count(buf.begin(), buf.begin() + nread, '\n')) +
                                1;

        std::vector<std::vector<double>> columns(static_cast<size_t>(numColumns));
        for (auto &col : columns)
            col.reserve(numLines);

        char *p = buf.data();
        char *end = p + nread;
        size_t lineNumber = 0;

        while (p < end)
        {
            char *row = p;
            char *rowEnd = std::find(p, end, '\n');
            p = rowEnd < end ? rowEnd + 1 : end;
            *rowEnd = '\0'; // Keep strtod from consuming values from the next row.
            ++lineNumber;

            auto skipWhitespace = [&row]
            {
                while (std::isspace(static_cast<unsigned char>(*row)))
                    ++row;
            };
            auto invalidRow = [&]
            {
                return std::runtime_error("Invalid particle row in " + path + ":" +
                    std::to_string(lineNumber) + "; expected numeric columns or ESC");
            };

            skipWhitespace();
            if (*row == '\0' || *row == '#')
                continue;

            double values[16];
            if (std::strncmp(row, "ESC", 3) == 0)
            {
                row += 3;
                skipWhitespace();
                if (*row != '\0' && *row != '#')
                    throw invalidRow();
                std::fill_n(values, numColumns,
                    adaptive_octree::escapedParticleCoordinate<double>);
            }
            else
            {
                for (int col = 0; col < numColumns; ++col)
                {
                    char *next = row;
                    values[col] = std::strtod(row, &next);
                    if (next == row || (*next != '\0' && *next != '#' &&
                        !std::isspace(static_cast<unsigned char>(*next))))
                        throw invalidRow();
                    row = next;
                    skipWhitespace();
                }
            }

            for (int col = 0; col < numColumns; ++col)
                columns[static_cast<size_t>(col)].push_back(values[col]);
        }

        return columns;
    }

    // Reads x, y, z coordinates from a 4-column particle file. The charge
    // column is parsed (to keep column indexing correct) but discarded.
    inline std::tuple<std::vector<double>, std::vector<double>, std::vector<double>>
    readParticles(const std::string &path, Layout layout)
    {
        auto cols = readColumns(path, 4);

        switch (layout)
        {
        case Layout::ChargeXYZ:
            return {std::move(cols[1]), std::move(cols[2]), std::move(cols[3])};
        case Layout::XYZCharge:
            return {std::move(cols[0]), std::move(cols[1]), std::move(cols[2])};
        }

        throw std::invalid_argument("particle_io::readParticles: unknown layout");
    }

} // namespace particle_io
