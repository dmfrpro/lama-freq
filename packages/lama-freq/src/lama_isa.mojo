from std.collections import Array

from bytecode import BytecodeInstruction, BytecodeRoot

comptime FLOW_NEXT = 0
comptime FLOW_STOP = 1
comptime FLOW_JUMP = 2
comptime FLOW_CONDITIONAL = 3
comptime FLOW_CLOSURE = 4
comptime FLOW_INDIRECT = 5
comptime FLOW_CALL = 6

comptime STACK_DELTA = 0
comptime STACK_RESET = 1
comptime STACK_EXACT_ONE = 2

comptime OPCODE_BEGIN = 0x52
comptime OPCODE_BEGIN_CLOSURE = 0x53
comptime OPCODE_EOF = 0xFF

comptime OP_INTEGER = 105
comptime OP_STRING = 115
comptime OP_TARGET = 116
comptime OP_CALLABLE = 120
comptime OP_GLOBAL = 103
comptime OP_LOCAL = 108
comptime OP_ARGUMENT = 97
comptime OP_CAPTURE = 99
comptime OP_FIELD_COUNT = 102
comptime OP_ARGUMENT_COUNT = 110
comptime OP_CAPTURE_COUNT = 114
comptime OP_LENGTH = 122


struct Operation(ImplicitlyCopyable):
    var name: StaticString
    var operands: StaticString
    var flow: Int
    var pops: Int
    var pushes: Int
    var pop_operand: Int
    var stack_rule: Int
    var trailing_size: Int
    var trailing_count_operand: Int

    def __init__(
        out self,
        name: StaticString,
        operands: StaticString,
        flow: Int = FLOW_NEXT,
        pops: Int = 0,
        pushes: Int = 0,
        pop_operand: Int = -1,
        stack_rule: Int = STACK_DELTA,
        trailing_size: Int = 0,
        trailing_count_operand: Int = -1,
    ):
        self.name = name
        self.operands = operands
        self.flow = flow
        self.pops = pops
        self.pushes = pushes
        self.pop_operand = pop_operand
        self.stack_rule = stack_rule
        self.trailing_size = trailing_size
        self.trailing_count_operand = trailing_count_operand

    @always_inline
    def operand_count(self) -> Int:
        return self.operands.byte_length()

    @always_inline
    def fixed_size(self) -> Int:
        return 1 + 4 * self.operand_count()


@fieldwise_init
struct Context(Equatable, ImplicitlyCopyable):
    var owner: Int
    var depth: Int


@fieldwise_init
struct Root(BytecodeRoot, ImplicitlyCopyable):
    var offset: Int
    var closure: Bool

    def entry_offset(self) -> Int:
        return self.offset


@fieldwise_init
struct Instruction(BytecodeInstruction, Copyable):
    var start: Int
    var next: Int
    var opcode: Int
    var operands: Array[Int, 4]
    var flow: Int

    def offset(self) -> Int:
        return self.start

    def next_offset(self) -> Int:
        return self.next

    def falls_through(self) -> Bool:
        return self.flow != FLOW_STOP and self.flow != FLOW_JUMP

    def needs_ordered_validation(self) -> Bool:
        return self.flow == FLOW_JUMP or self.flow == FLOW_CONDITIONAL


def simple(
    name: StaticString, operands: StaticString, pops: Int = 0, pushes: Int = 0
) -> Operation:
    return Operation(name, operands, pops=pops, pushes=pushes)


def branch(
    opcode_name: StaticString, conditional: Bool, pops: Int
) -> Operation:
    return Operation(
        opcode_name,
        "t",
        FLOW_CONDITIONAL if conditional else FLOW_JUMP,
        pops=pops,
    )


def install_binary_handlers(mut table: Array[Operation, 256]):
    var names: Array[StaticString, 13] = [
        "ADD",
        "SUB",
        "MUL",
        "DIV",
        "MOD",
        "LT",
        "LE",
        "GT",
        "GE",
        "EQ",
        "NE",
        "AND",
        "OR",
    ]

    for index in range(len(names)):
        table[index + 1] = simple(names[index], "", 2, 1)


