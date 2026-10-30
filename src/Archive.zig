//! The central directory is the source of truth for every entry. Each entry's local header
//! (4.3.7) and data descriptor (4.3.9) are read only to cross-check it: a disagreement is an
//! error, never a different value (bug 21).
//!
//! Listing and reading are separate steps. `next` lists every entry from the central
//! directory alone, including ones we can't decompress (encrypted, patched, masked or an
//! unsupported method), so a mixed archive still lists. `streamEntry`, `readEntryAlloc` and
//! `extractEntry` open the entry first: they refuse what we can't read and cross-check the
//! local header, then read the data.

const std = @import("std");
const errors = @import("errors.zig");
const truncated = errors.truncated;

const extra = @import("extra.zig");
const path = @import("path.zig");
const Entry = @import("Entry.zig");
const Source = @import("source.zig").Source;
const HeaderId = @import("format.zig").HeaderId;
const escaped32 = @import("format.zig").escaped32;
const GeneralPurposeFlags = @import("format.zig").GeneralPurposeFlags;

const records = @import("records/root.zig");
// Vendored: std 0.16.0's inflater panics on truncated or corrupt input.
const Decompress = @import("vendor/flate/decompress.zig");

/// Iterates the central directory one entry at a time, without allocating.
///
/// `open` finds the end of central directory record (and the ZIP64 end record when the EOCD
/// fields are escaped), then `next` returns each entry as an `Entry` from its central header.
/// `next` and the read functions share `source` and each asks it for a reader at the offset
/// it needs, so reads and listing can be interleaved.
const Archive = @This();

/// The archive bytes, from a file or from memory.
source: Source,
/// Index of the entry `next` reads next.
cd_index: u64 = 0,
/// Offset of the central directory header `next` reads next.
cd_offset: u64 = 0,
/// Size of the central directory in bytes, from the EOCD or ZIP64 end record.
cd_size: u64 = 0,
/// Offset of the first central directory header. Entry data must end before it.
cd_start: u64 = 0,
/// Entry count from the EOCD or ZIP64 end record.
total_entries: u64 = 0,
/// One past the last byte of the central directory.
cd_end: u64 = 0,
/// Offset of the archive comment, right after the 22-byte end of central directory record
/// (APPNOTE 4.3.16). Read it with `comment`.
comment_offset: u64 = 0,
/// Length of the archive comment (APPNOTE 4.4.25).
comment_len: u16 = 0,
/// The limits `open` was given. See `Limits`.
limits: Limits,
/// Decompressed bytes the read functions have been allowed to produce so far, the running
/// budget checked against `limits.max_total_size`. See `openEntry`.
total_out: u64 = 0,

/// Safety limits against archives built to exhaust memory, disk or time (zip bombs). The
/// header sizes can lie, but reading never writes more than the central uncompressed size
/// (`ZipSizeMismatch` stops it), so every check here uses the central sizes and runs
/// before any data is read.
pub const Limits = struct {
    /// Most entries the end record may count (APPNOTE 4.4.22), else `ZipTooManyEntries`
    /// from `open`. Stops a forged count from making `next` loop for hours.
    max_entries: u64 = 1_000_000,
    /// Largest central uncompressed size (APPNOTE 4.4.9) an entry may have to be read, else
    /// `ZipEntryTooLarge`.
    max_entry_size: u64 = 1 << 30,
    /// Most decompressed bytes all reads through one `Archive` may produce together, else
    /// `ZipTotalTooLarge`. Catches many entries that are each under `max_entry_size`.
    max_total_size: u64 = 4 << 30,
    /// Largest uncompressed / compressed size ratio (APPNOTE 4.4.9 over 4.4.8), else
    /// `ZipRatioExceeded`. Rounded down, and a compressed size of 0 counts as 1. Deflate
    /// can't do better than about 1032:1 (a 258-byte match costs about 2 bits), so above
    /// that the central sizes can only be lying: the default catches the lie before any
    /// data is read and never refuses a real deflated file. The size caps above are what
    /// stop bombs.
    max_ratio: u64 = 1100,
    /// Entries whose uncompressed size is at most this many bytes skip the ratio check:
    /// small, highly repetitive files (a run of zeros, an empty-ish text) are harmless.
    ratio_grace: u64 = 1 << 20,

    pub const default: Limits = .{};
    /// No limit at all, for archives the caller trusts.
    pub const unlimited: Limits = .{
        .max_entries = std.math.maxInt(u64),
        .max_entry_size = std.math.maxInt(u64),
        .max_total_size = std.math.maxInt(u64),
        .max_ratio = std.math.maxInt(u64),
        .ratio_grace = std.math.maxInt(u64),
    };
};

/// How `open` treats archives that bend the format. The defaults follow APPNOTE strictly.
pub const OpenOptions = struct {
    /// The end of central directory record and its comment are the last bytes of an archive
    /// (APPNOTE 4.3.6, 4.3.16). True: the comment must end exactly at the end of the file,
    /// else `ZipNoEndRecord`. False: bytes after the comment are ignored, as when a file was
    /// padded or had something appended. The scan for the record starts at the end of the
    /// file and takes the first `PK\x05\x06` whose comment fits before the end, so trailing
    /// bytes that happen to hold such a record hide the real one. The record must still
    /// start in the last 22 + 65,535 bytes of the file.
    strict_trailing_bytes: bool = true,
    /// See `Limits`.
    limits: Limits = .default,
};

/// Opens an archive in a file. The caller keeps `reader` alive while the archive is used.
pub fn openFile(reader: *std.Io.File.Reader, options: OpenOptions) errors.OpenError!Archive {
    return open(.fromFile(reader), options);
}

/// Opens an archive already in memory. The caller keeps `bytes` alive while the archive is
/// used. Reading from memory never fails I/O.
pub fn openMemory(bytes: []const u8, options: OpenOptions) errors.OpenError!Archive {
    return open(.fromMemory(bytes), options);
}

