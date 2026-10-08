<script setup>
import { computed, ref, watch } from 'vue'
import { useSlideContext } from '@slidev/client'

const props = defineProps({
  url: { type: String, required: true },
  fallback: { type: String, default: '[INSERT SCREENSHOT]' },
  zoom: { type: Number, default: 0.45 }, // render at 1/zoom size, then scale down
})

const { $page, $nav, $renderContext } = useSlideContext()
// only mount the live app on the active slide in the main/presenter view (not in overview thumbnails)
const active = computed(() => $nav.value.currentPage === $page.value && ['slide', 'presenter'].includes($renderContext.value))

const reachable = ref(null) // null = checking
const key = ref(0)
const big = ref(false)

async function probe() {
  reachable.value = null
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), 8000)
  try {
    const sameOrigin = props.url.startsWith('/')
    if (sameOrigin) {
      // HEAD first; only download when the response is suspiciously small (Vite's SPA fallback page)
      const h = await fetch(props.url, { method: 'HEAD', cache: 'no-store', signal: ctrl.signal })
      const len = Number(h.headers.get('content-length') || 0)
      if (h.ok && len > 20000) reachable.value = true
      else {
        const r = await fetch(props.url, { cache: 'no-store', signal: ctrl.signal })
        const txt = r.ok ? await r.text() : ''
        reachable.value = r.ok && !txt.includes('/@vite/client') && !txt.includes('id="app"')
      }
    } else {
      await fetch(props.url, { mode: 'no-cors', cache: 'no-store', signal: ctrl.signal })
      reachable.value = true
    }
  } catch {
    reachable.value = false
  } finally {
    clearTimeout(timer)
  }
}
watch(active, a => { if (a) probe() }, { immediate: true })
function reload() { key.value++; probe() }
</script>

<template>
  <div class="live" :class="{ big }">
    <div class="bar">
      <span class="dot" :class="{ ok: reachable === true, bad: reachable === false }"></span>
      <span class="mono">{{ url }}</span>
      <span class="grow"></span>
      <button @click="reload" title="reload">⟳</button>
      <button @click="big = !big" :title="big ? 'shrink' : 'enlarge'">{{ big ? '⤡' : '⤢' }}</button>
      <a :href="url" target="_blank" rel="noopener" title="open in new tab">↗</a>
    </div>
    <div class="body">
      <iframe v-if="active && reachable" :key="key" :src="url" allow="fullscreen"
        :style="{ width: `${100 / zoom}%`, height: `${100 / zoom}%`, transform: `scale(${zoom})` }" />
      <Placeholder v-else-if="reachable === false" :label="fallback"
        :note="url.startsWith('/') ? `put the exported viewer at public${url}, then press ⟳` : `viewer not reachable at ${url} — start it, then press ⟳`" h="100%" />
      <div v-else class="muted tiny center">{{ active ? 'connecting…' : 'live viewer (loads on this slide)' }}</div>
    </div>
  </div>
</template>

<style scoped>
.live { display: flex; flex-direction: column; border: 1px solid var(--c-line); border-radius: 10px; overflow: hidden; background: var(--c-surface); height: 100%; }
.live.big { position: absolute; inset: 12px; z-index: 50; box-shadow: 0 10px 40px rgba(0, 0, 0, 0.25); height: auto; }
.bar { display: flex; align-items: center; gap: 8px; padding: 3px 8px; border-bottom: 1px solid var(--c-line); font-size: 0.62rem; color: var(--c-muted); background: var(--c-bg); }
.grow { flex: 1; }
.dot { width: 8px; height: 8px; border-radius: 99px; background: var(--c-line-strong); }
.dot.ok { background: #16a34a; }
.dot.bad { background: var(--c-placeholder); }
.bar button, .bar a { border: none; background: none; cursor: pointer; font-size: 0.8rem; color: var(--c-ink); text-decoration: none; padding: 0 2px; }
.body { flex: 1; position: relative; min-height: 0; }
iframe { position: absolute; left: 0; top: 0; border: 0; transform-origin: 0 0; }
.body { overflow: hidden; }
.center { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; }
</style>
