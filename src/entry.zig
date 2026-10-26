const std = @import("std");
const log = std.log.scoped(.zip);

const CompressionMethod = @import("format.zig").CompressionMethod;
const LocalFileHeader = @import("records/local_file_header.zig").LocalFileHeader;

/// File Data Entry where the extract stream-reader should be immediately following the local
/// header for a file SHOULD be placed the compressed or stored data for the file. If the file
/// is encrypted, the encryption header for the file SHOULD be placed after the local header and
/// before the file data.
///
/// The series of [local file header][encryption header] [file data][data descriptor] repeats for
/// each file in the .ZIP archive.
///
/// Zero-byte files, directories, and other file types that contain no content MUST NOT include
/// file data. Data Descriptor (Optional) Although not originally assigned a signature, the value
/// 0x08074b50 has commonly been adopted as a signature value for the data descriptor record.
/// When the Central Directory Encryption method is used, the data descriptor record is not required,
/// but MAY be used. If present, and bit 3 of the general purpose bit field is set to indicate its
/// presence, the values in fields of the data descriptor record MUST be set to binary zeros.
pub const FileData = struct {
    offset: u64,
    compressed_size: u64,
    uncompressed_size: u64,
    // TODO (dapa)  unwrap this

    header: LocalFileHeader,

    fn logicalOffset(self: FileData) u64 {
        return self.offset +
            LocalFileHeader.size +
            self.header.extra_len +
            self.header.filename_len;
    }

    // allows writing directly to a file or buffer without allocating the entire file in memory
    pub fn stream(self: FileData, reader: *std.Io.File.Reader, writer: *std.Io.Writer) !usize {
        // if flags.encrypted might need to read the encryption header
        if (self.header.flags.encrypted) return error.NotImplemented;

        // Use offset to seek to the start of the file's data
        // immediately after LFH and optional encryption header.
        const offset = self.logicalOffset();
        try reader.seekTo(offset);

        log.debug("seek {}", .{reader.interface.seek});
        log.debug("compression_method {}", .{self.header.compression_method});
        log.debug("compress_size {}", .{self.compressed_size});
        log.debug("uncompress_size {}", .{self.uncompressed_size});

        const crc32_checksum = self.header.crc32;

        switch (self.header.compression_method) {
            .stored => {
                if (self.compressed_size != self.uncompressed_size) {
                    return error.ZipSizeMismatch;
                }

                const actual_crc = try copyExactAndCrc(
                    &reader.interface,
                    writer,
                    self.uncompressed_size,
                );
                if (actual_crc != crc32_checksum) return error.ZipCRC32Mismatch;
                return self.uncompressed_size;
            },
            .deflate => {
                const history_len = 32768;
                const max_window_len = history_len * 2;
                var decompress_buf: [max_window_len]u8 = undefined;

                // Incremental read/decompress to a client-provided writer without full buffering.
                var decompress: std.compress.flate.Decompress = .init(
                    &reader.interface,
                    .raw,
                    &decompress_buf,
                );

                const actual_crc = try copyExactAndCrc(
                    &decompress.reader,
                    writer,
                    self.uncompressed_size,
                );

                if (actual_crc != crc32_checksum) return error.ZipCRC32Mismatch;
                return self.uncompressed_size;
            },
            else => return error.ZipUnsupportedCompressionMethod,
        }
    }

    fn copyExactAndCrc(
        source: *std.Io.Reader,
        dest: *std.Io.Writer,
        expected_size: u64,
    ) !u32 {
        var crc = std.hash.Crc32.init();
        var total: u64 = 0;
        var chunk: [8 << 10]u8 = undefined;

        while (total < expected_size) {
            const remaining = expected_size - total;
            const chunk_len: usize = @intCast(@min(remaining, 8 << 10));
            const n = source.readSliceShort(chunk[0..chunk_len]) catch |err| switch (err) {
                else => return err,
            };

            if (n == 0) return error.ZipTruncated;

            crc.update(chunk[0..n]);
            try dest.writeAll(chunk[0..n]);
            total += @intCast(n);
        }

        return crc.final();
    }

    pub const FileExistsBehavior = enum {
        fail, // Return error.PathAlreadyExists (default, matches std lib)
        skip, // Skip extraction of existing files
        overwrite, // Overwrite existing files
    };

    pub const ExtractOptions = struct {
        file_exists_behavior: FileExistsBehavior = .fail,
    };

    pub fn extract(self: FileData, io: std.Io, reader: *std.Io.File.Reader, dst: std.Io.Dir, options: ExtractOptions) !void {
        var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
        const filename = try self.filaneme(reader, filename_buf[0..self.header.filename_len]);

        if (isBadFileName(filename)) return error.ZipBadFileName;

        // All entries that end in '/' are directories
        if (filename[filename.len - 1] == '/') {
            if (self.uncompressed_size != 0) return error.ZipBadDirectorySize;
            try dst.createDir(io, filename[0 .. filename.len - 1], .default_dir);
            return;
        }

        const out_file = blk: {
            if (std.fs.path.dirname(filename)) |dirname| {
                var parent_dir = try dst.createDirPathOpen(io, dirname, .{});
                defer parent_dir.close(io);
                const basename = std.fs.path.basename(filename);
                break :blk parent_dir.createFile(io, basename, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => switch (options.file_exists_behavior) {
                        .fail => return err,
                        .overwrite => break :blk try parent_dir.createFile(io, basename, .{}),
                        .skip => return,
                    },
                    else => |e| return e,
                };
            }
            break :blk dst.createFile(io, filename, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => switch (options.file_exists_behavior) {
                    .fail => return err,
                    .overwrite => break :blk try dst.createFile(io, filename, .{}),
                    .skip => return,
                },
                else => |e| return e,
            };
        };

        defer out_file.close(io);

        var writer_buf: [4096]u8 = undefined;
        var writer = out_file.writer(io, &writer_buf);

        const n = try self.stream(reader, &writer.interface);
        if (n != self.uncompressed_size) {
            return error.ZipMalformed;
        }
        try writer.interface.flush();
    }

    // utility functions

    /// Compression method enum:
    pub fn compression(self: FileData) CompressionMethod {
        return self.header.compression_method;
    }

    /// Verify integrity post-extract; required for all ZIP tools.
    pub fn crc32Checksum(self: FileData) u32 {
        return self.header.crc32;
    }

    /// Check general purpose bit 0; clients must handle auth headers.
    pub fn is_encypted(self: FileData) bool {
        return self.header.flags.encrypted;
    }

    /// read the current entry filename (path) with the given filename buffer
    pub fn filaneme(self: FileData, reader: *std.Io.File.Reader, buffer: []u8) ![]u8 {
        if (buffer.len < self.header.filename_len) return error.InsufficientBufferSize;
        try reader.seekTo(self.offset + LocalFileHeader.size);
        const fname = buffer[0..self.header.filename_len];
        try reader.interface.readSliceAll(fname);
        return fname[0..self.header.filename_len];
    }
};

