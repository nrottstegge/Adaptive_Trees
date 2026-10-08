---
theme: default
title: Adaptive Trees on a GPU
favicon: data:image/png;base64,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
info: |
  Adaptive Trees on a GPU — Efficient GPU-aware Adaptive Tree Algorithm
  for the Fast Multipole Method.
colorSchema: light
canvasWidth: 1100
fonts:
  sans: PT Sans,Noto Sans
  mono: JetBrains Mono
transition: fade
mdc: true
layout: fzj-title
headerImage: header_octree.svg
author: Nils Rottstegge | Jülich Supercomputing Centre (JSC)
date: 05. October 2026

defaults:
  layout: fzj-content
  aspectRatio: 16/9
---

# Adaptive Trees on a GPU
## Efficient GPU-aware Adaptive Tree Algorithm for the Fast Multipole Method

---

# The Fast Multipole Method needs a hierarchy

<div class="grid grid-cols-[0.8fr_1.1fr_1.1fr] gap-6 items-center mt-2">
  <div class="flex flex-col items-center">
    <ToyTree dist="cluster" mode="adaptive" :size="190" :threshold="18" accent="var(--c-accent)" />
    <div class="tiny muted mt-1">particles + spatial hierarchy</div>
  </div>
  <FmmOperators />
  <div class="small">
    <table class="metrics">
      <tbody>
        <tr><td style="color: var(--c-op-up); font-weight: 700; white-space: nowrap">P2M · M2M</td><td>↑ upward: particles → multipoles → parents</td></tr>
        <tr><td style="color: var(--c-op-far); font-weight: 700; white-space: nowrap">M2L</td><td>far field between well-separated nodes</td></tr>
        <tr><td style="color: var(--c-op-down); font-weight: 700; white-space: nowrap">L2L · L2P</td><td>↓ downward: parents → children → particles</td></tr>
        <tr><td style="color: var(--c-op-near); font-weight: 700; white-space: nowrap">P2P</td><td>direct near field between neighbouring leaves</td></tr>
      </tbody>
    </table>
  </div>
</div>

<div class="msg mt-4">

FMM <Cite id="fmm" /> performance depends strongly on **how the spatial hierarchy represents the particle distribution**.

</div>

<!--
Particles → leaves → upward pass → root → downward pass → leaves → particles.
Near field is evaluated directly between neighbouring leaves; far field goes through the hierarchy.
-->

<SlideRefs :ids="['fmm']" />

---

# Two extremes: dense and sparse trees

<div class="grid grid-cols-2 gap-10 mt-2">
<div>
  <div class="flex items-center gap-2 mb-2"><b>Dense tree</b><span class="pill">regular · wasteful</span></div>
  <div class="flex flex-col items-start gap-1">
    <ToyTree dist="dense-core" mode="dense" :denseLevel="4" :size="190" shade-empty stats accent="var(--c-accent)" :dot="1.2" />
    <div class="illus">toy 2D · grey = empty cells</div>
  </div>
  <div class="small mt-1">

- uniform subdivision, GPU-friendly structure
- empty regions still create nodes and work

</div>
</div>
<div>
  <div class="flex items-center gap-2 mb-2"><b>Sparse tree</b><span class="pill">compact · irregular</span></div>
  <div class="flex flex-col items-start gap-1">
    <ToyTree dist="dense-core" mode="sparse" :denseLevel="4" :size="190" stats accent="var(--c-accent)" :dot="1.2" />
    <div class="illus">toy 2D · only occupied cells are stored</div>
  </div>
  <div class="small mt-1">

- follows the particles closely
- pointer chasing, scattered memory, dynamic allocation, divergent updates

</div>
</div>
</div>

<div class="msg mt-5 small">

Dense trees waste **work and memory**; sparse trees waste **GPU efficiency**. We want a hierarchy between the two.

</div>


---

# Adaptive trees: the middle ground

<div class="grid grid-cols-[auto_1fr] gap-12 items-center mt-3">
  <div class="flex flex-col items-center gap-1">
    <ToyTree dist="cluster" mode="adaptive" :size="300" :threshold="14" stats depth-fill accent="var(--c-accent)" label="large cells where possible, small cells where necessary" />
    <div class="illus">toy 2D · shade = depth</div>
  </div>
  <div>

- refine only where resolution is needed
- keeps the hierarchy, skips empty / low-work regions
- more regular than a pointer-based sparse tree
- representable with **contiguous arrays** → GPU-friendly

<div class="msg small mt-6">

The goal is not simply to minimise nodes — it is a hierarchy that **balances FMM work** while keeping a **GPU-friendly representation**.

