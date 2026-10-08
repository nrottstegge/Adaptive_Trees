<script setup>
// What each pipeline ends with: Cornerstone (updateOctreeGpu + buildOctreeGpu) vs this work (adaptive update + TreeView).
// chip kinds: u = produced by the update step, b = produced by build / TreeView, in = input from the caller
const cols = [
  { key: 'part', t: 'particles' },
  { key: 'leaf', t: 'leaves' },
  { key: 'tree', t: 'node hierarchy' },
  { key: 'pnode', t: 'particles per node', only: true },
  { key: 'p2l', t: 'particle → leaf', only: true },
]
const lanes = [
  {
    name: 'Cornerstone', cite: true,
    steps: [{ t: 'keys + sort', k: 'in', sub: 'by the caller' }, { t: 'updateOctreeGpu', k: 'u' }, { t: 'buildOctreeGpu', k: 'b' }],
    out: {
      part: [{ t: 'keys', k: 'in', n: 'input only' }],
      leaf: [{ t: 'tree', n: 'K', k: 'u' }, { t: 'counts', n: 'N', k: 'u' }],
      tree: [
        { t: 'prefixes', k: 'b' }, { t: 'childOffsets', n: '8 siblings contiguous', k: 'b' },
        { t: 'parents', n: '1 per 8 siblings', k: 'b' }, { t: 'levelRange', k: 'b' },
        { t: 'internalToLeaf', k: 'b' }, { t: 'leafToInternal', k: 'b' },
      ],
      pnode: [], p2l: [],
    },
  },
  {
    name: 'This work',
    steps: [{ t: 'positions', k: 'in' }, { t: 'adaptive update', k: 'u' }, { t: 'TreeView', k: 'b' }],
    out: {
      part: [{ t: 'particleKeys_d', n: 'P', k: 'u' }, { t: 'perm_d', k: 'u' }],
      leaf: [{ t: 'cornerstone_d', n: 'K', k: 'u' }, { t: 'leafCounts_d', n: 'N', k: 'u' }],
      tree: [
        { t: 'sfcBoxIndex_d', k: 'b' }, { t: 'childIndex_d', n: 'siblings M apart', k: 'b' },
        { t: 'parentIndex_d', n: '1 per node', k: 'b' }, { t: 'levelOffset_d', k: 'b' },
        { t: 'hasBoxSplit_d', k: 'b' }, { t: 'boxDepth_d', k: 'b' },
      ],
      pnode: [{ t: 'particleBeginIndex_d', k: 'b' }, { t: 'particleCounts_d', k: 'b' }],
      p2l: [{ t: 'sfcParticleIndex_d', k: 'b' }],
    },
  },
]
</script>

<template>
  <div class="oc">
    <div></div>
    <div class="hd">pipeline</div>
    <div v-for="c in cols" :key="c.key" class="hd" :class="{ only: c.only }">{{ c.t }}</div>

    <template v-for="(l, li) in lanes" :key="l.name">
      <div class="lane" :class="{ ours: li === 1 }">{{ l.name }} <Cite v-if="l.cite" id="cornerstone" /></div>
      <div class="pipe">
        <template v-for="(st, si) in l.steps" :key="si">
          <div class="step" :class="st.k">{{ st.t }}<div v-if="st.sub" class="sub">{{ st.sub }}</div></div>
          <div v-if="si < l.steps.length - 1" class="arr">↓</div>
        </template>
      </div>
      <div v-for="c in cols" :key="c.key" class="cell" :class="{ only: c.only }">
        <div v-for="ch in l.out[c.key]" :key="ch.t" class="chip" :class="ch.k">
          <span class="mono">{{ ch.t }}</span><span v-if="ch.n" class="n">{{ ch.n }}</span>
        </div>
        <div v-if="!l.out[c.key].length" class="chip none">not computed</div>
      </div>
    </template>

    <div></div>
    <div class="legend">
      <span><i class="u"></i>update step</span>
      <span><i class="b"></i>build / TreeView</span>
      <span><i class="in"></i>input</span>
    </div>
  </div>
</template>

<style scoped>
.oc { display: grid; grid-template-columns: 92px 128px 0.85fr 0.85fr 1.35fr 1fr 0.9fr; gap: 6px 10px; font-size: 0.7rem; align-items: stretch; }
.hd { font-weight: 700; color: var(--fzj-blue); border-bottom: 2px solid var(--fzj-blue); padding-bottom: 3px; font-size: 0.74rem; }
.hd.only { color: var(--fzj-blue); }
.lane { font-weight: 700; font-size: 0.8rem; align-self: center; color: var(--c-muted); }
.lane.ours { color: var(--fzj-blue); }
.pipe { display: flex; flex-direction: column; align-items: stretch; justify-content: center; padding: 6px 0; }
.step { border: 1.5px solid; border-radius: 4px; padding: 3px 6px; text-align: center; font-weight: 700; font-size: 0.66rem; background: var(--c-surface); }
.step .sub { font-weight: 400; font-size: 0.56rem; color: var(--c-muted); }
.step.u { border-color: var(--c-update); background: color-mix(in srgb, var(--c-update) 9%, white); }
.step.b { border-color: var(--c-view); background: color-mix(in srgb, var(--c-view) 12%, white); }
.step.in { border-color: var(--c-line-strong); border-style: dashed; }
.arr { text-align: center; color: var(--c-muted); line-height: 1; font-size: 0.7rem; }
.cell { display: flex; flex-wrap: wrap; align-content: center; gap: 4px; padding: 6px 4px; border-radius: 4px; }
.cell.only { background: color-mix(in srgb, var(--fzj-lightblue) 22%, transparent); }
.chip { display: inline-flex; flex-direction: column; border: 1.5px solid; border-radius: 3px; padding: 2px 6px; background: white; line-height: 1.2; }
.chip .mono { font-size: 0.64rem; font-weight: 600; }
.chip .n { font-size: 0.55rem; color: var(--c-muted); }
.chip.u { border-color: var(--c-update); }
.chip.b { border-color: var(--c-view); }
.chip.in { border-color: var(--c-line-strong); border-style: dashed; color: var(--c-muted); }
.chip.none { border: 1.5px dashed var(--c-line); color: var(--c-muted); font-style: italic; font-size: 0.6rem; background: transparent; }
.legend { grid-column: 3 / -1; display: flex; gap: 16px; font-size: 0.62rem; color: var(--c-muted); padding-top: 2px; }
.legend i { display: inline-block; width: 12px; height: 9px; border: 1.5px solid; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
.legend i.u { border-color: var(--c-update); }
.legend i.b { border-color: var(--c-view); }
.legend i.in { border-color: var(--c-line-strong); border-style: dashed; }
</style>
