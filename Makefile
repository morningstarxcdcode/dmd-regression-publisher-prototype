.PHONY: bench-latest bench-compatible bench-both analyze-both trace switch-bench not-done not-done-perfetto linux-gap-close build-parser-threaded-dmd parser-thread-compare all clean

PYTHON := $(if $(wildcard .venv/bin/python),$(CURDIR)/.venv/bin/python,python3)
BASELINE_DMD ?= ./external/dmd/generated/osx/release/64/dmd
THREADED_DMD ?= ./external/dmd/generated/osx/debug/64/dmd

bench-latest:
	./bench_releases.sh --track latest20

bench-compatible:
	./bench_releases.sh --track compatible20

bench-both:
	./bench_releases.sh --track both

analyze-both:
	$(PYTHON) ./analyze_results.py --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts --trace-summary artifacts/trace_phase_summary.csv --granularity-csv artifacts/trace_granularity_sweep.csv

trace:
	./run_trace.sh --python-bin "$(PYTHON)" --dmd-bin ./.locald/dmd-nightly/osx/bin/dmd --granularity 1 --granularity-sweep 1,10,50,100

switch-bench:
	$(PYTHON) ./switch_case_experiment.py --compiler ./.locald/dmd-nightly/osx/bin/dmd --case-counts 100,1000,10000 --runs 7 --warmups 2 --out-dir artifacts/switch_scaling

not-done:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done

not-done-perfetto:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done --attempt-perfetto-screenshot

linux-gap-close:
	./linux_gap_close.sh --python-bin "$(PYTHON)"

build-parser-threaded-dmd:
	./build_parser_threaded_dmd.sh --host-dmd ./.locald/dmd-nightly/osx/bin/dmd

parser-thread-compare:
	./parser_threading_compare.sh --python-bin "$(PYTHON)" --baseline-dmd "$(BASELINE_DMD)" --threaded-dmd "$(THREADED_DMD)"

all: bench-both analyze-both trace
	$(PYTHON) ./analyze_results.py --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts --trace-summary artifacts/trace_phase_summary.csv --granularity-csv artifacts/trace_granularity_sweep.csv

clean:
	rm -rf artifacts/latest20 artifacts/compatible20
	rm -rf artifacts/switch_scaling
	rm -f artifacts/results_raw.csv artifacts/results_summary.csv artifacts/regression_table.csv artifacts/report.md
	rm -f artifacts/compile_time_trend.png artifacts/artifact_size_trend.png
	rm -f artifacts/trace.json artifacts/trace_phase_summary.csv artifacts/trace_event_summary.csv artifacts/trace_phase_bar.png artifacts/trace_granularity_sweep.csv
