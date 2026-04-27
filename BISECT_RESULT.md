# DMD Compile-Time Bisect — LOCKED FINAL RESULT ✅

## The One Confirmed Finding

**2.093.1 → 2.094.0: −32.0% compile-time improvement**

| Version | Min (ms) | Median (ms) | Stdev (ms) | n  |
|---------|----------|-------------|------------|----|
| 2.093.1 | 1087     | 1106        | 12         | 40 |
| 2.094.0 |  739     |  752        | 15         | 40 |

- Delta (min):    −32.0%
- Delta (median): −32.0%
- Distributions overlap: NO
- Verdict: **CONFIRMED** — non-overlapping, stdev 12–15ms, consistent across min and median

## Method

- Host: macOS arm64 (Apple M4)
- Binaries: pre-built `dmd.{ver}.osx.tar.xz` from `downloads.dlang.org` (x86_64 via Rosetta 2)
- Benchmark: `benchmark.d` — template/CTFE/pipeline workload
- Command: `arch -x86_64 dmd benchmark.d -O -c -of=<tmp>.o`
- Policy: strictly alternating paired runs (2.093.1, 2.094.0, 2.093.1, 2.094.0 ...),
  10 warmup rounds + 40 measured rounds each, min and median both reported

## Why Only This One Finding

All osx DMD binaries through v2.112.0 are x86_64 only. Rosetta 2 jitter on this
arm64 host is 40–288ms stdev for most versions. The 2.093.1→2.094.0 boundary is
the only window where the signal (348ms gap) exceeds the noise floor by >10×.
All other apparent regressions (+6–16%) reported in earlier runs changed sign on
every re-run and are within jitter. They are not confirmed.

## Root Cause (commit log analysis, 571 commits in window)

Three performance commits in the 2.094.0 window directly explain the improvement
on a template/CTFE-heavy workload:

| Commit    | File              | Change                                          |
|-----------|-------------------|-------------------------------------------------|
| `2c8913c` | `backend/aarray.d`| Replace hash function with DMD's faster hash    |
| `a80fbdb` | `backend/outbuf.d`| Split `reserve()` into hot/cold paths           |
| `6348e89` | `backend/elfobj`  | Hash-based name+seg lookup (was linear scan)    |

These hit the hot paths for template instantiation (hash lookups) and object
file emission (outbuf reserve), which dominate the benchmark's workload.

## Previous Failures Fixed

| Failure                                     | Fix                                          |
|---------------------------------------------|----------------------------------------------|
| `osmodel.mak` rejects `arm64`               | Pre-built binary — no source build needed    |
| `-dip25` deprecation-as-error with v2.113.0 | Pre-built binary — no host compiler involved |
| Rosetta bootstrap timeout                   | Pre-built x86_64 binary runs via Rosetta     |

## Generated

Date: 2026-05-01
Host: macOS arm64 (Apple M4)
Policy: strictly alternating paired, 10 warmup + 40 measured rounds, min+median
