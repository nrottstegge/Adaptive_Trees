<script setup>
defineProps({
  steps: { type: Array, required: true }, // strings or {t, sub, tone}
  horizontal: { type: Boolean, default: false },
  loop: { type: String, default: '' },
  compact: { type: Boolean, default: false },
})
const txt = s => (typeof s === 'string' ? s : s.t)
const sub = s => (typeof s === 'string' ? '' : s.sub || '')
const tone = s => (typeof s === 'string' ? '' : s.tone || '')
</script>

<template>
  <div class="flow" :class="{ h: horizontal, compact, looped: !!loop }">
    <template v-for="(s, i) in steps" :key="i">
      <div class="step" :class="tone(s)">
        <div class="t" v-html="txt(s)" />
        <div v-if="sub(s)" class="sub" v-html="sub(s)" />
      </div>
      <div v-if="i < steps.length - 1" class="arrow">{{ horizontal ? '→' : '↓' }}</div>
    </template>
    <div v-if="loop && !horizontal" class="loop"><span>{{ loop }}</span></div>
  </div>
</template>

<style scoped>
.flow { position: relative; display: flex; flex-direction: column; align-items: stretch; width: max-content; min-width: 220px; }
.flow.h { flex-direction: row; align-items: center; width: auto; }
.flow.looped { padding-right: 90px; }
.step {
  border: 1.5px solid var(--c-line-strong); border-radius: 8px; padding: 5px 14px;
  background: var(--c-surface); text-align: center; font-size: 0.82rem; line-height: 1.25;
}
.compact .step { padding: 3px 10px; font-size: 0.74rem; }
.step .sub { font-size: 0.66rem; color: var(--c-muted); margin-top: 1px; }
.step.accent { border-color: var(--c-accent); background: color-mix(in srgb, var(--c-accent) 9%, var(--c-surface)); }
.step.update { border-color: var(--c-update); background: color-mix(in srgb, var(--c-update) 10%, var(--c-surface)); }
.step.view { border-color: var(--c-view); background: color-mix(in srgb, var(--c-view) 12%, var(--c-surface)); }
.step.dim { opacity: 0.55; }
.arrow { text-align: center; color: var(--c-muted); font-size: 0.9rem; line-height: 1.1; }
.compact .arrow { font-size: 0.75rem; line-height: 1; }
.h .arrow { padding: 0 6px; }
.loop {
  position: absolute; right: 8px; top: 49%; bottom: 14px; width: 48px;
  border: 1.5px dashed var(--c-accent); border-left: none; border-radius: 0 12px 12px 0;
}
.loop::before { content: '◀'; position: absolute; top: -9px; left: -6px; font-size: 0.6rem; color: var(--c-accent); }
.loop span {
  position: absolute; left: 100%; margin-left: 6px; top: 50%; transform: translateY(-50%);
  writing-mode: vertical-rl; font-size: 0.66rem; color: var(--c-accent); white-space: nowrap;
}
</style>
