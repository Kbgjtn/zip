const std = @import("std");
const log = std.log.scoped(.zip);

const eocd_size = @import("../format.zig").eocd_size;

pub const EndOfCentralDirectoryRecord = extern struct {
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

    const max_comment_len: usize = 0xFFFF;
    const max_eocd_len = eocd_size + max_comment_len;

    pub const signature_marker: u32 = 0x0605_4B50;
    const size: u64 = 22;

    /// [4.4.1 General notes on fields] (https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)
    /// 4.4.1.4  If one of the fields in the end of central directory
    /// record is too small to hold required data, the field SHOULD be
    /// set to -1 (0xFFFF or 0xFFFFFFFF) and the ZIP64 format record
    /// SHOULD be created.
    ///
    /// 4.4.1.5  The end of central directory record and the Zip64 end
    /// of central directory locator record MUST reside on the same
    /// disk when splitting or spanning an archive.
    pub fn requiresZip64(self: EndOfCentralDirectoryRecord) bool {
        return self.record_count_total == 0xFFFF or
            self.record_count_disk == 0xFFFF or
            self.central_directory_size == 0xFFFFFFFF or
            self.central_directory_offset == 0xFFFFFFFF;
    }

    pub fn read(f: *std.Io.File.Reader) !struct { offset: u64, record: EndOfCentralDirectoryRecord } {
        const file_size: u64 = try f.getSize();
        if (file_size < eocd_size) {
            return error.ZipNoEndRecord;
        }

        const max_record_len = eocd_size + std.math.maxInt(u16);
        var buffer: [max_record_len]u8 = undefined;

        var loaded_len: usize = 0;
        var comment_len: usize = 0;

        var search_limit: usize = file_size;
        search_limit = @min(search_limit, max_eocd_len);
        const base_file_offset = file_size - search_limit;

        while (comment_len <= max_comment_len) : (comment_len += 1) {
            const record_len = eocd_size + comment_len;
            if (record_len > search_limit) break;

            try ensureLoaded(
                f,
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
            const record_bytes = buffer[record_start..][0..eocd_size];

            if (isValidEndRecord(record_bytes, @intCast(comment_len))) {
                return .{
                    .record = parse(record_bytes),
                    .offset = base_file_offset + record_offset,
                };
            }
        }

        return error.ZipNoEndRecord;
    }

    pub fn validateStructure(
        self: EndOfCentralDirectoryRecord,
        file_size: u64,
        offset: u64,
    ) error{ ZipMalformed, ZipMultiDisk }!void {
        // no multi-disk support
        if (self.disk_number != 0 or
            self.central_directory_disk_number != 0 or
            self.record_count_disk != self.record_count_total)
        {
            return error.ZipMultiDisk;
        }

        // The comment must end exactly at the end of the file.
        if (offset + size + self.comment_len != file_size) return error.ZipMalformed;
    }

    pub fn validateSizeFields(self: EndOfCentralDirectoryRecord, file_size: u64) error{ZipMalformed}!void {
        if (self.central_directory_offset >= file_size) return error.ZipMalformed;
        // Two u32 fields can't overflow a u64.
        if (@as(u64, self.central_directory_offset) + self.central_directory_size > file_size) {
            return error.ZipMalformed;
        }
    }

    fn parse(bytes: []const u8) EndOfCentralDirectoryRecord {
        return EndOfCentralDirectoryRecord{
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

    fn isValidEndRecord(record_bytes: []const u8, expected_comment_len: u16) bool {
        if (std.mem.readInt(u32, record_bytes[0..4], .little) != signature_marker) {
            return false;
        }
        const actual_comment_len = std.mem.readInt(u16, record_bytes[20..22], .little);
        return actual_comment_len == expected_comment_len;
    }

    fn ensureLoaded(
        file_reader: *std.Io.File.Reader,
        file_size: u64,
        buf: []u8,
        loaded_len: *usize,
        required_len: usize,
    ) !void {
        const step: u16 = 512;
        while (required_len > loaded_len.*) {
            const new_loaded = @min(loaded_len.* + step, buf.len);
            const n = new_loaded - loaded_len.*;

            try file_reader.seekTo(file_size - new_loaded);
            const target = buf[buf.len - new_loaded ..][0..n];
            try file_reader.interface.readSliceAll(target);

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

fn readEndRecordOf(path: []const u8) !EndOfCentralDirectoryRecord {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const found = try EndOfCentralDirectoryRecord.read(&reader);
    return found.record;
}

test "eocd: signature marker is PK 5 6" {
    try std.testing.expectEqual(std.mem.readInt(u32, &[_]u8{ 'P', 'K', 5, 6 }, .little), EndOfCentralDirectoryRecord.signature_marker);
}

test "eocd: file smaller than 22 bytes is a clean ZipNoEndRecord" {
    // testdata/hostile/tiny.zip: 10 bytes (EOCD signature + 6 zeros), see scripts/gen-hostile.py.
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
