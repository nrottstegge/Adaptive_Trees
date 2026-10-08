<script setup>
import { computed } from 'vue'
// Same sequence of required buffer sizes (leaves per time step), three memory policies.
//  1. ordinary resize: grow capacity to exactly `required`; resize() value-initialises newly exposed elements
//  2. resizeWithHeadroom: reserve required + 25 % when capacity is exceeded; resize(n, thrust::no_init)
//  3. graph capacity: storage prepared once; only a device-side logical count moves; overflow → grow + recapture
const props = defineProps({
  step: { type: Number, default: 0 },
  sizes: { type: Array, default: () => [1000, 940, 1060, 1010, 1130, 1080, 1190, 1150, 1240, 1210, 1310, 1270] },
})
const MAXW = 1700

function simulate(policy) {
  let cap = 0, size = 0
  const hist = []
  const tot = { alloc: 0, init: 0, useful: 0, recapture: 0, hostResize: 0 }
  props.sizes.forEach((req, t) => {
    const ev = { prev: size, prevCap: cap, alloc: false, init: 0, recapture: false }
    if (policy === 'graph') {
      if (t === 0) { cap = Math.ceil(req * 1.25); ev.alloc = true; tot.alloc++; tot.recapture++; tot.hostResize++; ev.recapture = true }
      else if (req > cap) { cap = Math.ceil(req * 1.25); ev.alloc = true; tot.alloc++; tot.recapture++; tot.hostResize++; ev.recapture = true }
    } else {
      tot.hostResize++
      if (req > cap) { cap = policy === 'exact' ? req : Math.ceil(req * 1.25); ev.alloc = true; tot.alloc++ }
      if (policy === 'exact' && req > size) { ev.init = req - size; tot.init += ev.init }
    }
    size = req
    tot.useful += req
    hist.push({ ...ev, size, cap, tot: { ...tot } })
  })
  return hist
}
const policies = [
  { id: 'exact', name: 'ordinary resize()', sub: 'exact capacity · value-initialises new elements', color: 'var(--c-bad)' },
  { id: 'headroom', name: 'resizeWithHeadroom', sub: '+25 % capacity · resize(n, thrust::no_init)', color: 'var(--c-update)' },
  { id: 'graph', name: 'prepared graph capacity', sub: 'fixed storage · logical count lives on the device', color: 'var(--c-good)' },
]
const sims = Object.fromEntries(policies.map(p => [p.id, simulate(p.id)]))
const t = computed(() => Math.min(props.step, props.sizes.length - 1))
const pct = v => (100 * v) / MAXW + '%'
</script>

<template>
  <div class="bp">
    <div class="head small">time step <b>{{ t + 1 }}</b> · required size <b class="mono">{{ sizes[t] }}</b>
      <span class="spark">
        <span v-for="(s, i) in sizes" :key="i" :style="{ height: (s - 850) / 8 + 'px', background: i === t ? 'var(--fzj-blue)' : 'var(--c-line)' }"></span>
      </span>
    </div>
    <div v-for="p in policies" :key="p.id" class="pol">
      <div class="name"><b :style="{ color: p.color }">{{ p.name }}</b><span v-if="sims[p.id][t].alloc" class="atag">{{ sims[p.id][t].recapture ? (t === 0 ? 'alloc + capture' : 'alloc + recapture') : 'alloc' }}</span><div class="tiny muted">{{ p.sub }}</div></div>
      <div class="bar">
        <div class="cap" :style="{ width: pct(sims[p.id][t].cap), borderColor: sims[p.id][t].alloc ? 'var(--c-bad)' : 'var(--c-ink)', borderStyle: sims[p.id][t].alloc ? 'solid' : 'dashed', borderWidth: sims[p.id][t].alloc ? '2.5px' : '1.2px' }"></div>
        <div class="size" :style="{ width: pct(sims[p.id][t].size) }"></div>
        <div v-if="sims[p.id][t].init" class="init" :style="{ left: pct(sims[p.id][t].prev), width: pct(sims[p.id][t].init) }"></div>
      </div>
      <div class="ctr mono">
        <span title="allocations">alloc <b>{{ sims[p.id][t].tot.alloc }}</b></span>
        <span title="value-initialisation writes that the kernel overwrites anyway">init <b :style="{ color: sims[p.id][t].tot.init ? 'var(--c-view)' : '' }">{{ sims[p.id][t].tot.init }}</b></span>
        <span title="host-side resize calls (for the graph only when capacity must grow, outside the replay)">host resize <b>{{ sims[p.id][t].tot.hostResize }}</b></span>
        <span v-if="p.id === 'graph'" title="graph recaptures after growth">recapture <b>{{ sims[p.id][t].tot.recapture }}</b></span>
      </div>
    </div>
    <div class="legend tiny muted">
      <span><i style="border: 1.5px dashed var(--c-ink)"></i>capacity</span>
      <span><i style="background: color-mix(in srgb, var(--c-good) 35%, white)"></i>logical size (written by the kernel)</span>
      <span><i style="background: var(--c-view)"></i>newly exposed → value-initialised, then overwritten</span>
      <span><i style="border: 2.5px solid var(--c-bad)"></i>allocation this step</span>
    </div>
  </div>
</template>

<style scoped>
.bp { display: flex; flex-direction: column; gap: 6px; }
.head { display: flex; align-items: flex-end; gap: 8px; }
.spark { display: inline-flex; align-items: flex-end; gap: 2px; height: 60px; margin-left: auto; }
.spark span { width: 8px; border-radius: 1px; }
.pol { display: grid; grid-template-columns: 1fr auto; row-gap: 2px; gap: 10px; align-items: center; border-top: 1px solid var(--c-line); padding-top: 4px; }
.bar { position: relative; height: 30px; grid-column: 1 / -1; grid-row: 2; }
.bar > div { position: absolute; top: 3px; height: 24px; transition: all 0.35s; }
.bar .cap { left: 0; box-sizing: border-box; border-radius: 3px; background: white; }
.bar .size { left: 0; top: 7px; height: 16px; background: color-mix(in srgb, var(--c-good) 35%, white); }
.bar .init { top: 7px; height: 16px; background: var(--c-view); }
.atag { margin-left: 8px; padding: 0 5px; border: 1px solid var(--c-bad); border-radius: 3px; font-size: 0.65rem; font-weight: 700; color: var(--c-bad); white-space: nowrap; }
.ctr { display: flex; gap: 10px; white-space: nowrap; font-size: 0.72rem; color: var(--c-muted); }
.ctr b { color: var(--c-ink); }
.legend { display: flex; flex-wrap: wrap; gap: 4px 14px; }
.legend i { display: inline-block; width: 14px; height: 10px; margin-right: 5px; vertical-align: -1px; }
@media (max-width: 560px) { .pol { grid-template-columns: 1fr; } .bar { grid-row: auto; } }
</style>
