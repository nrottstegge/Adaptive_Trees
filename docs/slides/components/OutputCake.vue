<script setup>
// Two "cakes": same category slices; outer ring = arrays (coloured by category), inner ring = producing step.
const cats = [
  { key: 'sort', t: 'sorting', c: 'var(--fzj-green)' },
  { key: 'count', t: 'counts', c: 'var(--fzj-yellow)' },
  { key: 'offset', t: 'offsets', c: 'var(--fzj-lightblue)' },
  { key: 'index', t: 'indexing', c: 'color-mix(in srgb, var(--fzj-blue) 55%, white)' },
]
// u = timed in the tree-update phase, b = timed in the view phase (as in the benchmark drivers)
const cakes = [
  {
    name: 'Cornerstone', tag: 'baseline', caption: 'computeSfcKeys · sort · updateOctreeGpu · buildOctreeGpu',
    out: {
      sort: [{ t: 'sorted keys P', k: 'u' }, { t: 'permutation', k: 'u' }],
      count: [{ t: 'N per leaf', k: 'u' }],
      offset: [{ t: 'leaf bounds K', k: 'u' }, { t: 'level offsets', k: 'b' }],
      index: [{ t: 'node keys', k: 'b' }, { t: 'child / parent links', k: 'b' }, { t: 'order maps', k: 'b' }],
      missing: { count: 'no NF, no per-node counts', offset: 'no per-node offsets', index: 'no particle → leaf' },
    },
  },
  {
    name: 'This work', tag: '', caption: 'adaptive update · TreeView',
    out: {
      sort: [{ t: 'sorted keys P', k: 'u' }, { t: 'permutation', k: 'u' }],
      count: [{ t: 'N per leaf', k: 'u' }, { t: 'NF per leaf', k: 'u' }, { t: 'particles per node', k: 'b' }],
      offset: [{ t: 'leaf bounds K', k: 'u' }, { t: 'level offsets', k: 'b' }, { t: 'particle begin per node', k: 'b' }],
      index: [{ t: 'node keys', k: 'b' }, { t: 'child / parent links', k: 'b' }, { t: 'split / depth flags', k: 'b' }, { t: 'particle → leaf', k: 'b' }],
    },
  },
]
// identical slice angles in both cakes: proportional to the larger array count per category
const units = cats.map(c => Math.max(...cakes.map(k => k.out[c.key].length), 1))
const total = units.reduce((a, b) => a + b, 0)
const GAP = 2.2 // degrees between categories
const span = cats.map((c, i) => ({ ...c, a0: -90 + (units.slice(0, i).reduce((a, b) => a + b, 0) / total) * 360, a1: -90 + (units.slice(0, i + 1).reduce((a, b) => a + b, 0) / total) * 360 }))

const R = { s0: 50, s1: 62, a0: 66, a1: 116, lab: 126 }
const rad = d => (d * Math.PI) / 180
const pt = (r, d) => [r * Math.cos(rad(d)), r * Math.sin(rad(d))]
function sector(r0, r1, d0, d1) {
  const [x0, y0] = pt(r1, d0), [x1, y1] = pt(r1, d1), [x2, y2] = pt(r0, d1), [x3, y3] = pt(r0, d0)
  const large = d1 - d0 > 180 ? 1 : 0
  return `M ${x0} ${y0} A ${r1} ${r1} 0 ${large} 1 ${x1} ${y1} L ${x2} ${y2} A ${r0} ${r0} 0 ${large} 0 ${x3} ${y3} Z`
}
// one outer segment per group (merged), inner ring keeps one cell per array, remainder hatched
function segments(cake) {
  const outer = [], inner = []
  span.forEach((c, ci) => {
    const items = cake.out[c.key]
    const d0 = c.a0 + GAP / 2, d1 = c.a1 - GAP / 2, w = (d1 - d0) / units[ci]
    const f1 = d0 + items.length * w
    if (items.length) outer.push({ cat: c, d0, d1: items.length < units[ci] ? f1 - 0.6 : d1, mid: (d0 + (items.length < units[ci] ? f1 : d1)) / 2, t: c.t })
    items.forEach((it, i) => inner.push({ k: it.k, d0: d0 + i * w + 0.5, d1: d0 + (i + 1) * w - 0.5 }))
    if (items.length < units[ci]) {
      const r0 = items.length ? f1 + 0.6 : d0
      outer.push({ cat: c, empty: true, d0: r0, d1, mid: (r0 + d1) / 2, t: (cake.out.missing && cake.out.missing[c.key]) || c.t + ': not computed' })
    }
  })
  return { outer, inner }
}
const stepColor = k => (k === 'u' ? 'var(--c-update)' : k === 'b' ? 'var(--c-view)' : 'var(--c-line)')
// label positions with simple collision avoidance per side (min vertical gap)
function placeLabels(segs) {
  const GAPY = 13
  const items = segs.map((sg, i) => {
    const [x, y] = pt(R.lab, sg.mid)
    return { i, side: Math.cos(rad(sg.mid)) >= 0 ? 1 : -1, x, y }
  })
  for (const side of [1, -1]) {
    const col = items.filter(it => it.side === side).sort((a, b) => a.y - b.y)
    for (let k = 1; k < col.length; k++) if (col[k].y - col[k - 1].y < GAPY) col[k].y = col[k - 1].y + GAPY
    // re-centre the column if it was pushed down
    const over = Math.max(0, col.length ? col[col.length - 1].y - 140 : 0)
    col.forEach(it => { it.y -= over })
  }
  return items.map(it => {
    const sg = segs[it.i]
    const [lx0, ly0] = pt(R.a1 + 1, sg.mid)
    const x = it.side * Math.max(Math.abs(it.x), 40)
    return { x: x + it.side * 4, y: it.y, anchor: it.side > 0 ? 'start' : 'end', line: `M ${lx0} ${ly0} L ${x} ${it.y}` }
  })
}
const layout = cakes.map((k, i) => { const { outer, inner } = segments(k); return { ...k, cx: 260 + i * 540, segs: outer, inner, labs: placeLabels(outer) } })
</script>

