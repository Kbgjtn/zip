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

        switch (self.header.compression_method) {
            .stored => {
                const n = try reader.interface.stream(writer, .limited64(self.compressed_size));
                return n;
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

                decompress.reader.streamExact64(writer, self.uncompressed_size) catch |err| switch (err) {
                    error.EndOfStream => {
                        log.debug("error.EndOfStream: {}", .{err == error.EndOfStream});
                    },
                    else => return err,
                };

                return self.uncompressed_size;
            },
            else => return error.ZipUnsupportedCompressionMethod,
        }
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
