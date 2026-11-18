from std.ffi import c_int, c_long, external_call
from std.memory import unsafe_memcpy

from bytecode import BytecodeBackend
from sequence import (
    RunRecord,
    Record,
    append_u32_le,
    compare_bytes,
    format_record,
    format_run_record,
)

comptime IO_BUFFER_SIZE = 65536
comptime RUN_HEADER_SIZE = 12
comptime MAXIMUM_FANIN = 16
comptime RECORD_OVERHEAD = 96


def encode_count(mut destination: List[UInt8], count: Int):
    for shift in range(0, 64, 8):
        destination.append(UInt8((count >> shift) & 0xFF))


def decode_count(data: List[UInt8]) -> Int:
    var value = UInt64(0)

    for index in range(8):
        value |= UInt64(data[index]) << UInt64(8 * index)

    if (value >> 63) == 0:
        return Int(value)

    return -1 - Int(~value)


def decode_key_size(header: List[UInt8]) -> Int:
    var size = 0

    for index in range(4):
        size |= Int(header[8 + index]) << (8 * index)

    return size


struct TemporaryFile(Movable):
    var path: List[UInt8]
    var descriptor: Int
    var byte_count: Int

    def __init__(out self, directory: String) raises:
        self.path = List[UInt8]()
        self.path.extend(directory.as_bytes())
        self.path.extend("/lama-freq-XXXXXX".as_bytes())
        self.path.append(0)
        self.byte_count = 0
        self.descriptor = Int(
            external_call["mkstemp", c_int](self.path.unsafe_ptr())
        )
        if self.descriptor < 0:
            raise Error("cannot create a temporary file in " + directory)

    def __deinit__(deinit self):
        self.close()

    def close(mut self):
        if self.descriptor < 0:
            return

        _ = external_call["close", c_int](c_int(self.descriptor))
        _ = external_call["unlink", c_int](self.path.unsafe_ptr())
        self.descriptor = -1

    def seek_start(mut self) raises:
        if (
            external_call["lseek", c_long](
                c_int(self.descriptor), c_long(0), c_int(0)
            )
            < 0
        ):
            raise Error("cannot seek temporary stream")

    def write(mut self, data: List[UInt8]) raises:
        var position = 0

        while position < len(data):
            var count = external_call["write", Int](
                self.descriptor,
                data.unsafe_ptr().unsafe_offset(position),
                Int(len(data) - position),
            )

            if count <= 0:
                raise Error("cannot write temporary data")

            position += Int(count)

        self.byte_count += len(data)

    def read_some(mut self, mut buffer: List[UInt8]) raises -> Int:
        var count = external_call["read", Int](
            self.descriptor,
            buffer.unsafe_ptr(),
            len(buffer),
        )
        if count < 0:
            raise Error("cannot read temporary data")
        return Int(count)


struct RunWriter(Movable):
    var file: TemporaryFile
    var buffer: List[UInt8]

    def __init__(out self, directory: String) raises:
        self.file = TemporaryFile(directory)
        self.buffer = List[UInt8](capacity=IO_BUFFER_SIZE)

    def write(mut self, data: List[UInt8]) raises:
        if len(self.buffer) + len(data) >= IO_BUFFER_SIZE:
            self.flush()

        if len(data) >= IO_BUFFER_SIZE:
            self.file.write(data)
        else:
            for byte in data:
                self.buffer.append(byte)

    def write_record(mut self, record: RunRecord) raises:
        encode_count(self.buffer, record.count)
        append_u32_le(self.buffer, len(record.key))
        self.write(record.key)

    def flush(mut self) raises:
        if len(self.buffer) == 0:
            return
        self.file.write(self.buffer)
        self.buffer.clear()

    def finish(deinit self) raises -> TemporaryFile:
        self.flush()
        self.file.seek_start()
        return self.file^


