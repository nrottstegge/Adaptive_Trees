<script setup>
// Exploded isometric 3x3x3 stencil: the leaf (centre, dark) and its 26 same-level neighbours.
const s = 19, step = 1.75 // cube edge in px-units, spacing between cube origins (in cube edges)
const P = (x, y, z) => [(x - z) * 0.866 * s, (x + z) * 0.5 * s - y * s]
const poly = pts => pts.map(p => p.join(',')).join(' ')
const cubes = []
for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) for (let k = 0; k < 3; k++)
  cubes.push({ x: i * step, y: j * step, z: k * step, centre: i === 1 && j === 1 && k === 1 })
// painter's order: far (small x+z, high y drawn later? -> draw low y first, then by depth)
cubes.sort((a, b) => (a.x + a.z) - (b.x + b.z) || a.y - b.y)
function faces(c) {
  const { x, y, z } = c, w = 1
  return {
    top: poly([P(x, y + w, z), P(x + w, y + w, z), P(x + w, y + w, z + w), P(x, y + w, z + w)]),
    right: poly([P(x + w, y, z), P(x + w, y + w, z), P(x + w, y + w, z + w), P(x + w, y, z + w)]),
    left: poly([P(x, y, z + w), P(x + w, y, z + w), P(x + w, y + w, z + w), P(x, y + w, z + w)]),
  }
}
// outer box around the whole stencil (slightly padded)
const pad = 0.22, L0 = -pad, L1 = 2 * step + 1 + pad
const B = (a, b, c) => P(a ? L1 : L0, b ? L1 : L0, c ? L1 : L0)
const seg = (p, q) => `M ${B(...p).join(' ')} L ${B(...q).join(' ')}`
const hidden = [[[0,0,0],[1,0,0]], [[0,0,0],[0,1,0]], [[0,0,0],[0,0,1]]].map(([p, q]) => seg(p, q))
const visible = [
  [[1,1,1],[0,1,1]], [[1,1,1],[1,0,1]], [[1,1,1],[1,1,0]],
  [[0,1,0],[1,1,0]], [[1,1,0],[1,0,0]], [[1,0,0],[1,0,1]], [[1,0,1],[0,0,1]], [[0,0,1],[0,1,1]], [[0,1,1],[0,1,0]],
].map(([p, q]) => seg(p, q))
const boxPts = [0,1].flatMap(a => [0,1].flatMap(b => [0,1].map(c => B(a, b, c))))
const all = boxPts.concat(cubes.flatMap(c => Object.values(faces(c)).flatMap(f => f.split(' ').map(q => q.split(',').map(Number)))))
const xs = all.map(p => p[0]), ys = all.map(p => p[1])
const vb = [Math.min(...xs) - 4, Math.min(...ys) - 4, Math.max(...xs) - Math.min(...xs) + 8, Math.max(...ys) - Math.min(...ys) + 8]
</script>

<template>
  <svg :viewBox="vb.join(' ')" width="190">
    <path v-for="(d, i) in hidden" :key="'h' + i" :d="d" stroke="var(--fzj-blue)" stroke-width="1.1" stroke-dasharray="3 2.5" fill="none" />
    <g v-for="(c, i) in cubes" :key="i" :style="{ opacity: c.centre ? 1 : 0.45 }">
      <polygon :points="faces(c).left" :fill="c.centre ? 'var(--c-ink)' : 'color-mix(in srgb, var(--c-accent) 34%, white)'" :stroke="c.centre ? 'var(--c-ink)' : 'var(--c-accent)'" stroke-width="0.9" />
      <polygon :points="faces(c).right" :fill="c.centre ? 'color-mix(in srgb, var(--c-ink) 80%, white)' : 'color-mix(in srgb, var(--c-accent) 20%, white)'" :stroke="c.centre ? 'var(--c-ink)' : 'var(--c-accent)'" stroke-width="0.9" />
      <polygon :points="faces(c).top" :fill="c.centre ? 'color-mix(in srgb, var(--c-ink) 60%, white)' : 'color-mix(in srgb, var(--c-accent) 9%, white)'" :stroke="c.centre ? 'var(--c-ink)' : 'var(--c-accent)'" stroke-width="0.9" />
    </g>
    <path v-for="(d, i) in visible" :key="'v' + i" :d="d" stroke="var(--fzj-blue)" stroke-width="1.6" fill="none" stroke-linejoin="round" />
  </svg>
</template>
