# Shared settings, sourced by every shell step. Override any variable from the environment.
BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BENCH"
export REPO="${REPO:-../adaptive-octree}"
CSTONE_REPO="${CSTONE_REPO:-../cornerstone-octree}"
# Local clone of the fork supplying v1's corrected Cornerstone dependency.
export V1_CSTONE_SRC="${V1_CSTONE_SRC:-../cornerstone-octree-v1}"
# e7bd16a's own submodule pointer (bd98719d) predates the API it calls; the next repo commit
# 6f11cac changes only the pointer, to efd7e418
V1_CSTONE_COMMIT="${V1_CSTONE_COMMIT:-efd7e418d6286151e12d9a243c29f05dae66ed24}"
export DATA_ROOT="${DATA_ROOT:-..}"

# Pin every version to the commits used by the included results.
declare -A COMMIT_SPEC=(
    [cstone]="d7fddfb4f8d8ada0eb1a65d1a450a66c8cbd794c"
    [v1]="e7bd16a8ad2be3cb1a245ce7fe4d8ea167164025"
    [v2]="ea89b79a9dfd35df20fed759e6d15c60fe01e77c"
    [v3]="d830fc32ff2631e4e1344dc30b3e09c3b9690bed"
)
VERSIONS=(cstone v1 v2 v3)

# version -> applicable configs (cstone: LeafCount only; v1/v2: no KDTree3D)
declare -A VERSION_CONFIGS=(
    [cstone]="octree_leafcount"
    [v1]="octree_leafcount octree_nfcount"
    [v2]="octree_leafcount octree_nfcount"
    [v3]="octree_leafcount octree_nfcount kdtree3d_leafcount"
)

# dataset ids (sources are defined in gen_snapshots.py)
DATASETS=(${DATASETS_OVERRIDE:-coulomb_explosion flyby dense_halo nacl stmv cluster cluster_full})
# datasets restricted to some versions (escaped particles are only supported by v3)
declare -A DATASET_VERSIONS=([cluster_full]="v3")

# Toolchain: identical for every version.
CUDA_HOME="${CUDA_HOME:-}"
NVCC="${NVCC:-${CUDA_HOME:+$CUDA_HOME/bin/}nvcc}"
HOST_CXX="${HOST_CXX:-g++}"
CUDA_ARCH="${CUDA_ARCH:-120}"
CMAKE_COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_CXX_COMPILER="$HOST_CXX"
    -DCMAKE_CUDA_COMPILER="$NVCC"
    -DCMAKE_CUDA_HOST_COMPILER="$HOST_CXX"
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
    "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG"
    "-DCMAKE_CUDA_FLAGS_RELEASE=-O3 -DNDEBUG -lineinfo"
    # cstone's GPU unit tests need it; set for every version so flags stay identical
    "-DCMAKE_CUDA_FLAGS=--extended-lambda"
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
)
# Discover the installed toolkit; no workstation-specific compiler paths.
if [[ -z "${THRUST_DIR:-}" ]] && command -v "$NVCC" >/dev/null 2>&1; then
    toolkit="$(dirname "$(dirname "$(readlink -f "$(command -v "$NVCC")")")")"
    THRUST_DIR="$toolkit/targets/$(uname -m)-linux/lib/cmake/thrust"
fi
[[ -z "${THRUST_DIR:-}" ]] || CMAKE_COMMON+=(-DThrust_DIR="$THRUST_DIR")

# Measurement protocol (section 5)
W="${W:-3}"                       # discarded warm-up runs per series
R_MIN="${R_MIN:-10}"
R_MAX="${R_MAX:-50}"
CI_TOL="${CI_TOL:-0.05}"          # stop when the 95% CI of the median is within +-5% of the median
COLD_REPS="${COLD_REPS:-30}"      # separate processes for the cold initial build
NOISY_SNAPSHOTS="${NOISY_SNAPSHOTS:-1}"
NOISE_SIGMA="${NOISE_SIGMA:-1e-3}"
NOISE_SEED="${NOISE_SEED:-20261001}"
BOOT_SEED="${BOOT_SEED:-12345}"
LEAF_LIMIT=64
NF_LIMIT=$((64 * 64 * 27))       # default NFCount threshold in v1, v2, v3
PIN_CPU="${PIN_CPU:-4}"           # choose an available performance core on your machine
SNAPSHOT_STRIDE="${SNAPSHOT_STRIDE:-1}"  # 1 = full series (protocol); >1 is a documented deviation
export NOISY_SNAPSHOTS NOISE_SIGMA NOISE_SEED BOOT_SEED CI_TOL SNAPSHOT_STRIDE

export DATA_DIR="${DATA_DIR:-$BENCH/data}"
export PLOTS_DIR="${PLOTS_DIR:-$BENCH/plots}"
PY="$BENCH/.venv/bin/python"
export CUDA_MODULE_LOADING=EAGER  # no lazy kernel loading inside timed steps
export OMP_NUM_THREADS=1

driver_bin() { echo "$BENCH/build/$1/driver/bench_driver"; }
commit_of() { cat "$BENCH/env/commit_$1.txt" 2>/dev/null || echo unknown; }
pinned() { taskset -c "$PIN_CPU" "$@"; }
BENCH_T0=${BENCH_T0:-$SECONDS}
log() { echo "[$(date +%H:%M:%S) +$((SECONDS - BENCH_T0))s] $*"; }
# run a command, report its duration; output goes to the given log file
timed() {
    local label=$1 logfile=$2; shift 2
    local t=$SECONDS
    log "$label ... (log: ${logfile#$BENCH/})"
    if "$@" > "$logfile" 2>&1; then
        log "$label done in $((SECONDS - t))s"
    else
        log "$label FAILED after $((SECONDS - t))s"; return 1
    fi
}