/// Reads the end records and checks that the central directory lies inside the archive.
fn open(source: Source, options: OpenOptions) errors.OpenError!Archive {
    var archive: Archive = .{ .source = source, .limits = options.limits };
    const file_size = try archive.source.size();

    const eocd = try records.EndRecord.read(&archive.source, options.strict_trailing_bytes);
    try eocd.record.validateStructure(file_size, eocd.offset, options.strict_trailing_bytes);
    archive.comment_offset = eocd.offset + records.EndRecord.size;
    archive.comment_len = eocd.record.comment_len;

    if (eocd.record.requiresZip64()) {
        // An escaped EOCD field means the real values are in the ZIP64 end record,
        // found through the locator just before the EOCD (APPNOTE 4.3.14, 4.3.15).
        const locator = try records.EndRecord64Locator.read(&archive.source, eocd.offset, file_size);
        const record64 = try records.EndRecord64.read(&archive.source, locator.record_offset, file_size);
        try eocd.record.validateZip64Agrees(record64);
        archive.cd_offset = record64.central_directory_offset;
        archive.cd_size = record64.central_directory_size;
        archive.total_entries = record64.record_count_total;
    } else {
        try eocd.record.validateSizeFields(file_size);
        archive.cd_offset = eocd.record.central_directory_offset;
        archive.cd_size = eocd.record.central_directory_size;
        archive.total_entries = eocd.record.record_count_total;
    }

    try archive.validateSizeFields(file_size);
    archive.cd_start = archive.cd_offset;
    archive.cd_end = archive.cd_offset + archive.cd_size;
    return archive;
}

/// Reads the archive comment (APPNOTE 4.4.26), the bytes after the end of central directory
/// record, into `buffer` and returns it. Empty when `comment_len` is 0. At most 65,535 bytes,
/// so a `[std.math.maxInt(u16)]u8` buffer always fits; a shorter one than the comment is
/// `InsufficientBufferSize`, as in `entryComment`. The bytes come back as stored: no
/// flag says how the archive comment is encoded (bit 11 is per entry, 4.4.4).
pub fn comment(self: *Archive, buffer: []u8) errors.CommentError![]u8 {
    if (buffer.len < self.comment_len) return error.InsufficientBufferSize;
    const reader = try self.source.readerAt(self.comment_offset);
    const bytes = buffer[0..self.comment_len];
    reader.readSliceAll(bytes) catch |err| return truncated(err);
    return bytes;
}

/// Reads the name of `entry` and cleans it with `path.sanitize` into `buffer`: the name
/// `extractEntry` writes under and `checkLayout` compares.
///
/// - Bit 11 set: the central name (4.4.17), checked to be UTF-8 (APPNOTE 4.4.4).
/// - Bit 11 clear, with a usable 0x7075 Unicode Path (see `unicodeEntryName`): that name,
///   checked to be UTF-8, since the field exists to say so (4.6.9). It is held to the same
///   rules as any name, so an unsafe one fails rather than falling back to the raw name.
/// - Otherwise: the central name as raw bytes, officially CP437 (Appendix D), unconverted.
///
/// A name longer than `max_path_bytes` is `ZipNameTooLong`. A malformed 0x7075 field is
/// `ZipBadExtraField`, like any broken extra.
pub fn cleanEntryName(self: *Archive, entry: *const Entry, buffer: *[max_path_bytes]u8) errors.CleanNameError![]const u8 {
    // Cleaning only drops bytes, so a raw name that fits always leaves room for the clean one.
    var raw_buf: [max_path_bytes]u8 = undefined;
    // No extra field means no 0x7075, so skip the second pass over the name for its CRC.
    if (!entry.nameIsUtf8() and entry.extra_len > 0) {
        const unicode = self.unicodeEntryName(entry, &raw_buf) catch |err| switch (err) {
            error.InsufficientBufferSize => return error.ZipNameTooLong,
            else => |e| return e,
        };
        if (unicode) |name| return path.sanitize(name, buffer, .{ .utf8 = true });
    }

    if (entry.name_len > max_path_bytes) return error.ZipNameTooLong;
    const reader = try self.source.readerAt(entry.central_header_offset + records.CentralHeader.size);
    const raw = raw_buf[0..entry.name_len];
    reader.readSliceAll(raw) catch |err| return truncated(err);
    return path.sanitize(raw, buffer, .{ .utf8 = entry.nameIsUtf8() });
}

/// Reads the name (path) of `entry` into `buffer` and returns it. The name comes from the
/// central directory header (APPNOTE 4.4.17), the one `next` listed; the local name
/// may be masked (4.4.17.2) and is only compared when the entry is read.
pub fn entryName(self: *Archive, entry: *const Entry, buffer: []u8) errors.EntryNameError![]u8 {
    if (buffer.len < entry.name_len) return error.InsufficientBufferSize;
    const reader = try self.source.readerAt(entry.central_header_offset + records.CentralHeader.size);
    const fname = buffer[0..entry.name_len];
    reader.readSliceAll(fname) catch |err| return truncated(err);
    return fname;
}

/// Reads the comment of `entry` into `buffer` and returns it (APPNOTE 4.4.18). It sits after
/// the name and the extra field in the central header (4.3.12); empty when `comment_len`
/// is 0. Under bit 11 it is UTF-8, like the name (APPNOTE Appendix D).
pub fn entryComment(self: *Archive, entry: *const Entry, buffer: []u8) errors.EntryCommentError![]u8 {
    if (buffer.len < entry.comment_len) return error.InsufficientBufferSize;
    const comment_offset = entry.central_header_offset + records.CentralHeader.size + entry.name_len + entry.extra_len;
    const reader = try self.source.readerAt(comment_offset);
    const bytes = buffer[0..entry.comment_len];
    reader.readSliceAll(bytes) catch |err| return truncated(err);
    return bytes;
}

