# Linux Gap-Close Runbook

This runbook covers two Linux paths:

1. hosted validation on GitHub-hosted Linux
2. strict closure on a Linux host with usable `perf`

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

## Strict one-pass Linux closure

```bash
./linux_gap_close.sh \
  --python-bin ./.venv/bin/python \
  --gate-b-mode strict \
  --dmd-bin /path/to/dmd
```

Outputs:

- `artifacts/linux_gap_close/releases/report.md`
- `artifacts/linux_gap_close/not_done_linux/status.md`
- `artifacts/linux_gap_close/summary.md`

Hosted CI option:

- GitHub Actions workflow: `.github/workflows/linux-gap-close.yml`
- This is the hosted-validation workflow.
- It allows Gate B to become `SKIP` when GitHub-hosted Ubuntu lacks a usable kernel-matched `perf`.
- Produces uploaded artifact bundle `linux-hosted-validation-artifacts`

Strict CI option:

- GitHub Actions workflow: `.github/workflows/linux-gap-close-strict.yml`
- Intended for a self-hosted Linux runner with real `perf`
- This is the only workflow that should be used to claim full Linux `dmd -profile` vs `perf` closure

Strict path gives:

- latest20 + compatible20 timing on Linux archives
- `dmd_profile_compare` using Linux `perf` path
- in-compiler parser benchmark (`parser_incompiler_parallel`)
- PASS/FAIL gates in `summary.md` (script exits non-zero if a gate fails)

Hosted workflow gives:

- real Linux release timing (`latest20` + `compatible20`)
- real Linux parser prototype execution
- Gate B recorded as `SKIP` instead of fake `PASS` when hosted `perf` is unavailable

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
  - `artifacts/linux_gap_close/not_done_linux/profile/dmd_profile_compare/perf_report.txt` (if produced)
- Parser candidate-vs-baseline table:
  - `artifacts/parser_thread_compare/comparison.csv`
