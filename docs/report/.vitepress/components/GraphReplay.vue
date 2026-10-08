<script setup>
import { computed, ref } from 'vue'
// Host-driven rebalance loop vs. a captured CUDA Graph with device-owned state (conceptual timeline).
const mode = ref('graph')
const overflow = ref(false)
const passes = ref(3)
const hover = ref(null)

function hostTimeline() {
  const seg = []
  let cpu = 0, gpu = 0
  const changing = 2 // passes that still change the tree; the next one detects convergence
  for (let p = 0; p <= changing; p++) {
    seg.push({ lane: 'cpu', t0: cpu, t1: cpu + 0.4, k: 'launch', t: 'launch' }); cpu += 0.4
    gpu = Math.max(gpu, cpu)
    seg.push({ lane: 'gpu', t0: gpu, t1: gpu + 1, k: 'kernel', t: 'decide' }); gpu += 1
    seg.push({ lane: 'gpu', t0: gpu, t1: gpu + 0.8, k: 'cub', t: 'scan' }); gpu += 0.8
    seg.push({ lane: 'pcie', t0: gpu, t1: gpu + 0.6, k: 'copy', t: 'count ↦ host' }); gpu += 0.6
    cpu = Math.max(cpu, gpu)
    seg.push({ lane: 'cpu', t0: cpu, t1: cpu + 0.5, k: 'host', t: p < changing ? 'changed?' : 'converged' }); cpu += 0.5
    if (p === changing) break
    if (p === 0 || overflow.value) { seg.push({ lane: 'cpu', t0: cpu, t1: cpu + 0.9, k: 'alloc', t: 'resize / alloc' }); cpu += 0.9 }
    seg.push({ lane: 'cpu', t0: cpu, t1: cpu + 0.4, k: 'launch', t: 'launch' }); cpu += 0.4
    gpu = Math.max(gpu, cpu)
    seg.push({ lane: 'gpu', t0: gpu, t1: gpu + 0.8, k: 'kernel', t: 'scatter' }); gpu += 0.8
    seg.push({ lane: 'gpu', t0: gpu, t1: gpu + 1.4, k: 'kernel', t: 'refresh N/NF' }); gpu += 1.4
    seg.push({ lane: 'cpu', t0: cpu, t1: cpu + 0.3, k: 'host', t: 'swap ptrs' }); cpu += 0.3
  }
  return seg
}
function graphReplay(seg, start, rejectFirst) {
  let gpu = start
  let converged = false
  for (let p = 0; p < passes.value; p++) {
    const live = !converged
    const changes = p < 2
    const add = (d, k, t, guard) => { seg.push({ lane: 'gpu', t0: gpu, t1: gpu + (guard ? 0.12 : d), k: guard ? 'guard' : k, t: guard ? '' : t, pass: p }); gpu += guard ? 0.12 : d }
    add(1, 'kernel', 'decide', !live)
    add(0.8, 'cub', 'scan', false) // capacity-sized scan is always in the graph
    add(0.15, 'kernel', 'check', !live)
    if (live && (rejectFirst || !changes)) converged = true
    add(0.8, 'kernel', 'scatter', converged)
    add(0.12, 'kernel', 'commit', converged)
    add(1.4, 'kernel', 'refresh N/NF', converged)
    if (rejectFirst) rejectFirst = false
  }
  return gpu
}
function graphTimeline() {
  const seg = []
  seg.push({ lane: 'cpu', t0: 0, t1: 0.4, k: 'launch', t: 'graph launch' })
  let gpu = graphReplay(seg, 0.4, overflow.value)
  seg.push({ lane: 'pcie', t0: gpu, t1: gpu + 0.6, k: 'copy', t: 'status ↦ host' }); gpu += 0.6
  if (overflow.value) {
    seg.push({ lane: 'cpu', t0: gpu, t1: gpu + 0.5, k: 'host', t: 'needsResize' })
    seg.push({ lane: 'cpu', t0: gpu + 0.5, t1: gpu + 2.3, k: 'alloc', t: 'grow + recapture' })
    seg.push({ lane: 'cpu', t0: gpu + 2.3, t1: gpu + 2.7, k: 'launch', t: 'graph launch' })
    gpu = graphReplay(seg, gpu + 2.7, false)
    seg.push({ lane: 'pcie', t0: gpu, t1: gpu + 0.6, k: 'copy', t: 'status ↦ host' })
  }
  return seg
}
const hostSegs = computed(() => hostTimeline())
const graphSegs = computed(() => graphTimeline())
const segs = computed(() => (mode.value === 'graph' ? graphSegs.value : hostSegs.value))
const span = computed(() => Math.max(...hostSegs.value.map(s => s.t1), ...graphSegs.value.map(s => s.t1)))
const total = computed(() => Math.max(...segs.value.map(s => s.t1)))
const busy = computed(() => segs.value.filter(s => s.lane === 'gpu' && s.k !== 'guard').reduce((a, s) => a + s.t1 - s.t0, 0))
const lanes = [{ id: 'cpu', n: 'CPU (host)' }, { id: 'pcie', n: 'device → host' }, { id: 'gpu', n: 'GPU stream' }]
const fill = { launch: 'var(--c-line)', host: 'color-mix(in srgb, var(--c-bad) 18%, white)', alloc: 'color-mix(in srgb, var(--c-bad) 45%, white)', kernel: 'color-mix(in srgb, var(--c-update) 22%, white)', cub: 'color-mix(in srgb, var(--c-update) 10%, white)', copy: 'color-mix(in srgb, var(--c-view) 30%, white)', guard: 'var(--c-line)' }
const X0 = 100, W = 680, RH = 30
const xs = computed(() => W / (span.value + 0.3))
const y = id => 10 + lanes.findIndex(l => l.id === id) * (RH + 10)
</script>

