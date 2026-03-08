# Draft Forum / Discord Post

Topic:
`Which frontend globals should be isolated first for real parser parallelism in DMD?`

Post:
I built a root-module parser-threading prototype to move from a process-level surrogate to a real in-compiler benchmark. The narrow mode is now stable on my synthetic workload, but it is still materially slower than the coarse-lock baseline.

Evidence:
- `artifacts/upgrades/parser_thread_compare_narrow/comparison.csv`
- `artifacts/upgrades/parser_thread_compare_narrow/threaded/status.csv`

Specific question:
If I want to turn this into a real speedup instead of just a correctness prototype, which shared frontend components are the best first targets to isolate or make thread-local?

What I already changed:
- per-lexer scratch buffer instead of a shared global lexer buffer
- locked identifier interning for correctness
- split parse path into local parse + serialized global commit

I am looking for guidance on the next narrowing step, not a broad “parallelize everything” answer.
