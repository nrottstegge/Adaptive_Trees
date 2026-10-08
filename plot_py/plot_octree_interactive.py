#!/usr/bin/env python3

"""
Interactive adaptive tree timeline viewer with charge-scaled particles.

Particle formats selected by tree_frames/domain.csv:

    xyz_charge : x y z charge
    charge_xyz : charge x y z

The fourth quantity is retained as point_data["charge"].

Particle rendering:
  - color is mapped continuously from charge
  - glyph radius/size increases with |charge|
  - a nonzero minimum glyph size keeps zero-charge particles visible
  - the same behavior is used in the full view, slices, and video

ESC rows are omitted from rendering.
"""

import base64
import glob
import io
import itertools
import os
import re

import numpy as np
import pandas as pd
import pyvista as pv
from matplotlib.figure import Figure

from pyvista.trame.ui import plotter_ui
from trame.app import get_server
from trame.ui.vuetify3 import SinglePageLayout
from trame.widgets import html, vuetify3


# ============================================================================
# Configuration
# ============================================================================

PORT = 8080

PROJECT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
TREE_ROOT_DIR = os.path.join(PROJECT_DIR, "tree_frames")
BENCHMARK_PATH = os.path.join(PROJECT_DIR, "bench_snapshots.csv")


def find_runs():
    manifest = os.path.join(TREE_ROOT_DIR, "runs.csv")
    if not os.path.exists(manifest):
        return [{"title": "Current run", "value": ""}]

    runs = pd.read_csv(manifest, dtype=str)
    required = {"run", "tree_type", "split_criterion"}
    if runs.empty or not required.issubset(runs.columns):
        raise RuntimeError(f"Empty or invalid run manifest: {manifest}")

    items = []
    for row in runs.to_dict("records"):
        name = row["run"]
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            raise RuntimeError(f"Invalid run directory in {manifest}: {name!r}")
        tree = "KDTree3D" if row["tree_type"] == "binary" else "Octree"
        criterion = {"leafcount": "LeafCount", "nfcount": "NFCount"}.get(
            row["split_criterion"], row["split_criterion"]
        )
        items.append({"title": f"{tree} / {criterion}", "value": name})
    return items


RUNS = find_runs()
TREE_DIR = os.path.join(TREE_ROOT_DIR, RUNS[0]["value"])

MAX_RENDERED_PARTICLES = 100_000

# Particle scalar/rendering configuration.
PARTICLE_SCALAR_NAME = "charge"
PARTICLE_CMAP = "plasma"

# Glyph radius = base_radius * (min_scale + normalized(|charge|) * range).
# These are world-coordinate sizes, relative to the domain size.
PARTICLE_GLYPH_BASE_RADIUS_FACTOR = 0.0005
PARTICLE_GLYPH_MIN_SCALE = 0.20
PARTICLE_GLYPH_MAX_SCALE = 1.50
PARTICLE_GLYPH_THETA_RESOLUTION = 8
PARTICLE_GLYPH_PHI_RESOLUTION = 8

# Slice particles are made somewhat larger.
SLICE_PARTICLE_RADIUS_MULTIPLIER = 1.35

# Video particles are made somewhat larger.
VIDEO_PARTICLE_RADIUS_MULTIPLIER = 1.25


# ============================================================================
# Video configuration
# ============================================================================

CREATE_VIDEO = False

VIDEO_OUTPUT = os.path.join(PROJECT_DIR, "tree_timeline.mp4")
VIDEO_FPS = 20
VIDEO_WINDOW_SIZE = (1920, 1080)
VIDEO_FRAME_STRIDE = 1

VIDEO_PARTICLE_OPACITY = 0.95
VIDEO_OCTREE_OPACITY = 0.22
VIDEO_OCTREE_LINE_WIDTH = 2

VIDEO_CAMERA_ORBITS = 0.85
VIDEO_CAMERA_DISTANCE_FACTOR = 3.0
VIDEO_CAMERA_MIN_DISTANCE_FACTOR = 0.05
VIDEO_CAMERA_MAX_DISTANCE_FACTOR = 3.2
VIDEO_CAMERA_FINAL_DISTANCE_FACTOR = 2.8
VIDEO_CAMERA_HEIGHT_FACTOR = 0.45
VIDEO_CAMERA_CENTER_SMOOTHING = 0.08
VIDEO_CAMERA_ZOOM_OUT_SMOOTHING = 0.30
VIDEO_FULL_DOMAIN_AT_PROGRESS = 0.60
VIDEO_ORBIT_END_PROGRESS = 0.75
VIDEO_DOMAIN_CENTER_BLEND_START = 0.60
VIDEO_DOMAIN_CENTER_BLEND_END = 0.85


# ============================================================================
# PyVista configuration
# ============================================================================

pv.global_theme.allow_empty_mesh = True
pv.OFF_SCREEN = True


# ============================================================================
# Utility functions
# ============================================================================

def smoothstep(value):
    return value * value * (3.0 - 2.0 * value)


def clamp01(value):
    return float(np.clip(value, 0.0, 1.0))


# ============================================================================
# Domain metadata
# ============================================================================

def load_domain_meta():
    path = os.path.join(TREE_DIR, "domain.csv")

    if not os.path.exists(path):
        raise RuntimeError(f"Missing domain metadata: {path}")

    df = pd.read_csv(path, dtype={"snapshots": str})

    if df.empty:
        raise RuntimeError(f"Empty domain metadata: {path}")

    row = df.iloc[0]

    particle_path = row.get("particle_path", "")
    if pd.isna(particle_path):
        particle_path = ""

    snapshots = None
    if "snapshots" in row.index:
        snapshot_value = row["snapshots"]
        if not pd.isna(snapshot_value) and str(snapshot_value).strip():
            snapshots = {
                int(value)
                for value in str(snapshot_value).split(";")
                if value.strip()
            }

    return {
        "tree_type": str(row.get("tree_type", "binary")),
        "split_criterion": row.get("split_criterion", None),
        "tree_bounds": tuple(
            float(row.get("tree_" + bound, row[bound]))
            for bound in ("xmin", "xmax", "ymin", "ymax", "zmin", "zmax")
        ),
        "xmin": float(row["xmin"]),
        "xmax": float(row["xmax"]),
        "ymin": float(row["ymin"]),
        "ymax": float(row["ymax"]),
        "zmin": float(row["zmin"]),
        "zmax": float(row["zmax"]),
        "dataset_kind": str(row.get("dataset_kind", "series")),
        "particle_pattern": str(row.get("particle_pattern", "xyz_{snapshot}")),
        "particle_layout": str(row.get("particle_layout", "xyz_charge")),
        "snapshots": snapshots,
        "particle_path": str(particle_path),
    }


def load_frame_metadata():
    path = os.path.join(TREE_DIR, "frames.csv")
    if not os.path.exists(path):
        return None

    df = pd.read_csv(path, dtype=str)
    count_columns = (
        "num_particle_slots",
        "num_active_particles",
        "num_escaped_particles",
    )
    missing = {"snapshot", *count_columns} - set(df.columns)
    if missing:
        raise RuntimeError(f"Missing columns in {path}: {sorted(missing)}")

    metadata = {}
    for row in df.to_dict("records"):
        try:
            snapshot = int(row["snapshot"])
            counts = {column: int(row[column]) for column in count_columns}
        except (TypeError, ValueError) as exc:
            raise RuntimeError(
                f"Invalid integer particle counts in {path}: {row}"
            ) from exc

        if snapshot in metadata:
            raise RuntimeError(f"Duplicate snapshot {snapshot} in {path}")

        if (
            any(value < 0 for value in counts.values())
            or counts["num_active_particles"] + counts["num_escaped_particles"]
            != counts["num_particle_slots"]
        ):
            raise RuntimeError(
                f"Inconsistent particle counts for snapshot {snapshot} in {path}"
            )

        metadata[snapshot] = counts

    return metadata


