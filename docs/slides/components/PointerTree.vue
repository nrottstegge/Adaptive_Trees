<script setup>
// Sparse pointer tree and its scattered memory layout
const nodes = [
  { id: 'R', x: 150, y: 24, addr: 2 },
  { id: 'A', x: 70, y: 84, addr: 9 },
  { id: 'B', x: 230, y: 84, addr: 5 },
  { id: 'C', x: 30, y: 144, addr: 13 },
  { id: 'D', x: 110, y: 144, addr: 0 },
  { id: 'E', x: 200, y: 144, addr: 11 },
  { id: 'F', x: 265, y: 144, addr: 7 },
  { id: 'G', x: 180, y: 200, addr: 15 },
  { id: 'H', x: 225, y: 200, addr: 3 },
]
const edges = [['R', 'A'], ['R', 'B'], ['A', 'C'], ['A', 'D'], ['B', 'E'], ['B', 'F'], ['E', 'G'], ['E', 'H']]
const by = Object.fromEntries(nodes.map(n => [n.id, n]))
const cell = 21, mx = 330, my = 70
const memX = a => mx + (a % 4) * cell * 1.9
const memY = a => my + Math.floor(a / 4) * cell * 1.5
</script>

<template>
  <svg viewBox="0 0 520 230" width="100%">
    <line v-for="(e, i) in edges" :key="i" :x1="by[e[0]].x" :y1="by[e[0]].y" :x2="by[e[1]].x" :y2="by[e[1]].y"
      stroke="var(--c-line-strong)" stroke-width="1.4" />
    <g v-for="n in nodes" :key="n.id">
      <circle :cx="n.x" :cy="n.y" r="13" fill="var(--c-surface)" stroke="var(--c-ink)" stroke-width="1.4" />
      <text :x="n.x" :y="n.y + 4" text-anchor="middle" style="font-size:13px" fill="var(--c-ink)">{{ n.id }}</text>
    </g>
    <text x="150" y="226" text-anchor="middle" style="font-size:11px" fill="var(--c-muted)">logical tree</text>

    <text :x="mx + 70" :y="my - 22" text-anchor="middle" style="font-size:11px" fill="var(--c-muted)">device memory (heap)</text>
    <g v-for="a in 16" :key="'m' + a">
      <rect :x="memX(a - 1) - 17" :y="memY(a - 1) - 13" width="34" height="22" rx="3"
        fill="var(--c-surface)" stroke="var(--c-line)" />
    </g>
    <g v-for="n in nodes" :key="'mm' + n.id">
      <rect :x="memX(n.addr) - 17" :y="memY(n.addr) - 13" width="34" height="22" rx="3"
        fill="color-mix(in srgb, var(--c-bad) 14%, var(--c-surface))" stroke="var(--c-bad)" />
      <text :x="memX(n.addr)" :y="memY(n.addr) + 3" text-anchor="middle" style="font-size:11px" fill="var(--c-ink)">{{ n.id }}</text>
    </g>
    <path v-for="(e, i) in edges" :key="'p' + i"
      :d="`M ${memX(by[e[0]].addr)} ${memY(by[e[0]].addr)} Q ${(memX(by[e[0]].addr) + memX(by[e[1]].addr)) / 2 + 18} ${(memY(by[e[0]].addr) + memY(by[e[1]].addr)) / 2 - 18} ${memX(by[e[1]].addr)} ${memY(by[e[1]].addr)}`"
      fill="none" stroke="var(--c-bad)" stroke-opacity="0.55" stroke-width="1" />
  </svg>
</template>
