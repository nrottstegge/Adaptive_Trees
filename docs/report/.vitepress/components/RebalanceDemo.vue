<script setup>
import { computed, ref } from 'vue'
import { K0, P, MAXKEY, levelOf, countsFor, leafCountOps, exclusiveScan, materialise } from '../lib/octree22.js'

// One Cornerstone rebalance pass on the 22-leaf toy octree:
//   step 0: K + N   step 1: decisions   step 2: exclusive scan   step 3: scatter → new K   step 4: refresh N
const props = defineProps({ step: { type: Number, default: 0 } })
const threshold = ref(8)

const N = computed(() => countsFor(K0))
const ops = computed(() => leafCountOps(K0, N.value, threshold.value))
const offs = computed(() => exclusiveScan(ops.value))
const next = computed(() => materialise(K0, ops.value))
const N1 = computed(() => countsFor(next.value.K))
const s = computed(() => props.step)

// layout
const W = 800, X0 = 64
const cw = computed(() => (W - X0) / Math.max(K0.length - 1, next.value.K.length - 1))
const cellX = i => X0 + i * cw.value
const AX = k => X0 + (k / MAXKEY) * (W - X0)
const Y = { axis: 22, k: 64, n: 90, op: 116, off: 142, nk: 228, nn: 254 }
const shade = lv => `color-mix(in srgb, var(--c-accent) ${6 + 12 * lv}%, var(--c-surface))`
const opColor = o => (o === 0 ? 'var(--c-muted)' : o === 1 ? 'var(--c-ink)' : 'var(--c-bad)')
const kindColor = { keep: 'var(--c-line-strong)', child: 'var(--c-bad)', merge: 'var(--c-good)' }
const hover = ref(-1)
const hoverOut = ref(-1)
const linkedIn = computed(() => (hoverOut.value >= 0 ? next.value.origin[hoverOut.value].from : hover.value))
</script>

