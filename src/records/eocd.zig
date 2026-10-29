const std = @import("std");

const truncated = @import("../errors.zig").truncated;
const Source = @import("../source.zig").Source;

const EndRecord64 = @import("eocd64.zig").EndRecord64;

pub const EndRecord = extern struct {
    signature: u32 align(1),
    disk_number: u16 align(1),
    central_directory_disk_number: u16 align(1),
    record_count_disk: u16 align(1),
    record_count_total: u16 align(1),
    central_directory_size: u32 align(1),
    central_directory_offset: u32 align(1),
    comment_len: u16 align(1),
    // fixed size is 22
    // ...
    // comment (variable size)

    pub const size: u64 = 22;
    const max_comment_len: usize = 0xFFFF;
    const max_eocd_len = size + max_comment_len;

    pub const signature_marker: u32 = 0x0605_4B50;

    /// [4.4.1 General notes on fields] (https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
    /// 4.4.1.4  If one of the fields in the end of central directory
    /// record is too small to hold required data, the field SHOULD be
    /// set to -1 (0xFFFF or 0xFFFFFFFF) and the ZIP64 format record
    /// SHOULD be created.
    ///
    /// 4.4.1.5  The end of central directory record and the Zip64 end
    /// of central directory locator record MUST reside on the same
    /// disk when splitting or spanning an archive.
    pub fn requiresZip64(self: EndRecord) bool {
        return self.record_count_total == 0xFFFF or
            self.record_count_disk == 0xFFFF or
            self.central_directory_size == 0xFFFFFFFF or
            self.central_directory_offset == 0xFFFFFFFF;
    }

    /// When the EOCD escapes a field, the real value is in the ZIP64 end record (APPNOTE 4.4.1.4).
    /// A field that isn't escaped must still equal its ZIP64 value (4.3.16), or the two records
    /// describe different archives.
    pub fn validateZip64Agrees(self: EndRecord, r64: EndRecord64) error{ZipCentralDirectoryMismatch}!void {
        const agrees =
            (self.record_count_disk == 0xFFFF or self.record_count_disk == r64.record_count_disk) and
            (self.record_count_total == 0xFFFF or self.record_count_total == r64.record_count_total) and
            (self.central_directory_size == 0xFFFFFFFF or self.central_directory_size == r64.central_directory_size) and
            (self.central_directory_offset == 0xFFFFFFFF or self.central_directory_offset == r64.central_directory_offset);
        if (!agrees) return error.ZipCentralDirectoryMismatch;
    }

    /// Finds the end record by scanning backward from the end of the file (APPNOTE 4.3.16):
    /// the candidate at `room` bytes before the last 22 is valid when it starts with the
    /// signature and its comment fills those `room` bytes exactly (`strict_trailing_bytes`)
    /// or fits in them. `room` runs 0 to 65,535, the longest comment, so the first valid
    /// candidate is the one nearest the end of the file.
    pub fn read(source: *Source, strict_trailing_bytes: bool) !struct { offset: u64, record: EndRecord } {
        const file_size: u64 = try source.size();
        if (file_size < size) {
            return error.ZipNoEndRecord;
        }

        var buffer: [max_eocd_len]u8 = undefined;

        var loaded_len: usize = 0;
        // Bytes between the candidate's fixed 22 bytes and the end of the file. usize, not
        // u16: the loop must reach 65,535 and then stop.
        var room: usize = 0;

        var search_limit: usize = file_size;
        search_limit = @min(search_limit, max_eocd_len);
        const base_file_offset = file_size - search_limit;

        while (room <= max_comment_len) : (room += 1) {
            const record_len = size + room;
            if (record_len > search_limit) break;

            try ensureLoaded(
                source,
                file_size,
                buffer[buffer.len - search_limit ..],
                &loaded_len,
                record_len,
            );

            // [file data .............][ EOCD header ][ comment ]
            //                             ^ start
            const record_offset = search_limit - record_len;
            const window_start = buffer.len - search_limit;
            const record_start = window_start + record_offset;
            const record_bytes = buffer[record_start..][0..size];

            if (isValidEndRecord(record_bytes, @intCast(room), strict_trailing_bytes)) {
                return .{
                    .record = parse(record_bytes),
                    .offset = base_file_offset + record_offset,
                };
            }
        }

        return error.ZipNoEndRecord;
    }

    pub fn validateStructure(
        self: EndRecord,
        file_size: u64,
        offset: u64,
        strict_trailing_bytes: bool,
    ) error{ ZipMalformed, ZipMultiDisk }!void {
        // no multi-disk support
        if (self.disk_number != 0 or
            self.central_directory_disk_number != 0 or
            self.record_count_disk != self.record_count_total)
        {
            return error.ZipMultiDisk;
        }

        // The comment must end at the end of the file, or before it when trailing bytes are
        // allowed. `offset` is inside the file, so this can't overflow.
        const comment_end = offset + size + self.comment_len;
        if (comment_end > file_size) return error.ZipMalformed;
        if (strict_trailing_bytes and comment_end != file_size) return error.ZipMalformed;
    }

    pub fn validateSizeFields(self: EndRecord, file_size: u64) error{ZipMalformed}!void {
        if (self.central_directory_offset >= file_size) return error.ZipMalformed;
        // Two u32 fields can't overflow a u64.
        if (@as(u64, self.central_directory_offset) + self.central_directory_size > file_size) {
            return error.ZipMalformed;
        }
    }

    fn parse(bytes: []const u8) EndRecord {
        return EndRecord{
            .signature = std.mem.readInt(u32, bytes[0..4], .little),
            .disk_number = std.mem.readInt(u16, bytes[4..6], .little),
            .central_directory_disk_number = std.mem.readInt(u16, bytes[6..8], .little),
            .record_count_disk = std.mem.readInt(u16, bytes[8..10], .little),
            .record_count_total = std.mem.readInt(u16, bytes[10..12], .little),
            .central_directory_size = std.mem.readInt(u32, bytes[12..16], .little),
            .central_directory_offset = std.mem.readInt(u32, bytes[16..20], .little),
            .comment_len = std.mem.readInt(u16, bytes[20..22], .little),
        };
    }

    /// Whether `record_bytes` starts an end record whose comment fills the `room` bytes left
    /// before the end of the file (strict), or fits in them.
    fn isValidEndRecord(record_bytes: []const u8, room: u16, strict_trailing_bytes: bool) bool {
        if (std.mem.readInt(u32, record_bytes[0..4], .little) != signature_marker) {
            return false;
        }
        const comment_len = std.mem.readInt(u16, record_bytes[20..22], .little);
        return if (strict_trailing_bytes) comment_len == room else comment_len <= room;
    }

    fn ensureLoaded(
        source: *Source,
        file_size: u64,
        buf: []u8,
        loaded_len: *usize,
        required_len: usize,
    ) !void {
        const step: u16 = 512;
        while (required_len > loaded_len.*) {
            const new_loaded = @min(loaded_len.* + step, buf.len);
            const n = new_loaded - loaded_len.*;

            const reader = try source.readerAt(file_size - new_loaded);
            const target = buf[buf.len - new_loaded ..][0..n];
            reader.readSliceAll(target) catch |err| return truncated(err);

            loaded_len.* = new_loaded;
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("End-of-central-directory record\n", .{});
        try writer.print("-------------------------------\n", .{});
        try writer.print("signature                      \t0x{X}\n", .{self.signature});
        try writer.print("disk_number                    \t{d}\n", .{self.disk_number});
        try writer.print("central_directory_disk_number  \t{d}\n", .{self.central_directory_disk_number});
        try writer.print("record_count_disk              \t{d}\n", .{self.record_count_disk});
        try writer.print("record_count_total             \t{d}\n", .{self.record_count_total});
        try writer.print("central_directory_size         \t{d}\n", .{self.central_directory_size});
        try writer.print("central_directory_offset       \t{d}\n", .{self.central_directory_offset});
        try writer.print("comment_len                    \t{d}\n\n", .{self.comment_len});
    }
};

comptime {
    // The struct is parsed and written byte for byte: a field of the wrong width breaks both
    // the scan and the writer's EOCD (APPNOTE 4.3.16: 22 fixed bytes).
    std.debug.assert(@sizeOf(EndRecord) == EndRecord.size);
    // The scan must try every comment length the u16 field can hold, no more (4.4.25).
    std.debug.assert(EndRecord.max_comment_len == std.math.maxInt(@FieldType(EndRecord, "comment_len")));
    // A byte-order slip in the hex means no archive ever opens (4.3.16).
    std.debug.assert(EndRecord.signature_marker == std.mem.readInt(u32, "PK\x05\x06", .little));
}

// NOTE! cases this might appears:
// - Streaming ZIP creation:
//   - the writer doesn't yet know: the final compressed_size, final uncompressed_size, and final crc32
//   - HTTP response stream
//   - Pipe, stdout, cloud object storage stream
// - on-the-fly compression
// - zip64 streaming
// - some libarary defaults
//
// [optional 0x08074b50 signature]
// CRC-32                (4 bytes)
// Compressed size       (4 or 8 bytes ZIP64)
// Uncompressed size     (4 or 8 bytes ZIP64)

fn readEndRecordOf(path: []const u8) !EndRecord {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var source: Source = .fromFile(&reader);
    const found = try EndRecord.read(&source, true);
    return found.record;
}

test "eocd: file smaller than 22 bytes is a clean ZipNoEndRecord" {
    // testdata/hostile/tiny.zip: 10 bytes (EOCD signature + 6 zeros), see scripts/gen-testdata.py.
    try std.testing.expectError(error.ZipNoEndRecord, readEndRecordOf("testdata/hostile/tiny.zip"));
}

test "eocd: comment_len pointing past end of file is a clean ZipNoEndRecord" {
    // testdata/hostile/eocd_bad_comment_len.zip: valid archive, EOCD comment_len patched to 500.
    try std.testing.expectError(error.ZipNoEndRecord, readEndRecordOf("testdata/hostile/eocd_bad_comment_len.zip"));
}

test "eocd: scan of a >64 KiB file with no EOCD returns ZipNoEndRecord without overflowing" {
    // testdata/hostile/no_eocd_70k.zip: 70_000 bytes of 0xAA. The scan must try every
    // comment length 0..65535 and then stop; a u16 counter overflows at 65535.
    try std.testing.expectError(error.ZipNoEndRecord, readEndRecordOf("testdata/hostile/no_eocd_70k.zip"));
}
