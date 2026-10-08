<script setup>
import { computed, ref } from 'vue'
import { particles, quadtree } from '../lib/toytree.js'

const props = defineProps({
  dist: { type: String, default: 'cluster' },
  n: { type: Number, default: 160 },
  seed: { type: Number, default: 11 },
  threshold: { type: Number, default: 16 },
  maxLevel: { type: Number, default: 3 },
  size: { type: Number, default: 200 },
  barWidth: { type: Number, default: 560 },
  showN: { type: Boolean, default: false },
  showP: { type: Boolean, default: true },
  proportional: { type: Boolean, default: false }, // extra strip with true key-range proportions
  showArray: { type: Boolean, default: true },
  row: { type: Boolean, default: false },
  level: { type: Number, default: -1 }, // show refinement only down to this level (-1 = final tree)
  binary: { type: Boolean, default: false }, // binary tree: 1 key bit per level, each split halves the longest side
  aspect: { type: Number, default: 1 }, // binary mode: domain width / height
  accent: { type: String, default: 'var(--c-accent)' },
  scale: { type: String, default: 'edge' }, // 'edge' (width ∝ cell edge = √span), 'linear' (∝ span), 'equal'
})

const hover = ref(-1)
const ASP = computed(() => (props.binary ? props.aspect : 1))
const pts = computed(() => particles(props.dist, props.n, props.seed).map(([x, y]) => [x * ASP.value, y]))
function binaryTree(points, threshold, maxBin, cap) {
  const leaves = []
  const inBox = (p, x, y, w, h) => p[0] >= x && p[0] < x + w && p[1] >= y && p[1] < y + h
  const rec = (x, y, w, h, level, code) => {
    const n = points.reduce((c, p) => c + (inBox(p, x, y, w, h) ? 1 : 0), 0)
    if (level >= maxBin || n <= threshold || (cap >= 0 && level >= cap)) { leaves.push({ x, y, w, h, level, n, code }); return }
    if (w >= h) { rec(x, y, w / 2, h, level + 1, code * 2); rec(x + w / 2, y, w / 2, h, level + 1, code * 2 + 1) } // longest side: x
    else { rec(x, y, w, h / 2, level + 1, code * 2); rec(x, y + h / 2, w, h / 2, level + 1, code * 2 + 1) } // longest side: y
  }
  rec(0, 0, ASP.value, 1, 0, 0)
  return { leaves }
}
const fullTree = computed(() => props.binary
  ? binaryTree(pts.value, props.threshold, 2 * props.maxLevel, -1)
  : quadtree(pts.value, { threshold: props.threshold, maxLevel: props.maxLevel }))
// truncate the final tree at `level`: deeper leaves are replaced by their ancestor at that level
const tree = computed(() => {
  const cap = props.level
  if (cap < 0) return fullTree.value
  if (props.binary) return binaryTree(pts.value, props.threshold, 2 * props.maxLevel, cap)
  const out = [], seen = new Map()
  for (const l of fullTree.value.leaves) {
    if (l.level <= cap) { out.push(l); continue }
    const up = l.level - cap, code = Math.floor(l.code / 4 ** up), size = l.w * 2 ** up
    const key = cap + ':' + code
    if (!seen.has(key)) {
      const a = { x: Math.floor(l.x / size + 1e-9) * size, y: Math.floor(l.y / size + 1e-9) * size, w: size, h: size, level: cap, n: 0, code }
      seen.set(key, a); out.push(a)
    }
    seen.get(key).n += l.n
  }
  return { ...fullTree.value, leaves: out }
})
const total = computed(() => 4 ** props.maxLevel)

function morton(x, y) {
  let k = 0
  for (let b = 0; b < 16; b++) k |= ((x >> b) & 1) << (2 * b) | ((y >> b) & 1) << (2 * b + 1)
  return k
}
// particle keys at a finer resolution, expressed in units of the displayed key space
const FINE = 8
const FINE_B = 16
function binaryKey([px, py]) {
  let x = 0, y = 0, w = ASP.value, h = 1, code = 0
  for (let b = 0; b < FINE_B; b++) {
    if (w >= h) { w /= 2; const bit = px >= x + w ? 1 : 0; code = code * 2 + bit; if (bit) x += w }
    else { h /= 2; const bit = py >= y + h ? 1 : 0; code = code * 2 + bit; if (bit) y += h }
  }
  return (code + 0.5) / 2 ** (FINE_B - 2 * props.maxLevel)
}
const pkeys = computed(() => {
  if (props.binary) return pts.value.map(binaryKey)
  const m = 1 << FINE, scale = 4 ** (FINE - props.maxLevel)
  return pts.value.map(([x, y]) => (morton(Math.floor(x * m), Math.floor(y * m)) + 0.5) / scale)
})

