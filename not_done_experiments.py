#!/usr/bin/env python3
"""
Run Dennis gist "Not Done" experiments and emit reproducible status artifacts.
"""

from __future__ import annotations

import argparse
import csv
import difflib
import json
import math
import os
import platform
import random
import re
import shutil
import statistics
import subprocess
import sys
import textwrap
import time
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path


CURATED_PROJECTS = [
    "vibe-d/vibe.d",
    "dlang/dmd",
    "ldc-developers/ldc",
    "dlang/dub",
    "dlang-community/serve-d",
]

TOP10_SNAPSHOT_2026_03_07 = [
    "dlang/dmd",
    "ldc-developers/ldc",
    "dlang/phobos",
    "vibe-d/vibe.d",
    "dlang/dub",
    "dlang/druntime",
    "dlang-community/DCD",
    "dlang-community/D-Scanner",
    "dlang-community/dfmt",
    "dlang/dlang.org",
]

TASK_ORDER = [
    "perfetto",
    "zero_cost",
    "phobos_sections",
    "gc_kernels",
    "aa_kernels",
    "float_to_string_kernels",
    "dub_pgo",
    "non_zero_init_structs",
    "linker_strip",
    "ast_field_order",
    "parser_parallel",
    "parser_incompiler_parallel",
    "allocator_compare",
    "c_vs_d_asm",
    "dmd_profile_compare",
    "compiler_fuzz",
    "large_char_array",
]

PHASE_TASKS = {
    "quick": [
        "perfetto",
        "zero_cost",
        "phobos_sections",
        "gc_kernels",
        "aa_kernels",
        "float_to_string_kernels",
        "linker_strip",
        "c_vs_d_asm",
        "compiler_fuzz",
        "large_char_array",
    ],
    "analysis": [
        "non_zero_init_structs",
        "allocator_compare",
        "dmd_profile_compare",
    ],
    "invasive": [
        "ast_field_order",
        "parser_parallel",
        "parser_incompiler_parallel",
    ],
    "runtime_libs": [
        "gc_kernels",
        "aa_kernels",
        "float_to_string_kernels",
    ],
    "broader_gist": [
        "gc_kernels",
        "aa_kernels",
        "float_to_string_kernels",
        "dub_pgo",
    ],
}


def now_utc() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def run_cmd(
    cmd: list[str],
    *,
    cwd: Path | None = None,
    timeout: float | None = None,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    cp = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        env=env,
    )
    if check and cp.returncode != 0:
        raise RuntimeError(
            f"command failed ({cp.returncode}): {' '.join(cmd)}\n"
            f"stdout:\n{cp.stdout}\n"
            f"stderr:\n{cp.stderr}"
        )
    return cp


def task_result(task: str, status: str, **kwargs: object) -> dict[str, object]:
    row: dict[str, object] = {"task": task, "status": status}
    row.update(kwargs)
    return row


