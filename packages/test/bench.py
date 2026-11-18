#!/usr/bin/env python3

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import sys

from freq_report import diagnostic, ns_to_ms, render_report, run_measurement
from isa_cases import instruction
import make_bad_bc as bad
from stress_units import (
    make_dense_external,
    make_deferred_joins,
    make_fallback_replay,
    make_large_closure,
    make_pending_closures,
    make_worklist,
    write_dense_linear,
    write_near_zero,
    write_repeated_calls,
    write_repeated_closures,
    write_shuffled_cfg,
)
from toolchain import compile_lama

CODE_SIZE = (1 << 31) - 1


@dataclass(frozen=True)
class Benchmark:
    suite: str
    name: str
    builder: object
    arguments: tuple[str, ...] = ()
    timeout: int = 300


def compile_sort(path):
    source = Path(os.environ["LAMA_SRC"]) / "performance" / "Sort.lama"
    result, bytecode = compile_lama(source, path.parent / "compile", os.environ)
    if result.returncode:
        raise RuntimeError("Sort compilation failed: " + diagnostic(result.stderr))
    shutil.copyfile(bytecode, path)


def make_sparse(path):
    path.write_bytes(bad.hdr())
    with path.open("r+b") as output:
        output.seek(24 + CODE_SIZE - 1)
        output.write(bytes([0xFF]))


def make_variables(path):
    write_dense_linear(path, CODE_SIZE, pair=instruction(0x21, 0) + bytes([0x18]), locals_=1)


BENCHMARKS = (
    Benchmark("performance", "Sort", compile_sort, ("--root-zero",)),
    Benchmark("stress", "worklist_ram", make_worklist),
    Benchmark("stress", "pending_closures", make_pending_closures),
    Benchmark("stress", "large_closure", make_large_closure, ("--memory-limit-mib", "64")),
    Benchmark("stress", "dense_external", make_dense_external, ("--memory-limit-mib", "64")),
    Benchmark("stress", "fallback_replay", make_fallback_replay, ("--memory-limit-mib", "1")),
    Benchmark("stress", "deferred_joins", make_deferred_joins),
    Benchmark("stress-full", "sparse_2gib", make_sparse, timeout=1800),
    Benchmark("stress-full", "near_zero_2gib", lambda path: write_near_zero(path, CODE_SIZE), timeout=1800),
    Benchmark(
        "stress-full",
        "dense_2gib",
        lambda path: write_dense_linear(path, CODE_SIZE),
        timeout=1800,
    ),
    Benchmark("stress-full", "variables_2gib", make_variables, timeout=1800),
    Benchmark(
        "stress-full",
        "calls_2gib",
        lambda path: write_repeated_calls(path, CODE_SIZE),
        timeout=1800,
    ),
    Benchmark(
        "stress-full",
        "closures_2gib",
        lambda path: write_repeated_closures(path, CODE_SIZE),
        timeout=1800,
    ),
    Benchmark(
        "stress-full",
        "shuffled_2gib",
        lambda path: write_shuffled_cfg(path, CODE_SIZE),
        timeout=1800,
    ),
)


def memory_mb(kib):
    return round(kib * 1024 / 1_000_000, 3)


def prepare_input(benchmark, work, regenerate):
    bytecode = work / "inputs" / benchmark.suite / f"{benchmark.name}.bc"
    bytecode.parent.mkdir(parents=True, exist_ok=True)
    if not regenerate and bytecode.is_file():
        print(f"  reusing {bytecode}", file=sys.stderr, flush=True)
        return bytecode

    print(f"  generating {bytecode}", file=sys.stderr, flush=True)
    partial = bytecode.with_suffix(".partial")
    if partial.exists():
        partial.unlink()
    benchmark.builder(partial)
    partial.replace(bytecode)
    return bytecode


def run_benchmark(benchmark, work, timeout, regenerate):
    directory = work / benchmark.suite / benchmark.name
    directory.mkdir(parents=True, exist_ok=True)
    row = {"benchmark": benchmark.name, "status": "completed"}
    try:
        bytecode = prepare_input(benchmark, work, regenerate)
        print(f"  measuring {benchmark.name}", file=sys.stderr, flush=True)
        temporary = directory / "tmp"
        temporary.mkdir(exist_ok=True)
        result = run_measurement(
            [os.environ["ANALYZER"], "--temp-dir", str(temporary), *benchmark.arguments, str(bytecode)],
            directory / "output.txt",
            timeout=timeout or benchmark.timeout,
        )
        row.update(
            {
                "input_mb": round(bytecode.stat().st_size / 1_000_000, 3),
                "cpu_ms": ns_to_ms(result.stats["user_ns"] + result.stats["system_ns"]),
                "memory_mb": memory_mb(result.stats["max_rss_kib"]),
            }
        )
        if result.returncode:
            row["status"] = "failed"
            row["diagnostic"] = "timed out" if result.timed_out else diagnostic(result.stderr)
    except Exception as error:
        row.update({"status": "failed", "diagnostic": str(error)})
    return row


def main():
    parser = argparse.ArgumentParser(
        description="Measure analyzer CPU time and peak memory without checking frequencies"
    )
    parser.add_argument("suite", nargs="?", default="all", choices=("all", "performance", "stress", "stress-full"))
    parser.add_argument("name", nargs="?", help="run only this exact benchmark name")
    parser.add_argument(
        "--work",
        type=Path,
        default=Path("tmp/bench"),
        help="persistent input/output cache (default: tmp/bench)",
    )
    parser.add_argument("--regenerate", action="store_true", help="regenerate inputs even when cached files exist")
    parser.add_argument("--timeout", type=int, help="override each analyzer timeout in seconds")
    args = parser.parse_args()
    if args.timeout is not None and args.timeout <= 0:
        parser.error("--timeout must be positive")

    selected = [benchmark for benchmark in BENCHMARKS if args.suite in ("all", benchmark.suite)]
    if args.name:
        selected = [benchmark for benchmark in selected if benchmark.name == args.name]
    if not selected:
        parser.error("no benchmarks selected")

    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    rows = []
    for index, benchmark in enumerate(selected, 1):
        print(f"[{index}/{len(selected)}] {benchmark.name}", file=sys.stderr, flush=True)
        row = run_benchmark(benchmark, work, args.timeout, args.regenerate)
        rows.append((benchmark.suite, row))
    sections = [
        {
            "title": suite,
            "results": [row for row_suite, row in rows if row_suite == suite],
        }
        for suite in dict.fromkeys(suite for suite, _ in rows)
    ]
    render_report(
        sections,
        {
            "completed": sum(row["status"] == "completed" for _, row in rows),
            "failed": sum(row["status"] == "failed" for _, row in rows),
        },
    )
    return int(any(row["status"] == "failed" for _, row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
