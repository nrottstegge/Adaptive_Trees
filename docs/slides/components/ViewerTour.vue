<script setup>
import { computed } from 'vue'
// Sequence of exported viewer scenes, advanced with Slidev clicks.
const props = defineProps({
  scenes: { type: Array, required: true }, // [{ url, dataset, particles, note }]
  step: { type: Number, default: 0 },
})
const i = computed(() => Math.min(Math.max(props.step, 0), props.scenes.length - 1))
const sc = computed(() => props.scenes[i.value])
</script>

<template>
  <div class="tour">
    <LiveEmbed :key="sc.url" :url="sc.url" :zoom="1" fallback="[INSERT VIEWER EXPORT]" />
    <div class="side">
      <div class="steps">
        <div v-for="(s, k) in scenes" :key="k" class="st" :class="{ on: k === i, done: k < i }">
          <span class="n">{{ k + 1 }}</span>
          <span>{{ s.dataset }}<span v-if="s.short" class="muted"> · {{ s.short }}</span></span>
        </div>
      </div>
      <div class="card">
        <div class="muted tiny">dataset</div>
        <div class="big">{{ sc.dataset }}</div>
        <div v-if="sc.note" class="tiny muted mt-1">{{ sc.note }}</div>
      </div>
      <div class="card">
        <div class="muted tiny">particles</div>
        <div class="big">{{ sc.particles }}</div>
        <div v-if="sc.particlesNote" class="tiny muted mt-1">{{ sc.particlesNote }}</div>
      </div>
      <slot />
    </div>
  </div>
</template>

<style scoped>
.tour { display: grid; grid-template-columns: 2.4fr 1fr; gap: 20px; height: 395px; }
.side { display: flex; flex-direction: column; gap: 10px; font-size: 0.8rem; }
.steps { display: flex; flex-direction: column; gap: 3px; }
.st { display: flex; align-items: center; gap: 8px; font-size: 0.7rem; color: var(--c-muted); }
.st .n { width: 18px; height: 18px; display: inline-flex; align-items: center; justify-content: center; border: 1.5px solid var(--c-line-strong); font-size: 0.6rem; font-weight: 700; }
.st.on { color: var(--c-ink); font-weight: 700; }
.st.on .n { background: var(--fzj-blue); border-color: var(--fzj-blue); color: white; }
.st.done .n { border-color: var(--fzj-blue); color: var(--fzj-blue); }
.big { font-weight: 700; font-size: 1.05rem; }
</style>
