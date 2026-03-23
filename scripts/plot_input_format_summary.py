#!/usr/bin/env python3
"""Plot GFA vs GFAZ performance from a benchmark summary markdown table."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import Dict, List

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

GFA_COLOR  = "#E76F51"   # coral (warm, vivid but not too harsh)
GFAZ_COLOR = "#7B3F61"   # plum (deep, rich, high contrast)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Plot avg_wall_sec and avg_rss_kb for gfa vs gfaz from an "
            "input-format benchmark summary markdown file."
        )
    )
    parser.add_argument(
        "--summary",
        required=True,
        help="Path to the *_summary.md file produced by benchmark_input_formats.py.",
    )
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory for generated plots. Defaults to the summary file directory.",
    )
    parser.add_argument(
        "--prefix",
        default=None,
        help="Output filename prefix. Defaults to the summary filename stem without _summary.",
    )
    parser.add_argument(
        "--format",
        choices=("png", "pdf", "svg"),
        default="png",
        help="Image format for generated plots.",
    )
    parser.add_argument(
        "--normalize",
        action="store_true",
        help="Normalize wall time and RSS to the gfa baseline (gfa = 1).",
    )
    return parser


def parse_summary_table(summary_path: Path) -> List[Dict[str, str]]:
    rows: List[Dict[str, str]] = []
    in_table = False
    headers: List[str] = []

    for raw_line in summary_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if not cells:
            continue
        if cells[0] == "command":
            headers = cells
            in_table = True
            continue
        if not in_table:
            continue
        if set("".join(cells)) <= {"-", ":"}:
            continue
        if len(cells) != len(headers):
            continue
        rows.append(dict(zip(headers, cells)))

    if not rows:
        raise SystemExit(f"error: no benchmark summary rows found in {summary_path}")
    return rows


def collect_comparison_rows(rows: List[Dict[str, str]]) -> List[Dict[str, float | str]]:
    by_command: Dict[str, Dict[str, Dict[str, str]]] = {}
    for row in rows:
        by_command.setdefault(row["command"], {})[row["input"]] = row

    comparison_rows: List[Dict[str, float | str]] = []
    for command in sorted(by_command):
        inputs = by_command[command]
        if "gfa" not in inputs or "gfaz" not in inputs:
            continue
        gfa_row = inputs["gfa"]
        gfaz_row = inputs["gfaz"]
        if gfa_row["failures"] != "0" or gfaz_row["failures"] != "0":
            continue

        gfa_wall = float(gfa_row["avg_wall_sec"])
        gfaz_wall = float(gfaz_row["avg_wall_sec"])
        gfa_rss = float(gfa_row["avg_rss_kb"])
        gfaz_rss = float(gfaz_row["avg_rss_kb"])

        comparison_rows.append(
            {
                "command": command,
                "gfa_avg_wall_sec": gfa_wall,
                "gfaz_avg_wall_sec": gfaz_wall,
                "gfa_avg_rss_kb": gfa_rss,
                "gfaz_avg_rss_kb": gfaz_rss,
                "gfa_wall_normalized": 1.0,
                "gfaz_wall_normalized": gfa_wall / gfaz_wall if gfaz_wall else 0.0,
                "gfa_rss_normalized": 1.0,
                "gfaz_rss_normalized": gfaz_rss / gfa_rss if gfa_rss else 0.0,
                "wall_speedup": gfa_wall / gfaz_wall if gfaz_wall else 0.0,
                "rss_ratio": gfaz_rss / gfa_rss if gfa_rss else 0.0,
            }
        )

    if not comparison_rows:
        raise SystemExit("error: no comparable gfa/gfaz rows with zero failures were found")
    return comparison_rows


def write_comparison_tsv(out_path: Path, rows: List[Dict[str, float | str]]) -> None:
    headers = [
        "command",
        "gfa_avg_wall_sec",
        "gfaz_avg_wall_sec",
        "gfa_avg_rss_kb",
        "gfaz_avg_rss_kb",
        "gfa_wall_normalized",
        "gfaz_wall_normalized",
        "gfa_rss_normalized",
        "gfaz_rss_normalized",
        "wall_speedup",
        "rss_ratio",
    ]
    with out_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers, delimiter="\t")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def make_grouped_bar_plot(
    rows: List[Dict[str, float | str]],
    metric_key_gfa: str,
    metric_key_gfaz: str,
    ylabel: str,
    title: str,
    out_path: Path,
) -> None:
    commands = [str(row["command"]) for row in rows]
    gfa_values = [float(row[metric_key_gfa]) for row in rows]
    gfaz_values = [float(row[metric_key_gfaz]) for row in rows]
    figure_width = max(12.0, 0.45 * len(commands))
    fig, ax = plt.subplots(figsize=(figure_width, 6.5))

    positions = list(range(len(commands)))
    bar_width = 0.38

    ax.bar(
        [pos - bar_width / 2 for pos in positions],
        gfa_values,
        width=bar_width,
        label="gfa",
        color=GFA_COLOR,
    )
    ax.bar(
        [pos + bar_width / 2 for pos in positions],
        gfaz_values,
        width=bar_width,
        label="gfaz",
        color=GFAZ_COLOR,
    )

    ax.set_facecolor("#fafafa")
    ax.set_xticks(positions)
    ax.set_xticklabels(commands, rotation=45, ha="right")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(frameon=False)
    ax.grid(axis="y", color="#d9d9d9", alpha=0.6, linewidth=0.8)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)

    fig.tight_layout()
    fig.savefig(out_path, dpi=200, bbox_inches="tight")
    plt.close(fig)


def main() -> int:
    args = build_parser().parse_args()

    summary_path = Path(args.summary).resolve()
    if not summary_path.is_file():
        raise SystemExit(f"error: summary file not found: {summary_path}")

    out_dir = Path(args.out_dir).resolve() if args.out_dir else summary_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    default_prefix = summary_path.stem.removesuffix("_summary")
    prefix = args.prefix or default_prefix

    rows = parse_summary_table(summary_path)
    comparison_rows = collect_comparison_rows(rows)

    comparison_tsv = out_dir / f"{prefix}_gfa_vs_gfaz.tsv"
    if args.normalize:
        wall_plot = out_dir / f"{prefix}_gfa_vs_gfaz_normalized_wall.{args.format}"
        rss_plot = out_dir / f"{prefix}_gfa_vs_gfaz_normalized_rss.{args.format}"
    else:
        wall_plot = out_dir / f"{prefix}_gfa_vs_gfaz_avg_wall_sec.{args.format}"
        rss_plot = out_dir / f"{prefix}_gfa_vs_gfaz_avg_rss_kb.{args.format}"

    write_comparison_tsv(comparison_tsv, comparison_rows)
    if args.normalize:
        make_grouped_bar_plot(
            comparison_rows,
            "gfa_wall_normalized",
            "gfaz_wall_normalized",
            "Normalized wall time speedup (gfa = 1)",
            "ODGI Input Benchmark: GFA Baseline vs GFAZ Speedup",
            wall_plot,
        )
        make_grouped_bar_plot(
            comparison_rows,
            "gfa_rss_normalized",
            "gfaz_rss_normalized",
            "Normalized peak RSS ratio (gfa = 1)",
            "ODGI Input Benchmark: GFA Baseline vs GFAZ Peak RSS",
            rss_plot,
        )
    else:
        make_grouped_bar_plot(
            comparison_rows,
            "gfa_avg_wall_sec",
            "gfaz_avg_wall_sec",
            "Average wall time (sec)",
            "ODGI Input Benchmark: GFA vs GFAZ Average Wall Time",
            wall_plot,
        )
        make_grouped_bar_plot(
            comparison_rows,
            "gfa_avg_rss_kb",
            "gfaz_avg_rss_kb",
            "Average peak RSS (KB)",
            "ODGI Input Benchmark: GFA vs GFAZ Average Peak RSS",
            rss_plot,
        )

    print(f"Wrote: {comparison_tsv}")
    print(f"Wrote: {wall_plot}")
    print(f"Wrote: {rss_plot}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
