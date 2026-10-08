#!/usr/bin/env python3
"""Statistics (section 7): raw CSVs -> data/summary.csv (+ determinism, bar and pipeline tables).

Groups: (version, config, dataset, snapshot, metric) over the R independent runs, and
"pooled" over all timed snapshots (snapshot > 0). Per group: n, median, 95% BCa bootstrap
CI of the median (scipy.stats.bootstrap, 10,000 resamples, fixed seed), Shapiro-Wilk p,
min, max, mean, std. Pooled CIs resample whole runs (cluster bootstrap), because steps of
one run share process/tree history and are not independent.
"""
import sys

import numpy as np
import pandas as pd

import benchlib as bl
from benchlib import DATA, TIMING, STRUCTURAL

KEYS = ["version", "commit", "path", "config", "dataset"]
BARS = [("cstone", "octree_leafcount"), ("v3", "octree_leafcount"), ("v1", "octree_nfcount"),
        ("v2", "octree_nfcount"), ("v3", "octree_nfcount")]
CHUNK = 64


def log(msg):
    print(msg, flush=True)


def determinism(steps):
    cols = STRUCTURAL + ["empty_leaf_pct", "avg_particles_per_leaf"]
    g = steps.groupby(KEYS + ["snapshot"])[cols].nunique()
    bad = g[(g > 1).any(axis=1)].reset_index()
    per_cell = steps.groupby(KEYS).agg(runs=("run", "nunique"), snapshots=("snapshot", "nunique")).reset_index()
    counts = bad.groupby(KEYS).size().rename("nondeterministic_snapshots").reset_index()
    per_cell = per_cell.merge(counts, on=KEYS, how="left").fillna({"nondeterministic_snapshots": 0})
    per_cell["structurally_deterministic"] = per_cell.nondeterministic_snapshots == 0
    per_cell.to_csv(DATA / "determinism.csv", index=False)
    bad.to_csv(DATA / "determinism_violations.csv", index=False)
    for _, r in per_cell[~per_cell.structurally_deterministic].iterrows():
        log(f"  WARNING: structural metrics differ between runs: {r.version}/{r.config}/{r.dataset} "
            f"({int(r.nondeterministic_snapshots)} snapshots, see data/determinism_violations.csv)")
    return per_cell


def per_snapshot_rows(cell, keys, metric):
    wide = cell.pivot_table(index=["snapshot", "frame_id"], columns="run", values=metric, aggfunc="first")
    rows = []
    for start in range(0, len(wide), CHUNK):
        block = wide.iloc[start:start + CHUNK]
        x = block.to_numpy(float)
        if np.isnan(x).any():  # unequal run coverage: fall back to per-row handling
            for (snap, fid), vals in block.iterrows():
                d = bl.describe(vals.to_numpy(float))
                if d:
                    rows.append({**keys, "snapshot": snap, "frame_id": fid, "metric": metric, **d, "ci_method": "BCa"})
            continue
        med, lo, hi = bl.median_ci(x)
        p = bl.shapiro_p(x)
        for i, (snap, fid) in enumerate(block.index):
            rows.append({**keys, "snapshot": snap, "frame_id": fid, "metric": metric, "n": x.shape[1],
                         "median": med[i], "ci_low": lo[i], "ci_high": hi[i], "shapiro_p": p[i],
                         "min": x[i].min(), "max": x[i].max(), "mean": x[i].mean(),
                         "std": x[i].std(ddof=1) if x.shape[1] > 1 else np.nan, "ci_method": "BCa"})
    return rows


def pooled_row(cell, keys, metric):
    t = cell[["run", metric]].dropna()
    if t.empty:
        return None
    x = t[metric].to_numpy(float)
    med, lo, hi = bl.pooled_median_ci(x, t.run.to_numpy())
    return {**keys, "snapshot": "pooled", "frame_id": np.nan, "metric": metric, "n": len(x), "median": med,
            "ci_low": lo, "ci_high": hi, "shapiro_p": float(bl.shapiro_p(x)), "min": x.min(), "max": x.max(),
            "mean": x.mean(), "std": x.std(ddof=1), "ci_method": f"BCa, resampling {t.run.nunique()} runs"}


