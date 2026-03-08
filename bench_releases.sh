#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPAT_VERSIONS_FILE="$SCRIPT_DIR/versions_compatible20.txt"
LATEST_VERSIONS_FILE="$SCRIPT_DIR/versions_latest20.txt"
BENCHMARK_FILE="$SCRIPT_DIR/benchmark.d"
CACHE_DIR="$SCRIPT_DIR/.cache/dmd-releases"
ARTIFACT_DIR="$SCRIPT_DIR/artifacts"
OUT_CSV=""
RUNS=7
WARMUPS=2
TIMEOUT_SEC=120
TRACK="both" # latest20 | compatible20 | both
DMD_ARCHIVE_FLAVOR=""

resolve_archive_flavor() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo unknown)"
    case "$uname_s" in
        Darwin)
            echo "osx"
            ;;
        Linux)
            echo "linux"
            ;;
        *)
            echo ""
            ;;
    esac
}

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --track <name>            latest20, compatible20, or both (default: both).
  --versions-file <path>    Compatible-track version list file.
  --latest-file <path>      Path for auto-generated latest20 version list.
  --benchmark <path>        D benchmark source file (default: benchmark.d).
  --runs <n>                Number of measured runs per version (default: 7).
  --warmups <n>             Number of warmup runs per version (default: 2).
  --cache-dir <path>        Download and extraction cache directory.
  --track-out-dir <path>    Root output directory for per-track artifacts.
  --out-csv <path>          Output CSV path for single-track mode only.
  --timeout-sec <n>         Per-compile timeout in seconds (default: 120).
  --help                    Show this message.
USAGE
}

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

csv_escape() {
    local value="${1:-}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    value="${value//\"/\"\"}"
    printf '"%s"' "$value"
}

classify_failure() {
    local exit_code="$1"
    local error_hint="$2"

    if [[ "$exit_code" == "124" ]]; then
        echo "timeout"
        return
    fi

    if [[ "$exit_code" == "-11" || "$exit_code" == "139" || "$exit_code" == "134" || "$error_hint" == *"Segmentation fault"* ]]; then
        echo "runtime_crash"
        return
    fi

    if [[ "$error_hint" == *"unrecognized switch"* ]]; then
        echo "unsupported_switch"
        return
    fi

    if [[ "$error_hint" == *"linker exited"* ]]; then
        echo "linker_error"
        return
    fi

    if [[ "$error_hint" == *"download failed"* ]]; then
        echo "download_fail"
        return
    fi

    if [[ "$error_hint" == *"archive extraction failed"* ]]; then
        echo "extract_fail"
        return
    fi

    echo "compile_error"
}

append_row() {
    local out_csv="$1"
    local track="$2"
    local version="$3"
    local run_idx="$4"
    local is_warmup="$5"
    local time_ms="$6"
    local artifact_size="$7"
    local ok="$8"
    local error_code="$9"
    local failure_kind="${10}"
    local error_hint="${11}"
    local hostname_value="${12}"
    local cpu_brand="${13}"
    local os_value="${14}"
    local ts="${15}"

    {
        printf '%s,' "$(csv_escape "$track")"
        printf '%s,' "$(csv_escape "$version")"
        printf '%s,' "$(csv_escape "$run_idx")"
        printf '%s,' "$(csv_escape "$is_warmup")"
        printf '%s,' "$(csv_escape "$time_ms")"
        printf '%s,' "$(csv_escape "object")"
        printf '%s,' "$(csv_escape "$artifact_size")"
        printf '%s,' "$(csv_escape "$ok")"
        printf '%s,' "$(csv_escape "$error_code")"
        printf '%s,' "$(csv_escape "$failure_kind")"
        printf '%s,' "$(csv_escape "$error_hint")"
        printf '%s,' "$(csv_escape "$hostname_value")"
        printf '%s,' "$(csv_escape "$cpu_brand")"
        printf '%s,' "$(csv_escape "$os_value")"
        printf '%s\n' "$(csv_escape "$ts")"
    } >> "$out_csv"
}

measure_compile() {
    local dmd_bin="$1"
    local benchmark_path="$2"
    local out_obj="$3"
    local timeout_sec="$4"

    python3 - "$dmd_bin" "$benchmark_path" "$out_obj" "$timeout_sec" <<'PY'
import os
import subprocess
import sys
import time

dmd, benchmark, out_obj, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
cmd = [dmd, benchmark, f"-of={out_obj}", "-O", "-c"]
start_ns = time.perf_counter_ns()

try:
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=False)
    elapsed_ms = (time.perf_counter_ns() - start_ns) // 1_000_000
    stderr_text = proc.stderr.decode("utf-8", "ignore").strip()
    err_lines = stderr_text.splitlines()
    hint = err_lines[-1] if err_lines else ""
    size = os.path.getsize(out_obj) if proc.returncode == 0 and os.path.exists(out_obj) else -1
    print(elapsed_ms)
    print(proc.returncode)
    print(size)
    print(hint)
except subprocess.TimeoutExpired:
    elapsed_ms = (time.perf_counter_ns() - start_ns) // 1_000_000
    print(elapsed_ms)
    print(124)
    print(-1)
    print("compile timed out")
PY
}

