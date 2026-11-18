import make_bad_bc as bad


def i32(*values):
    return b"".join(bad.i32(value) for value in values)


def instruction(opcode, *operands):
    return bytes([opcode]) + i32(*operands)


def begin(args=0, locals_=0):
    return instruction(0x52, args, locals_)


def begin_closure(args=0, locals_=0, captures=0):
    return instruction(0x53, args, locals_, captures)


def const(value):
    return instruction(0x10, value)


def public_main(code):
    return bad.with_code(code, strings=b"main\0", pubs=[(0, 0, 0)])


def conformance_cases():
    result = []

    def add_code(name, opcode, code, strings=b"main\0", globals_=0):
        result.append((name, opcode, bad.with_code(code, strings=strings, globals_=globals_, pubs=[(0, 0, 0)])))

    def add(name, opcode, body, *, args=0, locals_=0, captures=0, closure_entry=False, strings=b"main\0", globals_=0):
        entry = begin_closure(args, locals_, captures) if closure_entry else begin(args, locals_)
        add_code(name, opcode, entry + body + bytes([0x16, 0xFF]), strings, globals_)

    for opcode, name in enumerate(
        ["ADD", "SUB", "MUL", "DIV", "MOD", "LT", "LE", "GT", "GE", "EQ", "NE", "AND", "OR"], 1
    ):
        add(name, opcode, const(6) + const(3) + bytes([opcode]))

    add("CONST", 0x10, const(-123))
    add("STRING", 0x11, instruction(0x11, 5), strings=b"main\0text\0")
    add("SEXP", 0x12, const(1) + const(2) + instruction(0x12, 5, 2), strings=b"main\0cons\0")
    add("STI", 0x13, instruction(0x30, 0) + const(7) + bytes([0x13]), globals_=1)
    add("STA", 0x14, instruction(0x74, 0) + const(0) + const(9) + bytes([0x14]))
    add("JMP", 0x15, instruction(0x15, 14) + const(0))
    add("END", 0x16, const(0))
    add_code("RET", 0x17, begin() + const(1) + bytes([0x17, 0xFF]))
    add("DROP", 0x18, const(1) + bytes([0x18]) + const(0))
    add("DUP", 0x19, const(1) + bytes([0x19, 0x01]))
    add("SWAP", 0x1A, const(1) + const(2) + bytes([0x1A, 0x02]))
    add("ELEM", 0x1B, instruction(0x74, 0) + const(0) + bytes([0x1B]))

    for base, group in ((0x20, "LD"), (0x30, "LDA"), (0x40, "ST")):
        for kind, suffix in enumerate(("GLO", "LOC", "ARG", "CLO")):
            name = f"{group}_{suffix}"
            body = const(7) if group == "ST" else b""
            add(
                name,
                base + kind,
                body + bytes([base + kind]) + i32(0),
                args=int(kind == 2),
                locals_=int(kind == 1),
                captures=int(kind == 3),
                closure_entry=kind == 3,
                globals_=int(kind == 0),
            )

    for opcode, name in ((0x50, "CJMP_Z"), (0x51, "CJMP_NZ")):
        add(name, opcode, const(0) + instruction(opcode, 19) + const(1))

    add("BEGIN", 0x52, const(0))
    add("BEGIN_CLOSURE", 0x53, const(0), closure_entry=True)
    closure_code = (
        begin(0, 1)
        + instruction(0x54, 29, 1)
        + bytes([1])
        + i32(0)
        + instruction(0x55, 0)
        + bytes([0x16])
        + begin_closure(0, 0, 1)
        + instruction(0x23, 0)
        + bytes([0x16, 0xFF])
    )
    add_code("CLOSURE", 0x54, closure_code)
    add_code("CALLC", 0x55, closure_code)
    call_code = begin() + instruction(0x56, 19, 0) + bytes([0x16]) + begin() + const(8) + bytes([0x16, 0xFF])
    add_code("CALL", 0x56, call_code)
    add("TAG", 0x57, const(0) + instruction(0x57, 5, 0), strings=b"main\0tag\0")
    add("ARRAY", 0x58, const(0) + instruction(0x58, 0))
    add_code("FAIL", 0x59, begin() + const(0) + instruction(0x59, 10, 20) + bytes([0xFF]))
    add_code("FAIL_KEEP", 0x5A, begin() + const(0) + instruction(0x5A, 10, 20) + bytes([0xFF]))
    add("LINE", 0x5B, instruction(0x5B, 123) + const(0))

    for opcode, name in (
        (0x60, "PATT_STR_CMP"),
        (0x61, "PATT_STRING"),
        (0x62, "PATT_ARRAY"),
        (0x63, "PATT_SEXP"),
        (0x64, "PATT_BOXED"),
        (0x65, "PATT_UNBOXED"),
        (0x66, "PATT_CLOSURE"),
    ):
        body = const(1) + const(2) if opcode == 0x60 else const(0)
        add(name, opcode, body + bytes([opcode]))

    add("BARRAY", 0x74, const(1) + const(2) + instruction(0x74, 2))
    return result


CASES = conformance_cases()
