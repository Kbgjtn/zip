const std = @import("std");
const log = std.log.scoped(.zip);

const eocd_signature_bytes = @import("../format.zig").eocd_signature_bytes;
const eocd_size = @import("../format.zig").eocd_size;
const max_u16 = @import("../format.zig").max_u16;

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

        const max_record_len = eocd_size + max_u16;
        var buffer: [max_record_len]u8 = undefined;
        const search_limit = @min(file_size, buffer.len);

        var loaded_len: usize = 0;
        var comment_len: u16 = 0;

        const base_file_offset = file_size - search_limit;

        while (comment_len <= max_u16) {
            const record_len = @as(usize, comment_len) + eocd_size;
            if (record_len > search_limit) {
                return error.ZipNoEndRecord;
            }

            try ensureLoaded(f, file_size, buffer[buffer.len - search_limit ..], &loaded_len, record_len);

            // [file data .............][ EOCD header ][ comment ]
            //                             ^ start
            const record_offset = search_limit - record_len;
            const window_start = buffer.len - search_limit;
            const record_start = window_start + record_offset;
            const record_bytes = buffer[record_start..][0..eocd_size];

            if (isValidEndRecord(record_bytes, comment_len)) {
                return .{
                    .record = parse(record_bytes),
                    .offset = base_file_offset + record_offset,
                };
            }

            comment_len += 1;
        }
    }

    pub fn validateStructure(
        self: EndOfCentralDirectoryRecord,
        file_size: u64,
        offset: u64,
    ) error{ ZipMalformed, ZipUnsupportedMultiDisk }!void {
        // no multi-disk support
        if (self.disk_number != 0 or
            self.central_directory_disk_number != 0 or
            self.record_count_disk != self.record_count_total)
        {
            return error.ZipUnsupportedMultiDisk;
        }

        // validate comment lenght consistency
        const expected_end = std.math.add(u64, offset, size) catch return error.ZipMalformed;
        const actual_end = std.math.add(u64, expected_end, self.comment_len) catch return error.ZipMalformed;
        if (actual_end != file_size) {
            return error.ZipMalformed;
        }
    }

    pub fn validateSizeFields(self: EndOfCentralDirectoryRecord, file_size: u64) error{
        ZipSizeOverflow,
        ZipEmptyArchive,
        ZipUnsupportedMultiDisk,
    }!void {
        if (self.central_directory_offset >= file_size) {
            return error.ZipSizeOverflow;
        }

        if (self.record_count_total == 0) {
            return error.ZipEmptyArchive;
        }

        const end = std.math.add(
            u64,
            self.central_directory_offset,
            self.central_directory_size,
        ) catch return error.ZipSizeOverflow;

        if (end > file_size) return error.ZipSizeOverflow;
    }

    pub fn getOffset(self: EndOfCentralDirectoryRecord) usize {
        return self.central_directory_size + self.central_directory_offset;
    }

    pub fn readComment(
        reader: *std.Io.File.Reader,
        file_size: u64,
        offset: u64,
        comment_len: u64,
        buf: []u8,
    ) ![]u8 {
        if (comment_len == 0) return buf[0..0];

        if (buf.len < comment_len) {
            return error.InsufficientBufferSize;
        }

        const comment_offset = offset + eocd_size;
        const comment_end = try std.math.add(u64, comment_offset, comment_len);

        if (comment_end != file_size) {
            return error.InvalidZipStructure;
        }

        try reader.seekTo(comment_offset);

        const out = buf[0..comment_len];
        try reader.interface.readSliceAll(out);
        return out;
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
        if (!std.mem.eql(u8, record_bytes[0..4], &eocd_signature_bytes)) {
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
