# Adaptive 3D Trees

GPU adaptive octrees and binary trees for particle data. `Tree<Real, Kind>` selects
the implementation at compile time using `TreeType::Octree` or `TreeType::Binary`.
Both provide sorted particle keys `P`, permutation `Perm`, leaf boundaries `K`,
and populations `N` through the same API.

```cpp
#include <adaptive_octree/tree.hpp>

using Tree = adaptive_octree::Tree<double, adaptive_octree::TreeType::Binary>;
Tree::Config config;
config.maxParticlesPerLeaf = 64;
config.box = {0., 1., 0., 2., 0., 8.};
config.stream = stream; // caller-owned CUDA stream

Tree tree(x_d, y_d, z_d, count, config);
tree.build();
tree.update();
while (tree.doBuffersNeedResize()) {
    tree.resizeBuffers();
    tree.update();
}
```

Change the template argument to select an octree. The wrapper stores that backend
directly, with no runtime selection or extra allocation. The two choices are
different C++ types. Direct
`Octree<Real>` and `KDTree3D<Real>` APIs remain available in `octree.hpp` and
`kdtree3d.hpp`, respectively, in the `adaptive_octree` namespace.

`Config::views` selects structure, populations, and particle mappings for both
tree types. `Config::splitCriterion` supports `LeafCount` for both types;
**NFCount is currently implemented only for Octree.** Binary mode rejects NFCount.
Octree also supports Morton/Hilbert through `Config::sfcKind`. Binary keys always
follow the longest-side split schedule; selecting Hilbert raises an error.
`nearFieldCounts_d()` and `sfcKind()` currently require Octree mode.

Implementation files are grouped in `src/octree/`, `src/kdtree3d/`, and
`src/common/`. Public headers stay in `include/adaptive_octree/`; `tree.hpp`
contains the thin wrapper. Both backends use the view builder in
`src/common/tree_view.cu`, instantiated for one or three bits per level.

Shared types, enums, configuration structs, defaults, sentinels, and macros
are defined in `include/adaptive_octree/config.hpp`. This includes NVTX switches,
CUDA error checks, leaf limits, update passes, launch sizes, buffer headroom,
and benchmark defaults. `Tree::Config`, `Octree::Config`, and `KDTree3D::Config`
alias those definitions. `config.hpp` replaces the former `types.hpp`,
`particle_status.hpp`, and `nvtx.hpp` headers.
CUDA/Thrust implementation functions stay in `src/common/helpers.cuh`;
`sfc_keys.cuh` contains the key algorithms. Build switches such as profiling
and benchmark CSV output remain CMake options.

`Config::maxDepth` and `Config::updateIterations` use `-1` for the backend
defaults: depth 21 / 63 and update passes 2 / 20 for Octree / Binary.
Binary enforces its depth limit, including explicit depth zero for a root-only
tree. The restored octree retains its existing behavior: its configurable
depth limit is not enforced. The wrapper is noninteractive.

