const std = @import("std");
const errors = @import("errors.zig");
const truncated = errors.truncated;
const log = std.log.scoped(.zip);

const extra = @import("extra.zig");
const time = @import("time.zig");
const path = @import("path.zig");
const CompressionMethod = @import("format.zig").CompressionMethod;
const GeneralPurposeFlags = @import("format.zig").GeneralPurposeFlags;
const Version = @import("format.zig").Version;
const records = @import("records/root.zig");
const Source = @import("source.zig").Source;
// Vendored: std 0.16.0's inflater panics on truncated or corrupt input.
const Decompress = @import("vendor/flate/decompress.zig");

/// One entry of the archive, as `Archive.next` lists it. Every value comes from the central
/// directory header (APPNOTE 4.3.12), with sizes and the local header offset taken from the
/// ZIP64 extra field when the 32-bit fields are escaped (4.5.3). The local header is only
/// read when the entry is opened for reading (`Archive.streamEntry`, `readEntryAlloc`,
/// `extractEntry`), where it must agree with these values.
const Entry = @This();

const max_path_bytes = std.Io.Dir.max_path_bytes;

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
/// The host system and spec version of the tool that wrote the entry (APPNOTE 4.4.2). Its
/// `os` says how to read `external_attributes`, see `unixMode`.
version_made_by: Version,
/// Host-specific attributes (APPNOTE 4.4.15). On Unix (3) and OS X (19) the high 16 bits
/// are the `st_mode`; for MS-DOS the low byte is the MS-DOS attribute byte, where 0x10
/// means a directory. Read it through `unixMode` and `kind`.
external_attributes: u32,
/// Last modification time in MS-DOS format: 2-second steps, no time zone (APPNOTE 4.4.6).
/// `modTime` prefers `mtime` and falls back to this and `dos_date`.
dos_time: u16,
/// Last modification date in MS-DOS format, years 1980 to 2107 (APPNOTE 4.4.6).
dos_date: u16,
/// Length of the extra field in the central header (APPNOTE 4.4.11). The comment comes
/// after the name and this field (4.3.12), so with `name_len` it locates the comment.
extra_len: u16,
/// Length of the entry comment (APPNOTE 4.4.12). Read it with `fileComment`.
comment_len: u16,
/// Whether the central name ends in '/'. Every zip tool writes directories that way
/// (APPNOTE never says so, but its 4.4.17.1 paths are '/'-separated). Kept because `kind`
/// needs it and the name itself isn't stored; `Archive.next` reads only this last byte.
name_ends_in_slash: bool,
/// Modification time in Unix seconds (UTC) from the Info-ZIP extended timestamp, extra
/// field 0x5455 (Info-ZIP extrafld.txt), or null when the central header has none. The
/// central copy holds the modification time only, whatever its flags say.
mtime: ?i64,
/// Owner user id from the Info-ZIP New Unix extra field 0x7875 (Info-ZIP extrafld.txt),
/// or null. Metadata only: extraction never applies it.
uid: ?u32,
/// Owner group id from the 0x7875 extra field, like `uid`. Metadata only.
gid: ?u32,

/// What `stream` can return: the data checks (`IntegrityError`), the file or caller's
/// writer failing, `ZipTruncated` when the data runs past the end of the file, and
/// `ZipUnsupportedMethod` for a direct call on an entry `Archive` would have refused.
/// The header checks happen before, in `Archive.streamEntry`, so their errors aren't here.
const StreamError = error{ ZipTruncated, ZipUnsupportedMethod } || errors.IntegrityError || std.Io.File.SeekError || error{ReadFailed} || std.Io.Writer.Error;

/// Streams the decompressed bytes, which start at `data_start`, into `writer` and returns
/// how many were written. `Archive.streamEntry` is the public way in: it checks the entry
/// and finds `data_start` first. This stays pub only because Archive.zig calls it.
pub fn stream(self: Entry, source: *Source, data_start: u64, writer: *std.Io.Writer) StreamError!u64 {
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
                // The inflater reports its own failures as ReadFailed and keeps the cause.
                error.ReadFailed => return if (decompress.err) |cause| switch (cause) {
                    error.EndOfStream => error.ZipTruncated,
                    else => error.ZipBadDeflate, // the stream itself is corrupt
                } else err, // no cause: the file read underneath failed
                else => return err,
            };

            if (actual_crc != self.crc32) return error.ZipCrcMismatch;

            // The deflate stream must use up all of compressed_size: anything left is junk.
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
fn inflateExactAndCrc(decompress: *Decompress, dest: *std.Io.Writer, expected_size: u64) !u32 {
    // A clean end before expected_size means the final block came early: the stream is
    // whole but shorter than declared. A cut-short file fails as ReadFailed instead.
    const crc = copyExactAndCrc(&decompress.reader, dest, expected_size) catch |err| switch (err) {
        error.ZipTruncated => return error.ZipSizeMismatch,
        else => return err,
    };

    // Needed even for an empty entry: its stream is still a final block (`03 00`),
    // and nothing above pulls it out when expected_size is 0.
    var rest: [1]u8 = undefined;
    if (try decompress.reader.readSliceShort(&rest) != 0) return error.ZipSizeMismatch;
    return crc;
}

