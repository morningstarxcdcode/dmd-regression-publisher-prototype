# Draft Issue

Target repo: `dlang/dmd`

Title:
`ParserParallelPrototype narrow path is stable on root-module workloads but remains slower than coarse parsing`

Body:
I prototyped a real in-compiler parser-threading path for root modules and compared it against the coarse correctness-first path on synthetic multi-module workloads.

Current evidence:
- `artifacts/upgrades/parser_thread_compare_narrow/comparison.csv`
- `artifacts/upgrades/parser_thread_compare_narrow/threaded/parser_incompiler_parallel/speedup.csv`
- `artifacts/upgrades/parser_thread_compare_narrow/threaded/status.csv`

Observed result on my current host:
- correctness is stable at `1,2,4` threads for `64` and `128` files
- narrow mode is still slower than coarse mode by roughly `2.4x`

Question:
Which frontend-global/shared data structures are the intended first targets for making root-module parsing genuinely parallel without introducing a broad serialization point?

Repro commands:
```bash
./build_parser_threaded_dmd.sh --host-dmd ./.locald/dmd-nightly/osx/bin/dmd --build-mode debug
./parser_threading_compare.sh \
  --python-bin ./.venv/bin/python \
  --baseline-dmd ./.locald/dmd-nightly/osx/bin/dmd \
  --threaded-dmd ./external/dmd/generated/osx/debug/64/dmd \
  --threads 1,2,4 \
  --repeats 2 \
  --file-counts 64,128 \
  --out-dir artifacts/upgrades/parser_thread_compare_narrow
```
