#!/usr/bin/env python3
"""Dataset preparation (run once; every version uses the same outputs).

Per dataset writes datasets/<id>/manifest.txt (shared bounding box + ordered frame list)
and info.json. Frame paths are relative to their manifest. Single datasets get
NOISY_SNAPSHOTS extra binary frames (float64 N x 3, NaN = escaped): Gaussian noise with
sigma = NOISE_SIGMA x bounding-box edge per axis, cumulative, fixed seed, clamped to the box.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

import numpy as np
import pandas as pd

BENCH = Path(__file__).resolve().parent
def local_path(value):
    return (BENCH / value).resolve()


REPO = local_path(os.environ.get("REPO", "../adaptive-octree"))
DATA_ROOT = local_path(os.environ.get("DATA_ROOT", ".."))
DATASETS = {  # id -> source (referenced relative to the manifest, never copied)
    "coulomb_explosion": DATA_ROOT / "coulomb_explosion_ts/frames_more",
    "flyby": REPO / "tests/test_data/simdata",
    # 25.6 M instead of halo_102400000.dat: v2/v3 run out of memory on the 8 GB GPU with 102.4 M
    "dense_halo": REPO / "tests/test_data/halo_25600000.dat",
    "nacl": REPO / "tests/test_data/input_test.txt",
    "stmv": REPO / "tests/test_data/stmv_input.txt",
    # ESC rows from frame 53 on; only v3 supports escaped particles
    "cluster": REPO / "tests/test_data/cluster",
    "cluster_full": REPO / "tests/test_data/cluster",
}
LAST_FRAME = {"cluster": 52}  # box is still computed over all frames, identical to cluster_full
SERIES_PATTERNS = [  # (regex, column layout) as in the repo's bench_snapshots.cu
    (re.compile(r"xyz_([0-9]+)"), "xyzc"),
    (re.compile(r"snapshot_([0-9]{6})\.dat"), "cxyz"),
    (re.compile(r"cluster-([0-9]{4})\.dat"), "cxyz"),
]
DOMAIN_PADDING = 0.05  # adaptive_octree::defaults::domainPadding


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def read_xyz(path, layout):
    """Read 4 whitespace-separated columns; 'ESC' rows become NaN (escaped slots)."""
    cols = [1, 2, 3] if layout == "cxyz" else [0, 1, 2]
    # explicit names: a leading "ESC" row would otherwise make pandas infer a single column
    df = pd.read_csv(path, sep=r"\s+", header=None, names=[0, 1, 2, 3], comment="#", usecols=cols,
                     na_values=["ESC"], engine="c", dtype=np.float64)
    return df.to_numpy(dtype=np.float64)


def extend_bounds(xyz, lo, hi):
    active = ~np.isnan(xyz).any(axis=1)
    if not active.any():
        return lo, hi
    return np.minimum(lo, np.nanmin(xyz[active], axis=0)), np.maximum(hi, np.nanmax(xyz[active], axis=0))


def pad(lo, hi):
    """Same per-axis padding as tests/bench_snapshots.cu computeSeriesBoundingBox()."""
    eps = np.finfo(np.float64).eps
    margin = np.maximum(DOMAIN_PADDING * (hi - lo), 8 * eps * np.maximum.reduce([np.ones(3), np.abs(lo), np.abs(hi)]))
    return lo - margin, hi + margin


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 24), b""):
            h.update(block)
    return h.hexdigest()


def write_manifest(out_dir, ds, slots, box_lo, box_hi, frames):
    with open(out_dir / "manifest.txt", "w") as f:
        f.write(f"dataset {ds}\nslots {slots}\n")
        f.write("box " + " ".join(f"{v:.17g}" for pair in zip(box_lo, box_hi) for v in pair) + "\n")
        for i, (fid, fmt, path) in enumerate(frames):
            frame_path = os.path.relpath(path, out_dir)
            f.write(f"frame {i} {fid} {fmt} {frame_path}\n")


def prepare_series(ds, src, out_dir, stride, last=None):
    frames, layout = [], None
    for entry in os.scandir(src):
        if not entry.is_file():
            continue
        for rx, lay in SERIES_PATTERNS:
            m = rx.fullmatch(entry.name)
            if m:
                if layout not in (None, lay):
                    sys.exit(f"mixed snapshot formats in {src}")
                layout = lay
                frames.append((int(m.group(1)), lay, entry.path))
    frames.sort()
    frames = [f for f in frames if f[0] % stride == 0]
    if not frames:
        sys.exit(f"no frames in {src}")
    lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
    slots, escaped = None, []
    t0 = time.time()
    for k, (fid, lay, path) in enumerate(frames):
        xyz = read_xyz(path, lay)
        if slots is None:
            slots = len(xyz)
        elif len(xyz) != slots:
            sys.exit(f"slot count changed in {path}")
        escaped.append(int(np.isnan(xyz).any(axis=1).sum()))
        lo, hi = extend_bounds(xyz, lo, hi)
        if k % 200 == 0 or k == len(frames) - 1:
            log(f"  {ds}: scanned {k + 1}/{len(frames)} frames ({time.time() - t0:.0f}s)")
    box_lo, box_hi = pad(lo, hi)
    if last is not None:
        escaped = [e for f, e in zip(frames, escaped) if f[0] <= last]
        frames = [f for f in frames if f[0] <= last]
    write_manifest(out_dir, ds, slots, box_lo, box_hi, frames)
    return dict(kind="series", source=os.path.relpath(src, BENCH), frames=len(frames), stride=stride, slots=slots, last_frame=last,
                max_escaped=max(escaped), data_lo=lo.tolist(), data_hi=hi.tolist(),
                box_lo=box_lo.tolist(), box_hi=box_hi.tolist())


def prepare_single(ds, src, out_dir, n_noisy, sigma_rel, seed):
    t0 = time.time()
    xyz = read_xyz(src, "xyzc")  # single files use x y z charge
    log(f"  {ds}: read {len(xyz)} particles ({time.time() - t0:.0f}s)")
    esc = np.isnan(xyz).any(axis=1)
    lo, hi = extend_bounds(xyz, np.full(3, np.inf), np.full(3, -np.inf))
    sigma = sigma_rel * (hi - lo)
    rng = np.random.default_rng(seed)
    frames = [(0, "xyzc", str(src))]
    files = {}
    pos = xyz.copy()
    for k in range(1, n_noisy + 1):
        pos[~esc] += rng.normal(0.0, sigma, size=(int((~esc).sum()), 3))
        np.clip(pos, lo, hi, out=pos)  # NaN (escaped) rows stay NaN
        path = out_dir / f"noisy_{k:03d}.bin"
        pos.astype(np.float64).tofile(path)
        files[path.name] = sha256(path)
        frames.append((k, "bin", str(path)))
        log(f"  {ds}: wrote {path.name} ({time.time() - t0:.0f}s)")
    box_lo, box_hi = pad(lo, hi)  # clamping keeps every frame inside [lo, hi]
    write_manifest(out_dir, ds, len(xyz), box_lo, box_hi, frames)
    return dict(kind="single", source=os.path.relpath(src, BENCH), frames=len(frames), slots=len(xyz), escaped=int(esc.sum()),
                noise_sigma_rel=sigma_rel, noise_sigma_abs=sigma.tolist(), seed=seed, cumulative=True,
                clamped_to=[lo.tolist(), hi.tolist()], data_lo=lo.tolist(), data_hi=hi.tolist(),
                box_lo=box_lo.tolist(), box_hi=box_hi.tolist(), generated_sha256=files)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dataset", action="append", help="dataset id (repeatable); default: all")
    ap.add_argument("--noisy", type=int, default=int(os.environ.get("NOISY_SNAPSHOTS", 1)))
    ap.add_argument("--sigma", type=float, default=float(os.environ.get("NOISE_SIGMA", 1e-3)))
    ap.add_argument("--seed", type=int, default=int(os.environ.get("NOISE_SEED", 20261001)))
    ap.add_argument("--stride", type=int, default=int(os.environ.get("SNAPSHOT_STRIDE", 1)))
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    for ds in a.dataset or os.environ.get("DATASETS_OVERRIDE", " ".join(DATASETS)).split():
        src = DATASETS[ds]
        out_dir = BENCH / "datasets" / ds
        out_dir.mkdir(parents=True, exist_ok=True)
        params = dict(source=os.path.relpath(src, BENCH), noisy=a.noisy, sigma=a.sigma, seed=a.seed, stride=a.stride,
                      last=LAST_FRAME.get(ds))
        info_path = out_dir / "info.json"
        if not a.force and info_path.exists() and json.loads(info_path.read_text()).get("params") == params:
            log(f"{ds}: up to date")
            continue
        log(f"{ds}: preparing from {src}")
        info = prepare_series(ds, src, out_dir, a.stride, LAST_FRAME.get(ds)) if src.is_dir() else \
            prepare_single(ds, src, out_dir, a.noisy, a.sigma, a.seed)
        info["params"] = params
        info_path.write_text(json.dumps(info, indent=2))
        log(f"{ds}: {info['frames']} frames, {info['slots']} slots")


if __name__ == "__main__":
    main()
