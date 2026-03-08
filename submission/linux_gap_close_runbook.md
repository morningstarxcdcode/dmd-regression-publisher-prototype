# Linux Gap-Close Runbook

This runbook closes the three remaining partial items:

1. `dmd -profile` vs Linux `perf`
2. latest20 cross-version timing on a compatible Linux host
3. in-compiler parser threading workflow (baseline vs candidate DMD binary)

## Prerequisites (Linux)

- `bash`, `python3`, `curl`, `tar`, `perf`
- Repo checkout at project root
- Python environment with required deps:

```bash
python3 -m venv .venv
./.venv/bin/pip install matplotlib
```

- D compiler binaries:
  - DMD for profile/parser experiments (`--dmd-bin`)

## One-pass Linux closure

```bash
./linux_gap_close.sh \
  --python-bin ./.venv/bin/python \
  --dmd-bin /path/to/dmd
```

Outputs:

- `artifacts/linux_gap_close/releases/report.md`
- `artifacts/linux_gap_close/not_done_linux/status.md`
- `artifacts/linux_gap_close/summary.md`

CI option:

- GitHub Actions workflow: `.github/workflows/linux-gap-close.yml`
- Produces uploaded artifact bundle `linux-gap-close-artifacts`

What this gives:

- latest20 + compatible20 timing on Linux archives
- `dmd_profile_compare` using Linux `perf` path
- in-compiler parser benchmark (`parser_incompiler_parallel`)
- PASS/FAIL gates in `summary.md` (script exits non-zero if a gate fails)

## Real parser-threading comparison workflow

Use this after you have a candidate DMD binary with in-compiler parser threading changes.

If you are using the prototype in this repo, build candidate binary first:

```bash
./build_parser_threaded_dmd.sh --host-dmd ./.locald/dmd-nightly/osx/bin/dmd
```

```bash
./parser_threading_compare.sh \
  --baseline-dmd /path/to/baseline/dmd \
  --threaded-dmd /path/to/threaded/dmd \
  --python-bin ./.venv/bin/python \
  --threads 1,2,4,8 \
  --repeats 5 \
  --file-count 96
```

Outputs:

- `artifacts/parser_thread_compare/baseline/parser_incompiler_parallel/speedup.csv`
- `artifacts/parser_thread_compare/threaded/parser_incompiler_parallel/speedup.csv`
- `artifacts/parser_thread_compare/comparison.csv`

## Suggested submission evidence links

- Linux release trend result:
  - `artifacts/linux_gap_close/releases/latest20/results_summary.csv`
- Linux `perf` comparison result:
  - `artifacts/linux_gap_close/not_done_linux/dmd_profile_compare/perf_report.txt` (if produced)
- Parser candidate-vs-baseline table:
  - `artifacts/parser_thread_compare/comparison.csv`
