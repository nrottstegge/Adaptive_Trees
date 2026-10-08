#!/usr/bin/env bash
# Full pipeline. Each step also runs on its own; select steps with STEPS="test bench ...".
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
cd "$BENCH"
mkdir -p logs
LOG="logs/run_all_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
STEPS="${STEPS:-setup gen test bench analyze plot}"

step() {
    local name=$1; shift
    [[ " $STEPS " == *" $name "* ]] || { log "##### $name skipped"; return 0; }
    local t=$SECONDS
    log "##### $name"
    "$@"
    log "##### $name finished in $((SECONDS - t))s"
}

step setup   ./setup.sh
step gen     "$PY" gen_snapshots.py
step test    ./test.sh
step bench   ./bench.sh
step analyze "$PY" analyze.py
step plot    "$PY" plot.py
log "log: $LOG"
