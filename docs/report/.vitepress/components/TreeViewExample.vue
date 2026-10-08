<script setup>
// Worked example of TreeView::build (tree_view.cu), executed in JS on a toy K.
// LevelBits = 2 (4 children) for drawability; the real code uses 3 (octree) and 1 (KDTree3D).
import { computed } from 'vue'

const props = defineProps({ step: { type: Number, default: 0 }, steps: { type: Number, default: 5 } })

const B = 2, C = 1 << B, MAXKEY = 64, MAXL = 3
const K = [0, 4, 8, 12, 16, 32, 36, 40, 44, 48, 64]
const range = l => MAXKEY >> (B * l)
const nodeStart = (key, l) => Math.floor(key / range(l)) * range(l)
const levelOf = r => Math.round(Math.log(MAXKEY / r) / Math.log(C))

// ---- Stage 1: classify leaves and boundaries
const L = K.length - 1
const leaves = K.slice(0, -1).map((s, i) => ({ i, start: s, end: K[i + 1], level: levelOf(K[i + 1] - s) }))
function lcaLevel(a, b) {
  let r = 0
  for (let l = 1; l <= MAXL; l++) { if (nodeStart(a, l) !== nodeStart(b, l)) break; r = l }
  return r
}
const boundaries = K.slice(1, -1).map((right, j) => {
  const left = K[j]
  const lca = lcaLevel(left, right)
  const parentStart = nodeStart(right, lca)
  const slot = (right - parentStart) / range(lca + 1)
  return { j, key: right, lca, parentStart, slot, canonical: slot === 1 }
})
const numInternal = (L - 1) / (C - 1)
const numNodes = L + numInternal

// ---- Stage 2: level metadata (backward recurrence)
const leavesPerLevel = Array(MAXL + 1).fill(0)
leaves.forEach(l => leavesPerLevel[l.level]++)
const maxLevel = Math.max(...leaves.map(l => l.level))
const internalPer = Array(MAXL + 1).fill(0), nodesPer = Array(MAXL + 1).fill(0)
nodesPer[maxLevel] = leavesPerLevel[maxLevel]
for (let l = maxLevel - 1; l >= 0; l--) { internalPer[l] = nodesPer[l + 1] / C; nodesPer[l] = leavesPerLevel[l] + internalPer[l] }
const levelOffset = [0], levelOffsetInternal = [0]
for (let l = 0; l <= maxLevel; l++) { levelOffset.push(levelOffset[l] + nodesPer[l]); levelOffsetInternal.push(levelOffsetInternal[l] + internalPer[l]) }

// ---- Stage 3: compact flagged candidates (boundary order)
const compacted = boundaries.filter(b => b.canonical).map(b => ({ level: b.lca, start: b.parentStart }))
// ---- Stage 4: stable sort by level
const byLevel = [...compacted].sort((a, b) => a.level - b.level)
// ---- Stage 5: child-centric layout key = (1 << B*level) | reversed child path
function reversedPath(start, level) {
  let r = 0
  for (let d = level; d > 0; d--) {
    const ps = nodeStart(start, d - 1)
    r = r * C + (((start - ps) / range(d)) % C)
  }
  return r
}
const layout = byLevel.map((n, sfcPos) => ({ ...n, sfcPos, key: (1 << (B * n.level)) | reversedPath(n.start, n.level) }))
  .sort((a, b) => a.key - b.key)
  .map((n, layoutIdx) => ({ ...n, m: layoutIdx - levelOffsetInternal[n.level] }))
const mOf = (level, start) => layout.find(n => n.level === level && n.start === start).m

// ---- Stages 6 + 7: final node index = levelOffset[l] + childSlot * M[l-1] + m(parent)
function finalIndex(level, start) {
  if (level === 0) return 0
  const ps = nodeStart(start, level - 1)
  const slot = (start - ps) / range(level)
  return levelOffset[level] + slot * internalPer[level - 1] + mOf(level - 1, ps)
}
const nodes = [
  ...layout.map(n => ({ level: n.level, start: n.start, end: n.start + range(n.level), leaf: false, m: n.m })),
  ...leaves.map(l => ({ level: l.level, start: l.start, end: l.end, leaf: true })),
].map(n => {
  const idx = finalIndex(n.level, n.start)
  const ps = n.level ? nodeStart(n.start, n.level - 1) : null
  return { ...n, idx, parentStart: ps, slot: n.level ? (n.start - ps) / range(n.level) : 0 }
}).sort((a, b) => a.idx - b.idx)

