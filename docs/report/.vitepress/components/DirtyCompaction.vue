<script setup>
import { computed, ref } from 'vue'
import { K0, levelOf, countsFor, leafCountOps, materialise } from '../lib/octree22.js'
// After one rebalance pass (22 → 29 leaves), which NF values must be recomputed?
// Unchanged intervals carry N/NF over (particles do not move during rebalancing);
// split children and merge leaders are new geometry → dirty. CUB DeviceSelect compacts the dirty list.
const mode = ref('within') // 'within' = inside one update, 'timestep' = particles moved
const ops = leafCountOps(K0, countsFor(K0), 8)
const out = materialise(K0, ops)
const leaves = out.K.slice(0, -1).map((k, j) => ({ k, lv: levelOf(out.K[j + 1] - k), kind: out.origin[j].kind }))
const dirty = computed(() => leaves.map(l => (mode.value === 'timestep' ? 1 : l.kind === 'keep' ? 0 : 1)))
const selected = computed(() => dirty.value.flatMap((d, j) => (d ? [j] : [])))
const L = leaves.length
const kindColor = { keep: 'var(--c-line-strong)', child: 'var(--c-bad)', merge: 'var(--c-good)' }
</script>

<template>
  <div class="dc">
    <div class="ctl">
      <button class="pill" :class="{ on: mode === 'within' }" @click="mode = 'within'">inside one update (particles fixed)</button>
      <button class="pill" :class="{ on: mode === 'timestep' }" @click="mode = 'timestep'">new time step (particles moved)</button>
    </div>
    <div class="arr"><span class="lab">leaf</span>
      <span v-for="(l, j) in leaves" :key="'l' + j" class="chip" :style="{ borderColor: kindColor[l.kind], borderWidth: l.kind === 'keep' ? '1px' : '2px' }">{{ l.k }}</span>
    </div>
    <div class="arr"><span class="lab">reuse N, NF</span>
      <span v-for="(l, j) in leaves" :key="'c' + j" class="chip" :class="{ copy: !dirty[j] }">{{ dirty[j] ? '·' : '✓' }}</span>
    </div>
    <div class="arr"><span class="lab">nfDirty</span>
      <span v-for="(d, j) in dirty" :key="'d' + j" class="chip" :class="{ hot: d }">{{ d }}</span>
    </div>
    <div class="arr"><span class="lab">selected</span>
      <span v-for="j in selected" :key="'s' + j" class="chip hot">{{ j }}</span>
    </div>
    <div class="stats">
      <div class="card"><div class="tiny muted">NF queries without caching</div><div class="big mono">54 × {{ L }} = {{ 54 * L }}</div></div>
      <div class="card"><div class="tiny muted">with dirty flags + compaction</div><div class="big mono" style="color: var(--fzj-blue)">54 × {{ selected.length }} = {{ 54 * selected.length }}</div></div>
      <div class="card"><div class="tiny muted">saved binary searches</div><div class="big mono" style="color: var(--c-good)">{{ 54 * (L - selected.length) }}</div></div>
    </div>
    <div class="tiny muted">
      <span style="color: var(--c-bad)">■</span> split children ·
      <span style="color: var(--c-good)">■</span> merge leader (new, larger cell that must be recomputed although its op is 1) ·
      <span style="color: var(--c-line-strong)">■</span> identical interval → N and NF copied from the old arrays.
      <template v-if="mode === 'timestep'"> After particles move, <b>every</b> count is stale: the first pass of a time step refreshes all leaves (and skips the selection).</template>
    </div>
  </div>
</template>

<style scoped>
.dc { display: flex; flex-direction: column; gap: 6px; }
.arr { flex-wrap: nowrap; }
.chip { min-width: 23px; padding: 0 1px; font-size: 0.6rem; }
.chip.copy { background: color-mix(in srgb, var(--c-good) 10%, white); color: var(--c-good); border-color: var(--c-good); }
.chip.hot { background: color-mix(in srgb, var(--c-bad) 12%, white); color: var(--c-bad); border-color: var(--c-bad); font-weight: 700; }
.stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin: 6px 0; }
.big { font-weight: 700; font-size: 1rem; }
</style>