</div>
  </div>
</div>

---

# From simple coordinates to chasing the <span style="text-transform: none">μs</span> per tree update
## Cornerstone representation · TreeView · GPU optimisations

::center::

<div style="width: 100%; height: 250px"><FzjTitleArt /></div>

---

# From pointers to a sorted key space

<div class="grid grid-cols-[auto_1fr] gap-12 items-center mt-2">
  <MortonGrid :size="250" />
  <div>

<div class="flex flex-col gap-3 small">
  <div class="card"><b>1 · Quantise</b> coordinates onto an integer grid</div>
  <div class="card"><b>2 · Encode</b> by interleaving coordinate bits → Morton key</div>
  <div class="card"><b>3 · Sort</b> particles by key → <span class="mono">P = [p₀, p₁, …, p<sub>N−1</sub>]</span></div>
</div>

<div class="msg mt-5 small">

Spatially close particles are usually close in key space → spatial queries become **operations on sorted arrays**.

</div>

<div class="illus mt-2">2D Z-order shown for intuition; the implementation uses 3D Morton keys.</div>
  </div>
</div>

---
clicks: 3
---

# The Cornerstone array K

<div class="grid grid-cols-[1fr_auto] gap-8 items-start">
  <div class="small">

Represent the adaptive leaves only by their **SFC boundaries** (Cornerstone <Cite id="cornerstone" />):

<div class="mono mt-2 mb-2" style="font-size: 0.95rem">K = [k₀, k₁, …, k<sub>L</sub>]  ·  leaf i = [K[i], K[i+1])</div>

- K has **#leaves + 1** entries
- short interval ⇔ deep, fine leaf; long interval ⇔ coarse leaf
- no pointers, no explicit internal nodes

</div>
  <div class="card tiny" style="min-width: 190px">
    <h3>Notation</h3>
    <div class="grid grid-cols-[28px_1fr] gap-y-1">
      <b class="mono">P</b><span>sorted particle SFC keys</span>
      <b class="mono">K</b><span>Cornerstone leaf boundaries</span>
      <b class="mono">N</b><span>particles per leaf</span>
      <b class="mono">NF</b><span>near-field work estimate</span>
    </div>
  </div>
</div>

<div class="mt-2 flex justify-center">
  <KeySpace row proportional :size="170" :barWidth="540" :level="$clicks < 3 ? $clicks : -1" />
</div>
<div class="illus text-center">toy 2D quadtree, keys shown at coarse resolution (0 … 64) · hover a leaf</div>

<div class="msg mt-2 small">

The adaptive tree becomes an **ordered partition of SFC key space**.

</div>

<SlideRefs :ids="['cornerstone']" />

---

# Particle count alone is not enough for FMM

<div class="grid grid-cols-[auto_1fr] gap-8 items-center mt-1">
  <div class="small" style="max-width: 270px">

Near-field cost depends on the leaf **and its neighbourhood**.

<div class="card mono mt-2 mb-3 whitespace-nowrap" style="font-size: 0.72rem; padding: 0.5rem 0.6rem">
NF<sub>i</sub> = N<sub>i</sub> · ( N<sub>i</sub> + Σ<sub>j∈nb(i)</sub> N<sub>j</sub> )
</div>

<div class="flex flex-col items-start gap-1">
  <NeighborStencil />
  <div class="tiny muted">3D: leaf + 26 same-level neighbours</div>
</div>

</div>
  <NFView />
</div>

<div class="grid grid-cols-2 gap-6 mt-4">
  <div class="msg small" style="border-color: var(--c-oct-leaf)"><b>LeafCount</b> adapts to particle <b>density</b>.</div>
  <div class="msg small" style="border-color: var(--c-oct-nf)"><b>NFCount</b> adapts to expected <b>near-field work</b>.</div>
</div>

<!--
Same toy tree in both panels. A leaf with few particles next to a cluster is light on the left but dark on the right.
The neighbour counts are taken over same-level cells, independent of how the tree is refined there.
-->

---

# The adaptive update loop

<div class="mt-1 flex justify-center">
  <div style="width: 840px"><UpdateLoop /></div>
</div>

<div class="grid grid-cols-[1fr_1.4fr] gap-6 mt-1 items-center">
  <div class="flex gap-2 flex-wrap tiny">
    <span class="pill"><span class="sw" style="background: var(--c-update)"></span>tree update phase</span>
    <span class="pill"><span class="sw" style="background: var(--c-view)"></span>TreeView construction</span>
  </div>
  <div class="msg small">

Every step is a **bulk parallel array primitive** <Cite id="cornerstone" /> — no pointers, no per-node host logic.

