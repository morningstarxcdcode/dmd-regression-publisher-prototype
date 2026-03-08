# Reproducibility Manifest

Generated: 2026-03-08

## Environment Snapshot

- Python: `3.14.2`
- DMD: `v2.112.0`
- LDC: `1.42.0` (LLVM `21.1.8`)
- Clang: `17.0.0`
- Platform: `macOS-26.2-arm64-arm-64bit-Mach-O`

Reference manifests:

- `artifacts/not_done/manifest.json`
- `artifacts/upgrades/not_done/manifest.json`

## Canonical High-Rigor Run

```bash
./.venv/bin/python ./not_done_experiments.py \
  --out-dir artifacts/not_done \
  --phase all \
  --max-rigor \
  --ast-seeds 1,2,3 \
  --task-timeout 900 \
  --clone-timeout 1800 \
  --build-timeout 7200
```

Outputs:

- `artifacts/not_done/status.md`
- `artifacts/not_done/status.csv`
- `artifacts/not_done/manifest.json`

## Upgraded Switch Scaling Run

```bash
./.venv/bin/python ./switch_case_experiment.py \
  --compiler ./.locald/dmd-nightly/osx/bin/dmd \
  --case-counts 100,300,1000,3000,10000 \
  --runs 9 \
  --warmups 3 \
  --out-dir artifacts/upgrades/switch_scaling_v2
```

Outputs:

- `artifacts/upgrades/switch_scaling_v2/report.md`
- `artifacts/upgrades/switch_scaling_v2/results_summary.csv`
- `artifacts/upgrades/switch_scaling_v2/compile_time_vs_cases.png`

## Upgraded C-vs-D Multi-Kernel Assembly Run

```bash
./.venv/bin/python ./not_done_experiments.py \
  --out-dir artifacts/upgrades/not_done \
  --tasks c_vs_d_asm
```

Outputs:

- `artifacts/upgrades/not_done/c_vs_d_assembly/report.md`
- `artifacts/upgrades/not_done/c_vs_d_assembly/similarity.csv`
- `artifacts/upgrades/not_done/c_vs_d_assembly/*_instruction_diff.txt`

## In-Compiler Parser-Threading Prototype Run

```bash
# 1) Build threaded prototype compiler binary
./build_parser_threaded_dmd.sh --host-dmd ./.locald/dmd-nightly/osx/bin/dmd

# 2) Compare baseline vs threaded parser behavior
./parser_threading_compare.sh \
  --python-bin ./.venv/bin/python \
  --baseline-dmd ./external/dmd/generated/osx/release/64/dmd \
  --threaded-dmd ./external/dmd/generated/osx/debug/64/dmd \
  --threads 1,2,4 \
  --repeats 3 \
  --file-count 64 \
  --out-dir artifacts/upgrades/parser_thread_compare_final
```

Outputs:

- `artifacts/upgrades/parser_thread_compare_final/comparison.csv`
- `artifacts/upgrades/parser_thread_compare_final/baseline/parser_incompiler_parallel/results.csv`
- `artifacts/upgrades/parser_thread_compare_final/threaded/parser_incompiler_parallel/results.csv`

## Known Host-Limited Gaps

- Linux `perf` comparison is not reproducible on this macOS-only environment.
- `latest20` cross-version trend as successful compile timings is host-compatibility limited here.
