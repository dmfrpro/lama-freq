from collections import Counter
import random

import pytest

from helpers import check_oracle, frequencies
from isa_cases import begin, const, instruction, public_main

pytestmark = pytest.mark.functional


def make_cfg(rng):
    kinds = [rng.choice(("jump", "conditional")) for _ in range(rng.randrange(2, 12))]
    starts = []
    offset = len(begin())
    for kind in kinds:
        starts.append(offset)
        offset += 10 if kind == "jump" else 15

    code = bytearray(begin())
    instructions = {0: (begin(), "BEGIN 0 0", "next", None)}
    for index, (start, kind) in enumerate(zip(starts, kinds)):
        target = rng.choice(starts)
        line = instruction(0x5B, index + 1)
        instructions[start] = (line, f"LINE {index + 1}", "next", None)
        code += line
        if kind == "jump":
            branch = instruction(0x15, target)
            instructions[start + 5] = (branch, f"JMP {target}", "jump", target)
            code += branch
        else:
            condition = const(0)
            branch = instruction(0x50, target)
            instructions[start + 5] = (condition, "CONST 0", "next", None)
            instructions[start + 10] = (branch, f"CJMP_Z {target}", "conditional", target)
            code += condition + branch

    instructions[offset] = (const(0), "CONST 0", "next", None)
    instructions[offset + 5] = (b"\x16", "END", "stop", None)
    code += const(0) + b"\x16\xff"
    return public_main(bytes(code)), instructions


def expected_frequencies(instructions):
    reachable = set()
    pending = [0]
    while pending:
        offset = pending.pop()
        if offset in reachable:
            continue
        reachable.add(offset)
        raw, _, flow, target = instructions[offset]
        if flow in ("next", "conditional"):
            pending.append(offset + len(raw))
        if flow in ("jump", "conditional"):
            pending.append(target)

    labels = {
        instruction[3]
        for offset, instruction in instructions.items()
        if offset in reachable and instruction[3] is not None
    }
    counts = Counter()
    for offset in reachable:
        raw, text, flow, _ = instructions[offset]
        counts[text] += 1
        right = offset + len(raw)
        if flow in ("next", "conditional") and right in reachable and right not in labels:
            counts[text + " ; " + instructions[right][1]] += 1
    return counts


def test_deterministic_random_cfgs(run_analyzer):
    rng = random.Random(712367)
    for index in range(100):
        unit, instructions = make_cfg(rng)
        output = check_oracle(run_analyzer, unit)
        assert frequencies(output) == expected_frequencies(instructions), f"CFG case {index}"
