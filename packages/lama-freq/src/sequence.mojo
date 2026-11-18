from bytecode import BytecodeBackend

comptime UNIGRAM_TAG = 1
comptime BIGRAM_TAG = 2
comptime BIGRAM_HEADER_SIZE = 5


def compare_bytes(left: List[UInt8], right: List[UInt8]) -> Int:
    var common = min(len(left), len(right))

    for index in range(common):
        if left[index] < right[index]:
            return -1

        if left[index] > right[index]:
            return 1

    if len(left) < len(right):
        return -1

    if len(left) > len(right):
        return 1

    return 0


def copy_range(data: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var result = List[UInt8](capacity=end - start)

    for index in range(start, end):
        result.append(data[index])

    return result^


def append_bytes(mut destination: List[UInt8], data: List[UInt8]):
    for byte in data:
        destination.append(byte)


def append_u32_le(mut destination: List[UInt8], value: Int):
    for shift in range(0, 32, 8):
        destination.append(UInt8((value >> shift) & 0xFF))


def unigram_key(raw: List[UInt8]) -> List[UInt8]:
    var key = List[UInt8](capacity=1 + len(raw))
    key.append(UNIGRAM_TAG)
    append_bytes(key, raw)
    return key^


def bigram_key(left: List[UInt8], right: List[UInt8]) -> List[UInt8]:
    var key = List[UInt8](capacity=BIGRAM_HEADER_SIZE + len(left) + len(right))
    key.append(BIGRAM_TAG)
    append_u32_le(key, len(left))
    append_bytes(key, left)
    append_bytes(key, right)
    return key^


def load_u32_le(data: List[UInt8], start: Int) -> Int:
    var value = 0

    for index in range(4):
        value |= Int(data[start + index]) << (8 * index)

    return value


@fieldwise_init
struct Record(Comparable, Copyable):
    var key: List[UInt8]
    var count: Int

    def __lt__(self, other: Self) -> Bool:
        if self.count != other.count:
            return self.count > other.count
        return compare_bytes(self.key, other.key) < 0


@fieldwise_init
struct RunRecord(Comparable, Copyable):
    var key: List[UInt8]
    var count: Int

    def __lt__(self, other: Self) -> Bool:
        return compare_bytes(self.key, other.key) < 0

    def frequency_record(self) -> Record:
        return Record(self.key.copy(), self.count)


def validate_bigram(key: List[UInt8], right_start: Int) raises:
    if right_start <= BIGRAM_HEADER_SIZE or right_start >= len(key):
        raise Error("internal error: invalid bigram key lengths")


def format_sequence[
    B: BytecodeBackend
](backend: B, key: List[UInt8]) raises -> String:
    if len(key) < 2:
        raise Error("internal error: short sequence key")

    if key[0] == UNIGRAM_TAG:
        return backend.format_instruction(copy_range(key, 1, len(key)))

    if key[0] != BIGRAM_TAG or len(key) <= BIGRAM_HEADER_SIZE:
        raise Error("internal error: invalid sequence key")

    var right_start = BIGRAM_HEADER_SIZE + load_u32_le(key, 1)
    validate_bigram(key, right_start)
    var left = copy_range(key, BIGRAM_HEADER_SIZE, right_start)
    var right = copy_range(key, right_start, len(key))

    return (
        backend.format_instruction(left)
        + " ; "
        + backend.format_instruction(right)
    )


def format_record[
    B: BytecodeBackend
](backend: B, record: Record) raises -> String:
    return String(record.count) + "\t" + format_sequence(backend, record.key)


def format_run_record[
    B: BytecodeBackend
](backend: B, record: RunRecord) raises -> String:
    return String(record.count) + "\t" + format_sequence(backend, record.key)
