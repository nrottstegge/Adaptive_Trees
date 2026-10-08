<script setup>
import { useSlideContext } from '@slidev/client'
import { fzj } from '../lib/fzj.js'
defineProps({ minimal: { type: Boolean, default: false } })
const { $page } = useSlideContext()
</script>

<template>
  <div class="fzj-footer" :class="{ minimal }">
    <span>{{ fzj.banner }}</span>
    <span v-if="!minimal">{{ fzj.date }}</span>
    <span v-if="!minimal">Slide {{ $page }}</span>
    <img :src="fzj.logo" alt="Forschungszentrum Jülich" />
  </div>
</template>

<style scoped>
.fzj-footer {
  position: absolute; left: 31px; right: 31px; bottom: 28px; height: 50px;
  display: flex; align-items: flex-end; justify-content: space-between;
  font-size: 9.5px; color: var(--fzj-blue); line-height: 1; pointer-events: none;
}
.fzj-footer span { padding-bottom: 3px; }
.fzj-footer img { height: 50px; width: auto; }
</style>
