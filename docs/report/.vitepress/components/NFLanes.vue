<script setup>
import { computed } from 'vue'
// computeNFCooperative: an 8-thread tile evaluates the 27-cell stencil of one leaf.
// lane t handles cells t, t+8, t+16, t+24 (< 27); each cell = two lowerBound searches in P.
// Then a shfl_down tree reduction (4, 2, 1) and a broadcast from lane 0.
// steps: 0 = assignment, 1..4 = loop rounds, 5..7 = shfl_down 4/2/1, 8 = result
const props = defineProps({ step: { type: Number, default: 0 } })
const pop = [3, 0, 5, 2, 7, 1, 0, 4, 6, 1, 2, 0, 9, 11, 8, 3, 0, 2, 1, 4, 0, 6, 5, 2, 0, 3, 1] // populations of the 27 cells
const CENTER = 13
const laneColor = ['#1f6fd1', '#e8871e', '#15803d', '#b91c1c', '#7b3fbf', '#8b5a2b', '#0f766e', '#c026d3']
const lane = c => c % 8
const round = c => Math.floor(c / 8) // 0..3
const s = computed(() => props.step)
const loopDone = computed(() => Math.min(Math.max(s.value, 0), 4)) // rounds completed
const visited = c => round(c) < loopDone.value
const active = c => s.value >= 1 && s.value <= 4 && round(c) === s.value - 1

const partial = computed(() => {
  const acc = Array(8).fill(0)
  for (let c = 0; c < 27; c++) if (visited(c)) acc[lane(c)] += pop[c]
  // reduction
  const shifts = [4, 2, 1]
  for (let r = 0; r < Math.max(0, Math.min(3, s.value - 4)); r++) {
    const d = shifts[r], prev = [...acc]
    for (let t = 0; t < 8; t++) acc[t] = prev[t] + (t + d < 8 ? prev[t + d] : 0)
  }
  return acc
})
const S = pop.reduce((a, b) => a + b, 0)
const n = pop[CENTER]
const searches = computed(() => 2 * pop.filter((_, c) => visited(c)).length)
const shfl = computed(() => (s.value >= 5 && s.value <= 7 ? [4, 2, 1][s.value - 5] : 0))
// draw: three 3x3 slices (dz = -1, 0, +1)
const CS = 34
const cellPos = c => { const dx = c % 3, dy = Math.floor(c / 3) % 3, dz = Math.floor(c / 9); return { x: dz * (3 * CS + 22) + dx * CS, y: (2 - dy) * CS } }
</script>

<template>
  <div class="nfl">
    <div class="left">
      <svg :width="3 * (3 * CS + 22)" :height="3 * CS + 28">
        <g v-for="c in 27" :key="c">
          <rect :x="cellPos(c - 1).x" :y="cellPos(c - 1).y + 16" :width="CS - 3" :height="CS - 3" rx="4"
            :fill="visited(c - 1) || active(c - 1) ? `color-mix(in srgb, ${laneColor[lane(c - 1)]} ${active(c - 1) ? 45 : 18}%, white)` : 'var(--c-surface)'"
            :stroke="c - 1 === CENTER ? 'var(--c-ink)' : s >= 0 ? laneColor[lane(c - 1)] : 'var(--c-line)'" :stroke-width="c - 1 === CENTER ? 2.6 : 1" />
          <text :x="cellPos(c - 1).x + CS / 2 - 1.5" :y="cellPos(c - 1).y + 16 + 13" text-anchor="middle" style="font-size:8px" fill="var(--c-muted)">#{{ c - 1 }}</text>
          <text :x="cellPos(c - 1).x + CS / 2 - 1.5" :y="cellPos(c - 1).y + 16 + 26" text-anchor="middle" style="font-size:11px; font-weight:700" fill="var(--c-ink)">{{ pop[c - 1] }}</text>
        </g>
        <text v-for="z in 3" :key="'z' + z" :x="(z - 1) * (3 * CS + 22) + 1.5 * CS" y="10" text-anchor="middle" style="font-size:10px" fill="var(--c-muted)">dz = {{ z - 2 }}</text>
      </svg>
      <div class="tiny muted">numbers = particles in each same-level geometric cell · <b>#13</b> = the leaf itself</div>
    </div>
    <div class="right">
      <table class="lanes">
        <thead><tr><th>lane</th><th>cells</th><th>partial sum</th></tr></thead>
        <tbody>
          <tr v-for="t in 8" :key="t" :class="{ dim: s >= 5 && t - 1 >= Math.max(1, 8 >> (s - 4)) }">
            <td><span class="sw" :style="{ background: laneColor[t - 1] }"></span> {{ t - 1 }}</td>
            <td class="mono">{{ [0, 8, 16, 24].map(o => o + t - 1).filter(c => c < 27).join(', ') }}</td>
            <td class="mono"><b>{{ partial[t - 1] }}</b><span v-if="shfl && t - 1 + shfl < 8 && t - 1 < shfl" class="muted"> ← +lane {{ t - 1 + shfl }}</span></td>
          </tr>
        </tbody>
      </table>
      <div class="status">
        <template v-if="s === 0">8 threads cooperate on <b>one</b> leaf. Cell <i>c</i> goes to lane <i>c</i> mod 8.</template>
        <template v-else-if="s <= 4">Loop round {{ s }}: each lane counts one cell with two binary searches in <span class="mono">P</span>. Searches so far: <b>{{ searches }}</b> / 54.</template>
        <template v-else-if="s <= 7"><span class="mono">tile.shfl_down(sum, {{ shfl }})</span>: lane t adds lane t+{{ shfl }}'s partial sum.</template>
        <template v-else>
          Lane 0 holds S = <b>{{ S }}</b>, broadcast with <span class="mono">tile.shfl(…, 0)</span>.<br />
          <span class="mono">NF = n<sub>13</sub> · S = {{ n }} · {{ S }} = <b>{{ n * S }}</b></span><br />
          The centre count n<sub>13</sub> = {{ n }} is written to <span class="mono">N</span> for free.
        </template>
      </div>
    </div>
  </div>
</template>

<style scoped>
.nfl { display: flex; flex-wrap: wrap; gap: 20px; align-items: flex-start; }
.right { flex: 1; min-width: 260px; display: flex; flex-direction: column; gap: 8px; }
table.lanes { font-size: 0.75rem; border-collapse: collapse; width: 100%; margin: 0; display: table; }
table.lanes th, table.lanes td { padding: 2px 8px; border: none; border-bottom: 1px solid var(--c-line); text-align: left; }
table.lanes tr { background: none !important; }
tr.dim { opacity: 0.35; }
.status { font-size: 0.8rem; min-height: 4.2em; border-left: 3px solid var(--c-oct-nf); padding: 4px 10px; background: color-mix(in srgb, var(--c-oct-nf) 6%, white); }
</style>
