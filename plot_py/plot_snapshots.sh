#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Entering project directory"
cd "$PROJECT_DIR"

echo "==> Configuring"
cmake -S . -B build \
    -DADAPTIVE_OCTREE_BENCH_CSV=ON

echo "==> Building bench_snapshots only"
cmake --build build \
    --target bench_snapshots \
    -j

echo "==> Benchmarking tree modes and all views, direct and graph replay"
# Forward tree, dataset and sampling options; default to the halo file.
# Example: --tree octree --dataset tests/test_data/simdata --stride 100.
./build/tests/bench_snapshots "$@"

echo "==> Activating Python environment"
source .venv/bin/activate

echo "==> Plotting benchmark metrics"
python3 plot_py/plot_benchmark_metrics.py \
    bench_snapshots.csv \
    -o bench_snapshots.png \
    --no-show

echo "==> Launching interactive tree viewer (leaf bounds from K)"
python3 plot_py/plot_octree_interactive.py

echo "==> Done"
echo "CSV:         $PROJECT_DIR/bench_snapshots.csv"
echo "Benchmarks:  $PROJECT_DIR/bench_snapshots_<tree>_<criterion>.png (all modes)"
echo "Comparison:  $PROJECT_DIR/bench_snapshots_comparison.png (all modes)"
echo "Single mode: $PROJECT_DIR/bench_snapshots.png"
echo "Tree frames: $PROJECT_DIR/tree_frames"