/// Reads the Info-ZIP Unicode Path of `entry`, extra field 0x7075 (APPNOTE 4.6.9, Info-ZIP
/// extrafld.txt), into `buffer` and returns it, or null when there's none to use. Writers
/// that don't set bit 11 can store a UTF-8 copy of the name there, with the CRC-32 of the
/// header name it was made from. A tool that later renames the entry without updating the
/// field leaves that CRC stale, so per 4.6.9 a CRC that doesn't match the central name
/// gives null, and so does a version other than 1 (changes "MAY NOT be backward
/// compatible"). The bytes come back as stored; `cleanEntryName` checks that they are UTF-8.
pub fn unicodeEntryName(self: *Archive, entry: *const Entry, buffer: []u8) errors.UnicodeNameError!?[]u8 {
    const reader = try self.source.readerAt(entry.central_header_offset + records.CentralHeader.size);

    // The CRC covers the central name. The extra field follows it, so one reader does both.
    var crc = std.hash.Crc32.init();
    var chunk: [256]u8 = undefined;
    var left: usize = entry.name_len;
    while (left > 0) {
        const n = @min(chunk.len, left);
        reader.readSliceAll(chunk[0..n]) catch |err| return truncated(err);
        crc.update(chunk[0..n]);
        left -= n;
    }
    var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
    const central_extra = extra_buf[0..entry.extra_len];
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

/// Returns the next entry, or null after the last one.
///
/// One sequential pass over the central directory (APPNOTE 4.3.12): no local header or data
/// descriptor is read here, and nothing is refused based on flags or method. Entries we
/// can't read still list; `streamEntry` checks and refuses them. Sizes and the local header
/// offset come from the ZIP64 extra field when escaped (4.5.3), the modification time and
/// owner ids from the 0x5455 and 0x7875 fields when present (see `centralMetadata`).
pub fn next(self: *Archive) errors.IterError!?Entry {
    if (self.cd_index == self.total_entries) {
        // Headers left over that the end record never counted (APPNOTE 4.3.16).
        if (self.cd_offset != self.cd_end) return error.ZipCentralDirectoryMismatch;
        return null;
    }
    // The end record promised more entries than the central directory holds (APPNOTE 4.3.16).
    if (self.cd_offset >= self.cd_end) return error.ZipCentralDirectoryMismatch;

    const header_offset = self.cd_offset;
    const cdfh = try records.CentralHeader.read(&self.source, header_offset);

    // cd_offset < cd_end <= file size and entry_size < 200 KiB, so this can't overflow.
    const entry_size = cdfh.computeEntrySize();
    if (header_offset + entry_size > self.cd_end) return error.ZipMalformed;

    defer {
        self.cd_index += 1;
        self.cd_offset += entry_size;
    }

    // The name stays unread until `entryName` asks for it, except its last byte, which
    // `Entry.kind` needs. The extra field follows it, so one read gets both.
    // readSliceAll refills; toss would assert when the field crosses the end of the
    // buffered bytes (bug 23).
    const last_name_len: usize = @min(cdfh.name_len, 1);
    const reader = try self.source.readerAt(header_offset + records.CentralHeader.size + cdfh.name_len - last_name_len);
    var tail_buf: [1 + std.math.maxInt(u16)]u8 = undefined;
    const tail = tail_buf[0 .. last_name_len + cdfh.extra_len];
    reader.readSliceAll(tail) catch |err| return truncated(err);
    const name_ends_in_slash = last_name_len == 1 and tail[0] == '/';
    const central_extra = tail[last_name_len..];

    const sizes = try centralSizes(cdfh, central_extra);
    if (sizes.disk_number_start != 0) return error.ZipMultiDisk;
    const metadata = try centralMetadata(central_extra);

    return .{
        .local_header_offset = sizes.local_header_offset,
        .central_header_offset = header_offset,
        .name_len = cdfh.name_len,
        .method = cdfh.compression_method,
        .flags = cdfh.flags,
        .crc32 = cdfh.crc32,
        .compressed_size = sizes.compressed_size,
        .uncompressed_size = sizes.uncompressed_size,
        .version_made_by = cdfh.version_made_by,
        .external_attributes = cdfh.external_attributes,
        .dos_time = cdfh.dos_time,
        .dos_date = cdfh.dos_date,
        .extra_len = cdfh.extra_len,
        .comment_len = cdfh.comment_len,
        .name_ends_in_slash = name_ends_in_slash,
        .mtime = metadata.mtime,
        .uid = metadata.uid,
        .gid = metadata.gid,
    };
}

/// Streams the decompressed bytes of `entry`, an entry `next` returned, into `w`, and
/// returns how many were written. Checks and refuses the entry first (see `openEntry`).
/// The output stops at the central uncompressed size (`ZipSizeMismatch` if the data is
/// longer or shorter) and its CRC-32 must equal the central one (`ZipCrcMismatch`).
pub fn streamEntry(self: *Archive, entry: *const Entry, w: *std.Io.Writer) errors.EntryError!u64 {
    const data_start = try self.openEntry(entry);
    return self.streamData(entry, data_start, w);
}

/// Reads the decompressed bytes of `entry` into memory the caller owns. Fails with
/// `ZipEntryTooLarge` before allocating if the central uncompressed size is over
/// `max_size`. Checks and refusals are those of `streamEntry`.
pub fn readEntryAlloc(self: *Archive, gpa: std.mem.Allocator, entry: *const Entry, max_size: u64) errors.ReadAllocError![]u8 {
    if (entry.uncompressed_size > max_size) return error.ZipEntryTooLarge;
    const len = std.math.cast(usize, entry.uncompressed_size) orelse return error.ZipEntryTooLarge;
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    // streamEntry never writes past the declared size, so a fixed buffer is enough.
    var w: std.Io.Writer = .fixed(bytes);
    _ = try self.streamEntry(entry, &w);
    return bytes;
}

/// Checks the whole archive for tricks a reader that opens one entry at a time can't see
/// (design 11.4). Run it before extracting everything. Reads each central and local header
/// once and allocates the names and byte ranges with `gpa`, all freed before it returns.
/// It walks its own copy of the listing position, so `next` carries on where it was.
///
/// 1. Each entry takes up its local header, name, extra field, data and, under bit 3, its
///    data descriptor (APPNOTE 4.3.6, 4.3.7, 4.3.9). Two entries that share a byte are
///    `ZipOverlappingEntries`: an overlap bomb points many central headers at one
///    compressed stream, so a small file expands many times over. Entries that touch end
///    to end are fine. One that runs into the central directory is `ZipMalformed`.
/// 2. Every name is cleaned with `cleanEntryName`, as extraction does, and an unsafe one
///    fails with its `PathError`. Two entries whose cleaned names match, byte for byte, are
///    `ZipDuplicateName`: tools disagree on which one wins, so a scanner and an extractor
///    can see different files. "a//b", "./a/b" and "a/b" all match, and so do "d" and
///    "d/", a file and a directory at one path. Case and Unicode normalization are not
///    compared, so "A" and "a" differ.
///    A file or symlink at a path another entry uses as a folder, like "a" next to "a/b",
///    is `ZipPathConflict`, in either order: one of them can't be created, and tools
///    disagree on which wins (some replace the file, a symlink would redirect "a/b").
///    "a/" next to "a/b" is fine, as is "a/b" alone, whose folder is made implicitly.
/// 3. The central uncompressed sizes (4.4.9) of all entries must add up to at most
///    `limits.max_total_size`, else `ZipTotalTooLarge`.
pub fn checkLayout(self: *const Archive, gpa: std.mem.Allocator) errors.LayoutError!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var walker = self.*;
    walker.cd_index = 0;
    walker.cd_offset = self.cd_start;

    var spans: std.ArrayList(Span) = .empty;
    var names: std.StringHashMapUnmanaged(void) = .empty;
    // Cleaned names of files and symlinks, and every folder some name runs through.
    var leaves: std.StringHashMapUnmanaged(void) = .empty;
    var folders: std.StringHashMapUnmanaged(void) = .empty;
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var total: u64 = 0;
    while (try walker.next()) |entry| {
        total = std.math.add(u64, total, entry.uncompressed_size) catch return error.ZipTotalTooLarge;
        if (total > self.limits.max_total_size) return error.ZipTotalTooLarge;

        const clean = try walker.cleanEntryName(&entry, &name_buf);
        const key = trimSlash(clean);
        const slot = try names.getOrPut(arena, key);
        if (slot.found_existing) return error.ZipDuplicateName;
        // `key` points into name_buf, which the next entry overwrites.
        const owned = try arena.dupe(u8, key);
        slot.key_ptr.* = owned;

        if (entry.kind() != .directory) {
            if (folders.contains(owned)) return error.ZipPathConflict;
            try leaves.put(arena, owned, {});
        }
        // Each parent, longest first. One already seen means its own parents were added
        // and checked then, and any leaf added since was checked against them.
        var end = owned.len;
        while (std.mem.findScalarLast(u8, owned[0..end], '/')) |slash| : (end = slash) {
            const parent = owned[0..slash];
            if (leaves.contains(parent)) return error.ZipPathConflict;
            const seen = try folders.getOrPut(arena, parent);
            if (seen.found_existing) break;
        }

        try spans.append(arena, try walker.entrySpan(&entry));
    }

    // Sorted by start, an entry overlaps another exactly when it starts before the
    // previous one ends.
    std.mem.sort(Span, spans.items, {}, Span.startsBefore);
    var previous_end: u64 = 0;
    for (spans.items) |span| {
        if (span.start < previous_end) return error.ZipOverlappingEntries;
        previous_end = span.end;
    }
}