<template>
  <div class="rb">
    <div class="ctl">
      <label>LeafCount threshold <input type="range" min="2" max="14" v-model.number="threshold" /> <b class="mono">{{ threshold }}</b></label>
      <span>· {{ K0.length - 1 }} leaves, {{ P.length }} particles · key space [0, {{ MAXKEY }})</span>
    </div>
    <svg :viewBox="`0 0 ${W + 8} 280`" width="100%" style="min-width: 640px">
      <!-- proportional key axis with particle keys -->
      <text x="0" :y="Y.axis + 4" class="lab">P</text>
      <line :x1="X0" :x2="W" :y1="Y.axis" :y2="Y.axis" stroke="var(--c-line-strong)" />
      <line v-for="(k, i) in P" :key="'p' + i" :x1="AX(k + 0.5)" :x2="AX(k + 0.5)" :y1="Y.axis - 6" :y2="Y.axis + 6"
        :stroke="linkedIn >= 0 && k >= K0[linkedIn] && k < K0[linkedIn + 1] ? 'var(--c-bad)' : 'var(--c-particle)'" stroke-width="1.4" />
      <!-- connectors: proportional interval → array cell -->
      <path v-for="i in K0.length - 1" :key="'c' + i"
        :d="`M ${AX(K0[i - 1])} ${Y.axis + 8} L ${cellX(i - 1)} ${Y.k - 14}`" stroke="var(--c-line)" stroke-width="0.6" fill="none" />

      <!-- input arrays -->
      <text x="0" :y="Y.k + 4" class="lab">K</text>
      <text x="0" :y="Y.n + 4" class="lab">N</text>
      <g v-for="(k, i) in K0.slice(0, -1)" :key="'k' + i" @mouseenter="hover = i" @mouseleave="hover = -1">
        <rect :x="cellX(i) + 1" :y="Y.k - 12" :width="cw - 2" height="22" rx="3"
          :fill="linkedIn === i ? 'var(--c-hl)' : shade(levelOf(K0[i + 1] - k))" stroke="var(--c-accent)" stroke-width="0.8" />
        <text :x="cellX(i) + cw / 2" :y="Y.k + 3" class="v">{{ k }}</text>
        <text :x="cellX(i) + cw / 2" :y="Y.n + 4" class="v" :style="{ fontWeight: N[i] > threshold ? 700 : 400 }"
          :fill="N[i] > threshold ? 'var(--c-bad)' : 'var(--c-ink)'">{{ N[i] }}</text>
      </g>
      <text :x="cellX(K0.length - 1) + 4" :y="Y.k + 3" class="v" style="text-anchor: start" fill="var(--c-muted)">{{ MAXKEY }}</text>

      <g v-if="s >= 1">
        <text x="0" :y="Y.op + 4" class="lab">op</text>
        <g v-for="(o, i) in ops" :key="'o' + i">
          <rect :x="cellX(i) + 3" :y="Y.op - 10" :width="cw - 6" height="18" rx="9"
            :fill="o === 8 ? 'color-mix(in srgb, var(--c-bad) 15%, white)' : o === 0 ? 'var(--c-empty)' : 'white'" :stroke="opColor(o)" stroke-width="0.8" />
          <text :x="cellX(i) + cw / 2" :y="Y.op + 3" class="v" :fill="opColor(o)" style="font-weight:700">{{ o }}</text>
        </g>
      </g>
      <g v-if="s >= 2">
        <text x="0" :y="Y.off + 4" class="lab">offset</text>
        <text v-for="(o, i) in offs" :key="'f' + i" :x="cellX(i) + cw / 2" :y="Y.off + 4" class="v" fill="var(--c-update)" style="font-weight:700">{{ o }}</text>
        <text :x="cellX(offs.length - 1) + cw / 2" :y="Y.off + 18" class="v" fill="var(--c-muted)" style="font-size:8px">= #new leaves</text>
      </g>

      <!-- scatter -->
      <g v-if="s >= 3">
        <path v-for="(o, j) in next.origin" :key="'a' + j"
          :d="`M ${cellX(o.from) + cw / 2} ${Y.off + 8} C ${cellX(o.from) + cw / 2} ${Y.off + 40}, ${cellX(j) + cw / 2} ${Y.nk - 50}, ${cellX(j) + cw / 2} ${Y.nk - 14}`"
          :stroke="kindColor[o.kind]" :stroke-opacity="hoverOut < 0 || hoverOut === j ? 0.9 : 0.15" stroke-width="1" fill="none" />
        <text x="0" :y="Y.nk + 4" class="lab">K′</text>
        <g v-for="(k, j) in next.K.slice(0, -1)" :key="'n' + j" @mouseenter="hoverOut = j" @mouseleave="hoverOut = -1">
          <rect :x="cellX(j) + 1" :y="Y.nk - 12" :width="cw - 2" height="22" rx="3"
            :fill="hoverOut === j ? 'var(--c-hl)' : shade(levelOf(next.K[j + 1] - k))" :stroke="kindColor[next.origin[j].kind]" :stroke-width="next.origin[j].kind === 'keep' ? 0.8 : 1.8" />
          <text :x="cellX(j) + cw / 2" :y="Y.nk + 3" class="v">{{ k }}</text>
        </g>
        <text :x="cellX(next.K.length - 1) + 4" :y="Y.nk + 3" class="v" style="text-anchor: start" fill="var(--c-muted)">{{ MAXKEY }}</text>
      </g>
      <g v-if="s >= 4">
        <text x="0" :y="Y.nn + 4" class="lab">N′</text>
        <text v-for="(n, j) in N1" :key="'nn' + j" :x="cellX(j) + cw / 2" :y="Y.nn + 4" class="v"
          :fill="n > threshold ? 'var(--c-bad)' : 'var(--c-ink)'" :style="{ fontWeight: n > threshold ? 700 : 400 }">{{ n }}</text>
      </g>
    </svg>
    <div class="legend tiny">
      <template v-if="s === 0">Leaf <i>i</i> owns the key interval [K[i], K[i+1]). Shade = depth. <b style="color: var(--c-bad)">Red counts</b> exceed the threshold. Hover a leaf to highlight its particles.</template>
      <template v-else-if="s === 1">One thread per leaf: <b>8</b> = split into 8 children, <b>1</b> = keep (or lead a merge), <b>0</b> = boundary disappears because the 8 siblings together hold ≤ threshold particles.</template>
      <template v-else-if="s === 2">An exclusive prefix sum over the ops gives every input leaf its <b>output position</b>, and the last entry is the new leaf count ({{ offs[offs.length - 1] }}). No thread has to talk to another.</template>
      <template v-else-if="s === 3">Each thread writes its boundaries independently: <span style="color: var(--c-bad)">■ split children</span> · <span style="color: var(--c-good)">■ merged parent</span> · <span style="color: var(--c-muted)">■ kept</span>. Hover a new leaf to see where it came from.</template>
      <template v-else>Counts are refreshed for the new topology. If a leaf is still over the threshold, the next pass splits it again. The loop runs until nothing changes.</template>
    </div>
  </div>
</template>

<style scoped>
.rb { display: flex; flex-direction: column; gap: 4px; }
.lab { font-size: 11px; font-weight: 700; fill: var(--c-ink); }
.v { font-size: 9.5px; text-anchor: middle; font-family: var(--vp-font-family-mono); }
.legend { color: var(--c-muted); min-height: 2.4em; }
</style>
