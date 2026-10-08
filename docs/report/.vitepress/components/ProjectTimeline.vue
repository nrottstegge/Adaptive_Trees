<script setup>
import { computed, ref } from 'vue'
import { useData } from 'vitepress'
// Commit timeline. The entries live in the front matter of content/index.md (key: timeline),
// so they can be edited next to the text.
const { frontmatter } = useData()
const items = computed(() => (frontmatter.value.timeline || []).map((t, i) => ({ ...t, i, d: new Date(t.date) })))
const themes = {
  setup: { c: 'var(--c-line-strong)', n: 'setup & infrastructure' },
  criterion: { c: 'var(--c-oct-nf)', n: 'NFCount criterion' },
  views: { c: 'var(--c-view)', n: 'TreeView / FMM layout' },
  reuse: { c: 'var(--c-good)', n: 'reuse & caching' },
  memory: { c: 'var(--c-bad)', n: 'memory & primitives' },
  graph: { c: 'var(--c-update)', n: 'CUDA Graphs' },
  binary: { c: 'var(--c-kd-leaf)', n: 'binary tree' },
}
const t0 = computed(() => Math.min(...items.value.map(t => +t.d)))
const t1 = computed(() => Math.max(...items.value.map(t => +t.d)))
const W = 800, X0 = 20
const x = d => X0 + ((+d - t0.value) / Math.max(t1.value - t0.value, 1)) * (W - 2 * X0)
const placed = computed(() => {
  const count = {}
  return items.value.map(t => { const k = t.date; count[k] = (count[k] || 0) + 1; return { ...t, x: x(t.d), y: 70 - (count[k] - 1) * 15 } })
})
const sel = ref(null)
const filter = ref('')
const cur = computed(() => (sel.value != null ? items.value[sel.value] : null))
const months = computed(() => {
  const out = []
  const d = new Date(t0.value); d.setDate(1)
  while (+d <= t1.value) { d.setMonth(d.getMonth() + 1); if (+d > t0.value && +d <= t1.value) out.push(new Date(d)) }
  return out
})
const weekTicks = computed(() => { const out = []; for (let t = t0.value; t <= t1.value; t += 7 * 864e5) out.push(new Date(t)); return out })
const fmt = d => d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })
</script>

<template>
  <div class="tl">
    <div class="ctl">
      <button class="pill" :class="{ on: !filter }" @click="filter = ''">all</button>
      <button v-for="(th, k) in themes" :key="k" class="pill" :class="{ on: filter === k }" @click="filter = filter === k ? '' : k">
        <span class="sw" :style="{ background: th.c }"></span>{{ th.n }}
      </button>
    </div>
    <svg :viewBox="`0 0 ${W} 110`" width="100%" style="min-width: 620px">
      <line :x1="X0" :x2="W - X0" y1="86" y2="86" stroke="var(--c-ink)" />
      <g v-for="w in weekTicks" :key="+w">
        <line :x1="x(w)" :x2="x(w)" y1="83" y2="89" stroke="var(--c-ink)" />
        <text :x="x(w)" y="102" text-anchor="middle" style="font-size:9.5px" fill="var(--c-muted)">{{ fmt(w) }}</text>
      </g>
      <g v-for="m in months" :key="'m' + +m">
        <line :x1="x(m)" :x2="x(m)" y1="6" y2="86" stroke="var(--c-line)" stroke-dasharray="3 3" />
        <text :x="x(m) + 4" y="12" style="font-size:10px; font-weight:700" fill="var(--c-muted)">{{ m.toLocaleDateString('en-GB', { month: 'long' }) }}</text>
      </g>
      <g v-for="t in placed" :key="t.i" style="cursor: pointer" @click="sel = t.i" @mouseenter="sel = t.i">
        <circle :cx="t.x" :cy="t.y" :r="sel === t.i ? 7.5 : t.key ? 6.5 : 5"
          :fill="!filter || filter === t.theme ? (themes[t.theme]?.c || 'var(--c-ink)') : 'var(--c-empty)'"
          :stroke="sel === t.i ? 'var(--c-ink)' : 'white'" stroke-width="1.6" />
        <text v-if="t.key" :x="t.x" :y="t.y + 3" text-anchor="middle" style="font-size:7px; font-weight:700" fill="white" pointer-events="none">★</text>
      </g>
    </svg>
    <div class="detail" v-if="cur">
      <div class="dh">
        <span class="sw" :style="{ background: themes[cur.theme]?.c }"></span>
        <b>{{ cur.title }}</b>
        <span class="commit">{{ cur.hash }}</span>
        <span class="muted tiny">{{ fmt(cur.d) }} · {{ themes[cur.theme]?.n }}</span>
        <span class="grow"></span>
        <button class="btn" @click="sel = Math.max(0, sel - 1)">◀</button>
        <button class="btn" @click="sel = Math.min(items.length - 1, sel + 1)">▶</button>
      </div>
      <div class="small">{{ cur.text }}</div>
      <div v-if="cur.section" class="tiny"><a :href="'#' + cur.section">→ read the section</a></div>
    </div>
    <div class="detail muted small" v-else>Hover or click a commit. ★ = milestones that changed the performance picture.</div>
  </div>
</template>

<style scoped>
.tl { display: flex; flex-direction: column; gap: 6px; }
.detail { border: 1px solid var(--c-line); border-radius: 6px; padding: 8px 12px; min-height: 92px; display: flex; flex-direction: column; gap: 4px; }
.dh { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.grow { flex: 1; }
</style>
