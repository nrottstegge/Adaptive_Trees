// The consistent toy octree used throughout the report.
// Key domain [0, 512) = three octree levels (3 bits per level), leaf widths 512 / 8^level.
// 22 leaves, 29 particles. With a LeafCount threshold of 8 one rebalance pass splits
// [0,8) and [64,128) and merges the eight leaves covering [128,192) → 29 leaves.

export const MAXKEY = 512
export const MAXLEVEL = 3
export const range = l => MAXKEY / 8 ** l
export const levelOf = w => Math.round(Math.log(MAXKEY / w) / Math.log(8))

export const K0 = [
  0, 8, 16, 24, 32, 40, 48, 56,
  64,
  128, 136, 144, 152, 160, 168, 176, 184,
  192, 256, 320, 384, 448,
  512,
]
export const N0 = [
  10, 2, 0, 1, 0, 0, 0, 0,
  9,
  1, 0, 2, 0, 1, 1, 0, 1,
  0, 0, 1, 0, 0,
]

// deterministic particle keys consistent with N0 (integer keys inside each leaf interval)
function makeParticles() {
  const keys = []
  let s = 12345
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff)
  N0.forEach((n, i) => {
    const a = K0[i], w = K0[i + 1] - a
    for (let j = 0; j < n; j++) keys.push(a + Math.floor(rnd() * w))
  })
  return keys.sort((x, y) => x - y)
}
export const P = makeParticles()

export const countIn = (keys, a, b) => keys.filter(k => k >= a && k < b).length
export const countsFor = (K, keys = P) => K.slice(0, -1).map((a, i) => countIn(keys, a, K[i + 1]))

// index of this leaf within a complete group of 8 same-level siblings, or -1
export function siblingIndex(K, i) {
  const w = K[i + 1] - K[i]
  const lv = levelOf(w)
  if (lv === 0) return -1
  const pr = range(lv - 1)
  const first = Math.floor(K[i] / pr) * pr
  const s = (K[i] - first) / w
  const f = i - s
  if (f < 0 || f + 8 >= K.length) return -1
  if (K[f] !== first || K[f + 8] !== first + pr) return -1
  for (let k = 0; k < 8; k++) if (K[f + k + 1] - K[f + k] !== w) return -1
  return s
}

// LeafCount decision: 0 (boundary vanishes in a merge), 1 (keep / merge leader), 8 (split)
export function leafCountOps(K, N, threshold) {
  return N.map((n, i) => {
    const s = siblingIndex(K, i)
    if (s >= 0) {
      const f = i - s
      const parent = N.slice(f, f + 8).reduce((a, b) => a + b, 0)
      if (parent <= threshold) return s === 0 ? 1 : 0
    }
    const lv = levelOf(K[i + 1] - K[i])
    if (n > threshold && lv < MAXLEVEL) return 8
    return 1
  })
}

export function exclusiveScan(values) {
  const out = [0]
  for (const v of values) out.push(out[out.length - 1] + v)
  return out
}

// returns { K: next boundaries, origin: [{ from, kind: 'keep'|'child'|'merge' }] }
export function materialise(K, ops) {
  const next = [], origin = []
  for (let i = 0; i < ops.length; i++) {
    const o = ops[i]
    if (o === 0) continue
    const merge = o === 1 && i + 1 < ops.length && ops[i + 1] === 0
    const w = (K[i + 1] - K[i]) / o
    for (let j = 0; j < o; j++) {
      next.push(K[i] + j * w)
      origin.push({ from: i, kind: o > 1 ? 'child' : merge ? 'merge' : 'keep' })
    }
  }
  next.push(K[K.length - 1])
  return { K: next, origin }
}
