# High-Signal Findings (Evidence-First)

Generated: 2026-03-08

## 1) Switch scaling is strongly non-linear at higher case counts

- Evidence: `artifacts/upgrades/switch_scaling_v2/report.md`
- Result: `3000 -> 10000` cases shows `x6.338` compile-time multiplier, much steeper than lower ranges.
- Why it matters: regression publisher should include stress-shape benchmarks, not only small/medium synthetic inputs.

## 2) In-compiler parser prototype now passes strict 1/2/4-thread runs on this host

- Evidence:
  - `artifacts/upgrades/parser_thread_compare_final/comparison.csv`
  - `artifacts/upgrades/parser_thread_compare_final/threaded/parser_incompiler_parallel/speedup.csv`
- Result:
  - baseline and prototype candidate both completed `3/3` successful runs at `1`, `2`, and `4` threads.
  - correctness is stable, but performance is not yet consistently better than baseline because the current prototype uses a parse-lock safety guard.
- Why it matters: the project moved from surrogate-only evidence to a real single-process compiler prototype with strict pass criteria, and the next step is removing the safety bottleneck safely.

## 3) Allocator swap shows minimal compile-time delta on this host

- Evidence: `artifacts/not_done/allocator_compare/results.csv`
- Result:
  - system median: `1215.675 ms`
  - mimalloc median: `1216.924 ms`
  - jemalloc median: `1212.983 ms`
- Why it matters: allocator change alone is unlikely to produce headline wins for this benchmark; avoid overclaiming.

## 4) `std.range/std.algorithm` is not zero-cost in this specific benchmark shape

- Evidence: `artifacts/not_done/zero_cost_ldc/runtime_summary.csv`
- Result:
  - procedural median: `9.809 ms`
  - range median: `68.810 ms`
  - ratio: `7.015x`
- Why it matters: abstraction cost depends on code shape and optimizer behavior; benchmark design needs multiple kernels before generalized claims.

## 5) C vs D backend parity varies by kernel, not one fixed answer

- Evidence: `artifacts/upgrades/not_done/c_vs_d_assembly/similarity.csv`
- Result: similarity ratios range from `0.0000` to `0.2857` across 5 kernels.
- Why it matters: single-function comparisons are weak evidence; multi-kernel assembly/IR comparison is needed for credible conclusions.

## 6) Space concentration in `libphobos2.a` points to concrete audit targets

- Evidence: `artifacts/not_done/libphobos_sections/report.md`
- Result:
  - top member: `zlib.o` (`615865` bytes)
  - top aggregate section: `__textcoal_nt` (`2081616` bytes)
- Why it matters: size optimization should start with top contributors, not broad untargeted cleanup.

## 7) Host compatibility dominates latest20 release timing on this machine

- Evidence: `artifacts/report.md`
- Result: latest20 track has crash-only outcomes on this host; compatible20 is required for stable timing comparisons.
- Why it matters: reporting must separate "latest availability reality" from "regression-quality timing dataset".