# ============================================================================
# Find available tree frames
# ============================================================================

def find_tree_frames():
    files = glob.glob(os.path.join(TREE_DIR, "tree_*.csv"))
    frames = []

    for path in files:
        match = re.search(r"tree_(\d+)\.csv$", path)
        if match is None:
            continue

        snapshot = int(match.group(1))
        selected_snapshots = DOMAIN["snapshots"]

        if selected_snapshots is not None and snapshot not in selected_snapshots:
            continue

        frames.append({"snapshot": snapshot, "path": path})

    frames.sort(key=lambda frame: frame["snapshot"])

    if not frames:
        raise RuntimeError(f"No tree frames found in {TREE_DIR}")

    return frames


def select_tree_run(run):
    global TREE_DIR, DOMAIN, TREE_LABEL, FRAME_METADATA, FRAMES, DATASET_KIND, ACTIVE_RUN
    global BOX_BOUNDS, AXIS_BOUNDS, DOMAIN_SIZE, DOMAIN_CENTER
    global SCENE_BOUNDS, SCENE_CENTER, SCENE_SIZE
    global DEFAULT_SLICE_AXIS, DEFAULT_SLICE_POS, DEFAULT_SLICE_THICKNESS

    if run not in {item["value"] for item in RUNS}:
        raise ValueError(f"Unknown benchmark run: {run!r}")
    TREE_DIR = os.path.join(TREE_ROOT_DIR, run)
    DOMAIN = load_domain_meta()
    if DOMAIN["tree_type"] not in ("binary", "octree"):
        raise RuntimeError(f"Unknown tree_type: {DOMAIN['tree_type']}")
    TREE_LABEL = "KDTree3D" if DOMAIN["tree_type"] == "binary" else "Octree"
    FRAME_METADATA = load_frame_metadata()
    FRAMES = find_tree_frames()
    if FRAME_METADATA is not None:
        missing = {frame["snapshot"] for frame in FRAMES} - FRAME_METADATA.keys()
        if missing:
            raise RuntimeError(f"Missing particle metadata for snapshots: {sorted(missing)}")

    BOX_BOUNDS = tuple(DOMAIN[key] for key in ("xmin", "xmax", "ymin", "ymax", "zmin", "zmax"))
    AXIS_BOUNDS = {axis: BOX_BOUNDS[2 * i:2 * i + 2] for i, axis in enumerate("xyz")}
    DOMAIN_SIZE = max(high - low for low, high in AXIS_BOUNDS.values())
    if DOMAIN_SIZE <= 0.0:
        raise RuntimeError(f"Invalid domain bounds: {BOX_BOUNDS}")
    DOMAIN_CENTER = np.array([0.5 * sum(bounds) for bounds in AXIS_BOUNDS.values()])

    # Octree key space can extend beyond the physical particle domain.
    SCENE_BOUNDS = DOMAIN["tree_bounds"]
    SCENE_CENTER = np.array([
        0.5 * (SCENE_BOUNDS[i] + SCENE_BOUNDS[i + 1]) for i in (0, 2, 4)
    ])
    SCENE_SIZE = max(SCENE_BOUNDS[i + 1] - SCENE_BOUNDS[i] for i in (0, 2, 4))
    DEFAULT_SLICE_AXIS = "x"
    DEFAULT_SLICE_POS = 0.5 * sum(AXIS_BOUNDS[DEFAULT_SLICE_AXIS])
    DEFAULT_SLICE_THICKNESS = 0.02 * DOMAIN_SIZE
    DATASET_KIND = DOMAIN["dataset_kind"]
    ACTIVE_RUN = run


select_tree_run(RUNS[0]["value"])

print(f"Found {len(FRAMES)} tree frames")
print(f"Snapshots: {FRAMES[0]['snapshot']} .. {FRAMES[-1]['snapshot']}")


# ============================================================================
# Benchmark charts (render once per run; markers move in the browser)
# ============================================================================

def benchmark_charts():
    snapshots = [frame["snapshot"] for frame in FRAMES]
    padding = max(1.0, 0.03 * (snapshots[-1] - snapshots[0]))
    limits = (snapshots[0] - padding, snapshots[-1] + padding)
    try:
        data = pd.read_csv(BENCHMARK_PATH)
    except (OSError, pd.errors.ParserError, pd.errors.EmptyDataError) as exc:
        return [], f"Benchmark plots unavailable: {exc}", limits

    if "snapshot" not in data:
        return [], "Benchmark CSV has no snapshot column.", limits
    for column in ("tree_type", "split_criterion"):
        if column not in data:
            continue  # Older CSVs do not contain run metadata.
        expected = DOMAIN.get(column)
        if pd.notna(expected):
            data = data.loc[data[column] == expected]
        elif data[column].nunique() > 1:
            return [], f"Ambiguous benchmark {column}; regenerate domain.csv.", limits
    data = data.copy()
    data["snapshot"] = pd.to_numeric(data["snapshot"], errors="coerce")
    initial_snapshot = data["snapshot"].min()
    data = data.loc[data["snapshot"].isin(snapshots)]
    if data.empty:
        return [], "No benchmark rows match this run and its snapshots.", limits
    if data["snapshot"].duplicated().any():
        return [], "Multiple benchmark rows match a snapshot in this run.", limits
    missing_count = len(snapshots) - len(data)
    data = data.set_index("snapshot").reindex(snapshots)
    # Keep gaps for missing rows instead of connecting unrelated measurements.
    if "compute_total_ms" not in data and "tree_ms" in data:
        data["phase_total_ms"] = data["tree_ms"] + data.get("view_ms", 0)

    metrics = (
        ("Tree size", "Count", (("num_nodes", "Nodes"), ("num_leaves", "Leaves"))),
        ("Tree and view GPU time", "ms", (
            ("tree_ms", "Tree, direct"), ("view_ms", "View, direct"),
            ("graph_tree_ms", "Tree, graph"), ("graph_view_ms", "View, graph"),
        )),
        ("Compute time", "ms", (
            ("compute_total_ms", "Direct (wall)"),
            ("graph_compute_total_ms", "Graph (wall)"),
            ("phase_total_ms", "Tree + view (legacy)"),
        )),
        ("Maximum depth", "Depth", (("max_depth", "Depth"),)),
        ("Empty leaves", "%", (("empty_leaf_percent", "Empty leaves"),)),
        ("Average leaf population", "Particles / leaf", (
            ("avg_particles_per_leaf", "Particles / leaf"),
        )),
        ("Particle population", "Count", (
            ("num_active_particles", "Active"), ("num_escaped_particles", "Escaped"),
            ("num_particle_slots", "Slots"),
        )),
    )
    charts = []
    for title, ylabel, series in metrics:
        timing_plot = any(column.endswith("_ms") for column, _ in series)
        initial_values = []
        figure = Figure(figsize=(4.8, 1.85))
        axes = figure.subplots()
        # These fractions also define the CSS marker's exact plot rectangle.
        figure.subplots_adjust(left=0.16, right=0.98, bottom=0.25, top=0.95)
        for index, (column, label) in enumerate(series):
            if column not in data:
                continue
            values = pd.to_numeric(data[column], errors="coerce").copy()
            if timing_plot and initial_snapshot in values.index:
                initial = values.loc[initial_snapshot]
                if pd.notna(initial) and not column.startswith("graph_"):
                    initial_values.append(f"{label.split(',')[0]}: {initial:.3g} ms")
                # The full build uses wall timing and can include CUDA startup.
                # Only subsequent GPU updates belong on the incremental curves.
                values.loc[initial_snapshot] = np.nan
            if not values.notna().any():
                continue
            color = {"graph_tree_ms": "C0", "graph_view_ms": "C1",
                     "graph_compute_total_ms": "C0"}.get(column, f"C{index}")
            axes.plot(snapshots, values, label=label, color=color,
                      linestyle="--" if column.startswith("graph_") else "-",
                      marker="o" if len(snapshots) < 20 else None, markersize=3)
        if axes.lines:
            if len(series) > 1:
                axes.legend(fontsize=7, ncol=2, loc="best")
            axes.set_ylim(bottom=0)
        else:
            message = "No incremental updates" if timing_plot else "Not recorded"
            axes.text(0.5, 0.5, message, ha="center", va="center",
                      transform=axes.transAxes, fontsize=9)
        axes.set_xlim(*limits)
        axes.set_xlabel("Snapshot", fontsize=8)
        axes.set_ylabel(ylabel, fontsize=8)
        axes.tick_params(labelsize=7)
        axes.grid(alpha=0.2)
        output = io.BytesIO()
        figure.savefig(output, format="svg")
        note = "Initial (wall) — " + "; ".join(initial_values) if initial_values else ""
        charts.append({"title": title, "note": note, "image": "data:image/svg+xml;base64," +
                       base64.b64encode(output.getvalue()).decode("ascii")})
        figure.clear()
    note = f"{missing_count} snapshots have no benchmark measurements." if missing_count else ""
    return charts, note, limits


