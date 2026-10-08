<script setup>
// Stream / event DAG of TreeView::build (tree_view.cu). Logical order, not to scale.
const lanes = [
  { id: 'part', y: 44, name: 'particleStream', sub: 'computeC' },
  { id: 'exec', y: 122, name: 'exec', sub: 'caller / graph' },
  { id: 'meta', y: 200, name: 'metadataStream', sub: 'computeA' },
  { id: 'leaf', y: 268, name: 'leafStream', sub: 'computeB' },
]
const Y = Object.fromEntries(lanes.map(l => [l.id, l.y]))
const H = 34
const boxes = [
  { lane: 'part', x0: 132, x1: 292, t: 'leaf begin index', s: 'DeviceScan::ExclusiveSum(N)', kind: 'cub' },
  { lane: 'exec', x0: 132, x1: 222, t: 'S1 classify', s: '1 thread / leaf' },
  { lane: 'meta', x0: 244, x1: 350, t: 'S2 level metadata', s: '1 thread' },
  { lane: 'exec', x0: 244, x1: 322, t: 'S3 compact', s: 'DeviceSelect', kind: 'cub' },
  { lane: 'exec', x0: 330, x1: 412, t: 'S4 sort level', s: 'RadixSort 8 bit', kind: 'cub' },
  { lane: 'exec', x0: 420, x1: 512, t: 'S5 layout keys', s: '+ RadixSort', kind: 'cub' },
  { lane: 'exec', x0: 536, x1: 612, t: 'materialize', s: 'm per level' },
  { lane: 'exec', x0: 636, x1: 736, t: 'S6 internals', s: '1 thread / internal' },
  { lane: 'leaf', x0: 636, x1: 736, t: 'S7 leaves', s: '1 thread / leaf' },
  { lane: 'part', x0: 770, x1: 876, t: 'particle mapping', s: 'upperBound(K, P)' },
]
// events, routed by hand through the gaps between boxes: [path, label, lx, ly, anchor]
const events = [
  ['M 112 105 C 112 60, 116 44, 128 44', 'fork', 104, 78, 'end'],
  ['M 177 139 C 177 190, 200 200, 240 200', 'classificationDone', 172, 176, 'end'],
  ['M 350 200 C 470 200, 548 185, 562 143', 'metadataDone', 470, 186, 'middle'],
  ['M 350 205 C 520 212, 674 214, 674 247', 'metadataDone', 470, 222, 'middle'],
  ['M 590 139 C 590 200, 660 210, 660 247', 'layoutDone', 600, 176, 'start'],
  ['M 292 40 H 606 Q 624 40 624 60 V 214 Q 624 232 644 247', 'leafPrefixDone', 450, 34, 'middle'],
  ['M 736 268 C 752 268, 752 190, 752 143', 'leafBuildDone', 758, 200, 'start'],
  ['M 736 275 C 790 275, 800 150, 810 65', '', 0, 0, 'start'],
  ['M 876 44 C 894 44, 896 80, 896 103', 'particleMappingDone', 900, 86, 'end'],
]
</script>

<template>
  <svg viewBox="0 0 910 296" width="100%">
    <defs>
      <marker id="tvs-a" markerWidth="8" markerHeight="8" refX="6" refY="4" orient="auto">
        <path d="M0,0 L8,4 L0,8 z" fill="var(--c-ink)" />
      </marker>
    </defs>
    <g v-for="l in lanes" :key="l.id">
      <line x1="104" :x2="900" :y1="l.y" :y2="l.y" stroke="var(--c-line)" stroke-width="1" stroke-dasharray="2 4" />
      <text x="0" :y="l.y - 1" style="font-size:11px; font-weight:700" fill="var(--c-ink)" class="mono">{{ l.name }}</text>
      <text x="0" :y="l.y + 12" style="font-size:9.5px" fill="var(--c-muted)">{{ l.sub }}</text>
    </g>

    <path v-for="(e, i) in events" :key="'e' + i" :d="e[0]" fill="none" stroke="var(--c-ink)" stroke-opacity="0.55"
      stroke-width="1.2" marker-end="url(#tvs-a)" />

    <g v-for="b in boxes" :key="b.t">
      <rect :x="b.x0" :y="Y[b.lane] - H / 2" :width="b.x1 - b.x0" :height="H" rx="6"
        :fill="b.kind === 'cub' ? 'color-mix(in srgb, var(--c-view) 8%, var(--c-surface))' : 'color-mix(in srgb, var(--c-view) 20%, var(--c-surface))'"
        stroke="var(--c-view)" stroke-width="1.4" />
      <text :x="(b.x0 + b.x1) / 2" :y="Y[b.lane] - 2" text-anchor="middle" style="font-size:11px; font-weight:700" fill="var(--c-ink)">{{ b.t }}</text>
      <text :x="(b.x0 + b.x1) / 2" :y="Y[b.lane] + 11" text-anchor="middle" style="font-size:8.5px" fill="var(--c-muted)">{{ b.s }}</text>
    </g>

    <!-- event labels -->
    <text v-for="(e, i) in events.filter(e => e[1])" :key="'l' + i" :x="e[2]" :y="e[3]" :text-anchor="e[4]"
      class="mono halo" style="font-size:8.5px" fill="var(--c-muted)">{{ e[1] }}</text>

    <!-- only-if-internal bracket -->
    <path d="M 244 102 v -5 H 612 v 5" fill="none" stroke="var(--c-muted)" />
    <text x="428" y="92" text-anchor="middle" class="halo" style="font-size:8.5px" fill="var(--c-muted)">only if #internal &gt; 0</text>
  </svg>
</template>

<style scoped>
.halo { paint-order: stroke; stroke: var(--c-bg); stroke-width: 3px; stroke-linejoin: round; }
</style>
