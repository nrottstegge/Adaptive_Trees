#!/usr/bin/env bash
# Record the measurement environment into env/ (usage: env.sh before|after).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
tag="${1:-before}"
E="$BENCH/env"; mkdir -p "$E"

date -Is > "$E/date_$tag.txt"
nvidia-smi -q > "$E/nvidia-smi-q_$tag.txt"
nvidia-smi --query-gpu=name,uuid,pci.bus_id,driver_version,memory.total,memory.used,memory.free,clocks.gr,clocks.sm,clocks.mem,clocks.max.gr,clocks.max.mem,temperature.gpu,power.draw,pstate,persistence_mode \
    --format=csv > "$E/gpu_clocks_$tag.csv"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv > "$E/gpu_processes_$tag.csv"
{ uptime; echo; who; echo; ps -eo pid,user,pcpu,comm --sort=-pcpu | head -15; } > "$E/host_load_$tag.txt"

if [[ $tag == before* ]]; then
    env_file="$E/environment$( [[ $tag == before ]] || echo "_${tag#before_}").txt"
    {
        echo "date: $(date -Is)"
        echo "host: $(hostname)"
        echo "gpu: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader)"
        echo "nvcc: $("$NVCC" --version | tail -2 | tr '\n' ' ')"
        echo "host compiler: $("$HOST_CXX" --version | head -1)"
        echo "cmake: $(cmake --version | head -1)"
        echo "cpu: $(lscpu | sed -n 's/^Model name: *//p')"
        echo "os: $(. /etc/os-release; echo "$PRETTY_NAME"), kernel $(uname -r)"
        echo "python: $("$PY" --version 2>&1)"
        echo "cuda arch: sm_$CUDA_ARCH"
        echo "cmake flags: ${CMAKE_COMMON[*]}"
        echo "pinning: taskset -c $PIN_CPU; CUDA_MODULE_LOADING=$CUDA_MODULE_LOADING"
        echo "protocol: W=$W R_MIN=$R_MIN R_MAX=$R_MAX CI_TOL=$CI_TOL COLD_REPS=$COLD_REPS stride=$SNAPSHOT_STRIDE noisy=$NOISY_SNAPSHOTS sigma=$NOISE_SIGMA seed=$NOISE_SEED boot_seed=$BOOT_SEED"
        for v in "${VERSIONS[@]}"; do echo "commit $v: $(commit_of "$v")"; done
    } > "$env_file"
fi
if [[ $tag == before ]]; then
    "$NVCC" --version > "$E/nvcc_version.txt"
    "$HOST_CXX" --version > "$E/host_compiler.txt"
    lscpu > "$E/lscpu.txt"
    uname -a > "$E/uname.txt"
    cat /etc/os-release > "$E/os-release.txt"
    "$PY" -m pip freeze > "$E/python_packages.txt"
    # Clock locking needs root on this machine; record the attempt either way.
    max_gr="$(nvidia-smi --query-gpu=clocks.max.gr --format=csv,noheader,nounits | head -1)"
    if nvidia-smi -lgc "$max_gr,$max_gr" > "$E/clock_lock.txt" 2>&1; then
        echo "locked graphics clock at $max_gr MHz" >> "$E/clock_lock.txt"
    else
        echo "clock lock NOT permitted -> clocks recorded before/after instead" >> "$E/clock_lock.txt"
    fi
fi
if [[ $tag == after ]] && grep -q "^locked" "$E/clock_lock.txt" 2>/dev/null; then
    nvidia-smi -rgc >> "$E/clock_lock.txt" 2>&1 || true
fi

others="$(tail -n +2 "$E/gpu_processes_$tag.csv" | grep -vc '^$' || true)"
log "environment ($tag) recorded in env/; other GPU processes: $others; load: $(cut -d, -f3- /proc/loadavg 2>/dev/null || uptime)"
[[ "$others" == 0 ]] || log "WARNING: GPU not idle (see env/gpu_processes_$tag.csv)"
