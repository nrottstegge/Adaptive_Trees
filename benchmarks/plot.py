#!/usr/bin/env python3
"""All plots (section 9) from data/*.csv -> plots/*.png (300 dpi), *.webp, *.pdf."""
import os
import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker
import numpy as np
import pandas as pd

import benchlib as bl
from benchlib import BENCH, DATA

PLOTS = (BENCH / os.environ.get("PLOTS_DIR", "plots")).resolve()
# Forschungszentrum Jülich palette
FZJ = dict(blue="#006E92", lightblue="#8BBBD9", green="#B1C800", yellow="#FFCC00", orange="#EB5F01",
           red="#CC071E", darkgray="#3B3B3B", lightgray="#DADADA")
C = dict(octree_leafcount=FZJ["blue"], octree_nfcount=FZJ["orange"], kdtree3d_leafcount=FZJ["red"],
         tree=FZJ["lightblue"], view=FZJ["yellow"], total=FZJ["darkgray"], far=FZJ["green"], near=FZJ["darkgray"],
         nodes=FZJ["blue"], leaves=FZJ["green"], common=FZJ["lightgray"], lists=FZJ["orange"],
         escaped=FZJ["red"], active=FZJ["blue"], slots=FZJ["darkgray"])
CFG = dict(octree_leafcount="Octree / LeafCount", octree_nfcount="Octree / NFCount",
           kdtree3d_leafcount="KDTree3D / LeafCount")
SLIDE = dict(coulomb_explosion="Coulomb explosion", flyby="Flyby", dense_halo="Dense halo", nacl="NaCl", stmv="STMV",
             cluster="Cluster (snapshots 0–52)", cluster_full="Cluster (all 201 snapshots, with escapes)")
ORDER = list(SLIDE)
IMPL_ORDER = [d for d in ORDER if d != "cluster_full"]  # cluster_full is v3-only
VERSION_STYLE = {  # (colour, hatch) per bar in the implementation plots
    ("cstone", "octree_leafcount"): (FZJ["darkgray"], ""), ("v3", "octree_leafcount"): (FZJ["blue"], ""),
    ("v1", "octree_nfcount"): (FZJ["yellow"], ""), ("v2", "octree_nfcount"): (FZJ["orange"], ""),
    ("v3", "octree_nfcount"): (FZJ["red"], "")}
BAR_LABEL = {("cstone", "octree_leafcount"): "Cornerstone\nLeafCount", ("v3", "octree_leafcount"): "v3\nLeafCount",
             ("v1", "octree_nfcount"): "v1\nNFCount", ("v2", "octree_nfcount"): "v2\nNFCount",
             ("v3", "octree_nfcount"): "v3\nNFCount"}

plt.rcParams.update({"font.size": 9, "axes.titlesize": 10, "axes.spines.top": False, "axes.spines.right": False})


def env_text():
    f = BENCH / "env" / "environment.txt"
    info = dict(re.findall(r"^(\w[\w ]*): (.*)$", f.read_text(), re.M)) if f.exists() else {}
    gpu = info.get("gpu", "GPU ?").split(",")[0]
    cuda = re.search(r"release ([\d.]+)", info.get("nvcc", ""))
    return f"{gpu}, CUDA {cuda.group(1) if cuda else '?'}, measured {info.get('date', '?')[:10]}"


def protocol():
    s = bl.read_csv(DATA / "run_status.csv") if bl.csv_path(DATA / "run_status.csv").exists() else pd.DataFrame()
    w = int(s.W.max()) if len(s) and s.W.max() > 0 else int(os.environ.get("W", 3))
    return s, w


def note(fig, text):
    fig.text(0.01, 0.005, text, fontsize=6.5, color="#444444", va="bottom", ha="left", wrap=True)


def save(fig, stem):
    (PLOTS / stem).parent.mkdir(parents=True, exist_ok=True)
    for ext in ("png", "webp", "pdf"):
        fig.savefig(PLOTS / f"{stem}.{ext}", dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"  plots/{stem}.(png|webp|pdf)")


def ci_note(w, runs_text, pooled):
    how = "resampling whole runs (steps of one run are not independent)" if pooled else "over runs"
    return (f"{runs_text}; each run = full series in a fresh process, W={w} warm-up runs discarded. "
            f"Error bars/bands: 95% BCa bootstrap CI of the median (scipy, 10,000 resamples, fixed seed), {how}. "
            f"No mean±std shown. {env_text()}.")


