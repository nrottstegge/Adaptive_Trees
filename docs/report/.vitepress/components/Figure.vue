<script setup>
import { nextTick, onBeforeUnmount, onMounted, ref } from 'vue'
// Frame for figures: border, horizontal scroll on narrow screens, caption.
// The ⤢ button (or a click on the caption) enlarges the live figure to fill the screen:
// the same component instance is scaled with CSS zoom, so its state (step, sliders) is kept.
defineProps({
  caption: { type: String, default: '' },
  minWidth: { type: String, default: '0' }, // content min-width before it scrolls horizontally
  center: { type: Boolean, default: false },
})
const open = ref(false)
const fig = ref(null), inner = ref(null)
const holdH = ref(0)            // keeps the page from jumping while the figure is lifted out
const innerStyle = ref({})

async function expand() {
  const el = inner.value
  const w0 = el.offsetWidth, h0 = el.offsetHeight
  holdH.value = fig.value.offsetHeight
  open.value = true
  await nextTick()
  const capH = fig.value.querySelector('figcaption')?.offsetHeight || 0
  const availW = window.innerWidth * 0.94 - 48
  const availH = window.innerHeight * 0.94 - capH - 80
  const z = Math.max(1, Math.min(availW / w0, availH / h0, 3))
  innerStyle.value = { width: w0 + 'px', zoom: z }
  document.body.style.overflow = 'hidden'
}
function close() {
  open.value = false
  innerStyle.value = {}
  document.body.style.overflow = ''
}
const onKey = e => { if (e.key === 'Escape' && open.value) close() }
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => { window.removeEventListener('keydown', onKey); if (open.value) document.body.style.overflow = '' })
</script>

<template>
  <div class="fig-hold" :style="open ? { height: holdH + 'px' } : {}">
    <div v-if="open" class="fig-backdrop" @click="close"></div>
    <figure ref="fig" class="fig" :class="{ open }">
      <button class="fig-btn" :title="open ? 'close (Esc)' : 'enlarge figure'" @click="open ? close() : expand()">{{ open ? '✕' : '⤢' }}</button>
      <div class="scroll"><div ref="inner" class="inner" :style="[{ minWidth }, innerStyle]" :class="{ center }"><slot /></div></div>
      <figcaption v-if="caption || $slots.caption" :title="open ? '' : 'click to enlarge'" @click="!open && expand()"><slot name="caption">{{ caption }}</slot></figcaption>
    </figure>
  </div>
</template>

<style scoped>
.fig-hold { margin: 1.5rem 0; }
.fig { position: relative; margin: 0; border: 1px solid var(--c-line); border-radius: 6px; background: var(--c-surface); padding: 14px 16px 10px; }
.scroll { overflow-x: auto; }
.inner.center { display: flex; flex-direction: column; align-items: center; }
figcaption { margin-top: 10px; padding-top: 8px; border-top: 1px solid var(--c-line); font-size: 0.8rem; color: var(--c-muted); line-height: 1.45; cursor: zoom-in; }
:deep(p) { margin: 0.3rem 0; }

.fig-btn { position: absolute; top: 6px; right: 8px; z-index: 2; border: 1px solid var(--c-line); background: var(--c-surface); color: var(--c-muted);
  border-radius: 4px; width: 26px; height: 24px; font-size: 0.85rem; line-height: 1; cursor: pointer; opacity: 0.55; transition: opacity 0.15s; }
.fig:hover .fig-btn, .fig-btn:focus-visible { opacity: 1; }
.fig-btn:hover { border-color: var(--fzj-blue); color: var(--fzj-blue); }

.fig-backdrop { position: fixed; inset: 0; z-index: 199; background: rgba(2, 61, 107, 0.28); }
.fig.open { position: fixed; z-index: 200; inset: 3vh 3vw; overflow: auto; display: flex; flex-direction: column; justify-content: center;
  box-shadow: 0 16px 48px rgba(0, 0, 0, 0.3); padding: 36px 24px 16px; }
.fig.open .fig-btn { opacity: 1; width: 32px; height: 30px; font-size: 1rem; }
.fig.open .scroll { overflow: visible; display: flex; justify-content: center; }
.fig.open figcaption { cursor: default; font-size: 0.9rem; max-width: 1100px; margin-left: auto; margin-right: auto; }
</style>