def main():
    bl.merge()
    steps = bl.read_csv(DATA / "raw_steps.csv")
    steps = steps[steps.run > 0]  # warm-up runs (negative ids) are never analysed
    cold = bl.read_csv(DATA / "raw_initial_build.csv") if bl.csv_path(DATA / "raw_initial_build.csv").exists() else None

    log("determinism check of structural metrics ...")
    determinism(steps)

    rows = []
    timed = steps[steps.snapshot > 0]
    for keyvals, cell in timed.groupby(KEYS):
        keys = dict(zip(KEYS, keyvals))
        log(f"summary {'/'.join(str(k) for k in keyvals if k != keys['commit'])}: "
            f"{cell.run.nunique()} runs x {cell.snapshot.nunique()} snapshots")
        for metric in TIMING:
            rows += per_snapshot_rows(cell, keys, metric)
            r = pooled_row(cell, keys, metric)
            if r:
                rows.append(r)
    if cold is not None:
        for keyvals, cell in cold.groupby(KEYS):
            keys = dict(zip(KEYS, keyvals))
            for metric in ["initial_build_ms", "initial_tree_gpu_ms", "initial_view_gpu_ms"]:
                d = bl.describe(cell[metric].to_numpy(float))
                if d:
                    rows.append({**keys, "snapshot": "initial", "frame_id": 0, "metric": metric, **d,
                                 "ci_method": f"BCa over {len(cell)} cold processes"})
    summary = pd.DataFrame(rows)
    bl.write_csv(summary, DATA / "summary.csv", index=False)
    log(f"wrote data/summary.csv ({len(summary)} rows)")

    implementation_summary(summary)
    full_pipeline()


def implementation_summary(summary):
    status = bl.read_csv(DATA / "run_status.csv") if bl.csv_path(DATA / "run_status.csv").exists() else pd.DataFrame()
    pooled = summary[summary.snapshot == "pooled"]
    out = []
    for ds in sorted(pooled.dataset.unique()):
        base = pooled[(pooled.version == "cstone") & (pooled.config == "octree_leafcount") &
                      (pooled.dataset == ds) & (pooled.metric == "total_ms")]
        base_med = base["median"].iloc[0] if len(base) else np.nan
        for v, c in BARS:
            sel = pooled[(pooled.version == v) & (pooled.config == c) & (pooled.dataset == ds)]
            get = lambda m, col="median": sel.loc[sel.metric == m, col].iloc[0] if (sel.metric == m).any() else np.nan
            st = status[(status.version == v) & (status.config == c) & (status.dataset == ds)] if len(status) else status
            out.append(dict(dataset=ds, version=v, config=c, path=sel.path.iloc[0] if len(sel) else "",
                            median_total_ms=get("total_ms"), ci_low=get("total_ms", "ci_low"),
                            ci_high=get("total_ms", "ci_high"), n_steps=get("total_ms", "n"),
                            median_tree_update_ms=get("tree_update_ms"), median_view_ms=get("view_ms"),
                            median_wall_ms=get("wall_ms"), speedup_vs_cstone=base_med / get("total_ms"),
                            R=st.R.iloc[-1] if len(st) else np.nan, status=st.status.iloc[-1] if len(st) else "not run"))
    pd.DataFrame(out).to_csv(DATA / "implementation_runtime_summary.csv", index=False)
    log("wrote data/implementation_runtime_summary.csv")


def full_pipeline():
    src = bl.csv_path(DATA / "octree_comparison_source.csv")
    if not src.exists():
        log("no data/octree_comparison_source.csv -> data/full_pipeline.csv skipped")
        return
    d = bl.read_csv(src)
    rows = []
    for _, r in d.iterrows():
        for phase in ["common", "tree", "view", "lists", "fmm"]:
            rows.append(dict(input=r.input, implementation=r.implementation, split_criterion=r.split_criterion,
                             bucket=r.bucket, particles=r.particles, phase=phase, statistic="mean (source)",
                             value_ms=r[f"{phase}_ms"], std_ms=r[f"{phase}_std_ms"], min_ms=r[f"{phase}_min_ms"],
                             max_ms=r[f"{phase}_max_ms"], median_ms=np.nan, ci_low=np.nan, ci_high=np.nan,
                             repetitions=r.repetitions, steps_per_repetition=r.steps_per_repetition,
                             warmup_steps_excluded=r.warmup_steps_excluded, gpu=r.gpu,
                             note="not re-measured: FMM harness/raw samples unavailable here; source reports "
                                  "mean/std/min/max over repetitions; FMM not split into far/near field"))
    pd.DataFrame(rows).to_csv(DATA / "full_pipeline.csv", index=False)
    log("wrote data/full_pipeline.csv (source aggregates, see README)")


if __name__ == "__main__":
    sys.exit(main())