def r_range(status, **sel):
    s = status[(status.status == "ok")] if len(status) else status
    for k, v in sel.items():
        s = s[s[k] == v]
    if s.empty:
        return "R runs"
    lo, hi = int(s.R.min()), int(s.R.max())
    return f"R={lo} runs" if lo == hi else f"R={lo}–{hi} runs"


def integer_x(fig):
    for a in fig.axes:
        a.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))


# ------------------------------------------------------------------ plot 1 --
def implementation_runtime():
    f = bl.csv_path(DATA / "implementation_runtime_summary.csv")
    if not f.exists():
        return
    d = bl.read_csv(f)
    status, w = protocol()
    dss = [x for x in IMPL_ORDER if x in set(d.dataset)]
    fig, ax = plt.subplots(figsize=(11.5, 4.6))
    width = 0.16
    vals = d.median_total_ms.dropna()
    log = len(vals) and vals.max() / vals.min() > 10
    for j, (v, c) in enumerate(VERSION_STYLE):
        color, hatch = VERSION_STYLE[(v, c)]
        for i, ds in enumerate(dss):
            r = d[(d.dataset == ds) & (d.version == v) & (d.config == c)]
            x = i + (j - 2) * width
            if r.empty or np.isnan(r.median_total_ms.iloc[0]):
                st = r.status.iloc[0] if len(r) else "not run"
                ax.text(x, ax.get_ylim()[0] if log else 0, f" {v}: n/a ({st})", ha="center", va="bottom",
                        fontsize=5.5, rotation=90, color="#777777")
                continue
            r = r.iloc[0]
            ax.bar(x, r.median_total_ms, width, color=color, hatch=hatch, edgecolor=color,
                   label=f"{v} · {CFG[c]}" if i == 0 else None)
            ax.errorbar(x, r.median_total_ms, yerr=[[r.median_total_ms - r.ci_low], [r.ci_high - r.median_total_ms]],
                        color="black", capsize=2, lw=0.8)
            if not np.isnan(r.speedup_vs_cstone):
                ax.text(x, r.ci_high * (1.08 if log else 1.02), f"×{r.speedup_vs_cstone:.2g}", ha="center",
                        va="bottom", fontsize=6.5, rotation=90)
    if log:
        ax.set_yscale("log")
    ax.set_xticks(range(len(dss)), [SLIDE[x] for x in dss])
    ax.set_ylabel("median total time per update step [ms]")
    ax.set_title("Tree update + view construction per step (×: speed-up vs. Cornerstone)")
    ax.legend(fontsize=7, ncol=1, frameon=False, loc="upper left", bbox_to_anchor=(1.01, 1.0))
    note(fig, "Bars: median total_ms per update step, pooled over all timed snapshots; " +
         ci_note(w, r_range(status), True) +
         " Cornerstone: direct path (SFC keys + sort + converged rebalance; view = buildOctreeGpu); v1/v2 direct, "
         "v3 CUDA graph. Octree/LeafCount bars compare different tree criteria than the NFCount bars.")
    fig.subplots_adjust(bottom=0.2, right=0.8)
    save(fig, "implementation_runtime")


# ----------------------------------------------------------- plots 2 and 3 --
def pick_fastest(summary, ds, cfg):
    p = summary[(summary.snapshot == "pooled") & (summary.dataset == ds) & (summary.config == cfg) &
                (summary.metric == "total_ms")]
    return None if p.empty else p.sort_values("median").iloc[0].version


def series(summary, v, cfg, ds, metric):
    s = summary[(summary.version == v) & (summary.config == cfg) & (summary.dataset == ds) &
                (summary.metric == metric) & (summary.snapshot != "pooled") & (summary.snapshot != "initial")]
    return s.assign(frame_id=s.frame_id.astype(float)).sort_values("frame_id")


def structure(steps, v, cfg, ds):
    s = steps[(steps.version == v) & (steps.config == cfg) & (steps.dataset == ds)]
    return s[s.run == s.run.min()].sort_values("frame_id")


def line(ax, x, y, color, label=None, **kw):
    ax.plot(x, y, color=color, label=label, marker="o" if len(x) <= 20 else None, ms=3, lw=1.2, **kw)


