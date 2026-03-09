#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import os
import random
import statistics
import textwrap
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

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


@dataclass
class VersionStats:
    version: str
    n_runs: int
    n_ok: int
    n_fail: int
    median_ms: Optional[float]
    mad_ms: Optional[float]
    mean_ms: Optional[float]
    ci_low_ms: Optional[float]
    ci_high_ms: Optional[float]
    artifact_size_bytes: Optional[float]


@dataclass
class TrackResult:
    track: str
    summary: List[VersionStats]
    regressions: List[Dict[str, object]]
    failure_counts: Dict[str, int]
    total_rows: int
    methodology: "Methodology"


@dataclass
class Methodology:
    benchmark_label: str
    benchmark_description: str
    compile_command: str
    measured_runs: int
    warmup_runs: int
    hostname: str
    cpu_brand: str
    os_value: str
    trace_compiler_label: str

    def short_plot_note(self) -> str:
        return (
            f"{self.benchmark_label} | {self.compile_command} | "
            f"median of {self.measured_runs} measured runs after {self.warmup_runs} warmups | "
            f"{self.cpu_brand} | {self.os_value}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze raw DMD benchmark measurements.")
    parser.add_argument("--input", default="", help="Single raw measurements CSV path")
    parser.add_argument("--input-dir", default="artifacts", help="Root directory containing per-track CSVs")
    parser.add_argument("--tracks", default="compatible20", help="Comma-separated tracks (e.g. latest20,compatible20)")
    parser.add_argument("--out-dir", default="artifacts", help="Output directory")
    parser.add_argument("--summary-csv", default="results_summary.csv", help="Summary CSV filename")
    parser.add_argument("--regression-csv", default="regression_table.csv", help="Regression CSV filename")
    parser.add_argument("--report", default="report.md", help="Markdown report filename")
    parser.add_argument("--trace-summary", default="artifacts/trace_phase_summary.csv", help="Optional trace phase CSV")
    parser.add_argument("--granularity-csv", default="artifacts/trace_granularity_sweep.csv", help="Optional trace granularity CSV")
    parser.add_argument("--bootstrap-samples", type=int, default=2000, help="Bootstrap resamples for CI")
    parser.add_argument("--regression-threshold", type=float, default=10.0, help="Percent threshold for regression flags")
    parser.add_argument("--benchmark-label", default="benchmark.d", help="Benchmark source label used in the plots/report")
    parser.add_argument(
        "--benchmark-description",
        default="synthetic template/CTFE-heavy D source",
        help="Short benchmark description for methodology text",
    )
    parser.add_argument(
        "--compile-command",
        default="dmd benchmark.d -O -c -of=<temp>.o",
        help="Compile command template used for the release sweep",
    )
    parser.add_argument(
        "--trace-compiler-label",
        default="nightly DMD build",
        help="Label for the compiler used for separate -ftime-trace collection",
    )
    return parser.parse_args()


def semver_key(version: str) -> Tuple[int, int, int, str]:
    parts = version.strip().split(".")
    ints: List[int] = []
    for part in parts[:3]:
        try:
            ints.append(int(part))
        except ValueError:
            ints.append(0)
    while len(ints) < 3:
        ints.append(0)
    return ints[0], ints[1], ints[2], version


def percentile(sorted_values: Sequence[float], fraction: float) -> float:
    if not sorted_values:
        raise ValueError("Cannot calculate percentile of empty list")
    if len(sorted_values) == 1:
        return float(sorted_values[0])

    fraction = min(max(fraction, 0.0), 1.0)
    pos = (len(sorted_values) - 1) * fraction
    low = math.floor(pos)
    high = math.ceil(pos)
    if low == high:
        return float(sorted_values[int(pos)])

    low_val = float(sorted_values[low])
    high_val = float(sorted_values[high])
    return low_val + (high_val - low_val) * (pos - low)


