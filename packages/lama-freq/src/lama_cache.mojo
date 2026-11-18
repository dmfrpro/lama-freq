from std.collections import Array

from lama_isa import Instruction, Operation


struct LamaInstructionCache(Movable):
    var unigram_ids: Dict[List[UInt8], Int]
    var fixed_ids: Dict[Tuple[Int, Int, Int, Int, Int], Int]
    var short_ids: Dict[Tuple[Int, Int], Int]
    var recent_keys: Array[Tuple[Int, Int, Int, Int, Int], 256]
    var recent_ids: Array[Int, 256]

    def __init__(out self):
        self.unigram_ids = Dict[List[UInt8], Int]()
        self.fixed_ids = Dict[Tuple[Int, Int, Int, Int, Int], Int]()
        self.short_ids = Dict[Tuple[Int, Int], Int]()
        self.recent_keys = Array[Tuple[Int, Int, Int, Int, Int], 256](
            fill=(-1, -1, -1, -1, -1)
        )
        self.recent_ids = Array[Int, 256](fill=-1)

    def has_complete_operands(
        self, instruction: Instruction, op: Operation
    ) -> Bool:
        return (
            op.trailing_size == 0
            or instruction.operands[op.trailing_count_operand] == 0
        )

    def requires_raw(self, instruction: Instruction, op: Operation) -> Bool:
        return not self.has_complete_operands(instruction, op)

    def fixed_key(
        self, instruction: Instruction
    ) -> Tuple[Int, Int, Int, Int, Int]:
        return (
            instruction.opcode,
            instruction.operands[0],
            instruction.operands[1],
            instruction.operands[2],
            instruction.operands[3],
        )

    def lookup(
        self, instruction: Instruction, raw: List[UInt8], op: Operation
    ) -> Int:
        if not self.has_complete_operands(instruction, op):
            return self.unigram_ids.get(raw, -1)

        var identifier = self.recent_ids[instruction.opcode]

        if identifier >= 0:
            var recent_key = self.fixed_key(instruction)

            if recent_key == self.recent_keys[instruction.opcode]:
                return identifier

        if op.operand_count() <= 1:
            return self.short_ids.get(
                (instruction.opcode, instruction.operands[0]), -1
            )

        return self.fixed_ids.get(self.fixed_key(instruction), -1)

    def insert(
        mut self,
        instruction: Instruction,
        raw: List[UInt8],
        identifier: Int,
        op: Operation,
    ):
        if not self.has_complete_operands(instruction, op):
            self.unigram_ids[raw.copy()] = identifier
            return

        var key = self.fixed_key(instruction)

        if self.recent_ids[instruction.opcode] == -1:
            self.recent_keys[instruction.opcode] = key
            self.recent_ids[instruction.opcode] = identifier
        elif (
            self.recent_ids[instruction.opcode] >= 0
            and key != self.recent_keys[instruction.opcode]
        ):
            self.recent_ids[instruction.opcode] = -2

        if op.operand_count() <= 1:
            self.short_ids[
                (instruction.opcode, instruction.operands[0])
            ] = identifier
        else:
            self.fixed_ids[key] = identifier

    def clear(mut self):
        self.unigram_ids = Dict[List[UInt8], Int]()
        self.fixed_ids = Dict[Tuple[Int, Int, Int, Int, Int], Int]()
        self.short_ids = Dict[Tuple[Int, Int], Int]()
        self.recent_keys = Array[Tuple[Int, Int, Int, Int, Int], 256](
            fill=(-1, -1, -1, -1, -1)
        )
        self.recent_ids = Array[Int, 256](fill=-1)
