import json
import os
from pathlib import Path
import signal
import subprocess
import time
from dataclasses import dataclass, field
from typing import Sequence

ANALYSIS_FIELDS = {
    "reachable instructions": "reachable",
    "jump labels": "labels",
    "bigram occurrences": "bigrams",
    "sorting runs/merges": "sorting_runs",
    "largest sorting run set": "largest_run_set",
    "sorting merge rounds": "merge_rounds",
    "raw-key fallback": "raw_fallback",
    "temporary bytes written": "temporary_bytes",
}


def empty_usage_stats() -> dict[str, int]:
    return {
        "user_ns": 0,
        "system_ns": 0,
        "max_rss_kib": 0,
        "page_faults": 0,
        "ctx_switches": 0,
    }


@dataclass
class Result:
    returncode: int
    time_ns: int
    stdout: bytes
    stderr: bytes
    stats: dict[str, int] = field(default_factory=empty_usage_stats)
    timed_out: bool = False
    label: str = ""
    bytecode_bytes: int | None = None
    unique_sequences: int | None = None
    analysis: dict[str, int | str] = field(default_factory=dict)
    output_path: Path | None = None


def diagnostic(output: bytes | str) -> str:
    text = output.decode(errors="replace") if isinstance(output, bytes) else output
    return "\n".join(text.strip().splitlines()[-3:])


def ns_to_ms(value: int | None) -> float | None:
    return round(value / 1_000_000, 3) if value is not None else None


def kib_to_mib(value: int | None) -> float | None:
    return round(value / 1024, 2) if value is not None else None


def bytes_to_kib(value: int | None) -> float | None:
    return round(value / 1024, 2) if value is not None else None


def display_usage(stats: dict[str, int]) -> dict[str, int | float]:
    return {
        "user_ms": ns_to_ms(stats["user_ns"]),
        "system_ms": ns_to_ms(stats["system_ns"]),
        "peak_rss_mib": kib_to_mib(stats["max_rss_kib"]),
        "page_faults": stats["page_faults"],
        "ctx_switches": stats["ctx_switches"],
    }


def frequency_rows(output: str, limit: int | None = None) -> list[dict]:
    lines = output.splitlines()
    if limit is not None:
        lines = lines[:limit]
    result = []
    for rank, line in enumerate(lines, start=1):
        count, separator, sequence = line.partition("\t")
        if separator:
            result.append({"rank": rank, "count": int(count), "sequence": sequence})
    return result


def seconds_to_ns(value: float) -> int:
    return max(0, round(value * 1_000_000_000))


def usage_stats(path: Path) -> dict[str, int]:
    values = path.read_text().split()
    if len(values) != 7:
        raise RuntimeError(f"invalid GNU time output in {path}: {path.read_text()!r}")
    user, system = (float(value) for value in values[:2])
    max_rss, minor_faults, major_faults, voluntary, involuntary = map(int, values[2:])
    return {
        "user_ns": seconds_to_ns(user),
        "system_ns": seconds_to_ns(system),
        "max_rss_kib": max(0, max_rss),
        "page_faults": max(0, minor_faults + major_faults),
        "ctx_switches": max(0, voluntary + involuntary),
    }


def run_measurement(
    command: Sequence[str],
    output_path: Path,
    *,
    timeout: int,
    input_path: Path | None = None,
    cwd: Path | None = None,
) -> Result:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    error_path = output_path.with_suffix(output_path.suffix + ".err")
    usage_path = output_path.with_suffix(output_path.suffix + ".usage")
    timer = os.environ["TIME"]
    measured_command = [
        timer,
        "-q",
        "-o",
        str(usage_path),
        "-f",
        "%U %S %M %R %F %w %c",
        *command,
    ]
    stdin = input_path.open("rb") if input_path else subprocess.DEVNULL
    start = time.perf_counter_ns()
    timed_out = False

    try:
        with output_path.open("wb") as stdout, error_path.open("wb") as stderr:
            process = subprocess.Popen(
                measured_command,
                stdin=stdin,
                stdout=stdout,
                stderr=stderr,
                cwd=cwd,
                start_new_session=True,
            )
            while True:
                waited, status, _ = os.wait4(process.pid, os.WNOHANG)
                if waited:
                    break
                if time.perf_counter_ns() - start >= timeout * 1_000_000_000:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    _, status, _ = os.wait4(process.pid, 0)
                    timed_out = True
                    break
                time.sleep(0.001)

            process.returncode = 124 if timed_out else os.waitstatus_to_exitcode(status)
    finally:
        if input_path:
            stdin.close()

    return Result(
        process.returncode,
        time.perf_counter_ns() - start,
        output_path.read_bytes(),
        error_path.read_bytes(),
        empty_usage_stats() if timed_out else usage_stats(usage_path),
        timed_out=timed_out,
        output_path=output_path,
    )


def statistics(output: bytes | str) -> dict[str, int | str]:
    text = output.decode(errors="replace") if isinstance(output, bytes) else output
    result: dict[str, int | str] = {}
    for line in text.splitlines():
        name, separator, value = line.partition(": ")
        if not separator:
            continue
        number = value.split(maxsplit=1)[0]
        result[name] = int(number) if number.isdigit() else value
    return result


def render_report(sections: list[dict], summary: dict | None = None) -> None:
    report = {"sections": sections}
    if summary is not None:
        report["summary"] = [summary]
    subprocess.run(
        [os.environ["NU"], "--stdin", os.environ["TABLE_RENDERER"]],
        input=json.dumps(report),
        text=True,
        check=True,
    )
