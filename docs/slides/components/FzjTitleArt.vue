<script setup>
// Title-band artwork: adaptive quadtree cells in FZJ blues (stands in for the template's image band).
import { particles, quadtree, kdtree } from '../lib/toytree.js'
const props = defineProps({ kind: { type: String, default: 'octree' } }) // 'octree' | 'kd'
import { rng } from '../lib/toytree.js'
const ROOTS = 4
const cells = []
const r = rng(5)
for (let k = 0; k < ROOTS; k++) {
  const pts = particles(['cluster', 'sparse', 'dynamic', 'cluster'][k], 520, 11 + k, 0.35)
  const t = props.kind === 'kd' ? kdtree(pts, { threshold: 28, maxLevel: 11 }) : quadtree(pts, { threshold: 10, maxLevel: 6 })
  for (const l of t.leaves) cells.push({ ...l, x: l.x + k, level: props.kind === 'kd' ? l.level / 2 : l.level })
}
const lerp = (a, b, t) => Math.round(a + (b - a) * t)
const c0 = [205, 217, 238], c1 = [78, 116, 178]
function fill(c) {
  const t = Math.min(1, Math.max(0, (c.x + c.w / 2) / ROOTS * 0.85 + c.level * 0.03 + (r() - 0.5) * 0.12))
  return `rgb(${lerp(c0[0], c1[0], t)},${lerp(c0[1], c1[1], t)},${lerp(c0[2], c1[2], t)})`
}
const shaded = cells.map(c => ({ ...c, f: fill(c) }))
</script>

<template>
  <svg :viewBox="`0 0 ${ROOTS} 1`" preserveAspectRatio="xMidYMid slice" width="100%" height="100%">
    <rect v-for="(c, i) in shaded" :key="i" :x="c.x" :y="c.y" :width="c.w" :height="c.h" :fill="c.f"
      stroke="white" stroke-width="0.0035" />
  </svg>
</template>
