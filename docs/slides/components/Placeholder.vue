<script setup>
defineProps({
  label: { type: String, default: '[INSERT BENCHMARK]' },
  note: { type: String, default: '' },
  h: { type: String, default: '100%' },
})
</script>

<template>
  <div class="ph" :style="{ minHeight: h }">
    <div class="ph-label">{{ label }}</div>
    <div v-if="note" class="ph-note">{{ note }}</div>
    <slot />
  </div>
</template>

<style scoped>
.ph {
  border: 2px dashed var(--c-placeholder);
  border-radius: 10px;
  background: repeating-linear-gradient(135deg, transparent 0 10px, color-mix(in srgb, var(--c-placeholder) 7%, transparent) 10px 20px);
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  gap: 4px; padding: 10px; text-align: center; width: 100%;
}
.ph-label { font-family: var(--slidev-code-font-family, monospace); font-weight: 700; color: var(--c-placeholder); font-size: 0.85rem; letter-spacing: 0.02em; }
.ph-note { font-size: 0.7rem; color: var(--c-muted); max-width: 90%; overflow-wrap: anywhere; }
</style>