/// The bytes `[start, end)` an entry takes up in the archive.
const Span = struct {
    start: u64,
    end: u64,

    fn startsBefore(_: void, a: Span, b: Span) bool {
        return a.start < b.start;
    }
};

/// Where `entry` lies in the archive, from its local header to the end of its data, or of
/// its data descriptor under bit 3 (APPNOTE 4.3.6). The descriptor is 12 bytes, 20 with
/// 8-byte sizes (4.3.9.2), plus 4 when it starts with its signature (4.3.9.3).
fn entrySpan(self: *Archive, entry: *const Entry) !Span {
    const lfh = try records.LocalHeader.read(&self.source, entry.local_header_offset);
    var end = (try self.dataRange(entry, lfh)).end;
    if (entry.flags.data_descriptor) {
        // end <= cd_start here, so adding at most 24 bytes can't overflow.
        end += (try self.readDescriptor(entry, lfh, end)).len;
        if (end > self.cd_start) return error.ZipMalformed;
    }
    return .{ .start = entry.local_header_offset, .end = end };
}

/// The bytes `[start, end)` that hold the data of `entry`, after its local header `lfh`,
/// name and extra field (APPNOTE 4.3.6). Returns `error.ZipMalformed` if the data runs
/// into the central directory, which entries come before, or past the end of the file.
fn dataRange(self: *const Archive, entry: *const Entry, lfh: records.LocalHeader) error{ZipMalformed}!Span {
    // The local header was read, so its offset is inside the archive and this can't overflow.
    const start = entry.local_header_offset + records.LocalHeader.size + lfh.name_len + lfh.extra_len;
    // A ZIP64 compressed size can be close to 2^64, so the add itself can overflow.
    const end = std.math.add(u64, start, entry.compressed_size) catch return error.ZipMalformed;
    if (end > self.cd_start) return error.ZipMalformed;
    return .{ .start = start, .end = end };
}

/// A data descriptor and the bytes it takes: 12, or 20 with 8-byte sizes (APPNOTE
/// 4.3.9.2), plus 4 when it starts with its signature (4.3.9.3).
const Descriptor = struct {
    record: records.DataDescriptor,
    len: u64,
};

/// Reads the data descriptor of `entry` at `offset`, right after its data (APPNOTE 4.3.9).
fn readDescriptor(self: *Archive, entry: *const Entry, lfh: records.LocalHeader, offset: u64) !Descriptor {
    const zip64 = try self.descriptorIsZip64(entry, lfh);
    const record = try records.DataDescriptor.read(&self.source, offset, zip64);
    const signed = record.signature == records.DataDescriptor.signature_marker;
    return .{ .record = record, .len = @as(u64, if (signed) 4 else 0) + 4 + @as(u64, if (zip64) 16 else 8) };
}

/// Writes `entry` under `dest`: a directory for a name ending in '/', else a file. Checks and
/// refuses the entry (see `openEntry`) before anything is created on disk.
pub fn extractEntry(self: *Archive, io: std.Io, entry: *const Entry, dest: std.Io.Dir, options: Entry.ExtractOptions) errors.ExtractEntryError!void {
    const data_start = try self.openEntry(entry);
    return self.extractData(io, entry, data_start, dest, options);
}

/// What `streamData` can return: the data checks (`IntegrityError`), the file or the
/// caller's writer failing, `ZipTruncated` when the data runs past the end of the file, and
/// `ZipUnsupportedMethod` for a method `openEntry` would have refused. The header checks
/// happen before, in `openEntry`, so their errors aren't here.
const StreamError = error{ ZipTruncated, ZipUnsupportedMethod } || errors.IntegrityError || std.Io.File.SeekError || error{ReadFailed} || std.Io.Writer.Error;

/// Streams the decompressed bytes of `entry`, which start at `data_start`, into `writer`
/// and returns how many were written. Only for entries `openEntry` has checked.
fn streamData(self: *Archive, entry: *const Entry, data_start: u64, writer: *std.Io.Writer) StreamError!u64 {
    // Encrypted entries, the only ones with an encryption header between the local header
    // and the data (APPNOTE 4.3.6), were refused before this.
    const reader = try self.source.readerAt(data_start);

    var buf: [4 << 10]u8 = undefined;
    var bounded = std.Io.Reader.Limited.init(reader, .limited(entry.compressed_size), &buf);

    switch (entry.method) {
        .stored => {
            if (entry.compressed_size != entry.uncompressed_size) return error.ZipSizeMismatch;
            const actual_crc = try copyExactAndCrc(&bounded.interface, writer, entry.uncompressed_size);
            if (actual_crc != entry.crc32) return error.ZipCrcMismatch;
            return entry.uncompressed_size;
        },
        .deflate => {
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompress: Decompress = .init(&bounded.interface, .raw, &decompress_buf);

            const actual_crc = inflateExactAndCrc(&decompress, writer, entry.uncompressed_size) catch |err| switch (err) {
                // The inflater reports its own failures as ReadFailed and keeps the cause.
                error.ReadFailed => return if (decompress.err) |cause| switch (cause) {
                    error.EndOfStream => error.ZipTruncated,
                    else => error.ZipBadDeflate, // the stream itself is corrupt
                } else err, // no cause: the file read underneath failed
                else => return err,
            };
            if (actual_crc != entry.crc32) return error.ZipCrcMismatch;

            // The deflate stream must use up all of compressed_size: anything left is junk.
            var trailing: [1]u8 = undefined;
            if (try bounded.interface.readSliceShort(&trailing) != 0) return error.ZipSizeMismatch;
            return entry.uncompressed_size;
        },
        // openEntry refuses these; kept an error so nothing can misread them.
        else => return error.ZipUnsupportedMethod,
    }
}

