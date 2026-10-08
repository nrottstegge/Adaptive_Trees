<script setup>
import { computed } from 'vue'
// One benchmark slide: figure (switchable by clicks) + dataset animation top right.
const props = defineProps({
  figures: { type: Array, required: true }, // [{ label, src, color }]
  gif: { type: String, default: '' },
  facts: { type: Array, default: () => [] }, // [[key, value]]
  legend: { type: Array, default: () => [] }, // [[label, color]]
  step: { type: Number, default: 0 },
})
const active = computed(() => Math.min(props.step, props.figures.length - 1))
const fig = computed(() => props.figures[active.value])
</script>

<template>
  <div class="db">
    <div class="fig">
      <div class="tabs">
        <span v-for="(f, i) in figures" :key="i" class="pill" :class="{ on: i === active }"
          :style="i === active ? { borderColor: f.color, color: f.color } : {}">
          <span class="sw" :style="{ background: f.color }"></span>{{ f.label }}
        </span>
        <span v-for="l in legend" :key="l[0]" class="pill"><span class="sw" :style="{ background: l[1] }"></span>{{ l[0] }}</span>
      </div>
      <div class="frame">
        <MediaSlot :key="fig.src" :src="fig.src" label="[INSERT BENCHMARK]" />
      </div>
    </div>
    <div class="side">
      <div class="gif"><MediaSlot :src="gif" label="[INSERT GIF]" fit="cover" /></div>
      <div class="card tiny facts">
        <div v-for="f in facts" :key="f[0]" class="row"><span class="muted">{{ f[0] }}</span><span :class="{ ins: String(f[1]).startsWith('[') }">{{ f[1] }}</span></div>
      </div>
      <div v-if="figures.length > 1" class="tiny muted">click → {{ figures.map(f => f.label).join(' / ') }}</div>
    </div>
  </div>
</template>

<style scoped>
.db { display: grid; grid-template-columns: 1fr 165px; gap: 12px; height: 420px; margin-top: -54px; }
.fig { display: flex; flex-direction: column; gap: 6px; padding-top: 54px; min-height: 0; }
.tabs { display: flex; gap: 6px; flex-wrap: wrap; }
.pill.on { font-weight: 700; border-width: 2px; }
.frame { flex: 1; min-height: 0; position: relative; }
.side { display: flex; flex-direction: column; gap: 8px; }
.gif { width: 165px; height: 165px; border-radius: 10px; overflow: hidden; border: 1px solid var(--c-line); background: var(--c-surface); }
.facts .row { display: flex; justify-content: space-between; gap: 8px; padding: 1px 0; }
</style>
