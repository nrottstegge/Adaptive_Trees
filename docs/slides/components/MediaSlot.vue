<script setup>
import { computed, nextTick, ref, watch } from 'vue'
import { useSlideContext } from '@slidev/client'
// Image / GIF / video from public/ with a placeholder fallback until the file exists.
// Videos (.mp4/.webm) behave like GIFs (muted autoplay loop) but are only fetched on or next to
// the current slide and only play while their slide is shown.
const props = defineProps({
  src: { type: String, default: '' },
  label: { type: String, default: '[INSERT SCREENSHOT]' },
  note: { type: String, default: '' },
  fit: { type: String, default: 'contain' },
})
const failed = ref(!props.src)
watch(() => props.src, s => { failed.value = !s })

const isVideo = computed(() => /\.(mp4|webm)$/i.test(props.src))
const { $page, $nav, $renderContext } = useSlideContext()
const live = computed(() => ['slide', 'presenter'].includes($renderContext.value))
const near = computed(() => !live.value || Math.abs($nav.value.currentPage - $page.value) <= 1)
const active = computed(() => live.value && $nav.value.currentPage === $page.value)
const video = ref(null)
function sync() {
  const el = video.value
  if (!el || !el.currentSrc) return
  if (active.value) { if (el.paused) el.play().catch(() => {}) }
  else el.pause()
}
watch([active, video, near], () => nextTick(sync), { immediate: true })
</script>

<template>
  <div class="media">
    <template v-if="!failed">
      <video v-if="isVideo" ref="video" :src="near ? src : undefined" :style="{ objectFit: fit }"
        muted loop playsinline :preload="live ? 'auto' : 'metadata'"
        @loadeddata="sync" @canplay="sync" @pause="sync" @error="failed = true" />
      <img v-else :src="src" :style="{ objectFit: fit }" loading="lazy" decoding="async" @error="failed = true" />
    </template>
    <Placeholder v-else :label="label" :note="note || (src ? `put file at public${src}` : '')" h="100%" />
  </div>
</template>

<style scoped>
.media { width: 100%; height: 100%; position: relative; }
img, video { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
</style>
