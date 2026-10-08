#!/usr/bin/env bash
# Correctness gate: each version must pass its own tests plus a harness smoke test,
# otherwise it is not benchmarked (data/gate_<version>.txt). Results: data/correctness.csv.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
CORR="$DATA_DIR/correctness.csv"
mkdir -p "$DATA_DIR" "$BENCH/logs/test"
# CHECK_ONLY=1: append the cstone leaf-count check for $DATASETS, keep existing gate results
[[ "${CHECK_ONLY:-0}" == 1 && -f "$CORR" ]] || echo "version,test,result,notes" > "$CORR"
record() { echo "$1,$2,$3,\"${4//\"/\'}\"" >> "$CORR"; }

run_test() { # version test_name workdir cmd...
    local v=$1 name=$2 wd=$3; shift 3
    local lf="$BENCH/logs/test/${v}_${name}.log"
    if (cd "$wd" && timed "$v: $name" "$lf" "$@" < /dev/null); then
        record "$v" "$name" pass "log: logs/test/${v}_${name}.log"
    else
        record "$v" "$name" fail "$(grep -m1 -iE 'error|fail' "$lf" | cut -c1-200)"
        return 1
    fi
}

smoke() { # version config: driver on NaCl (2 snapshots), checks harness invariants
    local v=$1 cfg=$2 out="$BENCH/logs/test/${v}_${cfg}_smoke.csv"
    run_test "$v" "harness_smoke_$cfg" "$BENCH" pinned "$(driver_bin "$v")" --manifest "$BENCH/datasets/nacl/manifest.txt" \
        --config "$cfg" --mode steps --version "$v" --commit "$(commit_of "$v")" --run 0 --out "$out" < /dev/null || return 1
    local msg
    if msg="$("$PY" - "$out" <<'EOF'
import sys, pandas as pd
d = pd.read_csv(sys.argv[1])
bad = []
if len(d) < 2: bad.append("fewer than 2 snapshots")
if (d.particles_active + d.particles_escaped != d.particle_slots).any(): bad.append("particle accounting")
lib = d.lib_num_nodes.dropna()
if len(lib) and (lib != d.loc[lib.index, "num_nodes"]).any(): bad.append("library node count != harness node count")
if d.loc[d.snapshot > 0, ["tree_update_ms", "view_ms", "total_ms", "wall_ms"]].isna().any().any(): bad.append("missing timings")
t = d[d.snapshot > 0]
if ((t.tree_update_ms + t.view_ms) > t.total_ms * 1.001 + 1e-3).any(): bad.append("phases exceed total")
print("; ".join(bad) or f"leaves={list(d.num_leaves)} nodes={list(d.num_nodes)} depth={list(d.max_depth)}")
sys.exit(1 if bad else 0)
EOF
    )"; then
        record "$v" "harness_invariants_$cfg" pass "$msg"
    else
        record "$v" "harness_invariants_$cfg" fail "$msg"; return 1
    fi
}

[[ -f "$BENCH/datasets/nacl/manifest.txt" ]] || { log "run gen_snapshots.py first"; exit 1; }

for v in "${VERSIONS[@]}"; do
    [[ "${CHECK_ONLY:-0}" == 1 ]] && break
    gate=pass
    st="$(grep "^$v," "$BENCH/env/build_status.csv" | cut -d, -f3 || true)"
    if [[ "$st" != ok ]]; then
        record "$v" build "${st:-missing}" "$(grep "^$v," "$BENCH/env/build_status.csv" | cut -d, -f4- || true)"
        echo fail > "$DATA_DIR/gate_$v.txt"; log "$v: not built ($st) -> excluded"; continue
    fi
    record "$v" build pass "commit $(commit_of "$v")"
    T="$BENCH/build/$v/lib"
    case $v in
        v3) run_test v3 tree_test "$T" ./tests/tree_test || gate=fail
            run_test v3 tree_example "$T" ./tests/tree_example || gate=fail ;;
        # v2's Octree constructor always prompts for criterion + limit; both tests use NFCount/default
        v2) run_test v2 adaptive_octree_test "$T" bash -c 'printf "2\nn\n" | ./tests/adaptive_octree_test' || gate=fail
            run_test v2 octree_regression_test "$T" bash -c 'printf "2\nn\n" | ./tests/octree_regression_test' || gate=fail ;;
        v1) run_test v1 adaptive_octree_test "$T" bash -c 'printf "2\nn\n" | ./tests/adaptive_octree_test' || gate=fail ;;
        cstone) run_test cstone component_units "$T" ./test/unit/component_units || gate=fail
                run_test cstone component_units_cuda "$T" ./test/unit_cuda/component_units_cuda || gate=fail ;;
    esac
    for cfg in ${VERSION_CONFIGS[$v]}; do smoke "$v" "$cfg" || gate=fail; done
    echo "$gate" > "$DATA_DIR/gate_$v.txt"
    log "$v: gate $gate"
done

# Cornerstone vs v3 Octree/LeafCount: identical keys + bucket size -> identical leaf arrays?
CHECK="$BENCH/build/check/driver/cstone_check"
if [[ -x "$CHECK" ]]; then
    for ds in "${DATASETS[@]}"; do
        out="$DATA_DIR/cstone_leafcount_check_$ds.csv"
        lf="$BENCH/logs/test/cstone_check_$ds.log"
        extra=(); [[ -n "${CHECK_MAX_SNAPSHOTS:-}" ]] && extra=(--max-snapshots "$CHECK_MAX_SNAPSHOTS")
        if timed "cstone leaf-count check: $ds" "$lf" pinned "$CHECK" --manifest "$BENCH/datasets/$ds/manifest.txt" \
                --config octree_leafcount --out "$out" "${extra[@]}" < /dev/null; then
            summary="$("$PY" -c "
import pandas as pd; d = pd.read_csv('$out'); bad = d[d.leaf_arrays_identical == 0]
s = f'{len(d)-len(bad)}/{len(d)} snapshots identical'
if not bad.empty:
    s += (f'; first mismatch snapshot {int(bad.snapshot.iloc[0])}: v3 {int(bad.v3_leaves.iloc[0])} vs cstone {int(bad.cstone_leaves.iloc[0])} leaves; '
          f'max |diff| {int((bad.v3_leaves-bad.cstone_leaves).abs().max())}')
s += (f'; converged-tree violations (overfull leaves / mergeable groups) mean|max: v3 {d.v3_overfull_leaves.mean():.1f}|{d.v3_overfull_leaves.max()} / '
      f'{d.v3_mergeable_groups.mean():.1f}|{d.v3_mergeable_groups.max()}, cstone {d.cstone_overfull_leaves.max()} / {d.cstone_mergeable_groups.max()}')
print(s)")"
            result=pass; [[ "$summary" == *mismatch* ]] && result=mismatch
            record cstone "leafcount_vs_v3_$ds" "$result" "$summary (data/cstone_leafcount_check_$ds.csv)"
        else
            reason=failed; grep -qi "out of memory" "$lf" && reason=oom
            record cstone "leafcount_vs_v3_$ds" "$reason" "see logs/test/cstone_check_$ds.log"
        fi
    done
else
    record cstone leafcount_vs_v3 not_run "cstone_check not built"
fi
cat "$CORR"
