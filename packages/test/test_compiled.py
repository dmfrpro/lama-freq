import os
from pathlib import Path
import struct
import subprocess

import pytest

from toolchain import compile_lama
from helpers import check_oracle
from oracle import NAMES, OPERANDS, decode

UNSUPPORTED_BY_UPSTREAM_DISASSEMBLER = frozenset({0x13, 0x17, *range(0x30, 0x34)})
COMPILER_LIMITATIONS = {"test054", "test110"}


def regression_names():
    root = os.environ.get("LAMA_DIR")
    if not root:
        return []
    return sorted(path.stem for path in (Path(root) / "regression").glob("test*.lama"))


def linear_instructions(data):
    _, strings_size, _, imports_count, publics_count = struct.unpack_from("<5i", data, 4)
    code_start = 24 + strings_size + imports_count * 4 + publics_count * 9
    code = data[code_start:]
    result = []
    offset = 0
    while offset < len(code):
        current = decode(code, offset)
        result.append(current)
        offset = current["next"]
        if current["opcode"] == 0xFF:
            break
    assert result and offset == len(code) and result[-1]["opcode"] == 0xFF
    return result


def disassembly_arguments(current):
    opcode = current["opcode"]
    values = current["values"]
    if opcode in (0x11, 0x59, 0x5A):
        return None
    if opcode in (0x12, 0x57):
        return [str(values[1])]
    arguments = []
    for kind, value in zip(OPERANDS.get(opcode, ""), values):
        arguments.append(f"0x{value & 0xFFFFFFFF:08x}" if kind == "t" else str(value))
    if opcode == 0x54:
        position = 9
        for _ in range(values[1]):
            capture = struct.unpack_from("<i", current["raw"], position + 1)[0]
            arguments.extend((str(current["raw"][position]), str(capture)))
            position += 5
    return arguments


def check_upstream_disassembly(path, data, environment):
    instructions = linear_instructions(data)
    if any(current["opcode"] in UNSUPPORTED_BY_UPSTREAM_DISASSEMBLER for current in instructions):
        return
    result = subprocess.run(
        [environment["LAMAVM"], "--disassemble", str(path)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    lines = result.stdout.splitlines()
    disassembly = lines[lines.index("Code:") + 1 :]
    assert len(disassembly) == len(instructions)
    for current, line in zip(instructions, disassembly):
        parts = line.split("\t", 2)
        offset = int(parts[0].removesuffix(":"), 16)
        assert offset == current["start"]
        assert parts[1] == NAMES[current["opcode"]]
        expected = disassembly_arguments(current)
        if expected is None:
            continue
        actual = parts[2].split() if len(parts) == 3 else []
        if current["opcode"] in (0x12, 0x57):
            actual = actual[-1:]
        assert actual == expected


def check_compiled_unit(source, name, run_analyzer, tmp_path, environment):
    compiled, bytecode = compile_lama(source, tmp_path, environment)
    if (
        compiled.returncode
        and name in COMPILER_LIMITATIONS
        and "Indirect assignment is not supported yet" in compiled.stderr
    ):
        pytest.skip("upstream compiler limitation: " + compiled.stderr.strip())
    assert compiled.returncode == 0, compiled.stderr
    data = bytecode.read_bytes()
    check_oracle(run_analyzer, data, root_zero=True)
    check_upstream_disassembly(bytecode, data, environment)


@pytest.mark.regression
@pytest.mark.parametrize("name", regression_names())
def test_upstream_regression(run_analyzer, lama_environment, tmp_path, name):
    source = Path(lama_environment["LAMA_DIR"]) / "regression" / f"{name}.lama"
    check_compiled_unit(source, name, run_analyzer, tmp_path, lama_environment)


@pytest.mark.performance
def test_sort_performance_unit(run_analyzer, lama_environment, tmp_path):
    source = Path(lama_environment["LAMA_SRC"]) / "performance" / "Sort.lama"
    check_compiled_unit(source, "Sort", run_analyzer, tmp_path, lama_environment)