def bootstrap_ci(values: Sequence[float], samples: int = 2000, seed: int = 42) -> Tuple[float, float]:
    if not values:
        raise ValueError("Cannot bootstrap empty values")

    if len(values) == 1:
        value = float(values[0])
        return value, value

    rng = random.Random(seed)
    medians: List[float] = []
    n = len(values)

    for _ in range(samples):
        resample = [values[rng.randrange(n)] for _ in range(n)]
        medians.append(float(statistics.median(resample)))

    medians.sort()
    return percentile(medians, 0.025), percentile(medians, 0.975)


def median_absolute_deviation(values: Sequence[float]) -> float:
    center = float(statistics.median(values))
    deviations = [abs(v - center) for v in values]
    return float(statistics.median(deviations))


def safe_float(value: Optional[float]) -> str:
    if value is None:
        return ""
    return f"{value:.3f}"


def write_csv(path: Path, rows: Iterable[Dict[str, object]], headers: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(headers))
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def load_rows(path: Path) -> List[Dict[str, str]]:
    with path.open("r", newline="", encoding="utf-8") as handle:
        return [dict(row) for row in csv.DictReader(handle)]


def artifact_size_for_row(row: Dict[str, str]) -> float:
    for key in ("artifact_size_bytes", "binary_size_bytes"):
        try:
            value = float(row.get(key, "-1"))
        except ValueError:
            value = -1
        if value > 0:
            return value
    return -1


def summarize_versions(rows: Sequence[Dict[str, str]], bootstrap_samples: int) -> Tuple[List[VersionStats], Dict[str, int]]:
    grouped: Dict[str, Dict[str, List[float]]] = defaultdict(lambda: {"times": [], "sizes": []})
    counts: Dict[str, Dict[str, int]] = defaultdict(lambda: {"n_runs": 0, "n_ok": 0, "n_fail": 0})
    failure_counts: Counter[str] = Counter()

    for row in rows:
        version = row.get("version", "").strip()
        if not version:
            continue

        if row.get("is_warmup") != "0":
            continue

        counts[version]["n_runs"] += 1
        ok = row.get("ok") == "1"
        if ok:
            counts[version]["n_ok"] += 1
        else:
            counts[version]["n_fail"] += 1
            failure_kind = (row.get("failure_kind") or "unknown").strip() or "unknown"
            failure_counts[failure_kind] += 1

        try:
            time_ms = float(row.get("time_ms", "0"))
        except ValueError:
            time_ms = 0.0

        size_bytes = artifact_size_for_row(row)

        if ok and time_ms > 0:
            grouped[version]["times"].append(time_ms)
        if ok and size_bytes > 0:
            grouped[version]["sizes"].append(size_bytes)

    all_versions = sorted(set(grouped.keys()) | set(counts.keys()), key=semver_key)
    summary: List[VersionStats] = []

    for version in all_versions:
        times = grouped[version]["times"]
        sizes = grouped[version]["sizes"]

        if times:
            med = float(statistics.median(times))
            mad = median_absolute_deviation(times)
            mean_ms = float(statistics.mean(times))
            ci_low, ci_high = bootstrap_ci(times, samples=bootstrap_samples)
        else:
            med = None
            mad = None
            mean_ms = None
            ci_low = None
            ci_high = None

        artifact_size = float(statistics.median(sizes)) if sizes else None

        summary.append(
            VersionStats(
                version=version,
                n_runs=counts[version]["n_runs"],
                n_ok=counts[version]["n_ok"],
                n_fail=counts[version]["n_fail"],
                median_ms=med,
                mad_ms=mad,
                mean_ms=mean_ms,
                ci_low_ms=ci_low,
                ci_high_ms=ci_high,
                artifact_size_bytes=artifact_size,
            )
        )

    return summary, dict(failure_counts)


