from std.ffi import c_int, c_long, external_call
from std.memory import Pointer, unsafe_memcpy

comptime HEADER_SIZE = 24
comptime IMPORT_ENTRY_SIZE = 4
comptime PUBLIC_ENTRY_SIZE = 9
comptime PUBLIC_OFFSET_IN_ENTRY = 4
comptime PUBLIC_FLAG_IN_ENTRY = 8
comptime BytePointer = Pointer[UInt8, MutUntrackedOrigin]


def load_i32(data: BytePointer, position: Int) -> Int:
    return Int(data.unsafe_offset(position).unsafe_bitcast[Int32]()[])


def load_i32(data: List[UInt8], position: Int) -> Int:
    var value = 0

    for index in range(4):
        value |= Int(data[position + index]) << (8 * index)

    if value >= 0x80000000:
        value -= 0x100000000

    return value


def pointer_slice(data: BytePointer, start: Int, end: Int) -> List[UInt8]:
    var result = List[UInt8](unsafe_uninit_length=end - start)
    unsafe_memcpy(
        dest=result.unsafe_ptr(),
        src=data.unsafe_offset(start),
        count=end - start,
    )
    return result^


struct Unit(Movable):
    var file_path: String
    var data: BytePointer
    var image_size: Int
    var strings_size: Int
    var globals_count: Int
    var imports_count: Int
    var publics_count: Int
    var imports_start: Int
    var publics_start: Int
    var code_start: Int
    var strings_last_nul_plus_one: Int

    def __init__(out self, path: String) raises:
        self.file_path = path
        var fd = external_call["open", c_int](self.file_path.unsafe_ptr(), 0)

        if fd < 0:
            raise Error(self.file_path + ": cannot open bytecode file")

        var size = Int(external_call["lseek", c_long](fd, c_long(0), c_int(2)))

        if size < 0:
            _ = external_call["close", c_int](fd)
            raise Error(
                self.file_path + ": cannot determine bytecode file size"
            )

        self.image_size = size

        if size == 0:
            self.data = BytePointer(unsafe_from_address=1)
        else:
            var address = external_call["mmap", UInt](
                Optional[Pointer[NoneType, MutUntrackedOrigin]](),
                size,
                c_int(1),
                c_int(2),
                fd,
                c_long(0),
            )
            if Int(address) == -1:
                _ = external_call["close", c_int](fd)
                raise Error(self.file_path + ": cannot map bytecode file")
            self.data = BytePointer(unsafe_from_address=Int(address))
        _ = external_call["close", c_int](fd)
        self.strings_size = 0
        self.globals_count = 0
        self.imports_count = 0
        self.publics_count = 0
        self.imports_start = HEADER_SIZE
        self.publics_start = HEADER_SIZE
        self.code_start = HEADER_SIZE
        self.strings_last_nul_plus_one = 0
        self.parse_header()

    def __deinit__(deinit self):
        if self.image_size > 0:
            _ = external_call["munmap", c_int](self.data, self.image_size)

    def fail(self, source: Int, message: String) raises:
        raise Error(self.file_path + ": " + message)

    def code_size(self) -> Int:
        return self.image_size - self.code_start

    def code_byte(self, offset: Int) -> UInt8:
        return self.data[unsafe_offset=self.code_start + offset]

    def code_slice(self, start: Int, end: Int) -> List[UInt8]:
        return pointer_slice(
            self.data, self.code_start + start, self.code_start + end
        )

    def public_flag(self, index: Int) -> Int:
        return Int(
            self.data[
                unsafe_offset=self.publics_start
                + index * PUBLIC_ENTRY_SIZE
                + PUBLIC_FLAG_IN_ENTRY
            ]
        )

    def public_offset(self, index: Int) -> Int:
        return load_i32(
            self.data,
            self.publics_start
            + index * PUBLIC_ENTRY_SIZE
            + PUBLIC_OFFSET_IN_ENTRY,
        )

    def public_name(self, index: Int) -> Int:
        return load_i32(
            self.data, self.publics_start + index * PUBLIC_ENTRY_SIZE
        )

    def string_bytes(self, offset: Int, source: Int) raises -> List[UInt8]:
        if offset < 0 or offset >= self.strings_size:
            self.fail(
                source,
                "string table offset "
                + String(offset)
                + " is out of range [0, "
                + String(self.strings_size)
                + ")",
            )

        if (
            self.strings_last_nul_plus_one == 0
            or offset >= self.strings_last_nul_plus_one
        ):
            self.fail(
                source,
                "string at table offset "
                + String(offset)
                + " is not NUL-terminated",
            )

        var end = offset

        while self.data[unsafe_offset=HEADER_SIZE + end] != 0:
            end += 1

        return pointer_slice(self.data, HEADER_SIZE + offset, HEADER_SIZE + end)

    def external_string(
        self, reference: Int, source: Int
    ) raises -> List[UInt8]:
        var offset = -reference - 1

        if offset < 0 or offset > 0x7FFFFFFF:
            self.fail(source, "invalid external reference " + String(reference))

        return self.string_bytes(offset, source)

    def parse_header(mut self) raises:
        if self.image_size < HEADER_SIZE:
            self.fail(
                -1,
                "short bytecode header ("
                + String(self.image_size)
                + " bytes, need 24)",
            )
        if (
            self.data[unsafe_offset=0] != 76
            or self.data[unsafe_offset=1] != 97
            or self.data[unsafe_offset=2] != 77
            or self.data[unsafe_offset=3] != 97
        ):
            self.fail(-1, 'bad magic, expected "LaMa"')

        var version = load_i32(self.data, 4)
        self.strings_size = load_i32(self.data, 8)
        self.globals_count = load_i32(self.data, 12)
        self.imports_count = load_i32(self.data, 16)
        self.publics_count = load_i32(self.data, 20)

        if version != 1:
            self.fail(
                -1,
                "unsupported bytecode version "
                + String(version)
                + " (expected 1)",
            )

        if self.strings_size < 0:
            self.fail(
                -1, "negative string table size " + String(self.strings_size)
            )

        if self.globals_count < 0:
            self.fail(
                -1, "negative globals count " + String(self.globals_count)
            )

        if self.imports_count < 0:
            self.fail(
                -1, "negative imports count " + String(self.imports_count)
            )

        if self.publics_count < 0:
            self.fail(
                -1,
                "negative public symbols count " + String(self.publics_count),
            )

        var strings_end = HEADER_SIZE + self.strings_size
        self.imports_start = strings_end
        self.publics_start = (
            strings_end + self.imports_count * IMPORT_ENTRY_SIZE
        )
        self.code_start = (
            self.publics_start + self.publics_count * PUBLIC_ENTRY_SIZE
        )

        if self.code_start > self.image_size:
            self.fail(
                -1,
                "truncated file: need "
                + String(self.code_start)
                + " bytes for sections, have "
                + String(self.image_size),
            )

        if self.code_start == self.image_size:
            self.fail(-1, "missing code section")

        if self.code_size() > 0x7FFFFFFF:
            self.fail(
                -1, "code section is too large: " + String(self.code_size())
            )

        for index in range(self.strings_size - 1, -1, -1):
            if self.data[unsafe_offset=HEADER_SIZE + index] == 0:
                self.strings_last_nul_plus_one = index + 1
                break

        for index in range(self.imports_count):
            _ = self.string_bytes(
                load_i32(
                    self.data, self.imports_start + index * IMPORT_ENTRY_SIZE
                ),
                -1,
            )

        var names = Dict[List[UInt8], Int]()

        for index in range(self.publics_count):
            var offset = self.public_offset(index)
            var flag = self.public_flag(index)
            var name = self.string_bytes(self.public_name(index), -1)

            if flag > 1:
                self.fail(
                    -1,
                    "public symbol "
                    + String(index)
                    + " has invalid flag "
                    + String(flag),
                )

            if flag == 1 and (offset < 0 or offset >= self.globals_count):
                self.fail(
                    -1,
                    "public global "
                    + String(index)
                    + " index "
                    + String(offset)
                    + " is out of range [0, "
                    + String(self.globals_count)
                    + ")",
                )

            if flag == 0 and (offset < 0 or offset >= self.code_size() - 1):
                self.fail(
                    -1,
                    "public function "
                    + String(index)
                    + " code offset "
                    + String(offset)
                    + " is out of range",
                )
            var namespace = names.get(name, 0)

            if (namespace & (1 << flag)) != 0:
                self.fail(-1, "duplicate public symbol")

            names[name^] = namespace | (1 << flag)
