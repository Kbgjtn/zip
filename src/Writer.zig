//! ZIP archive writer.
//!
//! Entries go out one after another as local header, name and data (APPNOTE 4.3.6). The
//! writer keeps a small record per entry, and `finish` writes the central directory and
//! the end record from them.
//!
//! Current limits:
//! - ZIP64 only where it's needed. Sizes and offsets of 0xFFFFFFFF or more go in the ZIP64
//!   extra field (APPNOTE 4.5.3), and `finish` writes the ZIP64 end records (APPNOTE 4.3.14,
//!   4.3.15) for 0xFFFF or more entries, or a central directory whose size or offset is
//!   0xFFFFFFFF or more.
//! - `addStream` can't know up front whether an entry needs ZIP64, so the caller says so
//!   with `StreamOptions.zip64`.
//! - Data descriptors (bit 3) only for `addStream`, where the size isn't known up front.
//!   `addBytes`, `addDirectory` and `addSymlink` know sizes and CRC first, so bit 3 stays off.
//! - The only extra fields are the 0x5455 extended timestamp, mtime only (see `timestampExtra`),
//!   and the 0x0001 ZIP64 extra (see `CdRecord.zip64Extra`).
//!
//! Initialise it in place with `init` and never copy it. `counter.interface` points at
//! `self.buf`, and `CountingWriter` finds itself through `@fieldParentPtr`, so a copy
//! would write through a stale pointer.

const std = @import("std");

const flate = std.compress.flate;
const format = @import("format.zig");
const time = @import("time.zig");
const path = @import("path.zig");
const CountingWriter = @import("CountingWriter.zig");
const HashingWriter = @import("HashingWriter.zig");

const records = @import("records/root.zig");

const Writer = @This();

/// Allocator for the compressor, the window, the records and their names.
gpa: std.mem.Allocator,
/// Wraps the caller's writer and tracks the byte offset, which the central directory needs.
counter: CountingWriter,
/// Buffer behind `counter.interface`. Lives here, which is why the Writer can't be copied.
buf: [8 << 10]u8,
/// One record per entry written so far, turned into central directory headers by `finish`.
cd_records: std.ArrayList(CdRecord),
/// Deflate state, ~224 KiB, so it lives on the heap and is reused for every entry.
compress: *flate.Compress,
/// Deflate history window, `flate.max_window_len` bytes.
window: []u8,
/// Set by `finish`. After that, every add call and `finish` return `error.WriterFinished`.
finished: bool = false,

/// Set when an add call failed after writing part of an entry. `out` then holds
/// a broken entry, so every later add and `finish` return `error.WriterFailed`.
poisoned: bool = false,

