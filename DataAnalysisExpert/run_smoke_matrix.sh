#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/DataAnalysisExpert/smoke_logs"
SUMMARY_CSV="$ROOT_DIR/DataAnalysisExpert/smoke_command_summary.csv"
PY="$ROOT_DIR/.venv/bin/python"
DMD="$ROOT_DIR/.locald/dmd-nightly/osx/bin/dmd"
LDC2="$ROOT_DIR/.locald/ldc-1.42.0/bin/ldc2"

mkdir -p "$LOG_DIR" "$ROOT_DIR/DataAnalysisExpert/smoke_artifacts" "$ROOT_DIR/DataAnalysisExpert/smoke_not_done"

echo 'name,status,exit_code,duration_sec,log_file' > "$SUMMARY_CSV"

run_cmd() {
  local name="$1"
  local cmd="$2"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local log="$LOG_DIR/${name}_${ts}.log"

  echo "[RUN] $name"
  local start end dur rc status
  start="$(date +%s)"

  (cd "$ROOT_DIR" && bash -lc "$cmd") >"$log" 2>&1
  rc=$?

  end="$(date +%s)"
  dur=$((end - start))
  if [[ $rc -eq 0 ]]; then
    status="pass"
  else
    status="fail"
  fi

  echo "$name,$status,$rc,$dur,DataAnalysisExpert/smoke_logs/$(basename "$log")" >> "$SUMMARY_CSV"
  echo "[DONE] $name => $status (rc=$rc, ${dur}s)"
}

# Core build/check
run_cmd "dmdbench_build" "make dmdbench-build"

# Release sweep + analysis (reduced rigor for session-time feasibility)
run_cmd "sweep_both_smoke" "./bench_releases.sh --track both --versions-file DataAnalysisExpert/smoke_versions_compatible.txt --latest-file DataAnalysisExpert/smoke_versions_latest.txt --runs 1 --warmups 0 --timeout-sec 20 --track-out-dir DataAnalysisExpert/smoke_artifacts --latest-source file --archive-source cache"
run_cmd "analyze_both_smoke" "$PY ./analyze_results.py --input-dir DataAnalysisExpert/smoke_artifacts --tracks latest20,compatible20 --out-dir DataAnalysisExpert/smoke_artifacts"

# Trace and switch scaling
run_cmd "trace_smoke" "./run_trace.sh --python-bin $PY --dmd-bin $DMD --out-dir DataAnalysisExpert/smoke_artifacts --granularity 1 --granularity-sweep 1,10"
run_cmd "switch_scale_smoke" "$PY ./switch_case_experiment.py --compiler $DMD --case-counts 100,1000 --runs 3 --warmups 1 --out-dir DataAnalysisExpert/smoke_artifacts/switch_scaling"

# not_done focused paths that map to Make targets
run_cmd "runtime_libs_smoke" "$PY ./not_done_experiments.py --out-dir DataAnalysisExpert/smoke_not_done --tasks gc_kernels,aa_kernels,float_to_string_kernels --runtime-runs 1 --runtime-warmups 0 --task-timeout 300"
run_cmd "dub_pgo_smoke" "$PY ./not_done_experiments.py --out-dir DataAnalysisExpert/smoke_not_done --tasks dub_pgo --dub-pgo-runs 1 --dub-upstream-source cached --clone-timeout 20 --task-timeout 300"

# Linux-only probes now delegate to authoritative Linux CI artifacts on non-Linux hosts.
run_cmd "strict_perf_probe" "./strict_perf_probe.sh --out-dir DataAnalysisExpert/smoke_strict_perf"
run_cmd "linux_gap_close" "./linux_gap_close.sh --python-bin $PY --gate-b-mode strict --dmd-bin $DMD"

# Parser-related paths
run_cmd "build_parser_threaded" "./build_parser_threaded_dmd.sh --host-dmd $DMD"
run_cmd "parser_thread_compare" "./parser_threading_compare.sh --python-bin $PY --baseline-dmd $DMD --threaded-dmd ./external/dmd/generated/osx/debug/64/dmd --threads 1,2 --repeats 1 --file-counts 16,32 --out-dir DataAnalysisExpert/smoke_parser_compare"

cat "$SUMMARY_CSV"
