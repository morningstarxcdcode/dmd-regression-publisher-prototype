#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/artifacts/strict_perf_probe}"
PERF_BIN="${PERF_BIN:-}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Validates that a Linux host can run the strict perf workflow requirements.

Options:
  --out-dir <path>    Output directory (default: artifacts/strict_perf_probe)
  --perf-bin <path>   Explicit perf binary path (or PERF_BIN env)
  --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir) OUT_DIR="$2"; shift 2 ;;
        --perf-bin) PERF_BIN="$2"; shift 2 ;;
        --help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "strict_perf_probe.sh is intended for Linux hosts only." >&2
    exit 2
fi

mkdir -p "$OUT_DIR"

if [[ -z "$PERF_BIN" ]]; then
    PERF_BIN="$(command -v perf || true)"
fi

SUMMARY_MD="$OUT_DIR/summary.md"
SUMMARY_JSON="$OUT_DIR/summary.json"
TMP_DIR="$OUT_DIR/probe_tmp"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

KERNEL_REL="$(uname -r)"
KERNEL_OK=0
STAT_OK=0
RECORD_OK=0
REPORT_OK=0
PERF_VERSION=""
REASON=""

if [[ -z "$PERF_BIN" || ! -x "$PERF_BIN" ]]; then
    REASON="perf binary not found"
else
    PERF_VERSION="$("$PERF_BIN" --version 2>&1 | head -n 1 || true)"
    if [[ "$PERF_BIN" == *"$KERNEL_REL"* ]] || [[ "$PERF_VERSION" == *"$KERNEL_REL"* ]]; then
        KERNEL_OK=1
    fi

    set +e
    "$PERF_BIN" stat -- true >"$OUT_DIR/perf_stat_stdout.txt" 2>"$OUT_DIR/perf_stat_stderr.txt"
    STAT_RC=$?
    set -e
    if [[ $STAT_RC -eq 0 ]]; then
        STAT_OK=1
    fi

    set +e
    "$PERF_BIN" record -o "$TMP_DIR/perf.data" -- /bin/true >"$OUT_DIR/perf_record_stdout.txt" 2>"$OUT_DIR/perf_record_stderr.txt"
    RECORD_RC=$?
    set -e
    if [[ $RECORD_RC -eq 0 && -f "$TMP_DIR/perf.data" ]]; then
        RECORD_OK=1
    fi

    set +e
    "$PERF_BIN" report --stdio -i "$TMP_DIR/perf.data" >"$OUT_DIR/perf_report.txt" 2>"$OUT_DIR/perf_report_stderr.txt"
    REPORT_RC=$?
    set -e
    if [[ $REPORT_RC -eq 0 && -s "$OUT_DIR/perf_report.txt" ]]; then
        REPORT_OK=1
    fi

    if [[ $STAT_OK -eq 0 || $RECORD_OK -eq 0 || $REPORT_OK -eq 0 ]]; then
        REASON="perf probe failed"
    fi
fi

{
    echo "# Strict perf probe"
    echo
    echo "- Kernel release: \`$KERNEL_REL\`"
    echo "- perf binary: \`${PERF_BIN:-missing}\`"
    echo "- perf version: \`${PERF_VERSION:-missing}\`"
    echo "- Kernel match heuristic: $KERNEL_OK"
    echo "- perf stat ok: $STAT_OK"
    echo "- perf record ok: $RECORD_OK"
    echo "- perf report ok: $REPORT_OK"
    echo "- Reason: ${REASON:--}"
} >"$SUMMARY_MD"

cat >"$SUMMARY_JSON" <<EOF
{
  "kernel_release": "$KERNEL_REL",
  "perf_bin": "${PERF_BIN:-}",
  "perf_version": "${PERF_VERSION//\"/\\\"}",
  "kernel_match_ok": $KERNEL_OK,
  "perf_stat_ok": $STAT_OK,
  "perf_record_ok": $RECORD_OK,
  "perf_report_ok": $REPORT_OK,
  "reason": "${REASON//\"/\\\"}"
}
EOF

if [[ $STAT_OK -eq 0 || $RECORD_OK -eq 0 || $REPORT_OK -eq 0 ]]; then
    exit 3
fi
