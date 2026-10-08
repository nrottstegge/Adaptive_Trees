<script setup>
import { computed, ref } from 'vue'
// All datasets side by side (as on the slide): animation on top, benchmark figure below.
// One shared toggle switches the figure variant; click a figure to enlarge it.
// Figure paths are patterns with {key}, e.g. '/bench/talk/{key}_v3_octree_leafcount.webp'.
const props = defineProps({
  datasets: { type: Array, required: true }, // [{ key, name, video, particles, note }]
  variants: { type: Array, required: true }, // [{ label, color, pattern }]
})
const vi = ref(0)
const v = computed(() => props.variants[vi.value])
const src = d => v.value.pattern.replace('{key}', d.key)
</script>

<template>
  <div class="be">
    <div class="ctl" v-if="variants.length > 1">
      <span class="muted">figure</span>
      <button v-for="(x, i) in variants" :key="x.label" class="pill" :class="{ on: i === vi }"
        :style="i === vi ? { borderColor: x.color, color: x.color } : {}" @click="vi = i">
        <span class="sw" :style="{ background: x.color }"></span>{{ x.label }}
      </button>
    </div>
    <div class="cols" :style="{ gridTemplateColumns: `repeat(${datasets.length}, minmax(0, 1fr))` }">
      <div v-for="d in datasets" :key="d.key" class="col">
        <div class="head"><span class="name">{{ d.name }}</span> <b class="mono">{{ d.particles }}</b> <span class="muted tiny">particles</span></div>
        <div class="vid"><MediaSlot :src="d.video" label="[INSERT VIDEO]" fit="cover" /></div>
        <ZoomFig :key="src(d)" :src="src(d)" height="170px" :title="`${d.name} · ${v.label}`" />
      </div>
    </div>
  </div>
</template>

<style scoped>
.be { display: flex; flex-direction: column; gap: 8px; }
.cols { display: grid; gap: 12px; }
.col { display: flex; flex-direction: column; gap: 6px; min-width: 0; }
.head { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 0.8rem; }
.name { font-weight: 700; color: var(--fzj-blue); }
.vid { position: relative; height: 190px; border-radius: 6px; overflow: hidden; border: 1px solid var(--c-line); background: black; }
.col :deep(.zfwrap) { margin: 0; }
.col :deep(figcaption) { display: none; }
@media (max-width: 720px) { .cols { grid-template-columns: 1fr !important; } }
</style>
