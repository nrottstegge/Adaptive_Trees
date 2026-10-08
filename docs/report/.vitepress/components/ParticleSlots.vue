<script setup>
import { computed, ref } from 'vue'
// Escaped particles keep their slot: their key becomes UINT64_MAX, so sorting moves them into a suffix.
// The device finds the active prefix; buffer addresses (and the captured graph) stay unchanged.
const base = [37, 5, 61, 18, 44, 9, 52, 27, 13, 33]
const escaped = ref(new Set([6]))
function toggle(i) { const s = new Set(escaped.value); s.has(i) ? s.delete(i) : s.add(i); escaped.value = s }
const keys = computed(() => base.map((k, i) => (escaped.value.has(i) ? Infinity : k)))
const sorted = computed(() => keys.value.map((k, i) => ({ k, i })).sort((a, b) => a.k - b.k))
const active = computed(() => sorted.value.filter(s => s.k !== Infinity).length)
</script>

<template>
  <div class="ps">
    <div class="arr"><span class="lab">input slot</span>
      <button v-for="(k, i) in keys" :key="i" class="chip slot" :class="{ esc: k === Infinity }" @click="toggle(i)" :title="'toggle escape of particle ' + i">#{{ i }}</button>
    </div>
    <div class="arr"><span class="lab">key</span>
      <span v-for="(k, i) in keys" :key="i" class="chip" :class="{ esc: k === Infinity }">{{ k === Infinity ? 'MAX' : k }}</span>
    </div>
    <div class="arr"><span class="lab">sorted P</span>
      <span v-for="(s, j) in sorted" :key="'p' + s.i" class="chip" :class="{ esc: s.k === Infinity, cut: j === active }">{{ s.k === Infinity ? 'MAX' : s.k }}</span>
    </div>
    <div class="arr"><span class="lab">Perm</span>
      <span v-for="(s, j) in sorted" :key="'q' + s.i" class="chip" :class="{ esc: s.k === Infinity, cut: j === active }">{{ s.i }}</span>
    </div>
    <div class="tiny muted">Click a slot to let that particle escape the domain. Active particles: <b>{{ active }}</b> / {{ base.length }} slots.
      The tree counts and views only see the active prefix, and escaped entries map to an invalid node index. Note that key generation and the sort still touch all slots.</div>
  </div>
</template>

<style scoped>
.ps { display: flex; flex-direction: column; gap: 5px; }
.chip { min-width: 34px; font-size: 0.68rem; }
.slot { cursor: pointer; }
.esc { background: var(--c-empty); color: var(--c-muted); border-style: dashed; }
.cut { box-shadow: -3px 0 0 var(--c-bad); margin-left: 6px; }
</style>