/// What the central directory header needs to know about an entry that is already written
/// (APPNOTE 4.3.12). Sizes and offset are u64; values that don't fit the 32-bit header fields
/// go in the ZIP64 extra (APPNOTE 4.5.3).
const CdRecord = struct {
    /// Owned copy of the entry name, freed in `deinit`.
    name: []const u8,
    /// Same flags as the local header.
    flags: format.GeneralPurposeFlags,
    /// Method actually used, which can be `.stored` even when deflate was asked for.
    compression_method: format.CompressionMethod,
    /// DOS time (APPNOTE 4.4.6).
    dos_time: u16,
    /// DOS date (APPNOTE 4.4.6).
    dos_date: u16,
    /// CRC-32 of the uncompressed data.
    crc32: u32,
    /// Bytes stored in the archive.
    compressed_size: u64,
    /// Bytes after extraction.
    uncompressed_size: u64,
    /// Offset of the entry's local header from the start of the archive.
    local_header_offset: u64,
    /// Unix mode in the high 16 bits, MS-DOS attributes (0x10 for directories) in the low byte
    external_attributes: u32,
    /// 10 for stored, 20 for deflate, 45 when either header has the ZIP64 extra (APPNOTE 4.4.3).
    version_needed: u16,
    /// Modification time in Unix seconds, for the 0x5455 extra field in both headers.
    mtime: i64,
    /// The local header has the ZIP64 extra with both sizes, and 0xFFFFFFFF in its size fields
    /// (APPNOTE 4.5.3). For a streamed entry it also means 8-byte descriptor sizes (4.3.9.2).
    zip64_local: bool,

    /// Local file header for this entry (APPNOTE 4.3.7). With `zip64_local` both sizes are
    /// 0xFFFFFFFF and the real ones are in the ZIP64 extra. Without it they must fit in u32,
    /// which the add functions make sure of by setting `zip64_local` when they don't.
    fn localHeader(r: *const CdRecord) records.LocalHeader {
        return .{
            .signature = records.LocalHeader.signature_marker,
            .version_needed_to_extract = r.version_needed,
            .flags = r.flags,
            .compression_method = r.compression_method,
            .last_modification_time = r.dos_time,
            .last_modification_date = r.dos_date,
            .crc32 = r.crc32,
            .compressed_size = if (r.zip64_local) 0xFFFF_FFFF else @intCast(r.compressed_size),
            .uncompressed_size = if (r.zip64_local) 0xFFFF_FFFF else @intCast(r.uncompressed_size),
            .filename_len = @intCast(r.name.len),
            .extra_len = r.extraLen(.local),
        };
    }

    /// Central directory header for this entry (APPNOTE 4.3.12). Sizes and offset of
    /// 0xFFFFFFFF or more are written as 0xFFFFFFFF, with the real values in the ZIP64 extra.
    fn centralHeader(r: *const CdRecord) records.CentralHeader {
        return .{
            .signature = records.CentralHeader.signature_marker,
            // Made by Unix (3) with spec 6.3 (63), i.e. (3 << 8) | 63, so readers trust the
            // mode in external attributes (APPNOTE 4.4.2).
            .version_made_by = .{ .spec_version = 63, .os = .unix },
            .version_needed_to_extract = r.version_needed,
            .flags = r.flags,
            .compression_method = r.compression_method,
            .last_modification_time = r.dos_time,
            .last_modification_date = r.dos_date,
            .crc32 = r.crc32,
            .compressed_size = field32(r.compressed_size),
            .uncompressed_size = field32(r.uncompressed_size),
            .filename_len = @intCast(r.name.len),
            .extra_len = r.extraLen(.central),
            .comment_len = 0,
            .disk_number_start = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = r.external_attributes,
            .local_file_header_relative_offset = field32(r.local_header_offset),
        };
    }

    /// Bytes of extra field after the name in `header`: the 0x5455 timestamp, then ZIP64.
    fn extraLen(r: *const CdRecord, header: HeaderKind) u16 {
        var zip64_buf: [zip64_extra_max_len]u8 = undefined;
        const ut: usize = if (timestampExtra(r.mtime) != null) timestamp_extra_len else 0;
        return @intCast(ut + r.zip64Extra(header, &zip64_buf).len);
    }

    /// Writes the extra fields that `extraLen` counts, in the same order.
    fn writeExtra(r: *const CdRecord, w: *std.Io.Writer, header: HeaderKind) !void {
        if (timestampExtra(r.mtime)) |bytes| try w.writeAll(&bytes);
        var zip64_buf: [zip64_extra_max_len]u8 = undefined;
        try w.writeAll(r.zip64Extra(header, &zip64_buf));
    }

    /// ZIP64 extended information extra field 0x0001 (APPNOTE 4.5.3), built in `buf`: tag,
    /// data size, then u64 uncompressed size, compressed size and local header offset, in that
    /// order and each only when present. All little-endian. Returns the bytes, or an empty
    /// slice when `header` needs no ZIP64 extra.
    /// - Local: both sizes when `zip64_local`, never the offset.
    /// - Central: only the values whose 32-bit field is 0xFFFFFFFF.
    /// The u32 disk start number is never needed, since it's always 0.
    fn zip64Extra(r: *const CdRecord, header: HeaderKind, buf: *[zip64_extra_max_len]u8) []const u8 {
        const values = [_]u64{ r.uncompressed_size, r.compressed_size, r.local_header_offset };
        var len: usize = 4;
        for (values, 0..) |value, i| {
            const present = switch (header) {
                .local => r.zip64_local and i < 2,
                .central => value >= 0xFFFF_FFFF,
            };
            if (!present) continue;
            std.mem.writeInt(u64, buf[len..][0..8], value, .little);
            len += 8;
        }
        if (len == 4) return buf[0..0];

        std.mem.writeInt(u16, buf[0..2], @intFromEnum(format.HeaderId.zip64_extended_extra_field), .little);
        std.mem.writeInt(u16, buf[2..4], @intCast(len - 4), .little);
        return buf[0..len];
    }
};

/// Which header an extra field is for. Only the ZIP64 extra differs between the two.
const HeaderKind = enum { local, central };

/// Tag, size and three u64 values. Disk start is never written, see `CdRecord.zip64Extra`.
const zip64_extra_max_len = 4 + 8 + 8 + 8;

const timestamp_extra_len = 9;

comptime {
    // Both extras together always fit the u16 extra field length.
    std.debug.assert(timestamp_extra_len + zip64_extra_max_len <= std.math.maxInt(u16));
}

