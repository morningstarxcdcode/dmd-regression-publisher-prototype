#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import os
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List

try:
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", Path.cwd() / ".cache"))
    cache_root.mkdir(parents=True, exist_ok=True)
    if "MPLCONFIGDIR" not in os.environ:
        mpl_cache = cache_root / "matplotlib"
        mpl_cache.mkdir(parents=True, exist_ok=True)
        os.environ["MPLCONFIGDIR"] = str(mpl_cache)
        os.environ["XDG_CACHE_HOME"] = str(cache_root)

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    HAS_MATPLOTLIB = True
except Exception:
    HAS_MATPLOTLIB = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate DMD -ftime-trace events by compiler phase.")
    parser.add_argument("--input", required=True, help="Input trace JSON")
    parser.add_argument("--out-csv", default="artifacts/trace_phase_summary.csv", help="Output phase summary CSV")
    parser.add_argument("--events-csv", default="artifacts/trace_event_summary.csv", help="Output event summary CSV")
    parser.add_argument("--plot", default="artifacts/trace_phase_bar.png", help="Output bar chart PNG")
    parser.add_argument("--top-events", type=int, default=25, help="Number of top raw event names to export")
    parser.add_argument("--no-plot", action="store_true", help="Skip bar chart generation")
    return parser.parse_args()


def load_events(path: Path) -> List[Dict[str, object]]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)

    if isinstance(payload, dict) and isinstance(payload.get("traceEvents"), list):
        return payload["traceEvents"]
    if isinstance(payload, list):
        return payload
    raise ValueError("Trace format not recognized")


def normalize_phase(name: str) -> str:
    n = name.lower()

    if "semantic" in n or n.startswith("sem"):
        return "semantic_analysis"
    if "template" in n or "instantiat" in n:
        return "template_instantiation"
    if "ctfe" in n or "interpret" in n:
        return "ctfe"
    if "parse" in n or "syntax" in n:
        return "parsing"
    if "lex" in n or "token" in n:
        return "lexing"
    if "codegen" in n or "backend" in n or "emit" in n or "object" in n:
        return "codegen_backend"
    if "optimi" in n:
        return "optimization"
    if "import" in n:
        return "module_loading"
    return "other"


def to_float(value: object) -> float:
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value))
    except Exception:
        return 0.0


def write_csv(path: Path, rows: Iterable[Dict[str, object]], headers: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=headers)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def build_plot(path: Path, rows: List[Dict[str, object]]) -> None:
    if not HAS_MATPLOTLIB or not rows:
        return

    phases = [str(row["phase"]) for row in rows]
    totals_ms = [float(row["total_ms"]) for row in rows]

    fig, ax = plt.subplots(figsize=(10, 5.5))
    ax.barh(phases, totals_ms, color="#3a86ff", alpha=0.85)
    ax.invert_yaxis()
    ax.set_title("DMD -ftime-trace: Phase Time Distribution")
    ax.set_xlabel("Time (ms)")
    ax.grid(axis="x", alpha=0.25)
    fig.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=160)
    plt.close(fig)


def main() -> int:
    args = parse_args()

    input_path = Path(args.input)
    out_csv = Path(args.out_csv)
    events_csv = Path(args.events_csv)
    plot_path = Path(args.plot)

    events = load_events(input_path)

    phase_totals_us: Dict[str, float] = defaultdict(float)
    phase_counts: Dict[str, int] = defaultdict(int)
    event_totals_us: Dict[str, float] = defaultdict(float)

    for event in events:
        if not isinstance(event, dict):
            continue

        phase_type = str(event.get("ph", ""))
        if phase_type not in {"X", ""}:
            continue

        duration_us = to_float(event.get("dur", 0.0))
        if duration_us <= 0:
            continue

        name = str(event.get("name", "<unnamed>"))
        phase = normalize_phase(name)

        phase_totals_us[phase] += duration_us
        phase_counts[phase] += 1
        event_totals_us[name] += duration_us

    total_us = sum(phase_totals_us.values()) or 1.0

    phase_rows = []
    for phase, total_phase_us in sorted(phase_totals_us.items(), key=lambda kv: kv[1], reverse=True):
        phase_rows.append(
            {
                "phase": phase,
                "total_us": f"{total_phase_us:.3f}",
                "total_ms": f"{total_phase_us / 1000.0:.3f}",
                "percent": f"{(total_phase_us / total_us) * 100.0:.2f}",
                "event_count": phase_counts[phase],
            }
        )

    event_rows = []
    for name, total_event_us in sorted(event_totals_us.items(), key=lambda kv: kv[1], reverse=True)[: args.top_events]:
        event_rows.append(
            {
                "event": name,
                "total_us": f"{total_event_us:.3f}",
                "total_ms": f"{total_event_us / 1000.0:.3f}",
                "percent": f"{(total_event_us / total_us) * 100.0:.2f}",
            }
        )

    write_csv(out_csv, phase_rows, ["phase", "total_us", "total_ms", "percent", "event_count"])
    write_csv(events_csv, event_rows, ["event", "total_us", "total_ms", "percent"])
    if not args.no_plot:
        build_plot(plot_path, phase_rows)

    print(f"Wrote phase summary: {out_csv}")
    print(f"Wrote event summary: {events_csv}")
    if args.no_plot:
        print("Skipped phase chart (--no-plot)")
    elif HAS_MATPLOTLIB:
        print(f"Wrote phase chart: {plot_path}")
    else:
        print("matplotlib not available; skipped trace phase chart")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
