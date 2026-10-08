<script setup>
import { computed, ref } from 'vue'
import { particles, quadtree } from '../lib/toytree.js'

// LeafCount looks at one leaf; NFCount looks at the leaf + its 3x3 same-level stencil.
const props = defineProps({
  dist: { type: String, default: 'cluster' },
  n: { type: Number, default: 300 },
  seed: { type: Number, default: 7 },
  threshold: { type: Number, default: 14 },
  maxLevel: { type: Number, default: 4 },
  size: { type: Number, default: 220 },
})

const pts = computed(() => particles(props.dist, props.n, props.seed))
const count = (x, y, w, h) => {
  let c = 0
  for (const p of pts.value) if (p[0] >= x && p[0] < x + w && p[1] >= y && p[1] < y + h) c++
  return c
}
const leaves = computed(() => quadtree(pts.value, { threshold: props.threshold, maxLevel: props.maxLevel }).leaves.map(l => {
  const nb = count(l.x - l.w, l.y - l.h, 3 * l.w, 3 * l.h) - l.n
  return { ...l, nb, nf: l.n * (l.n + nb) }
}))
// default: an interior leaf with few particles but a busy neighbourhood (shows the difference best)
const defaultLeaf = computed(() => {
  let best = 0, score = -1
  leaves.value.forEach((l, i) => {
    const interior = l.x - l.w >= 0 && l.y - l.h >= 0 && l.x + 2 * l.w <= 1 && l.y + 2 * l.h <= 1
    const sc = interior && l.n >= 3 ? l.nb / l.n : -1
    if (sc > score) { score = sc; best = i }
  })
  return best
})
const hover = ref(-1)
const L = computed(() => leaves.value[hover.value >= 0 ? hover.value : defaultLeaf.value])

const inBox = (p, x, y, w, h) => p[0] >= x && p[0] < x + w && p[1] >= y && p[1] < y + h
function ptColor(p, stencil) {
  const l = L.value
  if (inBox(p, l.x, l.y, l.w, l.h)) return 'var(--c-ink)'
  if (stencil && inBox(p, l.x - l.w, l.y - l.h, 3 * l.w, 3 * l.h)) return 'var(--c-accent)'
  return 'var(--c-line-strong)'
}
const panels = [
  { key: 'n', title: 'LeafCount', sub: 'particles in the leaf', color: 'var(--c-oct-leaf)', stencil: false },
  { key: 'nf', title: 'NFCount', sub: 'leaf + 3×3 same-level stencil', color: 'var(--c-oct-nf)', stencil: true },
]
</script>

<template>
  <div>
  <div class="nfv" :style="{ gridTemplateColumns: `${size + 24}px ${size + 140}px` }">
    <div v-for="pn in panels" :key="pn.key" class="panel" :style="{ width: size + 'px' }">
      <div class="ptitle"><b :style="{ color: pn.color }">{{ pn.title }}</b> <span class="muted">· {{ pn.sub }}</span></div>
      <svg :width="size" :height="size" :viewBox="`-1 -1 ${size + 2} ${size + 2}`">
        <clipPath :id="'dom-' + pn.key"><rect x="0" y="0" :width="size" :height="size" /></clipPath>
        <rect v-for="(l, i) in leaves" :key="i" :x="l.x * size" :y="l.y * size" :width="l.w * size" :height="l.h * size"
          fill="var(--c-surface)" stroke="var(--c-line)" stroke-width="0.8"
          @mouseenter="hover = i" @mouseleave="hover = -1" />
        <!-- stencil (NFCount only) -->
        <g v-if="pn.stencil" pointer-events="none" :clip-path="`url(#dom-${pn.key})`">
          <rect :x="(L.x - L.w) * size" :y="(L.y - L.h) * size" :width="3 * L.w * size" :height="3 * L.h * size"
            :fill="`color-mix(in srgb, ${pn.color} 12%, transparent)`" :stroke="pn.color" stroke-width="1.6" />
          <line v-for="k in 2" :key="'v' + k" :x1="(L.x - L.w + k * L.w) * size" :x2="(L.x - L.w + k * L.w) * size"
            :y1="(L.y - L.h) * size" :y2="(L.y + 2 * L.h) * size" :stroke="pn.color" stroke-dasharray="3 2" />
          <line v-for="k in 2" :key="'h' + k" :y1="(L.y - L.h + k * L.h) * size" :y2="(L.y - L.h + k * L.h) * size"
            :x1="(L.x - L.w) * size" :x2="(L.x + 2 * L.w) * size" :stroke="pn.color" stroke-dasharray="3 2" />
        </g>
        <!-- the leaf itself -->
        <rect :x="L.x * size" :y="L.y * size" :width="L.w * size" :height="L.h * size" pointer-events="none"
          :fill="`color-mix(in srgb, ${pn.color} 22%, transparent)`" :stroke="pn.color" stroke-width="2.2" />
        <circle v-for="(p, i) in pts" :key="'p' + i" :cx="p[0] * size" :cy="p[1] * size" r="1.3"
          :fill="ptColor(p, pn.stencil)" pointer-events="none" />
      </svg>
      <div class="eq mono" :style="{ borderColor: pn.color }">
        <template v-if="!pn.stencil">N<sub>i</sub> = <b :style="{ color: pn.color }">{{ L.n }}</b></template>
        <template v-else>NF<sub>i</sub> = {{ L.n }} · ({{ L.n }} + {{ L.nb }}) = <b :style="{ color: pn.color }">{{ L.nf }}</b></template>
      </div>
    </div>
  </div>
  <div class="hint">same leaf in both panels · hover another leaf · 2D toy: 3×3 stencil (3D: 3×3×3)</div>
  </div>
</template>

<style scoped>
.nfv { display: grid; column-gap: 0; justify-content: start; }
.panel { display: flex; flex-direction: column; gap: 6px; align-items: flex-start; }
.ptitle { font-size: 0.78rem; white-space: nowrap; }
.eq { white-space: nowrap; border: 1.5px solid; background: var(--c-surface); border-radius: 4px; padding: 4px 10px; font-size: 0.8rem; }
.hint { font-size: 0.6rem; color: var(--c-muted); font-style: italic; margin-top: 4px; }
</style>
