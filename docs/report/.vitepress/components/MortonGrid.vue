<script setup>
import { computed } from 'vue'
const props = defineProps({
  level: { type: Number, default: 3 },
  size: { type: Number, default: 250 },
  showKeys: { type: Boolean, default: true },
  showCurve: { type: Boolean, default: true },
  showPoints: { type: Boolean, default: true },
})
const m = computed(() => 1 << props.level)
const s = computed(() => props.size / m.value)
function morton(x, y) {
  let k = 0
  for (let b = 0; b < 16; b++) k |= ((x >> b) & 1) << (2 * b) | ((y >> b) & 1) << (2 * b + 1)
  return k
}
const cells = computed(() => {
  const out = []
  for (let y = 0; y < m.value; y++) for (let x = 0; x < m.value; x++) out.push({ x, y, k: morton(x, y) })
  return out.sort((a, b) => a.k - b.k)
})
const path = computed(() => cells.value.map((c, i) => `${i ? 'L' : 'M'} ${(c.x + 0.5) * s.value} ${(c.y + 0.5) * s.value}`).join(' '))
const raw = [[0.12, 0.2], [0.33, 0.1], [0.7, 0.14], [0.61, 0.33], [0.2, 0.62], [0.42, 0.56], [0.9, 0.58], [0.1, 0.9], [0.55, 0.82], [0.83, 0.88], [0.66, 0.66]]
const pts = computed(() => raw.map(([px, py]) => {
  const cx = Math.floor(px * m.value), cy = Math.floor(py * m.value)
  return { px, py, k: morton(cx, cy) }
}).sort((a, b) => a.k - b.k))
</script>

<template>
  <div class="mg">
    <svg :width="size" :height="size" :viewBox="`-1 -1 ${size + 2} ${size + 2}`">
      <rect v-for="c in cells" :key="c.k" :x="c.x * s" :y="c.y * s" :width="s" :height="s"
        fill="var(--c-surface)" stroke="var(--c-line)" stroke-width="0.7" />
      <text v-if="showKeys" v-for="c in cells" :key="'t' + c.k" :x="c.x * s + 3" :y="c.y * s + 9"
        style="font-size:7px" fill="var(--c-muted)">{{ c.k }}</text>
      <path v-if="showCurve" :d="path" fill="none" stroke="var(--c-accent)" stroke-width="1.6" stroke-opacity="0.8" stroke-linejoin="round" />
      <g v-if="showPoints">
        <circle v-for="(p, i) in pts" :key="'p' + i" :cx="p.px * size" :cy="p.py * size" r="4.5"
          fill="var(--c-particle)" stroke="var(--c-surface)" stroke-width="1.2" />
      </g>
    </svg>
    <div v-if="showPoints" class="parr">
      <span class="lab">P =</span>
      <span v-for="(p, i) in pts" :key="i" class="chip">{{ p.k }}</span>
    </div>
  </div>
</template>

<style scoped>
.mg { display: inline-flex; flex-direction: column; align-items: center; gap: 10px; }
.parr { display: flex; gap: 3px; align-items: center; font-family: var(--vp-font-family-mono); font-size: 0.7rem; }
.lab { font-weight: 700; margin-right: 4px; color: var(--c-ink); }
.chip { border: 1px solid var(--c-line-strong); border-radius: 4px; padding: 1px 5px; background: var(--c-surface); min-width: 22px; text-align: center; }
</style>
