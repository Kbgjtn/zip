const std = @import("std");
const errors = @import("errors.zig");
const truncated = errors.truncated;
const log = std.log.scoped(.zip);

const CompressionMethod = @import("format.zig").CompressionMethod;
const GeneralPurposeFlags = @import("format.zig").GeneralPurposeFlags;
const LocalFileHeader = @import("records/local_file_header.zig").LocalFileHeader;
const Source = @import("source.zig").Source;
// Vendored: std 0.16.0's inflater panics on truncated or corrupt input.
const Decompress = @import("vendor/flate/decompress.zig");

/// One entry of the archive, as `Archive.next` lists it. Every value comes from the central
/// directory header (APPNOTE 4.3.12), with sizes and the local header offset taken from the
/// ZIP64 extra field when the 32-bit fields are escaped (4.5.3). The local header is only
/// read when the entry is opened for reading (`Archive.streamEntry`, `readEntryAlloc`,
/// `extractEntry`), where it must agree with these values.
const Entry = @This();

/// Offset of the local header (APPNOTE 4.4.16).
local_header_offset: u64,
/// Offset of the central directory header this entry came from (APPNOTE 4.3.12).
central_header_offset: u64,
/// Length of the name in the central header (APPNOTE 4.4.10).
name_len: u16,
/// Compression method (APPNOTE 4.4.5).
method: CompressionMethod,
/// General purpose flags (APPNOTE 4.4.4).
flags: GeneralPurposeFlags,
/// CRC-32 of the uncompressed data (APPNOTE 4.4.7).
crc32: u32,
/// Size of the stored data (APPNOTE 4.4.8).
compressed_size: u64,
/// Size after decompression (APPNOTE 4.4.9).
uncompressed_size: u64,

/// Streams the decompressed bytes, which start at `data_start`, into `writer` and returns
/// how many were written. `Archive.streamEntry` is the public way in: it checks the entry
/// and finds `data_start` first. This stays pub only because Archive.zig calls it.
pub fn stream(self: Entry, source: *Source, data_start: u64, writer: *std.Io.Writer) errors.EntryError!u64 {
    // Encrypted entries, the only ones with an encryption header between the local header
    // and the data (APPNOTE 4.3.6), were refused before this.
    const reader = try source.readerAt(data_start);

    var buf: [4 << 10]u8 = undefined;
    var bounded = std.Io.Reader.Limited.init(
        reader,
        .limited(self.compressed_size),
        &buf,
    );

    log.debug("data offset {}", .{data_start});
    log.debug("compression_method {}", .{self.method});
    log.debug("compress_size {}", .{self.compressed_size});
    log.debug("uncompress_size {}", .{self.uncompressed_size});

    switch (self.method) {
        .stored => {
            if (self.compressed_size != self.uncompressed_size) {
                return error.ZipSizeMismatch;
            }

            const actual_crc = try copyExactAndCrc(
                &bounded.interface,
                writer,
                self.uncompressed_size,
            );
            if (actual_crc != self.crc32) return error.ZipCrcMismatch;
            return self.uncompressed_size;
        },
        .deflate => {
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;

            // Incremental read/decompress to a client-provided writer without full buffering.
            var decompress: Decompress = .init(
                &bounded.interface,
                .raw,
                &decompress_buf,
            );

            const actual_crc = inflateExactAndCrc(
                &decompress,
                writer,
                self.uncompressed_size,
            ) catch |err| switch (err) {
                error.ReadFailed => return if (decompress.err) |cause| switch (cause) {
                    error.EndOfStream => error.ZipTruncated,
                    else => error.ZipBadDeflate, // corrupt stream; or return cause directly
                } else err, // null means the file read itself failed
                else => return err,
            };

            if (actual_crc != self.crc32) return error.ZipCrcMismatch;

            // The deflate stream should have consumed the entire compressed
            var trailing: [1]u8 = undefined;
            const n = try bounded.interface.readSliceShort(&trailing);
            if (n != 0) return error.ZipSizeMismatch;

            return self.uncompressed_size;
        },
        // Archive refuses these before calling; kept an error so a direct call can't misread.
        else => return error.ZipUnsupportedMethod,
    }
}

/// Inflates exactly `expected_size` bytes, then reads the deflate stream to its end
/// (final block, APPNOTE 4.4.5 method 8) so `source` holds only what follows it.
fn inflateExactAndCrc(
    decompress: *Decompress,
    dest: *std.Io.Writer,
    expected_size: u64,
) !u32 {
    // A clean end before expected_size means the final block came early: the stream is
    // whole but shorter than declared. A cut-short file fails as ReadFailed instead.
    const crc = copyExactAndCrc(&decompress.reader, dest, expected_size) catch |err| switch (err) {
        error.ZipTruncated => return error.ZipSizeMismatch,
        else => return err,
    };

    // Needed even for an empty entry: its stream is still a final block (`03 00`),
    // and nothing above pulls it out when expected_size is 0.
    var extra: [1]u8 = undefined;
    if (try decompress.reader.readSliceShort(&extra) != 0) return error.ZipSizeMismatch;
    return crc;
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

/// Writes the entry under `dst`, its data starting at `data_start`. `Archive.extractEntry`
/// is the public way in: it checks and refuses the entry before anything is created on
/// disk. This stays pub only because Archive.zig calls it.
pub fn extract(self: Entry, io: std.Io, source: *Source, data_start: u64, dst: std.Io.Dir, options: ExtractOptions) !void {
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    const filename = try self.filaneme(source, &filename_buf);

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

    // stream returns exactly uncompressed_size or an error.
    _ = try self.stream(source, data_start, &writer.interface);
    try writer.interface.flush();
}

/// Compression method enum:
pub fn compression(self: Entry) CompressionMethod {
    return self.method;
}

/// Verify integrity post-extract; required for all ZIP tools.
pub fn crc32Checksum(self: Entry) u32 {
    return self.crc32;
}

/// read the current entry filename (path) with the given filename buffer
pub fn filaneme(self: Entry, source: *Source, buffer: []u8) ![]u8 {
    if (buffer.len < self.name_len) return error.InsufficientBufferSize;
    const reader = try source.readerAt(self.local_header_offset + LocalFileHeader.size);
    const fname = buffer[0..self.name_len];
    reader.readSliceAll(fname) catch |err| return truncated(err);
    return fname;
}

// NOTE! stolen from std.zip:
// [](https://github.com/ziglang/zig/blob/738d2be9d6b6ef3ff3559130c05159ef53336224/lib/std/zip.zig#L208C1-L220C2)
fn isBadFileName(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/')
        return true;

    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".."))
            return true;
    }

    return false;
}
