#!/usr/bin/env bash
# Clone + checkout + build every version (library, its own tests, benchmark driver).
# Never touches $REPO or $CSTONE_REPO except for read-only git operations.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
mkdir -p "$BENCH/src" "$BENCH/build" "$BENCH/env" "$BENCH/logs" "$DATA_DIR"
STATUS="$BENCH/env/build_status.csv"
echo "version,commit,status,notes" > "$STATUS"
JOBS="${JOBS:-$(nproc)}"
if [[ ! -x "$PY" ]]; then
    python3 -m venv "$BENCH/.venv"
    "$PY" -m pip install -r "$BENCH/requirements.txt"
fi

source_repo() { [[ $1 == cstone ]] && echo "$CSTONE_REPO" || echo "$REPO"; }

checkout() {
    local v=$1 src commit
    src="$(source_repo "$v")"
    commit="$(git -C "$src" rev-parse --verify "${COMMIT_SPEC[$v]}^{commit}")"
    [[ -d "$BENCH/src/$v/.git" ]] || git clone -q "$src" "$BENCH/src/$v"
    git -C "$BENCH/src/$v" fetch -q origin
    git -C "$BENCH/src/$v" checkout -q --detach "$commit"
    echo "$commit" > "$BENCH/env/commit_$v.txt"
    # uncommitted work in the source repo is NOT benchmarked; record it
    git -C "$src" status --porcelain > "$BENCH/env/source_dirty_$v.txt" || true
    log "$v -> $commit"
}

v1_submodule() {
    # Clone the corrected fork directly: the original submodule pointer is incompatible.
    local d="$BENCH/src/v1"
    [[ -e "$d/external/cornerstone/.git" ]] || git clone -q "$V1_CSTONE_SRC" "$d/external/cornerstone"
    git -C "$d/external/cornerstone" checkout -q --detach "$V1_CSTONE_COMMIT"
    echo "$V1_CSTONE_COMMIT" > "$BENCH/env/commit_v1_cornerstone_submodule.txt"
}

check_keys() {
    # 64-bit Morton keys only; drivers additionally static_assert sizeof(KeyType)==8
    # and v2/v3 drivers set and verify SfcKind::Morton at runtime.
    local v=$1 d="$BENCH/src/$1"
    case $v in
        v1) grep -q 'using KeyType = unsigned long;' "$d/include/adaptive_octree/octree.hpp" &&
            grep -q 'MortonKey<KeyType>' "$d/src/octree.cu" &&
            ! grep -qE '^[^/]*HilbertKey<' "$d/src/octree.cu" ;;
        v2|v3) grep -rq 'using KeyType = unsigned long long;' "$d/include/adaptive_octree" ;;
        cstone) true ;;  # driver hard-codes MortonKey<uint64_t>
    esac
}

cmake_build() { # dir source targets...
    local dir=$1 src=$2; shift 2
    timed "configure ${dir#$BENCH/}" "$dir.configure.log" cmake -S "$src" -B "$dir" "${CMAKE_COMMON[@]}" "${EXTRA_CMAKE[@]}" || return 1
    local t=$SECONDS
    log "build ${dir#$BENCH/} [$*] ... (log: ${dir#$BENCH/}.build.log)"
    # live progress: only make's "[ NN%] Building/Linking" lines
    { cmake --build "$dir" -j "$JOBS" --target "$@" && echo 0 > "$dir.rc" || echo 1 > "$dir.rc"; } 2>&1 | tee "$dir.build.log" |
        grep --line-buffered -E '^\[ *[0-9]+%\] (Building|Linking)' | sed -u "s|$BENCH/||; s/^/    /" || true
    if [[ "$(cat "$dir.rc")" == 0 ]]; then log "build ${dir#$BENCH/} done in $((SECONDS - t))s"
    else log "build ${dir#$BENCH/} FAILED after $((SECONDS - t))s"; return 1; fi
}

build_version() {
    local v=$1 commit; commit="$(commit_of "$v")"
    local b="$BENCH/build/$v"; mkdir -p "$b"
    EXTRA_CMAKE=(-DBUILD_TESTING=ON)
    case $v in
        cstone) EXTRA_CMAKE+=(-DCSTONE_WITH_HIP=OFF) ; tests=(component_units component_units_cuda) ;;
        v1) tests=(adaptive_octree_test) ;;
        v2) tests=(adaptive_octree_test octree_regression_test) ;;
        v3) tests=(tree_test tree_example) ;;
    esac
    cmake_build "$b/lib" "$BENCH/src/$v" "${tests[@]}" || { echo "$v,$commit,fail,library/tests build failed (see build/$v/lib.build.log)" >> "$STATUS"; return 1; }
    EXTRA_CMAKE=(-DBENCH_VERSION="$v" -DBENCH_SRC="$BENCH/src/$v")
    cmake_build "$b/driver" "$BENCH/drivers" bench_driver || { echo "$v,$commit,fail,driver build failed (see build/$v/driver.build.log)" >> "$STATUS"; return 1; }
    cp "$b/driver/compile_commands.json" "$BENCH/env/compile_commands_$v.json"
    echo "$v,$commit,ok," >> "$STATUS"
}

for v in "${VERSIONS[@]}"; do
    checkout "$v"
    if [[ $v == v1 ]] && ! v1_submodule >> "$BENCH/logs/setup_v1_submodule.log" 2>&1; then
        echo "v1,$(commit_of v1),unavailable,corrected Cornerstone fork unavailable; set V1_CSTONE_SRC" >> "$STATUS"
        log "v1 submodule unavailable -> v1 skipped"
        continue
    fi
    if ! check_keys "$v"; then
        echo "$v,$(commit_of "$v"),fail,key type is not 64-bit Morton" >> "$STATUS"; continue
    fi
    "$PY" "$BENCH/prepare_sources.py" "$BENCH/src/$v"
    log "building $v"
    build_version "$v" || log "$v build FAILED"
done

# v3 + cstone leaf-count equivalence checker
if grep -q '^v3,.*,ok' "$STATUS" && grep -q '^cstone,.*,ok' "$STATUS"; then
    EXTRA_CMAKE=(-DBENCH_VERSION=check -DBENCH_SRC="$BENCH/src/v3" -DBENCH_CSTONE_SRC="$BENCH/src/cstone")
    mkdir -p "$BENCH/build/check"
    cmake_build "$BENCH/build/check/driver" "$BENCH/drivers" cstone_check && log "cstone_check built" || log "cstone_check build FAILED"
fi

# Optional aggregates from the separate FMM benchmark.
if [[ -n "${PIPELINE_CSV:-}" && ! -f "$DATA_DIR/octree_comparison_source.csv" ]]; then
    cp "$PIPELINE_CSV" "$DATA_DIR/octree_comparison_source.csv"
fi
cat "$STATUS"
