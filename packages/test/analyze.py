#!/usr/bin/env python3

import argparse
import os
from pathlib import Path
import shutil
import sys
import tempfile

from freq_report import (
    ANALYSIS_FIELDS,
    bytes_to_kib,
    diagnostic,
    display_usage,
    frequency_rows,
    kib_to_mib,
    ns_to_ms,
    render_report,
    run_measurement,
    statistics,
)


def find_input(value: str) -> Path:
    path = Path(value).expanduser()
    if path.is_file():
        return path.resolve()

    candidates = []
    if not path.suffix:
        candidates.extend(
            (
                Path(f"{value}.bc"),
                Path(f"{value}.lama"),
                Path(os.environ["LAMA_DIR"]) / "regression" / f"{value}.lama",
                Path(os.environ["LAMA_SRC"]) / "performance" / f"{value}.lama",
            )
        )

    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise SystemExit(f"input not found: {value} (expected a .bc, .lama, or upstream test name)")


def compile_source(source: Path, work: Path, timeout: int):
    lamac = os.environ["LAMAC"]
    lama_dir = Path(os.environ["LAMA_DIR"])
    name = source.stem
    shutil.copyfile(source, work / f"{name}.lama")
    result = run_measurement(
        [
            lamac,
            "-I",
            str(lama_dir / "runtime"),
            "-I",
            str(lama_dir / "stdlib/x64"),
            "-b",
            f"{name}.lama",
        ],
        work / f"{name}.compile.log",
        timeout=timeout,
        cwd=work,
    )
    result.label = "compile"
    return work / f"{name}.bc", result


def analysis_rows(result, resources=False) -> list[dict]:
    core = ["reachable instructions", "jump labels", "bigram occurrences"]
    fields = (
        list(ANALYSIS_FIELDS)
        if resources
        else core
        + [name for name in ANALYSIS_FIELDS if name not in core and result.analysis.get(name) not in (None, 0, "no")]
    )
    return [{"statistic": source, "value": result.analysis[source]} for source in fields if source in result.analysis]


def process_row(name, run, result):
    return {
        "input": name,
        "run": run,
        "wall_ms": ns_to_ms(result.time_ns),
        **display_usage(result.stats),
    }


def compact_row(name, status, details, result=None, bytecode=None, counter=None):
    row = {
        "input": name,
        "status": status,
        "bytecode_kib": bytes_to_kib(bytecode.stat().st_size if bytecode else None),
        "sequences": result.unique_sequences if result else None,
        "counter": counter,
        "time_ms": ns_to_ms(result.time_ns) if result else None,
        "peak_rss_mib": kib_to_mib(result.stats["max_rss_kib"]) if result else None,
    }
    if status == "FAIL":
        row["diagnostic"] = details
    return row


def inspect(args, work: Path) -> int:
    source = find_input(args.input)
    name = source.stem
    compiled = None
    performance = []

    if source.suffix == ".lama":
        bytecode, compiled = compile_source(source, work, args.timeout)
        if args.resources:
            performance.append(process_row(name, "compile", compiled))
        if compiled.returncode:
            details = "compilation timed out" if compiled.timed_out else diagnostic(compiled.stderr)
            row = compact_row(name, "FAIL", details, compiled)
            render_report(
                [{"title": "Manual analysis", "results": [row], "performance": performance}],
                {"passed": 0, "failed": 1},
            )
            return 1
    else:
        bytecode = source

    analyzer = os.environ["ANALYZER"]
    temporary = work / "tmp"
    temporary.mkdir(exist_ok=True)
    command = [analyzer, "--stats"]
    if not args.public_only:
        command.append("--root-zero")
    if args.raw_counter:
        command.append("--raw-counter")
    if args.memory_limit_mib:
        command.extend(("--memory-limit-mib", str(args.memory_limit_mib)))
    command.extend(("--temp-dir", str(temporary), str(bytecode)))

    output_path = work / f"{name}.freq"
    result = run_measurement(command, output_path, timeout=args.timeout)
    result.label = "raw" if args.raw_counter else "interned"
    result.bytecode_bytes = bytecode.stat().st_size
    result.analysis = statistics(result.stderr)
    if "reachable instructions" not in result.analysis:
        result.analysis = {}
    if args.resources:
        performance.append(process_row(name, result.label, result))

    output = result.stdout.decode(errors="replace")
    if result.returncode == 0:
        result.unique_sequences = len(output.splitlines())
        details = ""
        status = "PASS"
    else:
        details = "analysis timed out" if result.timed_out else diagnostic(result.stderr)
        status = "FAIL"

    row = compact_row(
        name,
        status,
        details,
        result,
        bytecode,
        result.label,
    )
    sections = [
        {
            "title": "Manual analysis",
            "results": [row],
            "performance": performance,
            "analysis": analysis_rows(result, args.resources),
        }
    ]

    if result.returncode == 0 and args.limit:
        sections.append(
            {
                "title": "Most frequent sequences",
                "results": frequency_rows(output, args.limit),
            }
        )

    render_report(sections, {"passed": int(status == "PASS"), "failed": int(status == "FAIL")})
    return int(status == "FAIL")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze one Lama unit and render statistics and frequent sequences")
    parser.add_argument("input", help=".bc, .lama, regression name, or performance name")
    parser.add_argument("--work", type=Path, help="retain bytecode, logs, and complete output")
    parser.add_argument(
        "--resources",
        action="store_true",
        help="show all analyzer diagnostics and per-process resource usage",
    )
    parser.add_argument("--public-only", action="store_true", help="do not add offset zero as a root")
    parser.add_argument("--raw-counter", action="store_true")
    parser.add_argument("--memory-limit-mib", type=int)
    parser.add_argument("--limit", type=int, default=20, help="top sequences to display; 0 hides them")
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("ANALYZE_TIMEOUT", "120")),
    )
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be nonnegative")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    temporary = None
    if args.work:
        work = args.work.resolve()
        work.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="lama-freq-analyze-")
        work = Path(temporary.name)

    try:
        return inspect(args, work)
    finally:
        if temporary:
            temporary.cleanup()


if __name__ == "__main__":
    sys.exit(main())