// ---- drawing
const W = 500, X0 = 26, ROW = 44, RH = 34
const X = k => X0 + (k / MAXKEY) * W
const rowY = l => 16 + l * ROW
const KY = rowY(maxLevel + 1) + 2
const STRIP_Y = KY + 58
const cellW = W / numNodes
// parents of the deepest level, for colouring child-centric interleaving
const parentsDeep = layout.filter(n => n.level === maxLevel - 1)
const groupColor = ['var(--c-accent)', 'var(--c-op-down)', 'var(--c-op-far)']
const colorOf = n => {
  if (n.level < 1) return 'var(--c-ink)'
  const pi = layout.findIndex(p => p.level === n.level - 1 && p.start === n.parentStart)
  return groupColor[pi % groupColor.length]
}
const s = computed(() => props.step)
const internalVisible = computed(() => s.value >= 1)
</script>

<template>
  <div class="tve">
    <svg :viewBox="`0 0 ${X0 + W + 16} ${STRIP_Y + 64}`" width="100%">
      <!-- level labels -->
      <text v-for="l in maxLevel + 1" :key="'lv' + l" x="4" :y="rowY(l - 1) + RH / 2 + 4" style="font-size:10px" fill="var(--c-muted)">L{{ l - 1 }}</text>

      <!-- icicle: every node spans its key range on its level row -->
      <g v-for="n in nodes" :key="'n' + n.idx">
        <rect v-if="n.leaf || internalVisible" :x="X(n.start) + 1" :y="rowY(n.level)" :width="X(n.end) - X(n.start) - 2" :height="RH" rx="4"
          :fill="n.leaf ? 'color-mix(in srgb, var(--c-accent) 18%, var(--c-surface))' : 'var(--c-surface)'"
          :stroke="n.leaf ? 'var(--c-accent)' : 'var(--c-ink)'" :stroke-dasharray="n.leaf ? '' : (s >= 3 ? '' : '4 3')" stroke-width="1.3" />
        <text v-if="(n.leaf || internalVisible) && s < 4" :x="(X(n.start) + X(n.end)) / 2" :y="rowY(n.level) + RH / 2 + 4" text-anchor="middle"
          :style="{ fontSize: n.leaf && n.end - n.start <= 4 ? '8px' : '10px' }" :fill="n.leaf ? 'var(--c-accent)' : 'var(--c-ink)'">
          {{ n.leaf ? `[${n.start},${n.end})` : (s >= 3 ? `m=${n.m}` : 'internal') }}
        </text>
        <text v-if="s >= 4" :x="(X(n.start) + X(n.end)) / 2" :y="rowY(n.level) + RH / 2 + 5" text-anchor="middle"
          style="font-size:13px; font-weight:700" :fill="colorOf(n)">{{ n.idx }}</text>
      </g>
      <!-- parent-child edges once the view exists -->
      <g v-if="s >= 4">
        <line v-for="n in nodes.filter(n => n.level > 0)" :key="'e' + n.idx"
          :x1="X(n.parentStart + range(n.level - 1) / 2)" :y1="rowY(n.level - 1) + RH"
          :x2="(X(n.start) + X(n.end)) / 2" :y2="rowY(n.level)" stroke="var(--c-line-strong)" stroke-width="0.8" />
      </g>

      <!-- K bar -->
      <text x="4" :y="KY + 15" style="font-size:11px; font-weight:700" fill="var(--c-ink)">K</text>
      <rect v-for="l in leaves" :key="'k' + l.i" :x="X(l.start)" :y="KY" :width="X(l.end) - X(l.start)" height="22"
        fill="color-mix(in srgb, var(--c-accent) 10%, var(--c-surface))" stroke="var(--c-accent)" />
      <text v-for="(k, i) in K" :key="'kl' + i" :x="X(k)" :y="KY + 36" text-anchor="middle" class="mono" style="font-size:9.5px" fill="var(--c-muted)">{{ k }}</text>

      <!-- Stage 1: boundaries, LCA and canonical flag -->
      <g v-if="s === 1 || s === 2">
        <g v-for="b in boundaries" :key="'b' + b.j">
          <line v-if="b.canonical" :x1="X(b.key)" :y1="KY" :x2="X(b.key)" :y2="rowY(b.lca) + RH"
            stroke="var(--c-op-far)" stroke-width="1.6" stroke-dasharray="3 2" />
          <circle :cx="X(b.key)" :cy="KY + 11" r="7" :fill="b.canonical ? 'var(--c-op-far)' : 'var(--c-surface)'"
            :stroke="b.canonical ? 'var(--c-op-far)' : 'var(--c-line-strong)'" />
          <text :x="X(b.key)" :y="KY + 14.5" text-anchor="middle" style="font-size:9px; font-weight:700"
            :fill="b.canonical ? 'white' : 'var(--c-muted)'">{{ b.slot }}</text>
        </g>
      </g>

      <!-- Stages 6+7: final flat node array -->
      <g v-if="s >= 4">
        <text x="4" :y="STRIP_Y + 15" style="font-size:9.5px; font-weight:700" fill="var(--c-ink)">view</text>
        <g v-for="n in nodes" :key="'s' + n.idx">
          <rect :x="X0 + n.idx * cellW + 1" :y="STRIP_Y" :width="cellW - 2" height="22" rx="3"
            :fill="n.leaf ? 'color-mix(in srgb, var(--c-accent) 14%, var(--c-surface))' : 'var(--c-surface)'"
            :stroke="colorOf(n)" stroke-width="1.5" />
          <text :x="X0 + (n.idx + 0.5) * cellW" :y="STRIP_Y + 15" text-anchor="middle" style="font-size:10px; font-weight:700" :fill="colorOf(n)">{{ n.idx }}</text>
          <text :x="X0 + (n.idx + 0.5) * cellW" :y="STRIP_Y + 34" text-anchor="middle" class="mono" style="font-size:7.5px" fill="var(--c-muted)">{{ n.start }}</text>
        </g>
        <g v-for="l in maxLevel + 1" :key="'br' + l">
          <path :d="`M ${X0 + levelOffset[l - 1] * cellW + 2} ${STRIP_Y + 42} v 5 H ${X0 + levelOffset[l] * cellW - 2} v -5`" fill="none" stroke="var(--c-muted)" />
          <text :x="X0 + ((levelOffset[l - 1] + levelOffset[l]) / 2) * cellW" :y="STRIP_Y + 58" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">level {{ l - 1 }}</text>
        </g>
      </g>
    </svg>

    <div class="panel">
      <template v-if="s === 0">
        <div class="stage">Input: Cornerstone K</div>
        <div class="kv mono">
          <span v-for="(k, i) in K" :key="i" class="chip">{{ k }}</span>
        </div>
        <p><b>L = {{ L }}</b> leaves. Every internal node has 2<sup>b</sup> = {{ C }} children ⇒</p>
        <div class="eq mono">#internal = (L − 1) / (2<sup>b</sup> − 1) = {{ numInternal }}</div>
        <p class="muted">sizes are known analytically, before building anything.</p>
      </template>

      <template v-else-if="s === 1">
        <div class="stage">Stage 1 · classify (1 thread / leaf)</div>
        <div class="eq mono">level = clz(K[i+1] − K[i]) / b</div>
        <p>For each boundary: LCA of the two leaf starts, and the child slot of the right side.</p>
        <p><span class="dot g">1</span> slot = 1 ⇒ the unique <b>child 0 | child 1</b> boundary of an internal node → flag it.</p>
        <p class="muted"><span class="dot">2</span><span class="dot">3</span> other slots: not flagged. Exactly {{ numInternal }} flags.</p>
      </template>

      <template v-else-if="s === 2">
        <div class="stage">Stage 2 · level metadata (1 thread)</div>
        <table class="metrics">
          <thead><tr><th>level</th><th>leaves</th><th>internal</th><th>nodes</th><th>offset</th></tr></thead>
          <tbody>
            <tr v-for="l in maxLevel + 1" :key="l"><td>{{ l - 1 }}</td><td>{{ leavesPerLevel[l - 1] }}</td><td>{{ internalPer[l - 1] }}</td><td>{{ nodesPer[l - 1] }}</td><td>{{ levelOffset[l - 1] }}</td></tr>
          </tbody>
        </table>
        <div class="eq mono" style="font-size: 0.66rem">internal[l] = nodes[l+1] / {{ C }}<br />nodes[l] = leaves[l] + internal[l]</div>
        <p class="muted">bottom-up from the deepest level · no host readback</p>
      </template>

      <template v-else-if="s === 3">
        <div class="stage">Stages 3–5 · order internal nodes</div>
        <div class="arr"><span class="lab">compact</span><span v-for="(n, i) in compacted" :key="i" class="chip">L{{ n.level }}:{{ n.start }}</span></div>
        <div class="arr"><span class="lab">sort by level</span><span v-for="(n, i) in byLevel" :key="i" class="chip">L{{ n.level }}:{{ n.start }}</span></div>
        <div class="arr"><span class="lab">layout key</span><span v-for="(n, i) in layout" :key="i" class="chip">{{ n.key }} → m={{ n.m }}</span></div>
        <p class="tiny muted">DeviceSelect::Flagged → DeviceRadixSort (8-bit level) → DeviceRadixSort on (1 ≪ b·level) | reversed child path</p>
        <p><b>m</b> = rank of an internal node within its level</p>
      </template>

      <template v-else>
        <div class="stage">Stages 6 + 7 · write every node directly</div>
        <div class="eq mono" style="font-size: 0.68rem">idx = levelOffset[l] + childSlot · M<sub>l−1</sub> + m<sub>parent</sub></div>
        <p>Children of one parent are <b>M apart</b>; all child-0s, then all child-1s, … (see the interleaved colours on level {{ maxLevel }}).</p>
        <div class="eq mono" style="font-size: 0.64rem">childIndex[p] = levelOffset[l+1] + m<sub>p</sub><br />child k = childIndex[p] + k · M<sub>l</sub></div>
        <p class="muted tiny">internal nodes (stage 6) and leaves (stage 7) run as independent kernels on different streams</p>
      </template>
      <div class="steps"><span v-for="i in steps" :key="i" :class="{ on: i - 1 === s }"></span></div>
    </div>
  </div>
