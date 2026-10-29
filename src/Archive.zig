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
const Entry = @import("Entry.zig");
const Source = @import("source.zig").Source;
const HeaderId = @import("format.zig").HeaderId;
const GeneralPurposeFlags = @import("format.zig").GeneralPurposeFlags;
const CentralDirectoryFileHeader = @import("records/central_directory.zig").CentralDirectoryFileHeader;
const DataDescriptor = @import("records/data_descriptor.zig").DataDescriptor;
const EndOfCentralDirectoryRecord = @import("records/eocd.zig").EndOfCentralDirectoryRecord;
const EndRecord64Locator = @import("records/eocd64.zig").EndRecord64Locator;
const EndOfCentralDirectoryRecord64 = @import("records/eocd64.zig").EndOfCentralDirectoryRecord64;
const LocalFileHeader = @import("records/local_file_header.zig").LocalFileHeader;

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
cd_size: u64 = 0,
/// Entry count from the EOCD or ZIP64 end record.
total_entries: u64 = 0,
/// One past the last byte of the central directory.
cd_end: u64 = 0,

/// Guard against an entry count that would make callers loop for hours.
const max_reasonable_entries = 10_000_000;

/// Opens an archive in a file. The caller keeps `reader` alive while the archive is used.
pub fn openFile(reader: *std.Io.File.Reader) errors.OpenError!Archive {
    return open(.fromFile(reader));
}

/// Opens an archive already in memory. The caller keeps `bytes` alive while the archive is
/// used. Reading from memory never fails I/O.
pub fn openMemory(bytes: []const u8) errors.OpenError!Archive {
    return open(.fromMemory(bytes));
}