</div>
</div>


<SlideRefs :ids="['cornerstone']" />


---

# What the FMM actually needs

<div class="flex flex-col items-center mt-1">
  <div style="width: 690px"><FmmNeeds /></div>
  <div class="flex gap-6 tiny items-center">
    <span class="flex items-center gap-1"><span class="sw" style="background: color-mix(in srgb, var(--c-accent) 16%, white); border: 1.5px solid var(--c-accent)"></span>leaf = one interval of K</span>
    <span class="flex items-center gap-1"><span class="sw" style="border-radius: 99px; background: color-mix(in srgb, var(--c-view) 22%, white); border: 1.5px dashed var(--c-view)"></span>internal node — not stored in K</span>
  </div>
</div>

<div class="msg mt-3 small">

**TreeView** reconstructs the missing internal nodes from K — the tree is rebuilt on demand, never maintained with pointers.

</div>

---

# TreeView construction

<div class="grid grid-cols-[auto_1fr] gap-12 items-center mt-4">
  <Flow :steps="[
    { t: 'Cornerstone K', tone: 'accent' },
    'classify leaves & boundaries',
    'per-level node counts',
    'order internal nodes',
    'write all nodes',
    { t: 'TreeView', tone: 'view' },
  ]" />
  <div class="flex flex-col gap-3 small">
    <div class="card"><b>1. Sizes are known up front</b><div class="muted tiny mt-1">L leaves ⇒ (L − 1)/(2<sup>b</sup> − 1) internal nodes</div></div>
    <div class="card"><b>2. Internal nodes are read off K</b><div class="muted tiny mt-1">each one sits at exactly one boundary between two leaves</div></div>
    <div class="card"><b>3. Every node is written directly to its final index</b><div class="muted tiny mt-1">flat, level-ordered arrays — no pointers, no host readback</div></div>
  </div>
</div>

<div class="msg mt-6 small">

Keep K for adaptation; **rebuild** the explicit FMM hierarchy from it in a few parallel passes.

</div>


---

# What we compute vs. Cornerstone

<OutputCake />

<div class="msg mt-3 small">

Same input, same two timed phases — this work additionally delivers **NF**, **per-node particle ranges** and the **particle → leaf map**.

</div>

<SlideRefs :ids="['cornerstone']" />

---

<script setup>
const base = import.meta.env.BASE_URL
</script>

# Runtime across implementations

<div class="flex justify-center mt-1">
  <div style="width: 620px"><ZoomFig :src="`${base}bench/cluster_implementation_runtime.webp`" height="395px" title="Cluster: tree update + view construction per step" /></div>
</div>

---
clicks: 2
---

<script setup>
const base = import.meta.env.BASE_URL
</script>

# Interactive tree viewer

<ViewerTour :step="$clicks" :scenes="[
  { url: base + 'viewer/scene-export-9.html', dataset: 'Flyby', short: 'first snapshot', note: 'very beginning of the run', particles: '512 002' },
  { url: base + 'viewer/scene-export-8.html', dataset: 'Flyby', short: 'evolved', note: 'same run, later snapshot — the tree follows the particles', particles: '512 002', particlesNote: 'as in the first snapshot' },
  { url: base + 'viewer/scene-export-6.html', dataset: 'Dense halo', short: 'subsample', note: 'subsample of the halo dataset', particles: '25 600 000', particlesNote: 'full dataset; a subsample is shown' },
]">
  <div class="msg tiny">

Aggregate metrics can hide **why** two trees differ in size or runtime — the viewer shows where.

</div>
</ViewerTour>


---
clicks: 1
---

<script setup>
const base = import.meta.env.BASE_URL
</script>

# Octree benchmarks

<BenchPair :step="$clicks" setup="1" :datasets="[
  { key: 'coulomb_explosion', name: 'Coulomb explosion', gif: base + 'gifs/coulomb_explosion.mp4', particles: '114 537' },
  { key: 'flyby', name: 'Flyby', gif: base + 'gifs/flyby.mp4', particles: '512 002' },
  { key: 'cluster_simulation', name: 'Cluster simulation', gif: base + 'gifs/cluster_simulation.mp4', particles: '10 000' },
]" :variants="[
  { label: 'Octree / LeafCount', color: 'var(--c-oct-leaf)', file: k => base + 'bench/' + k + '_octree_leafcount.webp' },
  { label: 'Octree / NFCount', color: 'var(--c-oct-nf)', file: k => base + 'bench/' + k + '_octree_nfcount.webp' },
]" />


<SlideRefs :ids="['benchmarking']" />

---

# The full pipeline
## Adaptive tree + FMM (fmsolvr-cuda), end to end