def runtime_panel(ax, summary, v, cfg, ds):
    tr, vw, to = (series(summary, v, cfg, ds, m) for m in ("tree_update_ms", "view_ms", "total_ms"))
    x = to.frame_id.to_numpy()
    if len(x) <= 5:  # single datasets: one or few timed steps -> stacked bars
        pos = np.arange(len(x))
        ax.bar(pos, tr["median"], width=0.5, color=C["tree"], label="tree update (median)")
        ax.bar(pos, vw["median"], width=0.5, bottom=tr["median"].to_numpy(), color=C["view"], label="view (median)")
        ax.errorbar(pos + 0.33, to["median"], yerr=[to["median"] - to.ci_low, to.ci_high - to["median"]], fmt="o",
                    color=C["total"], ms=3, capsize=3, label="total (median, 95% CI)")
        ax.set_xticks(pos, [f"update to snapshot {int(f)}" for f in x])
        ax.set_xlim(-0.6, len(x) - 0.2)
        ax.set_ylim(0, float(to.ci_high.max()) * 1.35)
    else:
        ax.stackplot(x, tr["median"], vw["median"], colors=[C["tree"], C["view"]], alpha=0.85,
                     labels=["tree update (median)", "view (median)"])
        ax.fill_between(x, to.ci_low, to.ci_high, color=C["total"], alpha=0.18, lw=0)
        ax.plot(x, to["median"], color=C["total"], lw=0.8, label="total (median, 95% CI band)")
    ax.set_ylabel("time per step [ms]")
    ax.set_title("Runtime (GPU events)")
    ax.legend(fontsize=6.5, frameon=False, loc="upper left", ncol=3 if len(x) <= 5 else 1)


def snapshot_figure(summary, steps, status, w, v, cfg, ds, stem):
    st = structure(steps, v, cfg, ds)
    x = st.frame_id.to_numpy()
    col = C[cfg]
    fig, axs = plt.subplots(2, 3, figsize=(13, 6.8))
    a = axs[0, 0]
    line(a, x, st.num_nodes, C["nodes"], "nodes")
    line(a, x, st.num_leaves, C["leaves"], "leaves")
    a.set_title("Tree size"); a.set_ylabel("count"); a.legend(fontsize=7, frameon=False)
    runtime_panel(axs[0, 1], summary, v, cfg, ds)
    a = axs[0, 2]
    line(a, x, st.max_depth, col, "max depth")
    a.set_title("Max depth (levels below root)"); a.set_ylabel("depth")
    a = axs[1, 0]; line(a, x, st.empty_leaf_pct, col); a.set_title("Empty leaves"); a.set_ylabel("% of leaves")
    a = axs[1, 1]; line(a, x, st.avg_particles_per_leaf, col); a.set_title("Avg particles per leaf")
    a.set_ylabel("active particles / leaves")
    a = axs[1, 2]
    line(a, x, st.particles_active, C["active"], "active")
    line(a, x, st.particles_escaped, C["escaped"], "escaped")
    line(a, x, st.particle_slots, C["slots"], "slots", ls="--")
    a.set_title("Particles"); a.legend(fontsize=7, frameon=False)
    for a in axs.flat[[0, 2, 3, 4, 5]]:
        a.set_xlabel("snapshot")
    axs[0, 1].set_xlabel("snapshot")
    r = status[(status.version == v) & (status.config == cfg) & (status.dataset == ds)]
    path = "CUDA graph" if v == "v3" else "direct"
    fig.suptitle(f"{SLIDE[ds]} — {CFG[cfg]} ({v}, {path} path, leaf limit {'64²·27 NF' if 'nf' in cfg else 64})")
    note(fig, "Runtime: median per snapshot of " + ci_note(w, r_range(status, version=v, config=cfg, dataset=ds), False) +
         " Stacked phases are medians (their sum need not equal the median total). "
         "Structural metrics are deterministic (identical in every run, see data/determinism.csv); shown from run 1.")
    integer_x(fig)
    if len(x) <= 5:
        axs[0, 1].xaxis.set_major_locator(matplotlib.ticker.FixedLocator(range(len(x) - 1)))
    fig.tight_layout(rect=(0, 0.04, 1, 0.97))
    save(fig, stem)


