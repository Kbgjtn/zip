const std = @import("std");
const errors = @import("errors.zig");
const truncated = errors.truncated;

const extra = @import("extra.zig");
const time = @import("time.zig");
const path = @import("path.zig");
const CompressionMethod = @import("format.zig").CompressionMethod;
const GeneralPurposeFlags = @import("format.zig").GeneralPurposeFlags;
const Version = @import("format.zig").Version;
const unix_mode = @import("format.zig").unix_mode;
const records = @import("records/root.zig");
const Source = @import("source.zig").Source;

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

/// What `Archive.extractEntry` and `Archive.extractAll` do when a file they would create
/// already exists.
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
    const unicode = try extra.InfoZipUnicodePath.parse(field.data);
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
/// 2. With a Unix mode (`unixMode`), its type bits `mode & unix_mode.type_mask` decide:
///    `directory` (0o040000), `regular` (0o100000) a file, `symlink` (0o120000), any other
///    type (fifo, device, socket) `other`. A mode with no type bits at all, which some
///    Unix writers leave as 0, falls through to the next rule.
/// 3. Otherwise bit 0x10 of the MS-DOS attribute byte means a directory, else a file.
pub fn kind(self: Entry) Kind {
    if (self.name_ends_in_slash) return .directory;
    if (self.unixMode()) |mode| switch (mode & unix_mode.type_mask) {
        unix_mode.directory => return .directory,
        unix_mode.regular => return .file,
        unix_mode.symlink => return .symlink,
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
