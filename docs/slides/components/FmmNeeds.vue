<script setup>
// K holds only the leaves; the FMM needs the explicit hierarchy -> TreeView reconstructs internal nodes.
const K = [0, 4, 8, 12, 16, 32, 36, 40, 44, 48, 64]
const MAXKEY = 64, X0 = 92, W = 500
const X = k => X0 + (k / MAXKEY) * W
const ROWY = [36, 104, 172], KY = 246
const lvl = r => Math.round(Math.log(MAXKEY / r) / Math.log(4))
const leaves = K.slice(0, -1).map((s, i) => ({ s, e: K[i + 1], level: lvl(K[i + 1] - s) }))
const internals = [{ s: 0, e: 64, level: 0 }, { s: 0, e: 16, level: 1 }, { s: 32, e: 48, level: 1 }]
const cx = n => X((n.s + n.e) / 2)
const parentOf = n => internals.find(p => p.level === n.level - 1 && p.s <= n.s && n.e <= p.e)
const children = [...leaves, ...internals].filter(n => n.level > 0)
</script>

<template>
  <svg viewBox="0 0 626 300" width="100%">
    <defs>
      <marker id="fn-a" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-view)" />
      </marker>
    </defs>

    <!-- row labels -->
    <text x="0" :y="ROWY[1] - 10" style="font-size:12px; font-weight:700" fill="var(--c-ink)">TreeView</text>
    <text x="0" :y="ROWY[1] + 5" style="font-size:9.5px" fill="var(--c-muted)">what the FMM</text>
    <text x="0" :y="ROWY[1] + 17" style="font-size:9.5px" fill="var(--c-muted)">traverses</text>
    <text x="0" :y="KY + 12" style="font-size:12px; font-weight:700" fill="var(--c-ink)">K</text>
    <text x="0" :y="KY + 26" style="font-size:9.5px" fill="var(--c-muted)">what adaptation</text>
    <text x="0" :y="KY + 38" style="font-size:9.5px" fill="var(--c-muted)">updates</text>
    <text v-for="(y, l) in ROWY" :key="'l' + l" x="70" :y="y + 4" style="font-size:10px" fill="var(--c-muted)">L{{ l }}</text>

    <!-- parent-child edges -->
    <line v-for="(n, i) in children" :key="'e' + i" :x1="cx(parentOf(n))" :y1="ROWY[n.level - 1] + 10"
      :x2="cx(n)" :y2="ROWY[n.level] - 9" stroke="var(--c-line-strong)" stroke-width="1.3" />

    <!-- leaves link down to their interval in K -->
    <line v-for="(n, i) in leaves" :key="'d' + i" :x1="cx(n)" :y1="ROWY[n.level] + 9" :x2="cx(n)" :y2="KY"
      stroke="var(--c-accent)" stroke-opacity="0.45" stroke-dasharray="2 3" />

    <!-- internal nodes: not stored in K, reconstructed -->
    <circle v-for="(n, i) in internals" :key="'i' + i" :cx="cx(n)" :cy="ROWY[n.level]" r="10"
      fill="color-mix(in srgb, var(--c-view) 22%, var(--c-surface))" stroke="var(--c-view)" stroke-width="1.8" stroke-dasharray="4 2" />
    <!-- leaves: exactly the intervals of K -->
    <rect v-for="(n, i) in leaves" :key="'s' + i" :x="cx(n) - 8" :y="ROWY[n.level] - 8" width="16" height="16"
      fill="color-mix(in srgb, var(--c-accent) 16%, var(--c-surface))" stroke="var(--c-accent)" stroke-width="1.5" />

    <!-- K bar -->
    <rect v-for="(n, i) in leaves" :key="'k' + i" :x="X(n.s)" :y="KY" :width="X(n.e) - X(n.s)" height="24"
      fill="color-mix(in srgb, var(--c-accent) 10%, var(--c-surface))" stroke="var(--c-accent)" stroke-width="1.2" />
    <text v-for="(k, i) in K" :key="'kl' + i" :x="X(k)" :y="KY + 38" text-anchor="middle" class="mono" style="font-size:9px" fill="var(--c-muted)">{{ k }}</text>

    <!-- reconstruct arrow -->
    <path :d="`M 604 ${KY + 4} C 612 ${KY - 70}, 612 ${ROWY[0] + 60}, 604 ${ROWY[0] + 20}`" fill="none"
      stroke="var(--c-view)" stroke-width="2" marker-end="url(#fn-a)" />
    <text x="600" :y="(KY + ROWY[0]) / 2 + 2" text-anchor="end" style="font-size:10.5px; font-weight:700" fill="var(--c-view)">reconstruct</text>
  </svg>
</template>
