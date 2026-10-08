<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
// Shows one tall figure as several side-by-side columns of horizontal strips (crops of the same image),
// so it can be displayed larger on a wide slide. Click: full figure over the slide.
const props = defineProps({
  src: { type: String, required: true },
  aspect: { type: Number, required: true }, // image width / height
  columns: { type: Array, required: true }, // [[ [y0, y1], ... ], ...] fractions of the image height
  title: { type: String, default: '' },
  gap: { type: String, default: '18px' },
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
  <div ref="anchor" class="cc" :style="{ gap }" title="click to show the full figure" @click="target = slideRoot(); open = true">
    <div v-for="(col, ci) in columns" :key="ci" class="col">
      <div v-for="(r, ri) in col" :key="ri" class="strip" :style="{ aspectRatio: aspect / (r[1] - r[0]) }">
        <img :src="src" :style="{ top: (-r[0] / (r[1] - r[0]) * 100) + '%', height: (100 / (r[1] - r[0])) + '%' }" alt="" />
      </div>
    </div>
  </div>
  <Teleport :to="target || 'body'" :disabled="!target">
  <div v-if="open" class="zoom" @click.self="open = false">
    <div class="zbox">
      <div class="zhead"><b>{{ title }}</b><span class="grow"></span><button class="close" @click="open = false">✕</button></div>
      <div class="zfig"><img :src="src" alt="" /></div>
    </div>
  </div>
  </Teleport>
</template>

<style scoped>
.cc { display: flex; align-items: flex-start; cursor: zoom-in; }
.col { flex: 1 1 0; min-width: 0; display: flex; flex-direction: column; }
.strip { position: relative; overflow: hidden; width: 100%; }
.strip img { position: absolute; left: 0; width: 100%; max-width: none; }
.zoom { position: absolute; inset: 0; z-index: 60; background: rgba(2, 61, 107, 0.18); display: flex; align-items: center; justify-content: center; }
.zbox { width: calc(100% - 20px); height: calc(100% - 10px); background: white; border: 1px solid var(--c-line); border-radius: 6px; box-shadow: 0 12px 40px rgba(0,0,0,.25); display: flex; flex-direction: column; padding: 8px 12px; gap: 4px; }
.zhead { display: flex; align-items: center; font-size: 0.9rem; color: var(--fzj-blue); }
.zhead .grow { flex: 1; }
.close { border: none; background: none; cursor: pointer; font-size: 1rem; color: var(--c-ink); }
.zfig { flex: 1; position: relative; min-height: 0; }
.zfig img { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: contain; }
</style>