/// Inflates exactly `expected_size` bytes, then reads the deflate stream to its end
/// (final block, APPNOTE 4.4.5 method 8) so the reader holds only what follows it.
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
/// Returns `error.ZipTruncated` if `source` ends first.
fn copyExactAndCrc(source: *std.Io.Reader, dest: *std.Io.Writer, expected_size: u64) !u32 {
    var crc = std.hash.Crc32.init();
    var total: u64 = 0;
    var chunk: [8 << 10]u8 = undefined;

    while (total < expected_size) {
        const chunk_len: usize = @intCast(@min(expected_size - total, chunk.len));
        const n = try source.readSliceShort(chunk[0..chunk_len]);
        if (n == 0) return error.ZipTruncated;

        crc.update(chunk[0..n]);
        try dest.writeAll(chunk[0..n]);
        total += n;
    }
    return crc.final();
}

/// Writes `entry`, its data starting at `data_start`, under `dest` by what `kind` says: a
/// directory, a regular file, or a symlink handled by `options.symlinks`, then sets the
/// mode and mtime `options` asks for. Other types
/// (fifo, device, socket) are written as regular files holding their data, so nothing
/// special is ever created.
fn extractData(self: *Archive, io: std.Io, entry: *const Entry, data_start: u64, dest: std.Io.Dir, options: Entry.ExtractOptions) !void {
    var name_buf: [max_path_bytes]u8 = undefined;
    const name = try self.cleanEntryName(entry, &name_buf);

    const attrs: FileAttributes = .{
        .mode = if (options.apply_unix_mode) permissionBits(entry) else null,
        .mtime = if (options.apply_mtime) entry.modTime() else null,
    };
    switch (entry.kind()) {
        .directory => {
            try makeDirectory(io, entry, dest, name);
            try setDirAttributes(io, dest, trimSlash(name), attrs);
        },
        .symlink => switch (options.symlinks) {
            .refuse => return error.ZipUnsafeSymlink,
            .skip => {},
        },
        .file, .other => try self.writeFile(io, entry, data_start, dest, name, options.file_exists_behavior, attrs),
    }
}

/// Creates the directory `name` (already cleaned, a trailing '/' allowed) and any missing
/// parents under `dest`. One that already exists is fine, as with `unzip`. Returns
/// `error.ZipBadDirectorySize` if the entry carries data.
fn makeDirectory(io: std.Io, entry: *const Entry, dest: std.Io.Dir, name: []const u8) !void {
    if (entry.uncompressed_size != 0) return error.ZipBadDirectorySize;
    try dest.createDirPath(io, trimSlash(name));
}

/// Permission bits and a modification time to set once an entry is written. Null leaves
/// what the OS gives a new file or folder.
const FileAttributes = struct {
    /// Permission bits only, at most 0o777.
    mode: ?u32 = null,
    /// Unix seconds, set as both the access and the modification time, as `unzip` does.
    mtime: ?i64 = null,
};

/// Writes the data of `entry` to the file `name` (already cleaned) under `dest`, creating
/// missing parent directories, then sets `attrs`.
fn writeFile(
    self: *Archive,
    io: std.Io,
    entry: *const Entry,
    data_start: u64,
    dest: std.Io.Dir,
    name: []const u8,
    on_exists: Entry.FileExistsBehavior,
    attrs: FileAttributes,
) !void {
    var parent_dir = dest;
    const parent = std.fs.path.dirname(name);
    if (parent) |dirname| parent_dir = try dest.createDirPathOpen(io, dirname, .{});
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
    // streamData returns exactly uncompressed_size or an error.
    _ = try self.streamData(entry, data_start, &writer.interface);
    try writer.interface.flush();

    // After the data, so the last write doesn't move the time, and a read-only mode can't
    // get in the way.
    if (attrs.mode) |mode| {
        if (permissions(mode)) |p| try out_file.setPermissions(io, p);
    }
    if (attrs.mtime) |mtime| {
        const at = timestamp(mtime);
        try out_file.setTimestamps(io, .{ .access_timestamp = at, .modify_timestamp = at });
    }
}

/// Sets `attrs` on the folder `dir_path` under `dest`.
fn setDirAttributes(io: std.Io, dest: std.Io.Dir, dir_path: []const u8, attrs: FileAttributes) !void {
    if (attrs.mtime) |mtime| {
        const at = timestamp(mtime);
        try dest.setTimestamps(io, dir_path, .{ .access_timestamp = at, .modify_timestamp = at });
    }
    if (attrs.mode) |mode| {
        if (permissions(mode)) |p| try dest.setFilePermissions(io, dir_path, p, .{});
    }
}

/// `mode` as `std.Io.File.Permissions`, or null where they hold no Unix mode (Windows).
fn permissions(mode: u32) ?std.Io.File.Permissions {
    const Permissions = std.Io.File.Permissions;
    if (comptime !@hasDecl(Permissions, "fromMode")) return null;
    return .fromMode(@intCast(mode));
}

/// Unix seconds as a timestamp to set.
fn timestamp(seconds: i64) std.Io.File.SetTimestamp {
    return .{ .new = .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s) };
}

/// `name` without its trailing '/', if it has one.
fn trimSlash(name: []const u8) []const u8 {
    return if (name.len > 0 and name[name.len - 1] == '/') name[0 .. name.len - 1] else name;
}

/// What `extractAll` does with symlink entries (design 11.2).
pub const SymlinkPolicy = enum {
    /// Fail with `ZipUnsafeSymlink` before anything is written.
    refuse,
    /// Leave symlink entries out and extract the rest.
    skip,
    /// Create symlinks whose target is relative and, followed from the link's folder, stays
    /// inside `dest` without passing through another symlink in the archive. Anything
    /// else is `ZipUnsafeSymlink` before anything is written. Links are created last, so
    /// no file or folder is ever written through one. `dest` is trusted: symlinks already
    /// in it aren't looked at.
    create_safe,
};

