from collections import Counter
import struct

NAMES = {
    **{
        i: name
        for i, name in enumerate(
            ["ADD", "SUB", "MUL", "DIV", "MOD", "LT", "LE", "GT", "GE", "EQ", "NE", "AND", "OR"], 1
        )
    },
    0x10: "CONST",
    0x11: "STRING",
    0x12: "SEXP",
    0x13: "STI",
    0x14: "STA",
    0x15: "JMP",
    0x16: "END",
    0x17: "RET",
    0x18: "DROP",
    0x19: "DUP",
    0x1A: "SWAP",
    0x1B: "ELEM",
    0x50: "CJMP_Z",
    0x51: "CJMP_NZ",
    0x52: "BEGIN",
    0x53: "BEGIN_CLOSURE",
    0x54: "CLOSURE",
    0x55: "CALLC",
    0x56: "CALL",
    0x57: "TAG",
    0x58: "ARRAY",
    0x59: "FAIL",
    0x5A: "FAIL_KEEP",
    0x5B: "LINE",
    0x60: "PATT_STR_CMP",
    0x61: "PATT_STRING",
    0x62: "PATT_ARRAY",
    0x63: "PATT_SEXP",
    0x64: "PATT_BOXED",
    0x65: "PATT_UNBOXED",
    0x66: "PATT_CLOSURE",
    0x74: "BARRAY",
    0xFF: "EOF",
}
for base, group in ((0x20, "LD"), (0x30, "LDA"), (0x40, "ST")):
    for kind, suffix in enumerate(("GLO", "LOC", "ARG", "CLO")):
        NAMES[base + kind] = f"{group}_{suffix}"

OPERANDS = {
    0x10: "i",
    0x11: "s",
    0x12: "si",
    0x15: "t",
    0x50: "t",
    0x51: "t",
    0x52: "ii",
    0x53: "iii",
    0x54: "ti",
    0x55: "i",
    0x56: "ti",
    0x57: "si",
    0x58: "i",
    0x59: "ii",
    0x5A: "ii",
    0x5B: "i",
    0x74: "i",
}
for base in (0x20, 0x30, 0x40):
    for kind in range(4):
        OPERANDS[base + kind] = "i"
FLOW = {
    0x15: "jump",
    0x16: "stop",
    0x17: "stop",
    0x50: "conditional",
    0x51: "conditional",
    0x54: "closure",
    0x55: "indirect",
    0x56: "call",
    0x59: "stop",
    0x5A: "stop",
    0xFF: "stop",
}


def i32(data, offset):
    return struct.unpack_from("<i", data, offset)[0]


def decode(code, offset):
    opcode = code[offset]
    if opcode not in NAMES:
        raise ValueError(f"unknown opcode {opcode:#x} at {offset}")
    position = offset + 1
    values = []
    for _ in OPERANDS.get(opcode, ""):
        values.append(i32(code, position))
        position += 4
    if opcode == 0x54:
        position += values[1] * 5
    return {
        "start": offset,
        "next": position,
        "raw": code[offset:position],
        "opcode": opcode,
        "values": values,
        "flow": FLOW.get(opcode, "next"),
        "target": values[0] if values else None,
    }


def analyze(data, root_zero=False):
    if data[:4] != b"LaMa":
        raise ValueError("bad magic")
    version, strings_size, _, imports_count, pubs_count = struct.unpack_from("<5i", data, 4)
    if version != 1:
        raise ValueError("bad version")
    strings_start = 24
    imports_start = strings_start + strings_size
    pubs_start = imports_start + imports_count * 4
    code_start = pubs_start + pubs_count * 9
    strings = data[strings_start:imports_start]
    code = data[code_start:]
    roots = [0] if root_zero else []
    for index in range(pubs_count):
        position = pubs_start + index * 9
        if data[position + 8] == 0:
            roots.append(i32(data, position + 4))

    reachable = set()
    labels = set()
    pending = list(roots)
    pending_closures = []
    indirect_calls = False
    while pending:
        offset = pending.pop()
        if offset in reachable:
            continue
        instruction = decode(code, offset)
        reachable.add(offset)
        flow = instruction["flow"]
        if flow == "indirect" and not indirect_calls:
            indirect_calls = True
            pending.extend(pending_closures)
            pending_closures.clear()
        if flow in ("next", "call", "closure", "conditional", "indirect"):
            pending.append(instruction["next"])
        if flow in ("jump", "conditional"):
            pending.append(instruction["target"])
            labels.add(instruction["target"])
        elif flow == "call" and instruction["target"] >= 0:
            pending.append(instruction["target"])
        elif flow == "closure" and instruction["target"] >= 0:
            if indirect_calls:
                pending.append(instruction["target"])
            else:
                pending_closures.append(instruction["target"])

    counts = Counter()
    previous = None
    for offset in sorted(reachable):
        current = decode(code, offset)
        counts[b"\x01" + current["raw"]] += 1
        if (
            previous is not None
            and previous["next"] == offset
            and previous["flow"] not in ("stop", "jump")
            and offset not in labels
        ):
            pair = b"\x02" + struct.pack("<I", len(previous["raw"]))
            counts[pair + previous["raw"] + current["raw"]] += 1
        previous = current
    return counts, strings


def escaped_string(strings, offset):
    end = strings.index(0, offset)
    result = '"'
    for byte in strings[offset:end]:
        result += {0x22: '\\"', 0x5C: "\\\\", 0x0A: "\\n", 0x0D: "\\r", 0x09: "\\t"}.get(
            byte, chr(byte) if 0x20 <= byte <= 0x7E else f"\\x{byte:02x}"
        )
    return result + '"'


def format_instruction(raw, strings):
    opcode = raw[0]
    position = 1
    fields = []
    values = []
    for kind in OPERANDS.get(opcode, ""):
        value = i32(raw, position)
        values.append(value)
        position += 4
        fields.append(escaped_string(strings, value) if kind == "s" else str(value))
    if opcode == 0x54:
        for _ in range(values[1]):
            kind = raw[position]
            value = i32(raw, position + 1)
            fields.extend((str(kind), str(value)))
            position += 5
    return NAMES[opcode] + (" " + " ".join(fields) if fields else "")


def format_key(key, strings):
    if key[0] == 1:
        return format_instruction(key[1:], strings)
    left_size = struct.unpack_from("<I", key, 1)[0]
    left = format_instruction(key[5 : 5 + left_size], strings)
    right = format_instruction(key[5 + left_size :], strings)
    return f"{left} ; {right}"


def expected_output(data, root_zero=False):
    counts, strings = analyze(data, root_zero)
    return "".join(
        f"{count}\t{format_key(key, strings)}\n"
        for key, count in sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    )
