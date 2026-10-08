<script setup>
// Isometric comparison: octree (1 split -> 8 cubes) vs KDTree3D (3 binary splits along the longest axis).
// Layout is computed from each stage's projected bounding box so labels and arrows line up.
const s = 44, gap = 0.12
const P = (x, y, z) => [(x - z) * 0.866 * s, (x + z) * 0.5 * s - y * s]

function boxes(dims) {
  const [nx, ny, nz] = dims, out = []
  for (let i = 0; i < nx; i++) for (let j = 0; j < ny; j++) for (let k = 0; k < nz; k++) {
    const w = 1 / nx, h = 1 / ny, d = 1 / nz
    out.push({ x: i * (w + gap), y: j * (h + gap), z: k * (d + gap), w, h, d })
  }
  return out.sort((a, b) => (a.x + a.z) - (b.x + b.z) || a.y - b.y)
}
function corners(b) {
  const { x, y, z, w, h, d } = b, c = []
  for (const dx of [0, w]) for (const dy of [0, h]) for (const dz of [0, d]) c.push(P(x + dx, y + dy, z + dz))
  return c
}
function bbox(bs) {
  const c = bs.flatMap(corners)
  return { x0: Math.min(...c.map(p => p[0])), x1: Math.max(...c.map(p => p[0])), y0: Math.min(...c.map(p => p[1])), y1: Math.max(...c.map(p => p[1])) }
}
const poly = (pts, ox, oy) => pts.map(([u, v]) => `${u + ox},${v + oy}`).join(' ')
function faces(b, ox, oy) {
  const { x, y, z, w, h, d } = b
  return {
    top: poly([P(x, y + h, z), P(x + w, y + h, z), P(x + w, y + h, z + d), P(x, y + h, z + d)], ox, oy),
    right: poly([P(x + w, y, z), P(x + w, y + h, z), P(x + w, y + h, z + d), P(x + w, y, z + d)], ox, oy),
    left: poly([P(x, y, z + d), P(x + w, y, z + d), P(x + w, y + h, z + d), P(x, y + h, z + d)], ox, oy),
  }
}

const COLX = [72, 207, 342, 477]
const LABEL_GAP = 16
function row(stages, baseY) {
  // align every stage's bbox bottom to baseY and centre it on its column
  const placed = stages.map(st => {
    const bs = boxes(st.dims), bb = bbox(bs)
    const ox = COLX[st.col] - (bb.x0 + bb.x1) / 2, oy = baseY - bb.y1
    return { ...st, bs, ox, oy, left: bb.x0 + ox, right: bb.x1 + ox, top: bb.y0 + oy, bottom: baseY }
  })
  const midY = baseY - Math.max(...placed.map(p => p.bottom - p.top)) / 2
  const arrows = placed.slice(1).map((p, i) => ({ x1: placed[i].right + 10, x2: p.left - 10, y: midY }))
  return { placed, arrows }
}
const oct = row([
  { dims: [1, 1, 1], col: 0, lab: 'root', sub: '' },
  { dims: [2, 2, 2], col: 3, lab: 'level 1', sub: '8 cubes at once' },
], 120)
const kd = row([
  { dims: [1, 1, 1], col: 0, lab: 'root', sub: '1 × 1 × 1' },
  { dims: [2, 1, 1], col: 1, lab: 'level 1', sub: 'split x → slabs' },
  { dims: [2, 2, 1], col: 2, lab: 'level 2', sub: 'split y → columns' },
  { dims: [2, 2, 2], col: 3, lab: 'level 3', sub: 'split z → cubes' },
], 292)
const rows = [
  { key: 'oct', title: 'Octree', color: 'var(--c-op-down)', titleColor: 'var(--c-ink)', y: 14, ...oct, arrowLabel: 'one split · 8 children' },
  { key: 'kd', title: 'KDTree3D', color: 'var(--c-kd-leaf)', titleColor: 'var(--c-kd-leaf)', y: 186, ...kd, arrowLabel: '' },
]
</script>

<template>
  <svg viewBox="0 0 545 340" width="100%">
    <defs>
      <marker id="kds-a" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-muted)" />
      </marker>
    </defs>
    <g v-for="r in rows" :key="r.key">
      <text x="0" :y="r.y" style="font-size:12px; font-weight:700" :fill="r.titleColor">{{ r.title }}</text>
      <g v-for="(st, i) in r.placed" :key="i">
        <g v-for="(b, bi) in st.bs" :key="bi">
          <polygon :points="faces(b, st.ox, st.oy).left" :fill="`color-mix(in srgb, ${r.color} 28%, white)`" :stroke="r.color" stroke-width="1" />
          <polygon :points="faces(b, st.ox, st.oy).right" :fill="`color-mix(in srgb, ${r.color} 16%, white)`" :stroke="r.color" stroke-width="1" />
          <polygon :points="faces(b, st.ox, st.oy).top" :fill="`color-mix(in srgb, ${r.color} 7%, white)`" :stroke="r.color" stroke-width="1" />
        </g>
        <text :x="COLX[st.col]" :y="st.bottom + LABEL_GAP" text-anchor="middle" style="font-size:10.5px; font-weight:600" fill="var(--c-ink)">{{ st.lab }}</text>
        <text v-if="st.sub" :x="COLX[st.col]" :y="st.bottom + LABEL_GAP + 13" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">{{ st.sub }}</text>
      </g>
      <g v-for="(a, i) in r.arrows" :key="'a' + i">
        <line :x1="a.x1" :y1="a.y" :x2="a.x2" :y2="a.y" stroke="var(--c-muted)" stroke-width="1.3" marker-end="url(#kds-a)" />
        <text v-if="r.arrowLabel" :x="(a.x1 + a.x2) / 2" :y="a.y - 7" text-anchor="middle" style="font-size:10px" fill="var(--c-muted)">{{ r.arrowLabel }}</text>
      </g>
    </g>
    <text :x="COLX[3]" :y="kd.placed[3].top - 8" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">= 1 octree level</text>
  </svg>
</template>
