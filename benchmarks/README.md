# Adaptive octree benchmark suite

Reproducible GPU benchmark of Cornerstone vs. my adaptive octree (v1, v2, v3)
following Hoefler & Belli, *Scientific Benchmarking of Parallel Computing Systems* (SC'15).
Nothing in `adaptive-octree/` or `cornerstone-octree/` is modified; versions are cloned to `src/`.

## Portable checkout

This folder contains the harness, compressed CSV results and environment records. Build
outputs, virtual environments, cloned sources, generated snapshots and plots are excluded.
Large CSVs are stored as `.csv.gz`, with their decompressed contents preserved exactly.
Analysis, merging and plotting accept both `.csv` and `.csv.gz` automatically. To unpack one,
use `gzip -dk data/raw_steps.csv.gz`; run `python3 csv_io.py` to compress large CSVs again.
New merged results and summary tables are compressed automatically above 1 MiB.
`data/source_csv/` preserves CSVs from the original source checkouts, including v1's old
snapshot benchmark and regression reference tables; these are archived, not merged into this suite.

Use Linux with Bash 4+, Python 3.11+ (including venv/pip), Git, CMake 3.22+, Make,
a CUDA toolkit and compatible C++20 host compiler, an NVIDIA GPU, and `taskset`/`nvidia-smi`.
The recorded run used CUDA 13.3, g++ 14.2 and `CUDA_ARCH=120`; select your GPU's architecture
and a compatible toolkit through the environment. `nvcc` and `g++` are discovered through PATH.
Python packages are pinned in `requirements.txt`.

Keep the source repositories and input data outside this folder, using this relative layout:

```text
workspace/
  adaptive-octree-bench/       # this repository
  adaptive-octree/             # Git repository containing all three pinned versions
    tests/test_data/           # input_test.txt, stmv_input.txt, halo_25600000.dat,
                               # simdata/, cluster/
  cornerstone-octree/          # Git repository for the cstone baseline
  cornerstone-octree-v1/       # Git repository for v1's corrected Cornerstone fork
  coulomb_explosion_ts/
    frames_more/              # Coulomb series
```

Supply these repositories and datasets separately; large particle inputs are not bundled.
The adaptive repository and v1 fork were hosted on the original project's Forgejo server
and may require access. Setup uses local Git clones and requires the full commit IDs in
`config.sh` to exist in those clones. Cornerstone's baseline is from
`https://github.com/sekelle/cornerstone-octree`. The adaptive repository must also contain
its checked-in test fixtures (`tests/test_data/input.dat` and `tests/verification_data/`).
CMake downloads Catch2 when building the v2/v3 tests. No benchmark input is downloaded by setup.

All configurable relative paths are interpreted from this folder, even when a script is
invoked from another working directory. Override the layout, for example:

```bash
REPO=../sources/adaptive-octree CSTONE_REPO=../sources/cornerstone-octree \
V1_CSTONE_SRC=../sources/cornerstone-octree-v1 DATA_ROOT=../inputs ./run_all.sh
```

`setup.sh` creates `.venv` and installs `requirements.txt` on the first run. To regenerate
plots from the included CSVs without GPU setup:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python plot.py
.venv/bin/python plot.py --talk
```

To repeat measurements while keeping the included results, choose a new output directory:

```bash
DATA_DIR=results/repeat PLOTS_DIR=results/repeat/plots ./run_all.sh
```

The original `data/` CSVs are preserved; old correctness gates and completion markers are
excluded so they cannot silently skip new measurements. NaCl is always needed for the
correctness smoke tests; include `nacl` when using `DATASETS_OVERRIDE`. `PIN_CPU` defaults
to the original core 4; override it to an allowed core on your machine. The optional
full-pipeline FMM aggregates are already included in `data/`; for a new output directory,
use `PIPELINE_CSV=data/octree_comparison_source.csv` to copy them. This suite does not
re-run the separate FMM harness.

## How to run

```bash
./run_all.sh                         # setup -> gen -> test -> bench -> analyze -> plot, log in logs/run_all_*.log
STEPS="bench analyze plot" ./run_all.sh   # any subset; every step also runs on its own:
./setup.sh                           # clone + checkout + build all versions (+ their tests + drivers)
.venv/bin/python gen_snapshots.py    # manifests, shared bounding boxes, noisy snapshots (once)
./test.sh                            # correctness gate -> data/correctness.csv, data/gate_<v>.txt
./bench.sh                           # measurement matrix -> data/raw/**, data/raw_steps.csv, data/raw_initial_build.csv
.venv/bin/python analyze.py          # statistics -> data/summary.csv (+ determinism, bar and pipeline tables)
.venv/bin/python plot.py             # plots/*.png (300 dpi), *.webp, *.pdf
```

`bench.sh` is resumable (finished cells have `data/raw/<v>/<cfg>/<ds>/DONE`) and prints progress
per process. Overrides (env): `W R_MIN R_MAX CI_TOL COLD_REPS`, `DATASETS_OVERRIDE="nacl flyby"`,
`DATA_DIR`, `PLOTS_DIR`, `PIN_CPU`. A quick pipeline check (not for slides):
`DATA_DIR=results/check PLOTS_DIR=results/check/plots DATASETS_OVERRIDE="nacl flyby" MAX_SNAPSHOTS=30 W=1 R_MIN=3 R_MAX=4 COLD_REPS=3 ./bench.sh`.
The Python environment is `.venv` (numpy, scipy, pandas, matplotlib, pillow).

Expected duration of the full run: several hours (Coulomb explosion = 7088 snapshots and
Flyby = 1201 snapshots per run, ≥ 13 processes per cell, plus 30 cold-build processes per cell).

## Versions

| id | source | commit | path |
|---|---|---|---|
| cstone | `cornerstone-octree` @ d7fddfb4 | `env/commit_cstone.txt` | direct |
| v1 | my repo @ e7bd16a8ad | `env/commit_v1.txt` | direct |
| v2 | my repo @ ea89b79a9d | `env/commit_v2.txt` | direct |
| v3 | my repo @ d830fc32 | `env/commit_v3.txt` | CUDA graph |

**Legacy test paths**: setup changes only the v1/v2 test fixture paths in disposable clones
to resolve from the test source directory. Library and benchmark code stay at their pinned versions.

**v1 submodule**: `external/cornerstone` is cloned from the local fork
`../cornerstone-octree-v1` (`V1_CSTONE_SRC`) and pinned to **efd7e418**, not
to e7bd16a's recorded pointer bd98719d: bd98719d lacks the API e7bd16a calls
(`computeNFCountsAndGroupCanMergeGpu`, new `updateOctreeGpu`/`computeSfcKeys` signatures). The fork
commit efd7e418 was made one minute after e7bd16a, and the next repo commit 6f11cac ("Update
cornerstone submodule") changes only that pointer — so the built v1 equals the tree of 6f11cac.

Toolchain (identical for all): nvcc 13.3, g++ 14.2 host compiler, `CMAKE_BUILD_TYPE=Release`,
`-O3 -DNDEBUG -lineinfo --extended-lambda` (the last one only because Cornerstone's GPU unit tests
need it), `sm_120`. Exact command lines are regenerated as `env/compile_commands_<v>.json` during setup.
Keys: 64-bit Morton everywhere. `setup.sh` checks the key typedefs, every driver
`static_assert`s `sizeof(KeyType) == 8`, v2/v3 drivers set and verify `SfcKind::Morton`, the
cstone driver uses `MortonKey<uint64_t>`.

v1's and v2's constructors always prompt on stdin for criterion and limit; their drivers answer
"default limit" through a redirected `std::cin` (patch-free; the defaults equal 64 / 64²·27).

## Configurations and parameters

| config | tree | criterion | limit |
|---|---|---|---|
| octree_leafcount | Octree (3 bits/level) | LeafCount | 64 |
| octree_nfcount | Octree | NFCount | 64·64·27 = 110592 (default in v1–v3) |
| kdtree3d_leafcount | KDTree3D (1 bit/level) | LeafCount | 64 |

cstone: octree_leafcount only. v1/v2: octree configs only. Max depth: library maximum
(not enforced for the octree; 63 for KDTree3D). v3 update passes: library defaults
(Octree 2, KDTree3D 6). All versions get the same bounding box (manifest) and the same particle order.

## Datasets

| id | source | type | slide name |
|---|---|---|---|
| coulomb_explosion | `coulomb_explosion_ts/frames_more` (7088 frames, 114 537 particles) | series | Coulomb explosion |
| flyby | `adaptive-octree/tests/test_data/simdata` (1201 frames, 512 002) | series | Flyby |
| dense_halo | `tests/test_data/halo_25600000.dat` (25.6 M) | single | Dense halo |
| nacl | `tests/test_data/input_test.txt` (6740) | single | NaCl |
| stmv | `tests/test_data/stmv_input.txt` (1 066 628) | single | STMV |
| cluster | `tests/test_data/cluster` (frames 0–52) | series | Cluster |
| cluster_full | `tests/test_data/cluster` (all 201 frames, escaped particles; v3 only) | series | Cluster (full) |

`datasets/<id>/manifest.txt` lists the shared padded bounding box (same 5 % per-axis padding as
the repo's `bench_snapshots.cu`, computed over all frames) and the ordered frames; sources are
referenced relative to the manifest file. Metadata source paths are relative to this folder. Single datasets get `noisy_001.bin` (float64 N×3): Gaussian noise
with σ = 1e-3 × bounding-box edge per axis, cumulative (`NOISY_SNAPSHOTS` > 1 adds further frames),
seed 20261001, clamped to the data bounding box; SHA-256 and parameters in `info.json`.

**Dense halo**: the 102.4 M halo does not fit on the 8 GB RTX 5060 for v2 and v3 (out of memory;
Cornerstone alone fits), so the 25.6 M halo is used. `bench.sh` still checks free GPU memory
before the dense halo and records `oom`/`failed` in `data/run_status.csv` instead of crashing.

## Correctness gate (`test.sh` → `data/correctness.csv`)

- cstone: `component_units` (329 tests), `component_units_cuda` (132 tests).
- v2: `adaptive_octree_test`, `octree_regression_test` (known-good reference arrays).
- v3: `tree_test` (Catch2, 18 test cases), `tree_example`.
- every version × config: harness smoke run on NaCl with invariant checks (library node count
  = harness node count, active + escaped = slots, phases ≤ total).
- Cornerstone vs. v3 Octree/LeafCount with **identical keys** (v3's sorted keys P fed to
  `cstone::updateOctreeGpu`, bucket 64, converged from the root) for every snapshot:
  `data/cstone_leafcount_check_<ds>.csv`. Besides leaf counts it counts violations of the
  (unique) converged LeafCount tree: overfull leaves and mergeable sibling groups.
  **Known result**: NaCl and STMV are identical; on Flyby v3's tree after `update()` (fixed 2
  passes, needed for graph capture) is not fully converged on most snapshots (≈ 76 overfull
  leaves / 49 mergeable groups out of ≈ 38 k leaves on average), whereas Cornerstone iterates to
  convergence. Mention this when comparing cstone vs. v3 LeafCount.

A version that fails is excluded from `bench.sh` (`data/gate_<v>.txt`).

## Measurement protocol (Hoefler & Belli rules applied)

- **Environment** (`env/`): GPU/driver/CUDA/nvcc/host compiler/CPU/OS, `nvidia-smi -q`, clocks
  and GPU processes before and after, host load, Python packages, commits, compile flags, date.
  Clock locking (`nvidia-smi -lgc`) needs root here → not permitted; clocks are recorded instead.
- **Isolation**: every process pinned with `taskset -c 4` (a P-core); `CUDA_MODULE_LOADING=EAGER`
  (no lazy kernel loading inside timed steps); `env.sh` warns if other GPU processes exist.
- **Cold initial build**: 30 separate processes; after `cudaFree(0)` and the coordinate upload,
  `initial_build_ms` = host wall time of construction (allocation) + build from the root + first
  view, synchronized (`initial_tree_gpu_ms` / `initial_view_gpu_ms`: GPU events).
- **Steps**: one run = a whole series in a fresh process starting at snapshot 0. W = 3 discarded
  warm-up runs (kept in `data/raw/**/warmup/`), then R measured runs: R ≥ 10, increased until the
  95 % CI of the median total_ms is within ±5 % of the median, max 50; R is in `data/run_status.csv`.
- Snapshot input is read and uploaded (synchronously) before each step, never inside timings.
- All raw samples are kept (`data/raw/**`, merged into `data/raw_steps.csv`).

### Phase boundaries (identical for all versions; cudaEvents on the version's stream)

`outerBegin` | `begin` | tree update | `treeEnd` | view | `end` | `outerEnd`, then host status check
and `cudaDeviceSynchronize`.

| column | definition |
|---|---|
| tree_update_ms | `begin → treeEnd` |
| view_ms | `treeEnd → end` |
| total_ms | `outerBegin → outerEnd` (graph: launch ↔ completion; includes host-induced gaps of direct paths) |
| wall_ms | host clock around the submission, status check and device sync (≙ the repo's `graph_compute_total_ms`) |

| version | tree update | view |
|---|---|---|
| v3 (graph) | `Tree::update()` captured in a graph; `begin/treeEnd/end` are external event nodes inside the graph | `computeViews({all})` |
| v2 (direct, legacy stream) | `Octree::update()` | `computeViews({all})` |
| v1 (direct, legacy stream) | `Octree::update()` | `buildFMSolvrView()` |
| cstone (direct, legacy stream) | `computeSfcKeys` + key/permutation radix sort + recount + `updateOctreeGpu` until converged | `OctreeData::resize` + `buildOctreeGpu` (internal-tree linking; closest equivalent of a TreeView) |

If v3 reports `doBuffersNeedResize()`, the step's buffers grow, the graph is recaptured
(`maintenance_ms`, not in the phases) and the step is replayed; phases sum over `attempts`.
Validation: v3 graph vs. direct path give identical trees and phase times within ~5 %;
Nsight Systems GPU spans agree with `total_ms` within ~2.5 % (v3 1.021 vs 0.999 ms,
cstone 0.950 vs 0.926 ms on STMV).

## Metrics (`data/raw_steps.csv`, one row per version × config × dataset × run × snapshot)

Timings above (snapshot 0 = initial build, timings NaN), `attempts`, `maintenance_ms`,
`iterations` (cstone rebalance iterations), and structural metrics recomputed identically for
every version from sorted keys P and leaf array K: `num_leaves`, `num_nodes` (L + (L−1)/7 resp.
2L−1), `max_depth` (levels below the root), `max_depth_octree_equiv` (KDTree3D: /3; octree: same),
`num_empty_leaves`, `empty_leaf_pct`, `avg_particles_per_leaf` (active / leaves),
`particles_active/escaped`, `particle_slots`, `lib_num_nodes` (library's own count, cross-check).
`analyze.py` checks that structural metrics are identical across runs (`data/determinism.csv`).

## Statistics (`data/summary.csv`)

Per (version, config, dataset, snapshot, metric) over runs, and `snapshot = pooled` over all
timed snapshots, plus `snapshot = initial` for cold builds: n, median, 95 % BCa bootstrap CI of the
median (`scipy.stats.bootstrap`, 10 000 resamples, `random_state` seeded), Shapiro–Wilk p
(`scipy.stats.shapiro`; approximate for n > 5000), min, max, mean, std, skewness.
Pooled CIs resample whole runs (cluster bootstrap) because steps of one run share history and are
not independent; the R stopping rule uses exactly this CI. Plots show medians with CI bars/bands only.

## Outputs

`data/raw_steps.csv`, `data/raw_initial_build.csv`, `data/summary.csv`, `data/correctness.csv`,
`data/run_status.csv`, `data/determinism.csv`, `data/implementation_runtime_summary.csv`
(median total/tree/view per bar, CI, speed-up vs cstone), `data/full_pipeline.csv`,
`data/octree_comparison_source.csv`, `data/cstone_leafcount_check_<ds>.csv`.

## Plots → slides

| file | slide |
|---|---|
| `plots/implementation_runtime.*` | implementation comparison (cstone/LeafCount, v3/LeafCount, v1–v3/NFCount) per dataset |
| `plots/<ds>_octree_leafcount.*`, `plots/<ds>_octree_nfcount.*` | per-dataset octree behaviour (fastest version of that config) |
| `plots/<ds>_kdtree3d_leafcount.*` | per-dataset KDTree3D behaviour |
| `plots/<ds>_octree_vs_kdtree3d.*` | Octree vs. KDTree3D (v3, graph timings) |
| `plots/full_pipeline.*` | tree + view + FMM pipeline |

`<ds>` ∈ coulomb_explosion (Coulomb explosion), flyby (Flyby), dense_halo (Dense halo), nacl (NaCl), stmv (STMV).

## Full-pipeline source data

`data/octree_comparison_source.csv` contains the original FMM aggregates (25 rows, 72 columns),
produced by a separate FMM harness on an **RTX 5060 Ti 16 GB** (not this GPU). Main columns:
`input`, `implementation` (dense, first_complete, first_update_rebuild, first_update, newest),
`particles`, `split_criterion`, `bucket`, `incremental_update`, `fmm_graph`, `repetitions`,
`steps_per_repetition`, `warmup_steps_excluded`; per phase `{total,common,tree,view,lists,fmm}_ms`
with `_std_ms`, `_min_ms`, `_max_ms` (mean/std/min/max over repetitions);
`synchronized_*` (same phases with per-phase synchronization), `input_upload_ms`, provenance
(`binary_sha256`, `input_sha256`, `settings_json`, `effective_settings_json`, commits, GPU UUID,
CPU affinity) and numerical validation (`numerical_gate_passed`, `validation_*`).
FMM is one total (`fmm_ms`), not split into far/near field, and raw samples are not available,
so the FMM phases could **not** be re-measured with this protocol: `full_pipeline.csv` and the
plot show the source means (whiskers = min–max of repetition means), labelled as such. Its inputs
differ from this suite (e.g. `halo` = 1.2 M subsample).

## Deviations from the requested protocol

- v1 is built with its cornerstone submodule at efd7e418 (= repo commit 6f11cac) instead of bd98719d.
- Dense halo uses the 25.6 M file (102.4 M does not fit for v2/v3 on 8 GB).
- GPU clocks not locked (no root); recorded before/after instead.
- `numactl` not installed; pinning via `taskset`. Single NUMA node.
- Cornerstone's "view" is internal-tree linking, not an FMSolvr-style TreeView; its tree update
  converges every step, while v3 does a fixed number of passes (see correctness section).
- Pooled CIs use a run-level cluster bootstrap (still scipy BCa) instead of treating every step as independent.
- Full-pipeline FMM phases come from the source CSV (other GPU, means only), not re-measured.
- Cells are run sequentially (dataset → version → config), not in randomized order.
