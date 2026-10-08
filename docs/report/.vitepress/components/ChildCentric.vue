<script setup>
import { computed, ref } from 'vue'
// M internal parents on one level, 8 children each. FMSolvr expects the children in
// child-centric order: all child-0s, then all child-1s, … ⇒ child(p, c) = childIndex[p] + c·M
const M = ref(3)
const layout = ref('child') // 'child' | 'parent'
const names = ['A', 'B', 'C', 'D']
const colors = ['var(--c-update)', 'var(--c-view)', 'var(--c-good)', 'var(--c-oct-leaf)']
const offset = 9 // levelOffset of the children's level (illustrative)
const slots = computed(() => {
  const out = []
  for (let i = 0; i < 8 * M.value; i++) {
    const p = layout.value === 'child' ? i % M.value : Math.floor(i / 8)
    const c = layout.value === 'child' ? Math.floor(i / M.value) : i % 8
    out.push({ i: offset + i, p, c })
  }
  return out
})
const hover = ref(null)
const formula = computed(() => {
  const h = hover.value
  if (!h) return null
  return layout.value === 'child'
    ? `child(${names[h.p]}, ${h.c}) = childIndex[${names[h.p]}] + ${h.c}·M = ${offset + h.p} + ${h.c}·${M.value} = ${h.i}`
    : `child(${names[h.p]}, ${h.c}) = childIndex[${names[h.p]}] + ${h.c} = ${offset + 8 * h.p} + ${h.c} = ${h.i}`
})
</script>

<template>
  <div class="cc">
    <div class="ctl">
      <button class="pill" :class="{ on: layout === 'parent' }" @click="layout = 'parent'">parent-major (siblings contiguous)</button>
      <button class="pill" :class="{ on: layout === 'child' }" @click="layout = 'child'">child-centric (FMSolvr layout)</button>
      <label>parents M <input type="range" min="2" max="4" v-model.number="M" /> <b>{{ M }}</b></label>
    </div>
    <div class="parents">
      <span v-for="p in M" :key="p" class="par" :style="{ borderColor: colors[p - 1], color: colors[p - 1] }">{{ names[p - 1] }}<small> = node {{ offset - M - 1 + p }}</small></span>
    </div>
    <div class="row">
      <div v-for="s in slots" :key="s.i" class="slot" :class="{ on: hover && hover.p === s.p, me: hover && hover.i === s.i }"
        :style="{ borderColor: colors[s.p], background: `color-mix(in srgb, ${colors[s.p]} ${hover && hover.p === s.p ? 30 : 10}%, white)` }"
        @mouseenter="hover = s" @mouseleave="hover = null">
        <b>{{ names[s.p] }}{{ s.c }}</b><span>{{ s.i }}</span>
      </div>
    </div>
    <div class="formula mono">{{ formula || 'hover a child slot' }}</div>
    <div class="tiny muted">childIndex[p] always points to child 0. With level offsets known, M = (levelOffset[ℓ+2] − levelOffset[ℓ+1]) / 8, so no per-node child list is needed.</div>
  </div>
</template>

<style scoped>
.cc { display: flex; flex-direction: column; gap: 8px; }
.parents { display: flex; gap: 8px; }
.par { border: 2px solid; border-radius: 6px; padding: 2px 10px; font-weight: 700; }
.par small { font-weight: 400; color: var(--c-muted); margin-left: 4px; }
.row { display: flex; flex-wrap: wrap; gap: 3px; }
.slot { width: 34px; border: 1.5px solid; border-radius: 4px; display: flex; flex-direction: column; align-items: center; font-size: 0.68rem; padding: 2px 0; cursor: default; transition: background 0.15s; }
.slot span { font-size: 0.58rem; color: var(--c-muted); font-family: var(--vp-font-family-mono); }
.slot.me { outline: 2px solid var(--c-ink); }
.formula { font-size: 0.8rem; min-height: 1.4em; color: var(--fzj-blue); }
</style>