def median_abs_deviation(values: list[float]) -> float:
    if not values:
        return float("nan")
    med = statistics.median(values)
    return statistics.median(abs(v - med) for v in values)


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def write_csv_dynamic(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        write_csv(path, ["task", "status"], [])
        return
    keys = {"task", "status"}
    for row in rows:
        keys.update(row.keys())
    ordered = ["task", "status"] + sorted(k for k in keys if k not in {"task", "status"})
    normalized = [{k: row.get(k, "") for k in ordered} for row in rows]
    write_csv(path, ordered, normalized)


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def repo_root() -> Path:
    return Path(__file__).resolve().parent


def format_float(value: float | None, digits: int = 3) -> str:
    if value is None or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        return ""
    return f"{float(value):.{digits}f}"


def compile_d_source(
    compiler: str,
    source: Path,
    exe: Path,
    *,
    extra_flags: list[str] | None = None,
    timeout_sec: float = 240.0,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    cmd = [compiler, str(source), f"-of={exe}"]
    if extra_flags:
        cmd.extend(extra_flags)
    return run_cmd(cmd, cwd=cwd, check=False, timeout=timeout_sec, env=env)


def emit_markdown_table(headers: list[str], rows: list[list[object]]) -> list[str]:
    lines = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for row in rows:
        lines.append("| " + " | ".join(str(cell) for cell in row) + " |")
    return lines


def remove_tree(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path, ignore_errors=True)


def parse_objdump_symbols(disasm_text: str) -> tuple[list[tuple[int, str]], dict[str, int]]:
    starts: list[tuple[int, str]] = []
    inst_count: dict[str, int] = defaultdict(int)
    current_symbol: str | None = None

    for line in disasm_text.splitlines():
        sym = re.match(r"^\s*([0-9a-fA-F]+) <([^>]+)>:$", line)
        if sym:
            current_symbol = sym.group(2)
            starts.append((int(sym.group(1), 16), current_symbol))
            continue
        if current_symbol and re.match(r"^\s*[0-9a-fA-F]+:\s", line):
            inst_count[current_symbol] += 1

    starts.sort(key=lambda x: x[0])
    return starts, inst_count


def symbol_sizes_from_starts(starts: list[tuple[int, str]]) -> dict[str, int]:
    sizes: dict[str, int] = {}
    for i, (addr, symbol) in enumerate(starts):
        if i + 1 < len(starts):
            sizes[symbol] = max(0, starts[i + 1][0] - addr)
    return sizes


def run_zero_cost_experiment(
    out_dir: Path,
    ldc2: str,
    runs: int,
    warmups: int,
    iterations: int,
) -> dict[str, object]:
    task_dir = out_dir / "zero_cost_ldc"
    task_dir.mkdir(parents=True, exist_ok=True)

    source = task_dir / "zero_cost.d"
    exe = task_dir / "zero_cost"
    obj = task_dir / "zero_cost.o"
    disasm_path = task_dir / "zero_cost.objdump.txt"

    source.write_text(
        textwrap.dedent(
            """
            module zero_cost;

            import std.algorithm : filter, map, sum;
            import std.array : array;
            import std.conv : to;
            import std.range : iota;
            import std.stdio : stderr, writeln;

            enum DATA_LEN = 400_000;

            pragma(inline, false)
            extern(C) long proceduralSum(scope const(int)[] values) @safe nothrow @nogc
            {
                long acc = 0;
                foreach (v; values)
                {
                    if ((v & 1) == 0)
                    {
                        acc += cast(long) v * 3 + 1;
                    }
                }
                return acc;
            }

            pragma(inline, false)
            extern(C) long rangeSum(scope const(int)[] values) @safe nothrow @nogc
            {
                return values
                    .filter!(v => (v & 1) == 0)
                    .map!(v => cast(long) v * 3 + 1)
                    .sum;
            }

            int main(string[] args)
            {
                if (args.length != 3)
                {
                    stderr.writeln("usage: ./zero_cost <proc|range> <iterations>");
                    return 2;
                }

                string mode = args[1];
                int iters = args[2].to!int;
                long sink = 0;
                auto data = iota(0, DATA_LEN).array;

                foreach (_; 0 .. iters)
                {
                    if (mode == "proc")
                    {
                        sink ^= proceduralSum(data);
                    }
                    else if (mode == "range")
                    {
                        sink ^= rangeSum(data);
                    }
                    else
                    {
                        stderr.writeln("invalid mode: ", mode);
                        return 3;
                    }
                }

                writeln(sink);
                return 0;
            }
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    run_cmd([ldc2, str(source), "-O3", "-release", "-boundscheck=off", f"-of={exe}"])
    run_cmd([ldc2, str(source), "-O3", "-release", "-boundscheck=off", "-c", f"-of={obj}"])

    raw_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []

    for mode in ("proc", "range"):
        for _ in range(warmups):
            run_cmd([str(exe), mode, str(iterations)], timeout=180.0, check=True)

        samples_ms: list[float] = []
        for run_idx in range(1, runs + 1):
            t0 = time.perf_counter_ns()
            cp = run_cmd([str(exe), mode, str(iterations)], timeout=180.0, check=True)
            elapsed_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
            sink = cp.stdout.strip()
            samples_ms.append(elapsed_ms)
            raw_rows.append(
                {
                    "mode": mode,
                    "run_idx": run_idx,
                    "elapsed_ms": f"{elapsed_ms:.3f}",
                    "sink": sink,
                }
            )

        summary_rows.append(
            {
                "mode": mode,
                "runs": runs,
                "median_ms": f"{statistics.median(samples_ms):.3f}",
                "mean_ms": f"{statistics.mean(samples_ms):.3f}",
                "mad_ms": f"{median_abs_deviation(samples_ms):.3f}",
                "min_ms": f"{min(samples_ms):.3f}",
                "max_ms": f"{max(samples_ms):.3f}",
            }
        )

    write_csv(task_dir / "runtime_raw.csv", ["mode", "run_idx", "elapsed_ms", "sink"], raw_rows)
    write_csv(
        task_dir / "runtime_summary.csv",
        ["mode", "runs", "median_ms", "mean_ms", "mad_ms", "min_ms", "max_ms"],
        summary_rows,
    )

    disasm = run_cmd(["objdump", "-d", str(obj)], check=True).stdout
    disasm_path.write_text(disasm, encoding="utf-8")
    starts, inst_count = parse_objdump_symbols(disasm)
    size_map = symbol_sizes_from_starts(starts)

    proc_symbol = next((s for _, s in starts if "proceduralSum" in s), "")
    range_symbol = next((s for _, s in starts if "rangeSum" in s), "")

    asm_rows: list[dict[str, object]] = []
    for symbol in (proc_symbol, range_symbol):
        if not symbol:
            continue
        asm_rows.append(
            {
                "symbol": symbol,
                "size_bytes_estimate": size_map.get(symbol, 0),
                "instruction_count": inst_count.get(symbol, 0),
            }
        )

    write_csv(task_dir / "assembly_summary.csv", ["symbol", "size_bytes_estimate", "instruction_count"], asm_rows)

    proc_median = float(next(r["median_ms"] for r in summary_rows if r["mode"] == "proc"))
    range_median = float(next(r["median_ms"] for r in summary_rows if r["mode"] == "range"))
    slowdown = range_median / proc_median if proc_median > 0 else float("nan")

    return task_result(
        "std.range/std.algorithm vs foreach (ldc2 -O3)",
        "done",
        runtime_proc_median_ms=round(proc_median, 3),
        runtime_range_median_ms=round(range_median, 3),
        runtime_ratio_range_over_proc=round(slowdown, 3),
        proc_symbol=proc_symbol,
        range_symbol=range_symbol,
        proc_inst_count=inst_count.get(proc_symbol, 0),
        range_inst_count=inst_count.get(range_symbol, 0),
    )


def run_gc_kernel_experiment(
    out_dir: Path,
    ldc2: str,
    runs: int,
    warmups: int,
    timeout_sec: float,
) -> dict[str, object]:
    task_dir = out_dir / "gc_kernels"
    task_dir.mkdir(parents=True, exist_ok=True)

    source = task_dir / "gc_kernels.d"
    exe = task_dir / "gc_kernels"
    source.write_text(
        textwrap.dedent(
            """
            module gc_kernels;

            import core.memory : GC;
            import core.time : MonoTime;
            import std.conv : to;
            import std.stdio : stderr, writeln;

            int main(string[] args)
            {
                if (args.length != 2)
                {
                    stderr.writeln("usage: gc_kernels <small|mixed|large>");
                    return 2;
                }

                string mode = args[1];
                size_t sink = 0;
                size_t allocations = 0;

                switch (mode)
                {
                    case "small":
                        auto keep = new ubyte[][](256);
                        foreach (i; 0 .. 220_000)
                        {
                            auto buf = new ubyte[](64 + (i & 15));
                            buf[0] = cast(ubyte) i;
                            buf[$ - 1] = cast(ubyte) (i >> 1);
                            keep[i % keep.length] = buf;
                            sink += buf[0] + buf[$ - 1];
                            allocations++;
                        }
                        break;

                    case "mixed":
                        auto keep = new ubyte[][](512);
                        foreach (i; 0 .. 160_000)
                        {
                            auto buf = new ubyte[](32 + (i % 96));
                            buf[0] = cast(ubyte) (i * 13);
                            sink ^= buf[0];
                            keep[i % keep.length] = buf;
                            if ((i & 255) == 0)
                                sink += keep[(i / 2) % keep.length].length;
                            allocations++;
                        }
                        break;

                    case "large":
                        auto keep = new ubyte[][](96);
                        foreach (i; 0 .. 6_000)
                        {
                            auto buf = new ubyte[](64 * 1024 + (i % 8) * 4096);
                            buf[0] = cast(ubyte) i;
                            keep[i % keep.length] = buf;
                            sink += keep[i % keep.length][0];
                            allocations++;
                        }
                        break;

                    default:
                        stderr.writeln("invalid mode: ", mode);
                        return 3;
                }

                auto collectStart = MonoTime.currTime;
                GC.collect();
                auto collectNs = (MonoTime.currTime - collectStart).total!"nsecs";
                writeln(mode, ",", allocations, ",", collectNs, ",", sink);
                return 0;
            }
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    compile_cp = compile_d_source(
        ldc2,
        source,
        exe,
        extra_flags=["-O3", "-release", "-boundscheck=off"],
        timeout_sec=timeout_sec,
    )
    (task_dir / "compile_stdout.txt").write_text(compile_cp.stdout, encoding="utf-8")
    (task_dir / "compile_stderr.txt").write_text(compile_cp.stderr, encoding="utf-8")
    if compile_cp.returncode != 0:
        return task_result(
            "benchmark D GC kernels",
            "blocked",
            reason="failed to compile gc benchmark",
            stderr_tail=compile_cp.stderr.strip().splitlines()[-1] if compile_cp.stderr.strip() else "",
        )

    rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []
    modes = ["small", "mixed", "large"]
    for mode in modes:
        for _ in range(warmups):
            run_cmd([str(exe), mode], check=True, timeout=timeout_sec)

        wall_samples: list[float] = []
        collect_samples_ms: list[float] = []
        alloc_samples: list[int] = []
        for run_idx in range(1, runs + 1):
            t0 = time.perf_counter_ns()
            cp = run_cmd([str(exe), mode], check=True, timeout=timeout_sec)
            wall_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
            parts = cp.stdout.strip().split(",")
            if len(parts) != 4:
                raise RuntimeError(f"unexpected gc benchmark output: {cp.stdout!r}")
            _, allocations_text, collect_ns_text, sink_text = parts
            allocations = int(allocations_text)
            collect_ms = int(collect_ns_text) / 1_000_000.0
            alloc_samples.append(allocations)
            collect_samples_ms.append(collect_ms)
            wall_samples.append(wall_ms)
            rows.append(
                {
                    "mode": mode,
                    "run_idx": run_idx,
                    "allocations": allocations,
                    "collect_ms": f"{collect_ms:.3f}",
                    "wall_ms": f"{wall_ms:.3f}",
                    "sink": sink_text,
                }
            )

        summary_rows.append(
            {
                "mode": mode,
                "runs": runs,
                "median_wall_ms": format_float(statistics.median(wall_samples)),
                "mad_wall_ms": format_float(median_abs_deviation(wall_samples)),
                "median_collect_ms": format_float(statistics.median(collect_samples_ms)),
                "median_allocations": int(statistics.median(alloc_samples)),
            }
        )

    write_csv(
        task_dir / "results.csv",
        ["mode", "run_idx", "allocations", "collect_ms", "wall_ms", "sink"],
        rows,
    )
    write_csv(
        task_dir / "summary.csv",
        ["mode", "runs", "median_wall_ms", "mad_wall_ms", "median_collect_ms", "median_allocations"],
        summary_rows,
    )

    report_rows = [
        [
            row["mode"],
            row["median_allocations"],
            row["median_collect_ms"],
            row["median_wall_ms"],
        ]
        for row in summary_rows
    ]
    report_lines = [
        "# D runtime GC kernels",
        "",
        "Compiler flags: `-O3 -release -boundscheck=off`",
        "",
        "Kernels:",
        "- `small`: short-lived small allocations",
        "- `mixed`: mixed churn with a persistent live set",
        "- `large`: larger array churn to stress collection cost",
        "",
        *emit_markdown_table(
            ["Mode", "Median allocations", "Median collect ms", "Median wall ms"],
            report_rows,
        ),
    ]
    (task_dir / "report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    return task_result(
        "benchmark D GC kernels",
        "done",
        modes=",".join(modes),
        runs=runs,
        fastest_mode=min(summary_rows, key=lambda row: float(row["median_wall_ms"]))["mode"],
    )


def run_aa_kernel_experiment(
    out_dir: Path,
    ldc2: str,
    runs: int,
    warmups: int,
    timeout_sec: float,
) -> dict[str, object]:
    task_dir = out_dir / "aa_kernels"
    task_dir.mkdir(parents=True, exist_ok=True)

    source = task_dir / "aa_kernels.d"
    exe = task_dir / "aa_kernels"
    source.write_text(
        textwrap.dedent(
            """
            module aa_kernels;

            import std.conv : to;
            import std.format : format;
            import std.stdio : stderr, writeln;

            string makeKey(size_t i)
            {
                return format!"key_%08x"(cast(uint) (i * 2_654_435_761U));
            }

            int main(string[] args)
            {
                if (args.length != 4)
                {
                    stderr.writeln("usage: aa_kernels <int|string> <insert|hit_lookup|miss_lookup|iterate|delete_reinsert> <scale>");
                    return 2;
                }

                string keyType = args[1];
                string workload = args[2];
                size_t scale = args[3].to!size_t;
                ulong sink = 0;
                size_t ops = 0;

                if (keyType == "int")
                {
                    int[int] table;
                    foreach (i; 0 .. scale)
                        table[cast(int) i] = cast(int) (i * 7 + 3);

                    switch (workload)
                    {
                        case "insert":
                            table = int[int].init;
                            foreach (i; 0 .. scale)
                            {
                                table[cast(int) i] = cast(int) (i * 7 + 3);
                                sink += table[cast(int) i];
                                ops++;
                            }
                            break;

                        case "hit_lookup":
                            foreach (_; 0 .. 5)
                            foreach (i; 0 .. scale)
                            {
                                sink += cast(uint) table[cast(int) i];
                                ops++;
                            }
                            break;

                        case "miss_lookup":
                            foreach (_; 0 .. 5)
                            foreach (i; 0 .. scale)
                            {
                                sink += (cast(int) (i + scale) in table) is null ? 1 : 0;
                                ops++;
                            }
                            break;

                        case "iterate":
                            foreach (_; 0 .. 4)
                            foreach (k, v; table)
                            {
                                sink += cast(uint) (k ^ v);
                                ops++;
                            }
                            break;

                        case "delete_reinsert":
                            foreach (i; 0 .. scale)
                            {
                                table.remove(cast(int) i);
                                ops++;
                            }
                            foreach (i; 0 .. scale)
                            {
                                table[cast(int) i] = cast(int) (i * 11 + 5);
                                sink += cast(uint) table[cast(int) i];
                                ops++;
                            }
                            break;

                        default:
                            stderr.writeln("invalid workload: ", workload);
                            return 3;
                    }
                }
                else if (keyType == "string")
                {
                    string[string] table;
                    auto keys = new string[](scale);
                    foreach (i; 0 .. scale)
                    {
                        keys[i] = makeKey(i);
                        table[keys[i]] = keys[i];
                    }

                    switch (workload)
                    {
                        case "insert":
                            table = string[string].init;
                            foreach (i; 0 .. scale)
                            {
                                auto key = makeKey(i);
                                table[key] = key;
                                sink += table[key].length;
                                ops++;
                            }
                            break;

                        case "hit_lookup":
                            foreach (_; 0 .. 5)
                            foreach (key; keys)
                            {
                                sink += table[key].length;
                                ops++;
                            }
                            break;

                        case "miss_lookup":
                            foreach (_; 0 .. 5)
                            foreach (i; 0 .. scale)
                            {
                                auto key = makeKey(i + scale);
                                sink += (key in table) is null ? 1 : 0;
                                ops++;
                            }
                            break;

                        case "iterate":
                            foreach (_; 0 .. 4)
                            foreach (k, v; table)
                            {
                                sink += k.length + v.length;
                                ops++;
                            }
                            break;

                        case "delete_reinsert":
                            foreach (key; keys)
                            {
                                table.remove(key);
                                ops++;
                            }
                            foreach (key; keys)
                            {
                                table[key] = key;
                                sink += table[key].length;
                                ops++;
                            }
                            break;

                        default:
                            stderr.writeln("invalid workload: ", workload);
                            return 3;
                    }
                }
                else
                {
                    stderr.writeln("invalid keyType: ", keyType);
                    return 4;
                }

                writeln(keyType, ",", workload, ",", scale, ",", ops, ",", sink);
                return 0;
            }
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    compile_cp = compile_d_source(
        ldc2,
        source,
        exe,
        extra_flags=["-O3", "-release", "-boundscheck=off"],
        timeout_sec=timeout_sec,
    )
    (task_dir / "compile_stdout.txt").write_text(compile_cp.stdout, encoding="utf-8")
    (task_dir / "compile_stderr.txt").write_text(compile_cp.stderr, encoding="utf-8")
    if compile_cp.returncode != 0:
        return task_result(
            "benchmark D associative arrays",
            "blocked",
            reason="failed to compile aa benchmark",
            stderr_tail=compile_cp.stderr.strip().splitlines()[-1] if compile_cp.stderr.strip() else "",
        )

    raw_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []
    key_types = ["int", "string"]
    workloads = ["insert", "hit_lookup", "miss_lookup", "iterate", "delete_reinsert"]
    scales = [1_000, 10_000, 100_000]

    for key_type in key_types:
        for workload in workloads:
            for scale in scales:
                for _ in range(warmups):
                    run_cmd([str(exe), key_type, workload, str(scale)], check=True, timeout=timeout_sec)

                wall_samples: list[float] = []
                ns_per_op_samples: list[float] = []
                ops_samples: list[int] = []
                for run_idx in range(1, runs + 1):
                    t0 = time.perf_counter_ns()
                    cp = run_cmd([str(exe), key_type, workload, str(scale)], check=True, timeout=timeout_sec)
                    wall_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
                    parts = cp.stdout.strip().split(",")
                    if len(parts) != 5:
                        raise RuntimeError(f"unexpected aa benchmark output: {cp.stdout!r}")
                    _, _, _, ops_text, sink_text = parts
                    ops = int(ops_text)
                    ns_per_op = (wall_ms * 1_000_000.0 / ops) if ops > 0 else float("nan")
                    wall_samples.append(wall_ms)
                    ns_per_op_samples.append(ns_per_op)
                    ops_samples.append(ops)
                    raw_rows.append(
                        {
                            "key_type": key_type,
                            "workload": workload,
                            "scale": scale,
                            "run_idx": run_idx,
                            "ops": ops,
                            "wall_ms": format_float(wall_ms),
                            "ns_per_op": format_float(ns_per_op),
                            "sink": sink_text,
                        }
                    )

                summary_rows.append(
                    {
                        "key_type": key_type,
                        "workload": workload,
                        "scale": scale,
                        "runs": runs,
                        "median_ops": int(statistics.median(ops_samples)),
                        "median_wall_ms": format_float(statistics.median(wall_samples)),
                        "median_ns_per_op": format_float(statistics.median(ns_per_op_samples)),
                    }
                )

    write_csv(
        task_dir / "results.csv",
        ["key_type", "workload", "scale", "run_idx", "ops", "wall_ms", "ns_per_op", "sink"],
        raw_rows,
    )
    write_csv(
        task_dir / "summary.csv",
        ["key_type", "workload", "scale", "runs", "median_ops", "median_wall_ms", "median_ns_per_op"],
        summary_rows,
    )

    report_lines = [
        "# D associative-array kernels",
        "",
        "Compiler flags: `-O3 -release -boundscheck=off`",
        "",
    ]
    best_rows = [row for row in summary_rows if row["scale"] == 100_000]
    report_lines.extend(
        emit_markdown_table(
            ["Key type", "Workload", "Scale", "Median ns/op", "Median wall ms"],
            [
                [row["key_type"], row["workload"], row["scale"], row["median_ns_per_op"], row["median_wall_ms"]]
                for row in best_rows
            ],
        )
    )
    (task_dir / "report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    return task_result(
        "benchmark D associative arrays",
        "done",
        key_types=",".join(key_types),
        workloads=",".join(workloads),
        scales=",".join(str(scale) for scale in scales),
    )


def run_float_to_string_experiment(
    out_dir: Path,
    ldc2: str,
    runs: int,
    warmups: int,
    timeout_sec: float,
) -> dict[str, object]:
    task_dir = out_dir / "float_to_string_kernels"
    task_dir.mkdir(parents=True, exist_ok=True)

    source = task_dir / "float_to_string_kernels.d"
    exe = task_dir / "float_to_string_kernels"
    source.write_text(
        textwrap.dedent(
            """
            module float_to_string_kernels;

            import std.array : appender;
            import std.conv : to;
            import std.math : cos, sin;
            import std.stdio : stderr, writeln;

            double[] buildDataset(string dataset)
            {
                auto result = appender!(double[])();
                switch (dataset)
                {
                    case "normal":
                        foreach (i; 0 .. 4096)
                            result.put(cast(double) i * 0.25 + sin(cast(double) i / 31.0));
                        break;

                    case "scientific":
                        foreach (i; 0 .. 4096)
                        {
                            auto mag = cast(double) ((i % 40) - 20);
                            result.put((sin(cast(double) i / 9.0) + 1.5) * 10.0 ^^ mag);
                        }
                        break;

                    case "special":
                        double[] base = [
                            0.0,
                            -0.0,
                            double.min_normal / 2.0,
                            double.min_normal,
                            double.max / 2.0,
                            double.infinity,
                            -double.infinity,
                            double.nan,
                            sin(1.0),
                            cos(1.0),
                        ];
                        foreach (_; 0 .. 512)
                            foreach (v; base)
                                result.put(v);
                        break;

                    default:
                        assert(0, "unknown dataset");
                }
                return result.data;
            }

            int main(string[] args)
            {
                if (args.length != 3)
                {
                    stderr.writeln("usage: float_to_string_kernels <normal|scientific|special> <outer_loops>");
                    return 2;
                }

                string dataset = args[1];
                size_t outerLoops = args[2].to!size_t;
                auto values = buildDataset(dataset);
                ulong sink = 0;
                size_t ops = 0;
                size_t totalChars = 0;

                foreach (_; 0 .. outerLoops)
                {
                    foreach (v; values)
                    {
                        auto s = v.to!string;
                        totalChars += s.length;
                        sink = (sink * 1_099_511_628_211UL) ^ cast(ulong) s.length;
                        ops++;
                    }
                }

                writeln(dataset, ",", ops, ",", totalChars, ",", sink);
                return 0;
            }
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    compile_cp = compile_d_source(
        ldc2,
        source,
        exe,
        extra_flags=["-O3", "-release", "-boundscheck=off"],
        timeout_sec=timeout_sec,
    )
    (task_dir / "compile_stdout.txt").write_text(compile_cp.stdout, encoding="utf-8")
    (task_dir / "compile_stderr.txt").write_text(compile_cp.stderr, encoding="utf-8")
    if compile_cp.returncode != 0:
        return task_result(
            "benchmark D float-to-string conversion",
            "blocked",
            reason="failed to compile float benchmark",
            stderr_tail=compile_cp.stderr.strip().splitlines()[-1] if compile_cp.stderr.strip() else "",
        )

    raw_rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []
    datasets = {"normal": 128, "scientific": 128, "special": 256}

    for dataset, outer_loops in datasets.items():
        for _ in range(warmups):
            run_cmd([str(exe), dataset, str(outer_loops)], check=True, timeout=timeout_sec)

        wall_samples: list[float] = []
        conversions_per_sec: list[float] = []
        ops_samples: list[int] = []
        for run_idx in range(1, runs + 1):
            t0 = time.perf_counter_ns()
            cp = run_cmd([str(exe), dataset, str(outer_loops)], check=True, timeout=timeout_sec)
            wall_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
            parts = cp.stdout.strip().split(",")
            if len(parts) != 4:
                raise RuntimeError(f"unexpected float benchmark output: {cp.stdout!r}")
            _, ops_text, total_chars_text, sink_text = parts
            ops = int(ops_text)
            cps = ops / (wall_ms / 1000.0) if wall_ms > 0 else float("nan")
            wall_samples.append(wall_ms)
            conversions_per_sec.append(cps)
            ops_samples.append(ops)
            raw_rows.append(
                {
                    "dataset": dataset,
                    "run_idx": run_idx,
                    "ops": ops,
                    "total_chars": total_chars_text,
                    "wall_ms": format_float(wall_ms),
                    "conversions_per_sec": format_float(cps, 1),
                    "sink": sink_text,
                }
            )

        summary_rows.append(
            {
                "dataset": dataset,
                "runs": runs,
                "median_ops": int(statistics.median(ops_samples)),
                "median_wall_ms": format_float(statistics.median(wall_samples)),
                "median_conversions_per_sec": format_float(statistics.median(conversions_per_sec), 1),
            }
        )

    write_csv(
        task_dir / "results.csv",
        ["dataset", "run_idx", "ops", "total_chars", "wall_ms", "conversions_per_sec", "sink"],
        raw_rows,
    )
    write_csv(
        task_dir / "summary.csv",
        ["dataset", "runs", "median_ops", "median_wall_ms", "median_conversions_per_sec"],
        summary_rows,
    )
    report_lines = [
        "# D float-to-string kernels",
        "",
        "Compiler flags: `-O3 -release -boundscheck=off`",
        "",
        *emit_markdown_table(
            ["Dataset", "Median ops", "Median wall ms", "Median conversions/sec"],
            [
                [row["dataset"], row["median_ops"], row["median_wall_ms"], row["median_conversions_per_sec"]]
                for row in summary_rows
            ],
        ),
    ]
    (task_dir / "report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    return task_result(
        "benchmark D float-to-string conversion",
        "done",
        datasets=",".join(datasets.keys()),
        runs=runs,
    )


def run_phobos_section_analysis(out_dir: Path, archive_path: Path) -> dict[str, object]:
    task_dir = out_dir / "libphobos_sections"
    task_dir.mkdir(parents=True, exist_ok=True)

    out = run_cmd(["objdump", "-h", str(archive_path)], check=True).stdout
    (task_dir / "objdump_sections.txt").write_text(out, encoding="utf-8")

    current_member: str | None = None
    member_section_rows: list[dict[str, object]] = []
    member_totals: dict[str, int] = defaultdict(int)
    section_totals: dict[str, int] = defaultdict(int)

    member_re = re.compile(r"^\s*.+\(([^()]+)\):\s+file format")
    section_re = re.compile(r"^\s*\d+\s+(\S+)\s+([0-9a-fA-F]+)\s+[0-9a-fA-F]+\s+(\S+)")

    for line in out.splitlines():
        m = member_re.match(line)
        if m:
            current_member = m.group(1)
            continue

        s = section_re.match(line)
        if not s or current_member is None:
            continue
        section_name = s.group(1)
        size_bytes = int(s.group(2), 16)
        section_type = s.group(3)
        member_section_rows.append(
            {
                "member": current_member,
                "section": section_name,
                "size_bytes": size_bytes,
                "section_type": section_type,
            }
        )
        member_totals[current_member] += size_bytes
        section_totals[section_name] += size_bytes

    write_csv(
        task_dir / "member_section_sizes.csv",
        ["member", "section", "size_bytes", "section_type"],
        member_section_rows,
    )

    member_total_rows = [
        {"member": member, "total_bytes": total}
        for member, total in sorted(member_totals.items(), key=lambda x: x[1], reverse=True)
    ]
    section_total_rows = [
        {"section": section, "total_bytes": total}
        for section, total in sorted(section_totals.items(), key=lambda x: x[1], reverse=True)
    ]

    write_csv(task_dir / "member_totals.csv", ["member", "total_bytes"], member_total_rows)
    write_csv(task_dir / "section_totals.csv", ["section", "total_bytes"], section_total_rows)

    top_members = member_total_rows[:15]
    top_sections = section_total_rows[:15]
    md_lines = [
        "# libphobos2.a section analysis",
        "",
        f"Archive: `{archive_path}`",
        "",
        "## Top members by total section bytes",
        "",
        "| Member | Total bytes |",
        "|---|---:|",
    ]
    for row in top_members:
        md_lines.append(f"| {row['member']} | {row['total_bytes']} |")

    md_lines.extend(["", "## Top section names by aggregate bytes", "", "| Section | Total bytes |", "|---|---:|"])
    for row in top_sections:
        md_lines.append(f"| {row['section']} | {row['total_bytes']} |")

    (task_dir / "report.md").write_text("\n".join(md_lines) + "\n", encoding="utf-8")

    return task_result(
        "libphobos.a/phobos64.lib section size sort",
        "done",
        archive=str(archive_path),
        member_count=len(member_totals),
        top_member=top_members[0]["member"] if top_members else "",
        top_member_bytes=top_members[0]["total_bytes"] if top_members else 0,
    )


def build_linker_strip_payload(payload_path: Path, marker_token: str, payload_len: int) -> None:
    literal = marker_token + ("X" * payload_len) + "_PAYLOAD_END"
    escaped = literal.replace("\\", "\\\\").replace('"', '\\"')
    payload_code = (
        "module payload_unused;\n\n"
        f'enum string PAYLOAD_MARKER = "{escaped}";\n'
        "immutable(char)[] LARGE_TEXT = PAYLOAD_MARKER;\n"
        "__gshared ubyte[8_000_000] LARGE_BSS;\n\n"
        "extern(C) size_t payloadMarkerLength() @nogc nothrow\n"
        "{\n"
        "    return LARGE_TEXT.length + LARGE_BSS.length;\n"
        "}\n"
    )
    payload_path.write_text(payload_code, encoding="utf-8")


def run_linker_strip_experiment(out_dir: Path, ldc2: str) -> dict[str, object]:
    task_dir = out_dir / "linker_strip_unused_data"
    task_dir.mkdir(parents=True, exist_ok=True)

    marker_token = "UNUSED_PAYLOAD_MARKER_35A2A4D9"
    payload_path = task_dir / "payload_unused.d"
    build_linker_strip_payload(payload_path, marker_token=marker_token, payload_len=262_144)

    main_baseline = task_dir / "main_baseline.d"
    main_import_only = task_dir / "main_import_only.d"
    main_touch_payload = task_dir / "main_touch_payload.d"

    main_baseline.write_text(
        "module main_baseline;\nimport std.stdio : writeln;\nvoid main() { writeln(\"ok\"); }\n",
        encoding="utf-8",
    )
    main_import_only.write_text(
        "module main_import_only;\nimport payload_unused;\nimport std.stdio : writeln;\nvoid main() { writeln(\"ok\"); }\n",
        encoding="utf-8",
    )
    main_touch_payload.write_text(
        "module main_touch_payload;\nimport payload_unused : payloadMarkerLength;\nimport std.stdio : writeln;\nvoid main() { writeln(payloadMarkerLength()); }\n",
        encoding="utf-8",
    )

    scenarios = [
        ("baseline", main_baseline, False),
        ("baseline", main_baseline, True),
        ("import_only", main_import_only, False),
        ("import_only", main_import_only, True),
        ("touch_payload", main_touch_payload, False),
        ("touch_payload", main_touch_payload, True),
    ]

    rows: list[dict[str, object]] = []
    for scenario, main_file, dead_strip in scenarios:
        suffix = "deadstrip" if dead_strip else "nodeadstrip"
        exe = task_dir / f"{scenario}_{suffix}"
        cmd = [
            ldc2,
            str(main_file),
            "-O3",
            "-release",
            "-boundscheck=off",
            f"-of={exe}",
        ]
        if scenario != "baseline":
            cmd.append(str(payload_path))
        if dead_strip:
            cmd.append("-L=-Wl,-dead_strip")

        cp = run_cmd(cmd, check=False)
        marker_found = False
        run_stdout = ""
        run_stderr = ""

        if cp.returncode == 0 and exe.exists():
            strings_out = run_cmd(["strings", "-a", str(exe)], check=True).stdout
            marker_found = marker_token in strings_out
            run_cp = run_cmd([str(exe)], check=False)
            run_stdout = run_cp.stdout.strip().replace("\n", " ")[:160]
            run_stderr = run_cp.stderr.strip().replace("\n", " ")[:160]

        rows.append(
            {
                "scenario": scenario,
                "dead_strip": int(dead_strip),
                "compile_ok": int(cp.returncode == 0),
                "exe_size_bytes": exe.stat().st_size if exe.exists() else "",
                "marker_present_in_binary": int(marker_found),
                "compile_stderr_tail": cp.stderr.strip().splitlines()[-1][:200] if cp.stderr.strip() else "",
                "run_stdout": run_stdout,
                "run_stderr": run_stderr,
            }
        )

    write_csv(
        task_dir / "results.csv",
        [
            "scenario",
            "dead_strip",
            "compile_ok",
            "exe_size_bytes",
            "marker_present_in_binary",
            "compile_stderr_tail",
            "run_stdout",
            "run_stderr",
        ],
        rows,
    )

    baseline_sizes = [int(r["exe_size_bytes"]) for r in rows if r["scenario"] == "baseline" and r["compile_ok"] == 1]
    import_sizes = [int(r["exe_size_bytes"]) for r in rows if r["scenario"] == "import_only" and r["compile_ok"] == 1]

    return task_result(
        "unused strings/arrays linker stripping test",
        "done",
        rows=len(rows),
        baseline_exe_size_min=min(baseline_sizes) if baseline_sizes else 0,
        import_only_exe_size_min=min(import_sizes) if import_sizes else 0,
    )


def extract_asm_instructions(path: Path, label: str) -> list[str]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    start_idx = -1
    target = f"{label}:"
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == target or stripped.startswith(target + " "):
            start_idx = i + 1
            break
    if start_idx < 0:
        return []

    out: list[str] = []
    for line in lines[start_idx:]:
        stripped = line.strip()
        if not stripped:
            continue
        if re.match(r"^[A-Za-z_.$][A-Za-z0-9_.$]*:$", stripped):
            break
        if stripped.startswith("."):
            continue
        no_comment = stripped.split("//")[0].split(";")[0].strip()
        if not no_comment:
            continue
        out.append(re.sub(r"\s+", " ", no_comment))
    return out


def run_c_vs_d_asm_experiment(out_dir: Path, ldc2: str, clang: str) -> dict[str, object]:
    task_dir = out_dir / "c_vs_d_assembly"
    task_dir.mkdir(parents=True, exist_ok=True)
    kernels = [
        {
            "name": "weighted_sum",
            "function": "weighted_sum",
            "c_body": """
            long weighted_sum(const int* data, size_t n) {
                long acc = 0;
                for (size_t i = 0; i < n; ++i) {
                    int v = data[i];
                    if ((v & 1) == 0) {
                        acc += (long)v * 3 + 1;
                    }
                }
                return acc;
            }
            """,
            "d_body": """
            long weighted_sum(const(int)* data, size_t n) @nogc nothrow
            {
                long acc = 0;
                for (size_t i = 0; i < n; ++i)
                {
                    int v = data[i];
                    if ((v & 1) == 0)
                    {
                        acc += cast(long) v * 3 + 1;
                    }
                }
                return acc;
            }
            """,
        },
        {
            "name": "saxpy_like",
            "function": "saxpy_like",
            "c_body": """
            void saxpy_like(float* out, const float* x, const float* y, float a, size_t n) {
                for (size_t i = 0; i < n; ++i) {
                    out[i] = a * x[i] + y[i];
                }
            }
            """,
            "d_body": """
            void saxpy_like(float* dst, const(float)* x, const(float)* y, float a, size_t n) @nogc nothrow
            {
                for (size_t i = 0; i < n; ++i)
                {
                    dst[i] = a * x[i] + y[i];
                }
            }
            """,
        },
        {
            "name": "branch_mix",
            "function": "branch_mix",
            "c_body": """
            int branch_mix(const int* data, size_t n, int bias) {
                int acc = 0;
                for (size_t i = 0; i < n; ++i) {
                    int v = data[i] + bias;
                    if ((v & 3) == 0) acc += v;
                    else if ((v & 3) == 1) acc -= (v << 1);
                    else if ((v & 3) == 2) acc ^= v;
                    else acc += (v >> 1);
                }
                return acc;
            }
            """,
            "d_body": """
            int branch_mix(const(int)* data, size_t n, int bias) @nogc nothrow
            {
                int acc = 0;
                for (size_t i = 0; i < n; ++i)
                {
                    int v = data[i] + bias;
                    if ((v & 3) == 0) acc += v;
                    else if ((v & 3) == 1) acc -= (v << 1);
                    else if ((v & 3) == 2) acc ^= v;
                    else acc += (v >> 1);
                }
                return acc;
            }
            """,
        },
        {
            "name": "memxor",
            "function": "memxor",
            "c_body": """
            void memxor(unsigned char* dst, const unsigned char* a, const unsigned char* b, size_t n) {
                for (size_t i = 0; i < n; ++i) {
                    dst[i] = (unsigned char)(a[i] ^ b[i]);
                }
            }
            """,
            "d_body": """
            void memxor(ubyte* dst, const(ubyte)* a, const(ubyte)* b, size_t n) @nogc nothrow
            {
                for (size_t i = 0; i < n; ++i)
                {
                    dst[i] = cast(ubyte)(a[i] ^ b[i]);
                }
            }
            """,
        },
        {
            "name": "clamp_sum",
            "function": "clamp_sum",
            "c_body": """
            long clamp_sum(const int* data, size_t n, int lo, int hi) {
                long acc = 0;
                for (size_t i = 0; i < n; ++i) {
                    int v = data[i];
                    if (v < lo) v = lo;
                    if (v > hi) v = hi;
                    acc += v;
                }
                return acc;
            }
            """,
            "d_body": """
            long clamp_sum(const(int)* data, size_t n, int lo, int hi) @nogc nothrow
            {
                long acc = 0;
                for (size_t i = 0; i < n; ++i)
                {
                    int v = data[i];
                    if (v < lo) v = lo;
                    if (v > hi) v = hi;
                    acc += v;
                }
                return acc;
            }
            """,
        },
    ]

    summary_rows: list[dict[str, object]] = []
    similarity_rows: list[dict[str, object]] = []
    total_clang = 0
    total_ldc = 0
    ratios: list[float] = []

    for kernel in kernels:
        name = str(kernel["name"])
        func = str(kernel["function"])
        c_src = task_dir / f"{name}.c"
        d_src = task_dir / f"{name}.d"
        c_asm = task_dir / f"{name}_clang.s"
        d_asm = task_dir / f"{name}_ldc.s"
        diff_path = task_dir / f"{name}_instruction_diff.txt"

        c_src.write_text(
            textwrap.dedent(
                f"""
                #include <stddef.h>

                {kernel["c_body"]}
                """
            ).strip()
            + "\n",
            encoding="utf-8",
        )
        d_src.write_text(
            textwrap.dedent(
                f"""
                module {name}_d;

                extern(C):

                {kernel["d_body"]}
                """
            ).strip()
            + "\n",
            encoding="utf-8",
        )

        run_cmd([clang, "-O3", "-S", str(c_src), "-o", str(c_asm)])
        run_cmd([ldc2, "-betterC", "-O3", "-release", "-boundscheck=off", "-output-s", str(d_src), f"-of={d_asm}"])

        clang_insts = extract_asm_instructions(c_asm, f"_{func}")
        if not clang_insts:
            clang_insts = extract_asm_instructions(c_asm, func)

        ldc_insts = extract_asm_instructions(d_asm, f"_{func}")
        if not ldc_insts:
            ldc_insts = extract_asm_instructions(d_asm, func)

        matcher = difflib.SequenceMatcher(a=clang_insts, b=ldc_insts)
        ratio = matcher.ratio()
        ratios.append(ratio)
        total_clang += len(clang_insts)
        total_ldc += len(ldc_insts)

        diff = list(
            difflib.unified_diff(
                clang_insts,
                ldc_insts,
                fromfile=f"clang_{name}",
                tofile=f"ldc_{name}",
                lineterm="",
            )
        )
        diff_path.write_text("\n".join(diff) + ("\n" if diff else ""), encoding="utf-8")

        summary_rows.append(
            {
                "kernel": name,
                "toolchain": "clang",
                "instruction_count": len(clang_insts),
            }
        )
        summary_rows.append(
            {
                "kernel": name,
                "toolchain": "ldc2",
                "instruction_count": len(ldc_insts),
            }
        )
        similarity_rows.append(
            {
                "kernel": name,
                "instruction_similarity_ratio": f"{ratio:.4f}",
                "clang_instruction_count": len(clang_insts),
                "ldc_instruction_count": len(ldc_insts),
                "diff_file": diff_path.name,
            }
        )

    write_csv(task_dir / "summary.csv", ["kernel", "toolchain", "instruction_count"], summary_rows)
    write_csv(
        task_dir / "similarity.csv",
        ["kernel", "instruction_similarity_ratio", "clang_instruction_count", "ldc_instruction_count", "diff_file"],
        similarity_rows,
    )

    avg_ratio = statistics.mean(ratios) if ratios else 0.0
    min_ratio = min(ratios) if ratios else 0.0
    max_ratio = max(ratios) if ratios else 0.0
    report_lines = [
        "# C vs D assembly comparison",
        "",
        f"- Kernels compared: {len(kernels)}",
        f"- Total clang instruction count: {total_clang}",
        f"- Total ldc2 instruction count: {total_ldc}",
        f"- Similarity ratio (avg/min/max): {avg_ratio:.4f} / {min_ratio:.4f} / {max_ratio:.4f}",
        "",
        "| Kernel | Clang inst | LDC inst | Similarity |",
        "|---|---:|---:|---:|",
    ]
    for row in similarity_rows:
        report_lines.append(
            f"| {row['kernel']} | {row['clang_instruction_count']} | "
            f"{row['ldc_instruction_count']} | {row['instruction_similarity_ratio']} |"
        )
    (task_dir / "report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    godbolt_notes = [
        "# Compiler Explorer follow-up",
        "",
        "Local assembly diffs were produced for each kernel in this folder.",
        "Use https://d.godbolt.org/ with -O3 and compare clang vs ldc2 for:",
    ]
    for kernel in kernels:
        name = str(kernel["name"])
        godbolt_notes.append(f"- `{name}.c` vs `{name}.d`")
    (task_dir / "godbolt_notes.md").write_text("\n".join(godbolt_notes) + "\n", encoding="utf-8")

    return task_result(
        "clang vs ldc2 assembly comparison",
        "done",
        clang_instruction_count=total_clang,
        ldc_instruction_count=total_ldc,
        instruction_similarity_ratio=round(avg_ratio, 4),
        kernel_count=len(kernels),
        godbolt_ui_url="https://d.godbolt.org/",
    )


def run_large_char_array_experiment(out_dir: Path, ldc2: str) -> dict[str, object]:
    task_dir = out_dir / "large_char_array_4gb"
    task_dir.mkdir(parents=True, exist_ok=True)

    source = task_dir / "large_char_array_4gb.d"
    exe = task_dir / "large_char_array_4gb"

    source.write_text(
        textwrap.dedent(
            """
            module large_char_array_4gb;

            import core.stdc.errno : errno;
            import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_PRIVATE, PROT_READ, PROT_WRITE, mmap, munmap;
            import std.stdio : writeln;

            enum ulong FOUR_GB = 4_294_967_296UL;
            enum size_t LEN = cast(size_t) (FOUR_GB + 8_192UL);

            int main()
            {
                void* p = mmap(null, LEN, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
                if (p == MAP_FAILED)
                {
                    writeln("mmap_failed errno=", errno);
                    return 2;
                }
                scope(exit) munmap(p, LEN);

                auto arr = (cast(char*) p)[0 .. LEN];
                if (arr.length != LEN)
                {
                    writeln("length_mismatch len=", arr.length, " expected=", LEN);
                    return 3;
                }

                arr[0] = 'A';
                arr[cast(size_t) FOUR_GB] = 'B';
                arr[$ - 1] = 'Z';

                auto hi = arr[cast(size_t) FOUR_GB .. cast(size_t) FOUR_GB + 16];
                hi[] = 'Q';

                auto copyProbe = arr[cast(size_t) FOUR_GB - 16 .. cast(size_t) FOUR_GB + 16].dup;
                bool ok = arr[0] == 'A'
                    && arr[cast(size_t) FOUR_GB] == 'Q'
                    && arr[$ - 1] == 'Z'
                    && hi.length == 16
                    && copyProbe.length == 32;

                writeln("len=", arr.length, " hi_len=", hi.length, " copy_len=", copyProbe.length, " ok=", ok ? 1 : 0);
                return ok ? 0 : 4;
            }
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    run_cmd([ldc2, str(source), "-O3", "-release", "-boundscheck=off", f"-of={exe}"])
    cp = run_cmd([str(exe)], check=False, timeout=180.0)
    (task_dir / "run_stdout.txt").write_text(cp.stdout, encoding="utf-8")
    (task_dir / "run_stderr.txt").write_text(cp.stderr, encoding="utf-8")

    return task_result(
        "char[] > 4GB truncation probe",
        "done" if cp.returncode == 0 else "failed",
        return_code=cp.returncode,
        stdout=cp.stdout.strip().replace("\n", " "),
    )


FUZZ_TOKENS = [
    "if",
    "else",
    "for",
    "while",
    "template",
    "mixin",
    "alias",
    "struct",
    "class",
    "{",
    "}",
    ";",
    "import std.stdio;",
    "pragma(msg, \"fuzz\");",
]


def mutate_text(seed_text: str, rng: random.Random) -> str:
    text = seed_text
    edits = rng.randint(1, 4)
    for _ in range(edits):
        if not text:
            text = "int main(){return 0;}\n"
        op = rng.choice(["insert", "delete", "flip", "duplicate"])
        if op == "insert":
            at = rng.randrange(0, len(text) + 1)
            token = rng.choice(FUZZ_TOKENS)
            text = text[:at] + token + text[at:]
        elif op == "delete" and len(text) > 8:
            i = rng.randrange(0, len(text) - 1)
            j = min(len(text), i + rng.randint(1, min(80, len(text) - i)))
            text = text[:i] + text[j:]
        elif op == "flip":
            i = rng.randrange(0, len(text))
            repl = rng.choice("abcdefghijklmnopqrstuvwxyz{}[]();,+-/*")
            text = text[:i] + repl + text[i + 1 :]
        elif op == "duplicate" and len(text) > 16:
            i = rng.randrange(0, len(text) - 1)
            j = min(len(text), i + rng.randint(1, min(40, len(text) - i)))
            at = rng.randrange(0, len(text) + 1)
            text = text[:at] + text[i:j] + text[at:]
    return text


def run_fuzz_experiment(
    out_dir: Path,
    dmd: str,
    dmd_repo: Path,
    iterations: int,
    timeout_sec: float,
    seed: int,
) -> dict[str, object]:
    task_dir = out_dir / "compiler_fuzz"
    task_dir.mkdir(parents=True, exist_ok=True)
    generated_dir = task_dir / "generated"
    generated_dir.mkdir(parents=True, exist_ok=True)

    test_root = dmd_repo / "compiler" / "test"
    if not test_root.exists():
        return task_result(
            "fuzz compiler with dmd/compiler/test seeds",
            "blocked",
            reason=f"missing {test_root}",
        )

    candidates = []
    for sub in ("compilable", "runnable", "fail_compilation"):
        root = test_root / sub
        if not root.exists():
            continue
        for path in root.glob("*.d"):
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if 0 < size <= 24_000:
                candidates.append(path)

    if not candidates:
        return task_result(
            "fuzz compiler with dmd/compiler/test seeds",
            "blocked",
            reason="no candidate seed files discovered",
        )

    rng = random.Random(seed)
    obj_path = task_dir / "fuzz_tmp.o"
    rows: list[dict[str, object]] = []
    counts: Counter[str] = Counter()

    for idx in range(1, iterations + 1):
        seed_file = rng.choice(candidates)
        try:
            original = seed_file.read_text(encoding="utf-8", errors="ignore")
        except OSError:
            continue
        mutated = mutate_text(original, rng)
        sample_path = generated_dir / f"mut_{idx:05d}.d"
        sample_path.write_text(mutated, encoding="utf-8")

        cmd = [dmd, "-c", str(sample_path), f"-of={obj_path}", f"-I{test_root}", "-fmax-errors=1"]

        t0 = time.perf_counter_ns()
        outcome = "compile_error"
        rc = 0
        stderr_tail = ""
        try:
            cp = run_cmd(cmd, timeout=timeout_sec, check=False)
            rc = cp.returncode
            stderr = cp.stderr or ""
            low = stderr.lower()
            stderr_tail = (stderr.strip().splitlines()[-1] if stderr.strip() else "")[:240]
            if rc == 0:
                outcome = "ok"
            elif rc < 0 or "segmentation fault" in low or "bus error" in low:
                outcome = "crash"
            else:
                outcome = "compile_error"
        except subprocess.TimeoutExpired:
            outcome = "timeout"
            rc = 124
            stderr_tail = "timeout"

        elapsed_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
        counts[outcome] += 1
        rows.append(
            {
                "iteration": idx,
                "seed_file": str(seed_file.relative_to(dmd_repo)),
                "sample_file": str(sample_path.relative_to(task_dir)),
                "outcome": outcome,
                "return_code": rc,
                "elapsed_ms": f"{elapsed_ms:.3f}",
                "stderr_tail": stderr_tail,
            }
        )

        if outcome == "ok":
            sample_path.unlink(missing_ok=True)
        obj_path.unlink(missing_ok=True)

    write_csv(
        task_dir / "results.csv",
        ["iteration", "seed_file", "sample_file", "outcome", "return_code", "elapsed_ms", "stderr_tail"],
        rows,
    )

    return task_result(
        "fuzz compiler with dmd/compiler/test seeds",
        "done",
        iterations=iterations,
        ok=counts.get("ok", 0),
        compile_error=counts.get("compile_error", 0),
        timeout=counts.get("timeout", 0),
        crash=counts.get("crash", 0),
    )


def attempt_perfetto_screenshot(out_dir: Path, trace_file: Path, timeout_sec: float) -> dict[str, object]:
    task_dir = out_dir / "perfetto"
    task_dir.mkdir(parents=True, exist_ok=True)
    screenshot_path = task_dir / "perfetto_trace.png"
    js_path = task_dir / "capture_perfetto.js"

    if shutil.which("node") is None or shutil.which("npm") is None:
        return task_result("perfetto screenshot from .trace", "blocked", reason="node/npm not available")
    if not trace_file.exists():
        return task_result("perfetto screenshot from .trace", "blocked", reason=f"trace file missing: {trace_file}")

    js_path.write_text(
        textwrap.dedent(
            f"""
            const {{ chromium }} = require('playwright');

            async function main() {{
              const browser = await chromium.launch({{ headless: true }});
              const page = await browser.newPage({{ viewport: {{ width: 1720, height: 980 }} }});
              await page.goto('https://ui.perfetto.dev/', {{ waitUntil: 'domcontentloaded', timeout: 120000 }});
              await page.waitForTimeout(5000);

              const input = page.locator('input[type=file]');
              if (await input.count() > 0) {{
                await input.first().setInputFiles('{trace_file.resolve()}');
              }} else {{
                const openBtn = page.getByText('Open trace file').first();
                if (await openBtn.count() > 0) {{
                  const [chooser] = await Promise.all([
                    page.waitForEvent('filechooser', {{ timeout: 30000 }}),
                    openBtn.click(),
                  ]);
                  await chooser.setFiles('{trace_file.resolve()}');
                }}
              }}

              await page.waitForTimeout(15000);
              await page.screenshot({{ path: '{screenshot_path.resolve()}', fullPage: true }});
              await browser.close();
            }}

            main().catch((err) => {{
              console.error(err);
              process.exit(1);
            }});
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    init_cp = run_cmd(["npm", "init", "-y"], cwd=task_dir, check=False, timeout=60.0)
    if init_cp.returncode != 0:
        return task_result(
            "perfetto screenshot from .trace",
            "blocked",
            reason="failed to initialize npm project for playwright",
            stderr_tail=init_cp.stderr.strip().splitlines()[-1] if init_cp.stderr.strip() else "",
        )

    pkg_cp = run_cmd(
        ["npm", "install", "playwright@1.53.0"],
        cwd=task_dir,
        check=False,
        timeout=max(timeout_sec, 300.0),
    )
    if pkg_cp.returncode != 0:
        return task_result(
            "perfetto screenshot from .trace",
            "blocked",
            reason="failed to install playwright npm package",
            stderr_tail=pkg_cp.stderr.strip().splitlines()[-1] if pkg_cp.stderr.strip() else "",
        )

    install_cp = run_cmd(
        ["npx", "playwright", "install", "chromium"],
        cwd=task_dir,
        check=False,
        timeout=max(timeout_sec, 300.0),
    )
    if install_cp.returncode != 0:
        return task_result(
            "perfetto screenshot from .trace",
            "blocked",
            reason="failed to install playwright chromium browser",
            stderr_tail=install_cp.stderr.strip().splitlines()[-1] if install_cp.stderr.strip() else "",
        )

    capture_cp = run_cmd(
        ["node", str(js_path.resolve())],
        cwd=task_dir,
        check=False,
        timeout=max(timeout_sec, 240.0),
    )
    (task_dir / "capture_stdout.txt").write_text(capture_cp.stdout, encoding="utf-8")
    (task_dir / "capture_stderr.txt").write_text(capture_cp.stderr, encoding="utf-8")

    if capture_cp.returncode == 0 and screenshot_path.exists():
        return task_result(
            "perfetto screenshot from .trace",
            "done",
            screenshot=str(screenshot_path),
        )
    return task_result(
        "perfetto screenshot from .trace",
        "blocked",
        reason="playwright capture failed",
        stderr_tail=capture_cp.stderr.strip().splitlines()[-1] if capture_cp.stderr.strip() else "",
    )


def ensure_repo_clone(slug: str, base_dir: Path, timeout_sec: float) -> tuple[Path | None, str]:
    local = base_dir / slug.replace("/", "__")
    if local.exists() and (local / ".git").exists():
        return local, "existing"

    url = f"https://github.com/{slug}.git"
    cp = run_cmd(["git", "clone", "--depth", "1", url, str(local)], check=False, timeout=timeout_sec)
    if cp.returncode != 0:
        return None, (cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else "clone failed")
    return local, "cloned"


def resolve_git_ref(repo_dir: Path, ref: str, timeout_sec: float) -> tuple[str | None, str]:
    candidates = [ref]
    if not ref.startswith("origin/"):
        candidates.append(f"origin/{ref}")
    for candidate in candidates:
        cp = run_cmd(
            ["git", "-C", str(repo_dir), "rev-parse", "--verify", candidate],
            check=False,
            timeout=timeout_sec,
        )
        if cp.returncode == 0:
            return cp.stdout.strip(), ""
    fetch_cp = run_cmd(
        ["git", "-C", str(repo_dir), "fetch", "--depth", "1", "origin", ref],
        check=False,
        timeout=timeout_sec,
    )
    stderr_tail = fetch_cp.stderr.strip().splitlines()[-1] if fetch_cp.stderr.strip() else ""
    if fetch_cp.returncode == 0:
        cp = run_cmd(
            ["git", "-C", str(repo_dir), "rev-parse", "--verify", "FETCH_HEAD"],
            check=False,
            timeout=timeout_sec,
        )
        if cp.returncode == 0:
            return cp.stdout.strip(), ""
    return None, stderr_tail or f"unable to resolve ref {ref}"


def prepare_git_worktree(repo_dir: Path, worktree: Path, commit: str, timeout_sec: float) -> tuple[bool, str]:
    worktree = worktree.resolve()
    worktree.parent.mkdir(parents=True, exist_ok=True)
    run_cmd(["git", "-C", str(repo_dir), "worktree", "remove", "--force", str(worktree)], check=False, timeout=timeout_sec)
    remove_tree(worktree)
    cp = run_cmd(
        ["git", "-C", str(repo_dir), "worktree", "add", "--force", "--detach", str(worktree), commit],
        check=False,
        timeout=timeout_sec,
    )
    if cp.returncode != 0:
        return False, cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else "worktree add failed"
    if not worktree.exists():
        return False, f"worktree add reported success but path is missing: {worktree}"
    return True, ""


def find_named_executable(root: Path, name: str) -> Path | None:
    candidates: list[Path] = []
    for path in root.rglob(name):
        if ".git" in path.parts:
            continue
        if path.is_file() and os.access(path, os.X_OK):
            candidates.append(path)
    if not candidates:
        return None
    candidates.sort(key=lambda p: p.stat().st_mtime_ns, reverse=True)
    return candidates[0]


def reset_dub_workspace_outputs(workspace_root: Path) -> None:
    for rel in (".dub", "bin", ".cache", ".dub-home"):
        remove_tree(workspace_root / rel)


def run_timed_cmd(
    cmd: list[str],
    *,
    cwd: Path,
    timeout_sec: float,
    env: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], float]:
    t0 = time.perf_counter_ns()
    cp = run_cmd(cmd, cwd=cwd, check=False, timeout=timeout_sec, env=env)
    wall_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
    return cp, wall_ms


def run_dub_pgo_experiment(
    out_dir: Path,
    dub_bin: str,
    ldmd2_bin: str,
    ldc_profdata_bin: str,
    runs: int,
    timeout_sec: float,
    clone_timeout: float,
    workspace_root: Path,
    upstream_ref: str,
) -> dict[str, object]:
    task_dir = out_dir / "dub_pgo"
    task_dir.mkdir(parents=True, exist_ok=True)

    if not workspace_root.exists():
        return task_result(
            "benchmark dub with PGO",
            "blocked",
            reason=f"missing benchmark workspace: {workspace_root}",
        )

    if not Path(dub_bin).exists():
        return task_result("benchmark dub with PGO", "blocked", reason=f"dub not found: {dub_bin}")
    if not Path(ldmd2_bin).exists():
        return task_result("benchmark dub with PGO", "blocked", reason=f"ldmd2 not found: {ldmd2_bin}")
    if not Path(ldc_profdata_bin).exists():
        return task_result("benchmark dub with PGO", "blocked", reason=f"ldc-profdata not found: {ldc_profdata_bin}")

    cache_root = repo_root() / "artifacts" / "cache" / "dub_pgo"
    cache_root.mkdir(parents=True, exist_ok=True)

    upstream_repo, clone_state = ensure_repo_clone("dlang/dub", cache_root, clone_timeout)
    if upstream_repo is None:
        return task_result(
            "benchmark dub with PGO",
            "blocked_external",
            reason=f"failed to clone dlang/dub: {clone_state}",
        )

    resolved_commit, resolve_err = resolve_git_ref(upstream_repo, upstream_ref, clone_timeout)
    if resolved_commit is None:
        return task_result(
            "benchmark dub with PGO",
            "blocked_external",
            reason=f"failed to resolve dub ref {upstream_ref}: {resolve_err}",
        )

    worktrees_dir = task_dir / "worktrees"
    worktrees_dir.mkdir(parents=True, exist_ok=True)
    baseline_tree = (worktrees_dir / "baseline").resolve()
    instr_tree = (worktrees_dir / "instrumented").resolve()
    pgo_tree = (worktrees_dir / "pgo").resolve()
    for tree in (baseline_tree, instr_tree, pgo_tree):
        ok, err = prepare_git_worktree(upstream_repo, tree, resolved_commit, clone_timeout)
        if not ok:
            return task_result(
                "benchmark dub with PGO",
                "blocked",
                reason=f"failed to prepare worktree {tree.name}: {err}",
            )

    def build_dub_variant(tree: Path, variant: str, dflags: list[str]) -> tuple[Path | None, str]:
        if not tree.exists():
            return None, f"missing worktree path: {tree}"
        env = os.environ.copy()
        env["PATH"] = f"{Path(ldmd2_bin).parent}:{env.get('PATH', '')}"
        env["DFLAGS"] = " ".join(dflags)
        env["DUB_HOME"] = str(task_dir / "builder_home" / variant)
        remove_tree(Path(env["DUB_HOME"]))
        cp = run_cmd(
            [
                dub_bin,
                "build",
                "--root",
                str(tree),
                "--compiler",
                ldmd2_bin,
                "--build=release",
                "--force",
                "--skip-registry=all",
                "--cache=local",
            ],
            cwd=tree,
            check=False,
            timeout=timeout_sec,
            env=env,
        )
        (task_dir / f"build_{variant}_stdout.txt").write_text(cp.stdout, encoding="utf-8")
        (task_dir / f"build_{variant}_stderr.txt").write_text(cp.stderr, encoding="utf-8")
        if cp.returncode != 0:
            return None, cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else "dub build failed"
        binary = find_named_executable(tree, "dub")
        if binary is None:
            return None, "unable to locate built dub binary"
        return binary, ""

    baseline_binary, build_err = build_dub_variant(
        baseline_tree,
        "baseline",
        ["-O3", "-release", "-boundscheck=off"],
    )
    if baseline_binary is None:
        return task_result("benchmark dub with PGO", "blocked", reason=f"baseline build failed: {build_err}")

    profraw_dir = task_dir / "profiles" / "raw"
    profraw_dir.mkdir(parents=True, exist_ok=True)
    instrumented_binary, build_err = build_dub_variant(
        instr_tree,
        "instrumented",
        [
            "-O3",
            "-release",
            "-boundscheck=off",
            f"-fprofile-instr-generate={profraw_dir / 'dub-%p.profraw'}",
        ],
    )
    if instrumented_binary is None:
        return task_result("benchmark dub with PGO", "blocked", reason=f"instrumented build failed: {build_err}")

    workload_commands = [
        ("describe", ["describe"]),
        ("build", ["build", "--build=release", "--force"]),
        ("test", ["test", "--build=unittest", "--force"]),
    ]

    workload_home = task_dir / "workload_home"
    remove_tree(workload_home)
    common_env = os.environ.copy()
    common_env["PATH"] = f"{Path(ldmd2_bin).parent}:{common_env.get('PATH', '')}"
    common_env["DUB_HOME"] = str(workload_home)
    common_env["LLVM_PROFILE_FILE"] = str(profraw_dir / "dub-%p.profraw")

    training_rows: list[dict[str, object]] = []
    for label, args in workload_commands:
        reset_dub_workspace_outputs(workspace_root)
        cp, wall_ms = run_timed_cmd(
            [str(instrumented_binary), *args, "--root", str(workspace_root), "--skip-registry=all", "--compiler", ldmd2_bin],
            cwd=workspace_root,
            timeout_sec=timeout_sec,
            env=common_env,
        )
        (task_dir / f"train_{label}_stdout.txt").write_text(cp.stdout, encoding="utf-8")
        (task_dir / f"train_{label}_stderr.txt").write_text(cp.stderr, encoding="utf-8")
        training_rows.append(
            {
                "command": label,
                "returncode": cp.returncode,
                "wall_ms": format_float(wall_ms),
            }
        )
        if cp.returncode != 0:
            return task_result(
                "benchmark dub with PGO",
                "blocked",
                reason=f"instrumented training failed on {label}",
                resolved_commit=resolved_commit,
            )

    profraw_files = sorted(profraw_dir.glob("*.profraw"))
    if not profraw_files:
        return task_result(
            "benchmark dub with PGO",
            "blocked",
            reason="instrumented dub run produced no .profraw files",
            resolved_commit=resolved_commit,
        )

    profdata_path = task_dir / "profiles" / "dub.profdata"
    merge_cp = run_cmd(
        [ldc_profdata_bin, "merge", "-output", str(profdata_path), *(str(path) for path in profraw_files)],
        check=False,
        timeout=timeout_sec,
    )
    (task_dir / "profdata_merge_stdout.txt").write_text(merge_cp.stdout, encoding="utf-8")
    (task_dir / "profdata_merge_stderr.txt").write_text(merge_cp.stderr, encoding="utf-8")
    if merge_cp.returncode != 0 or not profdata_path.exists():
        return task_result(
            "benchmark dub with PGO",
            "blocked",
            reason="failed to merge LLVM profile data",
            resolved_commit=resolved_commit,
        )

    pgo_binary, build_err = build_dub_variant(
        pgo_tree,
        "pgo",
        [
            "-O3",
            "-release",
            "-boundscheck=off",
            f"-fprofile-instr-use={profdata_path}",
        ],
    )
    if pgo_binary is None:
        return task_result("benchmark dub with PGO", "blocked", reason=f"PGO build failed: {build_err}")

    rows: list[dict[str, object]] = []
    summary_rows: list[dict[str, object]] = []
    variants = [("baseline", baseline_binary), ("pgo", pgo_binary)]
    for label, args in workload_commands:
        for variant, binary in variants:
            samples: list[float] = []
            for run_idx in range(1, runs + 1):
                reset_dub_workspace_outputs(workspace_root)
                cp, wall_ms = run_timed_cmd(
                    [str(binary), *args, "--root", str(workspace_root), "--skip-registry=all", "--compiler", ldmd2_bin],
                    cwd=workspace_root,
                    timeout_sec=timeout_sec,
                    env=common_env,
                )
                rows.append(
                    {
                        "variant": variant,
                        "command": label,
                        "run_idx": run_idx,
                        "wall_ms": format_float(wall_ms),
                        "returncode": cp.returncode,
                    }
                )
                if cp.returncode != 0:
                    return task_result(
                        "benchmark dub with PGO",
                        "failed",
                        reason=f"{variant} dub failed on {label}",
                        resolved_commit=resolved_commit,
                    )
                samples.append(wall_ms)

            summary_rows.append(
                {
                    "variant": variant,
                    "command": label,
                    "runs": runs,
                    "median_wall_ms": format_float(statistics.median(samples)),
                    "binary_size_bytes": binary.stat().st_size,
                }
            )

    write_csv(
        task_dir / "training.csv",
        ["command", "returncode", "wall_ms"],
        training_rows,
    )
    write_csv(
        task_dir / "results.csv",
        ["variant", "command", "run_idx", "wall_ms", "returncode"],
        rows,
    )
    write_csv(
        task_dir / "summary.csv",
        ["variant", "command", "runs", "median_wall_ms", "binary_size_bytes"],
        summary_rows,
    )

    comparison_rows: list[dict[str, object]] = []
    for command in [label for label, _ in workload_commands]:
        base = next(row for row in summary_rows if row["variant"] == "baseline" and row["command"] == command)
        pgo = next(row for row in summary_rows if row["variant"] == "pgo" and row["command"] == command)
        base_ms = float(base["median_wall_ms"])
        pgo_ms = float(pgo["median_wall_ms"])
        improvement = ((base_ms - pgo_ms) / base_ms * 100.0) if base_ms > 0 else float("nan")
        comparison_rows.append(
            {
                "command": command,
                "baseline_median_ms": format_float(base_ms),
                "pgo_median_ms": format_float(pgo_ms),
                "improvement_pct": format_float(improvement),
            }
        )
    write_csv(
        task_dir / "comparison.csv",
        ["command", "baseline_median_ms", "pgo_median_ms", "improvement_pct"],
        comparison_rows,
    )

    report_lines = [
        "# dub PGO benchmark",
        "",
        f"Upstream ref request: `{upstream_ref}`",
        f"Resolved commit: `{resolved_commit}`",
        f"Clone state: `{clone_state}`",
        f"Profile files: `{len(profraw_files)}` raw, merged to `{profdata_path.name}`",
        "",
        "## Runtime comparison",
        "",
        *emit_markdown_table(
            ["Command", "Baseline median ms", "PGO median ms", "Improvement %"],
            [
                [row["command"], row["baseline_median_ms"], row["pgo_median_ms"], row["improvement_pct"]]
                for row in comparison_rows
            ],
        ),
        "",
        "## Binary sizes",
        "",
        *emit_markdown_table(
            ["Variant", "Command", "Binary size bytes"],
            [
                [row["variant"], row["command"], row["binary_size_bytes"]]
                for row in summary_rows
            ],
        ),
    ]
    (task_dir / "report.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")

    best_gain = max((float(row["improvement_pct"]) for row in comparison_rows), default=float("nan"))
    return task_result(
        "benchmark dub with PGO",
        "done",
        resolved_commit=resolved_commit,
        best_improvement_pct=format_float(best_gain),
        profile_raw_files=len(profraw_files),
    )


def discover_project_source_roots(project_dir: Path) -> list[Path]:
    candidates = [
        project_dir / "source",
        project_dir / "src",
        project_dir / "compiler" / "src",
        project_dir / "druntime" / "src",
        project_dir / "std",
    ]
    roots = [p for p in candidates if p.exists() and p.is_dir()]
    if not roots:
        roots = [project_dir]
    return roots


def parse_struct_names_from_file(path: Path) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return []
    names = re.findall(r"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\b", text)
    out: list[str] = []
    for name in names:
        if name not in out:
            out.append(name)
    return out


def module_name_from_path(root: Path, file_path: Path) -> str:
    rel = file_path.relative_to(root)
    return ".".join(rel.with_suffix("").parts)


def probe_struct_is_zero_init(
    dmd: str,
    work_dir: Path,
    include_dirs: list[Path],
    module_name: str,
    struct_name: str,
    size_threshold: int,
    timeout_sec: float,
) -> tuple[bool, bool, int | None, str]:
    probe = work_dir / "probe_struct_trait.d"
    obj = work_dir / "probe_struct_trait.o"
    source = textwrap.dedent(
        f"""
        module probe_struct_trait;

        import {module_name} : {struct_name};
        import std.conv : to;

        enum bool __isNZ = !__traits(isZeroInit, {struct_name});
        enum size_t __sz = {struct_name}.sizeof;
        pragma(msg, "__SIZE__ " ~ __sz.to!string);
        static if (__isNZ && __sz >= {size_threshold})
            pragma(msg, "__HIT__ {module_name}.{struct_name} " ~ __sz.to!string);

        void main() {{}}
        """
    ).strip() + "\n"
    probe.write_text(source, encoding="utf-8")

    cmd = [dmd, str(probe), "-c", f"-of={obj}", "-o-"]
    for inc in include_dirs:
        cmd.append(f"-I{inc}")

    cp = run_cmd(cmd, cwd=work_dir, timeout=timeout_sec, check=False)
    output = (cp.stdout or "") + "\n" + (cp.stderr or "")

    size_match = re.search(r"__SIZE__\s+(\d+)", output)
    hit_match = re.search(r"__HIT__\s+\S+\s+(\d+)", output)
    size_val = int(size_match.group(1)) if size_match else None
    is_hit = hit_match is not None
    stderr_tail = cp.stderr.strip().splitlines()[-1] if cp.stderr.strip() else ""
    return cp.returncode == 0, is_hit, size_val, stderr_tail[:240]


def run_non_zero_init_struct_scan(
    out_dir: Path,
    dmd: str,
    project_set: str,
    max_candidates_per_project: int,
    size_threshold: int,
    clone_timeout: float,
    probe_timeout: float,
) -> dict[str, object]:
    task_dir = out_dir / "large_non_zero_init_structs"
    task_dir.mkdir(parents=True, exist_ok=True)

    repo_root = task_dir / "repos"
    repo_root.mkdir(parents=True, exist_ok=True)
    work_dir = task_dir / "probe_work"
    work_dir.mkdir(parents=True, exist_ok=True)

    if project_set == "curated5":
        slugs = CURATED_PROJECTS
    else:
        slugs = list(dict.fromkeys(CURATED_PROJECTS + TOP10_SNAPSHOT_2026_03_07))

    rows: list[dict[str, object]] = []
    hits: list[dict[str, object]] = []
    projects_scanned = 0

    for slug in slugs:
        local_repo, state = ensure_repo_clone(slug, repo_root, clone_timeout)
        if local_repo is None:
            rows.append(
                {
                    "project": slug,
                    "module": "",
                    "struct": "",
                    "compile_ok": 0,
                    "is_hit": 0,
                    "sizeof": "",
                    "error": state,
                }
            )
            continue

        source_roots = discover_project_source_roots(local_repo)
        candidates: list[tuple[str, str, list[Path]]] = []
        seen_pairs: set[tuple[str, str]] = set()

        for root in source_roots:
            d_files = sorted(root.rglob("*.d"))
            for d_file in d_files:
                if d_file.name.startswith("."):
                    continue
                if d_file.stat().st_size > 300_000:
                    continue
                mod = module_name_from_path(root, d_file)
                structs = parse_struct_names_from_file(d_file)
                if not structs:
                    continue
                include_dirs = [root, local_repo]
                for struct_name in structs:
                    key = (mod, struct_name)
                    if key in seen_pairs:
                        continue
                    seen_pairs.add(key)
                    candidates.append((mod, struct_name, include_dirs))
                if len(candidates) >= max_candidates_per_project:
                    break
            if len(candidates) >= max_candidates_per_project:
                break

        if not candidates:
            rows.append(
                {
                    "project": slug,
                    "module": "",
                    "struct": "",
                    "compile_ok": 0,
                    "is_hit": 0,
                    "sizeof": "",
                    "error": "no struct candidates found",
                }
            )
            continue

        projects_scanned += 1
        for mod, struct_name, include_dirs in candidates:
            compile_ok, is_hit, size_val, err = probe_struct_is_zero_init(
                dmd=dmd,
                work_dir=work_dir,
                include_dirs=include_dirs,
                module_name=mod,
                struct_name=struct_name,
                size_threshold=size_threshold,
                timeout_sec=probe_timeout,
            )
            row = {
                "project": slug,
                "module": mod,
                "struct": struct_name,
                "compile_ok": int(compile_ok),
                "is_hit": int(is_hit),
                "sizeof": size_val if size_val is not None else "",
                "error": "" if compile_ok else err,
            }
            rows.append(row)
            if is_hit:
                hits.append(row)

    write_csv(
        task_dir / "scan_results.csv",
        ["project", "module", "struct", "compile_ok", "is_hit", "sizeof", "error"],
        rows,
    )
    write_csv(
        task_dir / "hits.csv",
        ["project", "module", "struct", "compile_ok", "is_hit", "sizeof", "error"],
        hits,
    )

    status = "done" if projects_scanned > 0 else "blocked"
    return task_result(
        "find large non-zero-init structs in popular projects",
        status,
        projects_scanned=projects_scanned,
        probes=len(rows),
        hits=len(hits),
        size_threshold=size_threshold,
        project_set=project_set,
    )


def generate_parser_workload(task_dir: Path, file_count: int) -> list[Path]:
    src_dir = task_dir / "workload"
    src_dir.mkdir(parents=True, exist_ok=True)
    files: list[Path] = []
    for i in range(file_count):
        path = src_dir / f"mod_{i:03d}.d"
        src = textwrap.dedent(
            f"""
            module mod_{i:03d};

            enum N = 500;

            long calc_{i}()
            {{
                long acc = 0;
                foreach (v; 0 .. N)
                {{
                    if ((v & 3) == 0)
                        acc += v * 7 + 3;
                    else
                        acc -= v * 5 - 11;
                }}
                static foreach (k; 0 .. 8)
                    acc += (k + 1) * N;
                return acc;
            }}
            """
        ).strip() + "\n"
        path.write_text(src, encoding="utf-8")
        files.append(path)
    return files


def classify_compile_outcome(cp: subprocess.CompletedProcess[str]) -> str:
    if cp.returncode == 0:
        return "ok"
    stderr_low = (cp.stderr or "").lower()
    if (
        cp.returncode < 0
        or "segmentation fault" in stderr_low
        or "bus error" in stderr_low
        or "illegal instruction" in stderr_low
    ):
        return "crash"
    return "compile_error"


def compile_one_parse_probe(
    dmd: str,
    src: Path,
    timeout_sec: float,
    include_paths: list[Path] | None = None,
) -> tuple[str, float]:
    t0 = time.perf_counter_ns()
    cmd = [dmd, str(src), "-c", "-o-"]
    if include_paths:
        for p in include_paths:
            if p.exists():
                cmd.append(f"-I={p}")
    cp = run_cmd(cmd, check=False, timeout=timeout_sec)
    ms = (time.perf_counter_ns() - t0) / 1_000_000.0
    return classify_compile_outcome(cp), ms


def run_parallel_parser_experiment(
    out_dir: Path,
    dmd: str,
    file_count: int,
    thread_values: list[int],
    repeats: int,
    timeout_sec: float,
) -> dict[str, object]:
    task_dir = out_dir / "lexer_parser_parallel"
    task_dir.mkdir(parents=True, exist_ok=True)

    files = generate_parser_workload(task_dir, file_count=file_count)
    include_paths = resolve_d_import_paths(dmd)

    rows: list[dict[str, object]] = []
    summary_by_jobs: dict[int, list[float]] = defaultdict(list)
    race_flags = 0

    for jobs in thread_values:
        for rep in range(1, repeats + 1):
            t0 = time.perf_counter_ns()
            outcomes: Counter[str] = Counter()
            total_inner_ms = 0.0

            if jobs <= 1:
                for src in files:
                    outcome, ms = compile_one_parse_probe(dmd=dmd, src=src, timeout_sec=timeout_sec, include_paths=include_paths)
                    outcomes[outcome] += 1
                    total_inner_ms += ms
            else:
                with ThreadPoolExecutor(max_workers=jobs) as pool:
                    futs = [pool.submit(compile_one_parse_probe, dmd, src, timeout_sec, include_paths) for src in files]
                    for fut in as_completed(futs):
                        outcome, ms = fut.result()
                        outcomes[outcome] += 1
                        total_inner_ms += ms

            wall_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
            summary_by_jobs[jobs].append(wall_ms)
            if outcomes.get("crash", 0) > 0:
                race_flags += outcomes["crash"]

            rows.append(
                {
                    "threads": jobs,
                    "repeat": rep,
                    "files": len(files),
                    "wall_ms": f"{wall_ms:.3f}",
                    "sum_file_ms": f"{total_inner_ms:.3f}",
                    "ok": outcomes.get("ok", 0),
                    "compile_error": outcomes.get("compile_error", 0),
                    "crash": outcomes.get("crash", 0),
                }
            )

    write_csv(
        task_dir / "results.csv",
        ["threads", "repeat", "files", "wall_ms", "sum_file_ms", "ok", "compile_error", "crash"],
        rows,
    )

    baseline_med = statistics.median(summary_by_jobs[min(thread_values)])
    speed_rows = []
    for jobs in sorted(summary_by_jobs):
        med = statistics.median(summary_by_jobs[jobs])
        speed_rows.append(
            {
                "threads": jobs,
                "median_wall_ms": f"{med:.3f}",
                "speedup_vs_1": f"{(baseline_med / med if med > 0 else float('nan')):.3f}",
            }
        )
    write_csv(task_dir / "speedup.csv", ["threads", "median_wall_ms", "speedup_vs_1"], speed_rows)

    return task_result(
        "run DMD Lexer/Parser in parallel",
        "done",
        thread_values=",".join(str(x) for x in sorted(thread_values)),
        repeats=repeats,
        files=len(files),
        crashes=race_flags,
        methodology="process-level parallel compile surrogate",
    )


def compile_incompiler_parse_probe(
    dmd: str,
    files: list[Path],
    parse_threads: int,
    timeout_sec: float,
    obj_dir: Path,
    include_paths: list[Path] | None = None,
    lock_mode: str = "coarse",
    diagnostics: bool = False,
) -> tuple[str, float, int, str, str, str]:
    obj_dir.mkdir(parents=True, exist_ok=True)
    for obj in obj_dir.glob("*.o"):
        obj.unlink(missing_ok=True)

    cmd = [dmd, "-c", f"-od={obj_dir}"]
    if include_paths:
        for p in include_paths:
            if p.exists():
                cmd.append(f"-I={p}")
    cmd.extend(str(p) for p in files)
    env = os.environ.copy()
    env["DMD_PARSE_THREADS"] = str(parse_threads)
    env["DMD_PARSE_LOCK_MODE"] = lock_mode
    env["DMD_PARSE_DIAGNOSTICS"] = "1" if diagnostics else "0"

    t0 = time.perf_counter_ns()
    try:
        cp = run_cmd(cmd, check=False, timeout=timeout_sec, env=env)
    except subprocess.TimeoutExpired:
        ms = (time.perf_counter_ns() - t0) / 1_000_000.0
        return "timeout", ms, 124, "timeout", "timeout", ""

    ms = (time.perf_counter_ns() - t0) / 1_000_000.0
    stderr_lines = cp.stderr.strip().splitlines() if cp.stderr.strip() else []
    diag_lines = [line for line in stderr_lines if line.startswith("parse-parallel-diag ")]
    err_lines = [line for line in stderr_lines if not line.startswith("parse-parallel-diag ")]
    err_tail = err_lines[-1] if err_lines else (diag_lines[-1] if diag_lines else "")
    err_excerpt_lines = err_lines[:40]
    err_excerpt = "\n".join(err_excerpt_lines)
    return classify_compile_outcome(cp), ms, cp.returncode, err_tail, err_excerpt, "\n".join(diag_lines)


def run_incompiler_parser_parallel_experiment(
    out_dir: Path,
    dmd: str,
    file_counts: list[int],
    thread_values: list[int],
    repeats: int,
    timeout_sec: float,
    lock_mode: str,
    diagnostics: bool,
) -> dict[str, object]:
    task_dir = out_dir / "parser_incompiler_parallel"
    task_dir.mkdir(parents=True, exist_ok=True)

    include_paths = resolve_d_import_paths(dmd)

    rows: list[dict[str, object]] = []
    successful_by_key: dict[tuple[int, int], list[float]] = defaultdict(list)
    crash_count = 0
    first_failure_by_key: dict[tuple[int, int], dict[str, object]] = {}
    diagnostic_rows: list[dict[str, object]] = []
    file_counts = sorted(set(file_counts))

    def parse_diag_payload(payload: str, *, file_count: int, threads: int, repeat: int) -> None:
        if not payload:
            return
        for line in payload.splitlines():
            row: dict[str, object] = {
                "files": file_count,
                "threads": threads,
                "repeat": repeat,
            }
            for token in line.split()[1:]:
                if "=" not in token:
                    continue
                key, value = token.split("=", 1)
                row[key] = value
            diagnostic_rows.append(row)

    for file_count in file_counts:
        files = generate_parser_workload(task_dir / f"workload_{file_count}", file_count=file_count)
        obj_dir = task_dir / f"obj_{file_count}"
        for jobs in thread_values:
            for rep in range(1, repeats + 1):
                key = (file_count, jobs)
                outcome, wall_ms, rc, err_tail, err_excerpt, diag_payload = compile_incompiler_parse_probe(
                    dmd=dmd,
                    files=files,
                    parse_threads=jobs,
                    timeout_sec=timeout_sec,
                    obj_dir=obj_dir,
                    include_paths=include_paths,
                    lock_mode=lock_mode,
                    diagnostics=diagnostics,
                )
                if outcome == "ok":
                    successful_by_key[key].append(wall_ms)
                elif outcome == "crash":
                    crash_count += 1
                if outcome != "ok" and key not in first_failure_by_key:
                    first_failure_by_key[key] = {
                        "repeat": rep,
                        "outcome": outcome,
                        "returncode": rc,
                        "error_tail": err_tail,
                        "error_excerpt": err_excerpt,
                    }
                parse_diag_payload(diag_payload, file_count=file_count, threads=jobs, repeat=rep)

                rows.append(
                    {
                        "files": file_count,
                        "threads": jobs,
                        "repeat": rep,
                        "lock_mode": lock_mode,
                        "wall_ms": f"{wall_ms:.3f}",
                        "outcome": outcome,
                        "returncode": rc,
                        "error_tail": err_tail,
                    }
                )

    write_csv(
        task_dir / "results.csv",
        ["files", "threads", "repeat", "lock_mode", "wall_ms", "outcome", "returncode", "error_tail"],
        rows,
    )

    speed_rows: list[dict[str, object]] = []
    base_threads = min(thread_values)
    best_speedup = 1.0
    speedup_goal_met = False
    all_runs_clean = True
    for file_count in file_counts:
        baseline_samples = successful_by_key.get((file_count, base_threads), [])
        baseline_med = statistics.median(baseline_samples) if baseline_samples else None
        for jobs in sorted(thread_values):
            samples = successful_by_key.get((file_count, jobs), [])
            successful_runs = len(samples)
            if successful_runs != repeats:
                all_runs_clean = False
            if samples:
                med = statistics.median(samples)
                speedup = (baseline_med / med) if baseline_med and med > 0 else float("nan")
                if math.isfinite(speedup):
                    best_speedup = max(best_speedup, speedup)
                    if file_count >= 128 and jobs > base_threads and successful_runs == repeats and speedup >= 1.10:
                        speedup_goal_met = True
                speed_rows.append(
                    {
                        "files": file_count,
                        "threads": jobs,
                        "lock_mode": lock_mode,
                        "successful_runs": successful_runs,
                        "median_wall_ms": f"{med:.3f}",
                        "speedup_vs_1": format_float(speedup),
                    }
                )
            else:
                speed_rows.append(
                    {
                        "files": file_count,
                        "threads": jobs,
                        "lock_mode": lock_mode,
                        "successful_runs": 0,
                        "median_wall_ms": "",
                        "speedup_vs_1": "",
                    }
                )

    write_csv(
        task_dir / "speedup.csv",
        ["files", "threads", "lock_mode", "successful_runs", "median_wall_ms", "speedup_vs_1"],
        speed_rows,
    )

    if diagnostic_rows:
        write_csv_dynamic(task_dir / "diagnostics.csv", diagnostic_rows)

    if first_failure_by_key:
        failure_lines = ["# First failure by thread count", ""]
        for file_count, jobs in sorted(first_failure_by_key):
            f = first_failure_by_key[(file_count, jobs)]
            failure_lines.append(f"## files={file_count}, threads={jobs}")
            failure_lines.append(f"- repeat: {f['repeat']}")
            failure_lines.append(f"- outcome: {f['outcome']}")
            failure_lines.append(f"- returncode: {f['returncode']}")
            failure_lines.append(f"- error_tail: {f['error_tail']}")
            failure_lines.append("")
            excerpt = str(f.get("error_excerpt", "")).strip()
            if excerpt:
                failure_lines.append("```text")
                failure_lines.append(excerpt)
                failure_lines.append("```")
                failure_lines.append("")
        (task_dir / "failure_snippets.md").write_text("\n".join(failure_lines) + "\n", encoding="utf-8")

    performance_status = "done" if speedup_goal_met else "partial"
    if all_runs_clean and (lock_mode != "narrow" or speedup_goal_met or max(file_counts) < 128):
        status = "done"
    elif all_runs_clean:
        status = "partial"
    else:
        status = "blocked"
    return task_result(
        "run DMD Lexer/Parser in parallel (in-compiler threaded prototype)",
        status,
        thread_values=",".join(str(x) for x in sorted(thread_values)),
        repeats=repeats,
        file_counts=",".join(str(x) for x in file_counts),
        lock_mode=lock_mode,
        crashes=crash_count,
        failed_keys=",".join(f"{file_count}x{jobs}" for file_count, jobs in sorted(first_failure_by_key)) if first_failure_by_key else "",
        max_speedup_vs_1=round(best_speedup, 3),
        performance_status=performance_status,
        speedup_goal_met=int(speedup_goal_met),
        env_knobs="DMD_PARSE_THREADS,DMD_PARSE_LOCK_MODE,DMD_PARSE_DIAGNOSTICS",
        methodology="single compiler process; ParserParallelPrototype measures coarse vs narrow lock modes",
    )


def shuffle_lines(text: str, line_patterns: list[str], seed: int) -> tuple[str, bool]:
    lines = text.splitlines()
    indices: list[int] = []
    matched_lines: list[str] = []
    matched_pattern = [False] * len(line_patterns)

    def matches_pattern(stripped: str, pattern: str) -> bool:
        if stripped == pattern:
            return True
        # Allow trailing comments/spaces after field declarations.
        return pattern.endswith(";") and stripped.startswith(pattern)

    for i, line in enumerate(lines):
        stripped = line.strip()
        for p_idx, pattern in enumerate(line_patterns):
            if matched_pattern[p_idx]:
                continue
            if matches_pattern(stripped, pattern):
                indices.append(i)
                matched_lines.append(line)
                matched_pattern[p_idx] = True
                break
    if len(indices) != len(line_patterns):
        return text, False

    rnd = random.Random(seed)
    shuffled = matched_lines[:]
    rnd.shuffle(shuffled)
    for idx, new_line in zip(indices, shuffled):
        lines[idx] = new_line
    return "\n".join(lines) + "\n", True


def measure_compile_median(
    dmd_bin: str,
    benchmark_file: Path,
    work_dir: Path,
    runs: int,
    warmups: int,
    timeout_sec: float,
    extra_import_paths: list[Path] | None = None,
) -> tuple[float, float]:
    obj = work_dir / "bench_tmp.o"
    samples: list[float] = []
    cmd = [dmd_bin, str(benchmark_file), "-c", f"-of={obj}", "-O"]
    if extra_import_paths:
        for path in extra_import_paths:
            if path.exists():
                cmd.append(f"-I={path}")

    for _ in range(warmups):
        run_cmd(cmd, check=True, timeout=timeout_sec)

    for _ in range(runs):
        t0 = time.perf_counter_ns()
        run_cmd(cmd, check=True, timeout=timeout_sec)
        ms = (time.perf_counter_ns() - t0) / 1_000_000.0
        samples.append(ms)

    return statistics.median(samples), median_abs_deviation(samples)


def find_built_dmd(repo: Path) -> Path | None:
    for path in repo.rglob("dmd"):
        if not path.is_file():
            continue
        if "generated" not in path.parts:
            continue
        if os.access(path, os.X_OK):
            return path
    return None


def resolve_d_import_paths(host_dmd: str) -> list[Path]:
    dmd_path = Path(host_dmd).expanduser().resolve()
    roots = [
        dmd_path.parent.parent.parent,  # <install>/osx/bin/dmd -> <install>
        dmd_path.parent.parent,         # fallback: <install>/osx
    ]
    paths: list[Path] = []
    for root in roots:
        for candidate in (
            root / "src" / "druntime" / "import",
            root / "src" / "druntime" / "src",
            root / "src" / "phobos",
        ):
            if candidate.exists() and candidate not in paths:
                paths.append(candidate)

    # Repo-built DMD binaries (e.g. external/dmd/generated/*/dmd) need explicit
    # druntime/phobos include roots from the source checkout.
    for parent in dmd_path.parents:
        if (parent / "compiler" / "src" / "dmd" / "main.d").exists():
            for candidate in (
                parent / "druntime" / "import",
                parent / "druntime" / "src",
                parent / "phobos",
                parent / "src" / "druntime" / "import",
                parent / "src" / "druntime" / "src",
                parent / "src" / "phobos",
            ):
                if candidate.exists() and candidate not in paths:
                    paths.append(candidate)
            break
    return paths


def run_ast_field_order_experiment(
    out_dir: Path,
    dmd_repo: Path,
    host_dmd: str,
    rdmd_bin: Path | None,
    benchmark_file: Path,
    seeds: list[int],
    runs: int,
    warmups: int,
    build_timeout_sec: float,
    compile_timeout_sec: float,
) -> dict[str, object]:
    task_dir = out_dir / "ast_field_order"
    task_dir.mkdir(parents=True, exist_ok=True)

    if not dmd_repo.exists():
        return task_result(
            "randomize DMD AST field order and measure cache locality",
            "blocked",
            reason=f"missing dmd repo: {dmd_repo}",
        )

    worktree = task_dir / "worktree"
    run_cmd(
        ["git", "-C", str(dmd_repo), "worktree", "remove", "--force", str(worktree)],
        check=False,
        timeout=60.0,
    )
    if worktree.exists():
        shutil.rmtree(worktree, ignore_errors=True)

    add_cp = run_cmd(
        ["git", "-C", str(dmd_repo), "worktree", "add", "--detach", str(worktree), "HEAD"],
        check=False,
        timeout=120.0,
    )
    if add_cp.returncode != 0:
        return task_result(
            "randomize DMD AST field order and measure cache locality",
            "blocked",
            reason="failed to create git worktree",
            stderr_tail=add_cp.stderr.strip().splitlines()[-1] if add_cp.stderr.strip() else "",
        )

    src_dir = worktree / "compiler" / "src"
    build_env = os.environ.copy()
    if rdmd_bin and rdmd_bin.exists():
        build_env["PATH"] = f"{rdmd_bin.parent}:{build_env.get('PATH', '')}"
    if not src_dir.exists():
        try:
            shutil.copytree(dmd_repo, worktree, dirs_exist_ok=True)
        except OSError as exc:
            return task_result(
                "randomize DMD AST field order and measure cache locality",
                "blocked",
                reason=f"worktree copy fallback failed: {exc}",
            )
        src_dir = worktree / "compiler" / "src"
        if not src_dir.exists():
            return task_result(
                "randomize DMD AST field order and measure cache locality",
                "blocked",
                reason=f"missing compiler/src in worktree: {src_dir}",
            )
    build_cmd = ["./build.d", f"HOST_DMD={host_dmd}"]

    baseline_build = run_cmd(build_cmd, cwd=src_dir, check=False, timeout=build_timeout_sec, env=build_env)
    if baseline_build.returncode != 0:
        return task_result(
            "randomize DMD AST field order and measure cache locality",
            "blocked",
            reason="baseline dmd build failed",
            stderr_tail=baseline_build.stderr.strip().splitlines()[-1] if baseline_build.stderr.strip() else "",
        )

    built = find_built_dmd(worktree)
    if built is None:
        return task_result(
            "randomize DMD AST field order and measure cache locality",
            "blocked",
            reason="unable to locate built dmd binary in worktree",
        )

    dsymbol_path = worktree / "compiler" / "src" / "dmd" / "dsymbol.d"
    expression_path = worktree / "compiler" / "src" / "dmd" / "expression.d"
    original_dsymbol = dsymbol_path.read_text(encoding="utf-8")
    original_expression = expression_path.read_text(encoding="utf-8")

    rows: list[dict[str, object]] = []
    import_paths = resolve_d_import_paths(host_dmd)
    try:
        base_med, base_mad = measure_compile_median(
            dmd_bin=str(built),
            benchmark_file=benchmark_file,
            work_dir=task_dir,
            runs=runs,
            warmups=warmups,
            timeout_sec=compile_timeout_sec,
            extra_import_paths=import_paths,
        )
    except RuntimeError as exc:
        run_cmd(
            ["git", "-C", str(dmd_repo), "worktree", "remove", "--force", str(worktree)],
            check=False,
            timeout=60.0,
        )
        return task_result(
            "randomize DMD AST field order and measure cache locality",
            "blocked",
            reason="benchmark compile failed for baseline DMD build",
            stderr_tail=str(exc).strip().splitlines()[-1] if str(exc).strip() else "",
        )
    rows.append({"variant": "baseline", "seed": 0, "median_ms": f"{base_med:.3f}", "mad_ms": f"{base_mad:.3f}", "ratio_vs_baseline": "1.000"})

    completed = 0
    for seed in seeds:
        ds_text, ok1 = shuffle_lines(
            original_dsymbol,
            [
                "Identifier ident;",
                "Dsymbol parent;",
                "void* csym;",
                "Scope* _scope;",
                "private DsymbolAttributes* atts;",
                "const Loc loc;",
                "ushort localNum;",
            ],
            seed,
        )
        ex_text, ok2 = shuffle_lines(
            original_expression,
            [
                "Type type;",
                "Loc loc;        // file location",
                "const EXP op;   // to minimize use of dynamic_cast",
            ],
            seed,
        )
        if not (ok1 and ok2):
            rows.append(
                {
                    "variant": "seed",
                    "seed": seed,
                    "median_ms": "",
                    "mad_ms": "",
                    "ratio_vs_baseline": "",
                    "error": "failed to rewrite target field lines",
                }
            )
            continue

        dsymbol_path.write_text(ds_text, encoding="utf-8")
        expression_path.write_text(ex_text, encoding="utf-8")

        rebuild = run_cmd(build_cmd, cwd=src_dir, check=False, timeout=build_timeout_sec, env=build_env)
        if rebuild.returncode != 0:
            rows.append(
                {
                    "variant": "seed",
                    "seed": seed,
                    "median_ms": "",
                    "mad_ms": "",
                    "ratio_vs_baseline": "",
                    "error": rebuild.stderr.strip().splitlines()[-1] if rebuild.stderr.strip() else "rebuild failed",
                }
            )
            dsymbol_path.write_text(original_dsymbol, encoding="utf-8")
            expression_path.write_text(original_expression, encoding="utf-8")
            continue

        try:
            med, mad = measure_compile_median(
                dmd_bin=str(built),
                benchmark_file=benchmark_file,
                work_dir=task_dir,
                runs=runs,
                warmups=warmups,
                timeout_sec=compile_timeout_sec,
                extra_import_paths=import_paths,
            )
        except RuntimeError as exc:
            rows.append(
                {
                    "variant": "seed",
                    "seed": seed,
                    "median_ms": "",
                    "mad_ms": "",
                    "ratio_vs_baseline": "",
                    "error": str(exc).strip().splitlines()[-1] if str(exc).strip() else "compile benchmark failed",
                }
            )
            dsymbol_path.write_text(original_dsymbol, encoding="utf-8")
            expression_path.write_text(original_expression, encoding="utf-8")
            continue
        rows.append(
            {
                "variant": "seed",
                "seed": seed,
                "median_ms": f"{med:.3f}",
                "mad_ms": f"{mad:.3f}",
                "ratio_vs_baseline": f"{(med / base_med if base_med > 0 else float('nan')):.3f}",
            }
        )
        completed += 1

        dsymbol_path.write_text(original_dsymbol, encoding="utf-8")
        expression_path.write_text(original_expression, encoding="utf-8")

    write_csv_dynamic(task_dir / "results.csv", rows)

    run_cmd(
        ["git", "-C", str(dmd_repo), "worktree", "remove", "--force", str(worktree)],
        check=False,
        timeout=60.0,
    )

    return task_result(
        "randomize DMD AST field order and measure cache locality",
        "done" if completed > 0 else "blocked",
        seeds_attempted=len(seeds),
        seeds_completed=completed,
        baseline_median_ms=round(base_med, 3),
        dmd_binary=str(built),
    )


def parse_max_rss_bytes(time_stderr: str) -> int | None:
    m = re.search(r"\b(\d+)\s+maximum resident set size", time_stderr)
    if not m:
        return None
    try:
        return int(m.group(1))
    except ValueError:
        return None


def find_allocator_lib(name: str, local_root: Path) -> Path | None:
    candidates = [
        local_root / name / "lib" / f"lib{name}.dylib",
        local_root / f"lib{name}.dylib",
        Path(f"/opt/homebrew/lib/lib{name}.dylib"),
        Path(f"/usr/local/lib/lib{name}.dylib"),
    ]
    for c in candidates:
        if c.exists():
            return c
    return None


def run_allocator_compare(
    out_dir: Path,
    dmd: str,
    benchmark_file: Path,
    runs: int,
    warmups: int,
    timeout_sec: float,
) -> dict[str, object]:
    task_dir = out_dir / "allocator_compare"
    task_dir.mkdir(parents=True, exist_ok=True)

    libs_dir = task_dir / "allocators"
    libs_dir.mkdir(parents=True, exist_ok=True)

    modes: list[tuple[str, Path | None]] = [("system", None)]
    for name in ("mimalloc", "jemalloc"):
        lib = find_allocator_lib(name, libs_dir)
        if lib:
            modes.append((name, lib))

    rows: list[dict[str, object]] = []

    for mode, lib in modes:
        env = os.environ.copy()
        if lib is not None:
            env["DYLD_INSERT_LIBRARIES"] = str(lib)
            env["DYLD_FORCE_FLAT_NAMESPACE"] = "1"

        samples_ms: list[float] = []
        rss_samples: list[int] = []
        compile_errors = 0

        obj = task_dir / f"bench_{mode}.o"
        for _ in range(warmups):
            run_cmd(
                ["/usr/bin/time", "-l", dmd, str(benchmark_file), "-c", f"-of={obj}", "-O"],
                check=False,
                timeout=timeout_sec,
                env=env,
            )

        for _ in range(runs):
            t0 = time.perf_counter_ns()
            cp = run_cmd(
                ["/usr/bin/time", "-l", dmd, str(benchmark_file), "-c", f"-of={obj}", "-O"],
                check=False,
                timeout=timeout_sec,
                env=env,
            )
            elapsed_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
            if cp.returncode != 0:
                compile_errors += 1
                continue
            rss = parse_max_rss_bytes(cp.stderr)
            if rss is not None:
                rss_samples.append(rss)
            samples_ms.append(elapsed_ms)

        rows.append(
            {
                "mode": mode,
                "allocator_lib": str(lib) if lib else "",
                "runs": runs,
                "successful_runs": len(samples_ms),
                "compile_errors": compile_errors,
                "median_ms": f"{statistics.median(samples_ms):.3f}" if samples_ms else "",
                "mad_ms": f"{median_abs_deviation(samples_ms):.3f}" if len(samples_ms) >= 2 else "",
                "median_max_rss_bytes": int(statistics.median(rss_samples)) if rss_samples else "",
            }
        )

    write_csv_dynamic(task_dir / "results.csv", rows)

    alt_present = any(r["mode"] != "system" and r.get("successful_runs", 0) for r in rows)
    return task_result(
        "replace DMD malloc with mimalloc/jemalloc",
        "done" if alt_present else "blocked",
        modes_tested=",".join(r["mode"] for r in rows),
        note="set DYLD_INSERT_LIBRARIES for allocator interposition",
    )


def run_dmd_profile_compare(out_dir: Path, dmd: str, timeout_sec: float, perf_bin: str = "") -> dict[str, object]:
    task_dir = out_dir / "dmd_profile_compare"
    task_dir.mkdir(parents=True, exist_ok=True)

    src = task_dir / "profile_target.d"
    exe = task_dir / "profile_target"
    sample_file = task_dir / "sample_report.txt"

    src.write_text(
        textwrap.dedent(
            """
            module profile_target;

            import std.stdio : writeln;

            long hotLoop(size_t n)
            {
                long acc = 0;
                foreach (i; 0 .. n)
                {
                    auto v = cast(long) i;
                    if ((v & 1) == 0)
                        acc += v * 7 + 3;
                    else
                        acc -= v * 5 - 11;
                }
                return acc;
            }

            void main()
            {
                long total = 0;
                foreach (_; 0 .. 16)
                    total ^= hotLoop(40_000_000);
                writeln(total);
            }
            """
        ).strip()
        + "\n",
        encoding="utf-8",
    )

    (task_dir / "trace.log").unlink(missing_ok=True)
    (task_dir / "trace.def").unlink(missing_ok=True)

    compile_cp = run_cmd([dmd, str(src), "-O", "-release", "-profile", f"-of={exe}"], check=False, timeout=timeout_sec)
    if compile_cp.returncode != 0:
        return task_result(
            "dmd -profile vs perf comparison",
            "blocked",
            profiler_backend="compiler_profile",
            profiler_outcome="compile_failed",
            profiler_reason="failed to compile profile target",
            reason="failed to compile profile target",
            stderr_tail=compile_cp.stderr.strip().splitlines()[-1] if compile_cp.stderr.strip() else "",
        )

    exe_abs = str(exe.resolve())
    run_cp = run_cmd([exe_abs], cwd=task_dir, check=False, timeout=timeout_sec)
    trace_log = task_dir / "trace.log"
    trace_def = task_dir / "trace.def"

    if not trace_log.exists():
        return task_result(
            "dmd -profile vs perf comparison",
            "blocked",
            profiler_backend="compiler_profile",
            profiler_outcome="trace_missing",
            profiler_reason="trace.log not produced by profiled executable",
            reason="trace.log not produced by profiled executable",
        )

    trace_lines = len(trace_log.read_text(encoding="utf-8", errors="ignore").splitlines())
    (task_dir / "profiled_run_stdout.txt").write_text(run_cp.stdout, encoding="utf-8")
    (task_dir / "profiled_run_stderr.txt").write_text(run_cp.stderr, encoding="utf-8")

    def classify_linux_perf_failure(
        perf_stat_stderr: str,
        perf_record_stderr: str,
        perf_report_stderr: str,
    ) -> tuple[str, str]:
        combined = "\n".join((perf_stat_stderr, perf_record_stderr, perf_report_stderr))
        low = combined.lower()
        if "perf not found for kernel" in low:
            return "perf_unavailable", "hosted or local kernel-matched perf binary unavailable"
        if "no permission to enable" in low or "operation not permitted" in low or "perf_event_paranoid" in low:
            return "perf_permission_denied", "perf denied by kernel policy or permissions"
        return "perf_failed", "perf commands returned non-zero"

    system_name = platform.system().lower()
    resolved_perf = perf_bin if perf_bin and Path(perf_bin).exists() else (shutil.which("perf") or "")
    if system_name == "linux" and resolved_perf:
        perf_stat_file = task_dir / "perf_stat.txt"
        perf_record_file = task_dir / "perf.data"
        perf_report_file = task_dir / "perf_report.txt"

        perf_stat_cp = run_cmd(
            [resolved_perf, "stat", "-x,", "-o", str(perf_stat_file), exe_abs],
            cwd=task_dir,
            check=False,
            timeout=timeout_sec,
        )
        (task_dir / "perf_stat_stdout.txt").write_text(perf_stat_cp.stdout, encoding="utf-8")
        (task_dir / "perf_stat_stderr.txt").write_text(perf_stat_cp.stderr, encoding="utf-8")
        perf_record_cp = run_cmd(
            [resolved_perf, "record", "-F", "99", "-g", "-o", str(perf_record_file), exe_abs],
            cwd=task_dir,
            check=False,
            timeout=timeout_sec,
        )
        (task_dir / "perf_record_stdout.txt").write_text(perf_record_cp.stdout, encoding="utf-8")
        (task_dir / "perf_record_stderr.txt").write_text(perf_record_cp.stderr, encoding="utf-8")

        perf_report_cp = run_cmd(
            [resolved_perf, "report", "--stdio", "-i", str(perf_record_file)],
            cwd=task_dir,
            check=False,
            timeout=timeout_sec,
        )
        perf_report_file.write_text(perf_report_cp.stdout, encoding="utf-8")
        (task_dir / "perf_report_stderr.txt").write_text(perf_report_cp.stderr, encoding="utf-8")

        perf_report_lines = len(perf_report_cp.stdout.splitlines()) if perf_report_cp.stdout else 0
        ok = (
            perf_stat_cp.returncode == 0
            and perf_record_cp.returncode == 0
            and perf_report_cp.returncode == 0
            and perf_report_lines > 0
        )
        profiler_outcome = "done"
        profiler_reason = ""
        if not ok:
            profiler_outcome, profiler_reason = classify_linux_perf_failure(
                perf_stat_cp.stderr,
                perf_record_cp.stderr,
                perf_report_cp.stderr,
            )
        comparison_lines = [
            "# dmd -profile vs Linux perf",
            "",
            f"- Profiler binary: `{resolved_perf}`",
            f"- Trace log lines: {trace_lines}",
            f"- trace.def exists: {int(trace_def.exists())}",
            f"- perf_stat rc: {perf_stat_cp.returncode}",
            f"- perf_record rc: {perf_record_cp.returncode}",
            f"- perf_report rc: {perf_report_cp.returncode}",
            f"- perf_report lines: {perf_report_lines}",
            f"- profiler outcome: `{profiler_outcome}`",
        ]
        if profiler_reason:
            comparison_lines.append(f"- profiler reason: {profiler_reason}")
        (task_dir / "comparison_report.md").write_text("\n".join(comparison_lines) + "\n", encoding="utf-8")
        return task_result(
            "dmd -profile vs perf comparison",
            "done" if ok else "blocked",
            profiler_backend="perf",
            profiler_outcome=profiler_outcome,
            profiler_reason=profiler_reason,
            perf_bin=resolved_perf,
            methodology="linux perf",
            trace_log_lines=trace_lines,
            trace_def_exists=int(trace_def.exists()),
            perf_stat_rc=perf_stat_cp.returncode,
            perf_record_rc=perf_record_cp.returncode,
            perf_report_rc=perf_report_cp.returncode,
            perf_report_lines=perf_report_lines,
            note="If blocked, check kernel.perf_event_paranoid and debug symbols availability",
        )

    if system_name == "darwin" and shutil.which("sample"):
        proc = subprocess.Popen([exe_abs], cwd=str(task_dir), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(0.3)
        sample_cp = run_cmd(
            ["sample", str(proc.pid), "2", "1", "-mayDie", "-file", str(sample_file)],
            check=False,
            timeout=180.0,
        )
        (task_dir / "sample_stdout.txt").write_text(sample_cp.stdout, encoding="utf-8")
        (task_dir / "sample_stderr.txt").write_text(sample_cp.stderr, encoding="utf-8")
        try:
            proc_out, proc_err = proc.communicate(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc_out, proc_err = proc.communicate()

        (task_dir / "profiled_run_stdout.txt").write_text(run_cp.stdout + "\n---\n" + proc_out, encoding="utf-8")
        (task_dir / "profiled_run_stderr.txt").write_text(run_cp.stderr + "\n---\n" + proc_err, encoding="utf-8")
        sample_lines = len(sample_file.read_text(encoding="utf-8", errors="ignore").splitlines()) if sample_file.exists() else 0
        comparison_lines = [
            "# dmd -profile vs sample",
            "",
            f"- Trace log lines: {trace_lines}",
            f"- trace.def exists: {int(trace_def.exists())}",
            f"- sample lines: {sample_lines}",
            f"- sample rc: {sample_cp.returncode}",
        ]
        (task_dir / "comparison_report.md").write_text("\n".join(comparison_lines) + "\n", encoding="utf-8")

        return task_result(
            "dmd -profile vs perf comparison",
            "done" if sample_cp.returncode == 0 and sample_file.exists() else "blocked",
            profiler_backend="sample",
            profiler_outcome="done" if sample_cp.returncode == 0 and sample_file.exists() else "sample_failed",
            profiler_reason="" if sample_cp.returncode == 0 and sample_file.exists() else "sample tool failed",
            methodology="macOS sample (perf unavailable)",
            trace_log_lines=trace_lines,
            sample_report_lines=sample_lines,
            trace_def_exists=int(trace_def.exists()),
        )

    return task_result(
        "dmd -profile vs perf comparison",
        "blocked",
        profiler_backend="none",
        profiler_outcome="unsupported_host",
        profiler_reason="unsupported profiler setup for current host",
        reason=f"unsupported host profiler setup: platform={platform.system()} perf={int(bool(resolved_perf))} sample={int(bool(shutil.which('sample')))}",
        trace_log_lines=trace_lines,
        trace_def_exists=int(trace_def.exists()),
    )


def gather_tool_versions(
    ldc2: str,
    dmd: str,
    clang: str,
    dub_bin: str = "",
    ldmd2_bin: str = "",
    ldc_profdata_bin: str = "",
    perf_bin: str = "",
) -> dict[str, str]:
    versions: dict[str, str] = {}
    versions["python"] = sys.version.split()[0]
    versions["platform"] = platform.platform()

    for key, cmd in {
        "ldc2": [ldc2, "--version"],
        "dmd": [dmd, "--version"],
        "clang": [clang, "--version"],
        "dub": [dub_bin, "--version"] if dub_bin else [],
        "ldmd2": [ldmd2_bin, "--version"] if ldmd2_bin else [],
        "ldc-profdata": [ldc_profdata_bin, "--version"] if ldc_profdata_bin else [],
        "objdump": ["objdump", "--version"],
    }.items():
        if not cmd:
            versions[key] = ""
            continue
        exe = cmd[0]
        available = True
        if "/" in exe:
            available = Path(exe).exists()
        else:
            available = shutil.which(exe) is not None
        if not available:
            versions[key] = ""
            continue

        try:
            cp = run_cmd(cmd, check=False, timeout=20.0)
        except FileNotFoundError:
            versions[key] = ""
            continue
        text = (cp.stdout or cp.stderr).strip().splitlines()
        versions[key] = text[0] if text else ""

    resolved_perf = perf_bin if perf_bin and Path(perf_bin).exists() else (shutil.which("perf") or "")
    if resolved_perf:
        cp = run_cmd([resolved_perf, "--version"], check=False, timeout=20.0)
        text = (cp.stdout or cp.stderr).strip().splitlines()
        versions["perf"] = text[0] if text else ""
    if shutil.which("sample"):
        cp = run_cmd(["sample", "-h"], check=False, timeout=20.0)
        text = (cp.stdout or cp.stderr).strip().splitlines()
        versions["sample"] = text[0] if text else "sample available"
    return versions


def render_status_report(path: Path, results: list[dict[str, object]]) -> None:
    lines = [
        "# Dennis gist: Not Done status",
        "",
        f"Generated: {now_utc()}",
        "",
        "| Task | Status | Key result |",
        "|---|---|---|",
    ]

    for result in results:
        task = str(result.get("task", ""))
        status = str(result.get("status", "unknown"))
        key_bits = []
        for key in sorted(result.keys()):
            if key in {"task", "status"}:
                continue
            key_bits.append(f"{key}={result[key]}")
            if len(key_bits) >= 3:
                break
        key_result = "; ".join(key_bits) if key_bits else "-"
        lines.append(f"| {task} | {status} | {key_result} |")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def render_runtime_libs_report(out_dir: Path, results: list[dict[str, object]]) -> None:
    task_keys = {
        "benchmark D GC kernels": "gc_kernels",
        "benchmark D associative arrays": "aa_kernels",
        "benchmark D float-to-string conversion": "float_to_string_kernels",
    }
    selected = [result for result in results if str(result.get("task", "")) in task_keys]
    if not selected:
        return

    rows = []
    for result in selected:
        task = str(result.get("task", ""))
        rows.append(
            [
                task,
                result.get("status", ""),
                f"{task_keys[task]}/report.md",
            ]
        )

    lines = [
        "# Runtime-library benchmark aggregate",
        "",
        *emit_markdown_table(["Task", "Status", "Artifact"], rows),
    ]
    (out_dir / "runtime_libs_report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_int_list(csv_value: str) -> list[int]:
    out: list[int] = []
    for raw in csv_value.split(","):
        v = raw.strip()
        if not v:
            continue
        out.append(int(v))
    return sorted(set(x for x in out if x > 0))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", default="artifacts/not_done", help="Output directory")
    parser.add_argument("--phase", choices=["quick", "analysis", "invasive", "runtime_libs", "broader_gist", "all"], default="all")
    parser.add_argument("--tasks", default="", help="Comma-separated task keys to run")
    parser.add_argument("--skip-perfetto", action="store_true", help="Skip perfetto screenshot task")
    parser.add_argument("--max-rigor", action="store_true", help="Use higher run counts and sweeps")

    parser.add_argument("--ldc2", default=".locald/ldc-1.42.0/bin/ldc2", help="Path to ldc2")
    parser.add_argument("--dmd", default=".locald/dmd-nightly/osx/bin/dmd", help="Path to dmd")
    parser.add_argument("--dub-bin", default=".locald/ldc-1.42.0/bin/dub", help="Path to dub")
    parser.add_argument("--ldmd2-bin", default=".locald/ldc-1.42.0/bin/ldmd2", help="Path to ldmd2")
    parser.add_argument("--ldc-profdata-bin", default=".locald/ldc-1.42.0/bin/ldc-profdata", help="Path to ldc-profdata")
    parser.add_argument("--rdmd-bin", default=".locald/ldc-1.42.0/bin/rdmd", help="Path to rdmd for DMD build.d")
    parser.add_argument("--clang", default="clang", help="Path to clang")
    parser.add_argument("--perf-bin", default=os.environ.get("PERF_BIN", ""), help="Path to perf binary (or PERF_BIN env)")
    parser.add_argument(
        "--phobos-archive",
        default=".locald/dmd-nightly/osx/lib/libphobos2.a",
        help="Path to libphobos archive",
    )
    parser.add_argument("--benchmark", default="benchmark.d", help="Benchmark source file for compiler timing")
    parser.add_argument("--dmd-repo", default="external/dmd", help="Path to cloned dmd repository")
    parser.add_argument(
        "--dub-pgo-workspace",
        default="benchmarks/dub_pgo_workspace",
        help="Path to the checked-in workspace used to benchmark dub with PGO",
    )
    parser.add_argument("--dub-upstream-ref", default="master", help="Git ref for dlang/dub used in the PGO benchmark")

    parser.add_argument("--zero-cost-runs", type=int, default=9, help="Measured runs per mode")
    parser.add_argument("--zero-cost-warmups", type=int, default=2, help="Warmup runs per mode")
    parser.add_argument("--zero-cost-iters", type=int, default=25, help="Function invocations per run")
    parser.add_argument("--runtime-runs", type=int, default=7, help="Measured runs for runtime-library kernels")
    parser.add_argument("--runtime-warmups", type=int, default=2, help="Warmup runs for runtime-library kernels")
    parser.add_argument("--dub-pgo-runs", type=int, default=5, help="Measured runs per dub command for PGO comparison")

    parser.add_argument("--fuzz-iters", type=int, default=120, help="Number of fuzz iterations")
    parser.add_argument("--fuzz-timeout", type=float, default=2.0, help="Per-sample compile timeout")
    parser.add_argument("--fuzz-seed", type=int, default=42, help="RNG seed for fuzz mutations")

    parser.add_argument("--project-set", choices=["curated5", "top10+curated5"], default="top10+curated5")
    parser.add_argument("--struct-size-threshold", type=int, default=512, help="Large struct threshold in bytes")
    parser.add_argument("--struct-max-candidates", type=int, default=80, help="Max struct probes per project")

    parser.add_argument("--parser-file-count", type=int, default=48, help="Generated file count for parser benchmarks")
    parser.add_argument("--parser-file-counts", default="", help="Comma-separated parser benchmark corpus sizes")
    parser.add_argument("--parser-threads", default="1,2,4,8", help="Comma-separated parser benchmark thread counts")
    parser.add_argument("--parser-repeats", type=int, default=3, help="Repeats per parser thread count")
    parser.add_argument("--parser-lock-mode", choices=["coarse", "narrow"], default="narrow", help="Parser prototype lock mode")
    parser.add_argument("--parser-diagnostics", action="store_true", help="Enable parser prototype timing diagnostics")

    parser.add_argument("--allocator-runs", type=int, default=7, help="Runs for allocator comparison")
    parser.add_argument("--allocator-warmups", type=int, default=2, help="Warmups for allocator comparison")

    parser.add_argument("--ast-seeds", default="1", help="Comma-separated seeds for AST field order experiment")
    parser.add_argument("--ast-runs", type=int, default=5, help="Compile-time runs per AST variant")
    parser.add_argument("--ast-warmups", type=int, default=1, help="Compile-time warmups per AST variant")

    parser.add_argument("--task-timeout", type=float, default=240.0, help="Generic task timeout in seconds")
    parser.add_argument("--clone-timeout", type=float, default=300.0, help="Git clone timeout in seconds")
    parser.add_argument("--build-timeout", type=float, default=2400.0, help="DMD build timeout in seconds")

    return parser.parse_args()


def resolve_selected_tasks(args: argparse.Namespace) -> list[str]:
    if args.tasks.strip():
        selected = [x.strip() for x in args.tasks.split(",") if x.strip()]
    elif args.phase == "all":
        selected = TASK_ORDER[:]
    else:
        selected = PHASE_TASKS[args.phase][:]

    valid = set(TASK_ORDER)
    cleaned = []
    for task in selected:
        if task in valid and task not in cleaned:
            cleaned.append(task)

    if args.skip_perfetto and "perfetto" in cleaned:
        cleaned.remove("perfetto")

    return cleaned


def apply_max_rigor_defaults(args: argparse.Namespace) -> None:
    if not args.max_rigor:
        return

    args.zero_cost_runs = max(args.zero_cost_runs, 21)
    args.zero_cost_warmups = max(args.zero_cost_warmups, 5)
    args.zero_cost_iters = max(args.zero_cost_iters, 40)
    args.runtime_runs = max(args.runtime_runs, 11)
    args.runtime_warmups = max(args.runtime_warmups, 3)
    args.dub_pgo_runs = max(args.dub_pgo_runs, 7)

    args.fuzz_iters = max(args.fuzz_iters, 1000)
    args.fuzz_timeout = max(args.fuzz_timeout, 3.0)

    args.struct_max_candidates = max(args.struct_max_candidates, 200)

    args.parser_file_count = max(args.parser_file_count, 96)
    args.parser_repeats = max(args.parser_repeats, 5)

    args.allocator_runs = max(args.allocator_runs, 11)
    args.allocator_warmups = max(args.allocator_warmups, 3)

    args.ast_runs = max(args.ast_runs, 9)
    args.ast_warmups = max(args.ast_warmups, 2)


def main() -> int:
    args = parse_args()
    apply_max_rigor_defaults(args)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    selected_tasks = resolve_selected_tasks(args)
    if not selected_tasks:
        print("No tasks selected", file=sys.stderr)
        return 2

    ldc2 = str(Path(args.ldc2).expanduser().resolve())
    dmd = str(Path(args.dmd).expanduser().resolve())
    dub_bin = str(Path(args.dub_bin).expanduser().resolve())
    ldmd2_bin = str(Path(args.ldmd2_bin).expanduser().resolve())
    ldc_profdata_bin = str(Path(args.ldc_profdata_bin).expanduser().resolve())
    rdmd_bin = Path(args.rdmd_bin).expanduser().resolve()
    clang = args.clang
    perf_bin = str(Path(args.perf_bin).expanduser().resolve()) if args.perf_bin else ""
    phobos_archive = Path(args.phobos_archive).expanduser().resolve()
    dmd_repo = Path(args.dmd_repo).expanduser().resolve()
    benchmark_file = Path(args.benchmark).expanduser().resolve()
    dub_pgo_workspace = Path(args.dub_pgo_workspace).expanduser().resolve()

    tasks_need_ldc2 = {
        "zero_cost",
        "gc_kernels",
        "aa_kernels",
        "float_to_string_kernels",
        "linker_strip",
        "allocator_compare",
        "c_vs_d_asm",
        "large_char_array",
    }
    tasks_need_dmd = {"non_zero_init_structs", "ast_field_order", "parser_parallel", "parser_incompiler_parallel", "dmd_profile_compare", "compiler_fuzz"}
    tasks_need_clang = {"c_vs_d_asm"}
    tasks_need_phobos_archive = {"phobos_sections"}
    tasks_need_benchmark = {"ast_field_order"}
    tasks_need_rdmd = {"ast_field_order"}
    tasks_need_dub = {"dub_pgo"}
    tasks_need_ldmd2 = {"dub_pgo"}
    tasks_need_profdata = {"dub_pgo"}

    if any(task in tasks_need_ldc2 for task in selected_tasks) and not Path(ldc2).exists():
        print(f"ldc2 not found: {ldc2}", file=sys.stderr)
        return 2
    if any(task in tasks_need_dmd for task in selected_tasks) and not Path(dmd).exists():
        print(f"dmd not found: {dmd}", file=sys.stderr)
        return 2
    if any(task in tasks_need_clang for task in selected_tasks) and shutil.which(clang) is None:
        print(f"clang not found: {clang}", file=sys.stderr)
        return 2
    if any(task in tasks_need_phobos_archive for task in selected_tasks) and not phobos_archive.exists():
        print(f"phobos archive not found: {phobos_archive}", file=sys.stderr)
        return 2
    if any(task in tasks_need_benchmark for task in selected_tasks) and not benchmark_file.exists():
        print(f"benchmark file not found: {benchmark_file}", file=sys.stderr)
        return 2
    if any(task in tasks_need_rdmd for task in selected_tasks) and not rdmd_bin.exists():
        print(f"rdmd not found: {rdmd_bin}", file=sys.stderr)
        return 2
    if any(task in tasks_need_dub for task in selected_tasks) and not Path(dub_bin).exists():
        print(f"dub not found: {dub_bin}", file=sys.stderr)
        return 2
    if any(task in tasks_need_ldmd2 for task in selected_tasks) and not Path(ldmd2_bin).exists():
        print(f"ldmd2 not found: {ldmd2_bin}", file=sys.stderr)
        return 2
    if any(task in tasks_need_profdata for task in selected_tasks) and not Path(ldc_profdata_bin).exists():
        print(f"ldc-profdata not found: {ldc_profdata_bin}", file=sys.stderr)
        return 2

    manifest: dict[str, object] = {
        "generated_at": now_utc(),
        "selected_tasks": selected_tasks,
        "phase": args.phase,
        "args": vars(args),
        "tool_versions": gather_tool_versions(
            ldc2=ldc2,
            dmd=dmd,
            clang=clang,
            dub_bin=dub_bin,
            ldmd2_bin=ldmd2_bin,
            ldc_profdata_bin=ldc_profdata_bin,
            perf_bin=perf_bin,
        ),
    }

    parser_file_counts = parse_int_list(args.parser_file_counts) if args.parser_file_counts.strip() else [args.parser_file_count]

    task_funcs: dict[str, callable[[], dict[str, object]]] = {
        "perfetto": lambda: attempt_perfetto_screenshot(out_dir=out_dir, trace_file=Path("artifacts/trace.json"), timeout_sec=max(args.task_timeout, 360.0)),
        "zero_cost": lambda: run_zero_cost_experiment(
            out_dir=out_dir,
            ldc2=ldc2,
            runs=args.zero_cost_runs,
            warmups=args.zero_cost_warmups,
            iterations=args.zero_cost_iters,
        ),
        "phobos_sections": lambda: run_phobos_section_analysis(out_dir=out_dir, archive_path=phobos_archive),
        "gc_kernels": lambda: run_gc_kernel_experiment(
            out_dir=out_dir,
            ldc2=ldc2,
            runs=args.runtime_runs,
            warmups=args.runtime_warmups,
            timeout_sec=max(args.task_timeout, 240.0),
        ),
        "aa_kernels": lambda: run_aa_kernel_experiment(
            out_dir=out_dir,
            ldc2=ldc2,
            runs=args.runtime_runs,
            warmups=args.runtime_warmups,
            timeout_sec=max(args.task_timeout, 300.0),
        ),
        "float_to_string_kernels": lambda: run_float_to_string_experiment(
            out_dir=out_dir,
            ldc2=ldc2,
            runs=args.runtime_runs,
            warmups=args.runtime_warmups,
            timeout_sec=max(args.task_timeout, 240.0),
        ),
        "dub_pgo": lambda: run_dub_pgo_experiment(
            out_dir=out_dir,
            dub_bin=dub_bin,
            ldmd2_bin=ldmd2_bin,
            ldc_profdata_bin=ldc_profdata_bin,
            runs=args.dub_pgo_runs,
            timeout_sec=max(args.task_timeout, 2400.0),
            clone_timeout=args.clone_timeout,
            workspace_root=dub_pgo_workspace,
            upstream_ref=args.dub_upstream_ref,
        ),
        "non_zero_init_structs": lambda: run_non_zero_init_struct_scan(
            out_dir=out_dir,
            dmd=dmd,
            project_set=args.project_set,
            max_candidates_per_project=args.struct_max_candidates,
            size_threshold=args.struct_size_threshold,
            clone_timeout=args.clone_timeout,
            probe_timeout=max(8.0, args.fuzz_timeout),
        ),
        "linker_strip": lambda: run_linker_strip_experiment(out_dir=out_dir, ldc2=ldc2),
        "ast_field_order": lambda: run_ast_field_order_experiment(
            out_dir=out_dir,
            dmd_repo=dmd_repo,
            host_dmd=dmd,
            rdmd_bin=rdmd_bin,
            benchmark_file=benchmark_file,
            seeds=parse_int_list(args.ast_seeds),
            runs=args.ast_runs,
            warmups=args.ast_warmups,
            build_timeout_sec=args.build_timeout,
            compile_timeout_sec=max(args.task_timeout, 300.0),
        ),
        "parser_parallel": lambda: run_parallel_parser_experiment(
            out_dir=out_dir,
            dmd=dmd,
            file_count=max(parser_file_counts),
            thread_values=parse_int_list(args.parser_threads),
            repeats=args.parser_repeats,
            timeout_sec=max(args.task_timeout, 90.0),
        ),
        "parser_incompiler_parallel": lambda: run_incompiler_parser_parallel_experiment(
            out_dir=out_dir,
            dmd=dmd,
            file_counts=parser_file_counts,
            thread_values=parse_int_list(args.parser_threads),
            repeats=args.parser_repeats,
            timeout_sec=max(args.task_timeout, 180.0),
            lock_mode=args.parser_lock_mode,
            diagnostics=args.parser_diagnostics,
        ),
        "allocator_compare": lambda: run_allocator_compare(
            out_dir=out_dir,
            dmd=dmd,
            benchmark_file=benchmark_file,
            runs=args.allocator_runs,
            warmups=args.allocator_warmups,
            timeout_sec=max(args.task_timeout, 120.0),
        ),
        "c_vs_d_asm": lambda: run_c_vs_d_asm_experiment(out_dir=out_dir, ldc2=ldc2, clang=clang),
        "dmd_profile_compare": lambda: run_dmd_profile_compare(
            out_dir=out_dir,
            dmd=dmd,
            timeout_sec=max(args.task_timeout, 180.0),
            perf_bin=perf_bin,
        ),
        "compiler_fuzz": lambda: run_fuzz_experiment(
            out_dir=out_dir,
            dmd=dmd,
            dmd_repo=dmd_repo,
            iterations=args.fuzz_iters,
            timeout_sec=args.fuzz_timeout,
            seed=args.fuzz_seed,
        ),
        "large_char_array": lambda: run_large_char_array_experiment(out_dir=out_dir, ldc2=ldc2),
    }

    label_by_key = {
        "perfetto": "perfetto screenshot",
        "zero_cost": "zero-cost abstraction",
        "phobos_sections": "phobos section size analysis",
        "gc_kernels": "GC kernels",
        "aa_kernels": "associative-array kernels",
        "float_to_string_kernels": "float-to-string kernels",
        "dub_pgo": "dub PGO benchmark",
        "non_zero_init_structs": "large non-zero-init struct scan",
        "linker_strip": "linker strip behavior",
        "ast_field_order": "AST field-order cache-locality",
        "parser_parallel": "parallel lexer/parser",
        "parser_incompiler_parallel": "in-compiler parser threading",
        "allocator_compare": "allocator replacement",
        "c_vs_d_asm": "C vs D assembly",
        "dmd_profile_compare": "dmd -profile comparison",
        "compiler_fuzz": "compiler fuzz",
        "large_char_array": "char[] > 4GB probe",
    }

    results: list[dict[str, object]] = []
    for idx, task_key in enumerate(selected_tasks, start=1):
        print(f"[{idx}/{len(selected_tasks)}] {label_by_key.get(task_key, task_key)}")
        t0 = time.perf_counter_ns()
        try:
            result = task_funcs[task_key]()
        except Exception as exc:
            result = task_result(task_key, "failed", reason=f"exception: {exc}")
        elapsed_ms = (time.perf_counter_ns() - t0) / 1_000_000.0
        result["elapsed_ms"] = round(elapsed_ms, 3)
        result["task_key"] = task_key
        results.append(result)

    write_csv_dynamic(out_dir / "status.csv", results)
    render_status_report(out_dir / "status.md", results)
    render_runtime_libs_report(out_dir, results)

    manifest["results_count"] = len(results)
    manifest["completed_at"] = now_utc()
    write_json(out_dir / "manifest.json", manifest)

    print(f"Artifacts written to: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
