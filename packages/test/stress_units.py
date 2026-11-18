import os
import random

from isa_cases import begin, const, i32, instruction, public_main
import make_bad_bc as bad


def write_main_header(output):
    output.write(bad.hdr(b"main\0", pubs=[(0, 0, 0)]))
    output.write(b"main\0")
    output.write(i32(0, 0) + bytes([0]))


def write_dense_linear(path, code_size, pair=None, locals_=0):
    if pair is None:
        pair = const(0) + bytes([0x18])
    suffix = instruction(0x5B, 0) * 3 + const(0) + bytes([0x16, 0xFF])
    pairs, remainder = divmod(code_size - len(begin()) - len(suffix), len(pair))
    assert remainder == 0
    chunk_pairs = 1 << 20
    chunk = pair * chunk_pairs
    with path.open("wb") as output:
        write_main_header(output)
        output.write(begin(locals_=locals_))
        remaining = pairs
        while remaining >= chunk_pairs:
            output.write(chunk)
            remaining -= chunk_pairs
        output.write(pair * remaining)
        output.write(suffix)
        assert output.tell() == 24 + 5 + 9 + code_size
    return pairs


def write_repeated_calls(path, code_size):
    pairs, remainder = divmod(code_size - 47, 10)
    assert remainder == 0
    target = 10 * pairs + 31
    pair = instruction(0x56, target, 0) + bytes([0x18])
    suffix = instruction(0x5B, 0) * 3 + const(0) + bytes([0x16])
    callee = begin() + const(0) + bytes([0x16])
    chunk_pairs = 1 << 20
    chunk = pair * chunk_pairs
    with path.open("wb") as output:
        write_main_header(output)
        output.write(begin())
        remaining = pairs
        while remaining >= chunk_pairs:
            output.write(chunk)
            remaining -= chunk_pairs
        output.write(pair * remaining)
        output.write(suffix)
        output.write(bytes([0x77]))
        assert output.tell() == 38 + target
        output.write(callee + bytes([0xFF]))
        assert output.tell() == 24 + 5 + 9 + code_size
    return pairs, target


def write_repeated_closures(path, code_size):
    pairs, remainder = divmod(code_size - 47, 10)
    assert remainder == 0
    target = 10 * pairs + 27
    pair = instruction(0x54, target, 0) + bytes([0x18])
    suffix = const(0) + instruction(0x55, 0) + bytes([0x16])
    callee = bytes([0x53]) + i32(0, 0, 0) + const(0) + bytes([0x16])
    chunk_pairs = 1 << 20
    chunk = pair * chunk_pairs
    with path.open("wb") as output:
        write_main_header(output)
        output.write(begin())
        remaining = pairs
        while remaining >= chunk_pairs:
            output.write(chunk)
            remaining -= chunk_pairs
        output.write(pair * remaining)
        output.write(suffix)
        output.write(bytes([0x77]) * 7)
        assert output.tell() == 38 + target
        output.write(callee + bytes([0xFF]))
        assert output.tell() == 24 + 5 + 9 + code_size
    return pairs, target


def write_shuffled_cfg(path, code_size):
    labels = [len(begin()) + 10 * index for index in range(16)]
    order = list(range(16))
    random.Random(0).shuffle(order)
    targets = [labels[index] for index in order]
    suffix = instruction(0x5B, 0) + const(0) + bytes([0x18]) + const(0) + bytes([0x16, 0xFF])
    blocks, remainder = divmod(code_size - len(begin()) - len(suffix), 10)
    assert remainder == 0
    blocks_per_chunk = 1 << 16
    pattern = b"".join(const(0) + instruction(0x50, target) for target in targets)
    chunk = pattern * blocks_per_chunk
    chunk_blocks = 16 * blocks_per_chunk
    with path.open("wb") as output:
        write_main_header(output)
        output.write(begin())
        remaining = blocks
        while remaining >= chunk_blocks:
            output.write(chunk)
            remaining -= chunk_blocks
        output.write(pattern * (remaining // 16))
        output.write(b"".join(const(0) + instruction(0x50, target) for target in targets[: remaining % 16]))
        output.write(suffix)
        assert output.tell() == 24 + 5 + 9 + code_size
    return blocks, targets


def write_near_zero(path, code_size):
    prefix = begin() + const(0) + bytes([0x16])
    remaining = code_size - len(prefix) - 1
    payload = random.Random(0).randbytes(min(remaining, 1 << 20))
    with path.open("wb") as output:
        write_main_header(output)
        output.write(prefix)
        while remaining:
            size = min(remaining, len(payload))
            output.write(payload[:size])
            remaining -= size
        output.write(bytes([0xFF]))
        assert output.tell() == 24 + 5 + 9 + code_size


def make_worklist(path, branches=(1 << 20) + 17):
    targets_start = 9 + 10 * branches + 6
    code = bytearray(begin())
    for index in range(branches):
        code += const(0) + instruction(0x50, targets_start + 6 * index)
    code += const(0) + bytes([0x16])
    code += (const(0) + bytes([0x16])) * branches + bytes([0xFF])
    path.write_bytes(public_main(bytes(code)))
    return branches


def make_pending_closures(path, count=(1 << 20) + 17):
    code = bytearray(begin())
    code += (instruction(0x54, 0, 0) + bytes([0x18])) * count
    code += const(0) + instruction(0x55, 0) + bytes([0x16, 0xFF])
    path.write_bytes(public_main(bytes(code)))
    return count


def make_large_closure(path, captures=120000):
    target = 19 + 5 * captures
    code = (
        begin(0, 1)
        + instruction(0x54, target, captures)
        + (bytes([1]) + i32(0)) * captures
        + bytes([0x16, 0x53])
        + i32(0, 0, captures)
        + const(1)
        + bytes([0x16, 0xFF])
    )
    path.write_bytes(public_main(code))


def make_dense_external(path, count=None):
    if count is None:
        count = int(os.environ.get("LAMA_FREQ_DENSE_STRESS", "200000"))
    unit = public_main(
        begin()
        + b"".join(const(value) + const(1) + bytes([0x19, 0x18, 0x18, 0x18]) for value in range(count))
        + const(1)
        + bytes([0x16, 0xFF])
    )
    path.write_bytes(unit)


def make_fallback_replay(path, functions=(1 << 20) + 16, unique=40000):
    code = bytearray()
    strings = bytearray()
    publics = []
    for index in range(functions):
        name_offset = len(strings)
        strings += f"f{index}".encode() + b"\0"
        code_offset = len(code)
        code += begin()
        if index == 16:
            code += b"".join(const(value) + bytes([0x18]) for value in range(unique)) + const(0)
        elif index >= 1 << 20:
            code += const(999)
        else:
            code += const(0)
        code += bytes([0x16])
        publics.append((name_offset, code_offset, 0))
    code += bytes([0xFF])
    path.write_bytes(bad.with_code(bytes(code), strings=bytes(strings), pubs=publics))


def make_deferred_joins(path, count=16000):
    code = bytearray(begin())
    for index in range(count):
        code += const(0) + instruction(0x50, 9 + 10 * index)
    code += const(0) + bytes([0x16, 0xFF])
    path.write_bytes(public_main(bytes(code)))
    return count
