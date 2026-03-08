#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DMD_BIN="dmd"
BENCHMARK_FILE="$SCRIPT_DIR/benchmark.d"
OUT_DIR="$SCRIPT_DIR/artifacts"
TRACE_NAME="trace.json"
GRANULARITY=1
GRANULARITY_SWEEP=""
SWEEP_CSV=""
PYTHON_BIN="python3"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --dmd-bin <path>             DMD executable (default: dmd from PATH)
  --benchmark <path>           Benchmark source file (default: benchmark.d)
  --out-dir <path>             Output directory (default: artifacts)
  --trace-name <name>          Trace file name (default: trace.json)
  --granularity <n>            ftime-trace granularity for main trace (default: 1)
  --granularity-sweep <list>   Comma-separated sweep values (e.g. 1,10,50,100)
  --sweep-csv <path>           Sweep CSV output path (default: <out-dir>/trace_granularity_sweep.csv)
  --python-bin <path>          Python executable (default: python3)
  --help                       Show this message
USAGE
}

run_trace_compile() {
    local granularity="$1"
    local trace_path="$2"
    local out_obj="$3"

    set +e
    "$DMD_BIN" "$BENCHMARK_FILE" "-of=$out_obj" "-c" "-ftime-trace" "-ftime-trace-file=$trace_path" "-ftime-trace-granularity=$granularity" >/dev/null 2>&1
    local status=$?
    set -e

    if [[ $status -ne 0 ]]; then
        "$DMD_BIN" "$BENCHMARK_FILE" "-of=$out_obj" "-c" "-ftime-trace=$trace_path" "-ftime-trace-granularity=$granularity" >/dev/null
    fi
}

run_python() {
    MPLCONFIGDIR="$OUT_DIR/.cache/matplotlib" XDG_CACHE_HOME="$OUT_DIR/.cache" "$PYTHON_BIN" "$@"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmd-bin)
            DMD_BIN="$2"
            shift 2
            ;;
        --benchmark)
            BENCHMARK_FILE="$2"
            shift 2
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --trace-name)
            TRACE_NAME="$2"
            shift 2
            ;;
        --granularity)
            GRANULARITY="$2"
            shift 2
            ;;
        --granularity-sweep)
            GRANULARITY_SWEEP="$2"
            shift 2
            ;;
        --sweep-csv)
            SWEEP_CSV="$2"
            shift 2
            ;;
        --python-bin)
            PYTHON_BIN="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

mkdir -p "$OUT_DIR"
TRACE_PATH="$OUT_DIR/$TRACE_NAME"
OUT_OBJ="$OUT_DIR/.trace_build.o"
mkdir -p "$OUT_DIR/.cache/matplotlib" "$OUT_DIR/.cache/fontconfig"

if [[ -z "$SWEEP_CSV" ]]; then
    SWEEP_CSV="$OUT_DIR/trace_granularity_sweep.csv"
fi

echo "Generating trace with: $DMD_BIN"
run_trace_compile "$GRANULARITY" "$TRACE_PATH" "$OUT_OBJ"
rm -f "$OUT_OBJ"

if [[ ! -s "$TRACE_PATH" ]]; then
    echo "Trace file was not created: $TRACE_PATH" >&2
    exit 1
fi

run_python "$SCRIPT_DIR/trace_phase.py" \
    --input "$TRACE_PATH" \
    --out-csv "$OUT_DIR/trace_phase_summary.csv" \
    --events-csv "$OUT_DIR/trace_event_summary.csv" \
    --plot "$OUT_DIR/trace_phase_bar.png"

if [[ -n "$GRANULARITY_SWEEP" ]]; then
    echo "granularity,trace_size_bytes,timed_events,dominant_phase,dominant_phase_pct" > "$SWEEP_CSV"
    IFS=',' read -r -a SWEEP_VALUES <<< "$GRANULARITY_SWEEP"

    for raw in "${SWEEP_VALUES[@]}"; do
        g="$(echo "$raw" | tr -d '[:space:]')"
        if [[ -z "$g" ]]; then
            continue
        fi
        if ! [[ "$g" =~ ^[0-9]+$ ]]; then
            echo "Skipping invalid granularity value: $raw"
            continue
        fi

        SWEEP_TRACE="$OUT_DIR/.trace_g${g}.json"
        SWEEP_OBJ="$OUT_DIR/.trace_g${g}.o"
        SWEEP_PHASE="$OUT_DIR/.trace_g${g}_phase.csv"
        SWEEP_EVENTS="$OUT_DIR/.trace_g${g}_events.csv"

        run_trace_compile "$g" "$SWEEP_TRACE" "$SWEEP_OBJ"
        rm -f "$SWEEP_OBJ"

        if [[ ! -s "$SWEEP_TRACE" ]]; then
            echo "$g,0,0,missing,0" >> "$SWEEP_CSV"
            continue
        fi

        run_python "$SCRIPT_DIR/trace_phase.py" \
            --input "$SWEEP_TRACE" \
            --out-csv "$SWEEP_PHASE" \
            --events-csv "$SWEEP_EVENTS" \
            --plot "$OUT_DIR/.trace_g${g}.png" \
            --no-plot >/dev/null

        run_python - "$g" "$SWEEP_TRACE" "$SWEEP_PHASE" "$SWEEP_CSV" <<'PY'
import csv
import json
import os
import sys
from pathlib import Path

granularity = sys.argv[1]
trace_path = Path(sys.argv[2])
phase_csv = Path(sys.argv[3])
sweep_csv = Path(sys.argv[4])

trace_payload = json.loads(trace_path.read_text(encoding="utf-8", errors="ignore"))
if isinstance(trace_payload, dict):
    events = trace_payload.get("traceEvents", [])
elif isinstance(trace_payload, list):
    events = trace_payload
else:
    events = []

timed_events = sum(1 for ev in events if isinstance(ev, dict) and ev.get("ph") in {"X", ""} and float(ev.get("dur", 0) or 0) > 0)
trace_size = os.path.getsize(trace_path)

phase = ""
pct = ""
if phase_csv.exists():
    with phase_csv.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        first = next(reader, None)
        if first:
            phase = first.get("phase", "")
            pct = first.get("percent", "")

with sweep_csv.open("a", encoding="utf-8") as handle:
    handle.write(f"{granularity},{trace_size},{timed_events},{phase},{pct}\n")
PY

        rm -f "$SWEEP_TRACE" "$SWEEP_PHASE" "$SWEEP_EVENTS" "$OUT_DIR/.trace_g${g}.png"
    done

    echo "Granularity sweep CSV: $SWEEP_CSV"
fi

echo "Trace JSON: $TRACE_PATH"
echo "Phase summary: $OUT_DIR/trace_phase_summary.csv"