// NOTE! stolen from std.zip:
// [](https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/zip.zig#L208C1-L220C2)
pub fn isBadFileName(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/')
        return true;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}

fn firstEntryStreamResult(path: []const u8) !usize {
    const io = std.testing.io;
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try @import("iterator.zig").Iterator.init(&reader);
    const fd = (try iter.next()) orelse return error.TestUnexpectedEmptyArchive;

    var out_buf: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&out_buf);
    return fd.stream(&reader, &discard.writer);
}

test "entry: deflate stream shorter than the declared uncompressed size is an error" {
    // testdata/hostile/deflate_short_output.zip: a complete deflate stream inflating to 500
    // bytes, headers say 600 (see scripts/gen-hostile.py). Must not report success.
    if (firstEntryStreamResult("testdata/hostile/deflate_short_output.zip")) |n| {
        log.err("stream returned {d} bytes instead of an error", .{n});
        return error.TestExpectedError;
    } else |_| {}
}

test "entry: deflate stream cut short is an error" {
    // testdata/hostile/deflate_truncated.zip: 8192-byte entry whose deflate data is cut in half;
    // compressed_size matches the bytes present. Python's zipfile reports Bad CRC-32.
    if (firstEntryStreamResult("testdata/hostile/deflate_truncated.zip")) |n| {
        log.err("stream returned {d} bytes instead of an error", .{n});
        return error.TestExpectedError;
    } else |_| {}
}

test "entry: stored entry with a corrupted byte fails the CRC-32 check" {
    // testdata/hostile/stored_bad_crc.zip: one payload byte flipped, sizes all correct,
    // header CRC is for the original bytes (see scripts/gen-hostile.py).
    try std.testing.expectError(
        error.ZipCRC32Mismatch,
        firstEntryStreamResult("testdata/hostile/stored_bad_crc.zip"),
    );
}

test "entry: deflated entry with a corrupted byte is an error" {
    // testdata/hostile/deflate_bad_crc.zip: one byte flipped mid-stream. Either the
    // inflater or the CRC-32 check must reject it.
    if (firstEntryStreamResult("testdata/hostile/deflate_bad_crc.zip")) |n| {
        log.err("stream returned {d} bytes instead of an error", .{n});
        return error.TestExpectedError;
    } else |_| {}
}
