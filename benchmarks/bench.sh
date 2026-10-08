#!/usr/bin/env bash
# Benchmark matrix (section 5): cold initial builds in COLD_REPS processes, W discarded
# warm-up series runs, then R measured series runs (fresh process each) until the 95% CI
# of the median total_ms is within CI_TOL (R_MIN <= R <= R_MAX). Resumable: finished
# cells have data/raw/<v>/<cfg>/<ds>/DONE.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
STATUS_CSV="$DATA_DIR/run_status.csv"
mkdir -p "$DATA_DIR/raw" "$BENCH/logs/bench"
[[ -f "$STATUS_CSV" ]] || echo "version,commit,path,config,dataset,status,R,W,cold_reps,ci,notes" > "$STATUS_CSV"
status() { echo "$1,$(commit_of "$1"),$2,$3,$4,$5,$6,$7,$8,\"$9\",\"${10}\"" >> "$STATUS_CSV"; }
path_of() { [[ $1 == v3 ]] && echo graph || echo direct; }
extra=(); [[ -n "${MAX_SNAPSHOTS:-}" ]] && extra=(--max-snapshots "$MAX_SNAPSHOTS")

drive() { # v cfg ds mode run out errlog
    pinned "$(driver_bin "$1")" --manifest "$BENCH/datasets/$3/manifest.txt" --config "$2" --mode "$4" \
        --version "$1" --commit "$(commit_of "$1")" --run "$5" --out "$6" "${extra[@]}" < /dev/null >> "$7" 2>&1
}
failure_kind() { grep -qiE "out of memory|cudaErrorMemoryAllocation" "$1" && echo oom || echo failed; }

bash "$BENCH/env.sh" "before${ENV_SUFFIX:-}"
for ds in "${DATASETS[@]}"; do
    M="$BENCH/datasets/$ds/manifest.txt"
    [[ -f "$M" ]] || { log "missing $M (run gen_snapshots.py)"; exit 1; }
    slots="$(sed -n 's/^slots //p' "$M")"; frames="$(grep -c '^frame' "$M")"
    for v in "${VERSIONS[@]}"; do
        if [[ -n "${DATASET_VERSIONS[$ds]:-}" && " ${DATASET_VERSIONS[$ds]} " != *" $v "* ]]; then continue; fi
        if [[ "$(cat "$DATA_DIR/gate_$v.txt" 2>/dev/null)" != pass ]]; then
            for cfg in ${VERSION_CONFIGS[$v]}; do status "$v" "$(path_of "$v")" "$cfg" "$ds" excluded 0 0 0 "" "failed or missing correctness gate"; done
            continue
        fi
        for cfg in ${VERSION_CONFIGS[$v]}; do
            D="$DATA_DIR/raw/$v/$cfg/$ds"; L="$BENCH/logs/bench/${v}_${cfg}_${ds}.log"
            [[ -f "$D/DONE" ]] && { log "$v $cfg $ds: done earlier, skipping"; continue; }
            rm -rf "$D"; mkdir -p "$D/warmup"; : > "$L"
            cell_t=$SECONDS
            log "=== $v / $cfg / $ds ($frames snapshots, $slots particles) ==="

            if [[ $ds == dense_halo ]]; then
                free="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)"
                need=$(( slots * 24 / 1048576 ))
                log "GPU memory free ${free} MiB; coordinates alone need ${need} MiB"
                echo "GPU memory free ${free} MiB before $v/$cfg" >> "$L"
                if (( free < need )); then status "$v" "$(path_of "$v")" "$cfg" "$ds" oom 0 0 0 "" "precheck: ${free} MiB free"; continue; fi
            fi

            failed=""
            for rep in $(seq 1 "$COLD_REPS"); do
                if ! drive "$v" "$cfg" "$ds" cold "$rep" "$D/cold_$(printf %03d "$rep").csv" "$L"; then
                    failed="$(failure_kind "$L")"; break
                fi
                (( rep % 10 == 0 || rep == COLD_REPS )) && log "  cold build: $rep/$COLD_REPS processes ($((SECONDS - cell_t))s)"
            done
            if [[ -n $failed ]]; then
                log "  $failed -> recorded, skipping (see ${L#$BENCH/})"
                status "$v" "$(path_of "$v")" "$cfg" "$ds" "$failed" 0 0 0 "" "$(grep -m1 -iE 'error|memory' "$L" | cut -c1-200)"
                continue
            fi

            for w in $(seq 1 "$W"); do
                t=$SECONDS
                drive "$v" "$cfg" "$ds" steps "-$w" "$D/warmup/warmup_$w.csv" "$L" || { failed="$(failure_kind "$L")"; break; }
                log "  warm-up $w/$W (discarded) $((SECONDS - t))s"
            done
            [[ -z $failed ]] || { status "$v" "$(path_of "$v")" "$cfg" "$ds" "$failed" 0 0 "$COLD_REPS" "" "failed in warm-up"; continue; }

            r=0; ci=""
            while (( r < R_MAX )); do
                r=$((r + 1)); t=$SECONDS
                drive "$v" "$cfg" "$ds" steps "$r" "$D/run_$(printf %03d "$r").csv" "$L" || { failed="$(failure_kind "$L")"; break; }
                if (( r >= R_MIN )); then
                    if ci="$("$PY" "$BENCH/benchlib.py" ci-check "$D")"; then log "  run $r $((SECONDS - t))s: $ci"; break; fi
                    log "  run $r $((SECONDS - t))s: $ci"
                else
                    log "  run $r/$R_MIN $((SECONDS - t))s"
                fi
            done
            if [[ -n $failed ]]; then
                status "$v" "$(path_of "$v")" "$cfg" "$ds" "$failed" "$((r - 1))" "$W" "$COLD_REPS" "" "failed in measured run $r"; continue
            fi
            note=""; [[ $ci == *converged* ]] || note="CI criterion not met at R_MAX"
            [[ -n "${MAX_SNAPSHOTS:-}" ]] && note="$note MAX_SNAPSHOTS=$MAX_SNAPSHOTS (deviation)"
            status "$v" "$(path_of "$v")" "$cfg" "$ds" ok "$r" "$W" "$COLD_REPS" "$ci" "$note"
            touch "$D/DONE"
            log "  cell finished in $((SECONDS - cell_t))s"
        done
    done
done
bash "$BENCH/env.sh" "after${ENV_SUFFIX:-}"
"$PY" "$BENCH/benchlib.py" merge
