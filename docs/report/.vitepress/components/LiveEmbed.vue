<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { withBase } from 'vitepress'
// Embeds an exported (self-contained) vtk.js viewer scene. The scenes are several MB each,
// so nothing is downloaded until the reader presses "load".
const props = defineProps({
  url: { type: String, required: true },
  fallback: { type: String, default: '[INSERT VIEWER EXPORT]' },
  autoload: { type: Boolean, default: false },
})
const src = computed(() => (props.url.startsWith('/') ? withBase(props.url) : props.url))
const loaded = ref(props.autoload)
const exists = ref(null)
const key = ref(0)
const big = ref(false)
onMounted(async () => {
  try {
    const h = await fetch(src.value, { method: 'HEAD', cache: 'no-store' })
    const len = Number(h.headers.get('content-length') || 0)
    exists.value = h.ok && (len === 0 || len > 20000)
  } catch { exists.value = false }
})
const onKey = e => { if (e.key === 'Escape') big.value = false }
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div class="live" :class="{ big }">
    <div class="bar">
      <span class="dot" :class="{ ok: exists === true, bad: exists === false }"></span>
      <span class="mono path">{{ url }}</span>
      <span class="grow"></span>
      <button v-if="loaded" @click="key++" title="reload">⟳</button>
      <button @click="big = !big" :title="big ? 'shrink' : 'enlarge'">{{ big ? '⤡' : '⤢' }}</button>
      <a :href="src" target="_blank" rel="noopener" title="open in new tab">↗</a>
    </div>
    <div class="body">
      <iframe v-if="loaded && exists" :key="key" :src="src" allow="fullscreen" />
      <Placeholder v-else-if="exists === false" :label="fallback" :note="`put the exported viewer at public${url}`" h="100%" />
      <div v-else class="center">
        <button class="btn primary" @click="loaded = true">▶ load interactive 3D viewer</button>
        <div class="tiny muted">vtk.js scene · drag to rotate, scroll to zoom</div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.live { display: flex; flex-direction: column; border: 1px solid var(--c-line); border-radius: 8px; overflow: hidden; background: var(--c-surface); height: 100%; }
.live.big { position: fixed; inset: 24px; z-index: 100; box-shadow: 0 10px 40px rgba(0, 0, 0, 0.3); height: auto; }
.bar { display: flex; align-items: center; gap: 8px; padding: 3px 8px; border-bottom: 1px solid var(--c-line); font-size: 0.68rem; color: var(--c-muted); background: var(--c-bg); }
.path { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.grow { flex: 1; }
.dot { width: 8px; height: 8px; border-radius: 99px; background: var(--c-line-strong); flex: none; }
.dot.ok { background: #16a34a; }
.dot.bad { background: var(--c-placeholder); }
.bar button, .bar a { border: none; background: none; cursor: pointer; font-size: 0.9rem; color: var(--c-ink); text-decoration: none; padding: 0 2px; }
.body { flex: 1; position: relative; min-height: 0; overflow: hidden; background: #f8fafc; }
iframe { position: absolute; inset: 0; width: 100%; height: 100%; border: 0; }
.center { position: absolute; inset: 0; display: flex; flex-direction: column; gap: 8px; align-items: center; justify-content: center; }
</style>
