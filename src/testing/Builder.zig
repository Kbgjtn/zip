//! Test-only ZIP builder: writes raw records into memory with any field set to any value,
//! so tests can make hostile archives without fixture files.
//!
//! It never validates anything. Every options struct defaults to a valid record, and a test
//! changes only the field it is about. Records come out in call order, so the caller lays
//! out the archive (APPNOTE 4.3.6) and passes offsets along, taking them with `pos()`:
//!
//!     const off = try b.entry("a.txt", "hi\n");
//!     const cd_offset = b.pos();
//!     try b.central(.{ .name = "a.txt", .offset = @intCast(off), ... });
//!     try b.eocd(.{ .entries = 1, .cd_offset = @intCast(cd_offset), ... });
//!
//! Never shipped: only test files import it.
const std = @import("std");
const Writer = std.Io.Writer;

const records = @import("../records/root.zig");

const Builder = @This();

/// The archive so far. Its writer points into itself, so a Builder must not be copied
/// after the first write.
aw: Writer.Allocating,

/// Starts an empty archive. Call `deinit` when done.
pub fn init(gpa: std.mem.Allocator) Builder {
    return .{
        .aw = .init(gpa),
    };
}

/// Frees the archive; any slice from `bytes` is invalid after this.
pub fn deinit(self: *Builder) void {
    self.aw.deinit();
    self.* = undefined;
}

/// Current length of the archive, which is the offset the next record will start at.
pub fn pos(self: *Builder) usize {
    return self.aw.written().len;
}

/// The archive so far. Mutable, so a test can damage it in place (flip a byte, patch a
/// field). Invalidated by the next write.
pub fn bytes(self: *Builder) []u8 {
    return self.aw.written();
}

/// Fields of a local file header (APPNOTE 4.3.7). Defaults are a valid, empty, stored entry.
/// Method and flags are plain u16 so a test can write values the enums don't name.
pub const LocalOptions = struct {
    signature: u32 = records.LocalHeader.signature_marker,
    version_needed: u16 = 20,
    flags: u16 = 0,
    method: u16 = 0, // stored
    time: u16 = 0,
    date: u16 = 0x21, // 1980-01-01, the smallest valid DOS date
    crc32: u32 = 0,
    compressed_size: u32 = 0,
    uncompressed_size: u32 = 0,
    name: []const u8 = "",
    extra: []const u8 = "",
    // null means name.len; set it to make the header lie.
    name_len: ?u16 = null,
    extra_len: ?u16 = null,
};

/// Writes a local file header, then its name and extra (APPNOTE 4.3.7).
/// Entry data is not included; write it with `raw`.
pub fn local(self: *Builder, o: LocalOptions) !void {
    const w = &self.aw.writer;
    try w.writeStruct(records.LocalHeader{
        .signature = o.signature,
        .version_needed_to_extract = o.version_needed,
        .flags = @bitCast(o.flags),
        .compression_method = @enumFromInt(o.method),
        .dos_time = o.time,
        .dos_date = o.date,
        .crc32 = o.crc32,
        .compressed_size = o.compressed_size,
        .uncompressed_size = o.uncompressed_size,
        .name_len = o.name_len orelse @intCast(o.name.len),
        .extra_len = o.extra_len orelse @intCast(o.extra.len),
    }, .little);
    try w.writeAll(o.name);
    try w.writeAll(o.extra);
}

/// Writes a valid stored entry, local header plus `data`, and returns its offset for `central`.
pub fn entry(self: *Builder, name: []const u8, data: []const u8) !u64 {
    const off = self.pos();
    const size: u32 = @intCast(data.len);
    try self.local(.{
        .name = name,
        .crc32 = std.hash.Crc32.hash(data),
        .compressed_size = size,
        .uncompressed_size = size,
    });
    try self.raw(data);
    return off;
}

