<script setup>
// Binary-ish tree with upward (blue-free neutral) and downward arrows
const W = 380, H = 250
const levels = [
  [{ x: 190 }],
  [{ x: 100 }, { x: 280 }],
  [{ x: 55 }, { x: 145 }, { x: 235 }, { x: 325 }],
]
const y = [30, 105, 180]
const edges = []
levels[1].forEach((n, i) => edges.push([levels[0][0].x, y[0], n.x, y[1]]))
levels[2].forEach((n, i) => edges.push([levels[1][Math.floor(i / 2)].x, y[1], n.x, y[2]]))
const parts = [[40, 50, 62], [135, 150], [222, 232, 240, 252], [318, 334]]
</script>

<template>
  <svg :viewBox="`0 0 ${W} ${H}`" width="100%" style="max-width: 400px">
    <defs>
      <marker id="fa-up" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-up)" />
      </marker>
      <marker id="fa-dn" markerWidth="8" markerHeight="8" refX="4" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-down)" />
      </marker>
    </defs>
    <line v-for="(e, i) in edges" :key="i" :x1="e[0]" :y1="e[1]" :x2="e[2]" :y2="e[3]" stroke="var(--c-line-strong)" stroke-width="1.5" />
    <g v-for="(lv, li) in levels" :key="li">
      <circle v-for="(n, ni) in lv" :key="ni" :cx="n.x" :cy="y[li]" r="11" fill="var(--c-surface)" stroke="var(--c-ink)" stroke-width="1.5" />
    </g>
    <g v-for="(grp, gi) in parts" :key="'g' + gi">
      <circle v-for="(px, pi) in grp" :key="pi" :cx="px" :cy="222 + (pi % 2) * 8" r="3" fill="var(--c-particle)" />
      <line :x1="levels[2][gi].x" y1="191" :x2="levels[2][gi].x" y2="214" stroke="var(--c-line)" stroke-dasharray="2 2" />
    </g>
    <text x="190" y="14" text-anchor="middle" style="font-size:10px" fill="var(--c-muted)">root</text>
    <text x="190" y="250" text-anchor="middle" style="font-size:10px" fill="var(--c-muted)">particles</text>
    <!-- upward -->
    <path d="M 14 222 C 8 150, 8 80, 150 26" fill="none" stroke="var(--c-up)" stroke-width="2.2" marker-end="url(#fa-up)" />
    <text x="6" y="238" style="font-size:12px" fill="var(--c-up)" font-weight="700">↑ upward</text>
    <!-- downward -->
    <path d="M 230 26 C 372 80, 372 150, 366 222" fill="none" stroke="var(--c-down)" stroke-width="2.2" marker-end="url(#fa-dn)" />
    <text x="374" y="238" text-anchor="end" style="font-size:12px" fill="var(--c-down)" font-weight="700">downward ↓</text>
  </svg>
</template>
