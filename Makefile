.PHONY: bench-latest bench-compatible bench-both analyze-both trace switch-bench not-done not-done-perfetto runtime-libs dub-pgo broader-gist strict-perf-probe linux-gap-close build-parser-threaded-dmd parser-thread-compare dmdbench-build refresh-latest-snapshot bootstrap-external-cache verify-smoke verify-full verify-ci-local-view all clean

PYTHON := $(if $(wildcard .venv/bin/python),$(CURDIR)/.venv/bin/python,python3)
BASELINE_DMD ?= ./external/dmd/generated/osx/release/64/dmd
THREADED_DMD ?= ./external/dmd/generated/osx/debug/64/dmd
DMD_BENCH := $(if $(wildcard tools/dmdbench/bin/dmdbench),tools/dmdbench/bin/dmdbench,)
DUB := $(if $(wildcard $(CURDIR)/.locald/dmd-nightly/osx/bin/dub),$(CURDIR)/.locald/dmd-nightly/osx/bin/dub,dub)
DUB_HOME ?= $(CURDIR)/.tmp-dub-home

LATEST_SOURCE ?= snapshot
ARCHIVE_SOURCE ?= cache
LATEST_VERSIONS_FILE ?= ./versions_latest20.txt
COMPAT_VERSIONS_FILE ?= ./versions_compatible20.txt
RELEASE_CACHE_DIR ?= ./.cache/dmd-releases
LINUX_RELEASE_CACHE_DIR ?= ./.cache/dmd-releases-linux
BENCH_TRACK_OUT_DIR ?= artifacts
BENCH_RUNS ?= 7
BENCH_WARMUPS ?= 2
BENCH_TIMEOUT_SEC ?= 120
DUB_PGO_UPSTREAM_SOURCE ?= cached
DUB_PGO_UPSTREAM_PATH ?=
DUB_PGO_UPSTREAM_PATH_ARG := $(if $(DUB_PGO_UPSTREAM_PATH),--dub-upstream-path $(DUB_PGO_UPSTREAM_PATH),)

bench-latest:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" sweep --track latest20 --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)" --versions-file "$(COMPAT_VERSIONS_FILE)" --cache-dir "$(RELEASE_CACHE_DIR)" --track-out-dir "$(BENCH_TRACK_OUT_DIR)" --runs "$(BENCH_RUNS)" --warmups "$(BENCH_WARMUPS)" --timeout-sec "$(BENCH_TIMEOUT_SEC)"; \
	else \
		./bench_releases.sh --track latest20 --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)" --versions-file "$(COMPAT_VERSIONS_FILE)" --cache-dir "$(RELEASE_CACHE_DIR)" --track-out-dir "$(BENCH_TRACK_OUT_DIR)" --runs "$(BENCH_RUNS)" --warmups "$(BENCH_WARMUPS)" --timeout-sec "$(BENCH_TIMEOUT_SEC)"; \
	fi

bench-compatible:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" sweep --track compatible20 --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)" --versions-file "$(COMPAT_VERSIONS_FILE)" --cache-dir "$(RELEASE_CACHE_DIR)" --track-out-dir "$(BENCH_TRACK_OUT_DIR)" --runs "$(BENCH_RUNS)" --warmups "$(BENCH_WARMUPS)" --timeout-sec "$(BENCH_TIMEOUT_SEC)"; \
	else \
		./bench_releases.sh --track compatible20 --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)" --versions-file "$(COMPAT_VERSIONS_FILE)" --cache-dir "$(RELEASE_CACHE_DIR)" --track-out-dir "$(BENCH_TRACK_OUT_DIR)" --runs "$(BENCH_RUNS)" --warmups "$(BENCH_WARMUPS)" --timeout-sec "$(BENCH_TIMEOUT_SEC)"; \
	fi

bench-both:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" sweep --track both --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)" --versions-file "$(COMPAT_VERSIONS_FILE)" --cache-dir "$(RELEASE_CACHE_DIR)" --track-out-dir "$(BENCH_TRACK_OUT_DIR)" --runs "$(BENCH_RUNS)" --warmups "$(BENCH_WARMUPS)" --timeout-sec "$(BENCH_TIMEOUT_SEC)"; \
	else \
		./bench_releases.sh --track both --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)" --versions-file "$(COMPAT_VERSIONS_FILE)" --cache-dir "$(RELEASE_CACHE_DIR)" --track-out-dir "$(BENCH_TRACK_OUT_DIR)" --runs "$(BENCH_RUNS)" --warmups "$(BENCH_WARMUPS)" --timeout-sec "$(BENCH_TIMEOUT_SEC)"; \
	fi

