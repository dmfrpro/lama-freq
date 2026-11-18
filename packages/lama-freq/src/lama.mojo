from std.collections import Array, Set

from bytecode import BytecodeBackend, EDGE_BRANCH, EDGE_ENTRY, Edge
from lama_cache import LamaInstructionCache
from lama_isa import (
    Context,
    FLOW_CALL,
    FLOW_CLOSURE,
    FLOW_CONDITIONAL,
    FLOW_INDIRECT,
    FLOW_JUMP,
    Instruction,
    OP_ARGUMENT,
    OP_ARGUMENT_COUNT,
    OP_CALLABLE,
    OP_CAPTURE,
    OP_CAPTURE_COUNT,
    OP_FIELD_COUNT,
    OP_GLOBAL,
    OP_INTEGER,
    OP_LOCAL,
    OP_STRING,
    OP_TARGET,
    OPCODE_BEGIN,
    OPCODE_BEGIN_CLOSURE,
    OPCODE_EOF,
    Operation,
    Root,
    STACK_DELTA,
    STACK_EXACT_ONE,
    STACK_RESET,
    is_entry,
    build_operation_handlers,
)
from unit import Unit, load_i32


@always_inline
def checked_operation(
    unit: Unit, handlers: Array[Operation, 256], offset: Int
) raises -> Operation:
    if offset < 0 or offset >= unit.code_size():
        unit.fail(
            offset,
            "truncated instruction: need 1 bytes at code offset "
            + String(offset),
        )

    var opcode = Int(unit.code_byte(offset))
    var op = handlers[opcode]

    if op.name == "":
        unit.fail(offset, "unknown opcode " + String(opcode))

    return op


@always_inline
def decode_operands(
    unit: Unit, offset: Int, count: Int
) raises -> Array[Int, 4]:
    var fixed_size = 1 + 4 * count

    if fixed_size > unit.code_size() - offset:
        unit.fail(
            offset,
            "truncated instruction: need "
            + String(fixed_size)
            + " bytes at code offset "
            + String(offset),
        )

    var operands = Array[Int, 4](fill=0)

    for index in range(count):
        operands[index] = load_i32(
            unit.data, unit.code_start + offset + 1 + index * 4
        )

    return operands^


@always_inline
def decoded_end(
    unit: Unit,
    start: Int,
    fixed_end: Int,
    op: Operation,
    operands: Array[Int, 4],
) raises -> Int:
    if op.trailing_size == 0:
        return fixed_end

    var captures = operands[op.trailing_count_operand]

    if captures < 0:
        unit.fail(
            start,
            String(op.name)
            + " with negative capture count "
            + String(captures),
        )

    if captures > (unit.code_size() - fixed_end) // op.trailing_size:
        unit.fail(
            start,
            "truncated "
            + String(op.name)
            + " capture list ("
            + String(captures)
            + " entries)",
        )

    return fixed_end + captures * op.trailing_size


def decode_syntax(
    unit: Unit, handlers: Array[Operation, 256], offset: Int
) raises -> Instruction:
    var op = checked_operation(unit, handlers, offset)
    var operands = decode_operands(unit, offset, op.operand_count())
    var fixed_end = offset + op.fixed_size()
    var next = decoded_end(unit, offset, fixed_end, op, operands)

    return Instruction(
        offset, next, Int(unit.code_byte(offset)), operands^, op.flow
    )


@fieldwise_init
struct VariableBinding(ImplicitlyCopyable):
    var bound: Int
    var description: StaticString


def validate_global(unit: Unit, start: Int, value: Int) raises:
    if value < 0:
        _ = unit.external_string(value, start)
        return

    if value >= unit.globals_count:
        unit.fail(
            start,
            "global index "
            + String(value)
            + " is out of range [0, "
            + String(unit.globals_count)
            + ")",
        )


def enclosing_opcode(unit: Unit, context: Context, start: Int) raises -> Int:
    if context.owner < 0 or context.owner >= unit.code_size():
        unit.fail(start, "instruction is outside a function body")

    var opcode = Int(unit.code_byte(context.owner))

    if not is_entry(opcode):
        unit.fail(
            start, "invalid enclosing function offset " + String(context.owner)
        )

    return opcode