<template>
  <svg viewBox="0 0 1060 300" width="100%">
    <defs>
      <pattern id="cake-hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
        <rect width="6" height="6" fill="white" />
        <line x1="0" y1="0" x2="0" y2="6" stroke="var(--c-line-strong)" stroke-width="1.6" />
      </pattern>
    </defs>
    <g v-for="cake in layout" :key="cake.name" :style="{ transform: `translate(${cake.cx}px, 150px)` }">
      <path v-for="(c, j) in cake.inner" :key="'in' + j" :d="sector(R.s0, R.s1, c.d0, c.d1)" :fill="stepColor(c.k)" stroke="white" stroke-width="0.8" />
      <g v-for="(s, i) in cake.segs" :key="i">
        <!-- outer ring: arrays -->
        <path :d="sector(R.a0, R.a1, s.d0, s.d1)" :fill="s.empty ? 'url(#cake-hatch)' : s.k === 'in' ? 'white' : s.cat.c"
          :stroke="s.empty ? 'var(--c-line-strong)' : s.k === 'in' ? 'var(--c-line-strong)' : 'white'"
          :stroke-dasharray="s.empty || s.k === 'in' ? '3 2' : ''" stroke-width="1.2" />
        <!-- label -->
        <g v-if="!s.empty">
          <path :d="cake.labs[i].line" stroke="var(--c-line-strong)" stroke-width="0.8" />
          <text :x="cake.labs[i].x" :y="cake.labs[i].y + 3" :text-anchor="cake.labs[i].anchor" 
            style="font-size:13px; font-weight:700" fill="var(--c-ink)">{{ s.t }}<tspan v-if="s.n" style="font-size:8px; font-weight:400" fill="var(--c-muted)">&#160;{{ s.n }}</tspan></text>
        </g>
        <text v-else :x="cake.labs[i].x" :y="cake.labs[i].y + 3" :text-anchor="cake.labs[i].anchor"
          style="font-size:10.5px; font-style:italic" fill="var(--c-muted)">{{ s.t }}</text>
      </g>
      <text x="0" :y="cake.tag ? 0 : 5" text-anchor="middle" style="font-size:15px; font-weight:700"
        :fill="cake.name === 'This work' ? 'var(--fzj-blue)' : 'var(--c-muted)'">{{ cake.name }}</text>
      <text v-if="cake.tag" x="0" y="15" text-anchor="middle" style="font-size:10px" fill="var(--c-muted)">{{ cake.tag }}</text>
    </g>
  </svg>
  <div class="cake-captions">
    <div v-for="cake in layout" :key="cake.name" :style="{ left: (cake.cx / 1060) * 100 + '%' }" class="mono">{{ cake.caption }}</div>
  </div>
  <div class="cake-legend">

    <span><i style="background: var(--c-update)"></i>inner ring: tree-update phase</span>
    <span><i style="background: var(--c-view)"></i>view phase</span>
    <span><i class="hatch"></i>not computed</span>
  </div>
</template>

<style scoped>
.cake-captions { position: relative; height: 18px; margin-top: -6px; }
.cake-captions div { position: absolute; transform: translateX(-50%); white-space: nowrap; font-size: 0.68rem; color: var(--c-muted); }
.cake-legend { display: flex; flex-wrap: wrap; justify-content: center; gap: 6px 14px; font-size: 0.64rem; color: var(--c-muted); margin-top: 2px; }
.cake-legend i { display: inline-block; width: 11px; height: 11px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
.cake-legend i.hatch { background: repeating-linear-gradient(45deg, white 0 2px, var(--c-line-strong) 2px 3.5px); border: 1px dashed var(--c-line-strong); }
.cake-legend .sep { width: 1px; background: var(--c-line); }
</style>