# ============================================================================
# Particle loading
# ============================================================================

def particle_file_for_snapshot(snapshot):
    if DATASET_KIND == "single":
        path = DOMAIN["particle_path"]
        if not path:
            raise RuntimeError(
                "dataset_kind='single' requires particle_path in domain.csv"
            )
        return path

    directory = (
        DOMAIN["particle_path"]
        or os.path.join(PROJECT_DIR, "tests", "test_data", "simdata")
    )

    try:
        filename = DOMAIN["particle_pattern"].format(snapshot=snapshot)
    except Exception as exc:
        raise RuntimeError(
            "Could not format particle_pattern "
            f"{DOMAIN['particle_pattern']!r} for snapshot {snapshot}"
        ) from exc

    return os.path.join(directory, filename)


def load_particles(snapshot):
    """
    Load x/y/z AND the fourth scalar quantity.

    xyz_charge:
        col 0,1,2 -> xyz
        col 3     -> charge

    charge_xyz:
        col 0     -> charge
        col 1,2,3 -> xyz
    """
    path = particle_file_for_snapshot(snapshot)

    if not os.path.exists(path):
        raise RuntimeError(
            "Particle snapshot not found:\n"
            f"  snapshot: {snapshot}\n"
            f"  path:     {path}"
        )

    layout = DOMAIN["particle_layout"]

    if layout == "charge_xyz":
        # Read charge,x,y,z in source order.
        usecols = (0, 1, 2, 3)
        charge_column = 0
        xyz_columns = (1, 2, 3)
    elif layout == "xyz_charge":
        # Read x,y,z,charge in source order.
        usecols = (0, 1, 2, 3)
        xyz_columns = (0, 1, 2)
        charge_column = 3
    else:
        raise RuntimeError(
            f"Unsupported particle_layout {layout!r}. "
            "Expected 'xyz_charge' or 'charge_xyz'."
        )

    counts = {
        "num_particle_slots": 0,
        "num_escaped_particles": 0,
    }

    def active_rows(source):
        for line in source:
            content = line.partition("#")[0].strip()
            if not content:
                continue

            counts["num_particle_slots"] += 1

            if content == "ESC":
                counts["num_escaped_particles"] += 1
                continue

            yield line

    with open(path, encoding="utf-8") as source:
        rows = active_rows(source)
        first = next(rows, None)

        if first is None:
            raw = np.empty((0, 4), dtype=np.float64)
        else:
            raw = np.loadtxt(
                itertools.chain((first,), rows),
                comments="#",
                usecols=usecols,
                dtype=np.float64,
            )

    if raw.size == 0:
        raw = np.empty((0, 4), dtype=np.float64)
    elif raw.ndim == 1:
        raw = raw.reshape(1, 4)

    if raw.ndim != 2 or raw.shape[1] != 4:
        raise RuntimeError(
            f"Unexpected particle data shape {raw.shape} in {path}"
        )

    points = raw[:, xyz_columns]
    charge = raw[:, charge_column]

    if not np.all(np.isfinite(points)):
        raise RuntimeError(f"Non-finite particle coordinates in {path}")

    if not np.all(np.isfinite(charge)):
        raise RuntimeError(f"Non-finite particle charge values in {path}")

    total = int(points.shape[0])
    counts["num_active_particles"] = total

    if FRAME_METADATA is not None:
        expected = FRAME_METADATA.get(snapshot)
        if expected is None:
            raise RuntimeError(
                f"Missing particle metadata for snapshot {snapshot} in frames.csv"
            )
        if counts != expected:
            raise RuntimeError(
                f"Particle counts disagree for snapshot {snapshot}: "
                f"frames.csv has {expected}, but {path} has {counts}"
            )

    if total > MAX_RENDERED_PARTICLES:
        # Keep the particles with the largest absolute charge/mass.
        indices = np.argpartition(
            np.abs(charge),
            -MAX_RENDERED_PARTICLES,
        )[-MAX_RENDERED_PARTICLES:]

        points = points[indices]
        charge = charge[indices]

    particles = pv.PolyData(points)
    particles.point_data[PARTICLE_SCALAR_NAME] = np.asarray(
        charge, dtype=np.float64
    )

    particles.field_data["total_particles"] = np.array([total], dtype=np.int64)

    for name, count in counts.items():
        particles.field_data[name] = np.array([count], dtype=np.int64)

    return particles


def particle_charge_range(particles):
    if particles.n_points == 0 or PARTICLE_SCALAR_NAME not in particles.point_data:
        return (0.0, 1.0)

    values = np.asarray(particles.point_data[PARTICLE_SCALAR_NAME], dtype=float)

    if values.size == 0:
        return (0.0, 1.0)

    lo = float(np.min(values))
    hi = float(np.max(values))

    if lo == hi:
        pad = max(abs(lo) * 0.05, 1.0e-12)
        return (lo - pad, hi + pad)

    return (lo, hi)


def particle_summary(particles):
    active = int(particles.field_data["num_active_particles"][0])
    escaped = int(particles.field_data["num_escaped_particles"][0])
    slots = int(particles.field_data["num_particle_slots"][0])

    if particles.n_points:
        q = np.asarray(particles.point_data[PARTICLE_SCALAR_NAME], dtype=float)
        q_text = f"; charge {np.min(q):.4g} .. {np.max(q):.4g}"
    else:
        q_text = ""

    return (
        f"{active} active, {escaped} escaped / {slots} slots; "
        f"{particles.n_points} rendered{q_text}"
    )


