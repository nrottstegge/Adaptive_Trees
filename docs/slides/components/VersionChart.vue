<script setup>
import { computed } from 'vue'
// Runtime per implementation version. Fill `update` / `view` (ms); null -> placeholder bar.
const props = defineProps({
  data: { type: Array, required: true }, // [{ v, sub, update, view }]
  height: { type: Number, default: 250 },
})
const total = d => (d.update ?? 0) + (d.view ?? 0)
const known = computed(() => props.data.every(d => d.update != null))
const max = computed(() => Math.max(...props.data.map(total), 1e-9))
const base = computed(() => total(props.data[0]))
const fmt = x => (x >= 10 ? x.toFixed(0) : x >= 1 ? x.toFixed(1) : x.toFixed(2))
</script>

<template>
  <div class="vc">
    <div class="bars" :style="{ height: height + 'px' }">
      <div v-for="(d, i) in data" :key="i" class="col">
        <template v-if="d.update != null">
          <div class="val">{{ fmt(total(d)) }} ms</div>
          <div v-if="i > 0 && base" class="spd">{{ (base / total(d)).toFixed(1) }}×</div>
          <div class="stack" :style="{ height: (total(d) / max) * (height - 40) + 'px' }">
            <div v-if="d.view" class="seg" :style="{ flex: d.view, background: 'var(--c-view)' }"></div>
            <div class="seg" :style="{ flex: d.update, background: 'var(--c-update)' }"></div>
          </div>
        </template>
        <template v-else>
          <div class="ins">[INSERT]</div>
          <div class="stack ghost" :style="{ height: (height - 40) * 0.6 + 'px' }"></div>
        </template>
      </div>
    </div>
    <div class="labels">
      <div v-for="(d, i) in data" :key="i" class="lab">
        <b>{{ d.v }}</b><div class="muted">{{ d.sub }}</div>
      </div>
    </div>
    <div v-if="!known" class="tiny muted mt-1">Placeholder bars — set <span class="mono">update</span> / <span class="mono">view</span> in ms per version on this slide.</div>
  </div>
</template>

<style scoped>
.bars, .labels { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; gap: 10px; }
.bars { align-items: end; border-bottom: 1.5px solid var(--c-ink); }
.col { display: flex; flex-direction: column; align-items: center; justify-content: flex-end; height: 100%; }
.stack { width: 62%; display: flex; flex-direction: column; border-radius: 4px 4px 0 0; overflow: hidden; }
.stack.ghost { border: 1.5px dashed var(--c-placeholder); border-bottom: none; background: repeating-linear-gradient(135deg, transparent 0 8px, color-mix(in srgb, var(--c-placeholder) 7%, transparent) 8px 16px); }
.seg { width: 100%; }
.val { font-size: 0.68rem; font-weight: 700; font-variant-numeric: tabular-nums; }
.spd { font-size: 0.6rem; color: var(--c-muted); }
.lab { text-align: center; font-size: 0.66rem; line-height: 1.2; padding-top: 4px; }
.lab .muted { font-size: 0.58rem; }
</style>