/// Copies exactly `expected_size` bytes from `source` to `dest` and returns their CRC-32.
/// `ZipTruncated` if `source` ends first.
fn copyExactAndCrc(source: *std.Io.Reader, dest: *std.Io.Writer, expected_size: u64) !u32 {
    var crc = std.hash.Crc32.init();
    var total: u64 = 0;
    var chunk: [8 << 10]u8 = undefined;

    while (total < expected_size) {
        const remaining = expected_size - total;
        const chunk_len: usize = @intCast(@min(remaining, 8 << 10));
        const n = try source.readSliceShort(chunk[0..chunk_len]);

        if (n == 0) return error.ZipTruncated;

        crc.update(chunk[0..n]);
        try dest.writeAll(chunk[0..n]);
        total += @intCast(n);
    }

    return crc.final();
}

/// What `extract` does when the file it would create already exists.
pub const FileExistsBehavior = enum {
    /// Return `error.PathAlreadyExists`. The default, as in std.
    fail,
    /// Leave the existing file and skip the entry.
    skip,
    /// Replace the existing file.
    overwrite,
};

/// What `Archive.extractEntry` does with a symlink entry. Writing one as a regular file
/// holding its target would hide what it is, so that isn't an option. `Archive.extractAll`
/// can also create safe ones, see `Archive.SymlinkPolicy`.
pub const SymlinkPolicy = enum {
    /// Fail with `ZipUnsafeSymlink`.
    refuse,
    /// Leave the entry out and carry on.
    skip,
};

/// Options for `Archive.extractEntry`.
pub const ExtractOptions = struct {
    /// See `FileExistsBehavior`.
    file_exists_behavior: FileExistsBehavior = .fail,
    /// See `SymlinkPolicy`.
    symlinks: SymlinkPolicy = .refuse,
};

/// Writes the entry under `dst`, its data starting at `data_start`, by what `kind` says:
/// a directory, a regular file, or a symlink handled by `options.symlinks`. Other types
/// (fifo, device, socket) are written as regular files holding their data, so nothing
/// special is ever created. `Archive.extractEntry` is the public way in: it checks and
/// refuses the entry before anything is created on disk. This stays pub only because
/// Archive.zig calls it.
pub fn extract(self: Entry, io: std.Io, source: *Source, data_start: u64, dst: std.Io.Dir, options: ExtractOptions) !void {
    var filename_buf: [max_path_bytes]u8 = undefined;
    const filename = try self.cleanName(source, &filename_buf);

    switch (self.kind()) {
        .directory => try self.makeDirectory(io, dst, filename),
        .symlink => switch (options.symlinks) {
            .refuse => return error.ZipUnsafeSymlink,
            .skip => {},
        },
        .file, .other => try self.writeFile(io, source, data_start, dst, filename, options.file_exists_behavior, .{}),
    }
}

