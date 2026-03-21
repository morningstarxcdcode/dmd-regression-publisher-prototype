#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-dmdbench-build}"
TIMEOUT_SEC="${2:-180}"
LOG_DIR="$ROOT_DIR/DataAnalysisExpert/command_logs"
mkdir -p "$LOG_DIR"

TS="$(date +%Y%m%d_%H%M%S)"
LOG="$LOG_DIR/${TARGET}_verify_${TS}.log"

python3 - "$LOG" "$TIMEOUT_SEC" "$TARGET" <<'PY'
import os
import signal
import subprocess
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
timeout_sec = int(sys.argv[2])
target = sys.argv[3]
cmd = ["make", target]

with log_path.open("w", encoding="utf-8") as f:
    f.write("$ " + " ".join(cmd) + "\n")
    proc = subprocess.Popen(cmd, cwd=log_path.parents[2], stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        code = proc.wait(timeout=timeout_sec)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        f.write(f"\n[TIMEOUT] exceeded {timeout_sec}s\n")
        code = 124

print(code)
print(log_path)
PY