# ============================================================================
# Charge-scaled particle glyphs
# ============================================================================

def build_particle_glyphs(particles, radius_multiplier=1.0):
    """
    Turn particle points into sphere glyphs.

    Color:
        original signed charge

    Size:
        normalized absolute charge

    A nonzero minimum scale means q=0 particles remain visible.
    """
    if particles.n_points == 0:
        return pv.PolyData()

    charge = np.asarray(
        particles.point_data[PARTICLE_SCALAR_NAME],
        dtype=np.float64,
    )

    magnitude = np.abs(charge)
    max_magnitude = float(np.max(magnitude)) if magnitude.size else 0.0

    if max_magnitude > 0.0:
        normalized = magnitude / max_magnitude
    else:
        normalized = np.zeros_like(magnitude)

    scale_range = PARTICLE_GLYPH_MAX_SCALE - PARTICLE_GLYPH_MIN_SCALE
    size_scale = PARTICLE_GLYPH_MIN_SCALE + scale_range * normalized

    source_points = particles.copy(deep=True)
    source_points.point_data["particle_size"] = size_scale
    source_points.point_data[PARTICLE_SCALAR_NAME] = charge

    sphere = pv.Sphere(
        radius=PARTICLE_GLYPH_BASE_RADIUS_FACTOR
        * DOMAIN_SIZE
        * radius_multiplier,
        theta_resolution=PARTICLE_GLYPH_THETA_RESOLUTION,
        phi_resolution=PARTICLE_GLYPH_PHI_RESOLUTION,
    )

    glyphs = source_points.glyph(
        scale="particle_size",
        geom=sphere,
        orient=False,
        factor=1.0,
    )

    return glyphs


# ============================================================================
# Leaf geometry
# ============================================================================

def reconstruct_boxes(csv_file):
    """Read the leaves and physical bounds exported directly from K."""
    columns = [
        "node", "depth", "split", "particle_count",
        "xmin", "xmax", "ymin", "ymax", "zmin", "zmax",
    ]

    df = pd.read_csv(csv_file)
    missing = set(columns) - set(df.columns)

    if missing:
        raise RuntimeError(
            f"Missing tree columns in {csv_file}: {sorted(missing)}"
        )

    if df.empty:
        raise RuntimeError(f"Empty tree CSV: {csv_file}")

    if df["split"].ne(0).any():
        raise RuntimeError(f"Expected one row per leaf in {csv_file}")

    for axis in "xyz":
        if (df[axis + "min"] >= df[axis + "max"]).any():
            raise RuntimeError(f"Invalid {axis} bounds in {csv_file}")

    return df[columns].to_dict("records")


# ============================================================================
# Full 3D leaf wireframe
# ============================================================================

EDGE_PAIRS = np.array(
    [
        [0, 1], [1, 2], [2, 3], [3, 0],
        [4, 5], [5, 6], [6, 7], [7, 4],
        [0, 4], [1, 5], [2, 6], [3, 7],
    ],
    dtype=np.int64,
)


def build_leaf_mesh(boxes):
    leaves = [box for box in boxes if box["split"] == 0]
    n = len(leaves)

    if n == 0:
        raise RuntimeError("No leaf boxes found")

    xmin = np.fromiter((box["xmin"] for box in leaves), dtype=np.float64, count=n)
    xmax = np.fromiter((box["xmax"] for box in leaves), dtype=np.float64, count=n)
    ymin = np.fromiter((box["ymin"] for box in leaves), dtype=np.float64, count=n)
    ymax = np.fromiter((box["ymax"] for box in leaves), dtype=np.float64, count=n)
    zmin = np.fromiter((box["zmin"] for box in leaves), dtype=np.float64, count=n)
    zmax = np.fromiter((box["zmax"] for box in leaves), dtype=np.float64, count=n)
    depth = np.fromiter((box["depth"] for box in leaves), dtype=np.int32, count=n)

    corners = np.empty((n, 8, 3), dtype=np.float64)

    corners[:, 0] = np.stack([xmin, ymin, zmin], axis=1)
    corners[:, 1] = np.stack([xmax, ymin, zmin], axis=1)
    corners[:, 2] = np.stack([xmax, ymax, zmin], axis=1)
    corners[:, 3] = np.stack([xmin, ymax, zmin], axis=1)
    corners[:, 4] = np.stack([xmin, ymin, zmax], axis=1)
    corners[:, 5] = np.stack([xmax, ymin, zmax], axis=1)
    corners[:, 6] = np.stack([xmax, ymax, zmax], axis=1)
    corners[:, 7] = np.stack([xmin, ymax, zmax], axis=1)

    points = corners.reshape(-1, 3)

    box_offsets = (np.arange(n, dtype=np.int64) * 8)[:, None, None]
    edges = EDGE_PAIRS[None, :, :] + box_offsets

    lines = np.empty((n, 12, 3), dtype=np.int64)
    lines[:, :, 0] = 2
    lines[:, :, 1:] = edges

    mesh = pv.PolyData(points, lines=lines.reshape(-1))
    mesh.cell_data["depth"] = np.repeat(depth, 12)

    return mesh


# ============================================================================
# Slice mesh
# ============================================================================

def build_slice_mesh(boxes, axis="x", slice_pos=0.5):
    leaves = [box for box in boxes if box["split"] == 0]
    selected = []

    for box in leaves:
        if axis == "x":
            intersects = box["xmin"] <= slice_pos < box["xmax"]
        elif axis == "y":
            intersects = box["ymin"] <= slice_pos < box["ymax"]
        elif axis == "z":
            intersects = box["zmin"] <= slice_pos < box["zmax"]
        else:
            raise ValueError(f"Unknown slice axis: {axis}")

        if intersects:
            selected.append(box)

    if not selected:
        return pv.PolyData()

    points = []
    lines = []
    depths = []

    for box in selected:
        xmin, xmax = box["xmin"], box["xmax"]
        ymin, ymax = box["ymin"], box["ymax"]
        zmin, zmax = box["zmin"], box["zmax"]
        depth = box["depth"]

        if axis == "x":
            rectangle = [
                [slice_pos, ymin, zmin],
                [slice_pos, ymax, zmin],
                [slice_pos, ymax, zmax],
                [slice_pos, ymin, zmax],
            ]
        elif axis == "y":
            rectangle = [
                [xmin, slice_pos, zmin],
                [xmax, slice_pos, zmin],
                [xmax, slice_pos, zmax],
                [xmin, slice_pos, zmax],
            ]
        else:
            rectangle = [
                [xmin, ymin, slice_pos],
                [xmax, ymin, slice_pos],
                [xmax, ymax, slice_pos],
                [xmin, ymax, slice_pos],
            ]

        offset = len(points)
        points.extend(rectangle)

        for a, b in [(0, 1), (1, 2), (2, 3), (3, 0)]:
            lines.extend([2, offset + a, offset + b])
            depths.append(depth)

    mesh = pv.PolyData(
        np.asarray(points, dtype=np.float64),
        lines=np.asarray(lines, dtype=np.int64),
    )
    mesh.cell_data["depth"] = np.asarray(depths, dtype=np.int32)

    return mesh


# ============================================================================
# Particle slice
# ============================================================================

