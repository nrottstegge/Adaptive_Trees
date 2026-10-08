#!/usr/bin/env python3

import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt


def plot_metric(ax, snapshot, series, is_single, title=None, ylabel=None):
    """Plot one or more named value series.

    For a time series this draws lines over `snapshot`.
    For a single-snapshot benchmark a labeled bar per series is used.
    """

    if is_single:
        labels = list(series.keys())
        values = [values.iloc[0] for values in series.values()]

        x_positions = list(range(len(labels)))

        bars = ax.bar(
            x_positions,
            values,
        )

        ax.set_xticks(x_positions)
        ax.set_xticklabels(labels)

        for bar, value in zip(bars, values):
            ax.annotate(
                f"{value:.2f}",
                xy=(
                    bar.get_x() + bar.get_width() / 2,
                    bar.get_height(),
                ),
                xytext=(0, 3),
                textcoords="offset points",
                ha="center",
                va="bottom",
                fontsize=8,
            )
    else:
        for label, values in series.items():
            ax.plot(
                snapshot,
                values,
                label=label,
            )

        if len(series) > 1:
            ax.legend()

        ax.set_xlabel("Snapshot")

    if title:
        ax.set_title(title)

    if ylabel:
        ax.set_ylabel(ylabel)

    ax.grid(True, alpha=0.3)


def mode_label(tree_type, criterion):
    tree = "KDTree3D" if tree_type == "binary" else "Octree"
    split = {"leafcount": "leaf count", "nfcount": "NF count"}[criterion]
    return f"{tree} / {split}"


def plot_comparison(df, output):
    comparison_modes = [
        ("octree", "leafcount"),
        ("octree", "nfcount"),
        ("binary", "leafcount"),
    ]

    groups = []

    for key in comparison_modes:
        tree_type, criterion = key

        frame = df[
            (df["tree_type"] == tree_type)
            & (df["split_criterion"] == criterion)
        ]

        if not frame.empty:
            groups.append((key, frame))
    is_single = all(len(frame) == 1 for _, frame in groups)
    fig, axes = plt.subplots(2, 3, figsize=(18, 9))
    colors = {
        ("octree", "leafcount"): "tab:purple",
        ("octree", "nfcount"): "tab:brown",
        ("binary", "leafcount"): "tab:red",
    }

    def metric(ax, columns, title, ylabel, updates_only=False):
        plotted = False
        for mode_index, ((tree_type, criterion), frame) in enumerate(groups):
            label = mode_label(tree_type, criterion)
            values = frame.iloc[1:] if updates_only and len(frame) > 1 else frame
            for column_index, (column, phase) in enumerate(columns):
                if column not in values or not values[column].notna().any():
                    continue
                plotted = True
                if is_single:
                    width = 0.72 / len(columns)
                    position = mode_index + (column_index - (len(columns) - 1) / 2) * width
                    bars = ax.bar(
                        position, values[column].iloc[0], width=width,
                        color=colors[tree_type, criterion],
                        hatch="//" if column_index else None,
                        label=phase if mode_index == 0 else None,
                    )
                    ax.bar_label(bars, fmt="%.3g", padding=3, fontsize=7)
                else:
                    ax.plot(
                        values["snapshot"], values[column],
                        color=colors[tree_type, criterion],
                        linestyle="--" if column_index else "-",
                        marker="o" if len(values) < 20 else None,
                        markersize=3, linewidth=1.3,
                        label=f"{label}, {phase}" if phase else label,
                    )
        ax.set_title(title)
        ax.set_ylabel(ylabel)
        ax.grid(True, alpha=0.3)
        if is_single:
            ax.set_xticks(range(len(groups)))
            ax.set_xticklabels(
                [mode_label(*key).replace(" / ", "\n") for key, _ in groups],
                fontsize=8,
            )
            ax.margins(y=0.15)
        else:
            ax.set_xlabel("Snapshot")
        if plotted and (not is_single or len(columns) > 1):
            ax.legend(fontsize=7, loc="best")
        elif not plotted:
            ax.text(0.5, 0.5, "Unavailable in this CSV", ha="center", transform=ax.transAxes)

    metric(
        axes[0, 0],
        [("num_nodes", "")],
        "Tree Size",
        "Total Nodes",
    )
    gpu_suffix = " (GPU)" if "graph_tree_ms" in df else ""
    timing_prefix = "Mean Update" if is_single else "Incremental"
    metric(
        axes[0, 1],
        [("graph_compute_total_ms", "")],
        f"{timing_prefix} Total Runtime",
        "Runtime [ms]",
        updates_only=True,
    )
    metric(axes[0, 2], [("max_depth", "")], "Maximum Tree Depth", "Subdivisions from root")
    axes[0, 2].yaxis.get_major_locator().set_params(integer=True)
    metric(axes[1, 0], [("empty_leaf_percent", "")], "Empty Leaves", "Empty leaves [%]")
    metric(axes[1, 1], [("avg_particles_per_leaf", "")],
           "Average Particles per Leaf", "Particles / leaf")

    # Every mode receives the same particle snapshots, so show these counts once.
    shared_frame = groups[0][1]
    particles = {
        label: shared_frame[column]
        for column, label in (
            ("num_active_particles", "Active"),
            ("num_escaped_particles", "Escaped"),
            ("num_particle_slots", "Slots"),
        )
        if column in shared_frame and shared_frame[column].notna().any()
    }
    if particles:
        plot_metric(axes[1, 2], shared_frame["snapshot"], particles, is_single,
                    title="Particle Counts", ylabel="Particles")
    else:
        axes[1, 2].set_title("Particle Counts")
        axes[1, 2].text(0.5, 0.5, "Unavailable in this CSV", ha="center",
                        transform=axes[1, 2].transAxes)
        axes[1, 2].set_axis_off()

    initial_lines = []
    if not is_single:
        for key, frame in groups:
            if len(frame) > 1:
                first = frame.iloc[0]
                initial_lines.append(
                    f"{mode_label(*key)}: {first['tree_ms']:.2f} + "
                    f"{first.get('view_ms', 0):.2f} = {first['compute_total_ms']:.2f} ms"
                )
    maintenance = [
        ("graph_maintenance_ms", ""),
    ]
    has_maintenance = any(column in df and df[column].fillna(0).gt(0).any()
                          for column, _ in maintenance)

    fig.suptitle(
        "Adaptive Tree Mode Comparison",
        fontsize=16,
    )

    fig.tight_layout(
        rect=[0, 0, 1, 0.97]
    )

    fig.savefig(
        output,
        dpi=300,
        bbox_inches="tight",
    )

    print(f"Saved plot to: {output}")


