<script setup>
import { computed, onMounted, ref } from 'vue'
import { loadCsv } from '../lib/csv.js'
// Tree update + view construction per step, Cornerstone vs. snapshots of this work.
// Data: public/data/implementation_runtime_summary.csv (adaptive-octree-bench/analyze.py).
const props = defineProps({ dataset: { type: String, default: 'cluster' } })
const rows = ref([]), err = ref('')
onMounted(async () => { try { rows.value = await loadCsv('/data/implementation_runtime_summary.csv') } catch (e) { err.value = String(e) } })
const names = { cluster: 'Cluster simulation', coulomb_explosion: 'Coulomb explosion', flyby: 'Flyby', nacl: 'NaCl', stmv: 'STMV', dense_halo: 'Dense halo (25.6 M)' }
const ds = ref(props.dataset)
const datasets = computed(() => [...new Set(rows.value.filter(r => r.status === 'ok' && r.version === 'cstone').map(r => r.dataset))])
const bars = [
  { v: 'cstone', c: 'octree_leafcount', label: 'Cornerstone', sub: 'baseline · LeafCount' },
  { v: 'v1', c: 'octree_nfcount', label: 'early September', sub: 'NFCount · GPU-BFS views' },
  { v: 'v2', c: 'octree_nfcount', label: 'mid September', sub: 'NFCount · direct views, caching' },
  { v: 'v3', c: 'octree_nfcount', label: 'final', sub: 'NFCount · CUDA Graph' },
  { v: 'v3', c: 'octree_leafcount', label: 'final', sub: 'LeafCount · CUDA Graph' },
]
const data = computed(() => bars.map(b => {
  const r = rows.value.find(r => r.dataset === ds.value && r.version === b.v && r.config === b.c && r.status === 'ok')
  return r ? { ...b, tu: +r.median_tree_update_ms, vw: +r.median_view_ms, tot: +r.median_total_ms, lo: +r.ci_low, hi: +r.ci_high, sp: +r.speedup_vs_cstone, n: +r.n_steps } : { ...b, missing: true }
}))
const max = computed(() => Math.max(...data.value.filter(d => !d.missing).map(d => Math.max(d.tot, d.tu + d.vw)), 1e-9))
const hover = ref(-1)
const fmt = v => (v < 1 ? (v * 1000).toFixed(0) + ' µs' : v.toFixed(2) + ' ms')
</script>

<template>
  <div class="rc">
    <div class="ctl">
      <label>dataset
        <select v-model="ds"><option v-for="d in datasets" :key="d" :value="d">{{ names[d] || d }}</option></select>
      </label>
      <span class="pill"><span class="sw" style="background: var(--c-update)"></span>tree update</span>
      <span class="pill"><span class="sw" style="background: var(--c-view)"></span>view construction</span>
      <span class="pill"><span class="sw" style="background: var(--c-ink); width: 3px"></span>median total</span>
    </div>
    <div v-if="err" class="tiny" style="color: var(--c-bad)">could not load data: {{ err }}. Run <code>npm run sync</code></div>
    <div v-for="(d, i) in data" :key="i" class="row" @mouseenter="hover = i" @mouseleave="hover = -1">
      <div class="lab"><b>{{ d.label }}</b><div class="tiny muted">{{ d.sub }}</div></div>
      <div class="track">
        <template v-if="!d.missing">
          <div class="seg" :style="{ width: (100 * d.tu) / max + '%', background: 'var(--c-update)' }"></div>
          <div class="seg" :style="{ width: (100 * d.vw) / max + '%', background: 'var(--c-view)' }"></div>
          <div class="tot" :style="{ left: (100 * d.tot) / max + '%' }"></div>
        </template>
        <span v-else class="tiny muted">not measured</span>
      </div>
      <div class="val mono" v-if="!d.missing">{{ fmt(d.tot) }} <b :style="{ color: d.sp >= 1 ? 'var(--c-good)' : 'var(--c-bad)' }">×{{ d.sp.toFixed(2) }}</b></div>
    </div>
    <div class="info tiny">
      <template v-if="hover >= 0 && !data[hover].missing">
        tree update {{ fmt(data[hover].tu) }} · view {{ fmt(data[hover].vw) }} · total {{ fmt(data[hover].tot) }} (95 % CI {{ fmt(data[hover].lo) }} – {{ fmt(data[hover].hi) }}) · {{ data[hover].n }} steps
      </template>
      <template v-else>Medians per time step. Phase and total medians are computed separately, so the bars need not add up exactly to the tick. Speed-up relative to Cornerstone. Hover a row for details.</template>
    </div>
  </div>
</template>

<style scoped>
.rc { display: flex; flex-direction: column; gap: 6px; }
.row { display: grid; grid-template-columns: 190px 1fr 130px; gap: 10px; align-items: center; padding: 3px 0; border-radius: 4px; }
.row:hover { background: #f8fafc; }
.track { position: relative; height: 22px; display: flex; }
.seg { height: 100%; transition: width 0.4s; }
.tot { position: absolute; top: -3px; bottom: -3px; width: 2.5px; background: var(--c-ink); transition: left 0.4s; }
.val { font-size: 0.78rem; text-align: right; }
.info { color: var(--c-muted); min-height: 2.6em; }
@media (max-width: 640px) { .row { grid-template-columns: 1fr; } .val { text-align: left; } }
</style>