def build_particle_slice(
    particles,
    axis="x",
    slice_pos=0.5,
    thickness=0.02,
):
    points = particles.points

    if points.shape[0] == 0:
        return pv.PolyData()

    if axis == "x":
        values = points[:, 0]
    elif axis == "y":
        values = points[:, 1]
    elif axis == "z":
        values = points[:, 2]
    else:
        raise ValueError(f"Unknown slice axis: {axis}")

    half = 0.5 * thickness
    mask = np.abs(values - slice_pos) <= half

    sliced = pv.PolyData(points[mask])

    # IMPORTANT: preserve charge in the slice.
    if PARTICLE_SCALAR_NAME in particles.point_data:
        sliced.point_data[PARTICLE_SCALAR_NAME] = np.asarray(
            particles.point_data[PARTICLE_SCALAR_NAME]
        )[mask]

    # Preserve count metadata for convenience/debugging.
    for name in particles.field_data.keys():
        sliced.field_data[name] = particles.field_data[name]

    return sliced


# ============================================================================
# Load one complete frame
# ============================================================================

def validate_frame_particle_counts(snapshot, boxes, particles):
    active = int(particles.field_data["num_active_particles"][0])
    leaf_count = sum(
        box["particle_count"]
        for box in boxes
        if box["split"] == 0
    )

    if (
        leaf_count != active
        or any(
            box["particle_count"] < 0 or box["particle_count"] > active
            for box in boxes
        )
    ):
        raise RuntimeError(
            f"Tree particle counts disagree for snapshot {snapshot}: "
            f"{active} active particles, leaf sum {leaf_count}"
        )


def load_frame(frame_index):
    if frame_index < 0 or frame_index >= len(FRAMES):
        raise IndexError(
            f"Frame index {frame_index} outside [0, {len(FRAMES) - 1}]"
        )

    frame = FRAMES[frame_index]
    snapshot = frame["snapshot"]

    boxes = reconstruct_boxes(frame["path"])
    particles = load_particles(snapshot)

    validate_frame_particle_counts(snapshot, boxes, particles)

    mesh = build_leaf_mesh(boxes)

    return snapshot, mesh, particles, boxes


# ============================================================================
# Particle-cloud statistics
# ============================================================================

def particle_cloud_statistics(particles, fallback_center, minimum_radius):
    points = particles.points

    if points.shape[0] == 0:
        return (
            np.asarray(fallback_center, dtype=np.float64).copy(),
            minimum_radius,
        )

    center = np.mean(points, axis=0)
    distances = np.linalg.norm(points - center, axis=1)

    if distances.size == 0:
        radius = minimum_radius
    else:
        radius = float(np.max(distances))

    if not np.isfinite(radius):
        radius = minimum_radius

    radius = max(radius, minimum_radius)

    return center, radius


# ============================================================================
# Video rendering
# ============================================================================

def create_timeline_video(output_path=VIDEO_OUTPUT, fps=VIDEO_FPS):
    if VIDEO_FRAME_STRIDE < 1:
        raise RuntimeError("VIDEO_FRAME_STRIDE must be >= 1")

    video_indices = list(range(0, len(FRAMES), VIDEO_FRAME_STRIDE))
    final_index = len(FRAMES) - 1

    if video_indices[-1] != final_index:
        video_indices.append(final_index)

    print()
    print("=" * 72)
    print("Creating timeline video")
    print("=" * 72)
    print(f"Output:       {output_path}")
    print(f"Tree frames:  {len(FRAMES)}")
    print(f"Video frames: {len(video_indices)}")
    print(f"Frame stride: {VIDEO_FRAME_STRIDE}")
    print(f"FPS:          {fps}")
    print(f"Resolution:   {VIDEO_WINDOW_SIZE[0]} x {VIDEO_WINDOW_SIZE[1]}")
    print(f"Duration:     {len(video_indices) / fps:.2f} s")
    print()

    snapshot, mesh, particles, boxes = load_frame(video_indices[0])

    minimum_radius = 0.01 * DOMAIN_SIZE

    initial_particle_center, initial_particle_radius = particle_cloud_statistics(
        particles,
        fallback_center=DOMAIN_CENTER,
        minimum_radius=minimum_radius,
    )

    print("Initial particle center:", initial_particle_center)
    print("Initial rendered-particle radius:", initial_particle_radius)

    camera_min_distance = VIDEO_CAMERA_MIN_DISTANCE_FACTOR * DOMAIN_SIZE
    camera_max_distance = VIDEO_CAMERA_MAX_DISTANCE_FACTOR * SCENE_SIZE
    camera_final_distance = VIDEO_CAMERA_FINAL_DISTANCE_FACTOR * SCENE_SIZE

    initial_camera_distance = float(
        np.clip(
            VIDEO_CAMERA_DISTANCE_FACTOR * initial_particle_radius,
            camera_min_distance,
            camera_max_distance,
        )
    )

    smoothed_center = initial_particle_center.copy()
    camera_distance = initial_camera_distance

    video_plotter = pv.Plotter(
        off_screen=True,
        window_size=VIDEO_WINDOW_SIZE,
    )
    video_plotter.set_background("white")

    video_octree_actor = video_plotter.add_mesh(
        mesh,
        scalars="depth",
        cmap="turbo",
        opacity=VIDEO_OCTREE_OPACITY,
        show_scalar_bar=True,
        scalar_bar_args={"title": f"{TREE_LABEL} depth"},
        line_width=VIDEO_OCTREE_LINE_WIDTH,
        render=False,
    )

    video_particle_glyphs = build_particle_glyphs(
        particles,
        radius_multiplier=VIDEO_PARTICLE_RADIUS_MULTIPLIER,
    )

    video_particle_actor = video_plotter.add_mesh(
        video_particle_glyphs,
        scalars=PARTICLE_SCALAR_NAME,
        cmap=PARTICLE_CMAP,
        clim=particle_charge_range(particles),
        opacity=VIDEO_PARTICLE_OPACITY,
        show_scalar_bar=True,
        scalar_bar_args={"title": "Particle charge"},
        render=False,
    )

    video_domain = pv.Box(bounds=BOX_BOUNDS)

    video_plotter.add_mesh(
        video_domain,
        style="wireframe",
        color="white",
        opacity=0.12,
        line_width=1,
        render=False,
    )

    video_plotter.add_axes()

    initial_camera_height = VIDEO_CAMERA_HEIGHT_FACTOR * camera_distance

    video_plotter.camera_position = [
        (
            initial_particle_center[0] + camera_distance,
            initial_particle_center[1],
            initial_particle_center[2] + initial_camera_height,
        ),
        tuple(initial_particle_center),
        (0.0, 0.0, 1.0),
    ]

    video_plotter.reset_camera_clipping_range()

    video_plotter.add_text(
        f"Snapshot {snapshot}\n{particle_summary(particles)}",
        position="upper_left",
        font_size=18,
        color="white",
        name="snapshot_text",
    )

    video_plotter.open_movie(output_path, framerate=fps)

    try:
        for video_frame_number, frame_index in enumerate(video_indices):
            snapshot, mesh, particles, boxes = load_frame(frame_index)

            print(
                f"Video frame {video_frame_number + 1}/{len(video_indices)} "
                f"- source frame {frame_index + 1}/{len(FRAMES)} "
                f"- snapshot {snapshot}, "
                f"{mesh.n_cells} {TREE_LABEL} edges, "
                f"{particle_summary(particles)}"
            )

            video_plotter.remove_actor(video_octree_actor, render=False)

            video_octree_actor = video_plotter.add_mesh(
                mesh,
                scalars="depth",
                cmap="turbo",
                opacity=VIDEO_OCTREE_OPACITY,
                show_scalar_bar=False,
                line_width=VIDEO_OCTREE_LINE_WIDTH,
                render=False,
            )

            # Glyph topology changes when charge/particle count changes, so
            # recreate the particle actor for each video frame.
            video_plotter.remove_actor(video_particle_actor, render=False)

            video_particle_glyphs = build_particle_glyphs(
                particles,
                radius_multiplier=VIDEO_PARTICLE_RADIUS_MULTIPLIER,
            )

            video_particle_actor = video_plotter.add_mesh(
                video_particle_glyphs,
                scalars=PARTICLE_SCALAR_NAME,
                cmap=PARTICLE_CMAP,
                clim=particle_charge_range(particles),
                opacity=VIDEO_PARTICLE_OPACITY,
                show_scalar_bar=False,
                render=False,
            )

            video_plotter.add_text(
                f"Snapshot {snapshot}\n{particle_summary(particles)}",
                position="upper_left",
                font_size=18,
                color="white",
                name="snapshot_text",
            )

            if len(video_indices) <= 1:
                progress = 1.0
            else:
                progress = video_frame_number / (len(video_indices) - 1)

            current_center, current_radius = particle_cloud_statistics(
                particles,
                fallback_center=smoothed_center,
                minimum_radius=minimum_radius,
            )

            smoothed_center = (
                (1.0 - VIDEO_CAMERA_CENTER_SMOOTHING) * smoothed_center
                + VIDEO_CAMERA_CENTER_SMOOTHING * current_center
            )

            particle_required_distance = (
                VIDEO_CAMERA_DISTANCE_FACTOR * current_radius
            )

            if VIDEO_FULL_DOMAIN_AT_PROGRESS <= 0.0:
                zoom_t = 1.0
            else:
                zoom_t = clamp01(
                    progress / VIDEO_FULL_DOMAIN_AT_PROGRESS
                )

            zoom_progress = smoothstep(zoom_t)

            forced_distance = (
                (1.0 - zoom_progress) * initial_camera_distance
                + zoom_progress * camera_final_distance
            )

            desired_distance = max(
                particle_required_distance,
                forced_distance,
            )

            desired_distance = float(
                np.clip(
                    desired_distance,
                    camera_min_distance,
                    camera_max_distance,
                )
            )

            if desired_distance > camera_distance:
                camera_distance += (
                    VIDEO_CAMERA_ZOOM_OUT_SMOOTHING
                    * (desired_distance - camera_distance)
                )

                if desired_distance > 1.15 * camera_distance:
                    camera_distance = (
                        0.25 * camera_distance
                        + 0.75 * desired_distance
                    )

            camera_distance = float(
                np.clip(
                    camera_distance,
                    camera_min_distance,
                    camera_max_distance,
                )
            )

            blend_denominator = (
                VIDEO_DOMAIN_CENTER_BLEND_END
                - VIDEO_DOMAIN_CENTER_BLEND_START
            )

            if blend_denominator <= 0.0:
                center_blend_t = (
                    1.0
                    if progress >= VIDEO_DOMAIN_CENTER_BLEND_START
                    else 0.0
                )
            else:
                center_blend_t = clamp01(
                    (
                        progress
                        - VIDEO_DOMAIN_CENTER_BLEND_START
                    )
                    / blend_denominator
                )

            center_blend = smoothstep(center_blend_t)

            camera_target = (
                (1.0 - center_blend) * smoothed_center
                + center_blend * SCENE_CENTER
            )

            if VIDEO_ORBIT_END_PROGRESS <= 0.0:
                orbit_t = 1.0
            else:
                orbit_t = clamp01(
                    progress / VIDEO_ORBIT_END_PROGRESS
                )

            orbit_progress = smoothstep(orbit_t)

            angle = (
                2.0
                * np.pi
                * VIDEO_CAMERA_ORBITS
                * orbit_progress
            )

            camera_height = VIDEO_CAMERA_HEIGHT_FACTOR * camera_distance

            camera_x = (
                camera_target[0]
                + camera_distance * np.cos(angle)
            )

            camera_y = (
                camera_target[1]
                + camera_distance * np.sin(angle)
            )

            camera_z = camera_target[2] + camera_height

            video_plotter.camera_position = [
                (camera_x, camera_y, camera_z),
                tuple(camera_target),
                (0.0, 0.0, 1.0),
            ]

            video_plotter.reset_camera_clipping_range()
            video_plotter.render()
            video_plotter.write_frame()

    finally:
        video_plotter.close()

    print()
    print("=" * 72)
    print(f"Video written to: {output_path}")
    print("=" * 72)
    print()


