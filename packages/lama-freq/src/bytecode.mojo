trait BytecodeRoot(Copyable, Deinitable):
    def entry_offset(self) -> Int:
        ...


trait BytecodeInstruction(Copyable, Deinitable):
    def offset(self) -> Int:
        ...

    def next_offset(self) -> Int:
        ...

    def falls_through(self) -> Bool:
        ...

    def needs_ordered_validation(self) -> Bool:
        ...


@fieldwise_init
struct Edge[C: ImplicitlyCopyable & Deinitable](ImplicitlyCopyable):
    var target: Int
    var context: Self.C
    var kind: Int


@fieldwise_init
struct WorkItem[C: ImplicitlyCopyable & Deinitable](ImplicitlyCopyable):
    var offset: Int
    var context: Self.C


@fieldwise_init
struct Stats(Copyable):
    var reachable_instructions: Int
    var jump_labels: Int
    var bigram_occurrences: Int

    def __init__(out self):
        self = Self(0, 0, 0)


trait BytecodeBackend(Deinitable, Movable):
    comptime Context: ImplicitlyCopyable & Equatable & Deinitable
    comptime Instruction: BytecodeInstruction
    comptime Root: BytecodeRoot

    def code_size(self) -> Int:
        ...

    def path(self) -> String:
        ...

    def decode(
        self, offset: Int, context: Self.Context
    ) raises -> Self.Instruction:
        ...

    def decode_structure(self, offset: Int) raises -> Self.Instruction:
        ...

    def instruction_bytes(self, instruction: Self.Instruction) -> List[UInt8]:
        ...

    def next_context(
        self, instruction: Self.Instruction, context: Self.Context
    ) raises -> Self.Context:
        ...

    def root_context(mut self, root: Self.Root) raises -> Self.Context:
        ...

    def successors(
        mut self,
        instruction: Self.Instruction,
        next_context: Self.Context,
    ) raises -> List[Edge[Self.Context]]:
        ...

    def join_context(
        self,
        offset: Int,
        previous: Self.Context,
        incoming: Self.Context,
        source: Int,
    ) raises:
        ...

    def requires_raw_for_cache(self, instruction: Self.Instruction) -> Bool:
        ...

    def cached_identifier(
        self, instruction: Self.Instruction, raw: List[UInt8]
    ) -> Int:
        ...

    def cache_identifier(
        mut self,
        instruction: Self.Instruction,
        raw: List[UInt8],
        identifier: Int,
    ):
        ...

    def clear_cached_identifiers(mut self):
        ...

    def finalize(mut self):
        ...

    def validate_ordered(self, offset: Int) raises:
        ...

    def format_instruction(self, raw: List[UInt8]) raises -> String:
        ...


comptime EDGE_BRANCH = 0
comptime EDGE_ENTRY = 1
comptime EDGE_FALLTHROUGH = 2
