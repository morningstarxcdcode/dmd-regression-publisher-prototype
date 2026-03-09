# Performance Regression Publisher: Done/Not-Done Audit (2026-03-08)

## Status Summary

- Core Dennis prototype checklist (original 12 tracked items): **done**
- Broader gist runtime-library kernels: **done**
- Broader gist `dub` PGO benchmark: **implemented, host-blocked**
- GSoC competitiveness extras (community-visible engagement, upstream contributions): **partially done**
- Parser in-compiler threading prototype: **advanced but still performance-partial**
- Cross-platform validation (Linux `perf`, Linux latest20 non-crash timings): **hosted Linux evidence exists; strict `perf` still self-hosted only**
- Methodology labeling for compile-time plots/reports: **done**
- Release-window spike attribution note: **started with changelog + commit-window evidence**

## Detailed Matrix

| Area | Status | Evidence | Notes |
|---|---|---|---|
| Perfetto trace screenshot | done | `artifacts/not_done/perfetto/perfetto_trace.png` | Captured from `artifacts/trace.json` |
| `std.range/std.algorithm` vs procedural (`ldc2 -O3`) | done | `artifacts/not_done/zero_cost_ldc/runtime_summary.csv` | Range median 68.810 ms vs procedural 9.809 ms |
| `libphobos` section size audit | done | `artifacts/not_done/libphobos_sections/report.md` | Largest member: `zlib.o` |
| GC kernel benchmarks | done | `artifacts/upgrades/runtime_libs_smoke/gc_kernels/report.md` | Added small/mixed/large allocation kernels |
| Associative-array kernel benchmarks | done | `artifacts/upgrades/runtime_libs_smoke/aa_kernels/report.md` | Insert/lookup/iterate/delete-reinsert across `1k/10k/100k` |
| Float-to-string kernel benchmarks | done | `artifacts/upgrades/runtime_libs_smoke/float_to_string_kernels/report.md` | Normal/scientific/special datasets |
| `dub` PGO benchmark | partial | `artifacts/upgrades/runtime_libs_smoke/status.csv` | Implemented with repo-local LDC toolchain; current host blocks clone/DNS to `github.com` |
| Large non-zero-init structs scan | done | `artifacts/not_done/large_non_zero_init_structs/scan_results.csv` | 1129 probes, 0 hits for threshold 512 |
| Unused strings/arrays linker stripping | done | `artifacts/not_done/linker_strip_unused_data/results.csv` | Marker absent for unused-only scenarios |
| AST field-order randomization impact | done | `artifacts/not_done/ast_field_order/results.csv` | 3 seeds completed |
| Lexer/parser parallel test (surrogate) | done | `artifacts/not_done/lexer_parser_parallel/speedup.csv` | Process-level parallel compile surrogate for baseline scaling reference |
| Lexer/parser in-compiler threaded prototype | partial + advanced | `artifacts/upgrades/parser_thread_compare_narrow/comparison.csv` | Narrow parse path is stable at 1/2/4 threads for `64/128` files, but still slower than coarse mode on this host |
| Allocator replacement (mimalloc/jemalloc) | done | `artifacts/not_done/allocator_compare/results.csv` | Modes tested: system,mimalloc,jemalloc |
| C vs D assembly comparison | done + upgraded | `artifacts/upgrades/not_done/c_vs_d_assembly/report.md` | Upgraded from 1 kernel to 5 kernels |
| `dmd -profile` vs external profiler | done (host-limited) | `artifacts/not_done/dmd_profile_compare/sample_report.txt` | macOS uses `sample`; Linux `perf` pending |
| Compiler fuzzing | done | `artifacts/not_done/compiler_fuzz/results.csv` | 1000 compile errors, 0 crashes |
| `char[] > 4GB` truncation probe | done | `artifacts/not_done/large_char_array_4gb/run_stdout.txt` | Probe reported `ok=1` |
| Switch scaling benchmark | done + upgraded | `artifacts/upgrades/switch_scaling_v2/report.md` | Upgraded points: 100,300,1000,3000,10000 |
| Methodology note in generated report | done | `artifacts/report.md` | Report now defines benchmark, compile command, run policy, and machine |
| Dennis reply draft with clarified methodology | done | `submission/dennis_reply_draft.md` | Ready to send/edit |
| Release-window spike attribution note | partial | `submission/release_spike_attribution.md` | Official changelog + actual `v2.096.0...v2.096.1` commit window captured; full bisect still follow-up |
| Specific mentor questions | done | `submission/mentor_packet.md` | Questions are explicit and reviewable |
| AI usage disclosure | done | `submission/ai_usage_disclosure.md` | Concise disclosure exists |
| Public community engagement links (issue/PR/forum) | partial | `submission/community_activity.md` | Tracker created; links still to be populated |
| Upstream merged PR(s) from findings | not done | `submission/community_activity.md` | Requires external repo contribution cycle |
| Linux `perf` comparison run | partial | `submission/linux_gap_close_runbook.md` | Hosted CI is honest `SKIP`; strict closure requires self-hosted Linux with usable `perf` |
| Linux latest20 compile trend (non-crash) | done on hosted Linux | `.github/workflows/linux-gap-close.yml` | Hosted validation now produces successful Linux latest20 timings |

## What Is Missing for a Stronger Submission

- Add at least one upstream issue and one PR linked from `submission/community_activity.md`
- Post the prepared issue/PR/forum drafts and replace `ready_to_post` placeholders with real links
- Add strict self-hosted Linux validation run for:
  - `dmd -profile` vs `perf`
  - parser speedup if narrow mode improves beyond coarse baseline

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
