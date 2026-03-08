#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$SCRIPT_DIR/.venv/bin/python}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-$SCRIPT_DIR/artifacts/linux_gap_close}"
DMD_BIN="${DMD_BIN:-$SCRIPT_DIR/.locald/dmd-nightly/linux/bin64/dmd}"
PROFILE_DMD_BIN="${PROFILE_DMD_BIN:-$DMD_BIN}"
PARSER_DMD_BIN="${PARSER_DMD_BIN:-$DMD_BIN}"
LDC2_BIN="${LDC2_BIN:-$SCRIPT_DIR/.locald/ldc-1.42.0/bin/ldc2}"
CLANG_BIN="${CLANG_BIN:-clang}"
PARSER_THREADS="${PARSER_THREADS:-1,2,4,8}"
PARSER_REPEATS="${PARSER_REPEATS:-5}"
PARSER_FILE_COUNT="${PARSER_FILE_COUNT:-96}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Runs Linux-focused closure for remaining "partial" items:
  1) latest20 + compatible20 release timing (Linux archive flavor)
  2) dmd -profile vs perf comparison (Linux perf path)
  3) in-compiler parser threading benchmark (real single-process parser path)

Options:
  --python-bin <path>      Python executable (default: .venv/bin/python)
  --artifact-root <path>   Output root (default: artifacts/linux_gap_close)
  --dmd-bin <path>         Legacy default DMD binary for both profile/parser tasks
  --profile-dmd-bin <path> DMD binary for dmd_profile_compare
  --parser-dmd-bin <path>  DMD binary for parser_incompiler_parallel
  --ldc2-bin <path>        LDC2 binary path
  --clang-bin <path>       Clang binary path
  --parser-threads <csv>   Parser in-compiler thread counts (default: 1,2,4,8)
  --parser-repeats <n>     Parser repeats per thread count (default: 5)
  --parser-file-count <n>  Parser generated file count (default: 96)
  --help                   Show this help
EOF
}

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --python-bin) PYTHON_BIN="$2"; shift 2 ;;
        --artifact-root) ARTIFACT_ROOT="$2"; shift 2 ;;
        --dmd-bin)
            DMD_BIN="$2"
            PROFILE_DMD_BIN="$2"
            PARSER_DMD_BIN="$2"
            shift 2
            ;;
        --profile-dmd-bin) PROFILE_DMD_BIN="$2"; shift 2 ;;
        --parser-dmd-bin) PARSER_DMD_BIN="$2"; shift 2 ;;
        --ldc2-bin) LDC2_BIN="$2"; shift 2 ;;
        --clang-bin) CLANG_BIN="$2"; shift 2 ;;
        --parser-threads) PARSER_THREADS="$2"; shift 2 ;;
        --parser-repeats) PARSER_REPEATS="$2"; shift 2 ;;
        --parser-file-count) PARSER_FILE_COUNT="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "linux_gap_close.sh is intended for Linux hosts only." >&2
    exit 2
fi

if [[ ! -x "$PYTHON_BIN" ]]; then
    echo "Python binary not executable: $PYTHON_BIN" >&2
    exit 2
fi

if [[ ! -x "$PROFILE_DMD_BIN" ]]; then
    echo "Profile DMD binary not executable: $PROFILE_DMD_BIN" >&2
    exit 2
fi

if [[ ! -x "$PARSER_DMD_BIN" ]]; then
    echo "Parser DMD binary not executable: $PARSER_DMD_BIN" >&2
    exit 2
fi

mkdir -p "$ARTIFACT_ROOT"

if ! command -v perf >/dev/null 2>&1; then
    log "perf not available in PATH; Linux profile task may be reported as blocked."
fi

RELEASE_DIR="$ARTIFACT_ROOT/releases"
NOT_DONE_DIR="$ARTIFACT_ROOT/not_done_linux"
SUMMARY_FILE="$ARTIFACT_ROOT/summary.md"

log "Step 1/4: Linux release sweep (latest20 + compatible20)"
"$SCRIPT_DIR/bench_releases.sh" \
    --track both \
    --track-out-dir "$RELEASE_DIR" \
    --cache-dir "$SCRIPT_DIR/.cache/dmd-releases-linux"

log "Step 2/4: Analyze release sweep"
"$PYTHON_BIN" "$SCRIPT_DIR/analyze_results.py" \
    --input-dir "$RELEASE_DIR" \
    --tracks latest20,compatible20 \
    --out-dir "$RELEASE_DIR"

log "Step 3/4: Linux not_done subset (dmd profile + in-compiler parser threading)"
"$PYTHON_BIN" "$SCRIPT_DIR/not_done_experiments.py" \
    --out-dir "$NOT_DONE_DIR/profile" \
    --tasks dmd_profile_compare \
    --dmd "$PROFILE_DMD_BIN" \
    --ldc2 "$LDC2_BIN" \
    --clang "$CLANG_BIN" \
    --task-timeout 900

"$PYTHON_BIN" "$SCRIPT_DIR/not_done_experiments.py" \
    --out-dir "$NOT_DONE_DIR/parser" \
    --tasks parser_incompiler_parallel \
    --dmd "$PARSER_DMD_BIN" \
    --ldc2 "$LDC2_BIN" \
    --clang "$CLANG_BIN" \
    --parser-threads "$PARSER_THREADS" \
    --parser-repeats "$PARSER_REPEATS" \
    --parser-file-count "$PARSER_FILE_COUNT" \
    --task-timeout 900

