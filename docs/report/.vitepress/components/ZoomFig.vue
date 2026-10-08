<script setup>
import { ref, onMounted, onBeforeUnmount } from 'vue'
// A figure that enlarges over the page on click (Esc / click outside closes).
defineProps({
  src: { type: String, required: true },
  height: { type: String, default: '420px' },
  title: { type: String, default: '' },
  caption: { type: String, default: '' },
})
const open = ref(false)
const onKey = e => { if (e.key === 'Escape') open.value = false }
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <figure class="fig zfwrap">
    <div class="zf" :style="{ height }" title="click to enlarge" @click="open = true">
      <MediaSlot :src="src" label="[INSERT PLOT]" />
    </div>
    <figcaption v-if="caption || title">{{ caption || title }} <span class="muted">· click to enlarge</span></figcaption>
  </figure>
  <Teleport to="body">
    <div v-if="open" class="zoom" @click.self="open = false">
      <div class="zbox">
        <div class="zhead"><b>{{ title }}</b><span class="grow"></span><button class="close" @click="open = false">✕</button></div>
        <div class="zfig"><MediaSlot :src="src" label="[INSERT PLOT]" /></div>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.zfwrap { margin: 1.2rem 0; }
.zf { position: relative; cursor: zoom-in; border: 1px solid var(--c-line); border-radius: 4px; background: white; }
.zf:hover { border-color: var(--fzj-blue); }
figcaption { font-size: 0.78rem; color: var(--c-ink); margin-top: 6px; text-align: center; }
.zoom { position: fixed; inset: 0; z-index: 200; background: rgba(2, 61, 107, 0.25); display: flex; align-items: center; justify-content: center; }
.zbox { width: min(96vw, 1500px); height: 92vh; background: white; border: 1px solid var(--c-line); border-radius: 6px; box-shadow: 0 12px 40px rgba(0,0,0,.25); display: flex; flex-direction: column; padding: 10px 14px; gap: 6px; }
.zhead { display: flex; align-items: center; font-size: 0.95rem; color: var(--fzj-blue); }
.zhead .grow { flex: 1; }
.close { border: none; background: none; cursor: pointer; font-size: 1.1rem; color: var(--c-ink); }
.zfig { flex: 1; position: relative; min-height: 0; }
</style>
