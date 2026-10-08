<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { withBase } from 'vitepress'
// Image / video from public/ with a placeholder fallback until the file exists.
// Videos behave like GIFs: muted, looping, autoplaying. The <video> tag is written as literal HTML
// so `muted` and `autoplay` exist as real attributes from the first byte (browsers only allow
// autoplay for elements that are muted *before* playback starts; Vue would set `muted` only as a
// property after hydration). Off-screen videos are paused and resume when scrolled back into view.
const props = defineProps({
  src: { type: String, default: '' },
  label: { type: String, default: '[INSERT SCREENSHOT]' },
  note: { type: String, default: '' },
  fit: { type: String, default: 'contain' },
})
const url = computed(() => (props.src.startsWith('/') ? withBase(props.src) : props.src))
const failed = ref(!props.src)
watch(() => props.src, s => { failed.value = !s })
const isVideo = computed(() => /\.(mp4|webm)$/i.test(props.src))
const esc = s => s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
const videoHtml = computed(() =>
  `<video src="${esc(url.value)}" autoplay muted loop playsinline preload="auto" disablepictureinpicture ` +
  `style="position:absolute;inset:0;width:100%;height:100%;display:block;object-fit:${props.fit}"></video>`)

const root = ref(null)
let visible = true, io, el = null
const play = () => { if (el && visible && el.paused) { el.muted = true; el.play().catch(() => {}) } }
function sync() {
  if (!el) return
  if (visible) play(); else if (!el.paused) el.pause()
}
const onVis = () => (document.hidden ? el?.pause() : sync())
onMounted(() => {
  el = root.value?.querySelector('video') || null
  if (el) {
    el.muted = true
    el.addEventListener('error', () => (failed.value = true))
    for (const ev of ['loadeddata', 'canplay']) el.addEventListener(ev, sync)
    // if a browser still blocked autoplay, start on the first interaction anywhere on the page
    window.addEventListener('pointerdown', play, { passive: true })
    document.addEventListener('visibilitychange', onVis)
  }
  if ('IntersectionObserver' in window) {
    io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; sync() }, { threshold: 0.05 })
    io.observe(root.value)
  }
  sync()
})
onBeforeUnmount(() => {
  io?.disconnect()
  window.removeEventListener('pointerdown', play)
  document.removeEventListener('visibilitychange', onVis)
})
</script>

<template>
  <div ref="root" class="media">
    <template v-if="!failed">
      <div v-if="isVideo" class="vwrap" v-html="videoHtml"></div>
      <img v-else :src="url" :style="{ objectFit: fit }" loading="lazy" decoding="async" @error="failed = true" />
    </template>
    <Placeholder v-else :label="label" :note="note || (src ? `put file at public${src} (or run npm run sync)` : '')" h="100%" />
  </div>
</template>

<style scoped>
.media { width: 100%; height: 100%; position: relative; }
.vwrap { position: absolute; inset: 0; }
img { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
</style>