/// A 32-bit header field: the value itself, or 0xFFFFFFFF when it needs the ZIP64 extra.
fn field32(value: u64) u32 {
    return if (value >= 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(value);
}

/// Info-ZIP extended timestamp extra field 0x5455 ("UT", APPNOTE 4.5 and 4.6) with mtime
/// only: tag, data size 5, flags 0x01, mtime as i32 Unix seconds (UTC), all little-endian.
/// Same bytes in the local and central headers. Returns null when mtime doesn't fit in i32
/// (before 1901 or after 2038), in which case the field is left out, like Info-ZIP does.
fn timestampExtra(mtime: i64) ?[timestamp_extra_len]u8 {
    const t = std.math.cast(i32, mtime) orelse return null;
    var out: [timestamp_extra_len]u8 = undefined;

    std.mem.writeInt(u16, out[0..2], 0x5455, .little);
    std.mem.writeInt(u16, out[2..4], 5, .little);
    out[4] = 0x01; // bit 0: mtime present
    std.mem.writeInt(i32, out[5..9], t, .little);

    return out;
}

test "writer: timestampExtra encodes mtime and skips values outside i32" {
    const testing = std.testing;
    const bytes = timestampExtra(1793013477).?;
    try testing.expectEqualSlices(u8, &.{ 'U', 'T', 5, 0, 1, 0xE5, 0x36, 0xDF, 0x6A }, &bytes);
    try testing.expectEqual(@as(i32, -1), std.mem.readInt(i32, timestampExtra(-1).?[5..9], .little));
    try testing.expect(timestampExtra(std.math.maxInt(i32)) != null);
    try testing.expect(timestampExtra(std.math.maxInt(i32) + 1) == null);
    try testing.expect(timestampExtra(std.math.minInt(i32) - 1) == null);
}

/// A record with only the fields the header and extra tests look at set to something useful.
fn testRecord(uncompressed: u64, compressed: u64, offset: u64, zip64_local: bool) CdRecord {
    return .{
        .name = "a.txt",
        .flags = @bitCast(@as(u16, 0)),
        .compression_method = .deflate,
        .dos_time = 0,
        .dos_date = 0,
        .crc32 = 0x1234_5678,
        .compressed_size = compressed,
        .uncompressed_size = uncompressed,
        .local_header_offset = offset,
        .external_attributes = 0,
        .version_needed = 45,
        .mtime = 1793013477,
        .zip64_local = zip64_local,
    };
}

test "writer: zip64Extra holds both sizes locally and only the overflowing values centrally" {
    const testing = std.testing;
    var buf: [zip64_extra_max_len]u8 = undefined;
    const big = 0x1_0000_0002; // 4 GiB + 2

    // Local: both sizes, uncompressed first, never the offset, even when it overflows.
    try testing.expectEqualSlices(u8, &.{
        0x01, 0x00, 16, 0x00,
        7,    0,    0,  0,
        0,    0,    0,  0,
        5,    0,    0,  0,
        0,    0,    0,  0,
    }, testRecord(7, 5, big, true).zip64Extra(.local, &buf));
    try testing.expectEqual(0, testRecord(big, big, big, false).zip64Extra(.local, &buf).len);

    // Central, nothing overflows: no extra, even when the local header has one.
    try testing.expectEqual(0, testRecord(7, 5, 0xFFFF_FFFE, true).zip64Extra(.central, &buf).len);

    // Only the uncompressed size.
    try testing.expectEqualSlices(u8, &.{
        0x01, 0x00, 8, 0x00,
        2,    0,    0, 0,
        1,    0,    0, 0,
    }, testRecord(big, 5, 0, false).zip64Extra(.central, &buf));

    // Only the offset. The sentinel value itself counts as overflowing.
    try testing.expectEqualSlices(u8, &.{
        0x01, 0x00, 8,    0x00,
        0xFF, 0xFF, 0xFF, 0xFF,
        0,    0,    0,    0,
    }, testRecord(7, 5, 0xFFFF_FFFF, false).zip64Extra(.central, &buf));

    // All three, in the APPNOTE 4.5.3 order: uncompressed, compressed, offset.
    try testing.expectEqualSlices(u8, &.{
        0x01, 0x00, 24, 0x00,
        2,    0,    0,  0,
        1,    0,    0,  0,
        3,    0,    0,  0,
        1,    0,    0,  0,
        4,    0,    0,  0,
        1,    0,    0,  0,
    }, testRecord(big, big + 1, big + 2, false).zip64Extra(.central, &buf));
}

test "writer: headers write 0xFFFFFFFF where the ZIP64 extra holds the value" {
    const testing = std.testing;
    const big = 5 << 30;

    // Uncompressed size and offset overflow, the compressed size doesn't.
    const r = testRecord(big, 3, big + 1, true);

    const c = r.centralHeader();
    try testing.expectEqual(0xFFFF_FFFF, c.uncompressed_size);
    try testing.expectEqual(3, c.compressed_size);
    try testing.expectEqual(0xFFFF_FFFF, c.local_file_header_relative_offset);
    try testing.expectEqual(45, c.version_needed_to_extract);
    try testing.expectEqual(timestamp_extra_len + 4 + 16, c.extra_len);

    var central: [64]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&central);
    try r.writeExtra(&cw, .central);
    try testing.expectEqual(c.extra_len, cw.end);
    try testing.expectEqualSlices(u8, &timestampExtra(r.mtime).?, central[0..9]);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 16, 0x00 }, central[9..13]);
    try testing.expectEqual(big, std.mem.readInt(u64, central[13..21], .little));
    try testing.expectEqual(big + 1, std.mem.readInt(u64, central[21..29], .little));

    // Local: both size fields are sentinels and the extra has both sizes.
    const l = r.localHeader();
    try testing.expectEqual(0xFFFF_FFFF, l.uncompressed_size);
    try testing.expectEqual(0xFFFF_FFFF, l.compressed_size);
    try testing.expectEqual(timestamp_extra_len + 4 + 16, l.extra_len);

    var local: [64]u8 = undefined;
    var lw: std.Io.Writer = .fixed(&local);
    try r.writeExtra(&lw, .local);
    try testing.expectEqual(l.extra_len, lw.end);
    try testing.expectEqual(big, std.mem.readInt(u64, local[13..21], .little));
    try testing.expectEqual(3, std.mem.readInt(u64, local[21..29], .little));

    // Nothing overflows and no local ZIP64: plain 32-bit fields, just the UT extra.
    const small = testRecord(7, 5, 100, false);
    try testing.expectEqual(7, small.centralHeader().uncompressed_size);
    try testing.expectEqual(100, small.centralHeader().local_file_header_relative_offset);
    try testing.expectEqual(timestamp_extra_len, small.centralHeader().extra_len);
    try testing.expectEqual(5, small.localHeader().compressed_size);
    try testing.expectEqual(timestamp_extra_len, small.localHeader().extra_len);
}

