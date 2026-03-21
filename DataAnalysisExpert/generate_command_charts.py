#!/usr/bin/env python3
"""Generate charts from DataAnalysisExpert command summary CSV.

This script writes lightweight SVG charts so it can run without external
plotting dependencies.
"""

from __future__ import annotations

import argparse
import csv
from collections import Counter
from pathlib import Path


DEFAULT_SUMMARY = Path("DataAnalysisExpert/command_run_summary.csv")
DEFAULT_OUT_DIR = Path("DataAnalysisExpert")


def mermaid_block(diagram_lines: list[str]) -> list[str]:
    return ["```mermaid", *diagram_lines, "```"]


def read_summary(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        raise FileNotFoundError(f"Summary CSV not found: {path}")
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        return [row for row in reader]


def parse_int(row: dict[str, str], key: str, default: int = 0) -> int:
    try:
        return int((row.get(key) or "").strip())
    except ValueError:
        return default


def row_label(row: dict[str, str]) -> str:
    return (row.get("target") or row.get("name") or "").strip()


def svg_header(width: int, height: int) -> list[str]:
    return [
        f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>",
        "<style>text{font-family:Arial, sans-serif; fill:#0f172a;} .title{font-size:16px; font-weight:bold;} .label{font-size:12px;} .axis{stroke:#94a3b8; stroke-width:1;} .grid{stroke:#e2e8f0; stroke-width:1;}</style>",
    ]


def svg_footer() -> list[str]:
    return ["</svg>"]


def status_color(status: str) -> str:
    return {
        "pass": "#2f855a",
        "fail": "#c53030",
        "timeout": "#dd6b20",
        "unknown": "#718096",
    }.get(status, "#718096")


def render_status_counts(rows: list[dict[str, str]], out_path: Path) -> None:
    counts = Counter((row.get("status") or "unknown").strip() or "unknown" for row in rows)
    if not counts:
        return

    statuses = sorted(counts.keys())
    values = [counts[s] for s in statuses]
    max_val = max(values) if values else 1

    width = 720
    height = 420
    margin = 60
    plot_width = width - 2 * margin
    plot_height = height - 2 * margin
    slot = plot_width / max(1, len(statuses))
    bar_width = slot * 0.6
    scale = plot_height / max_val if max_val else 1

    lines = svg_header(width, height)
    lines.append(f"<text class='title' x='{margin}' y='32'>Command Outcome Counts</text>")
    lines.append(f"<line class='axis' x1='{margin}' y1='{height - margin}' x2='{width - margin}' y2='{height - margin}'/>")
    lines.append(f"<line class='axis' x1='{margin}' y1='{margin}' x2='{margin}' y2='{height - margin}'/>")

    for i, (status, value) in enumerate(zip(statuses, values)):
        x = margin + i * slot + (slot - bar_width) / 2
        bar_height = value * scale
        y = height - margin - bar_height
        lines.append(
            f"<rect x='{x:.1f}' y='{y:.1f}' width='{bar_width:.1f}' height='{bar_height:.1f}' fill='{status_color(status)}'/>"
        )
        lines.append(
            f"<text class='label' x='{x + bar_width / 2:.1f}' y='{y - 6:.1f}' text-anchor='middle'>{value}</text>"
        )
        lines.append(
            f"<text class='label' x='{x + bar_width / 2:.1f}' y='{height - margin + 18:.1f}' text-anchor='middle'>{status}</text>"
        )

    lines.extend(svg_footer())
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def render_duration_chart(rows: list[dict[str, str]], out_path: Path, title: str) -> None:
    if not rows:
        return

    labels = [row_label(row) for row in rows]
    durations = [parse_int(row, "duration_sec", 0) for row in rows]
    statuses = [row.get("status", "unknown") for row in rows]
    max_val = max(durations) if durations else 1

    row_height = 24
    margin = 60
    width = 960
    height = max(320, margin * 2 + row_height * len(labels) + 20)
    plot_width = width - margin * 2
    scale = plot_width / max_val if max_val else 1

    lines = svg_header(width, height)
    lines.append(f"<text class='title' x='{margin}' y='32'>{title}</text>")
    lines.append(f"<line class='axis' x1='{margin}' y1='{height - margin}' x2='{width - margin}' y2='{height - margin}'/>")
    lines.append(f"<line class='axis' x1='{margin}' y1='{margin}' x2='{margin}' y2='{height - margin}'/>")

    for i, (label, duration, status) in enumerate(zip(labels, durations, statuses)):
        y = margin + i * row_height
        bar_length = duration * scale
        lines.append(
            f"<rect x='{margin}' y='{y:.1f}' width='{bar_length:.1f}' height='16' fill='{status_color(status)}'/>"
        )
        lines.append(
            f"<text class='label' x='{margin - 8}' y='{y + 12:.1f}' text-anchor='end'>{label}</text>"
        )
        lines.append(
            f"<text class='label' x='{margin + bar_length + 6:.1f}' y='{y + 12:.1f}'>{duration}</text>"
        )

    lines.extend(svg_footer())
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_chart_index(rows: list[dict[str, str]], out_path: Path, image_names: list[str], summary_path: Path, label: str) -> None:
    counts = Counter((row.get("status") or "unknown").strip() or "unknown" for row in rows)
    total = len(rows)
    lines = [
        "# Command Chart Index",
        "",
        "This index ties the summary CSV to the generated SVG charts.",
        "",
        f"- Total commands: {total}",
        f"- Pass: {counts.get('pass', 0)}",
        f"- Fail: {counts.get('fail', 0)}",
        f"- Timeout: {counts.get('timeout', 0)}",
        "",
        f"## Dataset",
        f"- Label: {label}",
        "",
        "## Chart Pipeline",
        "",
        *mermaid_block(
            [
                "flowchart TD",
                f"    A[\"{summary_path.as_posix()}\\ncommand summary rows\"] --> B[\"generate_command_charts.py\\nCSV reader + SVG renderer\"]",
                f"    B --> C[\"{image_names[0]}\\nstatus distribution\"]",
                f"    B --> D[\"{image_names[1]}\\nduration by entry\"]",
                f"    B --> E[\"{out_path.name}\\nchart index\"]",
                "    C --> E",
                "    D --> E",
            ]
        ),
        "",
        "## Generated Graph Files",
    ]
    for name in image_names:
        lines.append(f"- {name}")

    lines += [
        "",
        "## Source",
        f"- {summary_path}",
    ]
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate charts from command run summary")
    parser.add_argument("--summary", type=Path, default=DEFAULT_SUMMARY)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    parser.add_argument("--prefix", default="command", help="Output filename prefix")
    args = parser.parse_args()

    rows = read_summary(args.summary)
    args.out_dir.mkdir(parents=True, exist_ok=True)

    status_svg = args.out_dir / f"{args.prefix}_status_counts.svg"
    duration_svg = args.out_dir / f"{args.prefix}_duration_by_target.svg"
    chart_index_name = "chart_index.md" if args.prefix == "command" else f"{args.prefix}_chart_index.md"
    chart_index = args.out_dir / chart_index_name

    render_status_counts(rows, status_svg)
    render_duration_chart(rows, duration_svg, f"{args.prefix.replace('_', ' ').title()} Duration by Entry")
    write_chart_index(rows, chart_index, [status_svg.name, duration_svg.name], args.summary, args.prefix)

    print(status_svg)
    print(duration_svg)
    print(chart_index)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
