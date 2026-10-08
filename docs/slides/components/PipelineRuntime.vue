<script setup>
import { computed } from 'vue'
// Full-pipeline runtime per dataset/config. Parts in ms; null -> placeholder bar.
const props = defineProps({
  rows: { type: Array, required: true }, // [{ group, label, color, update, view, fmm, far, near }]
})
const PH = [
  ['update', 'var(--c-update)'], ['view', 'var(--c-view)'],
  ['far', 'var(--c-op-far)'], ['near', 'var(--c-op-near)'], ['fmm', 'var(--c-op-far)'],
]
const tot = r => PH.reduce((s, [k]) => s + (r[k] ?? 0), 0)
const has = r => tot(r) > 0
const max = computed(() => Math.max(...props.rows.map(tot), 1e-9))
const fmt = x => (x >= 10 ? x.toFixed(0) : x >= 1 ? x.toFixed(1) : x.toFixed(2))
</script>

<template>
  <div class="pr">
    <template v-for="(r, i) in rows" :key="i">
      <div v-if="r.group && (i === 0 || rows[i - 1].group !== r.group)" class="grp">{{ r.group }}</div>
      <div class="row">
        <span class="lab" :style="{ color: r.color }">{{ r.label }}</span>
        <div class="track">
          <div v-if="has(r)" class="bar" :style="{ width: (tot(r) / max) * 100 + '%' }">
            <template v-for="[k, c] in PH" :key="k">
              <div v-if="r[k]" :style="{ flex: r[k], background: c }"></div>
            </template>
          </div>
          <div v-else class="bar ghost"></div>
        </div>
        <span class="val" :class="{ ins: !has(r) }">{{ has(r) ? fmt(tot(r)) + ' ms' : '[INSERT RUNTIME]' }}</span>
      </div>
    </template>
  </div>
</template>

<style scoped>
.pr { display: flex; flex-direction: column; gap: 3px; }
.grp { font-size: 0.7rem; font-weight: 700; margin-top: 6px; }
.row { display: grid; grid-template-columns: 140px 1fr 110px; gap: 10px; align-items: center; }
.lab { font-size: 0.64rem; font-weight: 600; }
.track { height: 16px; }
.bar { height: 100%; display: flex; border-radius: 3px; overflow: hidden; }
.bar.ghost { width: 100%; border: 1.5px dashed var(--c-placeholder); background: repeating-linear-gradient(135deg, transparent 0 8px, color-mix(in srgb, var(--c-placeholder) 7%, transparent) 8px 16px); }
.val { font-size: 0.64rem; font-variant-numeric: tabular-nums; text-align: right; }
</style>