# ------------------------------------------------------------------ plot 5 --
def comparison_figure(summary, steps, status, w, ds):
    cfgs = [c for c in CFG if not structure(steps, "v3", c, ds).empty]
    if len(cfgs) < 2:
        return
    fig, axs = plt.subplots(2, 3, figsize=(13, 6.8))
    for c in cfgs:
        st = structure(steps, "v3", c, ds)
        x = st.frame_id.to_numpy()
        line(axs[0, 0], x, st.num_nodes, C[c], CFG[c])
        line(axs[1, 0], x, st.max_depth, C[c], CFG[c])
        line(axs[1, 1], x, st.empty_leaf_pct, C[c], CFG[c])
        line(axs[1, 2], x, st.avg_particles_per_leaf, C[c], CFG[c])
        for a, m in ((axs[0, 1], "tree_update_ms"), (axs[0, 2], "total_ms")):
            s = series(summary, "v3", c, ds, m)
            if len(s) <= 5:
                k = cfgs.index(c)
                a.bar(k, s["median"].iloc[0], color=C[c], label=CFG[c])
                a.errorbar(k, s["median"].iloc[0], yerr=[[s["median"].iloc[0] - s.ci_low.iloc[0]],
                                                         [s.ci_high.iloc[0] - s["median"].iloc[0]]],
                           color="black", capsize=3)
                a.set_xticks([])
            else:
                a.fill_between(s.frame_id, s.ci_low, s.ci_high, color=C[c], alpha=0.2, lw=0)
                a.plot(s.frame_id, s["median"], color=C[c], lw=0.9, label=CFG[c])
    titles = [["Total nodes", "Tree update runtime (median, 95% CI)", "Total runtime (median, 95% CI)"],
              ["Max depth (levels below root)", "Empty leaves [%]", "Avg particles per leaf"]]
    ylabels = [["nodes", "tree_update_ms", "total_ms"], ["depth", "% of leaves", "particles / leaf"]]
    for i in range(2):
        for j in range(3):
            axs[i, j].set_title(titles[i][j]); axs[i, j].set_ylabel(ylabels[i][j]); axs[i, j].set_xlabel("snapshot")
    axs[0, 0].legend(fontsize=7, frameon=False)
    fig.suptitle(f"{SLIDE[ds]} — Octree vs. KDTree3D (v3, CUDA graph timings)")
    note(fig, "Runtime: median per snapshot of " + ci_note(w, r_range(status, version="v3", dataset=ds), False) +
         " Max depth: levels below the root (KDTree3D: 1 key bit per level, octree: 3).")
    integer_x(fig)
    fig.tight_layout(rect=(0, 0.04, 1, 0.97))
    save(fig, f"{ds}_octree_vs_kdtree3d")


# ------------------------------------------------------------------ plot 4 --
def full_pipeline():
    src = bl.csv_path(DATA / "octree_comparison_source.csv")
    if not src.exists():
        return
    d = bl.read_csv(src)
    inputs = list(dict.fromkeys(d.input))
    impls = list(dict.fromkeys(d.implementation))
    phases = [("common", "common/preprocessing", C["common"]), ("tree", "tree update", C["tree"]),
              ("view", "view construction", C["view"]), ("lists", "interaction lists", C["lists"]),
              ("fmm", "FMM total (far + near field, not split)", C["far"])]
    fig, axs = plt.subplots(1, len(inputs), figsize=(3 * len(inputs), 4.4))
    for a, inp in zip(np.atleast_1d(axs), inputs):
        sub = d[d.input == inp].set_index("implementation").reindex(impls)
        bottom = np.zeros(len(impls))
        for key, label, color in phases:
            v = sub[f"{key}_ms"].fillna(0).to_numpy()
            a.bar(range(len(impls)), v, bottom=bottom, color=color, label=label if inp == inputs[0] else None)
            bottom += v
        a.errorbar(range(len(impls)), sub.total_ms, yerr=[sub.total_ms - sub.total_min_ms, sub.total_max_ms - sub.total_ms],
                   fmt="none", color="black", capsize=2, lw=0.8)
        crit = [f"{i}\n{c if c != 'not applicable' else ''} {'' if pd.isna(b) else int(b)}"
                for i, c, b in zip(impls, sub.split_criterion, sub.bucket)]
        a.set_xticks(range(len(impls)), crit, rotation=60, ha="right", fontsize=6.5)
        a.set_title(f"{inp} ({int(sub.particles.dropna().iloc[0]):,} particles)\n"
                    f"{int(sub.repetitions.max())} reps × {int(sub.steps_per_repetition.max())} steps", fontsize=8.5)
    np.atleast_1d(axs)[0].set_ylabel("mean time per step [ms]")
    fig.legend(loc="upper center", ncol=5, fontsize=7.5, frameon=False)
    r = d.iloc[0]
    note(fig, f"Source: data/octree_comparison_source.csv, {r.gpu}, separate "
              f"FMM harness; repetitions × steps per panel title, {int(r.warmup_steps_excluded)} warm-up steps excluded. "
              "Bars: source means (raw samples not available, "
              "so no median/bootstrap CI); whiskers: min–max of the repetition means. Not re-measured with this suite's "
              "protocol; FMM is reported as one total (no far/near-field split in the source). Inputs differ from this "
              "suite (e.g. 'halo' = 1.2 M-particle subsample, coulomb early/late windows; buckets differ per bar).")
    fig.tight_layout(rect=(0, 0.07, 1, 0.92))
    save(fig, "full_pipeline")