const segs = computed(() => tree.value.leaves.map(l => {
  const span = props.binary ? 2 ** (2 * props.maxLevel - l.level) : 4 ** (props.maxLevel - l.level)
  const k0 = l.code * span, k1 = (l.code + 1) * span
  return { ...l, k0, k1, keys: pkeys.value.filter(k => k >= k0 && k < k1) }
}))
const K = computed(() => [...segs.value.map(s => s.k0), total.value])
const weight = l => (props.scale === 'equal' ? 1 : props.scale === 'linear' ? l.k1 - l.k0 : Math.sqrt(l.k1 - l.k0))
const xs = computed(() => {
  const w = segs.value.map(weight), sum = w.reduce((a, b) => a + b, 0)
  const out = [0]
  for (const v of w) out.push(out[out.length - 1] + (v / sum) * props.barWidth)
  return out
})
const cx = i => xs.value[i]
const cwOf = i => xs.value[i + 1] - xs.value[i]
const px = k => (k / total.value) * props.barWidth // proportional position

const levelColor = lv => `color-mix(in srgb, ${props.accent} ${5 + 8 * (props.binary ? lv / 2 : lv)}%, var(--c-surface))`
const inLeaf = (p, l) => p[0] >= l.x && p[0] < l.x + l.w && p[1] >= l.y && p[1] < l.y + l.h

// vertical layout
const BOX_Y = 18, BOX_H = 40
const LAB_Y = BOX_Y + BOX_H + 14
const N_Y = LAB_Y + 16
const PROP_Y = computed(() => (props.showN ? N_Y : LAB_Y) + 22)
const H = computed(() => (props.proportional ? PROP_Y.value + 30 : (props.showN ? N_Y : LAB_Y) + 8))
// deterministic small vertical jitter for particle ticks
const jit = (i) => ((i * 37) % 5) * 5
</script>

