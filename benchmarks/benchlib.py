#!/usr/bin/env python3
"""Shared helpers: raw-file merging, the stopping rule for R, and robust statistics.

CLI (used by bench.sh):
  benchlib.py ci-check <run_dir>    exit 0 when the 95% CI of the median total_ms is within +-CI_TOL
  benchlib.py merge                 data/raw/** -> data/raw_steps.csv, data/raw_initial_build.csv
"""
import os
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

from csv_io import csv_files, csv_path, read_csv, write_csv

BENCH = Path(__file__).resolve().parent
DATA = (BENCH / os.environ.get("DATA_DIR", "data")).resolve()
BOOT_SEED = int(os.environ.get("BOOT_SEED", 12345))
N_RESAMPLES = 10_000
TIMING = ["tree_update_ms", "view_ms", "total_ms", "wall_ms"]
STRUCTURAL = ["num_nodes", "num_leaves", "max_depth", "num_empty_leaves", "particles_active",
              "particles_escaped", "particle_slots"]


def median_ci(samples, seed=BOOT_SEED):
    """Median and 95% BCa bootstrap CI of the median along the last axis (scipy.stats.bootstrap).

    samples: array (..., n). Returns (median, low, high) with the batch shape."""
    x = np.asarray(samples, dtype=float)
    med = np.median(x, axis=-1)
    low = np.full(med.shape, np.nan)
    high = np.full(med.shape, np.nan)
    if x.shape[-1] < 2:
        return med, low, high
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")  # degenerate (constant) groups are handled below
        res = stats.bootstrap((x,), np.median, method="BCa", n_resamples=N_RESAMPLES, confidence_level=0.95,
                              random_state=np.random.default_rng(seed), axis=-1, vectorized=True)
    low, high = np.asarray(res.confidence_interval.low, float), np.asarray(res.confidence_interval.high, float)
    const = np.ptp(x, axis=-1) == 0
    low = np.where(const, med, low)
    high = np.where(const, med, high)
    return med, low, high


def pooled_median_ci(values, runs, seed=BOOT_SEED):
    """Median of samples pooled over snapshots, 95% BCa CI from scipy.stats.bootstrap that
    resamples whole runs (the independent fresh-process units), not single correlated steps."""
    values, runs = np.asarray(values, float), np.asarray(runs)
    keep = ~np.isnan(values)
    values, runs = values[keep], runs[keep]
    run_ids, label = np.unique(runs, return_inverse=True)
    order = np.argsort(values, kind="stable")
    v_sorted, l_sorted = values[order], label[order]
    med = float(np.median(values))
    if len(run_ids) < 2:
        return med, np.nan, np.nan

    def weighted_median(idx):  # median of the multiset union of the resampled runs
        cum = np.cumsum(np.bincount(idx, minlength=len(run_ids))[l_sorted])
        total = cum[-1]
        lo, hi = np.searchsorted(cum, [(total - 1) // 2, total // 2], side="right")
        return 0.5 * (v_sorted[lo] + v_sorted[hi])

    if np.ptp(values) == 0:
        return med, med, med
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        res = stats.bootstrap((np.arange(len(run_ids)),), weighted_median, method="BCa", n_resamples=N_RESAMPLES,
                              confidence_level=0.95, random_state=np.random.default_rng(seed), vectorized=False)
    return med, float(res.confidence_interval.low), float(res.confidence_interval.high)


def shapiro_p(samples):
    x = np.asarray(samples, dtype=float)
    if x.shape[-1] < 3:
        return np.full(x.shape[:-1], np.nan)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        p = np.asarray(stats.shapiro(x, axis=-1).pvalue, float)
    return np.where(np.ptp(x, axis=-1) == 0, np.nan, p)


def describe(x, seed=BOOT_SEED):
    """Summary row for one group of raw samples (1-D)."""
    x = np.asarray(x, dtype=float)
    x = x[~np.isnan(x)]
    if len(x) == 0:
        return None
    med, lo, hi = median_ci(x, seed)
    return dict(n=len(x), median=float(med), ci_low=float(lo), ci_high=float(hi), shapiro_p=float(shapiro_p(x)),
                min=x.min(), max=x.max(), mean=x.mean(), std=x.std(ddof=1) if len(x) > 1 else np.nan,
                skewness=float(stats.skew(x)) if len(x) > 2 else np.nan)


def ci_check(run_dir, tol=float(os.environ.get("CI_TOL", 0.05))):
    """Stopping rule: same pooled median + run-level BCa CI that analyze.py reports."""
    runs = csv_files(run_dir, "run_*.csv")
    d = pd.concat([read_csv(f) for f in runs], ignore_index=True) if runs else pd.DataFrame()
    if len(runs) < 2:
        print(f"R={len(runs)}: too few runs")
        return 1
    d = d[d.snapshot > 0]
    med, lo, hi = pooled_median_ci(d.total_ms.to_numpy(), d.run.to_numpy())
    rel_lo, rel_hi = (med - lo) / med, (hi - med) / med
    ok = rel_lo <= tol and rel_hi <= tol
    print(f"R={len(runs)} median(total_ms)={med:.4g} 95% CI=[{lo:.4g}, {hi:.4g}] (-{100 * rel_lo:.1f}% / "
          f"+{100 * rel_hi:.1f}%) -> {'converged' if ok else 'continue'}")
    return 0 if ok else 1


def merge():
    raw = DATA / "raw"
    steps = csv_files(raw, "*/*/*/run_*.csv")
    cold = csv_files(raw, "*/*/*/cold_*.csv")
    if steps:
        write_csv(pd.concat([read_csv(f) for f in steps], ignore_index=True), DATA / "raw_steps.csv", index=False)
    if cold:
        d = pd.concat([read_csv(f) for f in cold], ignore_index=True)
        write_csv(d, DATA / "raw_initial_build.csv", index=False)
    print(f"merged {len(steps)} step runs, {len(cold)} cold-build processes")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "ci-check":
        sys.exit(ci_check(sys.argv[2]))
    if len(sys.argv) >= 2 and sys.argv[1] == "merge":
        merge()
        sys.exit(0)
    sys.exit(__doc__)