def variable_binding(
    unit: Unit, context: Context, kind: Int, opcode: Int
) -> VariableBinding:
    if kind == OP_ARGUMENT:
        return VariableBinding(
            load_i32(unit.data, unit.code_start + context.owner + 1), "argument"
        )

    if kind == OP_CAPTURE:
        var bound = 0

        if opcode == OPCODE_BEGIN_CLOSURE:
            bound = load_i32(unit.data, unit.code_start + context.owner + 9)

        return VariableBinding(bound, "capture")

    return VariableBinding(
        load_i32(unit.data, unit.code_start + context.owner + 5), "local"
    )


def validate_variable(
    unit: Unit,
    context: Context,
    start: Int,
    kind: Int,
    value: Int,
    capture: Bool,
) raises:
    if kind == OP_GLOBAL:
        validate_global(unit, start, value)
        return

    if value < 0:
        unit.fail(start, "negative variable index " + String(value))

    var opcode = enclosing_opcode(unit, context, start)
    var binding = variable_binding(unit, context, kind, opcode)

    if value >= binding.bound:
        unit.fail(
            start,
            String(binding.description)
            + " index "
            + String(value)
            + " is out of range [0, "
            + String(binding.bound)
            + ")"
            + (" in closure capture" if capture else ""),
        )


def validate_operand(
    unit: Unit,
    context: Context,
    instruction: Instruction,
    op: Operation,
    kind: Int,
    value: Int,
) raises:
    if kind == OP_INTEGER or kind == OP_TARGET:
        return

    if kind == OP_STRING:
        _ = unit.string_bytes(value, instruction.start)
        return

    if kind == OP_CALLABLE:
        if value < 0:
            _ = unit.external_string(value, instruction.start)

        return

    if (
        kind == OP_GLOBAL
        or kind == OP_LOCAL
        or kind == OP_ARGUMENT
        or kind == OP_CAPTURE
    ):
        validate_variable(unit, context, instruction.start, kind, value, False)
        return

    if value >= 0:
        return

    var description = "length"

    if kind == OP_FIELD_COUNT:
        description = "field count"
    elif kind == OP_ARGUMENT_COUNT:
        description = "argument count"
    elif kind == OP_CAPTURE_COUNT:
        description = "capture count"

    unit.fail(
        instruction.start,
        String(op.name) + " with negative " + description + " " + String(value),
    )


def validate_entry_counts(unit: Unit, instruction: Instruction) raises -> Bool:
    if instruction.opcode == OPCODE_BEGIN:
        if instruction.operands[0] < 0 or instruction.operands[1] < 0:
            unit.fail(
                instruction.start,
                "BEGIN with negative argument/local count "
                + String(instruction.operands[0])
                + "/"
                + String(instruction.operands[1]),
            )

        return True

    if instruction.opcode == OPCODE_BEGIN_CLOSURE:
        if (
            instruction.operands[0] < 0
            or instruction.operands[1] < 0
            or instruction.operands[2] < 0
        ):
            unit.fail(
                instruction.start,
                "BEGIN_CLOSURE with negative argument/local/capture count",
            )

        return True

    return False


def validate_operands(
    unit: Unit, context: Context, instruction: Instruction, op: Operation
) raises:
    for index in range(op.operand_count()):
        validate_operand(
            unit,
            context,
            instruction,
            op,
            Int(op.operands.as_bytes()[index]),
            instruction.operands[index],
        )


def validate_capture(
    unit: Unit,
    context: Context,
    instruction: Instruction,
    op: Operation,
    index: Int,
) raises:
    var capture_kinds: Array[Int, 4] = [
        OP_GLOBAL,
        OP_LOCAL,
        OP_ARGUMENT,
        OP_CAPTURE,
    ]
    var fixed_size = op.fixed_size()
    var position = instruction.start + fixed_size + index * op.trailing_size
    var kind = Int(unit.code_byte(position))
    var value = load_i32(unit.data, unit.code_start + position + 1)

    if kind > 3:
        unit.fail(
            instruction.start,
            "CLOSURE capture "
            + String(index)
            + " has invalid kind "
            + String(kind),
        )

    validate_variable(
        unit, context, instruction.start, capture_kinds[kind], value, True
    )


def validate_captures(
    unit: Unit, context: Context, instruction: Instruction, op: Operation
) raises:
    if op.trailing_size == 0:
        return

    for index in range(instruction.operands[op.trailing_count_operand]):
        validate_capture(unit, context, instruction, op, index)


