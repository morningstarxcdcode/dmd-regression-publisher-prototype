# Evidence Packet

## Parser-threading prototype

- Comparison table:
  - `artifacts/upgrades/parser_thread_compare_narrow/comparison.csv`
- Baseline status:
  - `artifacts/upgrades/parser_thread_compare_narrow/baseline/status.csv`
- Threaded status:
  - `artifacts/upgrades/parser_thread_compare_narrow/threaded/status.csv`
- Threaded diagnostics:
  - `artifacts/upgrades/parser_thread_compare_narrow/threaded/parser_incompiler_parallel/diagnostics.csv`

Refresh command:
```bash
./parser_threading_compare.sh \
  --python-bin ./.venv/bin/python \
  --baseline-dmd ./.locald/dmd-nightly/osx/bin/dmd \
  --threaded-dmd ./external/dmd/generated/osx/debug/64/dmd \
  --threads 1,2,4 \
  --repeats 2 \
  --file-counts 64,128 \
  --out-dir artifacts/upgrades/parser_thread_compare_narrow
```

## Runtime-library kernels

- Aggregate report:
  - `artifacts/upgrades/runtime_libs_smoke/runtime_libs_report.md`
- GC kernels:
  - `artifacts/upgrades/runtime_libs_smoke/gc_kernels/report.md`
- Associative-array kernels:
  - `artifacts/upgrades/runtime_libs_smoke/aa_kernels/report.md`
- Float-to-string kernels:
  - `artifacts/upgrades/runtime_libs_smoke/float_to_string_kernels/report.md`

Refresh command:
```bash
./.venv/bin/python ./not_done_experiments.py \
  --out-dir artifacts/upgrades/runtime_libs_smoke \
  --tasks gc_kernels,aa_kernels,float_to_string_kernels \
  --runtime-runs 2 \
  --runtime-warmups 1
```

## dub PGO

- Status CSV:
  - `artifacts/upgrades/runtime_libs_smoke/status.csv`
- Current host limitation:
  - `dub_pgo` is implemented but blocked externally here because cloning `https://github.com/dlang/dub.git` fails without DNS/network access.

Refresh command:
```bash
./.venv/bin/python ./not_done_experiments.py \
  --out-dir artifacts/upgrades/runtime_libs_smoke \
  --tasks dub_pgo \
  --dub-pgo-runs 1 \
  --clone-timeout 20
```