/// Per-entry options for `addBytes`.
pub const EntryOptions = struct {
    /// Asked-for method. Deflate falls back to stored when it doesn't make the data smaller.
    method: format.CompressionMethod = .deflate,
    /// Deflate level, ignored for stored.
    level: flate.Compress.Options = .default,
    /// Modification time in Unix seconds (UTC). Stored as is in the 0x5455 extended timestamp
    /// field (Info-ZIP, APPNOTE 4.5), which readers that understand it prefer. The DOS time
    /// fields get the same seconds for old tools, at 2-second steps and with no time zone.
    /// Outside the i32 range (before 1901, after 2038) only the DOS time is written.
    mtime: i64 = 0,
    /// Permission bits only (e.g. 0o644). The file type is set by the add* function.
    mode: u32 = 0o644,
};

/// Sets up the writer in place over `out`. Allocates the compressor and its window up front,
/// so it fails only with `error.OutOfMemory`. Call `deinit` when done, even after `finish`.
pub fn init(self: *Writer, gpa: std.mem.Allocator, out: *std.Io.Writer) !void {
    self.* = undefined;
    self.gpa = gpa;
    self.buf = undefined;
    self.counter = CountingWriter.init(out, &self.buf);
    self.cd_records = .empty;
    self.finished = false;
    self.poisoned = false;

    self.compress = try gpa.create(flate.Compress);
    errdefer gpa.destroy(self.compress);

    self.window = try gpa.alloc(u8, flate.max_window_len);
}

/// Frees the records, their names, the compressor and the window. Doesn't touch `out`.
pub fn deinit(self: *Writer) void {
    for (self.cd_records.items) |item| self.gpa.free(item.name);
    self.cd_records.deinit(self.gpa);
    self.gpa.free(self.window);
    self.gpa.destroy(self.compress);
}

/// Writes one entry whose data is fully in memory. The name is copied, `data` isn't kept
/// after the call returns.
///
/// Sizes or an offset of 0xFFFFFFFF or more get the ZIP64 extra (APPNOTE 4.5.3), so there is
/// no per-entry size limit, only the memory `data` takes.
///
/// Errors:
/// - `error.WriterFinished` after `finish`.
/// - `error.WriterFailed` after an earlier add call failed partway.
/// - `error.InvalidName`, see `validateName`.
/// - Whatever the underlying writer or the allocator returns.
pub fn addBytes(
    self: *Writer,
    name: []const u8,
    data: []const u8,
    opts: EntryOptions,
) !void {
    return self.addEntry(name, data, format.unix_mode.regular, opts);
}