## Build and run

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
./build/tests/tree_example
./build/tests/tree_example particles.dat
```

`tests/` has three programs:

- `tree_example.cu`: a straight-line `main()` that reads particles, uploads them,
  builds a binary tree with LeafCount and all views, accesses the arrays, and updates.
  Input rows are `charge x y z` or `ESC`; without an argument it uses the included
  verification snapshot. Change its template argument to try octree mode.
- `tree_test.cu`: the consolidated regression suite for both backends and the
  template wrapper, including graph capture and resize.
- `bench_snapshots.cu`: dataset/series benchmarks and plotting exports. Its
  `--tree` and `--criterion` options select which implementations to benchmark.

`particle_io.hpp` is the shared reader. Test data and saved reference arrays
remain in their existing folders.

## Tree representation

Both backends store the same leaf arrays:

- `P`: sorted spatial keys, including escaped particles at the end.
- `Perm`: original input slot for each sorted key.
- `K`: sorted key boundaries with `leaves + 1` entries. Each
  `[K[i], K[i+1])` describes one leaf cell. The root is `{0, 1ULL << 63}`.
- `N`: active particle count in each leaf's key range.

Counts are differences between sorted particle positions at leaf boundaries.
Escaped particles keep their input slots, with all coordinates equal to
`escapedParticleCoordinate<Real>`. Their keys are `invalidParticleKey`, ordered
after active keys. `P` and `Perm` retain all slots; `N` excludes escaped slots.
`numParticles()` reports slots, `numActiveParticles()` reports active particles,
and `numActiveParticles_d()` supplies the device count for downstream kernels.
Host getters reflect the last build or status refresh.

### Octree

Keys follow Morton or Hilbert order, selected by `Config::sfcKind`. Each level
uses three key bits and divides a cell into eight octants. A depth-`d` cell spans
`1ULL << (63 - 3*d)` keys, allowing depths 0–21. Splitting adds seven boundaries
to `K`; merging eight sibling leaves removes those boundaries. A rebalance pass
can split through several levels at once.

With `LeafCount`, refinement uses `N` and eight siblings merge when their total
population fits `Config::maxParticlesPerLeaf`. With `NFCount`, refinement uses
the additional `NF` array: each leaf's population multiplied by the population
of its periodic 3×3×3 same-level neighborhood, including itself. Repeated cells
at shallow depths retain their stencil multiplicity. `nearFieldCounts_d()`
exposes these interaction estimates, capped at the maximum `unsigned` value.

### Binary

The box determines one split-axis sequence: repeatedly bisect the longest
physical side, breaking ties X, Y, Z. Particle coordinate bits are interleaved
directly in that order. Every prefix describes one cell, so splitting inserts
the midpoint key and merging removes the boundary between two sibling leaves.
Each level uses one key bit, and a depth-`d` cell spans `1ULL << (63 - d)` keys.
The sequence covers depths 0–63: 64 tree levels including the root. Rectangular
boxes have no per-axis 21-bit limit. The key sequence does not depend on the
configured maximum tree depth.

Binary currently implements particle-count refinement. A leaf splits when
`N > Config::maxParticlesPerLeaf` (default 64), up to `Config::maxDepth`
(default 63). Siblings merge when their combined population fits the same limit.

## CUDA graph updates

`build()` starts at the root and runs until convergence, growing storage outside
capture. `update()` submits the configured number of passes, with
no allocation, host readback, or host buffer swapping. Logical leaf counts,
convergence, resize status, and active A/B selection remain on the device.

Set `Config::stream` to a non-default capture stream. After graph replay or a
direct update, call `doBuffersNeedResize()` outside capture to publish host sizes
and the active buffer. Overflow rejects the entire topology proposal, preserving
valid K/N. `resizeBuffers()` grows storage by 25%; recapture afterwards. A clear
resize flag means sufficient capacity, not convergence.

Binary `numNodes()` reports `2 * leaves - 1`. With views disabled, internal nodes
are not materialized and its `maxAchievedDepth()` queries K after status refresh.
With views enabled, both backends expose the arrays described below. Octree's
depth getter requires a view to be built.
See [bench_snapshots.cu](tests/bench_snapshots.cu) for replay and recapture.

## Tree views

Both types provide `sfcBoxIndex_d`, `boxDepth_d`, `hasBoxSplit_d`, `parentIndex_d`,
`childIndex_d`, `levelOffset_d`, `particleBeginIndex_d`, `particleCounts_d`, and
`sfcParticleIndex_d`. Enabling any view builds the structure; the two particle
flags enable their respective arrays.

Nodes are grouped by depth. Within the next level, all child-0 nodes come first,
then all child-1 nodes, and so on, in parent order. `childIndex_d[parent]` is the
first child. Consecutive children of that parent are separated by the next
level's width divided by 2 (binary) or 8 (octree). The root parent and leaf child
indices are `invalidNodeIndex`.

`sfcBoxIndex_d` contains each node's path preceded by a placeholder bit: binary
root 1, children 2 and 3, using one path bit per depth; octree uses three bits per
depth. `levelOffset_d` has 65 entries for binary and 23 for octree; unused trailing
offsets equal `numNodes()`. Per-box counts include a trailing active-particle
total. Particle mappings use sorted-key order, with escaped backing slots set to
`invalidParticleNodeIndex`.

Set `Config::views` before building to prepare storage for captured updates.
`computeViews(flags)` can also request views later. If new storage is needed,
it sets the usual resize flag: call `resizeBuffers()` and retry `computeViews`
outside capture, then recapture any graphs that use those buffers. Subsequent
`update()` calls rebuild the views selected in the original config.

## Benchmarks and visualization

```bash
./plot_py/plot_snapshots.sh --dataset tests/test_data/simdata --leaf-limit 64 --nf-limit 110592
./plot_py/plot_snapshots.sh --tree octree --criterion nfcount --dataset tests/test_data/halo_25600000.dat --repeats 20
```

The script builds with `ADAPTIVE_OCTREE_BENCH_CSV=ON`, runs the benchmark, generates
the metric plots, and starts the interactive viewer. The same arguments work
with `./build/tests/bench_snapshots` without launching plots. By default it
benchmarks all three supported combinations: binary LeafCount, octree LeafCount,
and octree NFCount. Every combination computes all view arrays. `--tree`
accepts `all`, `binary`, or `octree`; `--criterion` accepts `all`, `leafcount`, or
`nfcount`. Binary NFCount is not implemented. There are no prompts.

`--dataset` accepts a folder or file. Folder formats are `xyz_N` (`x y z charge`),
`snapshot_NNNNNN.dat`, and `cluster-NNNN.dat` (both `charge x y z`). A single file
uses `x y z charge`. `--last-snapshot N` limits frame IDs; `--stride N` selects IDs
divisible by N. `--leaf-limit N` sets the LeafCount population limit (default 64);
`--nf-limit N` sets the NFCount interaction limit (default 110592 = 64² × 27).
Single-file runs average `--repeats N` warmed updates (default 20). Without a path,
`--series` selects simdata; `--halo`, the default, selects halo_25600000.dat.

The benchmark compares direct launches with graph replay and checks P, Perm, K,
N, NF when enabled, and every view array after each update. `tree_ms` measures
tree updates and `view_ms` measures `computeViews()` separately using GPU events;
`graph_tree_ms` and `graph_view_ms` measure the same phases during replay.
`compute_total_ms` and `graph_compute_total_ms` are wall times covering both
phases, launch, completion, and the status check. Resize and graph capture costs
have separate columns. Initial tree/view builds are not captured; their first
series row reports wall times including allocation and preparation.

Selected snapshots share one rectangular domain, with independent 5% padding on
each side of each axis and a small positive width for flat axes. Particle slot
counts must stay constant: replace escaped rows with `ESC` rather than deleting
them. Blank lines and comments do not occupy slots. Bounds ignore escaped rows;
at least one selected frame must contain an active particle.

The octree's existing encoder reduces coordinate bit depth on short axes.
Its full key space can therefore include empty cells beyond the input domain.
Exports preserve these cells and record separate `tree_*` bounds for the viewer;
binary cells cover exactly the rectangular input domain.

Outputs:

- `bench_snapshots.csv`: timings, statistics, and particle totals for each
  `(tree_type, split_criterion, snapshot)` combination.
- `tree_frames/runs.csv`: the combinations produced by the current run.
- `tree_frames/<run>/domain.csv`: tree type, criterion, rectangular bounds,
  dataset path/layout, and selected frames.
- `tree_frames/<run>/frames.csv`: active/escaped/slot totals for each exported frame.
- `tree_frames/<run>/tree_*.csv`: one row per leaf with physical bounds, depth,
  `particle_count`, `key_begin`, and `key_end`.
- `bench_snapshots_<run>.png`: metrics for each combination, and
  `bench_snapshots_comparison.png`: octree/binary comparisons. A single-combination
  run writes `bench_snapshots.png` instead.

Here `<run>` is `binary_leafcount`, `octree_leafcount`, or `octree_nfcount`.
The viewer lets you select a combination and shows benchmark plots beside the
3D tree. A marker on every plot tracks the snapshot slider using actual snapshot
IDs. Switching combinations preserves the selected snapshot. Tree, view, and
total timings are shown separately. The viewer checks particle totals against
the source data and also accepts the older single-run `tree_frames` layout.

## Other scripts

`./tests/run_verification.sh` builds and runs `tree_test`. It retains the octree
reference-array checks, independent binary CPU geometry oracle, and wrapper
checks for captured updates, escaped particles, resize/recapture, and supported
options. Catch2 arguments are forwarded, e.g. `./tests/run_verification.sh '[binary]'`.

`./tests/profile.sh [particles.dat]` builds the example with profiling enabled and runs Nsight
Systems and Nsight Compute. Reports go in timestamped `profiling_reports` folders.