/// Writes `data` as is: entry data, junk between records, or a record cut short.
pub fn raw(self: *Builder, data: []const u8) !void {
    try self.aw.writer.writeAll(data);
}

/// Fields of a central directory header (APPNOTE 4.3.12). Defaults are a valid header for
/// an empty stored file at offset 0; set `name`, `offset`, CRC and sizes to match the entry.
pub const CentralOptions = struct {
    signature: u32 = records.CentralHeader.signature_marker,
    /// 3.0 made by Unix (APPNOTE 4.4.2).
    version_made_by: u16 = (3 << 8) | 30,
    version_needed: u16 = 20,
    flags: u16 = 0,
    method: u16 = 0, // stored
    time: u16 = 0,
    date: u16 = 0x21,
    crc32: u32 = 0,
    compressed_size: u32 = 0,
    uncompressed_size: u32 = 0,
    disk_start: u16 = 0,
    internal_attributes: u16 = 0,
    /// Regular file, mode 0644, in the high 16 bits (APPNOTE 4.4.15).
    external_attributes: u32 = 0o100644 << 16,
    /// Offset of the entry's local header, usually what `entry` returned.
    offset: u32 = 0,
    name: []const u8 = "",
    extra: []const u8 = "",
    comment: []const u8 = "",
    // null means the real length; set it to make the header lie.
    name_len: ?u16 = null,
    extra_len: ?u16 = null,
    comment_len: ?u16 = null,
};

/// Writes a central directory header, then its name, extra and comment (APPNOTE 4.3.12).
pub fn central(self: *Builder, o: CentralOptions) !void {
    const w = &self.aw.writer;
    try w.writeStruct(records.CentralHeader{
        .signature = o.signature,
        .version_made_by = @bitCast(o.version_made_by),
        .version_needed_to_extract = o.version_needed,
        .flags = @bitCast(o.flags),
        .compression_method = @enumFromInt(o.method),
        .dos_time = o.time,
        .dos_date = o.date,
        .crc32 = o.crc32,
        .compressed_size = o.compressed_size,
        .uncompressed_size = o.uncompressed_size,
        .name_len = o.name_len orelse @intCast(o.name.len),
        .extra_len = o.extra_len orelse @intCast(o.extra.len),
        .comment_len = o.comment_len orelse @intCast(o.comment.len),
        .disk_number_start = o.disk_start,
        .internal_file_attributes = o.internal_attributes,
        .external_attributes = o.external_attributes,
        .local_header_offset = o.offset,
    }, .little);
    try w.writeAll(o.name);
    try w.writeAll(o.extra);
    try w.writeAll(o.comment);
}

/// Fields of the end of central directory record (APPNOTE 4.3.16). Defaults describe an
/// empty archive; set `entries`, `cd_size` and `cd_offset` to match what was written.
pub const EocdOptions = struct {
    signature: u32 = records.EndRecord.signature_marker,
    disk: u16 = 0,
    cd_disk: u16 = 0,
    /// Entries on this disk; null means `entries`.
    entries_disk: ?u16 = null,
    entries: u16 = 0,
    cd_size: u32 = 0,
    cd_offset: u32 = 0,
    comment: []const u8 = "",
    comment_len: ?u16 = null,
};

/// Writes the end of central directory record and its comment (APPNOTE 4.3.16).
pub fn eocd(self: *Builder, o: EocdOptions) !void {
    const w = &self.aw.writer;
    try w.writeStruct(records.EndRecord{
        .signature = o.signature,
        .disk_number = o.disk,
        .central_directory_disk_number = o.cd_disk,
        .record_count_disk = o.entries_disk orelse o.entries,
        .record_count_total = o.entries,
        .central_directory_size = o.cd_size,
        .central_directory_offset = o.cd_offset,
        .comment_len = o.comment_len orelse @intCast(o.comment.len),
    }, .little);
    try w.writeAll(o.comment);
}