def main():
    if "--talk" in sys.argv[1:]:
        return talk()
    summary = bl.read_csv(DATA / "summary.csv")
    steps = bl.read_csv(DATA / "raw_steps.csv")
    steps = steps[steps.run > 0]
    status, w = protocol()
    print("plotting ...")
    implementation_runtime()
    for ds in [x for x in ORDER if x in set(steps.dataset)]:
        for cfg in CFG:
            v = pick_fastest(summary, ds, cfg) if cfg != "kdtree3d_leafcount" else "v3"
            if v and not structure(steps, v, cfg, ds).empty:
                snapshot_figure(summary, steps, status, w, v, cfg, ds, f"{ds}_{cfg}")
        comparison_figure(summary, steps, status, w, ds)
    full_pipeline()


# ------------------------------------------------------------ talk plots --
# plot.py --talk: only the slide figures below, written to plots/talk/.
TALK_SERIES = ["coulomb_explosion", "flyby", "cluster_full"]


def block_size(n_snapshots):
    return 100 if n_snapshots > 3000 else max(1, n_snapshots // 60)


def snapshot_axis(ax, xmax):
    ax.xaxis.set_major_locator(matplotlib.ticker.MaxNLocator(nbins=5, integer=True))
    if xmax >= 10000:
        ax.xaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: f"{v / 1000:g}k" if v else "0"))
    ax.set_xlabel("snapshot")


