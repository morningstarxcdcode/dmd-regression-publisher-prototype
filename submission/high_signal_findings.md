# High-Signal Findings (Evidence-First)

Generated: 2026-03-08

## 1) Switch scaling is strongly non-linear at higher case counts

- Evidence: `artifacts/upgrades/switch_scaling_v2/report.md`
- Result: `3000 -> 10000` cases shows `x6.338` compile-time multiplier, much steeper than lower ranges.
- Why it matters: regression publisher should include stress-shape benchmarks, not only small/medium synthetic inputs.

## 2) In-compiler parser prototype now has a real narrow-path implementation, but it is still slower

- Evidence:
  - `artifacts/upgrades/parser_thread_compare_narrow/comparison.csv`
  - `artifacts/upgrades/parser_thread_compare_narrow/threaded/parser_incompiler_parallel/speedup.csv`
- Result:
  - baseline and narrow-path candidate both completed successful runs at `1`, `2`, and `4` threads for `64` and `128` files.
  - narrow mode is still materially slower than coarse mode on this host, so parser performance remains partial.
- Why it matters: the project moved from surrogate-only evidence to a real single-process compiler prototype with a split parse/commit path, and now has concrete evidence for where the remaining cost lives.

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

## 8) Runtime-library kernels are now benchmarked directly

- Evidence:
  - `artifacts/upgrades/runtime_libs_smoke/gc_kernels/report.md`
  - `artifacts/upgrades/runtime_libs_smoke/aa_kernels/report.md`
  - `artifacts/upgrades/runtime_libs_smoke/float_to_string_kernels/report.md`
- Result:
  - GC, associative arrays, and float-to-string now have reproducible kernel benchmarks in the repo.
  - `dub` PGO is also implemented, but current local execution is blocked by DNS/network access to `github.com`.
- Why it matters: this closes most of the broader-gist implementation gap with concrete, rerunnable tasks instead of narrative-only intent.