::center::

<div style="width: 100%; height: 250px"><FzjTitleArt /></div>

---

<script setup>
const base = import.meta.env.BASE_URL
</script>

# Full pipeline runtime: adaptive octree + FMM

<div class="flex justify-center">
  <div style="width: 440px"><ZoomFig :src="`${base}bench/full_pipeline_dense_vs_newest.webp`" height="395px" title="Full pipeline: dense tree vs. newest adaptive tree" /></div>
</div>

---

# But there is one more thing …
## A binary 3D tree — KDTree3D

::center::

<div style="width: 100%; height: 250px"><FzjTitleArt kind="kd" /></div>

---

# KDTree3D: a binary alternative to the octree

<div class="grid grid-cols-[1.25fr_1fr] gap-8 items-center mt-1">
  <KdSplit />
  <div class="small">

- **2 children** per split instead of 8 — <span class="mono">LevelBits = 1</span>
- split the **longest axis** of the current box at its midpoint <Cite id="kdlongest" />
- boxes become **rectangular** (slabs, columns) between octree levels
- refines one direction at a time → can avoid cells the octree creates in directions that need no refinement
- ≈ 3 binary levels per octree level → **deeper** trees
- linear (implicit) kd-tree <Cite id="poirrier" />: same machinery as our octree — binary SFC keys, same K format, same TreeView code (<span class="mono">TreeView&lt;1&gt;</span>)

</div>
</div>


<SlideRefs :ids="['kdlongest', 'poirrier']" />




---
clicks: 6
---

# The binary Cornerstone array K

<div class="small">

Same K format — every split halves the **longest side** of the box and the key interval: **1 key bit per level** (octree: 3 bits).

</div>

<div class="mt-3 flex justify-center">
  <KeySpace proportional binary :aspect="2" accent="var(--c-kd-leaf)" :size="140" :barWidth="860" :level="$clicks < 6 ? $clicks : -1" />
</div>
<div class="illus text-center">toy 2D binary tree on a 2 : 1 domain · every split halves the current longest side · keys at coarse resolution (0 … 64) · hover a leaf</div>

---

<script setup>
const base = import.meta.env.BASE_URL
</script>

# KDTree3D benchmarks

<BenchPair :step="$clicks" setup="1" :datasets="[
  { key: 'coulomb_explosion', name: 'Coulomb explosion', gif: base + 'gifs/coulomb_explosion.mp4', particles: '114 537' },
  { key: 'flyby', name: 'Flyby', gif: base + 'gifs/flyby.mp4', particles: '512 002' },
  { key: 'cluster_simulation', name: 'Cluster simulation', gif: base + 'gifs/cluster_simulation.mp4', particles: '10 000' },
]" :variants="[
  { label: 'Octree vs KDTree3D', color: 'var(--c-ink)', file: k => base + 'bench/' + k + '_octree_vs_kdtree3d.webp' },
]" />


<SlideRefs :ids="['benchmarking']" />
---

# Takeaways

<div class="grid grid-cols-2 gap-8">
  <div class="card kpi">
    <div class="kpi-num">×2.23</div>
    <div><b>faster than Cornerstone</b> — tree update + TreeView per step</div>
    <div class="tiny muted">Cluster · LeafCount · 0.301 → 0.135 ms · median per step</div>
  </div>
  <div class="card kpi">
    <div class="kpi-num">×4.79</div>
    <div><b>faster full pipeline</b> (tree + FMM) than a dense tree</div>
    <div class="tiny muted">coulomb_early · NFCount · mean time per step</div>
  </div>
</div>

<div class="grid grid-cols-2 gap-x-8 gap-y-3 mt-5 small">
  <div class="card"><b>1 · Adaptive trees</b> — a compromise between dense regular trees and irregular sparse structures.</div>
  <div class="card"><b>2 · Cornerstone</b> — adaptation as operations on sorted SFC arrays <span class="mono">P</span>, <span class="mono">K</span>: GPU-friendly by construction.</div>
  <div class="card"><b>3 · NFCount</b> — refinement driven by expected near-field work, not particle count alone.</div>
  <div class="card"><b>4 · TreeView</b> — bridges the compact K and the explicit hierarchy for upward/downward passes.</div>
  <div class="card"><b>5 · GPU optimisations</b> — cooperative groups, dirty reuse, streams, fixed-capacity buffers, CUDA Graphs make repeated updates practical.</div>
  <div class="card"><b>6 · Octree vs KDTree3D</b> — different tradeoffs depending on the particle distribution.</div>
</div>

<div class="text-center mt-5 muted">Questions?</div>


---

# References

<References />
