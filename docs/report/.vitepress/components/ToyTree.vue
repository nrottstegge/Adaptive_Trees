<script setup>
import { computed } from 'vue'
import { particles, quadtree, kdtree, dense, sparse } from '../lib/toytree.js'

const props = defineProps({
  dist: { type: String, default: 'cluster' },
  mode: { type: String, default: 'adaptive' }, // none | dense | sparse | adaptive | nf | kd
  n: { type: Number, default: 420 },
  seed: { type: Number, default: 7 },
  t: { type: Number, default: 0 },
  threshold: { type: Number, default: 14 },
  nfThreshold: { type: Number, default: 500 },
  denseLevel: { type: Number, default: 4 },
  maxLevel: { type: Number, default: 6 },
  size: { type: Number, default: 260 },
  stats: { type: Boolean, default: false },
  shadeEmpty: { type: Boolean, default: false },
  depthFill: { type: Boolean, default: false },
  accent: { type: String, default: 'var(--c-ink)' },
  dot: { type: Number, default: 1.6 },
  label: { type: String, default: '' },
})

const pts = computed(() => particles(props.dist, props.n, props.seed, props.t))
const tree = computed(() => {
  const p = pts.value
  if (props.mode === 'none') return null
  if (props.mode === 'dense') return dense(p, props.denseLevel)
  if (props.mode === 'sparse') return sparse(p, props.denseLevel)
  if (props.mode === 'kd') return kdtree(p, { threshold: props.threshold, maxLevel: 2 * props.maxLevel })
  return quadtree(p, {
    criterion: props.mode === 'nf' ? 'nf' : 'count',
    threshold: props.threshold,
    nfThreshold: props.nfThreshold,
    maxLevel: props.maxLevel,
  })
})
const S = computed(() => props.size)
function fill(l) {
  if (props.shadeEmpty && l.n === 0) return 'var(--c-empty)'
  if (props.depthFill) {
    const max = props.mode === 'kd' ? 2 * props.maxLevel : props.maxLevel
    const a = 0.04 + 0.26 * (l.level / max)
    return `color-mix(in srgb, ${props.accent} ${Math.round(a * 100)}%, transparent)`
  }
  return 'transparent'
}
</script>

<template>
  <div class="toy">
    <svg :width="S" :height="S" :viewBox="`-1 -1 ${S + 2} ${S + 2}`">
      <rect x="0" y="0" :width="S" :height="S" fill="var(--c-surface)" stroke="var(--c-line)" />
      <g v-if="tree">
        <rect v-for="(l, i) in tree.leaves" :key="i"
          :x="l.x * S" :y="l.y * S" :width="l.w * S" :height="l.h * S"
          :fill="fill(l)" :stroke="accent" stroke-opacity="0.55" stroke-width="0.7" />
      </g>
      <circle v-for="(p, i) in pts" :key="'p' + i" :cx="p[0] * S" :cy="p[1] * S" :r="dot"
        fill="var(--c-particle)" />
    </svg>
    <div v-if="label" class="toy-label">{{ label }}</div>
    <div v-if="stats && tree" class="toy-stats">
      <span><b>{{ tree.nodes }}</b> nodes</span>
      <span><b>{{ tree.numLeaves }}</b> leaves</span>
      <span><b>{{ tree.empty }}</b> empty</span>
      <span>depth <b>{{ tree.depth }}</b></span>
    </div>
  </div>
</template>

<style scoped>
.toy { display: inline-flex; flex-direction: column; align-items: center; gap: 6px; }
.toy-label { font-size: 0.8rem; font-weight: 600; color: var(--c-ink); }
.toy-stats { display: flex; gap: 10px; white-space: nowrap; font-size: 0.68rem; color: var(--c-muted); font-variant-numeric: tabular-nums; }
.toy-stats b { color: var(--c-ink); font-weight: 600; }
</style>
