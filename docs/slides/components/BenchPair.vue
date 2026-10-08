<script setup>
import { computed, ref, watch, onMounted, onBeforeUnmount } from 'vue'
// Two datasets side by side: animation + particle count, and a 2×3 figure per dataset.
// One shared toggle switches the figure variant (click a tab, or advance with Slidev clicks);
// clicking a figure enlarges it over the slide.
const props = defineProps({
  datasets: { type: Array, required: true }, // [{ key, name, gif, particles }]
  variants: { type: Array, required: true }, // [{ label, color, file: key => '/bench/...' }]
  step: { type: Number, default: 0 },
  setup: { type: String, default: '' }, // non-empty -> show the measurement-setup line
})
const sel = ref(0)
watch(() => props.step, v => { sel.value = Math.min(Math.max(v, 0), props.variants.length - 1) }, { immediate: true })
const v = computed(() => props.variants[sel.value])
const zoomed = ref(null) // dataset key or null
const zoomDs = computed(() => props.datasets.find(d => d.key === zoomed.value))
const anchor = ref(null)
const target = ref(null)
function openZoom(k) { target.value = anchor.value?.closest('.layout-wrapper') || null; zoomed.value = k }
const onKey = e => { if (e.key === 'Escape') zoomed.value = null }
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div ref="anchor" class="bp">
    <div class="tabs">
      <button v-for="(x, i) in variants" :key="x.label" class="pill" :class="{ on: i === sel }"
        :style="i === sel ? { borderColor: x.color, color: x.color } : {}" @click="sel = i">
        <span class="sw" :style="{ background: x.color }"></span>{{ x.label }}
      </button>
      <span class="hint"><template v-if="setup">NVIDIA GeForce RTX 5060 · CUDA Graph timings · median + bootstrap CI <Cite id="benchmarking" /> · </template>click a figure to enlarge</span>
    </div>
    <div class="cols" :style="{ gridTemplateColumns: `repeat(${datasets.length}, 1fr)` }">
      <div v-for="d in datasets" :key="d.key" class="col">
        <div class="head">
          <span class="name">{{ d.name }}</span>
          <span class="num" :class="{ ins: String(d.particles).startsWith('[') }">{{ d.particles }}</span>
          <span class="muted tiny">particles</span>
        </div>
        <div class="gif"><MediaSlot :src="d.gif" label="[INSERT GIF]" fit="cover" /></div>
        <div class="fig" @click="openZoom(d.key)" title="click to enlarge">
          <MediaSlot :key="v.file(d.key)" :src="v.file(d.key)" label="[INSERT BENCHMARK]" />
        </div>
      </div>
    </div>

    <Teleport :to="target || 'body'" :disabled="!target">
    <div v-if="zoomDs" class="zoom" @click.self="zoomed = null">
      <div class="zbox">
        <div class="zhead">
          <b>{{ zoomDs.name }}</b>
          <button v-for="(x, i) in variants" :key="'z' + x.label" class="pill" :class="{ on: i === sel }"
            :style="i === sel ? { borderColor: x.color, color: x.color } : {}" @click="sel = i">
            <span class="sw" :style="{ background: x.color }"></span>{{ x.label }}
          </button>
          <span class="grow"></span>
          <button class="close" @click="zoomed = null">✕</button>
        </div>
        <div class="zfig"><MediaSlot :key="'z' + v.file(zoomDs.key)" :src="v.file(zoomDs.key)" label="[INSERT BENCHMARK]" /></div>
      </div>
    </div>
    </Teleport>
  </div>
</template>

<style scoped>
.bp { display: flex; flex-direction: column; gap: 8px; }
.tabs { display: flex; gap: 6px; align-items: center; }
.tabs .hint { margin-left: auto; font-size: 0.62rem; color: var(--c-muted); }
button.pill { cursor: pointer; }
.pill.on { font-weight: 700; border-width: 2px; }
.cols { display: grid; gap: 16px; }
.col { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.head { display: flex; gap: 6px; align-items: baseline; white-space: nowrap; }
.gif { width: 100%; height: 175px; border-radius: 6px; overflow: hidden; border: 1px solid var(--c-line); background: var(--c-surface); position: relative; }
.name { font-weight: 700; font-size: 0.95rem; color: var(--fzj-blue); margin-right: 4px; }
.num { font-weight: 700; font-size: 0.85rem; }
.fig { position: relative; height: 140px; cursor: zoom-in; border: 1px solid var(--c-line); border-radius: 4px; overflow: hidden; background: white; }
.fig:hover { border-color: var(--fzj-blue); }
.zoom { position: absolute; inset: 0; z-index: 60; background: rgba(2, 61, 107, 0.18); display: flex; align-items: center; justify-content: center; }
.zbox { width: calc(100% - 16px); height: calc(100% - 12px); background: white; border: 1px solid var(--c-line); border-radius: 6px; box-shadow: 0 12px 40px rgba(0,0,0,.25); display: flex; flex-direction: column; padding: 10px 14px; gap: 8px; }
.zhead { display: flex; gap: 8px; align-items: center; font-size: 0.9rem; }
.zhead .grow { flex: 1; }
.close { border: none; background: none; cursor: pointer; font-size: 1rem; color: var(--c-ink); }
.zfig { flex: 1; position: relative; min-height: 0; }
</style>