fn addEntry(self: *Writer, name: []const u8, data: []const u8, file_type: u32, opts: EntryOptions) !void {
    if (self.poisoned) return error.WriterFailed;
    if (self.finished) return error.WriterFinished;

    const utf8 = try validateName(self.gpa, name);
    // A trailing '/' means "directory" to every extractor, so only addDirectory may use it.
    if (file_type != format.unix_mode.directory and name[name.len - 1] == '/') return error.InvalidName;
    const crc = std.hash.Crc32.hash(data);

    // Compressed bytes must outlive the write below, so the Allocating lives here.
    // Starts with real capacity because Compress.init asserts the output has at least 8 bytes.
    var aw: std.Io.Writer.Allocating = try .initCapacity(self.gpa, @max(64, data.len / 2));
    defer aw.deinit();

    var compression_method = opts.method;
    var payload = data;
    if (compression_method == .deflate) {
        // Fresh state for every entry: `finish` leaves the compressor's writer failing,
        // so it can't be reused as is.
        self.compress.* = try .init(&aw.writer, self.window, .raw, opts.level);
        try self.compress.writer.writeAll(data);
        try self.compress.finish();
        // Store when deflate doesn't help, like Info-ZIP. Also covers empty data.
        if (aw.written().len < data.len) payload = aw.written() else compression_method = .stored;
    }

    var flags: format.GeneralPurposeFlags = @bitCast(@as(u16, 0));
    flags.language_encoding = utf8;
    const dos = time.encodeDosDateTime(opts.mtime);
    const offset = self.counter.position();

    // Sizes that don't fit go in the ZIP64 extra of both headers, an offset that doesn't fit
    // only in the central one (APPNOTE 4.5.3).
    const zip64_local = data.len >= 0xFFFF_FFFF or payload.len >= 0xFFFF_FFFF;
    const zip64 = zip64_local or offset >= 0xFFFF_FFFF;

    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);

    const is_dir = file_type == format.unix_mode.directory;
    const unix_mode: u32 = @as(u32, opts.mode & 0o7777) | file_type;

    const record: CdRecord = .{
        .name = owned,
        .flags = flags,
        .compression_method = compression_method,
        .dos_time = dos.time,
        .dos_date = dos.date,
        .crc32 = crc,
        .compressed_size = payload.len,
        .uncompressed_size = data.len,
        .local_header_offset = offset,
        // High 16 bits hold the Unix mode, read when made-by says Unix (APPNOTE 4.4.15).
        .external_attributes = (unix_mode << 16) | @as(u32, if (is_dir) 0x10 else 0),
        // Version needed to extract: 1.0 for stored, 2.0 for deflate and directories, 4.5 with
        // a ZIP64 extra in either header (APPNOTE 4.4.3).
        .version_needed = if (zip64) 45 else if (compression_method == .deflate or is_dir) 20 else 10,
        .mtime = opts.mtime,
        .zip64_local = zip64_local,
    };

    // From here on `out` may hold part of an entry.
    self.poisoned = true;

    const w = &self.counter.interface;
    try w.writeStruct(record.localHeader(), .little);
    try w.writeAll(name);
    try record.writeExtra(w, .local);
    try w.writeAll(payload);
    try self.cd_records.append(self.gpa, record);

    self.poisoned = false;
}

/// Rejects names that are unsafe, unrepresentable, or not already clean. Returns true when
/// the name has non-ASCII bytes, so the caller sets bit 11 (UTF-8, APPNOTE 4.4.4 and
/// appendix D).
///
/// A name is accepted when `path.sanitize` takes it and gives it back unchanged, and it is
/// at most 0xFFFF bytes. So the writer refuses what the reader would refuse, and also names
/// the reader would rewrite ("a//b", "./x", "a/./b"), since those would come back out
/// under a different name. Forward slashes only (APPNOTE 4.4.17). Windows rules stay off,
/// so the archive doesn't depend on which OS wrote it.
fn validateName(gpa: std.mem.Allocator, name: []const u8) error{ InvalidName, OutOfMemory }!bool {
    if (name.len == 0 or name.len > 0xFFFF) return error.InvalidName;
    const utf8 = for (name) |c| {
        if (c >= 0x80) break true;
    } else false;

    // Cleaning only drops bytes, so a buffer of name.len always fits the result.
    const buffer = try gpa.alloc(u8, name.len);
    defer gpa.free(buffer);
    const clean = path.sanitize(name, buffer, .{ .windows_rules = false, .utf8 = utf8 }) catch
        return error.InvalidName;
    if (!std.mem.eql(u8, clean, name)) return error.InvalidName;
    return utf8;
}