class Blocks:
    """Medians over blocks of consecutive snapshots (raw samples of all runs pooled per block)."""

    def __init__(self, steps, v, cfg, ds):
        s = steps[(steps.version == v) & (steps.config == cfg) & (steps.dataset == ds)]
        timed = s[s.snapshot > 0]
        self.n = timed.snapshot.nunique()
        self.runs = s.run.nunique()
        self.size = block_size(self.n)
        self.timed = timed.assign(block=(timed.snapshot - 1) // self.size)
        st = s[s.run == s.run.min()]
        self.struct = st.assign(block=np.maximum(st.snapshot - 1, 0) // self.size)
        self.xmax = s.frame_id.max()

    def timing(self, metric, ci=False):
        g = self.timed.groupby("block")
        x, med = g.frame_id.median().to_numpy(), g[metric].median().to_numpy()
        if not ci:
            return x, med, None, None
        lo, hi = np.empty(len(x)), np.empty(len(x))
        for i, (_, grp) in enumerate(g):
            _, lo[i], hi[i] = bl.pooled_median_ci(grp[metric].to_numpy(), grp.run.to_numpy())
        return x, med, lo, hi

    def structural(self, col, agg="median"):
        g = self.struct.groupby("block")
        return g.frame_id.median().to_numpy(), g[col].agg(agg).to_numpy()

    def note(self):
        return (f"Each point: median over a block of {self.size} consecutive snapshots "
                f"(runtime: all {self.runs}×{self.size} step samples of the block pooled)")


def depth_panel(ax, b, col, color, label=None):
    """Depth is integer and can alternate between steps: show the min–max range per block."""
    xs, lo = b.structural(col, "min")
    _, hi = b.structural(col, "max")
    ax.fill_between(xs, lo, hi, step="mid", color=color, alpha=0.3, lw=0)
    ax.step(xs, hi, where="mid", color=color, lw=1.3, label=label)
    ax.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(integer=True))
    ylo, yhi = ax.get_ylim()
    ax.set_ylim(min(ylo, np.nanmin(lo) - 1), max(yhi, np.nanmax(hi) + 1))


def talk_implementation_runtime(ds="coulomb_explosion"):
    d = bl.read_csv(DATA / "implementation_runtime_summary.csv")
    status, w = protocol()
    d = d[d.dataset == ds]
    fig, ax = plt.subplots(figsize=(6.8, 4.6))
    keys = list(VERSION_STYLE)
    for i, (v, c) in enumerate(keys):
        r = d[(d.version == v) & (d.config == c)]
        if r.empty or np.isnan(r.median_total_ms.iloc[0]):
            ax.text(i, 0, "n/a", ha="center", va="bottom", color=FZJ["darkgray"])
            continue
        r = r.iloc[0]
        tree, view = r.median_tree_update_ms, r.median_view_ms
        ax.bar(i, tree, 0.62, color=C["tree"], label="tree update (median)" if i == 0 else None)
        ax.bar(i, view, 0.62, bottom=tree, color=C["view"], label="view construction (median)" if i == 0 else None)
        for y0, h in ((0, tree), (tree, view)):
            if h > 0.06 * d.ci_high.max():
                ax.text(i, y0 + h / 2, f"{h:.3f}", ha="center", va="center", fontsize=7, color=FZJ["darkgray"])
        ax.errorbar(i, r.median_total_ms, yerr=[[r.median_total_ms - r.ci_low], [r.ci_high - r.median_total_ms]],
                    fmt="_", ms=14, color=FZJ["darkgray"], capsize=3, lw=0.9,
                    label="total (median, 95% CI)" if i == 0 else None)
        ax.text(i, max(r.ci_high, tree + view) * 1.03, f"{r.median_total_ms:.3f} ms\n×{r.speedup_vs_cstone:.2f}",
                ha="center", va="bottom", fontsize=7.5)
    ax.set_xticks(range(len(keys)), [BAR_LABEL[k] for k in keys])
    ax.set_ylim(0, d.ci_high.max() * 1.32)
    ax.set_ylabel("median time per update step [ms]")
    ax.set_title(f"{SLIDE[ds]}: tree update + view construction per step\n(×: total speed-up vs. Cornerstone)")
    ax.legend(fontsize=7, frameon=False, loc="upper right")
    n = int(d.n_steps.max()) if len(d) else 0
    note(fig, f"Segments: medians of the two phases (their sum need not equal the median total, shown as marker). "
         f"Median of {n:,} steps per bar (all timed snapshots of " + ci_note(w, r_range(status, dataset=ds), True) +
         " Cornerstone: SFC keys + sort + converged rebalance, view = buildOctreeGpu; v1/v2 direct, v3 CUDA graph.")
    fig.tight_layout(rect=(0, 0.17, 1, 1))
    save(fig, f"talk/{ds}_implementation_runtime")


def talk_snapshot_figure(steps, status, w, cfg, ds):
    b = Blocks(steps, "v3", cfg, ds)
    col = C[cfg]
    fig, axs = plt.subplots(2, 3, figsize=(13, 6.8))
    st = b.struct.sort_values("frame_id")
    x = st.frame_id.to_numpy()
    a = axs[0, 0]
    a.plot(x, st.num_nodes, color=C["nodes"], lw=1, label="nodes")
    a.plot(x, st.num_leaves, color=C["leaves"], lw=1, label="leaves")
    a.set_title("Tree size"); a.set_ylabel("count"); a.legend(fontsize=7, frameon=False)
    a = axs[0, 1]
    xb, tr, _, _ = b.timing("tree_update_ms")
    _, vw, _, _ = b.timing("view_ms")
    _, to, lo, hi = b.timing("total_ms", ci=True)
    a.stackplot(xb, tr, vw, colors=[C["tree"], C["view"]], labels=["tree update (median)", "view (median)"])
    a.fill_between(xb, lo, hi, color=C["total"], alpha=0.25, lw=0)
    a.plot(xb, to, color=C["total"], lw=1.2, label="total (median, 95% CI)")
    a.set_ylim(0, np.nanmax(hi) * 1.3)
    a.set_title(f"Runtime (median per {b.size} snapshots)"); a.set_ylabel("time per step [ms]")
    a.legend(fontsize=7, frameon=False, loc="upper left", ncol=3)
    a = axs[0, 2]
    depth_panel(a, b, "max_depth", col)
    a.set_title(f"Max depth (line: max, band: min–max per {b.size} snapshots)")
    a.set_ylabel("levels below root")
    a = axs[1, 0]; a.plot(x, st.empty_leaf_pct, color=col, lw=1); a.set_title("Empty leaves"); a.set_ylabel("% of leaves")
    a = axs[1, 1]; a.plot(x, st.avg_particles_per_leaf, color=col, lw=1); a.set_title("Avg particles per leaf")
    a.set_ylabel("active particles / leaves")
    for a in axs.flat:
        snapshot_axis(a, b.xmax)
    fig.suptitle(f"{SLIDE[ds]} — {CFG[cfg]} (v3, CUDA graph, limit {'64²·27 NF' if 'nf' in cfg else 64})")
    note(fig, "Runtime: " + b.note() + "; stacked phases are medians (their sum need not equal the median total). "
         + ci_note(w, r_range(status, version="v3", config=cfg, dataset=ds), True)
         + " Structural metrics are deterministic (identical in every run); shown per snapshot.")
    fig.tight_layout(rect=(0, 0.05, 1, 0.97))
    particles_panel(fig, axs[1, 2], x, st, b.xmax)
    save(fig, f"talk/{ds}_v3_{cfg}")


def particles_panel(fig, ax, x, st, xmax):
    """Active/slots and escaped counts; with escapes the y-axis is broken so the few escapes stay visible."""
    esc = st.particles_escaped.to_numpy()
    if esc.max() == 0:
        ax.plot(x, st.particles_active, color=C["active"], lw=1.2, label="active")
        ax.plot(x, esc, color=C["escaped"], lw=1.2, label="escaped")
        ax.plot(x, st.particle_slots, color=C["slots"], lw=1, ls="--", label="slots")
        ax.set_title("Particles"); ax.legend(fontsize=7, frameon=False)
        return
    pos = ax.get_position()
    ax.remove()
    gap, h_low = 0.015, pos.height * 0.42
    low = fig.add_axes([pos.x0, pos.y0, pos.width, h_low])
    top = fig.add_axes([pos.x0, pos.y0 + h_low + gap, pos.width, pos.height - h_low - gap], sharex=low)
    active, slots = st.particles_active.to_numpy(), st.particle_slots.to_numpy()
    pad = max(1.0, 0.15 * (slots.max() - active.min()))
    top.plot(x, active, color=C["active"], lw=1.2, label="active")
    top.plot(x, slots, color=C["slots"], lw=1, ls="--", label="slots")
    top.set_ylim(active.min() - pad, slots.max() + pad)
    low.plot(x, esc, color=C["escaped"], lw=1.2, label="escaped")
    low.set_ylim(0, esc.max() * 1.2 + 1)
    low.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(nbins=4, integer=True))
    top.yaxis.set_major_locator(matplotlib.ticker.MaxNLocator(nbins=3, integer=True))
    top.spines["bottom"].set_visible(False)
    top.tick_params(axis="x", bottom=False, labelbottom=False)
    marks = dict(marker=[(-1, -0.5), (1, 0.5)], markersize=9, linestyle="none", color=FZJ["darkgray"],
                 mec=FZJ["darkgray"], mew=1, clip_on=False)
    top.plot([0], [0], transform=top.transAxes, **marks)
    low.plot([0], [1], transform=low.transAxes, **marks)
    handles = top.get_legend_handles_labels()[0] + low.get_legend_handles_labels()[0]
    top.legend(handles, [h.get_label() for h in handles], fontsize=7, frameon=False, loc="center right")
    top.set_title("Particles (broken y-axis)")
    top.set_ylabel("active / slots")
    low.set_ylabel("escaped")
    snapshot_axis(low, xmax)


