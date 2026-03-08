#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$SCRIPT_DIR/.venv/bin/python}"
BASELINE_DMD=""
THREADED_DMD=""
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/artifacts/parser_thread_compare}"
THREADS="${THREADS:-1,2,4,8}"
REPEATS="${REPEATS:-5}"
FILE_COUNT="${FILE_COUNT:-96}"

usage() {
    cat <<EOF
Usage: $(basename "$0") --baseline-dmd <path> --threaded-dmd <path> [options]

Compares in-compiler parser-threading scaling between:
  - baseline DMD binary
  - candidate DMD binary (e.g. ParserParallelPrototype branch)

Options:
  --baseline-dmd <path>    Baseline DMD binary (required)
  --threaded-dmd <path>    Candidate DMD binary (required)
  --python-bin <path>      Python executable (default: .venv/bin/python)
  --out-dir <path>         Output directory (default: artifacts/parser_thread_compare)
  --threads <csv>          Thread counts (default: 1,2,4,8)
  --repeats <n>            Repeats per thread count (default: 5)
  --file-count <n>         Generated source files (default: 96)
  --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline-dmd) BASELINE_DMD="$2"; shift 2 ;;
        --threaded-dmd) THREADED_DMD="$2"; shift 2 ;;
        --python-bin) PYTHON_BIN="$2"; shift 2 ;;
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --repeats) REPEATS="$2"; shift 2 ;;
        --file-count) FILE_COUNT="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$BASELINE_DMD" || -z "$THREADED_DMD" ]]; then
    usage >&2
    exit 2
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python binary not executable: $PYTHON_BIN" >&2
    exit 2
fi

if [[ ! -x "$BASELINE_DMD" ]]; then
    echo "Baseline DMD binary not executable: $BASELINE_DMD" >&2
    exit 2
fi

if [[ ! -x "$THREADED_DMD" ]]; then
    echo "Threaded DMD binary not executable: $THREADED_DMD" >&2
    exit 2
fi

BASELINE_OUT="$OUT_DIR/baseline"
THREADED_OUT="$OUT_DIR/threaded"
COMPARE_CSV="$OUT_DIR/comparison.csv"

mkdir -p "$OUT_DIR"

"$PYTHON_BIN" "$SCRIPT_DIR/not_done_experiments.py" \
    --out-dir "$BASELINE_OUT" \
    --tasks parser_incompiler_parallel \
    --dmd "$BASELINE_DMD" \
    --parser-threads "$THREADS" \
    --parser-repeats "$REPEATS" \
    --parser-file-count "$FILE_COUNT" \
    --task-timeout 900

"$PYTHON_BIN" "$SCRIPT_DIR/not_done_experiments.py" \
    --out-dir "$THREADED_OUT" \
    --tasks parser_incompiler_parallel \
    --dmd "$THREADED_DMD" \
    --parser-threads "$THREADS" \
    --parser-repeats "$REPEATS" \
    --parser-file-count "$FILE_COUNT" \
    --task-timeout 900

"$PYTHON_BIN" - "$BASELINE_OUT/parser_incompiler_parallel/speedup.csv" "$THREADED_OUT/parser_incompiler_parallel/speedup.csv" "$COMPARE_CSV" "$REPEATS" <<'PY'
import csv
import sys
from pathlib import Path

baseline_csv = Path(sys.argv[1])
threaded_csv = Path(sys.argv[2])
out_csv = Path(sys.argv[3])
expected_repeats = int(sys.argv[4])

def load(path: Path):
    rows = {}
    for row in csv.DictReader(path.open("r", encoding="utf-8")):
        try:
            t = int(row["threads"])
            successful = int(row.get("successful_runs", "0") or "0")
        except (KeyError, ValueError):
            continue
        med_text = row.get("median_wall_ms", "").strip()
        med = float(med_text) if med_text else None
        rows[t] = (successful, med)
    return rows

b = load(baseline_csv)
t = load(threaded_csv)
threads = sorted(set(b) | set(t))

out_csv.parent.mkdir(parents=True, exist_ok=True)
with out_csv.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.writer(handle)
    writer.writerow([
        "threads",
        "baseline_successful_runs",
        "threaded_successful_runs",
        "baseline_median_ms",
        "threaded_median_ms",
        "ratio_threaded_over_baseline",
        "improvement_pct",
    ])
    for thr in threads:
        b_ok, bmed = b.get(thr, (0, None))
        t_ok, tmed = t.get(thr, (0, None))
        if bmed is not None and tmed is not None and bmed > 0:
            ratio = tmed / bmed
            improvement = ((bmed - tmed) / bmed * 100.0)
            ratio_str = f"{ratio:.4f}"
            improvement_str = f"{improvement:.3f}"
        else:
            ratio_str = ""
            improvement_str = ""
        writer.writerow([
            thr,
            b_ok,
            t_ok,
            f"{bmed:.3f}" if bmed is not None else "",
            f"{tmed:.3f}" if tmed is not None else "",
            ratio_str,
            improvement_str,
        ])

bad_threads = [
    thr for thr in threads
    if b.get(thr, (0, None))[0] != expected_repeats or t.get(thr, (0, None))[0] != expected_repeats
]
if bad_threads:
    print(
        f"strict gate failed: expected {expected_repeats} successful runs at every thread, bad threads={','.join(str(t) for t in bad_threads)}",
        file=sys.stderr,
    )
    raise SystemExit(3)
PY

echo "Wrote parser threading comparison: $COMPARE_CSV"
