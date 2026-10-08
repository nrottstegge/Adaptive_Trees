// Renders the adaptive-octree band artwork (same as components/FzjTitleArt.vue) to public/header_octree.svg,
// for the fzj-title layout's `headerImage`.  Run: node scripts/make-header.mjs
import { writeFileSync } from 'node:fs'
import { particles, quadtree, rng } from '../lib/toytree.js'

const ROOTS = 4, cells = [], r = rng(5)
for (let k = 0; k < ROOTS; k++) {
  const pts = particles(['cluster', 'sparse', 'dynamic', 'cluster'][k], 520, 11 + k, 0.35)
  for (const l of quadtree(pts, { threshold: 10, maxLevel: 6 }).leaves) cells.push({ ...l, x: l.x + k })
}
const lerp = (a, b, t) => Math.round(a + (b - a) * t)
const c0 = [205, 217, 238], c1 = [78, 116, 178]
const fill = c => {
  const t = Math.min(1, Math.max(0, (c.x + c.w / 2) / ROOTS * 0.85 + c.level * 0.03 + (r() - 0.5) * 0.12))
  return `rgb(${lerp(c0[0], c1[0], t)},${lerp(c0[1], c1[1], t)},${lerp(c0[2], c1[2], t)})`
}
const S = 1000 // user units per root square
const rects = cells.map(c => `<rect x="${(c.x * S).toFixed(2)}" y="${(c.y * S).toFixed(2)}" width="${(c.w * S).toFixed(2)}" height="${(c.h * S).toFixed(2)}" fill="${fill(c)}" stroke="#fff" stroke-width="3.5"/>`).join('')
writeFileSync(new URL('../public/header_octree.svg', import.meta.url),
  `<svg xmlns="http://www.w3.org/2000/svg" width="${ROOTS * S}" height="${S}" viewBox="0 0 ${ROOTS * S} ${S}">${rects}</svg>\n`)
console.log('wrote public/header_octree.svg with', cells.length, 'cells')
