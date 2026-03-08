# Performance Regression Publisher: Done/Not-Done Audit (2026-03-08)

## Status Summary

- Core Dennis prototype checklist (12 items from "Not Done" gist): **done**
- GSoC competitiveness extras (community-visible engagement, upstream contributions): **partially done**
- Parser in-compiler threading prototype: **done (local evidence captured)**
- Cross-platform validation (Linux `perf`, Linux latest20 non-crash timings): **not done on this host**

## Detailed Matrix

| Area | Status | Evidence | Notes |
|---|---|---|---|
| Perfetto trace screenshot | done | `artifacts/not_done/perfetto/perfetto_trace.png` | Captured from `artifacts/trace.json` |
| `std.range/std.algorithm` vs procedural (`ldc2 -O3`) | done | `artifacts/not_done/zero_cost_ldc/runtime_summary.csv` | Range median 68.810 ms vs procedural 9.809 ms |
| `libphobos` section size audit | done | `artifacts/not_done/libphobos_sections/report.md` | Largest member: `zlib.o` |
| Large non-zero-init structs scan | done | `artifacts/not_done/large_non_zero_init_structs/scan_results.csv` | 1129 probes, 0 hits for threshold 512 |
| Unused strings/arrays linker stripping | done | `artifacts/not_done/linker_strip_unused_data/results.csv` | Marker absent for unused-only scenarios |
| AST field-order randomization impact | done | `artifacts/not_done/ast_field_order/results.csv` | 3 seeds completed |
| Lexer/parser parallel test (surrogate) | done | `artifacts/not_done/lexer_parser_parallel/speedup.csv` | Process-level parallel compile surrogate for baseline scaling reference |
| Lexer/parser in-compiler threaded prototype | done + advanced | `artifacts/upgrades/parser_thread_compare_final/comparison.csv` | Single-process parser prototype using `ParserParallelPrototype`; strict run passed at 1/2/4 threads with a correctness-first parse lock |
| Allocator replacement (mimalloc/jemalloc) | done | `artifacts/not_done/allocator_compare/results.csv` | Modes tested: system,mimalloc,jemalloc |
| C vs D assembly comparison | done + upgraded | `artifacts/upgrades/not_done/c_vs_d_assembly/report.md` | Upgraded from 1 kernel to 5 kernels |
| `dmd -profile` vs external profiler | done (host-limited) | `artifacts/not_done/dmd_profile_compare/sample_report.txt` | macOS uses `sample`; Linux `perf` pending |
| Compiler fuzzing | done | `artifacts/not_done/compiler_fuzz/results.csv` | 1000 compile errors, 0 crashes |
| `char[] > 4GB` truncation probe | done | `artifacts/not_done/large_char_array_4gb/run_stdout.txt` | Probe reported `ok=1` |
| Switch scaling benchmark | done + upgraded | `artifacts/upgrades/switch_scaling_v2/report.md` | Upgraded points: 100,300,1000,3000,10000 |
| Specific mentor questions | done | `submission/mentor_packet.md` | Questions are explicit and reviewable |
| AI usage disclosure | done | `submission/ai_usage_disclosure.md` | Concise disclosure exists |
| Public community engagement links (issue/PR/forum) | partial | `submission/community_activity.md` | Tracker created; links still to be populated |
| Upstream merged PR(s) from findings | not done | `submission/community_activity.md` | Requires external repo contribution cycle |
| Linux `perf` comparison run | not done | `submission/high_signal_findings.md` | Blocked by host/tool availability |
| Linux latest20 compile trend (non-crash) | not done | `artifacts/report.md` | Current host latest20 is crash-only |

## What Is Missing for a Stronger Submission

- Add at least one upstream issue and one PR linked from `submission/community_activity.md`
- Add Linux validation run for:
  - `dmd -profile` vs `perf`
  - latest20 release trend with successful compile timings

## Automation Added for Gap Closure

- Linux bundle runner: `./linux_gap_close.sh`
  - Produces Linux latest20/compatible20 trend outputs, Linux `dmd_profile_compare`, and in-compiler parser benchmark.
  - Enforces PASS/FAIL gates (script exits non-zero if closure gates fail).
- Parser binary comparison runner: `./parser_threading_compare.sh`
  - Compares baseline DMD vs candidate threaded DMD using in-compiler parser benchmark output.
  - Enforces strict success gate (fails if any requested thread count has zero successful runs).
- Parser prototype builder: `./build_parser_threaded_dmd.sh`
  - Builds a candidate DMD binary with `-version=ParserParallelPrototype` for threaded parse experiments.
- Execution guide: `submission/linux_gap_close_runbook.md`
- CI workflow: `.github/workflows/linux-gap-close.yml`
  - Runs Linux gap-close on Ubuntu and uploads artifacts for submission links.
