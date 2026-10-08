<script setup>
import { num } from '../lib/refs.js'
const props = defineProps({ id: { type: [String, Array], required: true } })
const ids = Array.isArray(props.id) ? props.id : [props.id]
</script>

<template>
  <span class="cite">[{{ ids.map(num).join(', ') }}]</span>
</template>

<style scoped>
.cite { color: var(--fzj-blue); font-size: 0.82em; font-weight: 600; white-space: nowrap; margin-left: 0.15em; }
</style>