resolve_latest_versions() {
    local output_file="$1"
    local tmp_index
    tmp_index="$(mktemp)"

    if ! curl -fsSL "https://downloads.dlang.org/releases/2.x/" > "$tmp_index"; then
        rm -f "$tmp_index"
        return 1
    fi

    if ! python3 - "$tmp_index" "$output_file" <<'PY'; then
import re
import sys
from pathlib import Path

index_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
text = index_path.read_text(encoding="utf-8", errors="ignore")
versions = sorted(set(re.findall(r"2\.\d+\.\d+", text)), key=lambda s: tuple(int(p) for p in s.split(".")))
latest = versions[-20:]
if len(latest) < 20:
    raise SystemExit("Failed to resolve 20 releases from release index")
out_path.write_text(
    "# Auto-generated latest 20 DMD releases from downloads.dlang.org\n" + "\n".join(latest) + "\n",
    encoding="utf-8",
)
print(f"Resolved latest releases: {latest[0]} .. {latest[-1]}")
PY
        rm -f "$tmp_index"
        return 1
    fi

    rm -f "$tmp_index"
    return 0
}

load_versions() {
    local versions_file="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        printf '%s\n' "$line"
    done < "$versions_file"
}

run_track() {
    local track_name="$1"
    local versions_file="$2"
    local out_csv="$3"

    local -a versions=()
    while IFS= read -r version_line || [[ -n "$version_line" ]]; do
        versions+=("$version_line")
    done < <(load_versions "$versions_file")

    if [[ ${#versions[@]} -eq 0 ]]; then
        echo "No versions found in $versions_file" >&2
        return 1
    fi

    mkdir -p "$(dirname "$out_csv")"

    printf 'track,version,run_idx,is_warmup,time_ms,artifact_kind,artifact_size_bytes,ok,error_code,failure_kind,error_hint,hostname,cpu_brand,os,timestamp\n' > "$out_csv"

    log "[$track_name] Starting sweep across ${#versions[@]} versions"
    log "[$track_name] Measured runs/version: $RUNS | Warmups/version: $WARMUPS | Timeout: ${TIMEOUT_SEC}s"
    log "[$track_name] Output CSV: $out_csv"

    local version
    for version in "${versions[@]}"; do
        log "[$track_name] Preparing DMD $version"

        local tarball="$CACHE_DIR/dmd.${version}.${DMD_ARCHIVE_FLAVOR}.tar.xz"
        local extract_dir="$CACHE_DIR/dmd-${version}-${DMD_ARCHIVE_FLAVOR}"
        local url="https://downloads.dlang.org/releases/2.x/${version}/dmd.${version}.${DMD_ARCHIVE_FLAVOR}.tar.xz"

        if [[ ! -x "$extract_dir/osx/bin/dmd" ]]; then
            mkdir -p "$extract_dir"
            if [[ ! -f "$tarball" ]]; then
                if ! curl -fL --retry 3 --retry-delay 2 -o "$tarball" "$url" >/dev/null 2>&1; then
                    log "[$track_name] Download failed for $version"
                    local ts
                    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                    append_row "$out_csv" "$track_name" "$version" "-1" "0" "0" "-1" "0" "DL_FAIL" "download_fail" "download failed" "$HOSTNAME_VALUE" "$CPU_BRAND" "$OS_VALUE" "$ts"
                    continue
                fi
            fi

            rm -rf "$extract_dir"
            mkdir -p "$extract_dir"
            if ! tar -xf "$tarball" -C "$extract_dir" --strip-components=1 >/dev/null 2>&1; then
                log "[$track_name] Extraction failed for $version"
                local ts
                ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                append_row "$out_csv" "$track_name" "$version" "-1" "0" "0" "-1" "0" "EXTRACT_FAIL" "extract_fail" "archive extraction failed" "$HOSTNAME_VALUE" "$CPU_BRAND" "$OS_VALUE" "$ts"
                continue
            fi
        fi

        local dmd_bin="$extract_dir/${DMD_ARCHIVE_FLAVOR}/bin/dmd"
        if [[ ! -x "$dmd_bin" ]]; then
            dmd_bin="$extract_dir/${DMD_ARCHIVE_FLAVOR}/bin64/dmd"
        fi
        if [[ ! -x "$dmd_bin" ]]; then
            dmd_bin="$(
                find "$extract_dir" -type f \( -path '*/bin/dmd' -o -path '*/bin64/dmd' \) 2>/dev/null \
                    | head -n 1
            )"
        fi

        if [[ -z "$dmd_bin" || ! -x "$dmd_bin" ]]; then
            log "[$track_name] DMD binary not found for $version"
            local ts
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            append_row "$out_csv" "$track_name" "$version" "-1" "0" "0" "-1" "0" "BIN_NOT_FOUND" "binary_not_found" "unable to locate dmd executable" "$HOSTNAME_VALUE" "$CPU_BRAND" "$OS_VALUE" "$ts"
            continue
        fi

        local -a measured_times=()
        local -a measured_sizes=()
        local total_runs=$((WARMUPS + RUNS))

        local run_no
        for ((run_no = 1; run_no <= total_runs; run_no++)); do
            local is_warmup=0
            local csv_run_idx=$((run_no - WARMUPS))
            if ((run_no <= WARMUPS)); then
                is_warmup=1
                csv_run_idx=$run_no
            fi

            local out_obj="$ARTIFACT_DIR/.tmp_${track_name}_${version//./_}_${run_no}.o"
            local result_output
            result_output="$(measure_compile "$dmd_bin" "$BENCHMARK_FILE" "$out_obj" "$TIMEOUT_SEC")"

            local -a result_lines=()
            while IFS= read -r line || [[ -n "$line" ]]; do
                result_lines+=("$line")
            done <<DATA
$result_output
DATA

            local time_ms="${result_lines[0]:-0}"
            local exit_code="${result_lines[1]:-1}"
            local artifact_size="${result_lines[2]:--1}"
            local error_hint="${result_lines[3]:-unknown error}"
            local ok=0
            local failure_kind=""

            if [[ "$exit_code" == "0" ]]; then
                ok=1
                error_hint=""
                if ((is_warmup == 0)); then
                    measured_times+=("$time_ms")
                    if [[ "$artifact_size" =~ ^[0-9]+$ ]] && ((artifact_size > 0)); then
                        measured_sizes+=("$artifact_size")
                    fi
                fi
            else
                failure_kind="$(classify_failure "$exit_code" "$error_hint")"
            fi

            local ts
            ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            append_row "$out_csv" "$track_name" "$version" "$csv_run_idx" "$is_warmup" "$time_ms" "$artifact_size" "$ok" "$exit_code" "$failure_kind" "$error_hint" "$HOSTNAME_VALUE" "$CPU_BRAND" "$OS_VALUE" "$ts"
            rm -f "$out_obj"
        done

        if [[ ${#measured_times[@]} -gt 0 ]]; then
            local sorted_times=($(printf '%s\n' "${measured_times[@]}" | sort -n))
            local median_idx=$(( ${#sorted_times[@]} / 2 ))
            local median_time="${sorted_times[$median_idx]}"

            local median_size="-1"
            if [[ ${#measured_sizes[@]} -gt 0 ]]; then
                local sorted_sizes=($(printf '%s\n' "${measured_sizes[@]}" | sort -n))
                local size_idx=$(( ${#sorted_sizes[@]} / 2 ))
                median_size="${sorted_sizes[$size_idx]}"
            fi
            log "[$track_name] DMD $version complete: median=${median_time}ms object_size=${median_size} bytes"
        else
            log "[$track_name] DMD $version complete: no successful measured runs"
        fi
    done

    log "[$track_name] Sweep complete. Raw measurements: $out_csv"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --track)
            TRACK="$2"
            shift 2
            ;;
        --versions-file)
            COMPAT_VERSIONS_FILE="$2"
            shift 2
            ;;
        --latest-file)
            LATEST_VERSIONS_FILE="$2"
            shift 2
            ;;
        --benchmark)
            BENCHMARK_FILE="$2"
            shift 2
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --warmups)
            WARMUPS="$2"
            shift 2
            ;;
        --cache-dir)
            CACHE_DIR="$2"
            shift 2
            ;;
        --track-out-dir)
            ARTIFACT_DIR="$2"
            shift 2
            ;;
        --out-csv)
            OUT_CSV="$2"
            shift 2
            ;;
        --timeout-sec)
            TIMEOUT_SEC="$2"
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

if [[ "$TRACK" != "latest20" && "$TRACK" != "compatible20" && "$TRACK" != "both" ]]; then
    echo "--track must be one of: latest20, compatible20, both" >&2
    exit 1
fi

if [[ ! -f "$BENCHMARK_FILE" ]]; then
    echo "Benchmark file not found: $BENCHMARK_FILE" >&2
    exit 1
fi

if [[ ! -f "$COMPAT_VERSIONS_FILE" ]]; then
    echo "Compatible versions file not found: $COMPAT_VERSIONS_FILE" >&2
    exit 1
fi

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || ! [[ "$WARMUPS" =~ ^[0-9]+$ ]] || ! [[ "$TIMEOUT_SEC" =~ ^[0-9]+$ ]]; then
    echo "--runs, --warmups, and --timeout-sec must be non-negative integers" >&2
    exit 1
fi

if [[ "$TRACK" == "both" && -n "$OUT_CSV" ]]; then
    echo "--out-csv can only be used with single-track mode" >&2
    exit 1
fi

DMD_ARCHIVE_FLAVOR="$(resolve_archive_flavor)"
if [[ -z "$DMD_ARCHIVE_FLAVOR" ]]; then
    echo "Unsupported host OS: $(uname -s 2>/dev/null || echo unknown)" >&2
    echo "This script currently supports Darwin and Linux only." >&2
    exit 1
fi

mkdir -p "$CACHE_DIR" "$ARTIFACT_DIR"

HOSTNAME_VALUE="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown-host)"
CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu 2>/dev/null | awk -F: '/Model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' || echo unknown-cpu)"
OS_VALUE="$(uname -srm 2>/dev/null || echo unknown-os)"
log "Using DMD release archive flavor: $DMD_ARCHIVE_FLAVOR"

if [[ "$TRACK" == "latest20" || "$TRACK" == "both" ]]; then
    if ! resolve_latest_versions "$LATEST_VERSIONS_FILE"; then
        echo "Failed to resolve latest 20 versions from release index" >&2
        exit 1
    fi
fi

if [[ "$TRACK" == "latest20" ]]; then
    if [[ -n "$OUT_CSV" ]]; then
        run_track "latest20" "$LATEST_VERSIONS_FILE" "$OUT_CSV"
    else
        run_track "latest20" "$LATEST_VERSIONS_FILE" "$ARTIFACT_DIR/results_raw.csv"
    fi
elif [[ "$TRACK" == "compatible20" ]]; then
    if [[ -n "$OUT_CSV" ]]; then
        run_track "compatible20" "$COMPAT_VERSIONS_FILE" "$OUT_CSV"
    else
        run_track "compatible20" "$COMPAT_VERSIONS_FILE" "$ARTIFACT_DIR/results_raw.csv"
    fi
else
    run_track "latest20" "$LATEST_VERSIONS_FILE" "$ARTIFACT_DIR/latest20/results_raw.csv"
    run_track "compatible20" "$COMPAT_VERSIONS_FILE" "$ARTIFACT_DIR/compatible20/results_raw.csv"
    cp "$ARTIFACT_DIR/compatible20/results_raw.csv" "$ARTIFACT_DIR/results_raw.csv"
    log "[both] Copied compatible track CSV to $ARTIFACT_DIR/results_raw.csv for convenience"
fi
