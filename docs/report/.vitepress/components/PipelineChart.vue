<script setup>
import { computed, onMounted, ref } from 'vue'
import { loadCsv } from '../lib/csv.js'
// Full pipeline (tree + view + interaction lists + FMM) per time step, dense tree vs. adaptive versions.
// Data: public/data/full_pipeline.csv (separate FMM harness, means over repetitions).
const props = defineProps({ input: { type: String, default: 'coulomb_early' }, compact: { type: Boolean, default: false } })
const rows = ref([]), err = ref('')
onMounted(async () => { try { rows.value = await loadCsv('/data/full_pipeline.csv') } catch (e) { err.value = String(e) } })
const names = { coulomb_early: 'Coulomb explosion · early', coulomb_late: 'Coulomb explosion · late', flyby: 'Flyby', nacl: 'NaCl (6 740)', halo: 'Halo subsample' }
const impls = [
  { id: 'dense', label: 'dense tree', sub: 'uniform depth' },
  { id: 'first_complete', label: 'first complete', sub: 'first end-to-end version' },
  { id: 'first_update_rebuild', label: 'update API', sub: 'tree rebuilt every step' },
  { id: 'first_update', label: 'update API', sub: 'incremental update' },
  { id: 'newest', label: 'newest', sub: 'current version' },
]
const phases = [
  { id: 'common', label: 'keys / sort', c: 'var(--c-line-strong)' },
  { id: 'tree', label: 'tree update', c: 'var(--c-update)' },
  { id: 'view', label: 'view', c: 'var(--c-view)' },
  { id: 'lists', label: 'interaction lists', c: 'var(--c-lists)' },
  { id: 'fmm', label: 'FMM', c: 'var(--c-fmm)' },
]
const inp = ref(props.input)
const inputs = computed(() => [...new Set(rows.value.map(r => r.input))])
const shown = computed(() => (props.compact ? impls.filter(i => i.id === 'dense' || i.id === 'newest') : impls))
const data = computed(() => shown.value.map(im => {
  const ph = Object.fromEntries(phases.map(p => {
    const r = rows.value.find(r => r.input === inp.value && r.implementation === im.id && r.phase === p.id)
    return [p.id, r ? +r.value_ms : 0]
  }))
  const crit = rows.value.find(r => r.input === inp.value && r.implementation === im.id)?.split_criterion
  return { ...im, ph, crit, tot: Object.values(ph).reduce((a, b) => a + b, 0) }
}))
const max = computed(() => Math.max(...data.value.map(d => d.tot), 1e-9))
const dense = computed(() => data.value.find(d => d.id === 'dense')?.tot)
const hover = ref(null)
</script>

<template>
  <div class="pc">
    <div class="ctl">
      <label>input <select v-model="inp"><option v-for="i in inputs" :key="i" :value="i">{{ names[i] || i }}</option></select></label>
      <span v-for="p in phases" :key="p.id" class="pill"><span class="sw" :style="{ background: p.c }"></span>{{ p.label }}</span>
    </div>
    <div v-if="err" class="tiny" style="color: var(--c-bad)">could not load data: {{ err }}. Run <code>npm run sync</code></div>
    <div v-for="d in data" :key="d.id" class="row">
      <div class="lab"><b>{{ d.label }}</b><div class="tiny muted">{{ d.sub }}<template v-if="d.crit && d.crit !== 'not applicable'"> · {{ d.crit }}</template></div></div>
      <div class="track">
        <div v-for="p in phases" :key="p.id" class="seg" :title="`${p.label}: ${d.ph[p.id].toFixed(3)} ms`"
          :style="{ width: (100 * d.ph[p.id]) / max + '%', background: p.c }" @mouseenter="hover = { d, p }" @mouseleave="hover = null"></div>
      </div>
      <div class="val mono">{{ d.tot.toFixed(2) }} ms
        <b v-if="d.id !== 'dense' && dense" :style="{ color: dense / d.tot >= 1 ? 'var(--c-good)' : 'var(--c-bad)' }">
          {{ dense / d.tot >= 1 ? '×' + (dense / d.tot).toFixed(2) : '÷' + (d.tot / dense).toFixed(2) }}</b>
      </div>
    </div>
    <div class="info tiny">
      <template v-if="hover">{{ hover.d.label }} · {{ hover.p.label }}: <b>{{ hover.d.ph[hover.p.id].toFixed(3) }} ms</b> of {{ hover.d.tot.toFixed(3) }} ms</template>
      <template v-else>Mean time per step (separate FMM harness, RTX 5060 Ti, not re-measured with the construction benchmark protocol). Speed-up relative to the dense tree. Hover a segment.</template>
    </div>
  </div>
</template>

<style scoped>
.pc { display: flex; flex-direction: column; gap: 6px; }
.row { display: grid; grid-template-columns: 180px 1fr 130px; gap: 10px; align-items: center; }
.track { height: 22px; display: flex; background: #f8fafc; }
.seg { height: 100%; transition: width 0.4s; border-right: 1px solid white; }
.val { font-size: 0.78rem; text-align: right; }
.info { color: var(--c-muted); min-height: 2.6em; }
@media (max-width: 640px) { .row { grid-template-columns: 1fr; } .val { text-align: left; } }
</style>
