# DMD Regression Prototype (Dennis 2026 Alignment)

This prototype follows the Performance Regression Publisher direction with a dual-track workflow:

- `latest20`: literal interpretation of "latest ~20 releases" from downloads.dlang.org.
- `compatible20`: release window that runs reliably on this host for stable regression scoring.

## Why Dual Track

Dennis explicitly asks for latest-release evidence and concrete findings. On macOS arm64, some DMD releases are not consistently runnable. Dual-track output keeps both truths visible:

- Latest-release compatibility reality (`latest20` failures are evidence, not hidden).
- High-signal compile regressions from a fully runnable baseline (`compatible20`).

## What It Produces

- `artifacts/latest20/results_raw.csv`: raw latest-release measurements with failure taxonomy.
- `artifacts/compatible20/results_raw.csv`: raw compatible-track measurements.
- `artifacts/<track>/results_summary.csv`: per-version median, MAD, mean, CI, object size.
- `artifacts/<track>/regression_table.csv`: adjacent-version regression scan.
- `artifacts/<track>/compile_time_trend.png`: compile-time trend.
- `artifacts/<track>/artifact_size_trend.png`: compile-only object-size trend.
- `artifacts/trace.json`: main ftime-trace JSON.
- `artifacts/trace_phase_summary.csv`: phase-level attribution.
- `artifacts/trace_phase_bar.png`: phase chart.
- `artifacts/trace_granularity_sweep.csv`: granularity comparison table.
- `artifacts/report.md`: consolidated narrative report.
- `artifacts/switch_scaling/*`: switch-case scaling experiment artifacts (`100/1000/10000`).

## Requirements

- macOS, `bash`, `curl`, `tar`, `python3`.
- `matplotlib` for PNG generation.
- Trace-capable DMD build (example below uses workspace-local `dmd-nightly`).

Recommended Python setup:

```bash
python3 -m venv .venv
./.venv/bin/pip install matplotlib
```

## Quick Start

```bash
# 1) Run both tracks
./bench_releases.sh --track both

# 2) Analyze both tracks
./.venv/bin/python ./analyze_results.py --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts

# 3) Install trace-capable DMD (workspace-local)
curl -fsSL https://dlang.org/install.sh | bash -s -- -p ./.locald install dmd-nightly

# 4) Run trace + granularity sweep
./run_trace.sh --python-bin ./.venv/bin/python --dmd-bin ./.locald/dmd-nightly/osx/bin/dmd --granularity 1 --granularity-sweep 1,10,50,100

# 5) Rebuild report with trace context
./.venv/bin/python ./analyze_results.py --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts --trace-summary artifacts/trace_phase_summary.csv --granularity-csv artifacts/trace_granularity_sweep.csv

# 6) Run Dennis idea #1: switch cases vs compile time
./.venv/bin/python ./switch_case_experiment.py --compiler ./.locald/dmd-nightly/osx/bin/dmd --case-counts 100,1000,10000 --runs 7 --warmups 2 --out-dir artifacts/switch_scaling

# 7) Run additional "Not Done" gist items that are feasible here
./.venv/bin/python ./not_done_experiments.py --out-dir artifacts/not_done

# Optional: try automatic Perfetto screenshot capture from artifacts/trace.json
./.venv/bin/python ./not_done_experiments.py --out-dir artifacts/not_done --attempt-perfetto-screenshot

# Optional: build a ParserParallelPrototype DMD binary for in-compiler parser testing
./build_parser_threaded_dmd.sh --host-dmd ./.locald/dmd-nightly/osx/bin/dmd

# Optional: compare baseline vs threaded parser behavior (real in-compiler path)
./parser_threading_compare.sh --python-bin ./.venv/bin/python --baseline-dmd ./external/dmd/generated/osx/release/64/dmd --threaded-dmd ./external/dmd/generated/osx/debug/64/dmd

# Optional (Linux only): strict local/self-hosted gap close with real Gate-B perf requirement
./linux_gap_close.sh --python-bin ./.venv/bin/python --gate-b-mode strict --dmd-bin /path/to/dmd
```

## Important Method Notes

- Compile benchmarking uses `-c` mode: this measures compiler work while avoiding host linker mismatch noise.
- Artifact size metric is compile output object size, not linked executable size.
- Regression trigger is intentionally conservative: percentage jump + non-overlapping bootstrap CIs.
- The local `external/dmd` checkout is not part of the Git repo snapshot; the parser-prototype frontend change is preserved in `patches/external_dmd_parser_parallel_prototype.patch`.
- GitHub-hosted Linux validation treats missing kernel-matched `perf` as a documented `SKIP` for Gate B; strict Linux perf closure lives in `.github/workflows/linux-gap-close-strict.yml`.

## Extra Not-Done Artifacts

Running `not_done_experiments.py` writes:

- `artifacts/not_done/zero_cost_ldc/*`: `std.range/std.algorithm` vs `foreach` with `ldc2 -O3`.
- `artifacts/not_done/libphobos_sections/*`: section-size sort for `libphobos2.a`.
- `artifacts/not_done/linker_strip_unused_data/*`: unused strings/arrays linker-strip behavior.
- `artifacts/not_done/c_vs_d_assembly/*`: `clang` vs `ldc2` assembly comparison for equivalent function.
- `artifacts/not_done/large_char_array_4gb/*`: `char[]` larger-than-4GB truncation probe.
- `artifacts/not_done/compiler_fuzz/*`: random mutation fuzz run over `dmd/compiler/test` seeds.
- `artifacts/not_done/status.md`: checklist-style done/blocked summary.

## Mentor Feedback Hooks (Specific Questions)

- Are the dual-track chart labels (`latest20` vs `compatible20`) clear enough about what is being measured?
- Is object-size trend acceptable as a proxy on this host, or should this be reframed further?
- Does the phase table plus granularity sweep provide useful signal for choosing publisher metrics?
- For switch scaling, are the 100/1000/10000 data points enough for the submission, or should I include intermediate points for better curve shape?
