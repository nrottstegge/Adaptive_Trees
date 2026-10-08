<script setup>
import { refs, order } from '../lib/refs.js'
</script>

<template>
  <ol class="refs">
    <li v-for="(id, i) in order" :key="id">
      <span class="n">[{{ i + 1 }}]</span>
      <span :class="{ ins: refs[id].text.startsWith('[') }">{{ refs[id].text }}</span>
      <a v-if="refs[id].url" :href="refs[id].url" target="_blank" rel="noopener" class="u">{{ refs[id].url.replace(/^https?:\/\//, '') }}</a>
    </li>
  </ol>
</template>

<style scoped>
.refs { list-style: none; padding: 0; margin-top: 8px; display: flex; flex-direction: column; gap: 7px; font-size: 0.8rem; }
.refs li::before { display: none; }
.refs li { display: grid; grid-template-columns: 34px 1fr; column-gap: 6px; }
.n { color: var(--fzj-blue); font-weight: 700; }
.u { grid-column: 2; font-size: 0.72rem; color: var(--fzj-blue); font-family: var(--slidev-code-font-family, monospace); }
</style>