/// Creates the directory `name` (already cleaned, a trailing '/' allowed) and any missing
/// parents under `dst`. One that already exists is fine, as with `unzip`. A directory
/// entry carrying data is `ZipBadDirectorySize`. Pub only for Archive.zig.
pub fn makeDirectory(self: Entry, io: std.Io, dst: std.Io.Dir, name: []const u8) !void {
    if (self.uncompressed_size != 0) return error.ZipBadDirectorySize;
    const dir_path = if (name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
    try dst.createDirPath(io, dir_path);
}

/// Permission bits and a modification time for `writeFile` to set once the data is written.
/// Null leaves what the OS gives a new file.
pub const FileAttributes = struct {
    /// Permission bits only, at most 0o777.
    mode: ?u32 = null,
    /// Unix seconds, set as both the access and the modification time, as `unzip` does.
    mtime: ?i64 = null,
};

/// Writes the entry's data to the file `name` (already cleaned) under `dst`, creating
/// missing parent directories, then sets `attrs`. Pub only for Archive.zig.
pub fn writeFile(
    self: Entry,
    io: std.Io,
    source: *Source,
    data_start: u64,
    dst: std.Io.Dir,
    name: []const u8,
    on_exists: FileExistsBehavior,
    attrs: FileAttributes,
) !void {
    var parent_dir = dst;
    const parent = std.fs.path.dirname(name);
    if (parent) |dirname| parent_dir = try dst.createDirPathOpen(io, dirname, .{});
    defer if (parent != null) parent_dir.close(io);
    const basename = std.fs.path.basename(name);

    const out_file = parent_dir.createFile(io, basename, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => switch (on_exists) {
            .fail => return err,
            .overwrite => try parent_dir.createFile(io, basename, .{}),
            .skip => return,
        },
        else => |e| return e,
    };
    defer out_file.close(io);

    var writer_buf: [4096]u8 = undefined;
    var writer = out_file.writer(io, &writer_buf);
    // stream returns exactly uncompressed_size or an error.
    _ = try self.stream(source, data_start, &writer.interface);
    try writer.interface.flush();

    // After the data, so the last write doesn't move the time, and a read-only mode can't
    // get in the way.
    if (attrs.mode) |mode| try setMode(io, out_file, mode);
    if (attrs.mtime) |mtime| {
        const at: std.Io.File.SetTimestamp = .{ .new = unixTimestamp(mtime) };
        try out_file.setTimestamps(io, .{ .access_timestamp = at, .modify_timestamp = at });
    }
}

/// Sets permission bits on `file`. A no-op where `std.Io.File.Permissions` has no Unix
/// mode (Windows).
fn setMode(io: std.Io, file: std.Io.File, mode: u32) !void {
    const Permissions = std.Io.File.Permissions;
    if (comptime !@hasDecl(Permissions, "fromMode")) return;
    try file.setPermissions(io, .fromMode(@intCast(mode)));
}

/// Unix seconds as a `std.Io.Timestamp`. Pub only for Archive.zig.
pub fn unixTimestamp(seconds: i64) std.Io.Timestamp {
    return .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s);
}

/// The compression method (APPNOTE 4.4.5), same as `method`.
pub fn compression(self: Entry) CompressionMethod {
    return self.method;
}

/// The CRC-32 of the uncompressed data (APPNOTE 4.4.7), same as `crc32`. Reading the entry
/// already checks it.
pub fn crc32Checksum(self: Entry) u32 {
    return self.crc32;
}

/// Reads the entry's name and cleans it with `path.sanitize` into `buffer`: the name
/// `extract` writes under and `Archive.checkLayout` compares.
///
/// - Bit 11 set: the central name (4.4.17), checked to be UTF-8 (APPNOTE 4.4.4).
/// - Bit 11 clear, with a usable 0x7075 Unicode Path (see `unicodeName`): that name,
///   checked to be UTF-8, since the field exists to say so (4.6.9). It is held to the same
///   rules as any name, so an unsafe one fails rather than falling back to the raw name.
/// - Otherwise: the central name as raw bytes, officially CP437 (Appendix D), unconverted.
///
/// A name longer than `max_path_bytes` is `ZipNameTooLong`. A malformed 0x7075 field is
/// `ZipBadExtraField`, like any broken extra.
pub fn cleanName(self: Entry, source: *Source, buffer: *[max_path_bytes]u8) ![]const u8 {
    // Cleaning only drops bytes, so a raw name that fits always leaves room for the clean one.
    var raw_buf: [max_path_bytes]u8 = undefined;
    // No extra field means no 0x7075, so skip the second pass over the name for its CRC.
    if (!self.nameIsUtf8() and self.extra_len > 0) {
        const unicode = self.unicodeName(source, &raw_buf) catch |err| switch (err) {
            error.InsufficientBufferSize => return error.ZipNameTooLong,
            else => |e| return e,
        };
        if (unicode) |name| return path.sanitize(name, buffer, .{ .utf8 = true });
    }

    if (self.name_len > max_path_bytes) return error.ZipNameTooLong;
    const reader = try source.readerAt(self.central_header_offset + records.CentralHeader.size);
    const raw = raw_buf[0..self.name_len];
    reader.readSliceAll(raw) catch |err| return truncated(err);
    return path.sanitize(raw, buffer, .{ .utf8 = self.nameIsUtf8() });
}

/// Reads the entry's name (path) into `buffer` and returns it. The name comes from the
/// central directory header (APPNOTE 4.4.17), the one `Archive.next` listed; the local name
/// may be masked (4.4.17.2) and is only compared when the entry is read.
pub fn fileName(self: Entry, source: *Source, buffer: []u8) ![]u8 {
    if (buffer.len < self.name_len) return error.InsufficientBufferSize;
    const reader = try source.readerAt(self.central_header_offset + records.CentralHeader.size);
    const fname = buffer[0..self.name_len];
    reader.readSliceAll(fname) catch |err| return truncated(err);
    return fname;
}

