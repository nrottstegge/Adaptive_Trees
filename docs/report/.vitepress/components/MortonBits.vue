<script setup>
import { computed, ref } from 'vue'
// 2D Morton (Z-order) key explorer: pick a cell, see its coordinate bits interleave into the key.
// The implementation does the same in 3D with 21 bits per coordinate: key digit = 4·x + 2·y + z.
const props = defineProps({ bits: { type: Number, default: 3 }, size: { type: Number, default: 260 } })
const m = computed(() => 1 << props.bits)
const s = computed(() => props.size / m.value)
const morton = (x, y) => { let k = 0; for (let b = 0; b < 16; b++) k |= (((x >> b) & 1) << (2 * b + 1)) | (((y >> b) & 1) << (2 * b)); return k }
const cells = computed(() => {
  const out = []
  for (let y = 0; y < m.value; y++) for (let x = 0; x < m.value; x++) out.push({ x, y, k: morton(x, y) })
  return out.sort((a, b) => a.k - b.k)
})
const path = computed(() => cells.value.map((c, i) => `${i ? 'L' : 'M'} ${(c.x + 0.5) * s.value} ${(c.y + 0.5) * s.value}`).join(' '))
const sel = ref({ x: 5, y: 2 })
const showCurve = ref(true)
const bitsOf = (v) => [...Array(props.bits)].map((_, i) => (v >> (props.bits - 1 - i)) & 1)
const key = computed(() => morton(sel.value.x, sel.value.y))
// digits from the root down: each level contributes one 2-bit quadrant digit = 2·xbit + ybit
const digits = computed(() => bitsOf(sel.value.x).map((xb, i) => ({ xb, yb: bitsOf(sel.value.y)[i], d: 2 * xb + bitsOf(sel.value.y)[i] })))
// ancestors: square at each level containing the selected cell
const anc = computed(() => [...Array(props.bits)].map((_, l) => {
  const w = m.value >> l
  return { l, x: Math.floor(sel.value.x / w) * w, y: Math.floor(sel.value.y / w) * w, w }
}))
</script>

<template>
  <div class="mb">
    <div>
      <svg :width="size" :height="size" :viewBox="`-1 -1 ${size + 2} ${size + 2}`">
        <rect v-for="c in cells" :key="c.k" :x="c.x * s" :y="c.y * s" :width="s" :height="s"
          :fill="c.x === sel.x && c.y === sel.y ? 'var(--c-hl)' : 'var(--c-surface)'" stroke="var(--c-line)" stroke-width="0.7"
          style="cursor: pointer" @mouseenter="sel = { x: c.x, y: c.y }" @click="sel = { x: c.x, y: c.y }" />
        <rect v-for="a in anc.slice(1)" :key="'a' + a.l" :x="a.x * s" :y="a.y * s" :width="a.w * s" :height="a.w * s"
          fill="none" stroke="var(--c-accent)" :stroke-width="2.2 - a.l * 0.5" stroke-dasharray="4 2" pointer-events="none" />
        <path v-if="showCurve" :d="path" fill="none" stroke="var(--c-accent)" stroke-width="1.3" stroke-opacity="0.55" pointer-events="none" />
        <text v-for="c in cells" :key="'t' + c.k" :x="c.x * s + 3" :y="c.y * s + 10" style="font-size:8px" fill="var(--c-muted)" pointer-events="none">{{ c.k }}</text>
      </svg>
      <label class="ctl"><input type="checkbox" v-model="showCurve" /> show Z-curve (key order)</label>
    </div>
    <div class="bits">
      <div class="row"><span class="lab">x = {{ sel.x }}</span><span v-for="(b, i) in bitsOf(sel.x)" :key="'x' + i" class="bit x">{{ b }}</span></div>
      <div class="row"><span class="lab">y = {{ sel.y }}</span><span v-for="(b, i) in bitsOf(sel.y)" :key="'y' + i" class="bit y">{{ b }}</span></div>
      <div class="arrow">interleave ↓ (x bit, y bit) per level</div>
      <div class="row"><span class="lab">key</span>
        <template v-for="(d, i) in digits" :key="'d' + i"><span class="bit x">{{ d.xb }}</span><span class="bit y">{{ d.yb }}</span><span class="gap"></span></template>
        <span class="eq">= <b>{{ key }}</b></span>
      </div>
      <div class="row"><span class="lab">digits</span>
        <span v-for="(d, i) in digits" :key="'q' + i" class="digit">L{{ i + 1 }}: {{ d.d }}</span>
      </div>
      <p class="tiny muted">Each 2-bit digit selects a quadrant one level deeper (dashed squares). A cell at level ℓ therefore owns the
        <b>contiguous</b> key interval that shares its first ℓ digits. This is what makes a tree representable by sorted keys alone.</p>
    </div>
  </div>
</template>

<style scoped>
.mb { display: flex; flex-wrap: wrap; gap: 24px; align-items: flex-start; }
.bits { display: flex; flex-direction: column; gap: 8px; min-width: 280px; flex: 1; }
.row { display: flex; align-items: center; gap: 3px; font-family: var(--vp-font-family-mono); font-size: 0.85rem; }
.lab { width: 70px; font-weight: 700; color: var(--c-ink); font-size: 0.8rem; }
.bit { width: 22px; height: 24px; display: inline-flex; align-items: center; justify-content: center; border-radius: 3px; font-weight: 700; }
.bit.x { background: color-mix(in srgb, var(--c-update) 18%, white); color: var(--c-update); border: 1px solid var(--c-update); }
.bit.y { background: color-mix(in srgb, var(--c-view) 18%, white); color: #a65d0c; border: 1px solid var(--c-view); }
.gap { width: 6px; }
.eq { margin-left: 8px; }
.digit { border: 1px solid var(--c-line-strong); border-radius: 3px; padding: 0 6px; font-size: 0.75rem; }
.arrow { font-size: 0.72rem; color: var(--c-muted); margin-left: 70px; }
p { margin: 4px 0 0; }
</style>
