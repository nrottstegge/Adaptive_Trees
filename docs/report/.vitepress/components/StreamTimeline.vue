<script setup>
import { computed, ref } from 'vue'
// TreeView::build as a dependency graph on four streams (conceptual durations, not measured).
// Serial: everything on one stream in program order. Overlapped: each task starts once its stream
// is free and all events it waits on have fired.
const mode = ref('overlap')
const pWeight = ref(1) // particle-side work relative to leaf-side work
const hover = ref(null)
const lanes = [
  { id: 'part', name: 'particleStream' },
  { id: 'exec', name: 'exec (caller / graph)' },
  { id: 'meta', name: 'metadataStream' },
  { id: 'leaf', name: 'leafStream' },
]
const tasks = computed(() => [
  { id: 'scan', lane: 'part', t: 'leaf begin = scan(N)', d: 2 * pWeight.value, deps: [] },
  { id: 'cls', lane: 'exec', t: 'S1 classify', d: 2, deps: [] },
  { id: 'meta', lane: 'meta', t: 'S2 metadata', d: 1.5, deps: ['cls'] },
  { id: 'cmp', lane: 'exec', t: 'S3 compact', d: 1.5, deps: ['cls'] },
  { id: 'sort', lane: 'exec', t: 'S4 sort', d: 2, deps: ['cmp'] },
  { id: 'lay', lane: 'exec', t: 'S5 layout', d: 2, deps: ['sort'] },
  { id: 'mat', lane: 'exec', t: 'materialise', d: 1, deps: ['lay', 'meta'] },
  { id: 'int', lane: 'exec', t: 'S6 internals', d: 2, deps: ['mat'] },
  { id: 'lf', lane: 'leaf', t: 'S7 leaves', d: 2, deps: ['mat', 'meta', 'scan'] },
  { id: 'map', lane: 'part', t: 'particle → node', d: 3 * pWeight.value, deps: ['lf'] },
])
const sched = computed(() => {
  const end = {}, free = {}
  let tSerial = 0
  return tasks.value.map(tk => {
    let t0
    if (mode.value === 'serial') { t0 = tSerial; tSerial += tk.d }
    else t0 = Math.max(free[tk.lane] || 0, ...tk.deps.map(d => end[d]))
    end[tk.id] = t0 + tk.d
    free[tk.lane] = t0 + tk.d
    return { ...tk, t0, t1: t0 + tk.d, row: mode.value === 'serial' ? 'exec' : tk.lane }
  })
})
const total = computed(() => Math.max(...sched.value.map(s => s.t1)))
const serialTotal = computed(() => tasks.value.reduce((a, t) => a + t.d, 0))
const X0 = 150, W = 640, RH = 34
const xs = computed(() => W / Math.max(serialTotal.value, 1))
const rowY = id => 24 + lanes.findIndex(l => l.id === id) * (RH + 12)
const byId = computed(() => Object.fromEntries(sched.value.map(s => [s.id, s])))
// Fit a label into its box: full text, then first word, then a short form, shrinking down to 7px.
const shortForm = { 'materialise': 'mat.', 'S2 metadata': 'S2', 'S3 compact': 'S3', 'S4 sort': 'S4', 'S5 layout': 'S5', 'S6 internals': 'S6', 'S7 leaves': 'S7', 'S1 classify': 'S1' }
const CHAR_W = 0.58 // average glyph width relative to the font size
function fit(s) {
  const avail = s.d * xs.value - 6
  const forms = [s.t, s.t.split(' ')[0], shortForm[s.t] || s.t.slice(0, 3) + '.']
  for (const text of forms) {
    const size = Math.min(9.5, avail / (text.length * CHAR_W))
    if (size >= 7) return { text, size }
  }
  const last = forms[forms.length - 1] // very narrow box: smallest readable short form
  return { text: last, size: Math.max(6, avail / (last.length * CHAR_W)) }
}
const isDep = id => hover.value && byId.value[hover.value].deps.includes(id)
</script>

<template>
  <div>
    <div class="ctl">
      <button class="pill" :class="{ on: mode === 'serial' }" @click="mode = 'serial'">one stream (serial)</button>
      <button class="pill" :class="{ on: mode === 'overlap' }" @click="mode = 'overlap'">streams + events (overlapped)</button>
      <label>particle-side work × <input type="range" min="0.5" max="3" step="0.25" v-model.number="pWeight" /> <b>{{ pWeight }}</b></label>
      <span>makespan <b class="mono">{{ total.toFixed(1) }}</b> vs serial <b class="mono">{{ serialTotal.toFixed(1) }}</b> units</span>
    </div>
    <svg :viewBox="`0 0 ${X0 + W + 10} ${24 + 4 * (RH + 12)}`" width="100%" style="min-width: 640px">
      <g v-for="l in lanes" :key="l.id">
        <text x="0" :y="rowY(l.id) + RH / 2 + 4" class="mono" style="font-size:10.5px" fill="var(--c-ink)">{{ l.name }}</text>
        <line :x1="X0" :x2="X0 + W" :y1="rowY(l.id) + RH / 2" :y2="rowY(l.id) + RH / 2" stroke="var(--c-line)" stroke-dasharray="2 4" />
      </g>
      <!-- dependency arrows for hovered task -->
      <g v-if="hover && mode === 'overlap'">
        <path v-for="d in byId[hover].deps" :key="d"
          :d="`M ${X0 + byId[d].t1 * xs} ${rowY(byId[d].row) + RH / 2} L ${X0 + byId[hover].t0 * xs} ${rowY(byId[hover].row) + RH / 2}`"
          stroke="var(--c-bad)" stroke-width="1.5" fill="none" stroke-dasharray="3 2" />
      </g>
      <g v-for="s in sched" :key="s.id" @mouseenter="hover = s.id" @mouseleave="hover = null" style="transition: transform .4s">
        <rect :x="X0 + s.t0 * xs + 1" :y="rowY(s.row)" :width="Math.max(s.d * xs - 2, 2)" :height="RH" rx="5"
          :fill="hover === s.id ? 'var(--c-hl)' : isDep(s.id) ? 'color-mix(in srgb, var(--c-bad) 15%, white)' : s.lane === 'part' ? 'color-mix(in srgb, var(--c-update) 16%, white)' : 'color-mix(in srgb, var(--c-view) 20%, white)'"
          :stroke="s.lane === 'part' ? 'var(--c-update)' : 'var(--c-view)'" stroke-width="1.3" />
        <title>{{ s.t }}</title>
        <text :x="X0 + (s.t0 + s.d / 2) * xs" :y="rowY(s.row) + RH / 2 + 4" text-anchor="middle"
          :style="{ fontSize: fit(s).size + 'px', fontWeight: 600 }" fill="var(--c-ink)">{{ fit(s).text }}</text>
      </g>
      <line :x1="X0 + total * xs" :x2="X0 + total * xs" y1="14" :y2="24 + 4 * (RH + 12) - 8" stroke="var(--c-ink)" stroke-width="1.5" />
      <text :x="X0 + total * xs + 4" y="16" style="font-size:10px; font-weight:700" fill="var(--c-ink)">join</text>
    </svg>
    <div class="tiny muted">Hover a task to see the events it waits on. Durations are illustrative units, not measurements. Overlap creates an opportunity, it does not guarantee perfect concurrency on a busy GPU.</div>
  </div>
</template>
