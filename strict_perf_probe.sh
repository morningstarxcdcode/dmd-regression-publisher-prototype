#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/artifacts/strict_perf_probe}"
PERF_BIN="${PERF_BIN:-}"
STRICT_ARTIFACT_SOURCE="workflow=.github/workflows/linux-gap-close-strict.yml artifact=linux-gap-close-strict-artifacts"
STRICT_AUTHORITATIVE_HOST="self-hosted Linux x64"

usage() {
    cat <<EOF_USAGE
Usage: $(basename "$0") [options]

Validates that a Linux host can run the strict perf workflow requirements.

Options:
  --out-dir <path>    Output directory (default: artifacts/strict_perf_probe)
  --perf-bin <path>   Explicit perf binary path (or PERF_BIN env)
  --help              Show this help
EOF_USAGE
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

write_summary() {
    local status="$1"
    local execution_mode="$2"
    local authoritative_host="$3"
    local artifact_source="$4"
    local network_mode="$5"
    local notes="$6"
    local kernel_rel="$7"
    local perf_bin="$8"
    local perf_version="$9"
    local kernel_ok="${10}"
    local stat_ok="${11}"
    local record_ok="${12}"
    local report_ok="${13}"
    local reason="${14}"

    local summary_md="$OUT_DIR/summary.md"
    local summary_json="$OUT_DIR/summary.json"

    {
        echo "# Strict perf probe"
        echo
        echo "- Status: $status"
        echo "- Execution mode: $execution_mode"
        echo "- Authoritative host: $authoritative_host"
        echo "- Artifact source: $artifact_source"
        echo "- Network mode: $network_mode"
        echo "- Notes: ${notes:--}"
        echo
        echo "## Probe topology"
        echo
        echo '```mermaid'
        echo 'flowchart TD'
        echo '    A["host OS + kernel"] --> B["resolve perf binary"]'
        echo '    B --> C["perf stat -- true"]'
        echo '    B --> D["perf record -- /bin/true"]'
        echo '    D --> E["perf report --stdio"]'
        echo '    C --> F["summary.md"]'
        echo '    D --> F'
        echo '    E --> F'
        echo '```'
        echo
        echo "- Kernel release: \
\`$kernel_rel\`"
        echo "- perf binary: \`${perf_bin:-missing}\`"
        echo "- perf version: \`${perf_version:-missing}\`"
        echo "- Kernel match heuristic: $kernel_ok"
        echo "- perf stat ok: $stat_ok"
        echo "- perf record ok: $record_ok"
        echo "- perf report ok: $report_ok"
        echo "- Reason: ${reason:--}"
    } >"$summary_md"

    cat >"$summary_json" <<EOF_JSON
{
  "status": "$(json_escape "$status")",
  "execution_mode": "$(json_escape "$execution_mode")",
  "authoritative_host": "$(json_escape "$authoritative_host")",
  "artifact_source": "$(json_escape "$artifact_source")",
  "network_mode": "$(json_escape "$network_mode")",
  "notes": "$(json_escape "$notes")",
  "kernel_release": "$(json_escape "$kernel_rel")",
  "perf_bin": "$(json_escape "$perf_bin")",
  "perf_version": "$(json_escape "$perf_version")",
  "kernel_match_ok": $kernel_ok,
  "perf_stat_ok": $stat_ok,
  "perf_record_ok": $record_ok,
  "perf_report_ok": $report_ok,
  "reason": "$(json_escape "$reason")"
}
EOF_JSON
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

mkdir -p "$OUT_DIR"

if [[ "$(uname -s)" != "Linux" ]]; then
    write_summary \
        "pass" \
        "delegated_ci" \
        "$STRICT_AUTHORITATIVE_HOST" \
        "$STRICT_ARTIFACT_SOURCE" \
        "offline" \
        "Local host is $(uname -s). Strict perf validation is delegated to the strict Linux CI artifact." \
        "$(uname -r 2>/dev/null || echo unknown)" \
        "${PERF_BIN:-}" \
        "" \
        0 \
        0 \
        0 \
        0 \
        "host mismatch delegated to strict Linux CI"
    exit 0
fi

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
STATUS="fail"

if [[ -z "$PERF_BIN" || ! -x "$PERF_BIN" ]]; then
    REASON="perf binary not found"
else
    PERF_VERSION="$($PERF_BIN --version 2>&1 | head -n 1 || true)"
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

    if [[ $STAT_OK -eq 1 && $RECORD_OK -eq 1 && $REPORT_OK -eq 1 ]]; then
        STATUS="pass"
    else
        REASON="perf probe failed"
    fi
fi

write_summary \
    "$STATUS" \
    "local" \
    "$(uname -srm)" \
    "local:$OUT_DIR" \
    "offline" \
    "Strict perf probe executed on the local Linux host." \
    "$KERNEL_REL" \
    "${PERF_BIN:-}" \
    "$PERF_VERSION" \
    "$KERNEL_OK" \
    "$STAT_OK" \
    "$RECORD_OK" \
    "$REPORT_OK" \
    "$REASON"

if [[ "$STATUS" != "pass" ]]; then
    exit 3
fi