def install_variable_handlers(mut table: Array[Operation, 256]):
    var names: Array[StaticString, 12] = [
        "LD_GLO",
        "LD_LOC",
        "LD_ARG",
        "LD_CLO",
        "LDA_GLO",
        "LDA_LOC",
        "LDA_ARG",
        "LDA_CLO",
        "ST_GLO",
        "ST_LOC",
        "ST_ARG",
        "ST_CLO",
    ]
    var operands: Array[StaticString, 4] = ["g", "l", "a", "c"]

    for group in range(3):
        for kind in range(4):
            table[0x20 + 16 * group + kind] = simple(
                names[group * 4 + kind],
                operands[kind],
                1 if group == 2 else 0,
                1,
            )


def install_pattern_handlers(mut table: Array[Operation, 256]):
    var names: Array[StaticString, 7] = [
        "PATT_STR_CMP",
        "PATT_STRING",
        "PATT_ARRAY",
        "PATT_SEXP",
        "PATT_BOXED",
        "PATT_UNBOXED",
        "PATT_CLOSURE",
    ]

    for index in range(len(names)):
        table[0x60 + index] = simple(
            names[index], "", 2 if index == 0 else 1, 1
        )


def build_operation_handlers() -> Array[Operation, 256]:
    var table = Array[Operation, 256](fill=Operation("", ""))

    install_binary_handlers(table)
    install_variable_handlers(table)
    install_pattern_handlers(table)

    table[0x10] = simple("CONST", "i", pushes=1)
    table[0x11] = simple("STRING", "s", pushes=1)
    table[0x12] = Operation("SEXP", "sf", pushes=1, pop_operand=1)
    table[0x13] = simple("STI", "", 2, 1)
    table[0x14] = simple("STA", "", 3, 1)

    table[0x15] = branch("JMP", False, 0)
    table[0x16] = Operation("END", "", FLOW_STOP, stack_rule=STACK_EXACT_ONE)
    table[0x17] = Operation("RET", "", FLOW_STOP, stack_rule=STACK_EXACT_ONE)

    table[0x18] = simple("DROP", "", 1)
    table[0x19] = simple("DUP", "", 1, 2)
    table[0x1A] = simple("SWAP", "", 2, 2)
    table[0x1B] = simple("ELEM", "", 2, 1)

    table[0x50] = branch("CJMP_Z", True, 1)
    table[0x51] = branch("CJMP_NZ", True, 1)
    table[OPCODE_BEGIN] = Operation("BEGIN", "ii", stack_rule=STACK_RESET)
    table[OPCODE_BEGIN_CLOSURE] = Operation(
        "BEGIN_CLOSURE", "iii", stack_rule=STACK_RESET
    )
    table[0x54] = Operation(
        "CLOSURE",
        "xr",
        FLOW_CLOSURE,
        pushes=1,
        trailing_size=5,
        trailing_count_operand=1,
    )
    table[0x55] = Operation(
        "CALLC", "n", FLOW_INDIRECT, pops=1, pushes=1, pop_operand=0
    )
    table[0x56] = Operation("CALL", "xn", FLOW_CALL, pushes=1, pop_operand=1)
    table[0x57] = simple("TAG", "sf", 1, 1)
    table[0x58] = simple("ARRAY", "z", 1, 1)
    table[0x59] = Operation("FAIL", "ii", FLOW_STOP, pops=1)
    table[0x5A] = Operation("FAIL_KEEP", "ii", FLOW_STOP, pops=1, pushes=1)
    table[0x5B] = simple("LINE", "i")

    table[0x74] = Operation("BARRAY", "z", pushes=1, pop_operand=0)
    table[OPCODE_EOF] = Operation("EOF", "", FLOW_STOP)

    return table^


def is_entry(opcode: Int) -> Bool:
    return opcode == OPCODE_BEGIN or opcode == OPCODE_BEGIN_CLOSURE
