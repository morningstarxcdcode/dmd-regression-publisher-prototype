#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/DataAnalysisExpert/command_logs"
SUMMARY_CSV="$ROOT_DIR/DataAnalysisExpert/command_run_summary.csv"
BASELINE_DMD="$ROOT_DIR/.locald/dmd-nightly/osx/bin/dmd"
THREADED_DMD="$ROOT_DIR/external/dmd/generated/osx/debug/64/dmd"
TIMEOUT_SCALE="${TIMEOUT_SCALE:-1}"

mkdir -p "$LOG_DIR"

echo 'target,status,exit_code,duration_sec,timeout_sec,log_file' > "$SUMMARY_CSV"

scaled_timeout() {
  local base="$1"
  echo $((base * TIMEOUT_SCALE))
}

timeout_for_target() {
  case "$1" in
    dmdbench-build)
      scaled_timeout 30
      ;;
    bench-latest|bench-compatible|bench-both)
      scaled_timeout 1800
      ;;
    analyze-both|trace|switch-bench|runtime-libs|dub-pgo|strict-perf-probe|linux-gap-close)
      case "$1" in
        analyze-both)
          scaled_timeout 180
          ;;
        trace|switch-bench|strict-perf-probe)
          scaled_timeout 300
          ;;
        runtime-libs)
          scaled_timeout 900
          ;;
        dub-pgo|linux-gap-close)
          scaled_timeout 1800
          ;;
      esac
      ;;
    not-done|not-done-perfetto|broader-gist|build-parser-threaded-dmd|parser-thread-compare)
      case "$1" in
        build-parser-threaded-dmd)
          scaled_timeout 1800
          ;;
        parser-thread-compare)
          scaled_timeout 900
          ;;
        *)
          scaled_timeout 3600
          ;;
      esac
      ;;
    *)
      scaled_timeout 120
      ;;
  esac
}

run_make_target() {
  local log_path="$1"
  local timeout_sec="$2"
  shift 2

  python3 - "$log_path" "$timeout_sec" "$@" <<'PY'
import os
import signal
import subprocess
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
timeout_sec = int(sys.argv[2])
cmd = ["make", *sys.argv[3:]]

log_path.parent.mkdir(parents=True, exist_ok=True)
with log_path.open("w", encoding="utf-8") as handle:
    handle.write("$ " + " ".join(cmd) + "\n")
    proc = None
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=log_path.parents[2],
            stdout=handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        code = proc.wait(timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        if proc is not None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        handle.write(f"\n[TIMEOUT] exceeded {timeout_sec}s\n")
        code = 124
    except Exception as exc:
        handle.write(f"\n[ERROR] runner exception: {exc}\n")
        code = 1

print(code)
PY
}

TARGETS=(
  dmdbench-build
  bench-latest
  bench-compatible
  bench-both
  analyze-both
  trace
  switch-bench
  not-done
  not-done-perfetto
  runtime-libs
  dub-pgo
  broader-gist
  strict-perf-probe
  linux-gap-close
  build-parser-threaded-dmd
  parser-thread-compare
)

for target in "${TARGETS[@]}"; do
  ts="$(date +%Y%m%d_%H%M%S)"
  log="$LOG_DIR/${target}_${ts}.log"
  timeout_sec="$(timeout_for_target "$target")"
  echo "[RUN] $target"
  start="$(date +%s)"

  if [[ "$target" == "parser-thread-compare" ]]; then
    rc="$(run_make_target "$log" "$timeout_sec" "$target" "BASELINE_DMD=$BASELINE_DMD" "THREADED_DMD=$THREADED_DMD")"
  else
    rc="$(run_make_target "$log" "$timeout_sec" "$target")"
  fi

  end="$(date +%s)"
  dur=$((end - start))

  if [[ "$rc" == "0" ]]; then
    status="pass"
  elif [[ "$rc" == "124" ]]; then
    status="timeout"
  else
    status="fail"
  fi

  rel_log="DataAnalysisExpert/command_logs/$(basename "$log")"
  echo "$target,$status,$rc,$dur,$timeout_sec,$rel_log" >> "$SUMMARY_CSV"
  echo "[DONE] $target => $status (rc=$rc, ${dur}s, timeout=${timeout_sec}s)"
done

cat "$SUMMARY_CSV"
