from std.bit import count_leading_zeros, count_trailing_zeros
from std.ffi import c_int, c_long, external_call
from std.memory import Pointer
from std.sys import size_of

comptime WORD_SHIFT = 6
comptime WORD_BITS = 1 << WORD_SHIFT
comptime WORD_BYTES = size_of[UInt64]()
comptime WORD_MASK = WORD_BITS - 1
comptime WordPointer = Pointer[UInt64, MutUntrackedOrigin]

comptime PROT_READ = 1
comptime PROT_WRITE = 2
comptime MAP_PRIVATE = 0x02
comptime MAP_ANONYMOUS = 0x20
comptime MAP_FAILED = -1
comptime NO_FILE_DESCRIPTOR = -1
comptime EMPTY_POINTER_ADDRESS = 1


@always_inline
def words_needed(bit_count: Int) -> Int:
    return (bit_count + WORD_MASK) >> WORD_SHIFT


@always_inline
def word_index(offset: Int) -> Int:
    return offset >> WORD_SHIFT


@always_inline
def word_start(index: Int) -> Int:
    return index << WORD_SHIFT


@always_inline
def bit_offset(position: Int) -> Int:
    return position & WORD_MASK


@always_inline
def bit_mask(position: Int) -> UInt64:
    return UInt64(1) << UInt64(bit_offset(position))


@always_inline
def bits_below(count: Int) -> UInt64:
    if count >= WORD_BITS:
        return ~UInt64(0)

    return (UInt64(1) << UInt64(count)) - 1


@always_inline
def first_set_offset(index: Int, bits: UInt64) -> Int:
    return word_start(index) + Int(count_trailing_zeros(bits))


@always_inline
def last_set_offset(index: Int, bits: UInt64) -> Int:
    return word_start(index) + WORD_MASK - Int(count_leading_zeros(bits))


@fieldwise_init
struct OffsetBitsetIterator[mut: Bool, //, origin: Origin[mut=mut]](
    ImplicitlyCopyable, Iterator
):
    comptime Element = Int
    var source: Pointer[OffsetBitset, Self.origin]
    var next_offset: Int
    var end: Int
    var remaining: Int

    def __next__(mut self) -> Int:
        var current = self.next_offset
        self.next_offset = self.source[].first_in_range(current + 1, self.end)
        self.remaining -= 1
        return current

    def __len__(self) -> Int:
        return self.remaining

    def __has_next__(self) -> Bool:
        return self.remaining != 0


def allocate_zeroed_words(count: Int) raises -> WordPointer:
    if count == 0:
        return WordPointer(unsafe_from_address=EMPTY_POINTER_ADDRESS)

    var address = external_call["mmap", UInt](
        Optional[Pointer[NoneType, MutUntrackedOrigin]](),
        count * WORD_BYTES,
        c_int(PROT_READ | PROT_WRITE),
        c_int(MAP_PRIVATE | MAP_ANONYMOUS),
        c_int(NO_FILE_DESCRIPTOR),
        c_long(0),
    )

    if Int(address) == MAP_FAILED:
        raise Error("cannot allocate bitset")

    return WordPointer(unsafe_from_address=Int(address))


def release_words(pointer: WordPointer, count: Int):
    if count != 0:
        _ = external_call["munmap", c_int](pointer, count * WORD_BYTES)


struct OffsetBitset(Boolable, Iterable, Movable, Sized):
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = OffsetBitsetIterator[iterable_origin]

    var _words: WordPointer
    var _summary: WordPointer
    var _bit_size: Int
    var _word_count: Int
    var _summary_count: Int
    var _size: Int

    def __init__(out self, bit_size: Int) raises:
        self._bit_size = bit_size
        self._word_count = words_needed(bit_size)
        self._summary_count = words_needed(self._word_count)
        self._words = allocate_zeroed_words(self._word_count)
        self._summary = allocate_zeroed_words(self._summary_count)
        self._size = 0

    def __deinit__(deinit self):
        release_words(self._words, self._word_count)
        release_words(self._summary, self._summary_count)

    def __len__(self) -> Int:
        return self._size

    def __bool__(self) -> Bool:
        return self._size != 0

    def __contains__(self, offset: Int) -> Bool:
        return (
            self._words[unsafe_offset=word_index(offset)] & bit_mask(offset)
        ) != 0

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return {
            Pointer(to=self),
            self.first_in_range(0, self._bit_size),
            self._bit_size,
            len(self),
        }

    @always_inline
    def add(mut self, offset: Int) -> Bool:
        var index = word_index(offset)
        var mask = bit_mask(offset)
        var previous = self._words[unsafe_offset=index]

        if (previous & mask) != 0:
            return False

        if previous == 0:
            self._summary[unsafe_offset=word_index(index)] |= bit_mask(index)

        self._words[unsafe_offset=index] = previous | mask
        self._size += 1

        return True

    def discard(mut self, offset: Int):
        var index = word_index(offset)
        var mask = bit_mask(offset)
        var previous = self._words[unsafe_offset=index]

        if (previous & mask) == 0:
            return

        var next = previous & ~mask
        self._words[unsafe_offset=index] = next

        if next == 0:
            self._summary[unsafe_offset=word_index(index)] &= ~bit_mask(index)

        self._size -= 1

    def last_before(self, offset: Int) -> Int:
        if offset <= 0:
            return -1

        var last_word = word_index(offset - 1)
        var word = last_word

        while word >= 0:
            var summary_index = word_index(word)
            var summary_bits = self._summary[unsafe_offset=summary_index]
            var within_summary = bit_offset(word)

            if within_summary != WORD_MASK:
                summary_bits &= bits_below(within_summary + 1)

            if summary_bits == 0:
                word = word_start(summary_index) - 1
                continue

            word = last_set_offset(summary_index, summary_bits)
            var bits = self._words[unsafe_offset=word]

            if word == last_word and bit_offset(offset) != 0:
                bits &= bits_below(bit_offset(offset))

            if bits != 0:
                return last_set_offset(word, bits)

            word -= 1

        return -1

    def first_in_range(self, start: Int, end: Int) -> Int:
        if start >= end:
            return end

        var first_word = word_index(start)
        var last_word = word_index(end - 1)
        var word = first_word

        while word <= last_word:
            if bit_offset(word) == 0 and last_word - word >= WORD_MASK:
                var summary_index = word_index(word)
                var bits = self._summary[unsafe_offset=summary_index]

                if bits == 0:
                    word += WORD_BITS
                    continue

                word = first_set_offset(summary_index, bits)

            var bits = self._words[unsafe_offset=word]

            if word == first_word:
                bits &= ~UInt64(0) << UInt64(bit_offset(start))

            if word == last_word and bit_offset(end) != 0:
                bits &= bits_below(bit_offset(end))

            if bits != 0:
                return first_set_offset(word, bits)

            word += 1

        return end
