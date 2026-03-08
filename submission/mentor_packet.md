# Mentor Packet (Performance Regression Publisher Prototype)

## Prototype Summary
I built a dual-track DMD benchmarking prototype that measures release-history compile trends, phase attribution (`-ftime-trace`), and multiple Dennis 2026 prototype ideas. I also upgraded experiments for stronger evidence: multi-point switch scaling, multi-kernel C-vs-D assembly comparison, and an in-compiler parser prototype comparison.

## Strongest Evidence
- `latest20` track: validates compatibility reality against the most recent release window.
- `compatible20` track: gives stable, fully successful measurements for regression scoring.
- Trace phase breakdown: identifies which compiler phases dominate and should be tracked by a publisher.
- Switch scaling benchmark (v2): `100,300,1000,3000,10000` points show a stronger curve shape than the original 3-point run.
- C-vs-D assembly comparison (v2): expanded from one function to five kernels with per-kernel diffs.
- In-compiler parser prototype: baseline vs `ParserParallelPrototype` candidate comparison now exists with strict passing artifacts.

## Key Findings to Review
- Regressions are detected only when both percentage jump and CI separation are true.
- Compile-only object-size trend is tracked as a separate metric from compile time.
- Phase attribution confirms dominant cost buckets for metric selection.
- Switch compile-time behavior is non-uniform in v2: `1000 -> 3000` is `x1.850`, `3000 -> 10000` is `x6.338`.
- Assembly parity differs by kernel; one-function comparisons were not representative.
- Parser prototype now passes strict `1/2/4`-thread validation on this host, though the current correctness-first lock means speedup is still modest.

## Specific Questions for Dennis
1. Do the current labels clearly separate “latest release availability” from “regression-quality dataset”?
2. Is compile-only object size an acceptable metric under host linker constraints, or should it be downgraded in emphasis?
3. Is the granularity sweep (`1,10,50,100`) enough to justify a default trace granularity recommendation?
4. For switch scaling, do the v2 points (`100,300,1000,3000,10000`) look sufficient, or should I add very large points (e.g. `30000`)?
5. For C-vs-D assembly, is this kernel set useful, or should I pivot to IR-level comparisons instead of instruction-level diffs?
6. Which result is most useful to turn into an upstream issue/PR first: switch scaling, assembly parity, phobos section concentration, or parser-threading behavior?
7. For parser threading, is the current result more useful as a correctness prototype, or should I focus next on removing the serialization bottleneck and proving real speedup?

## Links to Artifacts
- `artifacts/report.md`
- `artifacts/latest20/*`
- `artifacts/compatible20/*`
- `artifacts/trace_phase_summary.csv`
- `artifacts/trace_granularity_sweep.csv`
- `artifacts/switch_scaling/report.md`
- `artifacts/switch_scaling/compile_time_vs_cases.png`
- `artifacts/upgrades/switch_scaling_v2/report.md`
- `artifacts/upgrades/switch_scaling_v2/compile_time_vs_cases.png`
- `artifacts/upgrades/not_done/c_vs_d_assembly/report.md`
- `artifacts/upgrades/parser_thread_compare_final/comparison.csv`
- `artifacts/upgrades/parser_thread_compare_final/threaded/parser_incompiler_parallel/results.csv`
- `submission/done_not_done_audit.md`
- `submission/high_signal_findings.md`
- `submission/community_activity.md`
