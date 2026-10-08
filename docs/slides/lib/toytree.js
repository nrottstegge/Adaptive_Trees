// Toy 2D tree builder used only for illustrative slide graphics.
// Nothing here is a benchmark: all numbers shown from it are properties of the toy example.

export function rng(seed) {
  let s = seed >>> 0 || 1
  return () => {
    s ^= s << 13; s >>>= 0
    s ^= s >> 17
    s ^= s << 5; s >>>= 0
    return s / 4294967296
  }
}

function gauss(r) {
  const u = Math.max(r(), 1e-9), v = r()
  return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
}

const clamp = x => Math.min(0.999, Math.max(0.001, x))

export function particles(kind = 'cluster', n = 400, seed = 7, t = 0) {
  const r = rng(seed)
  const pts = []
  const blob = (cx, cy, sx, sy, m) => {
    for (let i = 0; i < m; i++) pts.push([clamp(cx + sx * gauss(r)), clamp(cy + sy * gauss(r))])
  }
  if (kind === 'uniform') {
    for (let i = 0; i < n; i++) pts.push([clamp(r()), clamp(r())])
  } else if (kind === 'cluster') {
    blob(0.62, 0.38, 0.06, 0.06, n * 0.55)
    blob(0.3, 0.68, 0.05, 0.04, n * 0.3)
    for (let i = 0; i < n * 0.15; i++) pts.push([clamp(r()), clamp(r())])
  } else if (kind === 'dense-core') {
    blob(0.56, 0.44, 0.07, 0.07, n)
  } else if (kind === 'sparse') {
    blob(0.2, 0.22, 0.015, 0.015, n * 0.35)
    blob(0.78, 0.7, 0.02, 0.012, n * 0.35)
    blob(0.72, 0.18, 0.012, 0.012, n * 0.15)
    for (let i = 0; i < n * 0.15; i++) pts.push([clamp(r()), clamp(r())])
  } else if (kind === 'filament') {
    for (let i = 0; i < n; i++) {
      const s = r()
      pts.push([clamp(0.08 + 0.84 * s), clamp(0.5 + 0.12 * Math.sin(5 * s) + 0.015 * gauss(r))])
    }
  } else if (kind === 'dynamic') {
    // two clusters that merge as t goes 0 -> 1
    const d = 0.28 * (1 - t)
    blob(0.5 - d, 0.5 - d * 0.6, 0.05, 0.05, n * 0.45)
    blob(0.5 + d, 0.5 + d * 0.6, 0.05, 0.05, n * 0.45)
    for (let i = 0; i < n * 0.1; i++) pts.push([clamp(r()), clamp(r())])
  }
  return pts
}

function countIn(pts, x, y, w, h) {
  let c = 0
  for (const p of pts) if (p[0] >= x && p[0] < x + w && p[1] >= y && p[1] < y + h) c++
  return c
}

// Quadtree (2D analogue of the octree). Children in Morton / Z order.
// criterion: 'count' (LeafCount) or 'nf' (NFCount analogue with 3x3 same-level stencil)
export function quadtree(pts, { criterion = 'count', threshold = 16, nfThreshold = 600, maxLevel = 6 } = {}) {
  const leaves = []
  let nodes = 0
  const rec = (x, y, s, level, code) => {
    nodes++
    const n = countIn(pts, x, y, s, s)
    let nf = 0
    if (criterion === 'nf') {
      const nb = countIn(pts, x - s, y - s, 3 * s, 3 * s) - n
      nf = n * (n + nb)
    }
    const split = level < maxLevel && (criterion === 'nf' ? nf > nfThreshold : n > threshold)
    if (!split) { leaves.push({ x, y, w: s, h: s, level, n, nf, code }); return }
    const h = s / 2
    rec(x, y, h, level + 1, code * 4 + 0)
    rec(x + h, y, h, level + 1, code * 4 + 1)
    rec(x, y + h, h, level + 1, code * 4 + 2)
    rec(x + h, y + h, h, level + 1, code * 4 + 3)
  }
  rec(0, 0, 1, 0, 0)
  return summarize(leaves, nodes, maxLevel)
}

// Binary (KD-style) tree: split the longest dimension at its midpoint.
export function kdtree(pts, { threshold = 16, maxLevel = 12 } = {}) {
  const leaves = []
  let nodes = 0
  const rec = (x, y, w, h, level) => {
    nodes++
    const n = countIn(pts, x, y, w, h)
    if (level >= maxLevel || n <= threshold) { leaves.push({ x, y, w, h, level, n }); return }
    if (w >= h) { rec(x, y, w / 2, h, level + 1); rec(x + w / 2, y, w / 2, h, level + 1) }
    else { rec(x, y, w, h / 2, level + 1); rec(x, y + h / 2, w, h / 2, level + 1) }
  }
  rec(0, 0, 1, 1, 0)
  return summarize(leaves, nodes, maxLevel)
}

export function dense(pts, level = 4) {
  const leaves = []
  const m = 1 << level, s = 1 / m
  for (let j = 0; j < m; j++) for (let i = 0; i < m; i++)
    leaves.push({ x: i * s, y: j * s, w: s, h: s, level, n: countIn(pts, i * s, j * s, s, s) })
  let nodes = 0
  for (let l = 0; l <= level; l++) nodes += 4 ** l
  return summarize(leaves, nodes, level)
}

// Sparse tree: only occupied cells exist (all levels down to `level`); empty space is not stored.
export function sparse(pts, level = 4) {
  let nodes = 0
  let leaves = []
  for (let l = 0; l <= level; l++) {
    const m = 1 << l, s = 1 / m, occ = new Map()
    for (const p of pts) {
      const i = Math.min(m - 1, Math.floor(p[0] * m)), j = Math.min(m - 1, Math.floor(p[1] * m))
      occ.set(j * m + i, (occ.get(j * m + i) || 0) + 1)
    }
    nodes += occ.size
    if (l === level) leaves = [...occ].map(([k, n]) => ({ x: (k % m) * s, y: Math.floor(k / m) * s, w: s, h: s, level: l, n }))
  }
  return summarize(leaves, nodes, level)
}

function summarize(leaves, nodes, maxLevel) {
  return {
    leaves,
    nodes,
    maxLevel,
    numLeaves: leaves.length,
    empty: leaves.filter(l => l.n === 0).length,
    depth: Math.max(...leaves.map(l => l.level)),
  }
}
