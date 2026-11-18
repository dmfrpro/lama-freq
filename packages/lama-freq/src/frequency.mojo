from bytecode import BytecodeBackend, BytecodeInstruction, Stats
from external import ExternalCounter
from sequence import Record, bigram_key, format_record, unigram_key

comptime UNIGRAM_OVERHEAD = 128
comptime BIGRAM_OVERHEAD = 64


@fieldwise_init
struct CounterOptions(Copyable):
    var memory_limit: Int
    var temporary_directory: String
    var force_raw: Bool


@fieldwise_init
struct CountedInstruction[I: BytecodeInstruction](Copyable):
    var instruction: Self.I
    var identifier: Int


struct AnalysisResult(Movable):
    var unigram_keys: List[List[UInt8]]
    var unigram_counts: List[Int]
    var bigram_counts: Dict[Tuple[Int, Int], Int]
    var cached_bigram_first: Tuple[Int, Int]
    var cached_bigram_second: Tuple[Int, Int]
    var cached_bigram_first_count: Int
    var cached_bigram_second_count: Int
    var cached_bigram_size: Int
    var stats: Stats
    var external: ExternalCounter
    var raw_mode: Bool
    var memory_limit: Int
    var estimated_bytes: Int

    def __init__(out self, options: CounterOptions):
        self.unigram_keys = List[List[UInt8]]()
        self.unigram_counts = List[Int]()
        self.bigram_counts = Dict[Tuple[Int, Int], Int]()
        self.cached_bigram_first = (-1, -1)
        self.cached_bigram_second = (-1, -1)
        self.cached_bigram_first_count = 0
        self.cached_bigram_second_count = 0
        self.cached_bigram_size = 0
        self.stats = Stats()
        self.external = ExternalCounter(
            options.temporary_directory, options.memory_limit
        )
        self.raw_mode = options.force_raw
        self.memory_limit = options.memory_limit
        self.estimated_bytes = 0

    def clear_interned(mut self):
        self.unigram_keys = List[List[UInt8]]()
        self.unigram_counts = List[Int]()
        self.bigram_counts = Dict[Tuple[Int, Int], Int]()
        self.cached_bigram_size = 0
        self.cached_bigram_first_count = 0
        self.cached_bigram_second_count = 0
        self.estimated_bytes = 0

    def store_bigram(mut self, key: Tuple[Int, Int], count: Int):
        if count == 0:
            return

        if key not in self.bigram_counts:
            self.estimated_bytes += BIGRAM_OVERHEAD

        self.bigram_counts[key] = self.bigram_counts.get(key, 0) + count

    def flush_cached_bigrams(mut self):
        var first = self.cached_bigram_first
        var second = self.cached_bigram_second
        var first_count = self.cached_bigram_first_count
        var second_count = self.cached_bigram_second_count

        if self.cached_bigram_size > 1:
            self.store_bigram(second, second_count)

        if self.cached_bigram_size > 0:
            self.store_bigram(first, first_count)

        self.cached_bigram_size = 0
        self.cached_bigram_first_count = 0
        self.cached_bigram_second_count = 0

    def export_external(mut self) raises:
        self.flush_cached_bigrams()

        for identifier, raw in enumerate(self.unigram_keys):
            var count = self.unigram_counts[identifier]

            if count != 0:
                self.external.add(unigram_key(raw), count)

        for item in self.bigram_counts.items():
            if item.value != 0:
                var key = bigram_key(
                    self.unigram_keys[item.key[0]],
                    self.unigram_keys[item.key[1]],
                )
                self.external.add(key^, item.value)

        self.clear_interned()

    def use_external[B: BytecodeBackend](mut self, mut backend: B) raises:
        if self.raw_mode:
            return
        self.raw_mode = True
        self.export_external()
        backend.clear_cached_identifiers()

    def maybe_use_external[B: BytecodeBackend](mut self, mut backend: B) raises:
        if self.estimated_bytes > self.memory_limit:
            self.use_external(backend)

    def add_raw_instruction(mut self, raw: List[UInt8]) raises -> Int:
        self.external.add(unigram_key(raw), 1)
        return 0

    def add_interned_instruction[
        B: BytecodeBackend
    ](
        mut self, mut backend: B, instruction: B.Instruction
    ) raises -> CountedInstruction[B.Instruction]:
        var raw = List[UInt8]()

        if backend.requires_raw_for_cache(instruction):
            raw = backend.instruction_bytes(instruction)

        var identifier = backend.cached_identifier(instruction, raw)

        if identifier >= 0:
            self.unigram_counts[identifier] += 1
            return CountedInstruction(instruction.copy(), identifier)

        if len(raw) == 0:
            raw = backend.instruction_bytes(instruction)

        identifier = len(self.unigram_keys)
        backend.cache_identifier(instruction, raw, identifier)
        self.unigram_keys.append(raw.copy())
        self.unigram_counts.append(1)
        self.estimated_bytes += len(raw) + UNIGRAM_OVERHEAD
        self.maybe_use_external(backend)

        return CountedInstruction(instruction.copy(), identifier)

    def add_instruction[
        B: BytecodeBackend
    ](
        mut self, mut backend: B, instruction: B.Instruction
    ) raises -> CountedInstruction[B.Instruction]:
        if not self.raw_mode:
            return self.add_interned_instruction(backend, instruction)

        var raw = backend.instruction_bytes(instruction)

        return CountedInstruction(
            instruction.copy(), self.add_raw_instruction(raw)
        )

    def find_instruction[
        B: BytecodeBackend
    ](self, backend: B, instruction: B.Instruction) raises -> Int:
        if self.raw_mode:
            return 0

        var raw = List[UInt8]()

        if backend.requires_raw_for_cache(instruction):
            raw = backend.instruction_bytes(instruction)

        return backend.cached_identifier(instruction, raw)

    def add_external_bigram[
        B: BytecodeBackend
    ](mut self, backend: B, left: B.Instruction, right: B.Instruction) raises:
        var key = bigram_key(
            backend.instruction_bytes(left), backend.instruction_bytes(right)
        )
        self.external.add(key^, 1)

    def add_bigram[
        B: BytecodeBackend
    ](
        mut self,
        mut backend: B,
        left: CountedInstruction[B.Instruction],
        right: CountedInstruction[B.Instruction],
    ) raises:
        if self.raw_mode:
            self.add_external_bigram(
                backend, left.instruction, right.instruction
            )
        else:
            var key = (left.identifier, right.identifier)
            if self.cached_bigram_size > 0 and key == self.cached_bigram_first:
                self.cached_bigram_first_count += 1
            elif (
                self.cached_bigram_size > 1 and key == self.cached_bigram_second
            ):
                self.cached_bigram_second_count += 1
            else:
                if self.cached_bigram_size > 1:
                    var evicted = self.cached_bigram_second
                    var evicted_count = self.cached_bigram_second_count

                    self.store_bigram(evicted, evicted_count)

                if self.cached_bigram_size > 0:
                    self.cached_bigram_second = self.cached_bigram_first
                    self.cached_bigram_second_count = (
                        self.cached_bigram_first_count
                    )

                self.cached_bigram_first = key
                self.cached_bigram_first_count = 1
                self.cached_bigram_size = min(2, self.cached_bigram_size + 1)

        self.stats.bigram_occurrences += 1

        if not self.raw_mode:
            self.maybe_use_external(backend)

    def subtract_bigram[
        B: BytecodeBackend
    ](
        mut self, mut backend: B, left: B.Instruction, right: B.Instruction
    ) raises:
        if self.raw_mode:
            var key = bigram_key(
                backend.instruction_bytes(left),
                backend.instruction_bytes(right),
            )
            self.external.add(key^, -1)
        else:
            self.flush_cached_bigrams()
            var key = (
                self.find_instruction(backend, left),
                self.find_instruction(backend, right),
            )
            var count = self.bigram_counts.get(key, 0)

            if count <= 0:
                raise Error(
                    "internal error: missing streamed bigram correction"
                )

            self.bigram_counts[key] = count - 1

        self.stats.bigram_occurrences -= 1

    def sorted_records(mut self) -> List[Record]:
        self.flush_cached_bigrams()
        var records = List[Record](
            capacity=len(self.unigram_keys) + len(self.bigram_counts)
        )

        for identifier, raw in enumerate(self.unigram_keys):
            var count = self.unigram_counts[identifier]

            if count != 0:
                records.append(Record(unigram_key(raw), count))

        for item in self.bigram_counts.items():
            if item.value != 0:
                var key = bigram_key(
                    self.unigram_keys[item.key[0]],
                    self.unigram_keys[item.key[1]],
                )
                records.append(Record(key^, item.value))

        sort(records)

        return records^


def render[
    B: BytecodeBackend
](backend: B, mut result: AnalysisResult) raises -> String:
    var output = String()

    for record in result.sorted_records():
        output += format_record(backend, record)
        output += "\n"

    return output^


def render_result[
    B: BytecodeBackend
](backend: B, mut result: AnalysisResult) raises:
    if result.raw_mode:
        result.external.render(backend)
        return

    print(render(backend, result), end="")
