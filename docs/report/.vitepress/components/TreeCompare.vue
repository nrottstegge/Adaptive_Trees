<script setup>
import { computed, ref } from 'vue'
import { particles, quadtree, kdtree } from '../lib/toytree.js'
// Same particles, same LeafCount threshold: quadtree (2D octree analogue, 4 children) vs. binary tree
// (longest-side midpoint splits). 2 binary levels = 1 quadtree level in 2D (3 = 1 octree level in 3D).
const dist = ref('filament')
const threshold = ref(12)
const n = 420
const pts = computed(() => particles(dist.value, n, 7, 0.4))
const q = computed(() => quadtree(pts.value, { threshold: threshold.value, maxLevel: 7 }))
const k = computed(() => kdtree(pts.value, { threshold: threshold.value, maxLevel: 14 }))
const S = 250
const stats = t => ({ leaves: t.numLeaves, nodes: t.nodes, empty: t.empty, emptyPct: ((100 * t.empty) / t.numLeaves).toFixed(0), avg: (n / t.numLeaves).toFixed(1), depth: t.depth })
const panels = computed(() => [
  { name: 'Quadtree (octree in 3D)', c: 'var(--c-oct-leaf)', t: q.value, s: stats(q.value), eq: `depth ${q.value.depth}` },
  { name: 'Binary tree (KDTree3D)', c: 'var(--c-kd-leaf)', t: k.value, s: stats(k.value), eq: `depth ${k.value.depth} ≈ ${(k.value.depth / 2).toFixed(1)} quad levels` },
])
</script>

<template>
  <div>
    <div class="ctl">
      <label>distribution
        <select v-model="dist"><option value="filament">filament</option><option value="cluster">two clusters</option><option value="sparse">sparse clumps</option><option value="uniform">uniform</option></select>
      </label>
      <label>max particles / leaf <input type="range" min="4" max="40" v-model.number="threshold" /> <b>{{ threshold }}</b></label>
    </div>
    <div class="tc">
      <div v-for="p in panels" :key="p.name" class="panel">
        <b :style="{ color: p.c }">{{ p.name }}</b>
        <svg :width="S" :height="S" :viewBox="`-1 -1 ${S + 2} ${S + 2}`">
          <rect x="0" y="0" :width="S" :height="S" fill="var(--c-surface)" stroke="var(--c-line)" />
          <rect v-for="(l, i) in p.t.leaves" :key="i" :x="l.x * S" :y="l.y * S" :width="l.w * S" :height="l.h * S"
            :fill="l.n === 0 ? 'var(--c-empty)' : 'transparent'" :stroke="p.c" stroke-opacity="0.6" stroke-width="0.7" />
          <circle v-for="(pt, i) in pts" :key="'p' + i" :cx="pt[0] * S" :cy="pt[1] * S" r="1.2" fill="var(--c-particle)" />
        </svg>
        <table class="st"><tbody>
          <tr><td>leaves</td><td><b>{{ p.s.leaves }}</b></td><td>empty</td><td><b>{{ p.s.empty }}</b> ({{ p.s.emptyPct }} %)</td></tr>
          <tr><td>nodes</td><td><b>{{ p.s.nodes }}</b></td><td>avg / leaf</td><td><b>{{ p.s.avg }}</b></td></tr>
          <tr><td colspan="4" class="muted">{{ p.eq }}</td></tr>
        </tbody></table>
      </div>
    </div>
  </div>
</template>

<style scoped>
.tc { display: flex; flex-wrap: wrap; gap: 24px; }
.panel { display: flex; flex-direction: column; gap: 6px; }
table.st { font-size: 0.75rem; border-collapse: collapse; margin: 0; display: table; }
table.st td { padding: 1px 8px 1px 0 !important; border: none !important; }
table.st tr { background: none !important; }
</style>
