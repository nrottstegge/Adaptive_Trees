<script setup>
import { computed, ref } from 'vue'
// Exported viewer scenes, switchable by tabs.
const props = defineProps({
  scenes: { type: Array, required: true }, // [{ url, dataset, short, particles, particlesNote, note }]
})
const i = ref(0)
const sc = computed(() => props.scenes[i.value])
</script>

<template>
  <div class="tour">
    <div class="side">
      <div class="steps">
        <button v-for="(s, k) in scenes" :key="k" class="st" :class="{ on: k === i }" @click="i = k">
          <span class="n">{{ k + 1 }}</span>
          <span>{{ s.dataset }}<span v-if="s.short" class="muted"> · {{ s.short }}</span></span>
        </button>
      </div>
      <div class="facts">
        <div class="card"><div class="muted tiny">dataset</div><div class="big">{{ sc.dataset }}</div><div v-if="sc.note" class="tiny muted mt-1">{{ sc.note }}</div></div>
        <div class="card"><div class="muted tiny">particles</div><div class="big">{{ sc.particles }}</div><div v-if="sc.particlesNote" class="tiny muted mt-1">{{ sc.particlesNote }}</div></div>
      </div>
      <slot />
    </div>
    <div class="view"><LiveEmbed :key="sc.url" :url="sc.url" /></div>
  </div>
</template>

<style scoped>
.tour { display: flex; flex-direction: column; gap: 10px; margin: 1.2rem 0; }
.side { display: flex; flex-direction: column; gap: 8px; font-size: 0.85rem; }
.steps { display: flex; flex-wrap: wrap; gap: 6px; }
.st { display: inline-flex; align-items: center; gap: 8px; font-size: 0.8rem; color: var(--c-muted); border: 1px solid var(--c-line); border-radius: 99px; padding: 2px 10px 2px 3px; background: var(--c-surface); cursor: pointer; }
.st .n { width: 20px; height: 20px; border-radius: 99px; display: inline-flex; align-items: center; justify-content: center; border: 1.5px solid var(--c-line-strong); font-size: 0.65rem; font-weight: 700; }
.st.on { color: var(--c-ink); font-weight: 700; border-color: var(--fzj-blue); }
.st.on .n { background: var(--fzj-blue); border-color: var(--fzj-blue); color: white; }
.facts { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.big { font-weight: 700; font-size: 1.05rem; }
.view { height: 480px; }
</style>