struct RunCursor(Movable):
    var file: TemporaryFile
    var buffer: List[UInt8]
    var position: Int
    var available: Int
    var current: RunRecord
    var valid: Bool

    def __init__(out self, var file: TemporaryFile) raises:
        self.file = file^
        self.buffer = List[UInt8](unsafe_uninit_length=IO_BUFFER_SIZE)
        self.position = 0
        self.available = 0
        self.current = RunRecord(List[UInt8](), 0)
        self.valid = False
        self.file.seek_start()

    def refill(mut self) raises -> Bool:
        self.available = self.file.read_some(self.buffer)
        self.position = 0
        return self.available != 0

    def read_into(mut self, mut destination: List[UInt8]) raises -> Int:
        var copied = 0

        while copied < len(destination):
            if self.position == self.available and not self.refill():
                break

            var count = min(
                len(destination) - copied, self.available - self.position
            )
            unsafe_memcpy(
                dest=destination.unsafe_ptr().unsafe_offset(copied),
                src=self.buffer.unsafe_ptr().unsafe_offset(self.position),
                count=count,
            )
            copied += count
            self.position += count

        return copied

    def read_exact(mut self, size: Int) raises -> List[UInt8]:
        var result = List[UInt8](unsafe_uninit_length=size)

        if self.read_into(result) != size:
            raise Error("unexpected end of temporary data")

        return result^

    def next(mut self) raises:
        self.valid = False
        var header = List[UInt8](unsafe_uninit_length=RUN_HEADER_SIZE)
        var count = self.read_into(header)

        if count == 0:
            return

        if count != RUN_HEADER_SIZE:
            raise Error("truncated temporary sorting run header")

        var key = self.read_exact(decode_key_size(header))
        self.current = RunRecord(key^, decode_count(header))
        self.valid = True


def precedes(left: RunRecord, right: RunRecord, by_frequency: Bool) -> Bool:
    if by_frequency and left.count != right.count:
        return left.count > right.count

    return compare_bytes(left.key, right.key) < 0


def first_cursor(cursors: List[RunCursor], by_frequency: Bool) -> Int:
    var first = -1

    for index in range(len(cursors)):
        if not cursors[index].valid:
            continue

        if first < 0 or precedes(
            cursors[index].current, cursors[first].current, by_frequency
        ):
            first = index

    return first


@fieldwise_init
struct ExternalStats(Copyable):
    var spills: Int
    var maximum_runs: Int
    var merge_rounds: Int
    var temporary_bytes: Int

    def __init__(out self):
        self = Self(0, 0, 0, 0)