def regression_scan(summary: Sequence[VersionStats], threshold: float) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []

    for i in range(1, len(summary)):
        prev = summary[i - 1]
        curr = summary[i]

        if prev.median_ms is None or curr.median_ms is None or prev.median_ms == 0:
            pct_change = None
            ci_separated = False
            compile_regression = False
        else:
            pct_change = ((curr.median_ms - prev.median_ms) / prev.median_ms) * 100.0
            ci_separated = bool(
                curr.ci_low_ms is not None and prev.ci_high_ms is not None and curr.ci_low_ms > prev.ci_high_ms
            )
            compile_regression = pct_change >= threshold and ci_separated

        if (
            prev.artifact_size_bytes is None
            or curr.artifact_size_bytes is None
            or prev.artifact_size_bytes == 0
        ):
            size_pct_change = None
            size_regression = False
        else:
            size_pct_change = ((curr.artifact_size_bytes - prev.artifact_size_bytes) / prev.artifact_size_bytes) * 100.0
            size_regression = size_pct_change >= 5.0

        reason = []
        if compile_regression:
            reason.append("compile_time_jump")
        if size_regression:
            reason.append("artifact_size_jump")

        rows.append(
            {
                "from_version": prev.version,
                "to_version": curr.version,
                "pct_change_compile_ms": "" if pct_change is None else f"{pct_change:.3f}",
                "pct_change_artifact_size": "" if size_pct_change is None else f"{size_pct_change:.3f}",
                "ci_separated": int(ci_separated),
                "compile_regression": int(bool(compile_regression)),
                "size_regression": int(bool(size_regression)),
                "flag_reason": ";".join(reason),
            }
        )

    return rows


def most_common_field(rows: Sequence[Dict[str, str]], key: str, fallback: str) -> str:
    values = [row.get(key, "").strip() for row in rows if row.get(key, "").strip()]
    if not values:
        return fallback
    return Counter(values).most_common(1)[0][0]


def infer_methodology(rows: Sequence[Dict[str, str]], args: argparse.Namespace) -> Methodology:
    version_counts: Dict[str, Counter[str]] = defaultdict(Counter)
    for row in rows:
        version = row.get("version", "").strip()
        if not version:
            continue
        version_counts[version][row.get("is_warmup", "0")] += 1

    sample_counts = next(iter(version_counts.values()), Counter())
    measured_runs = int(sample_counts.get("0", 0))
    warmup_runs = int(sample_counts.get("1", 0))

    return Methodology(
        benchmark_label=args.benchmark_label,
        benchmark_description=args.benchmark_description,
        compile_command=args.compile_command,
        measured_runs=measured_runs,
        warmup_runs=warmup_runs,
        hostname=most_common_field(rows, "hostname", "unknown-host"),
        cpu_brand=most_common_field(rows, "cpu_brand", "unknown-cpu"),
        os_value=most_common_field(rows, "os", "unknown-os"),
        trace_compiler_label=args.trace_compiler_label,
    )


def plot_compile(
    summary: Sequence[VersionStats],
    regression_rows: Sequence[Dict[str, object]],
    out_path: Path,
    title: str,
    methodology: Methodology,
) -> None:
    if not HAS_MATPLOTLIB:
        return

    versions = [s.version for s in summary]
    medians = [s.median_ms if s.median_ms is not None else math.nan for s in summary]
    lows = [s.ci_low_ms if s.ci_low_ms is not None else s.median_ms for s in summary]
    highs = [s.ci_high_ms if s.ci_high_ms is not None else s.median_ms for s in summary]
    x = list(range(len(summary)))

    fig, ax = plt.subplots(figsize=(13, 6.4))
    ax.plot(x, medians, color="#005f73", marker="o", linewidth=2, label="Median compile time")

    if all(v is not None for v in lows) and all(v is not None for v in highs):
        ax.fill_between(x, lows, highs, color="#94d2bd", alpha=0.35, label="95% bootstrap CI")

    flagged_versions = {
        row["to_version"]
        for row in regression_rows
        if str(row.get("compile_regression", "0")) in {"1", "True", "true"}
    }

    for idx, stat in enumerate(summary):
        if stat.version in flagged_versions and stat.median_ms is not None:
            ax.scatter(idx, stat.median_ms, color="#bb3e03", s=90, zorder=3)

    ax.set_title(title)
    ax.set_ylabel("Compile wall time (ms)")
    ax.set_xlabel("DMD version")
    ax.set_xticks(x)
    ax.set_xticklabels(versions, rotation=45, ha="right")
    ax.grid(alpha=0.25)
    ax.legend(loc="upper left")
    fig.subplots_adjust(bottom=0.24)
    fig.text(
        0.01,
        0.01,
        textwrap.fill(methodology.short_plot_note(), width=120),
        ha="left",
        va="bottom",
        fontsize=8,
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=160)
    plt.close(fig)