def talk_octree_vs_kdtree3d(steps, status, w, ds):
    cfgs = ["octree_leafcount", "kdtree3d_leafcount"]
    fig, axs = plt.subplots(2, 3, figsize=(13, 6.8))
    b = None
    for c in cfgs:
        b = Blocks(steps, "v3", c, ds)
        for a, col in ((axs[0, 0], "num_nodes"), (axs[1, 1], "empty_leaf_pct"), (axs[1, 2], "avg_particles_per_leaf")):
            xs, ys = b.structural(col)
            a.plot(xs, ys, color=C[c], lw=1.3, label=CFG[c])
        depth_panel(axs[1, 0], b, "max_depth", C[c], CFG[c])
        for a, m in ((axs[0, 1], "tree_update_ms"), (axs[0, 2], "total_ms")):
            xs, med, lo, hi = b.timing(m, ci=True)
            a.fill_between(xs, lo, hi, color=C[c], alpha=0.25, lw=0)
            a.plot(xs, med, color=C[c], lw=1.3, label=CFG[c])
    titles = [["Total nodes", "Tree update runtime", "Total runtime (tree update + view)"],
              ["Max depth (levels below root; line: max, band: min–max per block)", "Empty leaves", "Avg particles per leaf"]]
    ylabels = [["nodes", "time per step [ms]", "time per step [ms]"], ["depth", "% of leaves", "particles / leaf"]]
    for i in range(2):
        for j in range(3):
            axs[i, j].set_title(titles[i][j]); axs[i, j].set_ylabel(ylabels[i][j]); snapshot_axis(axs[i, j], b.xmax)
    for a in (axs[0, 1], axs[0, 2]):
        a.set_ylim(0, a.get_ylim()[1])
    axs[0, 0].legend(fontsize=7.5, frameon=False)
    fig.suptitle(f"{SLIDE[ds]} — Octree vs. KDTree3D, LeafCount (limit 64; v3, CUDA graph)")
    note(fig, "All panels: " + b.note() + " (max depth: min–max per block; KDTree3D: 1 key bit per level, octree: 3); runtime bands: 95% CI. "
         + ci_note(w, r_range(status, version="v3", dataset=ds), True))
    fig.tight_layout(rect=(0, 0.05, 1, 0.97))
    save(fig, f"talk/{ds}_octree_vs_kdtree3d_leafcount")


