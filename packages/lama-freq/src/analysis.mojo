from bitset import OffsetBitset
from bytecode import (
    BytecodeBackend,
    EDGE_BRANCH,
    EDGE_ENTRY,
    EDGE_FALLTHROUGH,
    WorkItem,
)
from frequency import AnalysisResult, CounterOptions, CountedInstruction


@fieldwise_init
struct Deferred[C: ImplicitlyCopyable & Deinitable](ImplicitlyCopyable):
    var context: Self.C
    var source: Int


struct Analyzer[B: BytecodeBackend]:
    var backend: Self.B
    var roots: List[Self.B.Root]
    var work: List[WorkItem[Self.B.Context]]
    var reachable: OffsetBitset
    var labels: OffsetBitset
    var branches: OffsetBitset
    var joins: Dict[Int, Self.B.Context]
    var deferred: Dict[Int, Deferred[Self.B.Context]]
    var pending: OffsetBitset
    var counted_early: OffsetBitset
    var result: AnalysisResult

    def __init__(
        out self,
        var backend: Self.B,
        roots: List[Self.B.Root],
        options: CounterOptions,
    ) raises:
        self.backend = backend^
        self.roots = roots.copy()
        self.work = List[WorkItem[Self.B.Context]]()
        self.reachable = OffsetBitset(self.backend.code_size())
        self.labels = OffsetBitset(self.backend.code_size())
        self.branches = OffsetBitset(self.backend.code_size())
        self.joins = Dict[Int, Self.B.Context]()
        self.deferred = Dict[Int, Deferred[Self.B.Context]]()
        self.pending = OffsetBitset(self.backend.code_size())
        self.counted_early = OffsetBitset(self.backend.code_size())
        self.result = AnalysisResult(options)

    def fail(self, source: Int, message: String) raises:
        raise Error(String(t"{self.backend.path()}: {message}"))

    def join_context(
        self,
        offset: Int,
        previous: Self.B.Context,
        incoming: Self.B.Context,
        source: Int,
    ) raises:
        self.backend.join_context(offset, previous, incoming, source)

    def check_existing(
        mut self, offset: Int, context: Self.B.Context, source: Int
    ) raises:
        if offset in self.joins:
            self.join_context(offset, self.joins[offset], context, source)
        elif offset in self.deferred:
            self.join_context(
                offset, self.deferred[offset].context, context, source
            )
        else:
            self.deferred[offset] = Deferred(context, source)

    def prepare(
        mut self, offset: Int, context: Self.B.Context, kind: Int, source: Int
    ) raises -> Bool:
        if offset < 0 or offset >= self.backend.code_size():
            self.fail(
                source, String(t"control-flow target {offset} is out of range")
            )

        if kind == EDGE_BRANCH:
            _ = self.labels.add(offset)

        if not self.reachable.add(offset):
            self.check_existing(offset, context, source)
            return False

        if kind != EDGE_FALLTHROUGH:
            self.joins[offset] = context

        return True

    def schedule(
        mut self, offset: Int, context: Self.B.Context, kind: Int, source: Int
    ) raises:
        if self.prepare(offset, context, kind, source):
            _ = self.pending.add(offset)
            self.work.append(WorkItem(offset, context))

    def decode_reachable_structures(mut self) -> List[Self.B.Instruction]:
        var instructions = List[Self.B.Instruction](
            capacity=len(self.reachable)
        )

        for offset in self.reachable:
            try:
                instructions.append(self.backend.decode_structure(offset))
            except:
                pass

        return instructions^

    def check_target_boundaries(mut self) raises:
        var instructions = self.decode_reachable_structures()

        for target in self.labels:
            for instruction in instructions:
                if instruction.offset() >= target:
                    break

                if instruction.next_offset() > target:
                    self.fail(
                        target,
                        String(
                            t"control-flow target {target} is not an"
                            t" instruction boundary"
                        ),
                    )

    def decode_reached(
        mut self, offset: Int, context: Self.B.Context
    ) raises -> Self.B.Instruction:
        try:
            return self.backend.decode(offset, context)
        except error:
            self.check_target_boundaries()
            raise error

    def next_reached_context(
        mut self,
        instruction: Self.B.Instruction,
        context: Self.B.Context,
    ) raises -> Self.B.Context:
        try:
            return self.backend.next_context(instruction, context)
        except error:
            self.check_target_boundaries()
            raise error

    def found_instruction(
        mut self,
        instruction: Self.B.Instruction,
    ) raises -> CountedInstruction[Self.B.Instruction]:
        var identifier = self.result.find_instruction(self.backend, instruction)

        return CountedInstruction(instruction.copy(), identifier)

    def count_reached(
        mut self,
        instruction: Self.B.Instruction,
    ) raises -> CountedInstruction[Self.B.Instruction]:
        if self.counted_early and instruction.offset() in self.counted_early:
            self.counted_early.discard(instruction.offset())
            return self.found_instruction(instruction)

        return self.result.add_instruction(self.backend, instruction)

    def count_join(
        mut self,
        instruction: Self.B.Instruction,
    ) raises -> CountedInstruction[Self.B.Instruction]:
        if instruction.offset() in self.pending and self.counted_early.add(
            instruction.offset()
        ):
            return self.result.add_instruction(self.backend, instruction)

        return self.found_instruction(instruction)

    def mark_branch(mut self, instruction: Self.B.Instruction):
        if instruction.needs_ordered_validation():
            _ = self.branches.add(instruction.offset())

    def check_overlap(mut self, instruction: Self.B.Instruction) raises:
        var overlap = self.reachable.first_in_range(
            instruction.offset() + 1, instruction.next_offset()
        )

        if overlap != instruction.next_offset():
            self.fail(
                instruction.offset(),
                String(
                    t"instruction overlaps another instruction at offset"
                    t" {overlap}"
                ),
            )

    def count_previous(
        mut self,
        previous: CountedInstruction[Self.B.Instruction],
        current: CountedInstruction[Self.B.Instruction],
    ) raises:
        if previous.instruction.next_offset() != current.instruction.offset():
            self.fail(
                current.instruction.offset(),
                "internal error: broken streamed fallthrough chain",
            )

        self.result.add_bigram(self.backend, previous, current)

    def count_current(
        mut self,
        instruction: Self.B.Instruction,
        previous: Optional[CountedInstruction[Self.B.Instruction]],
    ) raises -> CountedInstruction[Self.B.Instruction]:
        self.mark_branch(instruction)
        self.check_overlap(instruction)
        var current = self.count_reached(instruction)

        if previous:
            self.count_previous(previous.value(), current)

        return current^

    def schedule_successors(
        mut self, instruction: Self.B.Instruction, context: Self.B.Context
    ) raises:
        var edges = self.backend.successors(instruction, context)

        for edge in edges:
            self.schedule(
                edge.target, edge.context, edge.kind, instruction.offset()
            )

    def continue_fallthrough(
        mut self,
        current: CountedInstruction[Self.B.Instruction],
        context: Self.B.Context,
    ) raises -> Bool:
        var instruction = current.instruction.copy()

        if self.prepare(
            instruction.next_offset(),
            context,
            EDGE_FALLTHROUGH,
            instruction.offset(),
        ):
            return True

        var right = self.backend.decode_structure(instruction.next_offset())
        var right_counted = self.count_join(right)

        self.result.add_bigram(self.backend, current, right_counted)

        return False

    def traverse_stream(mut self, var item: WorkItem[Self.B.Context]) raises:
        var previous: Optional[CountedInstruction[Self.B.Instruction]] = None

        while True:
            var instruction = self.decode_reached(item.offset, item.context)
            var current = self.count_current(instruction, previous)
            var context = self.next_reached_context(instruction, item.context)
            self.schedule_successors(instruction, context)

            if not instruction.falls_through():
                break

            if not self.continue_fallthrough(current, context):
                break

            previous = current.copy()
            item = WorkItem(instruction.next_offset(), context)

    def traverse(mut self) raises:
        for root in self.roots:
            var context = self.backend.root_context(root)
            self.schedule(root.entry_offset(), context, EDGE_ENTRY, -1)

        while len(self.work) != 0:
            var item = self.work.pop()
            self.pending.discard(item.offset)
            self.traverse_stream(item)

    def reconstructed_context(
        mut self,
        offset: Int,
        follows_previous: Bool,
        next_context: Optional[Self.B.Context],
    ) raises -> Self.B.Context:
        if follows_previous:
            return next_context.value()

        if offset not in self.joins:
            self.fail(offset, "cannot reconstruct missing join context")

        return self.joins[offset]

    def validate_deferred_entry(
        mut self, offset: Int, context: Self.B.Context
    ) raises:
        if offset not in self.deferred:
            return

        var entry = self.deferred[offset]
        self.join_context(offset, entry.context, context, entry.source)

    def validate_deferred(mut self) raises:
        if len(self.deferred) == 0:
            return

        var previous: Optional[Self.B.Instruction] = None
        var next_context: Optional[Self.B.Context] = None

        for offset in self.reachable:
            var follows = (
                previous
                and previous.value().next_offset() == offset
                and previous.value().falls_through()
            )
            var context = self.reconstructed_context(
                offset, follows, next_context
            )
            self.validate_deferred_entry(offset, context)
            var instruction = self.backend.decode_structure(offset)

            if instruction.falls_through():
                next_context = self.backend.next_context(instruction, context)
            else:
                next_context = None

            previous = instruction.copy()

    def subtract_late_label(mut self, offset: Int) raises:
        var previous_offset = self.reachable.last_before(offset)

        if previous_offset < 0:
            return

        var previous = self.backend.decode_structure(previous_offset)

        if previous.next_offset() != offset or not previous.falls_through():
            return

        var instruction = self.backend.decode_structure(offset)
        self.result.subtract_bigram(self.backend, previous, instruction)

    def validate_sequences(mut self) raises:
        for offset in self.labels:
            self.subtract_late_label(offset)

        for offset in self.branches:
            self.backend.validate_ordered(offset)

    def record_statistics(mut self):
        self.result.stats.reachable_instructions = len(self.reachable)
        self.result.stats.jump_labels = len(self.labels)

    def run(mut self) raises:
        if len(self.roots) == 0:
            return

        self.traverse()
        self.record_statistics()
        self.backend.finalize()
        self.validate_deferred()

        if self.labels:
            self.validate_sequences()
