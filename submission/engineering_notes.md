# Engineering Notes

## Problem Framing
The project needs latest-release visibility and reliable regression signal at the same time. On this host those goals conflict if treated as a single dataset.

## Alternatives Explored
- Single latest20 dataset only:
  - Pro: literal alignment with idea text.
  - Con: compatibility failures can dominate and reduce statistical signal.
- Single compatible-only dataset:
  - Pro: clean regression analysis.
  - Con: weak alignment with “latest 20 releases” instruction.
- Dual-track dataset (selected):
  - Pro: preserves literal latest-release evidence and high-signal regression analysis.
  - Con: requires clearer reporting to avoid confusion.

## Data and Metric Decisions
- Warmups are excluded from scoring but retained in raw logs.
- Regression trigger uses threshold + CI separation to reduce false positives.
- `-c` compilation mode is used to isolate compiler behavior from linker/runtime mismatch.
- Artifact size is labeled as object size to avoid overclaiming “binary size.”
- Switch-scaling experiment uses generated source variants (`100/1000/10000` cases) with identical benchmark harness logic, changing only switch width.

## Remaining Risks
- Latest-release track can still fail if release binaries are incompatible with host/runtime.
- Trace granularity recommendations can vary with benchmark shape and machine load.
- Switch scaling curve can be sensitive to code-shape details (single giant function vs split dispatch); follow-up variants may be needed before broad claims.
