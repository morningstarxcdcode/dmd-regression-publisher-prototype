# Release Spike Attribution Notes

## Benchmark and interpretation

- Benchmark: `benchmark.d`
- Compile command used for the release sweep: `dmd benchmark.d -O -c -of=<temp>.o`
- Metric: wall-clock compile time in milliseconds
- Policy: `2` warmups + `7` measured runs per release, median of measured runs
- Machine: `Souravs-MacBook-Air` / `Apple M4` / `Darwin 25.2.0 arm64`
- Important: the nightly build was used only for separate `-ftime-trace` phase analysis, not for the release sweep

## Current compatible-track spike candidate

From the current tracked dataset:

- `2.096.0 -> 2.096.1`: `+6.780%`
- confidence intervals are separated in `artifacts/compatible20/regression_table.csv`
- this is notable, but it does **not** pass the current hard `>= 10%` compile-regression threshold

This differs from the earlier emailed `+106%` observation. Treat the larger number as an earlier run that still needs reconciliation against the current rerun before it is presented as a confirmed release regression.

## Official changelog pages

- `2.096.0`: <https://dlang.org/changelog/2.096.0.html>
- `2.096.1`: <https://dlang.org/changelog/2.096.1.html>

The `2.096.1` changelog is the most relevant release page for the slowdown window because it is a patch release with a short, bounded compiler change set.

## 2.096.1 compiler-side items most likely to matter

Relevant compiler-side entries on the official `2.096.1` changelog page:

- Bugzilla 21229: constructor flow analysis does not understand unions
- Bugzilla 21687: confusing error message for CTFE pointer in static initializer
- Bugzilla 21798: `checkaction=context` creates temporary of type `void`
- Bugzilla 21806: overload selection ignores slice
- Bugzilla 21799: CTFE does not call base class destructor for `extern(D)` classes

For a template/CTFE-heavy benchmark, the strongest candidate buckets are:

- semantic / flow-analysis changes
- overload-resolution changes
- CTFE changes

## Actual release-window commits (`v2.096.0...v2.096.1`)

The GitHub release-window compare patch for `v2.096.0...v2.096.1` contains 21 commits. The compiler/CTFE-facing candidates are:

- `75fe50f497dceeaf49651259df8c52d3318f037e` — Fix issue 21687 - Confusing error message for CTFE
- `9a7e7a0871dfe37ef936f1f145a58d2a6e6d8aea` — Fix compilable/ctfe_math.d regression on hosts with ...
- `dfa37aa33795ad33d9d69a2c3de02ddb4e586158` — Fix 21799 - CTFE doesn't call base class destructor for ...
- `655278312e2851b74b1f88dd71c7ffdb47224c20` — Fix 21229 - Accept construction of a unions member as ...
- `5bba6357deac1ba8d5994ffeb5c526716e89a274` — Fix Issue 21806 - Overload selection ignores slice
- `03c30609389c5dce7e22ce39e8a176081e3e9c10` — Fix Issue 21845 - Make `in` take precedence in ...

These are the first commits to check if the slowdown remains reproducible in a source-built bisect.

## Practical conclusion

The current evidence is strong enough to say:

- the methodology should be made explicit in the plot/report
- `2.096.0 -> 2.096.1` is the right release window to investigate first
- the official changelog and actual release compare already narrow the search to a small compiler/CTFE-heavy commit set

The current evidence is **not** yet strong enough to claim a single first-bad commit from a true bisect. That remains a follow-up step.