def talk_full_pipeline():
    src = bl.csv_path(DATA / "octree_comparison_source.csv")
    d = bl.read_csv(src)
    d = d[d.implementation.isin(["dense", "newest"])]
    inputs = list(dict.fromkeys(d.input))
    phases = [("common", "common/preprocessing", C["common"]), ("tree", "tree update", C["tree"]),
              ("view", "view construction", C["view"]), ("lists", "interaction lists", C["lists"]),
              ("fmm", "FMM (far + near field)", C["far"])]
    fig, axs = plt.subplots(len(inputs), 1, figsize=(8, 1.25 * len(inputs) + 1.4))
    for a, inp in zip(np.atleast_1d(axs), inputs):
        sub = d[d.input == inp].set_index("implementation").reindex(["dense", "newest"])
        left = np.zeros(2)
        for key, label, color in phases:
            v = sub[f"{key}_ms"].fillna(0).to_numpy()
            a.barh([0, 1], v, left=left, height=0.6, color=color, label=label if inp == inputs[0] else None)
            left += v
        a.errorbar(sub.total_ms, [0, 1], xerr=[sub.total_ms - sub.total_min_ms, sub.total_max_ms - sub.total_ms],
                   fmt="none", color=FZJ["darkgray"], capsize=2, lw=0.8)
        speed = sub.total_ms.iloc[0] / sub.total_ms.iloc[1]
        a.text(sub.total_max_ms.iloc[1] * 1.02, 1, f"  ×{speed:.2f} {'faster' if speed >= 1 else 'slower'} than dense",
               va="center", fontsize=8, fontweight="bold", color=FZJ["blue"] if speed >= 1 else FZJ["red"])
        a.set_yticks([0, 1], ["dense", f"newest ({sub.split_criterion.iloc[1]})"])
        a.invert_yaxis()
        a.set_xlim(0, sub.total_max_ms.max() * 1.45)
        a.set_title(f"{inp} ({int(sub.particles.iloc[0]):,} particles)", fontsize=9, loc="left")
    np.atleast_1d(axs)[-1].set_xlabel("mean time per step [ms]")
    fig.legend(loc="upper center", ncol=5, fontsize=7.5, frameon=False)
    r = d.iloc[0]
    note(fig, f"Source: data/octree_comparison_source.csv, {r.gpu}, separate FMM harness; means over repetitions "
              "(raw samples unavailable: no median/CI), whiskers min–max of repetition means; not re-measured with this "
              "suite's protocol. Speed-up = dense total / newest total. FMM is one total (no far/near-field split). "
              "'halo' = 1.2 M-particle subsample.")
    fig.tight_layout(rect=(0, 0.06, 1, 0.95))
    save(fig, "talk/full_pipeline_dense_vs_newest")


def talk():
    cols = ["version", "config", "dataset", "run", "snapshot", "frame_id", "tree_update_ms", "view_ms", "total_ms",
            "num_nodes", "num_leaves", "max_depth", "max_depth_octree_equiv", "empty_leaf_pct",
            "avg_particles_per_leaf", "particles_active", "particles_escaped", "particle_slots"]
    steps = bl.read_csv(DATA / "raw_steps.csv", usecols=cols)
    steps = steps[(steps.run > 0) & steps.dataset.isin(TALK_SERIES) & (steps.version == "v3")]
    status, w = protocol()
    print("plotting talk figures (bootstrap per block takes a few minutes) ...")
    talk_implementation_runtime("coulomb_explosion")
    talk_implementation_runtime("cluster")
    for ds in TALK_SERIES:
        for cfg in ("octree_leafcount", "octree_nfcount"):
            talk_snapshot_figure(steps, status, w, cfg, ds)
        talk_octree_vs_kdtree3d(steps, status, w, ds)
    talk_full_pipeline()


if __name__ == "__main__":
    main()