/// Fields of the ZIP64 end of central directory record (APPNOTE 4.3.14). Readers look for
/// it only when the EOCD has a 0xFFFF or 0xFFFFFFFF field, so set those in `eocd` too.
pub const Eocd64Options = struct {
    signature: u32 = records.EndRecord64.signature_marker,
    /// Size of the rest of the record, without the leading 12 bytes (APPNOTE 4.3.14.1).
    record_size: u64 = records.EndRecord64.size,
    version_made_by: u16 = (3 << 8) | 45,
    version_needed: u16 = 45,
    disk: u32 = 0,
    cd_disk: u32 = 0,
    /// Entries on this disk; null means `entries`.
    entries_disk: ?u64 = null,
    entries: u64 = 0,
    cd_size: u64 = 0,
    cd_offset: u64 = 0,
};

/// Writes the ZIP64 end of central directory record (APPNOTE 4.3.14).
/// `record_size` is written as given and no data sector follows, so a bigger value lies.
pub fn eocd64(self: *Builder, o: Eocd64Options) !void {
    const w = &self.aw.writer;
    try w.writeStruct(records.EndRecord64.Header{
        .signature = o.signature,
        .record_size = o.record_size,
    }, .little);
    try w.writeStruct(records.EndRecord64{
        .version_made_by = @bitCast(o.version_made_by),
        .version_needed_to_extract = o.version_needed,
        .disk_number = o.disk,
        .central_directory_disk_number = o.cd_disk,
        .record_count_disk = o.entries_disk orelse o.entries,
        .record_count_total = o.entries,
        .central_directory_size = o.cd_size,
        .central_directory_offset = o.cd_offset,
    }, .little);
}

/// Fields of the ZIP64 end of central directory locator (APPNOTE 4.3.15). It must sit right
/// before the EOCD, so write it last, just before `eocd`.
pub const Locator64Options = struct {
    signature: u32 = records.EndRecord64Locator.signature_marker,
    eocd64_disk: u32 = 0,
    /// Offset of the ZIP64 end record, usually `pos()` taken before `eocd64`.
    eocd64_offset: u64 = 0,
    total_disks: u32 = 1,
};

/// Writes the ZIP64 end of central directory locator (APPNOTE 4.3.15).
pub fn locator64(self: *Builder, o: Locator64Options) !void {
    try self.aw.writer.writeStruct(records.EndRecord64Locator{
        .signature = o.signature,
        .record_disk = o.eocd64_disk,
        .record_offset = o.eocd64_offset,
        .total_disks = o.total_disks,
    }, .little);
}

/// Fields of a data descriptor (APPNOTE 4.3.9). It follows the data of an entry with flag
/// bit 3 set, whose local header has zero CRC and sizes.
pub const DescriptorOptions = struct {
    /// The signature is optional on the wire (APPNOTE 4.3.9.3); false leaves it out.
    signed: bool = true,
    signature: u32 = records.DataDescriptor.signature_marker,
    crc32: u32 = 0,
    compressed_size: u64 = 0,
    uncompressed_size: u64 = 0,
    /// 8-byte sizes, used when the entry has a ZIP64 extra (APPNOTE 4.3.9.2).
    zip64: bool = false,
};

/// Writes a data descriptor after an entry's data (APPNOTE 4.3.9).
/// Written field by field: `records.DataDescriptor` holds u64 sizes whatever the wire
/// width, so its memory layout is not the wire layout.
pub fn descriptor(self: *Builder, o: DescriptorOptions) !void {
    const w = &self.aw.writer;
    if (o.signed) try w.writeInt(u32, o.signature, .little);
    try w.writeInt(u32, o.crc32, .little);
    if (o.zip64) {
        try w.writeInt(u64, o.compressed_size, .little);
        try w.writeInt(u64, o.uncompressed_size, .little);
    } else {
        try w.writeInt(u32, @truncate(o.compressed_size), .little);
        try w.writeInt(u32, @truncate(o.uncompressed_size), .little);
    }
}
