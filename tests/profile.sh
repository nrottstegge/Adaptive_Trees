#!/usr/bin/env bash
# Usage: ./tests/profile.sh [particles.dat]. Profiles the straight-line example.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
EXE="$BUILD_DIR/tests/tree_example"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
REPORT_DIR="$ROOT_DIR/profiling_reports/$TIMESTAMP"
NSYS_BASE="$REPORT_DIR/tree_nsys"
NCU_BASE="$REPORT_DIR/tree_ncu"
mkdir -p "$REPORT_DIR"

cmake -S "$ROOT_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DADAPTIVE_OCTREE_PROFILING=ON
cmake --build "$BUILD_DIR" -j"$(nproc)" --target tree_example

nsys profile --force-overwrite=true --trace=cuda,nvtx,osrt --sample=none \
    --cuda-memory-usage=true --output="$NSYS_BASE" "$EXE" "$@"
nsys stats --force-export=true "$NSYS_BASE.nsys-rep" | tee "$NSYS_BASE.txt"

ncu -f --set basic --target-processes all -o "$NCU_BASE" "$EXE" "$@"
ncu --import "$NCU_BASE" --page details

echo "Profiling reports: $REPORT_DIR"