/// Reads the entry's comment into `buffer` and returns it (APPNOTE 4.4.18). It sits after
/// the name and the extra field in the central header (4.3.12); empty when `comment_len`
/// is 0. Under bit 11 it is UTF-8, like the name (APPNOTE Appendix D).
pub fn fileComment(self: Entry, source: *Source, buffer: []u8) ![]u8 {
    if (buffer.len < self.comment_len) return error.InsufficientBufferSize;
    const comment_offset = self.central_header_offset + records.CentralHeader.size + self.name_len + self.extra_len;
    const reader = try source.readerAt(comment_offset);
    const comment = buffer[0..self.comment_len];
    reader.readSliceAll(comment) catch |err| return truncated(err);
    return comment;
}

/// Reads the entry's Info-ZIP Unicode Path, extra field 0x7075 (APPNOTE 4.6.9, Info-ZIP
/// extrafld.txt), into `buffer` and returns it, or null when there's none to use. Writers
/// that don't set bit 11 can store a UTF-8 copy of the name there, with the CRC-32 of the
/// header name it was made from. A tool that later renames the entry without updating the
/// field leaves that CRC stale, so per 4.6.9 a CRC that doesn't match the central name
/// gives null, and so does a version other than 1 (changes "MAY NOT be backward
/// compatible"). The bytes come back as stored; `cleanName` checks that they are UTF-8.
pub fn unicodeName(self: Entry, source: *Source, buffer: []u8) !?[]u8 {
    const reader = try source.readerAt(self.central_header_offset + records.CentralHeader.size);

    // The CRC covers the central name. The extra field follows it, so one reader does both.
    var crc = std.hash.Crc32.init();
    var chunk: [256]u8 = undefined;
    var left: usize = self.name_len;
    while (left > 0) {
        const n = @min(chunk.len, left);
        reader.readSliceAll(chunk[0..n]) catch |err| return truncated(err);
        crc.update(chunk[0..n]);
        left -= n;
    }
    var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
    const central_extra = extra_buf[0..self.extra_len];
    reader.readSliceAll(central_extra) catch |err| return truncated(err);

    const extra_iterator: extra.Iterator = .{ .buf = central_extra };
    const field = (try extra_iterator.find(.info_zip_unicode_path)) orelse return null;
    // A 0x7075 field always has a parser, so parse never returns null for it.
    const unicode = (try field.parse(.none)).?.info_zip_unicode_path;
    if (unicode.version != 1 or unicode.name_crc32 != crc.final()) return null;

    if (buffer.len < unicode.name.len) return error.InsufficientBufferSize;
    const name = buffer[0..unicode.name.len];
    @memcpy(name, unicode.name);
    return name;
}

/// Whether bit 11, the language encoding flag, says the name and comment are UTF-8
/// (APPNOTE 4.4.4, Appendix D). Without it they are officially IBM code page 437. Only the
/// flag is reported here; `cleanName` checks that the bytes are valid UTF-8.
pub fn nameIsUtf8(self: Entry) bool {
    return self.flags.language_encoding;
}

/// The Unix `st_mode`, file type and permission bits, from the high 16 bits of
/// `external_attributes`. Null unless `version_made_by` is Unix (3) or OS X (19), the hosts
/// that store a mode there (APPNOTE 4.4.2.2, 4.4.15).
pub fn unixMode(self: Entry) ?u32 {
    return switch (self.version_made_by.os) {
        .unix, .osx_darwin => self.external_attributes >> 16,
        else => null,
    };
}

/// What an entry is, as `kind` reports it.
pub const Kind = enum { file, directory, symlink, other };

/// What the entry is (APPNOTE 4.4.15):
/// 1. A name ending in '/' is a directory, whatever the attributes say. That is also what
///    `Archive.extractEntry` creates for it, so the two always agree.
/// 2. With a Unix mode (`unixMode`), its type bits `mode & 0o170000` decide: 0o040000
///    directory, 0o100000 file, 0o120000 symlink, any other type (fifo, device, socket)
///    `other`. A mode with no type bits at all, which some Unix writers leave as 0, falls
///    through to the next rule.
/// 3. Otherwise bit 0x10 of the MS-DOS attribute byte means a directory, else a file.
pub fn kind(self: Entry) Kind {
    if (self.name_ends_in_slash) return .directory;
    if (self.unixMode()) |mode| switch (mode & 0o170000) {
        0o040000 => return .directory,
        0o100000 => return .file,
        0o120000 => return .symlink,
        0 => {},
        else => return .other,
    };
    return if (self.external_attributes & 0x10 != 0) .directory else .file;
}

/// Modification time in Unix seconds: `mtime` (0x5455, UTC, 1-second steps) when present,
/// else the MS-DOS `dos_date` and `dos_time` read as UTC (APPNOTE 4.4.6). DOS time has no
/// time zone, so in that case the result is the writer's local clock, not real UTC.
pub fn modTime(self: Entry) i64 {
    return self.mtime orelse time.decodeDosDateTime(.{ .time = self.dos_time, .date = self.dos_date });
}