def plot_artifact_size(summary: Sequence[VersionStats], out_path: Path, title: str, methodology: Methodology) -> None:
    if not HAS_MATPLOTLIB:
        return

    versions = [s.version for s in summary]
    sizes_kb = [
        (s.artifact_size_bytes / 1024.0) if s.artifact_size_bytes is not None else math.nan
        for s in summary
    ]
    x = list(range(len(summary)))

    fig, ax = plt.subplots(figsize=(13, 5.4))
    ax.bar(x, sizes_kb, color="#0a9396", alpha=0.85)
    ax.set_title(title)
    ax.set_ylabel("Compile-only object size (KB)")
    ax.set_xlabel("DMD version")
    ax.set_xticks(x)
    ax.set_xticklabels(versions, rotation=45, ha="right")
    ax.grid(axis="y", alpha=0.25)
    fig.subplots_adjust(bottom=0.24)
    fig.text(
        0.01,
        0.01,
        textwrap.fill(methodology.short_plot_note(), width=120),
        ha="left",
        va="bottom",
        fontsize=8,
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, dpi=160)
    plt.close(fig)


def read_csv_if_exists(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def build_report(
    report_path: Path,
    track_results: Dict[str, TrackResult],
    trace_rows: Sequence[Dict[str, str]],
    granularity_rows: Sequence[Dict[str, str]],
) -> None:
    lines: List[str] = []
    lines.append("# DMD Performance Regression Study")
    lines.append("")
    lines.append(f"Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')}")
    lines.append("")
    lines.append("## Setup Snapshot")
    lines.append("")

    for track_name in sorted(track_results):
        result = track_results[track_name]
        total_runs = sum(s.n_runs for s in result.summary)
        total_failures = sum(s.n_fail for s in result.summary)
        lines.append(f"- **{track_name}**: versions={len(result.summary)} runs={total_runs} failures={total_failures}")

    lines.append("")
    lines.append("## Data Collection Methodology")
    lines.append("")
    methodology = next(iter(track_results.values())).methodology
    lines.append(
        f"- Benchmark: `{methodology.benchmark_label}` ({methodology.benchmark_description})."
    )
    lines.append(
        f"- Release-sweep command: `{methodology.compile_command}`."
    )
    lines.append(
        "- Plotted `compile time` means wall-clock time for the compile-only command above; linking is excluded."
    )
    lines.append(
        f"- Sampling policy: {methodology.warmup_runs} warmups + {methodology.measured_runs} measured runs per release; plot and CSV use the median of measured runs."
    )
    lines.append(
        f"- Machine: `{methodology.hostname}` / `{methodology.cpu_brand}` / `{methodology.os_value}`."
    )
    lines.append(
        f"- Phase attribution (`-ftime-trace`) was collected separately with `{methodology.trace_compiler_label}`, not with each historical release binary."
    )

    lines.append("")
    lines.append("## Track Comparison")
    lines.append("")
    lines.append("- `latest20` is used to stay literal with Dennis's latest-release direction, even if host compatibility causes failures.")
    lines.append("- `compatible20` is used for stable regression scoring on this machine.")
    lines.append("- Artifact size represents compile-only object output (`-c`), not final linked executable size.")

    if "latest20" in track_results:
        latest = track_results["latest20"]
        lines.append("")
        lines.append("## latest20 Availability")
        lines.append("")
        if latest.failure_counts:
            lines.append("| Failure kind | Count |")
            lines.append("|---|---:|")
            for kind, count in sorted(latest.failure_counts.items(), key=lambda kv: kv[1], reverse=True):
                lines.append(f"| {kind} | {count} |")
        else:
            lines.append("No failures were recorded in latest20 measured runs.")

    if "compatible20" in track_results:
        compatible = track_results["compatible20"]
        compile_regressions = [
            row
            for row in compatible.regressions
            if str(row.get("compile_regression", "0")) in {"1", "True", "true"}
        ]
        improvements = []
        for row in compatible.regressions:
            try:
                pct = float(row.get("pct_change_compile_ms", ""))
            except ValueError:
                continue
            if pct <= -10.0:
                improvements.append(row)

        lines.append("")
        lines.append("## compatible20 Key Regressions")
        lines.append("")
        if compile_regressions:
            lines.append("| From | To | Compile change | CI separated |")
            lines.append("|---|---:|---:|---:|")
            for row in compile_regressions[:8]:
                lines.append(
                    f"| {row['from_version']} | {row['to_version']} | {row['pct_change_compile_ms']}% | {row['ci_separated']} |"
                )
        else:
            lines.append("No compile-time regressions passed the threshold + CI separation rule.")

        lines.append("")
        lines.append("## compatible20 Notable Improvements")
        lines.append("")
        if improvements:
            lines.append("| From | To | Compile change |")
            lines.append("|---|---:|---:|")
            for row in improvements[:6]:
                lines.append(f"| {row['from_version']} | {row['to_version']} | {row['pct_change_compile_ms']}% |")
        else:
            lines.append("No improvements exceeded -10% on median compile time.")

    lines.append("")
    lines.append("## Phase-Level Trace Signals")
    lines.append("")
    if trace_rows:
        lines.append("| Phase | Total ms | Share | Event count |")
        lines.append("|---|---:|---:|---:|")
        for row in trace_rows[:6]:
            lines.append(
                f"| {row.get('phase', '')} | {row.get('total_ms', '')} | {row.get('percent', '')}% | {row.get('event_count', '')} |"
            )
    else:
        lines.append("No trace summary found. Run `./run_trace.sh` to generate phase attribution.")

    lines.append("")
    lines.append("## Granularity Sweep")
    lines.append("")
    if granularity_rows:
        lines.append("| Granularity | Trace size (bytes) | Timed events | Dominant phase | Dominant share |")
        lines.append("|---|---:|---:|---|---:|")
        for row in granularity_rows:
            lines.append(
                f"| {row.get('granularity', '')} | {row.get('trace_size_bytes', '')} | {row.get('timed_events', '')} | {row.get('dominant_phase', '')} | {row.get('dominant_phase_pct', '')}% |"
            )
    else:
        lines.append("No granularity sweep data found. Use `--granularity-sweep` in `run_trace.sh`.")

    lines.append("")
    lines.append("## Recommended Metrics for Publisher v1")
    lines.append("")
    lines.append("- End-to-end compile median (warmups excluded)")
    lines.append("- Noise indicators: MAD and CI width")
    lines.append("- Regression trigger: percent jump + non-overlapping CIs")
    lines.append("- Phase buckets from `-ftime-trace` (semantic/template/codegen)")

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def analyze_track(track: str, rows: Sequence[Dict[str, str]], args: argparse.Namespace, out_root: Path, multi_track: bool) -> TrackResult:
    summary, failure_counts = summarize_versions(rows, bootstrap_samples=args.bootstrap_samples)
    regressions = regression_scan(summary, threshold=args.regression_threshold)
    methodology = infer_methodology(rows, args)

    out_dir = out_root / track if multi_track else out_root
    out_dir.mkdir(parents=True, exist_ok=True)

    summary_rows = [
        {
            "track": track,
            "version": s.version,
            "n_runs": s.n_runs,
            "n_ok": s.n_ok,
            "n_fail": s.n_fail,
            "median_ms": safe_float(s.median_ms),
            "mad_ms": safe_float(s.mad_ms),
            "mean_ms": safe_float(s.mean_ms),
            "ci_low_ms": safe_float(s.ci_low_ms),
            "ci_high_ms": safe_float(s.ci_high_ms),
            "artifact_size_bytes": safe_float(s.artifact_size_bytes),
        }
        for s in summary
    ]
    write_csv(
        out_dir / args.summary_csv,
        summary_rows,
        [
            "track",
            "version",
            "n_runs",
            "n_ok",
            "n_fail",
            "median_ms",
            "mad_ms",
            "mean_ms",
            "ci_low_ms",
            "ci_high_ms",
            "artifact_size_bytes",
        ],
    )

    regression_rows = [{"track": track, **row} for row in regressions]
    write_csv(
        out_dir / args.regression_csv,
        regression_rows,
        [
            "track",
            "from_version",
            "to_version",
            "pct_change_compile_ms",
            "pct_change_artifact_size",
            "ci_separated",
            "compile_regression",
            "size_regression",
            "flag_reason",
        ],
    )

    plot_compile(
        summary,
        regressions,
        out_dir / "compile_time_trend.png",
        f"DMD Compile Wall Time for {methodology.benchmark_label} ({track})",
        methodology,
    )
    plot_artifact_size(
        summary,
        out_dir / "artifact_size_trend.png",
        f"DMD Compile-Only Object Size for {methodology.benchmark_label} ({track})",
        methodology,
    )

    return TrackResult(
        track=track,
        summary=summary,
        regressions=regressions,
        failure_counts=failure_counts,
        total_rows=len(rows),
        methodology=methodology,
    )


def resolve_track_inputs(args: argparse.Namespace) -> Dict[str, Path]:
    if args.input:
        return {"compatible20": Path(args.input)}

    input_dir = Path(args.input_dir)
    tracks = [item.strip() for item in args.tracks.split(",") if item.strip()]
    if not tracks:
        raise SystemExit("No tracks provided")

    track_paths: Dict[str, Path] = {}
    for track in tracks:
        candidate = input_dir / track / "results_raw.csv"
        if candidate.exists():
            track_paths[track] = candidate
            continue

        fallback = input_dir / "results_raw.csv"
        if len(tracks) == 1 and fallback.exists():
            track_paths[track] = fallback
            continue

        raise SystemExit(f"Could not find input CSV for track '{track}' (checked {candidate})")

    return track_paths


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    track_paths = resolve_track_inputs(args)
    multi_track = len(track_paths) > 1

    track_results: Dict[str, TrackResult] = {}
    for track, path in track_paths.items():
        rows = load_rows(path)
        if not rows:
            raise SystemExit(f"No rows found in {path}")
        track_results[track] = analyze_track(track, rows, args, out_dir, multi_track)

    if multi_track and "compatible20" in track_results:
        comp_dir = out_dir / "compatible20"
        for filename in (args.summary_csv, args.regression_csv, "compile_time_trend.png", "artifact_size_trend.png"):
            src = comp_dir / filename
            if src.exists():
                (out_dir / filename).write_bytes(src.read_bytes())

    trace_rows = read_csv_if_exists(Path(args.trace_summary))
    granularity_rows = read_csv_if_exists(Path(args.granularity_csv))
    build_report(out_dir / args.report, track_results, trace_rows, granularity_rows)

    for track in track_results:
        target_dir = out_dir / track if multi_track else out_dir
        print(f"[{track}] Wrote summary CSV: {target_dir / args.summary_csv}")
        print(f"[{track}] Wrote regression table: {target_dir / args.regression_csv}")
        if HAS_MATPLOTLIB:
            print(f"[{track}] Wrote plot: {target_dir / 'compile_time_trend.png'}")
            print(f"[{track}] Wrote plot: {target_dir / 'artifact_size_trend.png'}")
        else:
            print("matplotlib not available; skipped PNG plot generation")

    print(f"Wrote report: {out_dir / args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