def validate_scope(
    unit: Unit, context: Context, instruction: Instruction
) raises:
    if is_entry(instruction.opcode):
        if context.owner != instruction.start:
            unit.fail(
                instruction.start,
                "function entry reached through a non-entry edge",
            )
    elif instruction.opcode == OPCODE_EOF:
        if context.owner >= 0:
            unit.fail(instruction.start, "EOF is inside a function body")
    elif context.owner < 0:
        unit.fail(instruction.start, "instruction is outside a function body")


def validate_semantics(
    unit: Unit, context: Context, instruction: Instruction, op: Operation
) raises:
    if not validate_entry_counts(unit, instruction):
        validate_operands(unit, context, instruction, op)
    validate_captures(unit, context, instruction, op)
    validate_scope(unit, context, instruction)


def ascii_character(value: UInt8) -> String:
    var bytes = List[UInt8]()
    bytes.append(value)
    return String(unsafe_from_utf8=bytes)


def escaped_byte(byte: UInt8) -> String:
    if byte == 34:
        return '\\"'

    if byte == 92:
        return "\\\\"

    if byte == 10:
        return "\\n"

    if byte == 13:
        return "\\r"

    if byte == 9:
        return "\\t"

    if byte >= 0x20 and byte <= 0x7E:
        return ascii_character(byte)

    var digits = "0123456789abcdef".as_bytes()

    return (
        "\\x"
        + ascii_character(digits[Int(byte >> 4)])
        + ascii_character(digits[Int(byte & 0x0F)])
    )


def escaped_string(unit: Unit, offset: Int) raises -> String:
    var bytes = unit.string_bytes(offset, -1)
    return '"' + "".join([escaped_byte(byte) for byte in bytes]) + '"'


comptime LamaContext = Context
comptime LamaInstruction = Instruction
comptime LamaRoot = Root