/// Options for `extractAll`.
pub const ExtractAllOptions = struct {
    /// See `Entry.FileExistsBehavior`.
    file_exists_behavior: Entry.FileExistsBehavior = .fail,
    /// See `SymlinkPolicy`.
    symlinks: SymlinkPolicy = .refuse,
    /// Sets the permission bits (`mode & 0o777`, never setuid, setgid or sticky) of files and
    /// folders made on Unix (`Entry.unixMode`). Others get what the OS gives a new file.
    apply_unix_mode: bool = true,
    /// Sets each file's and folder's modification time to `Entry.modTime`.
    apply_mtime: bool = true,
    /// Runs `checkLayout` first, so overlapping entries, duplicate names and a total size
    /// over the limit fail before anything is written.
    check_layout: bool = true,
};

/// Extracts every entry under `dest` in three passes (design 11.2):
///
/// 1. Checks without writing: `checkLayout` (see `check_layout`), every name through
///    `cleanEntryName`, and the symlink policy. Under `.create_safe` it reads each
///    target and checks it, and refuses any entry whose path runs through a symlink.
/// 2. Creates folders and writes files in archive order, each file's mode and mtime set as
///    soon as it is written.
/// 3. Creates the symlinks, then sets folder modes and mtimes, deepest first: creating
///    entries inside a folder would move its mtime, and a read-only mode would block them.
///
/// A failure in pass 2 or 3 leaves what was already written. Uses `gpa` for the layout
/// check, the cleaned names, the symlink targets and the folder list, all freed before it
/// returns. Walks
/// its own copy of the listing position, so `next` carries on where it was.
pub fn extractAll(self: *Archive, gpa: std.mem.Allocator, io: std.Io, dest: std.Io.Dir, options: ExtractAllOptions) errors.ExtractAllError!void {
    if (options.check_layout) try self.checkLayout(gpa);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved_index = self.cd_index;
    const saved_offset = self.cd_offset;
    defer {
        self.cd_index = saved_index;
        self.cd_offset = saved_offset;
    }

    // Pass 1: names, and symlinks under the policy. Each cleaned name is kept, in archive
    // order, so later passes don't read and clean it again.
    var name_buf: [max_path_bytes]u8 = undefined;
    var names: std.ArrayList([]const u8) = .empty;
    var links: std.ArrayList(Link) = .empty;
    var link_names: std.StringHashMapUnmanaged(void) = .empty;
    self.rewind();
    while (try self.next()) |entry| {
        const name = try arena.dupe(u8, try self.cleanEntryName(&entry, &name_buf));
        try names.append(arena, name);
        if (entry.kind() != .symlink) continue;
        switch (options.symlinks) {
            .refuse => return error.ZipUnsafeSymlink,
            .skip => {},
            .create_safe => {
                if (entry.uncompressed_size > max_path_bytes) return error.ZipUnsafeSymlink;
                const target = try self.readEntryAlloc(arena, &entry, max_path_bytes);
                try links.append(arena, .{ .name = name, .target = target });
                try link_names.put(arena, name, {});
            },
        }
    }
    if (links.items.len > 0) {
        for (links.items) |link| try checkLinkTarget(link.name, link.target, &link_names);
        // A path through a link would be written wherever the link points.
        for (names.items) |name| {
            if (underLink(name, &link_names)) return error.ZipUnsafeSymlink;
        }
    }

    // Pass 2: folders and files.
    var dirs: std.ArrayList(DirAttributes) = .empty;
    self.rewind();
    for (names.items) |name| {
        // Same listing as pass 1, so the walk can't end early.
        const entry = (try self.next()).?;
        const kind = entry.kind();
        if (kind == .symlink) continue;
        const data_start = try self.openEntry(&entry);
        const attrs: FileAttributes = .{
            .mode = if (options.apply_unix_mode) permissionBits(&entry) else null,
            .mtime = if (options.apply_mtime) entry.modTime() else null,
        };
        if (kind == .directory) {
            try makeDirectory(io, &entry, dest, name);
            if (attrs.mode == null and attrs.mtime == null) continue;
            try dirs.append(arena, .{ .path = trimSlash(name), .attrs = attrs });
        } else {
            try self.writeFile(io, &entry, data_start, dest, name, options.file_exists_behavior, attrs);
        }
    }

    // Pass 3: symlinks, then folder attributes.
    for (links.items) |link| {
        if (std.fs.path.dirname(link.name)) |parent| try dest.createDirPath(io, parent);
        try dest.symLink(io, link.target, link.name, .{});
    }
    // Descending order puts "a/b" before "a", whatever order the archive listed them in.
    std.mem.sort(DirAttributes, dirs.items, {}, DirAttributes.deeperFirst);
    for (dirs.items) |dir| try setDirAttributes(io, dest, dir.path, dir.attrs);
}

const max_path_bytes = std.Io.Dir.max_path_bytes;

/// A symlink `extractAll` creates in pass 3.
const Link = struct {
    name: []const u8,
    target: []const u8,
};

/// A folder whose mode and mtime `extractAll` sets in pass 3.
const DirAttributes = struct {
    path: []const u8,
    attrs: FileAttributes,

    fn deeperFirst(_: void, a: DirAttributes, b: DirAttributes) bool {
        return std.mem.order(u8, a.path, b.path) == .gt;
    }
};

/// Points `next` back at the first central header.
fn rewind(self: *Archive) void {
    self.cd_index = 0;
    self.cd_offset = self.cd_start;
}

/// `mode & 0o777` for entries made on Unix. Null when there is no Unix mode, or its
/// permission bits are all 0, which some writers leave unset: applying that would make
/// the file unreadable.
fn permissionBits(entry: *const Entry) ?u32 {
    const mode = entry.unixMode() orelse return null;
    const bits = mode & 0o777;
    return if (bits == 0) null else bits;
}

/// Whether a proper prefix of `name`, ending at a '/', is one of `links`.
fn underLink(name: []const u8, links: *const std.StringHashMapUnmanaged(void)) bool {
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, name, start, '/')) |slash| : (start = slash + 1) {
        if (links.contains(name[0..slash])) return true;
    }
    return false;
}