<template>
  <div>
    <div class="ctl">
      <button class="pill" :class="{ on: mode === 'host' }" @click="mode = 'host'">host-driven loop</button>
      <button class="pill" :class="{ on: mode === 'graph' }" @click="mode = 'graph'">CUDA Graph replay</button>
      <label><input type="checkbox" v-model="overflow" /> topology exceeds capacity</label>
      <label v-if="mode === 'graph'">fixed passes <input type="range" min="2" max="6" v-model.number="passes" /> <b>{{ passes }}</b></label>
    </div>
    <svg :viewBox="`0 0 ${X0 + W + 10} ${10 + 3 * (RH + 10) + 14}`" width="100%" style="min-width: 640px">
      <g v-for="l in lanes" :key="l.id">
        <text x="0" :y="y(l.id) + RH / 2 + 4" style="font-size:11px; font-weight:700" fill="var(--c-ink)">{{ l.n }}</text>
        <rect :x="X0" :y="y(l.id)" :width="W" :height="RH" fill="#f8fafc" />
      </g>
      <g v-for="(s, i) in segs" :key="i" @mouseenter="hover = s" @mouseleave="hover = null">
        <rect :x="X0 + s.t0 * xs" :y="y(s.lane) + (s.k === 'guard' ? 8 : 0)" :width="Math.max((s.t1 - s.t0) * xs - 1, 1.5)" :height="s.k === 'guard' ? RH - 16 : RH" rx="3"
          :fill="fill[s.k]" :stroke="s.k === 'alloc' || s.k === 'host' ? 'var(--c-bad)' : s.k === 'copy' ? 'var(--c-view)' : 'var(--c-update)'" stroke-width="0.8" />
        <text v-if="(s.t1 - s.t0) * xs > 34" :x="X0 + ((s.t0 + s.t1) / 2) * xs" :y="y(s.lane) + RH / 2 + 3.5" text-anchor="middle" style="font-size:8.5px" fill="var(--c-ink)">{{ s.t }}</text>
      </g>
      <text :x="X0" :y="10 + 3 * (RH + 10) + 10" style="font-size:10px" fill="var(--c-muted)">
        time → · total {{ total.toFixed(1) }} units · GPU busy {{ Math.round((100 * busy) / total) }} %
      </text>
    </svg>
    <div class="tiny muted" v-if="mode === 'host'">Every pass needs the new leaf count on the host before it can resize buffers, swap pointers and launch the next kernels, and the GPU idles during each round trip.</div>
    <div class="tiny muted" v-else>One launch replays a fixed number of passes. <span class="mono">RebalanceState</span> on the device holds the leaf count, convergence flag and active A/B buffer. Kernels after convergence exit immediately (grey slivers), but the capacity-sized CUB scan still runs. An oversized proposal is rejected <i>before</i> anything is written; growth and recapture happen outside the replay.</div>
  </div>
</template>
