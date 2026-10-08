<script setup>
import { computed } from 'vue'
// Ordering internal nodes for the child-centric layout.
// Old: sort by reversed child path, then stable sort by level (two sorts, extra key arrays).
// New: one sort on layoutKey = (1 << 3ℓ) | reversedPath — the marker bit separates the levels.
// step 0: SFC order · 1: sorted by reversed path · 2: + stable sort by level · 3: one sort on layoutKey
const props = defineProps({ step: { type: Number, default: 0 } })
const paths = [[], [0], [0, 3], [0, 7], [2], [2, 1], [2, 6]]
const rev = p => [...p].reverse().reduce((v, d) => v * 8 + d, 0)
const nodes = paths.map((p, sfc) => ({ p, sfc, lv: p.length, rev: rev(p), key: (1 << (3 * p.length)) | rev(p) }))
const order = computed(() => {
  const a = [...nodes]
  if (props.step === 1) a.sort((x, y) => x.rev - y.rev)
  if (props.step === 2) { a.sort((x, y) => x.rev - y.rev); a.sort((x, y) => x.lv - y.lv) }
  if (props.step === 3) a.sort((x, y) => x.key - y.key)
  return a
})
const bin = (v, w) => v.toString(2).padStart(w, '0')
const W = 7 // bits shown (3·2 + 1)
const keyBits = n => bin(n.key, W).split('').map((b, i) => ({ b, marker: i === W - 1 - 3 * n.lv }))
const pathStr = p => (p.length ? p.join('·') : 'root')
const revStr = p => (p.length ? [...p].reverse().join('·') : '—')
</script>

<template>
  <div class="lk">
    <table>
      <thead><tr><th>#</th><th>node path</th><th>level</th><th>reversed path</th><th v-if="step === 3">layoutKey (binary)</th><th v-if="step === 3">value</th></tr></thead>
      <TransitionGroup tag="tbody" name="mv">
        <tr v-for="(n, i) in order" :key="n.sfc">
          <td class="muted">{{ i }}</td>
          <td class="mono"><b>{{ pathStr(n.p) }}</b></td>
          <td>{{ n.lv }}</td>
          <td class="mono" :class="{ hl: step === 1 }">{{ revStr(n.p) }} <span class="muted tiny">({{ n.rev }})</span></td>
          <td v-if="step === 3" class="mono"><span v-for="(b, j) in keyBits(n)" :key="j" :class="{ mk: b.marker, lead: !b.marker && j < W - 1 - 3 * n.lv }">{{ b.b }}</span></td>
          <td v-if="step === 3" class="mono">{{ n.key }}</td>
        </tr>
      </TransitionGroup>
    </table>
    <div class="note small">
      <template v-if="step === 0">Internal nodes in level-grouped <b>SFC order</b> (what the classify/compact stages produce). Paths are octal child digits from the root.</template>
      <template v-else-if="step === 1">Sorting by the <b>reversed</b> path orders by the newest child digit first, then by the parent, but levels are still mixed.</template>
      <template v-else-if="step === 2">A second, stable sort by level gives the child-centric order. <b>Two radix sorts</b>, plus a key-generation kernel and buffers for the intermediate keys.</template>
      <template v-else>The marker bit <span class="mk">1</span> at position 3ℓ puts every level into its own numeric range, and the reversed path uses fewer than 3ℓ bits below it. <b>One sort</b> reaches the identical order (commit <span class="commit">8e958d5</span>).</template>
    </div>
  </div>
</template>

<style scoped>
.lk { display: flex; flex-direction: column; gap: 8px; }
table { font-size: 0.8rem; border-collapse: collapse; display: table; margin: 0; width: 100%; }
th, td { padding: 3px 10px !important; border: none !important; border-bottom: 1px solid var(--c-line) !important; text-align: left; }
tr { background: none !important; }
.hl { background: var(--c-hl); }
.mk { color: white; background: var(--c-bad); border-radius: 2px; padding: 0 1px; font-weight: 700; }
.lead { color: var(--c-line-strong); }
.mv-move { transition: transform 0.5s ease; }
.note { border-left: 3px solid var(--c-view); padding: 4px 10px; background: color-mix(in srgb, var(--c-view) 6%, white); min-height: 3.2em; }
</style>