"$PYTHON_BIN" - "$NOT_DONE_DIR/profile/status.csv" "$NOT_DONE_DIR/parser/status.csv" "$NOT_DONE_DIR/status.csv" "$NOT_DONE_DIR/status.md" <<'PY'
import csv
import sys
from pathlib import Path

profile_csv = Path(sys.argv[1])
parser_csv = Path(sys.argv[2])
out_csv = Path(sys.argv[3])
out_md = Path(sys.argv[4])

rows = []
fieldnames = set()
for path in (profile_csv, parser_csv):
    if not path.exists():
        continue
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            rows.append(row)
            fieldnames.update(row.keys())

ordered = ["task", "status", "task_key"] + sorted(k for k in fieldnames if k not in {"task", "status", "task_key"})
with out_csv.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=ordered)
    writer.writeheader()
    for row in rows:
        writer.writerow({key: row.get(key, "") for key in ordered})

lines = [
    "# Linux not_done status",
    "",
    "| Task | Status | Task Key |",
    "|---|---|---|",
]
for row in rows:
    lines.append(f"| {row.get('task', '')} | {row.get('status', '')} | {row.get('task_key', '')} |")
out_md.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

log "Step 4/4: Build summary"
"$PYTHON_BIN" - "$RELEASE_DIR" "$NOT_DONE_DIR" "$SUMMARY_FILE" <<'PY'
import csv
import json
import sys
from pathlib import Path

release_dir = Path(sys.argv[1])
not_done_dir = Path(sys.argv[2])
summary_file = Path(sys.argv[3])

latest_csv = release_dir / "latest20" / "results_raw.csv"
compat_csv = release_dir / "compatible20" / "results_raw.csv"
status_csv = not_done_dir / "status.csv"
parser_speedup_csv = not_done_dir / "parser" / "parser_incompiler_parallel" / "speedup.csv"

def count_ok_fail(path: Path):
    ok = fail = 0
    if not path.exists():
        return ok, fail
    for row in csv.DictReader(path.open("r", encoding="utf-8")):
        if row.get("is_warmup") != "0":
            continue
        if row.get("ok") == "1":
            ok += 1
        else:
            fail += 1
    return ok, fail

latest_ok, latest_fail = count_ok_fail(latest_csv)
compat_ok, compat_fail = count_ok_fail(compat_csv)

profile_status = parser_incompiler_status = "missing"
if status_csv.exists():
    for row in csv.DictReader(status_csv.open("r", encoding="utf-8")):
        key = row.get("task_key", "")
        if key == "dmd_profile_compare":
            profile_status = row.get("status", "unknown")
        if key == "parser_incompiler_parallel":
            parser_incompiler_status = row.get("status", "unknown")

parser_threads_total = 0
parser_threads_with_success = 0
parser_threads_missing_success: list[str] = []
if parser_speedup_csv.exists():
    for row in csv.DictReader(parser_speedup_csv.open("r", encoding="utf-8")):
        parser_threads_total += 1
        thr = row.get("threads", "?")
        try:
            successful = int((row.get("successful_runs", "") or "0").strip() or "0")
        except ValueError:
            successful = 0
        if successful > 0:
            parser_threads_with_success += 1
        else:
            parser_threads_missing_success.append(thr)

parser_thread_coverage_ok = parser_threads_total > 0 and parser_threads_with_success == parser_threads_total

lines = [
    "# Linux Gap-Close Summary",
    "",
    f"- latest20 measured runs: ok={latest_ok} fail={latest_fail}",
    f"- compatible20 measured runs: ok={compat_ok} fail={compat_fail}",
    f"- dmd_profile_compare task status: {profile_status}",
    f"- parser_incompiler_parallel task status: {parser_incompiler_status}",
    "",
    "## Closure gates",
    "",
    f"- Gate A (latest20 has successful Linux runs): {'PASS' if latest_ok > 0 else 'FAIL'}",
    f"- Gate B (dmd_profile_compare on Linux perf): {'PASS' if profile_status == 'done' else 'FAIL'}",
    f"- Gate C (parser_incompiler_parallel executed): {'PASS' if parser_incompiler_status == 'done' else 'FAIL'}",
    f"- Gate D (parser thread coverage: each configured thread has successful runs): {'PASS' if parser_thread_coverage_ok else 'FAIL'}",
    f"- Parser threads missing success: {','.join(parser_threads_missing_success) if parser_threads_missing_success else '-'}",
    "",
    "## Key output paths",
    "",
    f"- Release analysis: `{release_dir / 'report.md'}`",
    f"- not_done status: `{not_done_dir / 'status.md'}`",
    f"- not_done raw status CSV: `{status_csv}`",
]
summary_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(summary_file)

if (
    latest_ok <= 0
    or profile_status != "done"
    or parser_incompiler_status != "done"
    or not parser_thread_coverage_ok
):
    raise SystemExit(3)
PY

log "Completed. Summary: $SUMMARY_FILE"
