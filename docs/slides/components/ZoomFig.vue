<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
// A figure that enlarges over the whole slide on click (Esc / click outside closes).
defineProps({
  src: { type: String, required: true },
  height: { type: String, default: '400px' },
  title: { type: String, default: '' },
})
const open = ref(false)
const anchor = ref(null)
const target = ref(null)
function slideRoot() { return anchor.value?.closest('.layout-wrapper') || null }
const onKey = e => { if (e.key === 'Escape') open.value = false }
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div ref="anchor" class="zf" :style="{ height }" title="click to enlarge" @click="target = slideRoot(); open = true">
    <MediaSlot :src="src" label="[INSERT BENCHMARK]" />
  </div>
  <Teleport :to="target || 'body'" :disabled="!target">
  <div v-if="open" class="zoom" @click.self="open = false">
    <div class="zbox">
      <div class="zhead"><b>{{ title }}</b><span class="grow"></span><button class="close" @click="open = false">✕</button></div>
      <div class="zfig"><MediaSlot :src="src" label="[INSERT BENCHMARK]" /></div>
    </div>
  </div>
  </Teleport>
</template>

<style scoped>
.zf { position: relative; cursor: zoom-in; }
.zoom { position: absolute; inset: 0; z-index: 60; background: rgba(2, 61, 107, 0.18); display: flex; align-items: center; justify-content: center; }
.zbox { width: calc(100% - 16px); height: calc(100% - 12px); background: white; border: 1px solid var(--c-line); border-radius: 6px; box-shadow: 0 12px 40px rgba(0,0,0,.25); display: flex; flex-direction: column; padding: 10px 14px; gap: 6px; }
.zhead { display: flex; align-items: center; font-size: 0.9rem; color: var(--fzj-blue); }
.zhead .grow { flex: 1; }
.close { border: none; background: none; cursor: pointer; font-size: 1rem; color: var(--c-ink); }
.zfig { flex: 1; position: relative; min-height: 0; }
</style>
