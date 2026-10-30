const std = @import("std");

const time = @import("time.zig");
const CompressionMethod = @import("format.zig").CompressionMethod;
const GeneralPurposeFlags = @import("format.zig").GeneralPurposeFlags;
const Version = @import("format.zig").Version;
const unix_mode = @import("format.zig").unix_mode;

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
/// Length of the entry comment (APPNOTE 4.4.12). Read it with `Archive.entryComment`.
comment_len: u16,
/// Whether the central name ends in '/', or in '\' when the archive was opened with
/// `allow_backslashes`. Every zip tool writes directories that way (APPNOTE never says so,
/// but its 4.4.17.1 paths are '/'-separated). Kept because `kind` needs it and the name
/// itself isn't stored; `Archive.next` reads only this last byte.
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
    /// Sets the permission bits (`mode & 0o777`, never setuid, setgid or sticky) of a file
    /// or folder made on Unix (`unixMode`), as `Archive.ExtractAllOptions` does. A folder
    /// gets them right away, so extract what goes inside it first, or use `extractAll`.
    apply_unix_mode: bool = true,
    /// Sets the modification time of a file or folder to `modTime`. Writing into a folder
    /// later moves its time again.
    apply_mtime: bool = true,
};

/// Whether bit 11, the language encoding flag, says the name and comment are UTF-8
/// (APPNOTE 4.4.4, Appendix D). Without it they are officially IBM code page 437. Only the
/// flag is reported here; `Archive.cleanEntryName` checks that the bytes are valid UTF-8.
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
/// 1. A name ending in '/' (or '\\' under `allow_backslashes`, see `name_ends_in_slash`)
///    is a directory, whatever the attributes say. That is also what
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