test "writer: validateName rejects unsafe names and flags UTF-8" {
    const testing = std.testing;
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidName, validateName(gpa, ""));
    try testing.expectError(error.InvalidName, validateName(gpa, &([_]u8{'a'} ** 0x10000)));
    try testing.expectError(error.InvalidName, validateName(gpa, "/etc/passwd"));
    try testing.expectError(error.InvalidName, validateName(gpa, "dir\\file.txt"));
    try testing.expectError(error.InvalidName, validateName(gpa, ".."));
    try testing.expectError(error.InvalidName, validateName(gpa, "../up.txt"));
    try testing.expectError(error.InvalidName, validateName(gpa, "a/../b.txt"));
    try testing.expectError(error.InvalidName, validateName(gpa, "a/.."));
    try testing.expectError(error.InvalidName, validateName(gpa, "bad\xff.txt"));
    // Names the reader would clean into something else.
    try testing.expectError(error.InvalidName, validateName(gpa, "a//b"));
    try testing.expectError(error.InvalidName, validateName(gpa, "./x"));
    try testing.expectError(error.InvalidName, validateName(gpa, "a/./b"));
    try testing.expectError(error.InvalidName, validateName(gpa, "dir//"));
    // Names the reader would refuse outright.
    try testing.expectError(error.InvalidName, validateName(gpa, "C:x"));
    try testing.expectError(error.InvalidName, validateName(gpa, "a\x00b"));
    try testing.expectError(error.InvalidName, validateName(gpa, "tab\tname"));

    try testing.expectEqual(false, try validateName(gpa, "hello.txt"));
    try testing.expectEqual(false, try validateName(gpa, "dir/"));
    try testing.expectEqual(false, try validateName(gpa, "a..b/..c"));
    try testing.expectEqual(false, try validateName(gpa, &([_]u8{'a'} ** 0xFFFF)));
    try testing.expectEqual(true, try validateName(gpa, "caf\xc3\xa9.txt"));
    // Windows rules are off, so these are fine to write.
    try testing.expectEqual(false, try validateName(gpa, "con.txt"));
    try testing.expectEqual(false, try validateName(gpa, "ab:c/d"));
}

test "writer: validateTarget rejects unsafe targets" {
    const testing = std.testing;
    // Always invalid, even when unsafe targets are allowed.
    for ([_]bool{ false, true }) |allow| {
        try testing.expectError(error.InvalidSymlinkTarget, validateTarget("", allow));
        try testing.expectError(error.InvalidSymlinkTarget, validateTarget("a\x00b", allow));
    }

    const unsafe = [_][]const u8{ "/etc/passwd", "\\server\\x", "C:", "C:foo", "C:\\x", "..", "../x", "a/../../x", "a\\..\\x" };
    for (unsafe) |target| {
        try testing.expectError(error.UnsafeSymlinkTarget, validateTarget(target, false));
        try validateTarget(target, true);
    }

    for ([_][]const u8{ "target.txt", "lib/libz.so", "a..b/..c", "./x" }) |target| {
        try validateTarget(target, false);
    }
}

/// Writes the central directory and the end record (APPNOTE 4.3.12, 4.3.16), then flushes
/// both our buffer and the underlying writer. Call it once; a second call returns
/// `error.WriterFinished`. For 0xFFFF or more entries, or a central directory whose size or
/// offset is 0xFFFFFFFF or more, the ZIP64 end record and its locator (APPNOTE 4.3.14,
/// 4.3.15) go before the classic end record, which then holds 0xFFFF or 0xFFFFFFFF in each
/// field that doesn't fit.
pub fn finish(self: *Writer) !void {
    // Poisoned first: a finish that failed partway sets both, and the archive is broken.
    if (self.poisoned) return error.WriterFailed;
    if (self.finished) return error.WriterFinished;

    const record_count = self.cd_records.items.len;

    const cd_offset = self.counter.position();

    self.finished = true;
    errdefer self.poisoned = true;
    const w = &self.counter.interface;
    for (self.cd_records.items) |*record| {
        try w.writeStruct(record.centralHeader(), .little);
        try w.writeAll(record.name);
        try record.writeExtra(w, .central);
    }

    const cd_size = self.counter.position() - cd_offset;

    if (cd_size >= 0xFFFF_FFFF or record_count >= 0xFFFF or cd_offset >= 0xFFFF_FFFF) {
        const eocd64_offset = self.counter.position();
        try w.writeStruct(records.EndRecord64.header64{
            .signature = records.EndRecord64.signature_marker,
            .record_size = records.EndRecord64.size,
        }, .little);
        try w.writeStruct(records.EndRecord64{
            .version_made_by = .{ .spec_version = 63, .os = .unix },
            .version_needed_to_extract = 45,
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = record_count,
            .record_count_total = record_count,
            .central_directory_size = cd_size,
            .central_directory_offset = cd_offset,
        }, .little);
        try w.writeStruct(records.EndRecord64Locator{
            .signature = records.EndRecord64Locator.signature_marker,
            .central_directory_disk = 0,
            .central_directory_offset = eocd64_offset,
            .total_disks = 1,
        }, .little);
    }

    const count: u16 = @min(record_count, 0xFFFF);
    const eocd = records.EndRecord{
        .signature = records.EndRecord.signature_marker,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = count,
        .record_count_total = count,
        .central_directory_size = @intCast(@min(cd_size, 0xFFFF_FFFF)),
        .central_directory_offset = @intCast(@min(cd_offset, 0xFFFF_FFFF)),
        .comment_len = 0,
    };

    try w.writeStruct(eocd, .little);
    try w.flush();
    try self.counter.out.flush();
}