# ============================================================================
# Initial interactive frame
# ============================================================================

(
    initial_snapshot,
    initial_mesh,
    initial_particles,
    initial_boxes,
) = load_frame(0)

initial_slice_mesh = build_slice_mesh(
    initial_boxes,
    axis=DEFAULT_SLICE_AXIS,
    slice_pos=DEFAULT_SLICE_POS,
)

initial_particle_slice = build_particle_slice(
    initial_particles,
    axis=DEFAULT_SLICE_AXIS,
    slice_pos=DEFAULT_SLICE_POS,
    thickness=DEFAULT_SLICE_THICKNESS,
)

initial_particle_glyphs = build_particle_glyphs(initial_particles)

initial_particle_slice_glyphs = build_particle_glyphs(
    initial_particle_slice,
    radius_multiplier=SLICE_PARTICLE_RADIUS_MULTIPLIER,
)

print(
    f"Initial snapshot {initial_snapshot}: "
    f"{len(initial_boxes)} nodes, "
    f"{particle_summary(initial_particles)}"
)


# ============================================================================
# Interactive PyVista scene
# ============================================================================

plotter = pv.Plotter()

plotter.enable_trackball_style()
plotter.enable_fly_to_right_click()
plotter.set_background("white")


# ----------------------------------------------------------------------------
# Full tree
# ----------------------------------------------------------------------------

octree_actor = plotter.add_mesh(
    initial_mesh,
    scalars="depth",
    cmap="turbo",
    show_scalar_bar=True,
    scalar_bar_args={"title": "Tree depth"},
    line_width=1,
)


# ----------------------------------------------------------------------------
# Tree slice
# ----------------------------------------------------------------------------

slice_actor = plotter.add_mesh(
    initial_slice_mesh,
    scalars="depth",
    cmap="turbo",
    show_scalar_bar=False,
    line_width=2,
)

slice_actor.SetVisibility(False)


# ----------------------------------------------------------------------------
# Full particles: charge -> color and |charge| -> size
# ----------------------------------------------------------------------------

particle_actor = plotter.add_mesh(
    initial_particle_glyphs,
    scalars=PARTICLE_SCALAR_NAME,
    cmap=PARTICLE_CMAP,
    clim=particle_charge_range(initial_particles),
    opacity=0.75,
    show_scalar_bar=True,
    scalar_bar_args={"title": "Particle charge"},
)


# ----------------------------------------------------------------------------
# Particle slice
# ----------------------------------------------------------------------------

if initial_particle_slice_glyphs.n_points == 0:
    particle_slice_actor = plotter.add_mesh(
        initial_particle_slice_glyphs,
        color="white",
        opacity=0.95,
        show_scalar_bar=False,
    )
else:
    particle_slice_actor = plotter.add_mesh(
        initial_particle_slice_glyphs,
        scalars=PARTICLE_SCALAR_NAME,
        cmap=PARTICLE_CMAP,
        clim=particle_charge_range(initial_particles),
        opacity=0.95,
        show_scalar_bar=False,
    )