</template>

<style scoped>
.tve { display: grid; grid-template-columns: 1.6fr 1fr; gap: 18px; align-items: start; }
.panel { font-size: 0.72rem; display: flex; flex-direction: column; gap: 6px; }
.panel p { margin: 0; line-height: 1.35; }
.stage { font-weight: 700; font-size: 0.8rem; color: var(--c-view); }
.eq { border: 1px solid var(--c-line); background: var(--c-surface); border-radius: 6px; padding: 5px 8px; font-size: 0.72rem; }
.kv, .arr { display: flex; flex-wrap: wrap; gap: 2px; align-items: center; font-size: 0.62rem; }
.arr { font-family: var(--vp-font-family-mono); }
.arr .lab { width: 78px; color: var(--c-muted); font-family: var(--vp-font-family-base); }
.chip { border: 1px solid var(--c-line-strong); border-radius: 3px; padding: 0 4px; background: var(--c-surface); }
.dot { display: inline-flex; width: 14px; height: 14px; border-radius: 99px; border: 1px solid var(--c-line-strong); align-items: center; justify-content: center; font-size: 0.55rem; margin-right: 3px; }
.dot.g { background: var(--c-op-far); border-color: var(--c-op-far); color: white; font-weight: 700; }
.steps { display: flex; gap: 4px; margin-top: 4px; }
.steps span { width: 18px; height: 4px; border-radius: 2px; background: var(--c-line); }
.steps span.on { background: var(--c-view); }
</style>
