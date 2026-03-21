#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARY="$ROOT_DIR/DataAnalysisExpert/command_run_summary.csv"
LOG_DIR="$ROOT_DIR/DataAnalysisExpert/command_logs"

mkdir -p "$LOG_DIR"

run_target() {
  local target="$1"
  local timeout_sec="$2"
  shift 2

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local log="$LOG_DIR/${target}_${ts}.log"
  local start end dur status rc

  start="$(date +%s)"

  rc="$(python3 - "$log" "$timeout_sec" "$target" "$@" <<'PY'
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
)"

  end="$(date +%s)"
  dur="$((end - start))"

  if [[ "$rc" == "0" ]]; then
    status="pass"
  elif [[ "$rc" == "124" ]]; then
    status="timeout"
  else
    status="fail"
  fi

  echo "$target,$status,$rc,$dur,$timeout_sec,DataAnalysisExpert/command_logs/$(basename "$log")" >> "$SUMMARY"
  echo "[$target] $status rc=$rc dur=${dur}s timeout=${timeout_sec}s"
}

run_target broader-gist 120
run_target strict-perf-probe 90
run_target linux-gap-close 90
run_target build-parser-threaded-dmd 120
run_target parser-thread-compare 120 "BASELINE_DMD=./.locald/dmd-nightly/osx/bin/dmd" "THREADED_DMD=./external/dmd/generated/osx/debug/64/dmd"

tail -n +1 "$SUMMARY"