refresh-latest-snapshot:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" sweep --track latest20 --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source refresh --resolve-latest-only; \
	else \
		./bench_releases.sh --track latest20 --latest-file "$(LATEST_VERSIONS_FILE)" --latest-source refresh --resolve-latest-only; \
	fi

bootstrap-external-cache:
	./bootstrap_external_cache.sh --track both --cache-dir "$(RELEASE_CACHE_DIR)" --latest-source "$(LATEST_SOURCE)"

analyze-both:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" analyze --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts; \
	else \
		"$(PYTHON)" ./analyze_results.py --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts --trace-summary artifacts/trace_phase_summary.csv --granularity-csv artifacts/trace_granularity_sweep.csv; \
	fi

trace:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" trace --dmd-bin ./.locald/dmd-nightly/osx/bin/dmd --granularity 1 --granularity-sweep 1,10,50,100; \
	else \
		./run_trace.sh --python-bin "$(PYTHON)" --dmd-bin ./.locald/dmd-nightly/osx/bin/dmd --granularity 1 --granularity-sweep 1,10,50,100; \
	fi

switch-bench:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" switch-scale --compiler ./.locald/dmd-nightly/osx/bin/dmd --case-counts 100,1000,10000 --runs 7 --warmups 2 --out-dir artifacts/switch_scaling; \
	else \
		"$(PYTHON)" ./switch_case_experiment.py --compiler ./.locald/dmd-nightly/osx/bin/dmd --case-counts 100,1000,10000 --runs 7 --warmups 2 --out-dir artifacts/switch_scaling; \
	fi

not-done:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done

not-done-perfetto:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done --tasks perfetto

runtime-libs:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done --phase runtime_libs

dub-pgo:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done --tasks dub_pgo --dub-upstream-source "$(DUB_PGO_UPSTREAM_SOURCE)" $(DUB_PGO_UPSTREAM_PATH_ARG)

broader-gist:
	$(PYTHON) ./not_done_experiments.py --out-dir artifacts/not_done --phase broader_gist

strict-perf-probe:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" perf-probe --out-dir artifacts/strict_perf_probe; \
	else \
		./strict_perf_probe.sh --out-dir artifacts/strict_perf_probe; \
	fi

linux-gap-close:
	@if [ -n "$(DMD_BENCH)" ]; then \
		"$(DMD_BENCH)" linux-gap-close --python-bin "$(PYTHON)" --release-cache-dir "$(LINUX_RELEASE_CACHE_DIR)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)"; \
	else \
		./linux_gap_close.sh --python-bin "$(PYTHON)" --release-cache-dir "$(LINUX_RELEASE_CACHE_DIR)" --latest-source "$(LATEST_SOURCE)" --archive-source "$(ARCHIVE_SOURCE)"; \
	fi

build-parser-threaded-dmd:
	./build_parser_threaded_dmd.sh --host-dmd ./.locald/dmd-nightly/osx/bin/dmd

parser-thread-compare:
	./parser_threading_compare.sh --python-bin "$(PYTHON)" --baseline-dmd "$(BASELINE_DMD)" --threaded-dmd "$(THREADED_DMD)" --file-counts 64,128,256

verify-smoke:
	bash DataAnalysisExpert/run_smoke_matrix.sh
	$(PYTHON) DataAnalysisExpert/generate_command_charts.py --summary DataAnalysisExpert/smoke_command_summary.csv --out-dir DataAnalysisExpert --prefix smoke

verify-full:
	bash DataAnalysisExpert/run_make_matrix.sh
	$(PYTHON) DataAnalysisExpert/generate_command_charts.py --summary DataAnalysisExpert/command_run_summary.csv --out-dir DataAnalysisExpert
	$(PYTHON) DataAnalysisExpert/generate_command_charts.py --summary DataAnalysisExpert/command_run_summary.csv --out-dir DataAnalysisExpert --prefix full

verify-ci-local-view: verify-full

all: bench-both analyze-both trace
	$(PYTHON) ./analyze_results.py --input-dir artifacts --tracks latest20,compatible20 --out-dir artifacts --trace-summary artifacts/trace_phase_summary.csv --granularity-csv artifacts/trace_granularity_sweep.csv

clean:
	rm -rf artifacts/latest20 artifacts/compatible20
	rm -rf artifacts/switch_scaling
	rm -f artifacts/results_raw.csv artifacts/results_summary.csv artifacts/regression_table.csv artifacts/report.md
	rm -f artifacts/compile_time_trend.png artifacts/artifact_size_trend.png
	rm -f artifacts/trace.json artifacts/trace_phase_summary.csv artifacts/trace_event_summary.csv artifacts/trace_phase_bar.png artifacts/trace_granularity_sweep.csv
dmdbench-build:
	@mkdir -p "$(DUB_HOME)"
	(cd tools/dmdbench && DUB_HOME="$(DUB_HOME)" $(DUB) build)
