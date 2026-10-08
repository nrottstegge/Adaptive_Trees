<script setup>
import { refs, num } from '../lib/refs.js'
const props = defineProps({ ids: { type: Array, required: true }, bottom: { type: Number, default: 82 } })
const list = props.ids.map(id => ({ n: num(id), ...refs[id] })).sort((a, b) => a.n - b.n)
</script>

<template>
  <div class="slide-refs">
    <div v-for="r in list" :key="r.n"><span class="n">[{{ r.n }}]</span> <span :class="{ ins: r.text.startsWith('[') }">{{ r.text }}</span></div>
  </div>
</template>

<style scoped>
.slide-refs { position: absolute; left: 0; right: 0; bottom: 0; font-size: 8.5px; line-height: 1.3; color: var(--c-muted); background: white; }
.n { color: var(--fzj-blue); font-weight: 700; }
</style>
