<script setup>
// Classic FMM operator picture on a small tree
const root = { x: 200, y: 26 }
const l1 = [{ x: 105, y: 92 }, { x: 295, y: 92 }]
const l2 = [{ x: 55, y: 158 }, { x: 155, y: 158 }, { x: 245, y: 158 }, { x: 345, y: 158 }]
const parts = l2.map(n => [n.x - 14, n.x - 4, n.x + 6, n.x + 15])
const PY = 222
</script>

<template>
  <svg viewBox="0 0 400 285" width="100%">
    <defs>
      <marker v-for="c in ['up', 'down', 'far', 'near']" :key="c" :id="'fo-' + c" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" :fill="`var(--c-op-${c})`" />
      </marker>
    </defs>

    <!-- edges -->
    <line v-for="(n, i) in l1" :key="'e1' + i" :x1="root.x" :y1="root.y" :x2="n.x" :y2="n.y" stroke="var(--c-line)" stroke-width="1.2" />
    <line v-for="(n, i) in l2" :key="'e2' + i" :x1="l1[i >> 1].x" :y1="l1[i >> 1].y" :x2="n.x" :y2="n.y" stroke="var(--c-line)" stroke-width="1.2" />

    <!-- M2M (up) on left branch -->
    <path :d="`M ${l2[0].x + 6} ${l2[0].y - 14} L ${l1[0].x - 8} ${l1[0].y + 14}`" stroke="var(--c-op-up)" stroke-width="2" marker-end="url(#fo-up)" />
    <path :d="`M ${l1[0].x + 8} ${l1[0].y - 14} L ${root.x - 14} ${root.y + 10}`" stroke="var(--c-op-up)" stroke-width="2" marker-end="url(#fo-up)" />
    <text :x="l1[0].x - 88" :y="l1[0].y - 4" style="font-size:11px; font-weight:700" fill="var(--c-op-up)">M2M</text>

    <!-- L2L (down) on right branch -->
    <path :d="`M ${root.x + 14} ${root.y + 10} L ${l1[1].x - 8} ${l1[1].y - 14}`" stroke="var(--c-op-down)" stroke-width="2" marker-end="url(#fo-down)" />
    <path :d="`M ${l1[1].x + 8} ${l1[1].y + 14} L ${l2[3].x - 6} ${l2[3].y - 14}`" stroke="var(--c-op-down)" stroke-width="2" marker-end="url(#fo-down)" />
    <text :x="l1[1].x + 54" :y="l1[1].y - 4" style="font-size:11px; font-weight:700" fill="var(--c-op-down)">L2L</text>

    <!-- M2L between well-separated leaves (same level, not neighbours) -->
    <path :d="`M ${l2[0].x + 12} ${l2[0].y - 6} C 130 118, 270 118, ${l2[3].x - 14} ${l2[3].y - 6}`" fill="none" stroke="var(--c-op-far)" stroke-width="2" stroke-dasharray="5 3" marker-end="url(#fo-far)" />
    <rect x="182" y="113" width="36" height="14" fill="var(--c-bg)" />
    <text x="200" y="124" text-anchor="middle" style="font-size:11px; font-weight:700" fill="var(--c-op-far)">M2L</text>

    <!-- nodes -->
    <circle :cx="root.x" :cy="root.y" r="11" fill="var(--c-surface)" stroke="var(--c-ink)" stroke-width="1.5" />
    <circle v-for="(n, i) in l1" :key="'n1' + i" :cx="n.x" :cy="n.y" r="11" fill="var(--c-surface)" stroke="var(--c-ink)" stroke-width="1.5" />
    <rect v-for="(n, i) in l2" :key="'n2' + i" :x="n.x - 11" :y="n.y - 11" width="22" height="22" rx="3"
      fill="color-mix(in srgb, var(--c-accent) 14%, var(--c-surface))" stroke="var(--c-accent)" stroke-width="1.5" />

    <!-- particles -->
    <g v-for="(grp, gi) in parts" :key="'g' + gi">
      <circle v-for="(px, pi) in grp" :key="pi" :cx="px" :cy="PY + (pi % 2) * 7" r="3" fill="var(--c-particle)" />
    </g>
    <!-- P2M (leaf 0), L2P (leaf 3) -->
    <path :d="`M ${l2[0].x} ${PY - 8} L ${l2[0].x} ${l2[0].y + 16}`" stroke="var(--c-op-up)" stroke-width="2" marker-end="url(#fo-up)" />
    <text :x="l2[0].x - 34" y="198" style="font-size:11px; font-weight:700" fill="var(--c-op-up)">P2M</text>
    <path :d="`M ${l2[3].x} ${l2[3].y + 14} L ${l2[3].x} ${PY - 10}`" stroke="var(--c-op-down)" stroke-width="2" marker-end="url(#fo-down)" />
    <text :x="l2[3].x + 8" y="198" style="font-size:11px; font-weight:700" fill="var(--c-op-down)">L2P</text>
    <!-- P2P between neighbouring leaves -->
    <path :d="`M ${l2[1].x - 10} ${PY + 20} Q 200 ${PY + 40} ${l2[2].x + 10} ${PY + 20}`" fill="none" stroke="var(--c-op-near)" stroke-width="2" marker-end="url(#fo-near)" />
    <path :d="`M ${l2[2].x - 10} ${PY + 20} Q 200 ${PY + 32} ${l2[1].x + 10} ${PY + 20}`" fill="none" stroke="var(--c-op-near)" stroke-width="1.2" stroke-opacity="0.5" />
    <text x="200" :y="PY + 38" text-anchor="middle" style="font-size:11px; font-weight:700" fill="var(--c-op-near)" dy="14">P2P</text>
  </svg>
</template>