struct LamaBackend(BytecodeBackend):
    comptime Context = LamaContext
    comptime Instruction = LamaInstruction
    comptime Root = LamaRoot

    var unit: Unit
    var entries: Dict[Int, Context]
    var pending_closures: Set[Int]
    var indirect_call_seen: Bool
    var entry_offsets: List[Int]
    var instruction_cache: LamaInstructionCache
    var operation_handlers: Array[Operation, 256]

    def __init__(out self, path: String) raises:
        self.unit = Unit(path)
        self.entries = Dict[Int, Context]()
        self.pending_closures = Set[Int]()
        self.indirect_call_seen = False
        self.entry_offsets = List[Int]()
        self.instruction_cache = LamaInstructionCache()
        self.operation_handlers = build_operation_handlers()

        if (
            self.unit.code_size() == 0
            or self.unit.code_byte(self.unit.code_size() - 1) != OPCODE_EOF
        ):
            self.unit.fail(-1, "code section does not end with the EOF opcode")

    def code_size(self) -> Int:
        return self.unit.code_size()

    def path(self) -> String:
        return self.unit.file_path

    def roots(self, root_zero: Bool) -> List[Root]:
        var result = List[Root](
            capacity=self.unit.publics_count + Int(root_zero)
        )

        if root_zero:
            result.append(Root(0, False))

        for index in range(self.unit.publics_count):
            if self.unit.public_flag(index) == 0:
                result.append(Root(self.unit.public_offset(index), True))

        return result^

    def requires_raw_for_cache(self, instruction: Instruction) -> Bool:
        var op = self.operation_handlers[instruction.opcode]
        return self.instruction_cache.requires_raw(instruction, op)

    def cached_identifier(
        self, instruction: Instruction, raw: List[UInt8]
    ) -> Int:
        var op = self.operation_handlers[instruction.opcode]
        return self.instruction_cache.lookup(instruction, raw, op)

    def cache_identifier(
        mut self, instruction: Instruction, raw: List[UInt8], identifier: Int
    ):
        var op = self.operation_handlers[instruction.opcode]
        self.instruction_cache.insert(instruction, raw, identifier, op)

    def clear_cached_identifiers(mut self):
        self.instruction_cache.clear()

    def join_context(
        self, offset: Int, previous: Context, incoming: Context, source: Int
    ) raises:
        if previous.owner != incoming.owner:
            self.unit.fail(
                source,
                String(
                    t"instruction {offset} is reached from conflicting function"
                    t" bodies"
                ),
            )
        if previous.depth != incoming.depth:
            self.unit.fail(
                source,
                String(
                    t"stack depth mismatch at instruction {offset}: recorded"
                    t" depth {previous.depth}, incoming depth {incoming.depth}"
                ),
            )

    def decode(self, offset: Int, context: Context) raises -> Instruction:
        var instruction = decode_syntax(
            self.unit, self.operation_handlers, offset
        )
        var op = self.operation_handlers[instruction.opcode]
        validate_semantics(self.unit, context, instruction, op)
        return instruction^

    def decode_structure(self, offset: Int) raises -> Instruction:
        return decode_syntax(self.unit, self.operation_handlers, offset)

    def instruction_bytes(self, instruction: Instruction) -> List[UInt8]:
        return self.unit.code_slice(instruction.start, instruction.next)

    @always_inline
    def next_context(
        self, instruction: Instruction, context: Context
    ) raises -> Context:
        var op = self.operation_handlers[instruction.opcode]

        if op.stack_rule == STACK_RESET:
            return Context(context.owner, 0)

        if op.stack_rule == STACK_EXACT_ONE:
            if context.depth != 1:
                self.unit.fail(
                    instruction.start,
                    String(
                        t"{op.name} requires stack depth 1, have"
                        t" {context.depth}"
                    ),
                )

            return Context(context.owner, context.depth)

        var pops = op.pops

        if op.pop_operand >= 0:
            pops += instruction.operands[op.pop_operand]

        if context.depth < pops:
            self.unit.fail(
                instruction.start,
                String(
                    t"stack underflow at {op.name}: need"
                    t" {pops} operands, have {context.depth}"
                ),
            )

        var depth = context.depth - pops + op.pushes

        if depth > 0x7FFFFFFF:
            self.unit.fail(instruction.start, "stack depth overflow")

        return Context(context.owner, depth)

    def check_entry_kind(self, source: Int, target: Int, closure: Bool) raises:
        var opcode = Int(self.unit.code_byte(target))

        if opcode != OPCODE_BEGIN and (
            not closure or opcode != OPCODE_BEGIN_CLOSURE
        ):
            self.unit.fail(
                source,
                ("CLOSURE" if closure else "CALL/public")
                + " target "
                + String(target)
                + " does not point to a function entry",
            )

    def check_capture_count(
        self, source: Int, target: Int, captures: Int
    ) raises:
        if (
            captures < 0
            or Int(self.unit.code_byte(target)) != OPCODE_BEGIN_CLOSURE
        ):
            return

        var target_captures = load_i32(
            self.unit.data, self.unit.code_start + target + 9
        )

        if target_captures != captures:
            self.unit.fail(
                source,
                "CLOSURE capture count "
                + String(captures)
                + " does not match target capture count "
                + String(target_captures),
            )

    def initialize_entry(
        mut self, source: Int, target: Int, closure: Bool
    ) raises:
        if target < 0 or target >= self.unit.code_size() - 1:
            self.unit.fail(
                source, "function target " + String(target) + " is out of range"
            )

        self.check_entry_kind(source, target, closure)
        var instruction = decode_syntax(
            self.unit, self.operation_handlers, target
        )

        if instruction.operands[0] < 0 or instruction.operands[1] < 0:
            self.unit.fail(
                source,
                "function target " + String(target) + " has negative counts",
            )

        if (
            instruction.opcode == OPCODE_BEGIN_CLOSURE
            and instruction.operands[2] < 0
        ):
            self.unit.fail(
                source,
                "function target "
                + String(target)
                + " has negative capture count",
            )

        self.entries[target] = Context(target, 0)

    def entry_context(
        mut self, source: Int, target: Int, closure: Bool, captures: Int
    ) raises -> Context:
        if target not in self.entries:
            self.initialize_entry(source, target, closure)
        else:
            self.check_entry_kind(source, target, closure)

        if closure:
            self.check_capture_count(source, target, captures)

        return self.entries[target]

    def root_context(mut self, root: Root) raises -> Context:
        return self.entry_context(-1, root.offset, root.closure, -1)

    def checked_branch_target(self, source: Int, target: Int) raises -> Int:
        if target < 0 or target >= self.unit.code_size():
            self.unit.fail(
                source,
                "control-flow target " + String(target) + " is out of range",
            )

        var opcode = Int(self.unit.code_byte(target))

        if is_entry(opcode):
            self.unit.fail(
                source,
                "jump target " + String(target) + " points to a function entry",
            )

        if opcode == OPCODE_EOF:
            self.unit.fail(
                source, "jump target " + String(target) + " points to EOF"
            )

        return target

    def append_branch(
        mut self,
        mut result: List[Edge[Context]],
        instruction: Instruction,
        context: Context,
    ) raises:
        var target = self.checked_branch_target(
            instruction.start, instruction.operands[0]
        )
        result.append(Edge(target, context, EDGE_BRANCH))

    def append_call(
        mut self, mut result: List[Edge[Context]], instruction: Instruction
    ) raises:
        var target = instruction.operands[0]

        if target < 0:
            return

        var context = self.entry_context(instruction.start, target, False, 0)
        result.append(Edge(target, context, EDGE_ENTRY))

    def append_closure(
        mut self, mut result: List[Edge[Context]], instruction: Instruction
    ) raises:
        var target = instruction.operands[0]

        if target < 0:
            return

        var context = self.entry_context(
            instruction.start, target, True, instruction.operands[1]
        )

        if self.indirect_call_seen:
            result.append(Edge(target, context, EDGE_ENTRY))
        else:
            self.pending_closures.add(target)

    def activate_pending_closures(mut self, mut result: List[Edge[Context]]):
        self.indirect_call_seen = True

        for target in self.pending_closures:
            result.append(Edge(target, Context(target, 0), EDGE_ENTRY))

        self.pending_closures.clear()

    def successors(
        mut self, instruction: Instruction, next_context: Context
    ) raises -> List[Edge[Context]]:
        var op = self.operation_handlers[instruction.opcode]
        var result = List[Edge[Context]]()
        if op.flow == FLOW_JUMP or op.flow == FLOW_CONDITIONAL:
            self.append_branch(result, instruction, next_context)
        elif op.flow == FLOW_CALL:
            self.append_call(result, instruction)
        elif op.flow == FLOW_CLOSURE:
            self.append_closure(result, instruction)
        elif op.flow == FLOW_INDIRECT and not self.indirect_call_seen:
            self.activate_pending_closures(result)
        return result^

    def finalize(mut self):
        self.entry_offsets.clear()

        for item in self.entries.items():
            self.entry_offsets.append(item.key)

        sort(self.entry_offsets)

    @always_inline
    def enclosing_entry(self, offset: Int) raises -> Int:
        var low = 0
        var high = len(self.entry_offsets)

        while low < high:
            var middle = (low + high) // 2

            if self.entry_offsets[middle] <= offset:
                low = middle + 1
            else:
                high = middle

        if low == 0:
            self.unit.fail(
                offset, "instruction has no enclosing function entry"
            )

        return self.entry_offsets[low - 1]

    def validate_ordered(self, offset: Int) raises:
        var target = load_i32(self.unit.data, self.unit.code_start + offset + 1)
        if (
            len(self.entry_offsets) == 1
            and self.entry_offsets[0] <= offset
            and target >= self.entry_offsets[0]
        ):
            return
        var owner = self.enclosing_entry(offset)
        var target_owner = self.enclosing_entry(target)
        if owner != target_owner:
            self.unit.fail(
                offset,
                "jump target "
                + String(target)
                + " is outside function body starting at "
                + String(owner),
            )

    def format_instruction(self, raw: List[UInt8]) raises -> String:
        if len(raw) == 0:
            raise Error("empty instruction key")

        var opcode = Int(raw[0])
        var op = self.operation_handlers[opcode]

        if op.name == "":
            raise Error("invalid opcode in canonical key")

        var result = String(op.name)
        var position = 1

        for index in range(op.operand_count()):
            var value = load_i32(raw, position)
            position += 4
            result += " "

            if Int(op.operands.as_bytes()[index]) == OP_STRING:
                result += escaped_string(self.unit, value)
            else:
                result += String(value)

        if op.trailing_size != 0:
            var count_offset = 1 + 4 * op.trailing_count_operand

            for _ in range(load_i32(raw, count_offset)):
                result += " " + String(raw[position])
                result += " " + String(load_i32(raw, position + 1))
                position += op.trailing_size

        return result^