/// Per-entry options for `addDirectory`. A directory has no data, so there is no method or level.
pub const DirectoryOptions = struct {
    /// Modification time in seconds since 1970, written the same way as `EntryOptions.mtime`.
    mtime: i64 = 0,
    /// Permission bits only (e.g. 0o755). The directory type is set by `addDirectory`.
    mode: u32 = 0o755,
};

/// Adds a directory entry. A trailing '/' is added if missing.
/// Stored, no data, version needed 2.0 (APPNOTE 4.4.3.2).
pub fn addDirectory(self: *Writer, name: []const u8, opts: DirectoryOptions) !void {
    // Only append the slash when it's missing, so "src/" doesn't become "src//".
    const has_slash = name.len > 0 and name[name.len - 1] == '/';
    const dir_name = if (has_slash) name else try std.mem.concat(self.gpa, u8, &.{ name, "/" });
    defer if (!has_slash) self.gpa.free(dir_name);

    const entry_opts: EntryOptions = .{ .method = .stored, .mode = opts.mode, .mtime = opts.mtime };
    try self.addEntry(dir_name, "", format.unix_mode.directory, entry_opts);
}

/// Rejects empty targets and targets containing NUL. Unless `allow_unsafe` is set,
/// also rejects absolute, drive-letter and ".." targets, which an extractor
/// following the link could use to escape the output directory.
fn validateTarget(target: []const u8, allow_unsafe: bool) error{ InvalidSymlinkTarget, UnsafeSymlinkTarget }!void {
    if (target.len == 0) return error.InvalidSymlinkTarget;
    if (std.mem.findScalar(u8, target, 0) != null) return error.InvalidSymlinkTarget;
    if (allow_unsafe) return;
    // Treat backslashes as separators too, for archives extracted on Windows.
    if (target[0] == '/' or target[0] == '\\') return error.UnsafeSymlinkTarget;

    // "C:", "C:foo" and "C:\foo" all leave the current directory on Windows.
    const has_drive = target.len >= 2 and std.ascii.isAlphabetic(target[0]) and target[1] == ':';
    if (has_drive) return error.UnsafeSymlinkTarget;

    var it = std.mem.tokenizeAny(u8, target, "/\\");
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return error.UnsafeSymlinkTarget;
    }
}

/// Per-entry options for `addSymlink`. The data is the target, so there is no method or level.
pub const SymlinkOptions = struct {
    /// Modification time in seconds since 1970, written the same way as `EntryOptions.mtime`.
    mtime: i64 = 0,
    /// Permission bits only (e.g. 0o777, what `ln -s` gives). The symlink type is set by `addSymlink`.
    mode: u32 = 0o777,
    /// Skips the absolute, drive-letter and ".." target checks. Only for trusted trees, like backups.
    allow_unsafe_target: bool = false,
};

/// Adds a symlink entry, Info-ZIP style: the data is the target path,
/// stored, with `format.unix_mode.symlink` in the high bits of the external attributes.
pub fn addSymlink(self: *Writer, name: []const u8, target: []const u8, opts: SymlinkOptions) !void {
    try validateTarget(target, opts.allow_unsafe_target);
    try self.addEntry(name, target, format.unix_mode.symlink, .{ .method = .stored, .mtime = opts.mtime, .mode = opts.mode });
}

/// Options for `addStream`. Streamed entries are always deflated, because a stored entry
/// with a data descriptor has no end marker that streaming readers can find.
pub const StreamOptions = struct {
    /// Deflate level.
    level: flate.Compress.Options = .default,
    /// Permission bits only (e.g. 0o644). The type is always a regular file.
    mode: u32 = 0o644,
    /// Modification time in seconds since 1970, written the same way as `EntryOptions.mtime`.
    mtime: i64 = 0,
    /// Set this when the stream may reach 4 GiB (0xFFFFFFFF bytes) before or after deflate.
    /// The local header goes out before any data, so its format has to be chosen up front.
    /// - true: the local header has 0xFFFFFFFF sizes and a ZIP64 extra holding two zero
    ///   sizes, version needed is 4.5, and the data descriptor has 8-byte sizes, 24 bytes in
    ///   all (APPNOTE 4.3.9.2, 4.5.3). Readers pick the descriptor width from that extra.
    ///   Costs 28 bytes per entry, and readers without ZIP64 support can't open the entry.
    /// - false: 32-bit sizes and a 16-byte descriptor. If the entry turns out to need ZIP64
    ///   anyway, `addStream` returns `error.Zip64Required` after streaming all of it, and
    ///   the writer is poisoned, because the local header already in `out` can't be fixed.
    zip64: bool = false,
};