<template>
  <div class="ks" :class="{ row }">
    <svg :width="size * ASP" :height="size" :viewBox="`-1 -1 ${size * ASP + 2} ${size + 2}`">
      <rect v-for="(l, i) in segs" :key="i" :x="l.x * size" :y="l.y * size" :width="l.w * size" :height="l.h * size"
        :fill="hover === i ? 'var(--c-hl)' : levelColor(l.level)" :stroke="accent" stroke-width="0.8"
        @mouseenter="hover = i" @mouseleave="hover = -1" />
      <text v-for="(l, i) in segs" :key="'i' + i" :x="(l.x + l.w / 2) * size" :y="(l.y + l.h / 2) * size + 4"
        text-anchor="middle" style="font-size:11px; font-weight:700" fill="var(--c-accent)" fill-opacity="0.55" pointer-events="none">{{ i }}</text>
      <circle v-for="(p, i) in pts" :key="'p' + i" :cx="p[0] * size" :cy="p[1] * size"
        :r="hover >= 0 && inLeaf(p, segs[hover]) ? 2.4 : 1.5"
        :fill="hover >= 0 && !inLeaf(p, segs[hover]) ? 'var(--c-line-strong)' : 'var(--c-particle)'" pointer-events="none" />
    </svg>

    <div class="right">
      <svg :width="barWidth + 40" :height="H" :viewBox="`-26 0 ${barWidth + 40} ${H}`">
        <text x="0" y="11" style="font-size:11px" fill="var(--c-muted)">leaf intervals of K in SFC order (width ∝ cell edge) · <tspan fill="var(--c-particle)">|</tspan> = particle key from P</text>

        <!-- K intervals, equal width -->
        <g v-for="(l, i) in segs" :key="i" @mouseenter="hover = i" @mouseleave="hover = -1">
          <rect :x="cx(i)" :y="BOX_Y" :width="cwOf(i)" :height="BOX_H"
            :fill="hover === i ? 'var(--c-hl)' : levelColor(l.level)" :stroke="accent" stroke-width="1" />
          <text :x="cx(i) + cwOf(i) / 2" :y="BOX_Y + 11" text-anchor="middle" style="font-size:9px" fill="var(--c-accent)">{{ i }}</text>
          <!-- P keys placed inside their interval -->
          <g v-if="showP">
            <line v-for="(k, j) in l.keys" :key="j"
              :x1="cx(i) + 2 + ((k - l.k0) / (l.k1 - l.k0)) * (cwOf(i) - 4)" :x2="cx(i) + 2 + ((k - l.k0) / (l.k1 - l.k0)) * (cwOf(i) - 4)"
              :y1="BOX_Y + 16 + jit(j)" :y2="BOX_Y + 22 + jit(j)"
              stroke="var(--c-particle)" stroke-width="1.1" />
          </g>
        </g>
        <text x="-6" :y="BOX_Y + BOX_H / 2 + 4" text-anchor="end" style="font-size:12px; font-weight:700" fill="var(--c-ink)">K</text>

        <!-- boundary key values -->
        <g v-for="(k, i) in K" :key="'b' + i">
          <line :x1="cx(i)" :x2="cx(i)" :y1="BOX_Y + BOX_H" :y2="BOX_Y + BOX_H + 4" stroke="var(--c-ink)" />
          <text :x="cx(i)" :y="LAB_Y" text-anchor="middle" class="mono"
            :style="{ fontSize: '10px', fontWeight: hover >= 0 && (i === hover || i === hover + 1) ? 700 : 400 }"
            :fill="hover >= 0 && (i === hover || i === hover + 1) ? 'var(--c-ink)' : 'var(--c-muted)'">{{ k }}</text>
        </g>

        <g v-if="showN">
          <text v-for="(l, i) in segs" :key="'n' + i" :x="cx(i) + cwOf(i) / 2" :y="N_Y" text-anchor="middle"
            style="font-size:11px; font-weight:600" fill="var(--c-ink)">{{ l.n }}</text>
          <text x="-6" :y="N_Y" text-anchor="end" style="font-size:12px; font-weight:700" fill="var(--c-ink)">N</text>
        </g>

        <!-- true proportions of key space -->
        <g v-if="proportional">
          <line v-for="(k, i) in K" :key="'c' + i" :x1="cx(i)" :y1="PROP_Y - 14" :x2="px(k)" :y2="PROP_Y"
            stroke="var(--c-line-strong)" stroke-width="0.7" />
          <rect v-for="(l, i) in segs" :key="'q' + i" :x="px(l.k0)" :y="PROP_Y" :width="px(l.k1) - px(l.k0)" height="10"
            :fill="hover === i ? 'var(--c-hl)' : levelColor(l.level)" :stroke="accent" stroke-width="0.8"
            @mouseenter="hover = i" @mouseleave="hover = -1" />
          <text x="0" :y="PROP_Y + 24" style="font-size:10px" fill="var(--c-muted)">same intervals drawn to scale: key space 0 … {{ total }}</text>
        </g>
      </svg>

      <div v-if="showArray" class="karr mono">
        <span class="lab">K =</span>
        <span v-for="(k, i) in K" :key="i" class="chip"
          :class="{ on: hover >= 0 && (i === hover || i === hover + 1) }">{{ k }}</span>
      </div>
      <div class="info">
        <template v-if="hover >= 0">
          leaf {{ hover }} = [K[{{ hover }}], K[{{ hover + 1 }}]) = [{{ segs[hover].k0 }}, {{ segs[hover].k1 }}) ·
          {{ segs[hover].k1 - segs[hover].k0 }} keys · level {{ segs[hover].level }} · N = {{ segs[hover].n }}
        </template>
        <template v-else><b>{{ level === 0 ? 'root' : level > 0 ? `after ${level} split${level > 1 ? 's' : ''}` : 'final tree' }}</b> · {{ segs.length }} leaves → K has {{ segs.length + 1 }} entries · hover a leaf</template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.ks { display: flex; flex-direction: column; align-items: center; gap: 8px; }
.ks.row { flex-direction: row; gap: 20px; align-items: center; }
.right { display: flex; flex-direction: column; gap: 4px; }
.karr { display: flex; flex-wrap: wrap; gap: 2px; align-items: center; font-size: 0.62rem; margin-left: 26px; }
.karr .lab { font-weight: 700; margin-right: 4px; }
.chip { border: 1px solid var(--c-line-strong); border-radius: 3px; padding: 0 3px; background: var(--c-surface); min-width: 18px; text-align: center; }
.chip.on { background: var(--c-hl); border-color: var(--c-ink); font-weight: 700; }
.info { font-size: 0.66rem; color: var(--c-muted); margin-left: 26px; min-height: 1.2em; }
</style>