particle_slice_actor.SetVisibility(False)


# ----------------------------------------------------------------------------
# Domain
# ----------------------------------------------------------------------------

domain = pv.Box(bounds=BOX_BOUNDS)

domain_actor = plotter.add_mesh(
    domain,
    style="wireframe",
    color="white",
    opacity=0.25,
    line_width=2,
)


# ----------------------------------------------------------------------------
# Camera / axes
# ----------------------------------------------------------------------------

plotter.show_grid()
plotter.add_axes()

_domain_center_tuple = tuple(SCENE_CENTER)

plotter.camera_position = [
    (
        SCENE_CENTER[0] + 1.7 * SCENE_SIZE,
        SCENE_CENTER[1] + 1.7 * SCENE_SIZE,
        SCENE_CENTER[2] + 1.4 * SCENE_SIZE,
    ),
    _domain_center_tuple,
    (0.0, 0.0, 1.0),
]

plotter.reset_camera_clipping_range()


# ============================================================================
# Trame
# ============================================================================

server = get_server()
state = server.state
ctrl = server.controller


# ----------------------------------------------------------------------------
# Timeline state
# ----------------------------------------------------------------------------

state.frame_index = 0
state.snapshot = initial_snapshot
state.num_frames = len(FRAMES)
state.max_frame_index = len(FRAMES) - 1
state.num_nodes = len(initial_boxes)
state.particle_summary = particle_summary(initial_particles)
state.run = ACTIVE_RUN
state.tree_label = TREE_LABEL
state.metric_charts, state.metric_note, metric_limits = benchmark_charts()
state.metric_xmin, state.metric_xmax = metric_limits
state.show_metrics = bool(state.metric_charts)


# ----------------------------------------------------------------------------
# Slice state
# ----------------------------------------------------------------------------

state.slice_enabled = False
state.slice_axis = DEFAULT_SLICE_AXIS

(
    state.slice_pos_min,
    state.slice_pos_max,
) = AXIS_BOUNDS[DEFAULT_SLICE_AXIS]

state.slice_pos = DEFAULT_SLICE_POS
state.slice_thickness_max = 0.5 * DOMAIN_SIZE
state.slice_thickness = DEFAULT_SLICE_THICKNESS
state.slice_particles = True
state.octree_visible = True

_slice_pos_step = 0.01 * DOMAIN_SIZE
_slice_thickness_step = 0.001 * DOMAIN_SIZE


# ============================================================================
# Actor replacement helpers
# ============================================================================

def replace_particle_actor(particles):
    """
    Rebuild full particle glyphs and replace the actor.

    Glyph meshes cannot reliably be shallow-copied when point count/topology
    changes, so replacing the actor is deliberate.
    """
    global particle_actor

    visible = bool(particle_actor.GetVisibility())
    plotter.remove_actor(particle_actor, render=False)

    glyphs = build_particle_glyphs(particles)

    particle_actor = plotter.add_mesh(
        glyphs,
        scalars=PARTICLE_SCALAR_NAME,
        cmap=PARTICLE_CMAP,
        clim=particle_charge_range(particles),
        opacity=0.75,
        show_scalar_bar=False,
        render=False,
    )

    particle_actor.SetVisibility(visible)


def replace_particle_slice_actor(particles):
    global particle_slice_actor

    visible = bool(particle_slice_actor.GetVisibility())
    plotter.remove_actor(particle_slice_actor, render=False)

    glyphs = build_particle_glyphs(
        particles,
        radius_multiplier=SLICE_PARTICLE_RADIUS_MULTIPLIER,
    )

    # If the slice is empty there is no scalar array to map.
    if glyphs.n_points == 0:
        particle_slice_actor = plotter.add_mesh(
            glyphs,
            color="white",
            opacity=0.95,
            show_scalar_bar=False,
            render=False,
        )
    else:
        particle_slice_actor = plotter.add_mesh(
            glyphs,
            scalars=PARTICLE_SCALAR_NAME,
            cmap=PARTICLE_CMAP,
            clim=particle_charge_range(particles),
            opacity=0.95,
            show_scalar_bar=False,
            render=False,
        )

    particle_slice_actor.SetVisibility(visible)


# ============================================================================
# Refresh current slice
# ============================================================================

def refresh_slice(boxes=None, particles=None):
    frame_index = int(state.frame_index)

    if boxes is None or particles is None:
        _, _, particles, boxes = load_frame(frame_index)

    axis = str(state.slice_axis)
    pos = float(state.slice_pos)
    thickness = float(state.slice_thickness)

    slice_mesh = build_slice_mesh(
        boxes,
        axis=axis,
        slice_pos=pos,
    )

    slice_actor.mapper.dataset.shallow_copy(slice_mesh)

    particle_slice = build_particle_slice(
        particles,
        axis=axis,
        slice_pos=pos,
        thickness=thickness,
    )

    replace_particle_slice_actor(particle_slice)


# ============================================================================
# Timeline callback
# ============================================================================

def update_frame(frame_index, **kwargs):
    frame_index = int(frame_index)

    snapshot, mesh, particles, boxes = load_frame(frame_index)

    print(
        f"Loading frame {frame_index + 1}/{len(FRAMES)}: "
        f"snapshot {snapshot}, "
        f"{len(boxes)} nodes, "
        f"{particle_summary(particles)}"
    )

    octree_actor.mapper.dataset.shallow_copy(mesh)

    replace_particle_actor(particles)

    if state.slice_enabled:
        refresh_slice(
            boxes=boxes,
            particles=particles,
        )

    state.snapshot = snapshot
    state.num_nodes = len(boxes)
    state.particle_summary = particle_summary(particles)

    # Re-apply visibility because replacing the particle actor creates a new
    # VTK actor.
    apply_visibility(render=False)

    plotter.render()
    ctrl.view_update()


state.change("frame_index")(update_frame)


# ============================================================================
# Slice callbacks
# ============================================================================

def apply_visibility(render=True, **kwargs):
    show_octree = bool(state.octree_visible)
    slice_on = bool(state.slice_enabled)

    octree_actor.SetVisibility(show_octree and not slice_on)
    slice_actor.SetVisibility(show_octree and slice_on)

    if slice_on and state.slice_particles:
        particle_actor.SetVisibility(False)
        particle_slice_actor.SetVisibility(True)
    else:
        particle_actor.SetVisibility(True)
        particle_slice_actor.SetVisibility(False)

    if render:
        plotter.render()
        ctrl.view_update()


def update_slice(**kwargs):
    if state.slice_enabled:
        refresh_slice()

    apply_visibility()


def update_slice_geometry(**kwargs):
    if not state.slice_enabled:
        return

    refresh_slice()
    plotter.render()
    ctrl.view_update()


def update_slice_axis(**kwargs):
    axis = str(state.slice_axis)
    axis_min, axis_max = AXIS_BOUNDS[axis]

    state.slice_pos_min = axis_min
    state.slice_pos_max = axis_max
    state.slice_pos = 0.5 * (axis_min + axis_max)


state.change("slice_enabled")(update_slice)
state.change("slice_axis")(update_slice_axis)
state.change("slice_axis")(update_slice_geometry)
state.change("slice_pos")(update_slice_geometry)
state.change("slice_thickness")(update_slice_geometry)
state.change("slice_particles")(apply_visibility)
state.change("octree_visible")(apply_visibility)