/// Adds a regular file whose size isn't known up front, deflating `reader` until it ends.
/// Sets bit 3, so the local header has zero CRC and sizes, and a data descriptor with the
/// real values follows the data (APPNOTE 4.3.9). Once the header is written, any failure
/// poisons the writer, because `out` then holds a partial entry. See `StreamOptions.zip64`
/// for entries of 4 GiB or more. An offset past 4 GiB needs nothing, the central directory's
/// ZIP64 extra carries it (APPNOTE 4.5.3).
///
/// Errors:
/// - `error.WriterFinished` after `finish`.
/// - `error.WriterFailed` after an earlier add call failed partway.
/// - `error.InvalidName`, see `validateName`. Names ending in '/' are rejected too.
/// - `error.Zip64Required` when `opts.zip64` is false and the data or compressed data turned
///   out to be 0xFFFFFFFF bytes or more. The writer is poisoned then.
/// - Whatever the reader, the underlying writer or the allocator returns.
pub fn addStream(self: *Writer, name: []const u8, reader: *std.Io.Reader, opts: StreamOptions) !void {
    if (self.poisoned) return error.WriterFailed;
    if (self.finished) return error.WriterFinished;

    const utf8 = try validateName(self.gpa, name);
    if (name[name.len - 1] == '/') return error.InvalidName;

    const offset = self.counter.position();

    var flags: format.GeneralPurposeFlags = @bitCast(@as(u16, 0));
    flags.language_encoding = utf8;
    flags.data_descriptor = true;
    const dos = time.encodeDosDateTime(opts.mtime);

    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);

    var record: CdRecord = .{
        .name = owned,
        .flags = flags,
        .compression_method = .deflate,
        .dos_date = dos.date,
        .dos_time = dos.time,
        // Zero with bit 3 set, in the local header or its ZIP64 extra. The real values go in
        // after streaming.
        .crc32 = 0,
        .compressed_size = 0,
        .uncompressed_size = 0,
        .local_header_offset = offset,
        .external_attributes = ((opts.mode & 0o7777) | format.unix_mode.regular) << 16,
        // 4.5 with a ZIP64 extra in either header: the local one from `opts.zip64`, or the
        // central one for an offset that doesn't fit (APPNOTE 4.4.3).
        .version_needed = if (opts.zip64 or offset >= 0xFFFF_FFFF) 45 else 20,
        .mtime = opts.mtime,
        .zip64_local = opts.zip64,
    };

    // From here on `out` may hold part of an entry.
    self.poisoned = true;

    const w = &self.counter.interface;
    try w.writeStruct(record.localHeader(), .little);
    try w.writeAll(name);
    try record.writeExtra(w, .local);

    const data_start = self.counter.position();

    // Fresh state for every entry: `finish` leaves the compressor's writer failing.
    self.compress.* = try .init(w, self.window, .raw, opts.level);

    var hash_buf: [4 << 10]u8 = undefined;
    var hashing: HashingWriter = .init(&self.compress.writer, &hash_buf);
    _ = try reader.streamRemaining(&hashing.interface);
    try hashing.interface.flush();
    try self.compress.finish();

    record.crc32 = hashing.final();
    record.uncompressed_size = hashing.count;
    record.compressed_size = self.counter.position() - data_start;
    const overflow = record.compressed_size >= 0xFFFF_FFFF or record.uncompressed_size >= 0xFFFF_FFFF;
    if (overflow and !opts.zip64) return error.Zip64Required;

    // Data descriptor with the commonly used signature (APPNOTE 4.3.9.3). Sizes are 8 bytes
    // exactly when the local header has the ZIP64 extra (APPNOTE 4.3.9.2).
    try w.writeInt(u32, records.DataDescriptor.signature_marker, .little);
    try w.writeInt(u32, record.crc32, .little);
    if (opts.zip64) {
        try w.writeInt(u64, record.compressed_size, .little);
        try w.writeInt(u64, record.uncompressed_size, .little);
    } else {
        try w.writeInt(u32, @intCast(record.compressed_size), .little);
        try w.writeInt(u32, @intCast(record.uncompressed_size), .little);
    }

    try self.cd_records.append(self.gpa, record);
    self.poisoned = false;
}