/// Checks a `.create_safe` symlink: `target` must be relative, with no control byte,
/// backslash or drive prefix, and resolved from `link`'s folder one segment at a time it
/// must never climb above the destination or step into another link in `links`. The last
/// segment may name a link, which is checked on its own. Only the text is looked at, which
/// is enough because every other path in the destination is a real folder or file we made.
fn checkLinkTarget(link: []const u8, target: []const u8, links: *const std.StringHashMapUnmanaged(void)) error{ZipUnsafeSymlink}!void {
    if (target.len == 0 or target[0] == '/') return error.ZipUnsafeSymlink;
    for (target) |c| {
        if (c < 0x20 or c == 0x7F or c == '\\') return error.ZipUnsafeSymlink;
    }
    const first = target[0 .. std.mem.findScalar(u8, target, '/') orelse target.len];
    // Stricter than `path.isDrivePrefix`: any ':' in the first segment, which also
    // covers alternate data streams like "a:b".
    if (std.mem.findScalar(u8, first, ':') != null) return error.ZipUnsafeSymlink;

    var buf: [max_path_bytes]u8 = undefined;
    const parent = std.fs.path.dirname(link) orelse "";
    @memcpy(buf[0..parent.len], parent);
    var len = parent.len;

    var segments = std.mem.splitScalar(u8, target, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        // Stepping past a link, even with "..", goes wherever it points.
        if (len > 0 and links.contains(buf[0..len])) return error.ZipUnsafeSymlink;
        if (std.mem.eql(u8, segment, "..")) {
            if (len == 0) return error.ZipUnsafeSymlink;
            len = std.mem.findScalarLast(u8, buf[0..len], '/') orelse 0;
            continue;
        }
        const sep: usize = @intFromBool(len > 0);
        if (len + sep + segment.len > buf.len) return error.ZipUnsafeSymlink;
        if (sep == 1) buf[len] = '/';
        @memcpy(buf[len + sep ..][0..segment.len], segment);
        len += sep + segment.len;
    }
}

/// Checks `entry` before any of its data is read and returns the offset where the data
/// starts (APPNOTE 4.3.6: local header, name, extra field, then data).
///
/// 1. Refuses what the central values already rule out: encrypted, bits 0 and 6
///    (`ZipEncrypted`), patched data, bit 5 (`ZipPatchedData`), masked local headers,
///    bit 13 (`ZipCentralDirectoryEncrypted`), all APPNOTE 4.4.4, and methods other than
///    stored and deflate (`ZipUnsupportedMethod`, 4.4.5).
/// 2. Reads the local header (4.3.7) and refuses its flags the same way. Bit 13 masks the
///    local values (4.4.17.2), so a masked header is refused, never compared.
/// 3. Cross-checks it against the central header (design 8.4): name, method and bit 3
///    must match (`ZipLocalHeaderMismatch`).
/// 4. Checks the data ends before the central directory starts (`ZipMalformed`): entries
///    come before the central directory (4.3.6), and a size that runs into it or past the
///    end of the file would read the wrong bytes.
/// 5. CRC and sizes must match too (`ZipLocalHeaderMismatch`). With bit 3 the data
///    descriptor must carry the central CRC and sizes instead (`ZipBadDataDescriptor`).
/// 6. Charges the central uncompressed size to `total_out` (see `checkLimits`).
fn openEntry(self: *Archive, entry: *const Entry) !u64 {
    try refuseFlags(entry.flags);
    switch (entry.method) {
        .stored, .deflate => {},
        else => return error.ZipUnsupportedMethod,
    }
    try self.checkLimits(entry);

    const lfh = try records.LocalHeader.read(&self.source, entry.local_header_offset);
    try refuseFlags(lfh.flags);

    // APPNOTE never says the names must match, but 4.4.17.2 allows a different local name
    // only under bit 13, refused above. A mismatch makes tools disagree on the contents.
    if (lfh.name_len != entry.name_len or
        lfh.compression_method != entry.method or
        lfh.flags.data_descriptor != entry.flags.data_descriptor or
        !try self.localNameMatches(entry))
    {
        return error.ZipLocalHeaderMismatch;
    }

    const data = try self.dataRange(entry, lfh);
    if (entry.flags.data_descriptor) {
        try self.checkDataDescriptor(entry, lfh, data.end);
    } else {
        try self.checkLocalSizes(entry, lfh);
    }
    // checkLimits made sure this fits under max_total_size.
    self.total_out += entry.uncompressed_size;
    return data.start;
}

/// Checks `entry` against `limits` from its central sizes alone, before anything is read
/// (design 11.3). Reading stops at the central uncompressed size (APPNOTE 4.4.9), so that
/// size is the most a read can produce: checking it up front is as strict as counting
/// bytes while inflating, and fails before any output instead of partway.
///
/// The running total charges every read that gets past `openEntry`, with the full central
/// size: reading the same entry twice counts twice, and a read that fails partway (a bad
/// CRC, say) still counts in full. It never goes back down. To start over, open the
/// archive again.
fn checkLimits(self: *const Archive, entry: *const Entry) error{ ZipEntryTooLarge, ZipRatioExceeded, ZipTotalTooLarge }!void {
    const size = entry.uncompressed_size;
    if (size > self.limits.max_entry_size) return error.ZipEntryTooLarge;
    // Dividing can't overflow, unlike max_ratio * compressed_size.
    if (size > self.limits.ratio_grace and size / @max(entry.compressed_size, 1) > self.limits.max_ratio) {
        return error.ZipRatioExceeded;
    }
    const total = std.math.add(u64, self.total_out, size) catch return error.ZipTotalTooLarge;
    if (total > self.limits.max_total_size) return error.ZipTotalTooLarge;
}

/// Refuses flags whose entries we can't read (APPNOTE 4.4.4). Checked on both headers:
/// bit 13 describes the local one (4.4.4, 7.2.2), and the flags are not compared otherwise.
fn refuseFlags(flags: GeneralPurposeFlags) error{ ZipEncrypted, ZipCentralDirectoryEncrypted, ZipPatchedData }!void {
    if (flags.encrypted or flags.strong_encryption) return error.ZipEncrypted;
    if (flags.mask_header_values) return error.ZipCentralDirectoryEncrypted;
    if (flags.compressed_patched_data) return error.ZipPatchedData;
}

/// Sizes and local header offset of a central header, taken from its ZIP64 extra field
/// when the 32-bit fields are escaped (APPNOTE 4.5.3).
fn centralSizes(cdfh: records.CentralHeader, central_extra: []const u8) !extra.Zip64 {
    if (!cdfh.requiresZip64()) return .{
        .compressed_size = cdfh.compressed_size,
        .uncompressed_size = cdfh.uncompressed_size,
        .local_header_offset = cdfh.local_header_offset,
        .disk_number_start = cdfh.disk_number_start,
    };

    const extra_iterator: extra.Iterator = .{ .buf = central_extra };
    const field = (try extra_iterator.find(HeaderId.zip64)) orelse
        return error.ZipBadExtraField;
    return extra.Zip64.parse(field.data, .{
        .uncompressed_size = cdfh.uncompressed_size,
        .compressed_size = cdfh.compressed_size,
        .local_header_offset = cdfh.local_header_offset,
        .disk_number_start = cdfh.disk_number_start,
    });
}

/// What `centralMetadata` finds in a central extra block. Null means the field is absent.
const CentralMetadata = struct {
    mtime: ?i64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
};

