# Adaptive tree benchmarks

Benchmark suite from Nils Rottstegge's 2026 Guest Student Programme at JSC,
Forschungszentrum Jülich. Compares Cornerstone with three historical adaptive-tree
implementations (v1–v3); v3 also includes binary trees and CUDA graph updates.
This folder contains the harness, recorded CSV results, and environment records.

[Repository overview](../README.md) ·
[Report](https://nrottstegge.github.io/Adaptive_Trees/report/) ·
[Slides](https://nrottstegge.github.io/Adaptive_Trees/slides/)

## Rebuild plots from included results

No GPU or historical source checkout is needed. Requires Python 3.11+ with
venv/pip; packages are pinned in `requirements.txt`. From the repository root:

```bash
cd benchmarks
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python plot.py
.venv/bin/python plot.py --talk
```

Plots go to `plots/` and `plots/talk/`. Analysis and plotting accept `.csv` and
`.csv.gz`; large archived tables are compressed. To recompute summary statistics:

```bash
.venv/bin/python analyze.py
```

`data/source_csv/` holds historical source tables, separate from the suite's merged
measurements. Build outputs, cloned sources, generated snapshots, plots, and the
Python environment are excluded from version control.

## Repeat GPU measurements

Use Linux with Bash 4+, Python, Git, CMake 3.22+, Make, a CUDA toolkit with Thrust,
a compatible C++20 host compiler, an NVIDIA GPU, `taskset`, and `nvidia-smi`.
The recorded environment is in `env/`; `config.sh` defaults to CUDA architecture
`120` and CPU core `4`. Set `CUDA_ARCH` and `PIN_CPU` for your machine; toolchain
overrides include `CUDA_HOME`, `NVCC`, `HOST_CXX`, and `THRUST_DIR`.

The suite clones historical versions into `src/` and builds them in `build/`.
It does not benchmark the current working tree. Supply local Git repositories
containing these pinned commits (full IDs are in `config.sh`):

| Version | Source | Commit |
|---|---|---|
| cstone | [Cornerstone](https://github.com/sekelle/cornerstone-octree) | `d7fddfb4` |
| v1 | Original adaptive-octree repository | `e7bd16a8ad` |
| v2 | Original adaptive-octree repository | `ea89b79a9d` |
| v3 | Original adaptive-octree repository | `d830fc32` |

The adaptive repository and v1's corrected Cornerstone fork originated on the
project's Forgejo server and may require access. This combined repository alone
does not guarantee those historical commits are available. The fork must contain
`efd7e418d6286151e12d9a243c29f05dae66ed24`; v1's original submodule pointer is
incompatible with its API. Setup patches legacy test fixture paths only in the
disposable clones. Catch2 is downloaded when configuring v2/v3 tests.

Supply the particle datasets separately; setup does not download them:

- In the adaptive source's `tests/test_data/`: `input_test.txt` (NaCl),
  `stmv_input.txt`, `halo_25600000.dat`, `simdata/` (Flyby), and `cluster/`.
- In `DATA_ROOT/coulomb_explosion_ts/frames_more/`: the Coulomb explosion series.
- Keep the source's test fixtures (`tests/test_data/input.dat` and
  `tests/verification_data/`) for the correctness tests.

From `benchmarks/`, configure the source paths and use a fresh result directory:

```bash
REPO=/path/to/historical/adaptive-octree \
CSTONE_REPO=/path/to/cornerstone-octree \
V1_CSTONE_SRC=/path/to/corrected/cornerstone-octree-v1 \
DATA_ROOT=/path/to/datasets \
DATA_DIR=results/repeat PLOTS_DIR=results/repeat/plots \
CUDA_ARCH=120 PIN_CPU=4 ./run_all.sh
```

Relative paths resolve from `benchmarks/`. Defaults still use the former sibling
repository layout (`../adaptive-octree`, `../cornerstone-octree`, and
`../cornerstone-octree-v1`), so pass overrides in this combined checkout.
A full measurement run takes several hours.

| Step | Command | Output |
|---|---|---|
| Checkout, build, Python setup | `./setup.sh` | `src/`, `build/`, `env/` |
| Prepare datasets | `.venv/bin/python gen_snapshots.py` | Manifests, bounds, noisy snapshots |
| Correctness gate | `./test.sh` | Correctness CSVs, version gates |
| Measure | `./bench.sh` | Raw samples, initial builds, run status |
| Analyze | `.venv/bin/python analyze.py` | Summary statistics and comparison tables |
| Plot | `.venv/bin/python plot.py` | PNG, WebP, PDF figures |

`run_all.sh` runs all steps and logs to `logs/run_all_*.log`; use
`STEPS="bench analyze plot"` to select steps, preserving the same environment
overrides. Measurements resume from per-cell `DONE` markers. Use a new `DATA_DIR`
for an independent run. `DATASETS_OVERRIDE="nacl flyby"`, `MAX_SNAPSHOTS`, `W`,
`R_MIN`, `R_MAX`, and `COLD_REPS` can shorten a smoke run; include NaCl for the
correctness gate. Such shortened runs do not reproduce the full protocol.

## Interpret the results

The protocol follows Hoefler and Belli's scientific benchmarking guidance:
three warm-up series, 10–50 measured processes until the median's 95% CI reaches
±5%, and 30 separate cold-build processes. Input loading/upload is outside timing.
`env/` records toolchain, hardware, commits, and flags; GPU clocks were recorded
rather than locked. Summary CIs use a run-level BCa bootstrap.

- `tree_update_ms` and `view_ms`: GPU event timings for tree updates and views.
- `total_ms`: outer GPU event interval, including launch gaps; `wall_ms` also
  includes host status checks and synchronization. Resize/recapture maintenance
  is recorded separately.
- `data/raw_steps.csv[.gz]`, `raw_initial_build.csv[.gz]`, `summary.csv[.gz]`:
  samples and statistics. Correctness, determinism, runtime summaries, and run
  status are stored alongside them.

Cornerstone converges on every update; v3 uses fixed update passes for graph
capture and can retain overfull leaves or mergeable siblings on moving data.
Cornerstone's view is internal-tree linking, whereas the adaptive versions build
FMM-style views. These differences matter when comparing runtime. Dense halo
uses 25.6 million particles because v2/v3 exceeded the recorded 8 GB GPU's memory
with 102.4 million.

Full-pipeline FMM figures use `data/octree_comparison_source.csv`, produced by a
separate harness on an RTX 5060 Ti 16 GB. They show source means and min–max
ranges, rather than this suite's medians and bootstrap CIs. This suite cannot
rerun that FMM harness. For a fresh result directory, set
`PIPELINE_CSV=data/octree_comparison_source.csv` to include those aggregates.

To update the publication, copy the needed figures into
[slides/public/bench/](../docs/slides/README.md) and follow the
[report asset-sync instructions](../docs/report/README.md).