def plot_single(df, output, label_criterion):
    tree_type = df["tree_type"].iloc[0]
    criterion = df["split_criterion"].iloc[0]
    tree_label = (mode_label(tree_type, criterion) if label_criterion
                  else "KDTree3D" if tree_type == "binary" else "Octree")
    snapshot = df["snapshot"]

    # A single row means a one-off benchmark rather than a snapshot series.
    is_single = len(df) == 1

    particle_series = {
        label: df[column]
        for column, label in (
            ("num_active_particles", "Active"),
            ("num_escaped_particles", "Escaped"),
            ("num_particle_slots", "Slots"),
        )
        if column in df and df[column].notna().any()
    }

    # -------------------------------------------------------------------------
    # Five tree metrics plus particle populations when available.
    # -------------------------------------------------------------------------

    fig = plt.figure(figsize=(16, 9))
    grid = fig.add_gridspec(2, 3)
    axes = {}
    for row, column in ((0, 0), (0, 1), (0, 2), (1, 0), (1, 1)):
        axes[row, column] = fig.add_subplot(
            grid[row, column],
            sharex=axes.get((0, 0)) if not is_single else None,
        )

    if particle_series:
        # Keep Active/Slots and Escaped visible on separate y ranges.
        particle_grid = grid[1, 2].subgridspec(2, 1, height_ratios=(2, 1), hspace=0.08)
        particle_ax_hi = fig.add_subplot(
            particle_grid[0], sharex=axes[0, 0] if not is_single else None,
        )
        particle_ax_lo = fig.add_subplot(particle_grid[1], sharex=particle_ax_hi)
        particle_ax_hi.tick_params(labelbottom=False)

    # =========================================================================
    # 1. Tree Size
    # =========================================================================

    plot_metric(
        axes[0, 0],
        snapshot,
        {
            "Nodes": df["num_nodes"],
            "Leaves": df["num_leaves"],
        },
        is_single,
        title=f"{tree_label} Size",
        ylabel="Count",
    )

    # =========================================================================
    # 2. Graph Runtime
    # =========================================================================

    ax = axes[0, 1]

    # Prefer graph timings everywhere.
    update_ms = df["graph_tree_ms"]
    view_ms = df["graph_view_ms"]

    # Wall-clock graph total if available. Otherwise fall back to the sum
    # of the two measured GPU phases.
    if "graph_compute_total_ms" in df:
        total_ms = df["graph_compute_total_ms"]
    else:
        total_ms = update_ms + view_ms

    if is_single:
        update = update_ms.iloc[0]
        view = view_ms.iloc[0]
        total = total_ms.iloc[0]

        ax.bar(
            ["Runtime"],
            [update],
            label="Tree update",
            color="C0",
        )

        ax.bar(
            ["Runtime"],
            [view],
            bottom=[update],
            label="View construction",
            color="C1",
        )

        # Total may include overhead not represented by the stacked GPU phases.
        ax.annotate(
            f"Total: {total:.3g} ms",
            xy=(0, update + view),
            xytext=(0, 5),
            textcoords="offset points",
            ha="center",
            va="bottom",
            fontsize=8,
        )

    else:
        # Snapshot 0 is the initial build, so runtime evolution starts at
        # snapshot 1.
        runtime = df.iloc[1:]

        x = runtime["snapshot"]
        update = runtime["graph_tree_ms"]
        view = runtime["graph_view_ms"]

        # Stacked filled areas:
        #
        # 0 ---------------- update
        # update ----------- update + view
        #
        phase_total = update + view

        ax.fill_between(
            x,
            0,
            update,
            color="C0",
            alpha=0.75,
            label="Tree update",
        )

        ax.fill_between(
            x,
            update,
            phase_total,
            color="C1",
            alpha=0.75,
            label="View construction",
        )

        # Actual graph wall time.
        if "graph_compute_total_ms" in runtime:
            total = runtime["graph_compute_total_ms"]

            ax.plot(
                x,
                total,
                color="black",
                linewidth=1.4,
                label="Total runtime",
            )

    ax.set_title(f"{tree_label} Graph Runtime")
    ax.set_xlabel("Snapshot" if not is_single else "")
    ax.set_ylabel("Runtime [ms]")
    ax.grid(True, alpha=0.3)
    ax.legend(loc="best", fontsize=8)

    # =========================================================================
    # 3. Maximum Achieved Tree Depth
    # =========================================================================

    ax = axes[0, 2]

    plot_metric(
        ax,
        snapshot,
        {
            "Max depth": df["max_depth"],
        },
        is_single,
        title=f"Maximum Achieved {tree_label} Depth",
        ylabel="Subdivisions from root",
    )

    ax.yaxis.get_major_locator().set_params(
        integer=True
    )

    # =========================================================================
    # 4. Percentage of Empty Leaves
    # =========================================================================

    plot_metric(
        axes[1, 0],
        snapshot,
        {
            "Empty leaves": df["empty_leaf_percent"],
        },
        is_single,
        title="Percentage of Empty Leaves",
        ylabel="Empty Leaves [%]",
    )

    # =========================================================================
    # 5. Average Particles per Leaf
    # =========================================================================

    plot_metric(
        axes[1, 1],
        snapshot,
        {
            "Avg particles/leaf": df["avg_particles_per_leaf"],
        },
        is_single,
        title="Average Particles per Leaf",
        ylabel="Particles / Leaf",
    )

    if particle_series:
        # Plot the particle data on both parts of the broken y-axis.
        for ax in (particle_ax_hi, particle_ax_lo):
            plot_metric(
                ax,
                snapshot,
                particle_series,
                is_single,
            )

            if not is_single:
                for line in ax.get_lines():
                    line.set_drawstyle("steps-post")

                    if len(df) <= 100:
                        line.set_marker("o")
                        line.set_markersize(3)

                    if line.get_label() == "Slots":
                        line.set_linestyle("--")
                        line.set_color("0.4")

            ax.yaxis.get_major_locator().set_params(integer=True)

        # ---------------------------------------------------------
        # Choose the two visible y ranges.
        # ---------------------------------------------------------

        active = df["num_active_particles"]
        slots = df["num_particle_slots"]
        escaped = df["num_escaped_particles"]

        # Bottom: show escaped particles relative to zero.
        escaped_max = max(1, escaped.max())

        particle_ax_lo.set_ylim(
            0,
            escaped_max * 1.15,
        )

        # Top: zoom in around Active and Slots.
        upper_min = min(active.min(), slots.min())
        upper_max = max(active.max(), slots.max())

        upper_span = upper_max - upper_min

        padding = max(
            upper_span * 0.10,
            1,
        )

        particle_ax_hi.set_ylim(
            upper_min - padding,
            upper_max + padding,
        )

        # ---------------------------------------------------------
        # Labels
        # ---------------------------------------------------------

        particle_ax_hi.set_title("Particle Counts")

        # plot_metric() adds "Snapshot" to both axes.
        # Remove it from the upper half of the broken axis.
        particle_ax_hi.set_xlabel("")

        particle_ax_lo.set_xlabel("Snapshot")
        particle_ax_lo.set_ylabel("Particles")

        if not is_single:
            particle_ax_hi.legend(loc="best")

        # Remove duplicate legend from lower plot.
        legend = particle_ax_lo.get_legend()
        if legend is not None:
            legend.remove()

        # ---------------------------------------------------------
        # Make the two axes visually look like one broken axis.
        # ---------------------------------------------------------

        particle_ax_hi.spines["bottom"].set_visible(False)
        particle_ax_lo.spines["top"].set_visible(False)

        particle_ax_hi.tick_params(bottom=False)
        particle_ax_lo.tick_params(top=False)

        # Draw diagonal // marks at the break.
        d = 0.006

        kwargs = dict(
            color="k",
            clip_on=False,
            linewidth=1,
        )

        particle_ax_hi.plot(
            (-d, +d),
            (-d, +d),
            transform=particle_ax_hi.transAxes,
            **kwargs,
        )

        particle_ax_hi.plot(
            (1 - d, 1 + d),
            (-d, +d),
            transform=particle_ax_hi.transAxes,
            **kwargs,
        )

        particle_ax_lo.plot(
            (-d, +d),
            (1 - d, 1 + d),
            transform=particle_ax_lo.transAxes,
            **kwargs,
        )

        particle_ax_lo.plot(
            (1 - d, 1 + d),
            (1 - d, 1 + d),
            transform=particle_ax_lo.transAxes,
            **kwargs,
        )

    # -------------------------------------------------------------------------
    # Global formatting
    # -------------------------------------------------------------------------

    fig.suptitle(
        (
            f"Adaptive {tree_label} Snapshot"
            if is_single
            else f"Adaptive {tree_label} Evolution"
        ),
        fontsize=16,
    )

    fig.tight_layout(
        rect=[0, 0.04, 1, 1]
    )

    # -------------------------------------------------------------------------
    # Save + show
    # -------------------------------------------------------------------------

    fig.savefig(
        output,
        dpi=300,
        bbox_inches="tight",
    )

    print(
        f"Saved plot to: {output}"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Plot adaptive tree snapshot benchmark results."
    )
    parser.add_argument("csv_file", help="Path to bench_snapshots.csv")
    parser.add_argument(
        "-o", "--output", default="bench_snapshots.png",
        help="Output image; mixed modes add mode and comparison suffixes (default: bench_snapshots.png)",
    )
    parser.add_argument("--no-show", action="store_true",
                        help="Save plots without opening interactive windows")
    args = parser.parse_args()
    df = pd.read_csv(args.csv_file)

    required = {"snapshot", "tree_ms", "num_nodes", "num_leaves", "max_depth",
                "empty_leaf_percent", "avg_particles_per_leaf"}
    missing = required - set(df.columns)
    if missing or df.empty:
        parser.error(f"Empty benchmark or missing columns: {sorted(missing)}")
    if "tree_type" not in df:
        df["tree_type"] = "binary"
    has_split_criterion = "split_criterion" in df
    if not has_split_criterion:
        df["split_criterion"] = "leafcount"
    if not df["tree_type"].isin(("binary", "octree")).all():
        parser.error("Expected tree_type: binary or octree")
    if not df["split_criterion"].isin(("leafcount", "nfcount")).all():
        parser.error("Expected split_criterion: leafcount or nfcount")

    groups = list(df.groupby(["tree_type", "split_criterion"], sort=False))
    if len(groups) == 1:
        plot_single(df, args.output, has_split_criterion)
    else:
        output = Path(args.output)
        suffix = output.suffix or ".png"
        for (tree_type, criterion), frame in groups:
            mode_output = output.with_name(f"{output.stem}_{tree_type}_{criterion}{suffix}")
            plot_single(frame, mode_output, True)
        comparison_output = output.with_name(f"{output.stem}_comparison{suffix}")
        plot_comparison(df, comparison_output)
    if args.no_show:
        plt.close("all")
    else:
        plt.show()


if __name__ == "__main__":
    main()
