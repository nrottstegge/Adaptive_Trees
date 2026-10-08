<script setup>
// Adaptive update: linear pre-processing, an inner rebalance cycle (tree update phase),
// then TreeView + FMM, all inside the outer time-step loop.
const C = { x: 520, y: 150, r: 92 }
const deg = a => (a * Math.PI) / 180
const at = a => ({ x: C.x + C.r * Math.cos(deg(a)), y: C.y + C.r * Math.sin(deg(a)) })
// cycle nodes (SVG angles, y down): top, bottom-right, bottom-left
const cyc = [
  { a: -90, t: 'evaluate N / NF', p: 'binary search' },
  { a: 30, t: 'split / merge', p: 'map · per leaf' },
  { a: 150, t: 'new K', p: 'scan + scatter' },
]
const nodes = cyc.map(n => ({ ...n, ...at(n.a) }))
// angular clearance around a node: the wide top node needs more than the two lower ones
const clear = a => (((a % 360) + 360) % 360 === 270 ? 42 : 22)
function arc(a0, a1) {
  const s = at(a0 + clear(a0)), e = at(a1 - clear(a1))
  return `M ${s.x} ${s.y} A ${C.r} ${C.r} 0 0 1 ${e.x} ${e.y}`
}
const arcs = [arc(-90, 30), arc(30, 150), arc(150, 270)]
const chain = [
  { x: 62, t: 'positions', p: '' },
  { x: 180, t: 'Morton keys P', p: 'map' },
  { x: 298, t: 'sort', p: 'radix sort' },
]
const W = 112, H = 38
</script>

<template>
  <svg viewBox="0 0 860 320" width="100%">
    <defs>
      <marker id="ul-a" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-ink)" />
      </marker>
      <marker id="ul-b" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-update)" />
      </marker>
      <marker id="ul-m" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-muted)" />
      </marker>
    </defs>

    <!-- tree-update region -->
    <circle :cx="C.x" :cy="C.y" :r="C.r + 44" fill="color-mix(in srgb, var(--c-update) 7%, transparent)"
      stroke="var(--c-update)" stroke-opacity="0.35" stroke-dasharray="4 4" />
    <text :x="C.x" :y="C.y - C.r - 50" text-anchor="middle" style="font-size:12px; font-weight:700" fill="var(--c-update)">tree update</text>

    <!-- inner cycle -->
    <path v-for="(d, i) in arcs" :key="i" :d="d" fill="none" stroke="var(--c-update)" stroke-width="2" marker-end="url(#ul-b)" />
    <text :x="C.x" :y="C.y - 4" text-anchor="middle" style="font-size:12px; font-weight:600" fill="var(--c-ink)">rebalance</text>
    <text :x="C.x" :y="C.y + 12" text-anchor="middle" style="font-size:10.5px" fill="var(--c-muted)">until converged</text>

    <g v-for="n in nodes" :key="n.t">
      <rect :x="n.x - W / 2" :y="n.y - H / 2" :width="W" :height="H" rx="8"
        :fill="n.t === 'new K' ? 'color-mix(in srgb, var(--c-update) 16%, var(--c-surface))' : 'var(--c-surface)'"
        stroke="var(--c-update)" stroke-width="1.5" />
      <text :x="n.x" :y="n.y - 2" text-anchor="middle" style="font-size:12px; font-weight:600" fill="var(--c-ink)">{{ n.t }}</text>
      <text :x="n.x" :y="n.y + 12" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">{{ n.p }}</text>
    </g>

    <!-- linear pre-processing -->
    <g v-for="(n, i) in chain" :key="n.t">
      <rect :x="n.x - 50" :y="C.y - H / 2" width="100" :height="H" rx="8" fill="var(--c-surface)" stroke="var(--c-line-strong)" stroke-width="1.5" />
      <text :x="n.x" :y="C.y + (n.p ? -2 : 4)" text-anchor="middle" style="font-size:12px; font-weight:600" fill="var(--c-ink)">{{ n.t }}</text>
      <text v-if="n.p" :x="n.x" :y="C.y + 12" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">{{ n.p }}</text>
      <line v-if="i < chain.length - 1" :x1="n.x + 50" :y1="C.y" :x2="chain[i + 1].x - 54" :y2="C.y" stroke="var(--c-ink)" stroke-width="1.5" marker-end="url(#ul-a)" />
    </g>
    <!-- enter cycle -->
    <path :d="`M ${298 + 50} ${C.y} C 395 ${C.y}, 400 ${nodes[0].y}, ${nodes[0].x - W / 2 - 4} ${nodes[0].y}`"
      fill="none" stroke="var(--c-ink)" stroke-width="1.5" marker-end="url(#ul-a)" />

    <!-- exit: no split/merge left -> converged -->
    <path :d="`M ${nodes[1].x + W / 2} ${nodes[1].y} C 700 ${nodes[1].y}, 700 ${C.y}, 724 ${C.y - 30}`"
      fill="none" stroke="var(--c-ink)" stroke-width="1.5" marker-end="url(#ul-a)" />
    <text x="694" :y="nodes[1].y + 18" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">no change</text>

    <!-- TreeView + FMM -->
    <rect x="730" :y="C.y - 58" width="104" :height="H" rx="8" fill="color-mix(in srgb, var(--c-view) 14%, var(--c-surface))" stroke="var(--c-view)" stroke-width="1.5" />
    <text x="782" :y="C.y - 35" text-anchor="middle" style="font-size:12px; font-weight:700" fill="var(--c-ink)">TreeView</text>
    <line x1="782" :y1="C.y - 20" x2="782" :y2="C.y + 14" stroke="var(--c-ink)" stroke-width="1.5" marker-end="url(#ul-a)" />
    <rect x="730" :y="C.y + 18" width="104" :height="H" rx="8" fill="var(--c-surface)" stroke="var(--c-ink)" stroke-width="1.5" />
    <text x="782" :y="C.y + 34" text-anchor="middle" style="font-size:12px; font-weight:700" fill="var(--c-ink)">FMM</text>
    <text x="782" :y="C.y + 48" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">forces / potentials</text>

    <!-- outer time-step loop -->
    <path :d="`M 782 ${C.y + 56} L 782 296 Q 782 304 772 304 L 72 304 Q 62 304 62 296 L 62 ${C.y + H / 2 + 6}`"
      fill="none" stroke="var(--c-muted)" stroke-width="1.5" stroke-dasharray="5 4" marker-end="url(#ul-m)" />
    <rect x="300" y="294" width="260" height="20" fill="var(--c-bg)" />
    <text x="430" y="308" text-anchor="middle" style="font-size:11px" fill="var(--c-muted)">next time step: particles move</text>
  </svg>
</template>