def update_run(run, **kwargs):
    if run == ACTIVE_RUN:
        return
    snapshot = int(state.snapshot)
    select_tree_run(run)
    state.tree_label = TREE_LABEL
    state.num_frames = len(FRAMES)
    state.max_frame_index = len(FRAMES) - 1
    state.metric_charts, state.metric_note, limits = benchmark_charts()
    state.metric_xmin, state.metric_xmax = limits
    domain_actor.mapper.dataset.shallow_copy(pv.Box(bounds=BOX_BOUNDS))
    state.slice_pos_min, state.slice_pos_max = AXIS_BOUNDS[str(state.slice_axis)]
    state.slice_pos = float(np.clip(state.slice_pos, state.slice_pos_min, state.slice_pos_max))
    state.slice_thickness_max = 0.5 * DOMAIN_SIZE
    state.slice_thickness = min(state.slice_thickness, state.slice_thickness_max)
    # Prefer the same snapshot; tolerate runs exported with different strides.
    frame_index = min(range(len(FRAMES)), key=lambda i: abs(FRAMES[i]["snapshot"] - snapshot))
    if frame_index == int(state.frame_index):
        update_frame(frame_index)
    else:
        state.frame_index = frame_index
    plotter.reset_camera(bounds=SCENE_BOUNDS, render=False)
    ctrl.view_update()


state.change("run")(update_run)


# ============================================================================
# UI
# ============================================================================

timeline_css = """
    .timeline-content { display:flex; height:100%; min-height:0; overflow:hidden; }
    .timeline-scene { flex:1; min-width:0; position:relative; }
    .timeline-metrics { width:420px; max-width:40%; overflow-y:auto; background:#fafafa; }
    @media (max-width:960px) {
        .timeline-content { flex-direction:column; overflow:auto; }
        .timeline-scene { flex:1 0 45vh; min-height:320px; }
        .timeline-metrics { width:100%; max-width:100%; overflow:visible;
            display:grid; grid-template-columns:repeat(auto-fit,minmax(300px,1fr)); }
    }
"""
server.enable_module({"styles": [
    "data:text/css;base64," + base64.b64encode(timeline_css.encode()).decode("ascii")
]})

with SinglePageLayout(server) as layout:

    layout.title.set_text("Adaptive {{ tree_label }} Timeline")

    with layout.toolbar:
        if len(RUNS) > 1:
            vuetify3.VSelect(
                v_model=("run", ACTIVE_RUN), items=("run_options", RUNS),
                label="Benchmark run", density="compact", hide_details=True,
                style="max-width:260px", classes="mr-4",
            )
        vuetify3.VSwitch(
            v_model=("show_metrics", state.show_metrics), label="Benchmark plots",
            density="compact", hide_details=True,
        )

    with layout.content:
        with html.Div(classes="timeline-content"):
            with html.Div(classes="timeline-scene"):
                view = plotter_ui(plotter)
                ctrl.view_update = view.update
            with html.Div(v_show="show_metrics", classes="timeline-metrics pa-2"):
                with html.Div(classes="text-caption mb-2", style="grid-column:1/-1"):
                    html.Span("Snapshot {{ snapshot }}", style="color:#d32f2f;font-weight:600")
                    html.Span(" · red line on every plot")
                    html.Div("{{ metric_note }}", v_if="metric_note", classes="mt-1")
                with html.Div(v_for="chart in metric_charts", key="chart.title", classes="mb-2"):
                    html.Div("{{ chart.title }}", classes="text-subtitle-2 px-2")
                    html.Div("{{ chart.note }}", v_if="chart.note", classes="text-caption px-2")
                    with html.Div(style="position:relative"):
                        html.Img(src=("chart.image",), alt=("chart.title",),
                                 style="display:block;width:100%;height:auto")
                        html.Div(style=(
                            "{ position: 'absolute', top: '5%', bottom: '25%', "
                            "borderLeft: '2px solid #d32f2f', pointerEvents: 'none', "
                            "left: (16 + 82 * (snapshot - metric_xmin) / "
                            "(metric_xmax - metric_xmin)) + '%' }",
                        ))

    with layout.footer:

        with vuetify3.VContainer(
            fluid=True,
            classes="pa-2",
        ):

            with vuetify3.VRow(
                align="center",
                dense=True,
            ):

                with vuetify3.VCol(cols=2):
                    vuetify3.VLabel("Snapshot {{ snapshot }}")

                with vuetify3.VCol(cols=2):
                    vuetify3.VLabel("Nodes {{ num_nodes }}")

                with vuetify3.VCol(cols=6):
                    vuetify3.VLabel("{{ particle_summary }}")

                with vuetify3.VCol(cols=2):
                    vuetify3.VLabel(
                        "Frame {{ frame_index + 1 }} / {{ num_frames }}"
                    )

            with vuetify3.VRow(
                align="center",
                dense=True,
            ):

                with vuetify3.VCol(cols=2):
                    vuetify3.VSwitch(
                        v_model=("slice_enabled", False),
                        label="Slice",
                        hide_details=True,
                    )

                with vuetify3.VCol(cols=2):
                    vuetify3.VSwitch(
                        v_model=("octree_visible", True),
                        label=("'Show ' + tree_label",),
                        hide_details=True,
                    )

                with vuetify3.VCol(cols=2):
                    vuetify3.VSelect(
                        v_model=("slice_axis", "x"),
                        items=["x", "y", "z"],
                        label="Axis",
                        hide_details=True,
                        density="compact",
                    )

                with vuetify3.VCol(cols=4):
                    vuetify3.VSlider(
                        v_model=("slice_pos", state.slice_pos),
                        min=("slice_pos_min", state.slice_pos_min),
                        max=("slice_pos_max", state.slice_pos_max),
                        step=_slice_pos_step,
                        label="Slice position",
                        hide_details=True,
                        thumb_label=True,
                    )

                with vuetify3.VCol(cols=2):
                    vuetify3.VSwitch(
                        v_model=("slice_particles", True),
                        label="Slice particles",
                        hide_details=True,
                    )

            with vuetify3.VRow(
                align="center",
                dense=True,
            ):

                with vuetify3.VCol(cols=2):
                    vuetify3.VLabel("Particle slab")

                with vuetify3.VCol(cols=10):
                    vuetify3.VSlider(
                        v_model=("slice_thickness", state.slice_thickness),
                        min=0.0,
                        max=(
                            "slice_thickness_max",
                            state.slice_thickness_max,
                        ),
                        step=_slice_thickness_step,
                        hide_details=True,
                        thumb_label=True,
                    )

            with vuetify3.VRow(
                align="center",
                dense=True,
            ):

                with vuetify3.VCol(cols=12):
                    vuetify3.VSlider(
                        v_model=("frame_index", 0),
                        min=0,
                        max=("max_frame_index", len(FRAMES) - 1),
                        step=1,
                        hide_details=True,
                        thumb_label=True,
                    )


# ============================================================================
# Main
# ============================================================================

def main():
    print()
    print(f"Open http://localhost:{PORT}")
    print()
    print("If running over SSH, forward the port:")
    print()
    print(f"    ssh -L {PORT}:localhost:{PORT} user@remote-host")
    print()
    print("Then open locally:")
    print()
    print(f"    http://localhost:{PORT}")
    print()

    if CREATE_VIDEO:
        create_timeline_video()

    server.start(
        port=PORT,
        host="localhost",
        open_browser=False,
    )


if __name__ == "__main__":
    main()