struct ExternalCounter(Movable):
    var directory: String
    var memory_limit: Int
    var counts: Dict[List[UInt8], Int]
    var estimated_bytes: Int
    var runs: List[TemporaryFile]
    var stats: ExternalStats

    def __init__(out self, directory: String, memory_limit: Int):
        self.directory = directory
        self.memory_limit = memory_limit
        self.counts = Dict[List[UInt8], Int]()
        self.estimated_bytes = 0
        self.runs = List[TemporaryFile]()
        self.stats = ExternalStats()

    def add(mut self, var key: List[UInt8], count: Int) raises:
        if key in self.counts:
            self.counts[key] += count
            return

        var needed = len(key) + RECORD_OVERHEAD

        if (
            len(self.counts) != 0
            and self.estimated_bytes + needed > self.memory_limit
        ):
            self.spill()

        self.counts[key^] = count
        self.estimated_bytes += needed

    def write_run(mut self, records: List[RunRecord]) raises:
        var writer = RunWriter(self.directory)

        for record in records:
            writer.write_record(record)

        self.push_run(writer^.finish())

    def push_run(mut self, var file: TemporaryFile):
        self.stats.temporary_bytes += file.byte_count
        self.stats.spills += 1
        self.runs.append(file^)
        self.stats.maximum_runs = max(self.stats.maximum_runs, len(self.runs))

    def spill(mut self) raises:
        if len(self.counts) == 0:
            return

        var records = List[RunRecord](capacity=len(self.counts))

        for item in self.counts.items():
            records.append(RunRecord(item.key.copy(), item.value))

        sort(records)
        self.write_run(records)
        self.counts = Dict[List[UInt8], Int]()
        self.estimated_bytes = 0

    def merge_fanin(self) -> Int:
        var affordable = self.memory_limit // (2 * IO_BUFFER_SIZE)
        return max(2, min(MAXIMUM_FANIN, affordable))

    def merge_group(
        mut self, mut group: List[TemporaryFile], by_frequency: Bool
    ) raises -> TemporaryFile:
        var cursors = List[RunCursor](capacity=len(group))

        while len(group) != 0:
            var cursor = RunCursor(group.pop(0))
            cursor.next()
            cursors.append(cursor^)

        var writer = RunWriter(self.directory)

        while True:
            var first = first_cursor(cursors, by_frequency)

            if first < 0:
                break

            var record = cursors[first].current.copy()
            var selected = List[Int]()
            selected.append(first)

            if not by_frequency:
                for index in range(len(cursors)):
                    if (
                        index != first
                        and cursors[index].valid
                        and compare_bytes(
                            record.key, cursors[index].current.key
                        )
                        == 0
                    ):
                        record.count += cursors[index].current.count
                        selected.append(index)

            writer.write_record(record)

            for index in selected:
                cursors[index].next()

        return writer^.finish()

    def merge_round(mut self, by_frequency: Bool) raises:
        var remaining = self.runs^
        self.runs = List[TemporaryFile]()

        while len(remaining) != 0:
            var group = List[TemporaryFile]()
            var count = min(self.merge_fanin(), len(remaining))

            for _ in range(count):
                group.append(remaining.pop(0))

            self.push_run(self.merge_group(group, by_frequency))

    def reduce_runs(mut self, by_frequency: Bool) raises:
        while len(self.runs) > 1:
            self.stats.merge_rounds += 1
            self.merge_round(by_frequency)

    def flush_frequencies(mut self, mut records: List[Record]) raises:
        sort(records)
        var runs = List[RunRecord](capacity=len(records))

        for record in records:
            runs.append(RunRecord(record.key.copy(), record.count))

        self.write_run(runs)

    def in_memory_records(self) -> List[Record]:
        var records = List[Record](capacity=len(self.counts))

        for item in self.counts.items():
            if item.value != 0:
                records.append(Record(item.key.copy(), item.value))

        return records^

    def render_in_memory[B: BytecodeBackend](mut self, backend: B) raises:
        var records = self.in_memory_records()
        sort(records)

        for record in records:
            print(format_record(backend, record))

    def render_run[B: BytecodeBackend](mut self, backend: B) raises:
        var cursor = RunCursor(self.runs.pop())
        cursor.next()

        while cursor.valid:
            if cursor.current.count != 0:
                print(format_run_record(backend, cursor.current))

            cursor.next()

    def reorder_by_frequency[B: BytecodeBackend](mut self, backend: B) raises:
        var cursor = RunCursor(self.runs.pop())
        var records = List[Record]()
        var size = 0
        cursor.next()

        while cursor.valid:
            if cursor.current.count < 0:
                raise Error("invalid signed frequency after corrections")

            var needed = len(cursor.current.key) + RECORD_OVERHEAD

            if len(records) != 0 and size + needed > self.memory_limit:
                self.flush_frequencies(records)
                records = List[Record]()
                size = 0

            if cursor.current.count != 0:
                records.append(cursor.current.frequency_record())
                size += needed

            cursor.next()

        if len(self.runs) == 0:
            sort(records)

            for record in records:
                print(format_record(backend, record))

            return

        self.flush_frequencies(records)
        self.reduce_runs(True)
        self.render_run(backend)

    def render[B: BytecodeBackend](mut self, backend: B) raises:
        if len(self.runs) == 0:
            self.render_in_memory(backend)
            return

        self.spill()
        self.reduce_runs(False)
        self.reorder_by_frequency(backend)