/// Reads the end records and checks that the central directory lies inside the archive.
pub fn open(source: Source) errors.OpenError!Archive {
    var archive: Archive = .{ .source = source };
    const file_size = try archive.source.size();

    const eocd = try EndOfCentralDirectoryRecord.read(&archive.source);
    try eocd.record.validateStructure(file_size, eocd.offset);

    if (eocd.record.requiresZip64()) {
        // An escaped EOCD field means the real values are in the ZIP64 end record,
        // found through the locator just before the EOCD (APPNOTE 4.3.14, 4.3.15).
        const locator = try EndRecord64Locator.read(&archive.source, file_size, eocd.offset);
        const record64 = try EndOfCentralDirectoryRecord64.read(
            &archive.source,
            file_size,
            locator.central_directory_offset,
        );
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
    archive.cd_end = archive.cd_offset + archive.cd_size;
    return archive;
}

/// Returns the next entry, or null after the last one.
///
/// One sequential pass over the central directory (APPNOTE 4.3.12): no local header or data
/// descriptor is read here, and nothing is refused based on flags or method. Entries we
/// can't read still list; `streamEntry` checks and refuses them. Sizes and the local header
/// offset come from the ZIP64 extra field when escaped (4.5.3).
pub fn next(self: *Archive) errors.IterError!?Entry {
    if (self.cd_index == self.total_entries) return null;
    // The end record promised more entries than the central directory holds (APPNOTE 4.3.16).
    if (self.cd_offset >= self.cd_end) return error.ZipCentralDirectoryMismatch;

    const header_offset = self.cd_offset;
    const cdfh = try CentralDirectoryFileHeader.read(&self.source, header_offset);

    // cd_offset < cd_end <= file size and entry_size < 200 KiB, so this can't overflow.
    const entry_size = cdfh.computeEntrySize();
    if (header_offset + entry_size > self.cd_end) return error.ZipMalformed;

    defer {
        self.cd_index += 1;
        self.cd_offset += entry_size;
    }

    // The extra field follows the name, which stays unread until `filaneme` asks for it.
    // readSliceAll refills; toss would assert when the field crosses the end of the
    // buffered bytes (bug 23).
    const reader = try self.source.readerAt(header_offset + CentralDirectoryFileHeader.size + cdfh.filename_len);
    var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
    const central_extra = extra_buf[0..cdfh.extra_len];
    reader.readSliceAll(central_extra) catch |err| return truncated(err);

    const sizes = try centralSizes(cdfh, central_extra);
    return .{
        .local_header_offset = sizes.local_file_header_relative_offset,
        .central_header_offset = header_offset,
        .name_len = cdfh.filename_len,
        .method = cdfh.compression_method,
        .flags = cdfh.flags,
        .crc32 = cdfh.crc32,
        .compressed_size = sizes.compressed_size,
        .uncompressed_size = sizes.uncompressed_size,
    };
}

/// Streams the decompressed bytes of `entry`, an entry `next` returned, into `w`, and
/// returns how many were written. Checks and refuses the entry first (see `openEntry`).
/// The output stops at the central uncompressed size (`ZipSizeMismatch` if the data is
/// longer or shorter) and its CRC-32 must equal the central one (`ZipCrcMismatch`).
pub fn streamEntry(self: *Archive, entry: *const Entry, w: *std.Io.Writer) errors.EntryError!u64 {
    const data_start = try self.openEntry(entry);
    return entry.stream(&self.source, data_start, w);
}

/// Reads the decompressed bytes of `entry` into memory the caller owns. Fails with
/// `ZipEntryTooLarge` before allocating if the central uncompressed size is over
/// `max_size`. Checks and refusals are those of `streamEntry`.
pub fn readEntryAlloc(self: *Archive, gpa: std.mem.Allocator, entry: *const Entry, max_size: u64) (errors.EntryError || std.mem.Allocator.Error)![]u8 {
    if (entry.uncompressed_size > max_size) return error.ZipEntryTooLarge;
    const len = std.math.cast(usize, entry.uncompressed_size) orelse return error.ZipEntryTooLarge;
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    // streamEntry never writes past the declared size, so a fixed buffer is enough.
    var w: std.Io.Writer = .fixed(bytes);
    _ = try self.streamEntry(entry, &w);
    return bytes;
}

/// Writes `entry` under `dst`: a directory for a name ending in '/', else a file. Checks and
/// refuses the entry (see `openEntry`) before anything is created on disk.
pub fn extractEntry(self: *Archive, io: std.Io, entry: *const Entry, dst: std.Io.Dir, options: Entry.ExtractOptions) !void {
    const data_start = try self.openEntry(entry);
    return entry.extract(io, &self.source, data_start, dst, options);
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
///    must match, and so must CRC and sizes (`ZipLocalHeaderMismatch`). With bit 3 the
///    data descriptor must carry the central CRC and sizes (`ZipBadDataDescriptor`).
fn openEntry(self: *Archive, entry: *const Entry) !u64 {
    try refuseFlags(entry.flags);
    switch (entry.method) {
        .stored, .deflate => {},
        else => return error.ZipUnsupportedMethod,
    }

    const lfh = try LocalFileHeader.read(&self.source, entry.local_header_offset);
    try refuseFlags(lfh.flags);

    // APPNOTE never says the names must match, but 4.4.17.2 allows a different local name
    // only under bit 13, refused above. A mismatch makes tools disagree on the contents.
    if (lfh.filename_len != entry.name_len or
        lfh.compression_method != entry.method or
        lfh.flags.data_descriptor != entry.flags.data_descriptor or
        !try self.localNameMatches(entry))
    {
        return error.ZipLocalHeaderMismatch;
    }

    const data_start = entry.local_header_offset + LocalFileHeader.size + lfh.filename_len + lfh.extra_len;

    if (entry.flags.data_descriptor) {
        try self.checkDataDescriptor(entry, lfh, data_start);
    } else {
        try self.checkLocalSizes(entry, lfh);
    }
    return data_start;
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
fn centralSizes(cdfh: CentralDirectoryFileHeader, central_extra: []const u8) !extra.Zip64Extended {
    if (!cdfh.requires_zip64()) return .{
        .compressed_size = cdfh.compressed_size,
        .uncompressed_size = cdfh.uncompressed_size,
        .local_file_header_relative_offset = cdfh.local_file_header_relative_offset,
        .disk_number_start = cdfh.disk_number_start,
    };

    const extra_iterator: extra.Iterator = .{ .buf = central_extra };
    const field = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse return error.ZipBadExtraField;
    // A 0x0001 field always has a parser, so parse never returns null for it.
    const out = (try field.parse(.{ .zip64_extended_extra_field = .{
        .uncompressed_size = cdfh.uncompressed_size,
        .compressed_size = cdfh.compressed_size,
        .disk_number_start = cdfh.disk_number_start,
        .local_file_header_relative_offset = cdfh.local_file_header_relative_offset,
    } })).?;
    return out.zip64_extended_extra_field;
}

/// Without bit 3, the local CRC and sizes must equal the central ones. Local sizes come
/// from the local ZIP64 extra when escaped (APPNOTE 4.5.3).
fn checkLocalSizes(self: *Archive, entry: *const Entry, lfh: LocalFileHeader) !void {
    if (lfh.crc32 != entry.crc32) return error.ZipLocalHeaderMismatch;

    var compressed: u64 = lfh.compressed_size;
    var uncompressed: u64 = lfh.uncompressed_size;
    if (compressed == 0xFFFF_FFFF or uncompressed == 0xFFFF_FFFF) {
        var buf: [std.math.maxInt(u16)]u8 = undefined;
        const local_extra = try self.readLocalExtra(entry.local_header_offset, lfh, &buf);
        const extra_iterator: extra.Iterator = .{ .buf = local_extra };
        const field = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse return error.ZipBadExtraField;
        const z = (try field.parse(.{ .zip64_extended_extra_field = .{
            .uncompressed_size = lfh.uncompressed_size,
            .compressed_size = lfh.compressed_size,
            .disk_number_start = null,
            .local_file_header_relative_offset = 0,
        } })).?.zip64_extended_extra_field;
        compressed = z.compressed_size;
        uncompressed = z.uncompressed_size;
    }

    if (compressed != entry.compressed_size or uncompressed != entry.uncompressed_size) {
        return error.ZipLocalHeaderMismatch;
    }
}

/// With bit 3, the local CRC is zero or the central CRC, and the data descriptor after
/// the data must carry the central CRC and sizes (APPNOTE 4.3.9, 4.4.4).
fn checkDataDescriptor(self: *Archive, entry: *const Entry, lfh: LocalFileHeader, data_start: u64) !void {
    // Local CRC and sizes SHOULD be zero, but some writers fill them in.
    if (lfh.crc32 != 0 and lfh.crc32 != entry.crc32) return error.ZipLocalHeaderMismatch;

    // Descriptor sizes are 8 bytes when the local header has a ZIP64 extra, whatever
    // the central directory has (APPNOTE 4.3.9.2).
    var buf: [std.math.maxInt(u16)]u8 = undefined;
    const local_extra = try self.readLocalExtra(entry.local_header_offset, lfh, &buf);
    const extra_iterator: extra.Iterator = .{ .buf = local_extra };
    const zip64 = extra_iterator.find(HeaderId.zip64_extended_extra_field) != null;

    const descriptor = try DataDescriptor.read(&self.source, data_start + entry.compressed_size, zip64);
    if (descriptor.crc32 != entry.crc32 or
        descriptor.compressed_size != entry.compressed_size or
        descriptor.uncompressed_size != entry.uncompressed_size)
    {
        return error.ZipBadDataDescriptor;
    }
}

/// Whether the local name of `entry` equals its central name. The caller has already
/// checked that the lengths match.
fn localNameMatches(self: *Archive, entry: *const Entry) !bool {
    var central_buf: [std.math.maxInt(u16)]u8 = undefined;
    const central_name = central_buf[0..entry.name_len];
    const central = try self.source.readerAt(entry.central_header_offset + CentralDirectoryFileHeader.size);
    central.readSliceAll(central_name) catch |err| return truncated(err);

    const local = try self.source.readerAt(entry.local_header_offset + LocalFileHeader.size);
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
fn readLocalExtra(self: *Archive, header_offset: u64, lfh: LocalFileHeader, buf: *[std.math.maxInt(u16)]u8) ![]u8 {
    const local_extra = buf[0..lfh.extra_len];
    const reader = try self.source.readerAt(header_offset + LocalFileHeader.size + lfh.filename_len);
    reader.readSliceAll(local_extra) catch |err| return truncated(err);
    return local_extra;
}

/// Checks the entry count and that the central directory ends inside the file.
fn validateSizeFields(self: Archive, file_size: u64) error{ ZipTooManyEntries, ZipMalformed }!void {
    if (self.total_entries > max_reasonable_entries) return error.ZipTooManyEntries;
    if (self.cd_offset >= file_size) return error.ZipMalformed;
    const end = std.math.add(u64, self.cd_offset, self.cd_size) catch return error.ZipMalformed;
    if (end > file_size) return error.ZipMalformed;
}