/// The modification time from the extended timestamp 0x5455 and the owner ids from the
/// Info-ZIP New Unix field 0x7875 of a central extra block (Info-ZIP extrafld.txt). The
/// central 0x5455 holds the modification time only, even when its flags name more, so it
/// is parsed by its length. Strict like the ZIP64 field (bug 13): a block that doesn't
/// split into whole fields, or a malformed 0x5455 or 0x7875, is `ZipBadExtraField`, never
/// "absent". Other fields are skipped.
fn centralMetadata(central_extra: []const u8) error{ZipBadExtraField}!CentralMetadata {
    var out: CentralMetadata = .{};
    var extra_iterator: extra.Iterator = .{ .buf = central_extra };
    while (try extra_iterator.next()) |field| {
        const id = field.asHeaderId() orelse continue;
        switch (id) {
            .extended_timestamp => {
                const ut = try extra.ExtendedTimestamp.parse(field.data);
                out.mtime = if (ut.mtime) |t| t else null;
            },
            .info_zip_unix_new => {
                const ux = try extra.InfoZipUnixNew.parse(field.data);
                out.uid = ux.uid;
                out.gid = ux.gid;
            },
            else => {},
        }
    }
    return out;
}

/// Without bit 3, the local CRC and sizes must equal the central ones. Local sizes come
/// from the local ZIP64 extra when either is escaped (APPNOTE 4.5.3).
fn checkLocalSizes(self: *Archive, entry: *const Entry, lfh: records.LocalHeader) !void {
    if (lfh.crc32 != entry.crc32) return error.ZipLocalHeaderMismatch;

    var compressed: u64 = lfh.compressed_size;
    var uncompressed: u64 = lfh.uncompressed_size;
    if (lfh.requiresZip64()) {
        var buf: [std.math.maxInt(u16)]u8 = undefined;
        const local_extra = try self.readLocalExtra(entry.local_header_offset, lfh, &buf);
        const extra_iterator: extra.Iterator = .{ .buf = local_extra };
        const field = (try extra_iterator.find(HeaderId.zip64)) orelse
            return error.ZipBadExtraField;
        // The local field MUST hold both sizes once either is escaped (APPNOTE 4.5.3), so
        // 16 bytes are both, whatever the header escaped. Shorter fields, from writers that
        // store only the escaped ones, are read against the header.
        const both = field.data.len == 16;
        const z = try extra.Zip64.parse(field.data, .{
            .uncompressed_size = if (both) escaped32 else lfh.uncompressed_size,
            .compressed_size = if (both) escaped32 else lfh.compressed_size,
        });
        // A size the header didn't escape must agree with its copy in the field.
        if (lfh.uncompressed_size != escaped32 and lfh.uncompressed_size != z.uncompressed_size) return error.ZipLocalHeaderMismatch;
        if (lfh.compressed_size != escaped32 and lfh.compressed_size != z.compressed_size) return error.ZipLocalHeaderMismatch;
        compressed = z.compressed_size;
        uncompressed = z.uncompressed_size;
    }

    if (compressed != entry.compressed_size or uncompressed != entry.uncompressed_size) {
        return error.ZipLocalHeaderMismatch;
    }
}

/// With bit 3, the local CRC is zero or the central CRC, and the data descriptor at
/// `data_end`, right after the data, must carry the central CRC and sizes (APPNOTE 4.3.9,
/// 4.4.4).
fn checkDataDescriptor(self: *Archive, entry: *const Entry, lfh: records.LocalHeader, data_end: u64) !void {
    // Local CRC and sizes SHOULD be zero, but some writers fill them in.
    if (lfh.crc32 != 0 and lfh.crc32 != entry.crc32) return error.ZipLocalHeaderMismatch;

    const descriptor = (try self.readDescriptor(entry, lfh, data_end)).record;
    if (descriptor.crc32 != entry.crc32 or
        descriptor.compressed_size != entry.compressed_size or
        descriptor.uncompressed_size != entry.uncompressed_size)
    {
        return error.ZipBadDataDescriptor;
    }
}

/// Whether the data descriptor of `entry` has 8-byte sizes, which APPNOTE 4.3.9.2 gives
/// "ZIP64 format archives": when its local header has a ZIP64 extra, or a central size
/// doesn't fit in 32 bits. Go's archive/zip writes the second kind: 8-byte sizes after
/// entries of 4 GiB or more, with no ZIP64 extra in the local header.
fn descriptorIsZip64(self: *Archive, entry: *const Entry, lfh: records.LocalHeader) !bool {
    if (entry.compressed_size >= escaped32 or entry.uncompressed_size >= escaped32) return true;
    var buf: [std.math.maxInt(u16)]u8 = undefined;
    const local_extra = try self.readLocalExtra(entry.local_header_offset, lfh, &buf);
    const extra_iterator: extra.Iterator = .{ .buf = local_extra };
    return (try extra_iterator.find(HeaderId.zip64)) != null;
}

/// Whether the local name of `entry` equals its central name. The caller has already
/// checked that the lengths match.
fn localNameMatches(self: *Archive, entry: *const Entry) !bool {
    var central_buf: [std.math.maxInt(u16)]u8 = undefined;
    const central_name = central_buf[0..entry.name_len];
    const central = try self.source.readerAt(entry.central_header_offset + records.CentralHeader.size);
    central.readSliceAll(central_name) catch |err| return truncated(err);

    const local = try self.source.readerAt(entry.local_header_offset + records.LocalHeader.size);
    var chunk: [256]u8 = undefined;
    var i: usize = 0;
    while (i < central_name.len) {
        const n = @min(chunk.len, central_name.len - i);
        local.readSliceAll(chunk[0..n]) catch |err| return truncated(err);
        if (!std.mem.eql(u8, chunk[0..n], central_name[i..][0..n])) return false;
        i += n;
    }
    return true;
}

/// Reads the extra field of the local header at `header_offset` into `buf`.
fn readLocalExtra(self: *Archive, header_offset: u64, lfh: records.LocalHeader, buf: *[std.math.maxInt(u16)]u8) ![]u8 {
    const local_extra = buf[0..lfh.extra_len];
    const reader = try self.source.readerAt(header_offset + records.LocalHeader.size + lfh.name_len);
    reader.readSliceAll(local_extra) catch |err| return truncated(err);
    return local_extra;
}

/// Checks the entry count and that the central directory ends inside the file.
fn validateSizeFields(self: *const Archive, file_size: u64) error{ ZipTooManyEntries, ZipMalformed }!void {
    if (self.total_entries > self.limits.max_entries) return error.ZipTooManyEntries;
    if (self.cd_offset >= file_size) return error.ZipMalformed;
    const end = std.math.add(u64, self.cd_offset, self.cd_size) catch return error.ZipMalformed;
    if (end > file_size) return error.ZipMalformed;
}
