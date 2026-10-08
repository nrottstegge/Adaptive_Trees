<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue'
// Generic stepper replacing Slidev clicks:
//   <Stepped :steps="5" :labels="['a','b',...]" v-slot="{ step }"> <Comp :step="step" /> </Stepped>
const props = defineProps({
  steps: { type: Number, required: true },
  labels: { type: Array, default: () => [] },
  start: { type: Number, default: 0 },
  interval: { type: Number, default: 1800 }, // ms per step while playing
})
const step = ref(props.start)
const playing = ref(false)
let timer = null
const label = computed(() => props.labels[step.value] || '')
function go(d) { step.value = (step.value + d + props.steps) % props.steps }
function toggle() {
  playing.value = !playing.value
  clearInterval(timer)
  if (playing.value) { if (step.value === props.steps - 1) step.value = 0; timer = setInterval(() => (step.value === props.steps - 1 ? toggle() : go(1)), props.interval) }
}
onBeforeUnmount(() => clearInterval(timer))
watch(() => props.steps, () => { step.value = Math.min(step.value, props.steps - 1) })
</script>

<template>
  <div class="stepped">
    <div class="sbar">
      <button class="btn" @click="go(-1)" title="previous step">◀</button>
      <button class="btn" :class="{ primary: playing }" @click="toggle" :title="playing ? 'pause' : 'play'">{{ playing ? '❚❚' : '▶' }}</button>
      <button class="btn" @click="go(1)" title="next step">▶|</button>
      <div class="dots">
        <button v-for="i in steps" :key="i" :class="{ on: i - 1 === step, done: i - 1 < step }" @click="step = i - 1" :title="labels[i - 1] || `step ${i}`"></button>
      </div>
      <span class="slabel"><b>{{ step + 1 }}/{{ steps }}</b><template v-if="label"> · {{ label }}</template></span>
    </div>
    <slot :step="step" />
  </div>
</template>

<style scoped>
.stepped { display: flex; flex-direction: column; gap: 8px; }
.sbar { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; font-size: 0.8rem; }
.dots { display: flex; gap: 3px; margin: 0 6px; }
.dots button { width: 20px; height: 6px; border-radius: 3px; border: none; background: var(--c-line); cursor: pointer; padding: 0; }
.dots button.done { background: color-mix(in srgb, var(--fzj-blue) 40%, white); }
.dots button.on { background: var(--fzj-blue); }
.slabel { color: var(--c-ink); }
</style>
