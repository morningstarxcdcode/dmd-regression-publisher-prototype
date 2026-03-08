# Draft PR

Suggested target repo: `dlang/dmd`

Title:
`Add a reproducible parser-threading benchmark harness and artifact comparison workflow`

Summary:
This draft PR would add a small benchmark harness for synthetic root-module parse workloads, plus a documented comparison workflow for baseline vs parser-thread prototype binaries.

Why this is worth submitting:
- it gives a reproducible way to discuss parser-threading work with numbers
- it separates correctness, coverage, and performance outcomes
- it keeps future parser-thread experiments from being one-off local scripts

Evidence backing the draft:
- `artifacts/upgrades/parser_thread_compare_narrow/comparison.csv`
- `artifacts/upgrades/parser_thread_compare_narrow/baseline/parser_incompiler_parallel/speedup.csv`
- `artifacts/upgrades/parser_thread_compare_narrow/threaded/parser_incompiler_parallel/speedup.csv`

Proposed PR shape:
- add a benchmark workload generator
- add a baseline-vs-candidate comparison script
- document expected outputs and acceptance checks

Reviewer question:
Would maintainers prefer this as a repo-local tool under `tools/` / `test/` or as a contributor-side script linked from documentation?
