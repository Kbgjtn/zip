//! ZIP archive writer.
//!
//! Entries go out one after another as local header, name and data (APPNOTE 4.3.6). The
//! writer keeps a small record per entry, and `finish` writes the central directory and
//! the end record from them.
//!
//! Current limits:
//! - No ZIP64 yet (M9). Anything that needs it returns `error.Zip64Required`.
//! - Data descriptors (bit 3) only for `addStream`, where the size isn't known up front.
//!   `addBytes`, `addDirectory` and `addSymlink` know sizes and CRC first, so bit 3 stays off.
//! - The only extra field is the 0x5455 extended timestamp, mtime only (see `timestampExtra`).
//!
//! Initialise it in place with `init` and never copy it. `counter.interface` points at
//! `self.buf`, and `CountingWriter` finds itself through `@fieldParentPtr`, so a copy
//! would write through a stale pointer.

const std = @import("std");

const flate = std.compress.flate;
const format = @import("format.zig");
const time = @import("time.zig");
const CountingWriter = @import("counting_writer.zig");
const HashingWriter = @import("hashing_writer.zig");

const records_mod = @import("records/root.zig");
const LocalFileHeader = records_mod.LocalFileHeader;
const CentralDirectoryFileHeader = records_mod.CentralDirectoryFileHeader;
const EndOfCentralDirectoryRecord = records_mod.EndOfCentralDirectoryRecord;

const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;

const Writer = @This();

/// Allocator for the compressor, the window, the records and their names.
gpa: std.mem.Allocator,
/// Wraps the caller's writer and tracks the byte offset, which the central directory needs.
counter: CountingWriter,
/// Buffer behind `counter.interface`. Lives here, which is why the Writer can't be copied.
buf: [8 << 10]u8,
/// One record per entry written so far, turned into central directory headers by `finish`.
records: std.ArrayList(CdRecord),
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
/// (APPNOTE 4.3.12). Sizes and offset are u64 so ZIP64 can use the same record later.
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
    /// 10 for stored, 20 for deflate (APPNOTE 4.4.3).
    version_needed: u16,
    /// Modification time in Unix seconds, for the 0x5455 extra field in both headers.
    mtime: i64,

    /// Local file header for this entry (APPNOTE 4.3.7). The caller must have checked that
    /// sizes fit in u32.
    fn localHeader(r: *const CdRecord) LocalFileHeader {
        return .{
            .signature = 0x0403_4B50,
            .version_needed_to_extract = r.version_needed,
            .flags = r.flags,
            .compression_method = r.compression_method,
            .last_modification_time = r.dos_time,
            .last_modification_date = r.dos_date,
            .crc32 = r.crc32,
            .compressed_size = @intCast(r.compressed_size),
            .uncompressed_size = @intCast(r.uncompressed_size),
            .filename_len = @intCast(r.name.len),
            .extra_len = r.extraLen(),
        };
    }

    /// Central directory header for this entry (APPNOTE 4.3.12). The caller must have checked
    /// that sizes and offset fit in u32.
    fn centralHeader(r: *const CdRecord) CentralDirectoryFileHeader {
        return .{
            .signature = 0x0201_4B50,
            // Made by Unix (3) with spec 6.3 (63), i.e. (3 << 8) | 63, so readers trust the
            // mode in external attributes (APPNOTE 4.4.2).
            .version_made_by = .{ .spec_version = 63, .os = .unix },
            .version_needed_to_extract = r.version_needed,
            .flags = r.flags,
            .compression_method = r.compression_method,
            .last_modification_time = r.dos_time,
            .last_modification_date = r.dos_date,
            .crc32 = r.crc32,
            .compressed_size = @intCast(r.compressed_size),
            .uncompressed_size = @intCast(r.uncompressed_size),
            .filename_len = @intCast(r.name.len),
            .extra_len = r.extraLen(),
            .comment_len = 0,
            .disk_number_start = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = r.external_attributes,
            .local_file_header_relative_offset = @intCast(r.local_header_offset),
        };
    }

    /// Bytes of extra field after the name, the same in both headers.
    fn extraLen(r: *const CdRecord) u16 {
        return if (timestampExtra(r.mtime) != null) timestamp_extra_len else 0;
    }

    /// Writes the extra field that `extraLen` counts, if any.
    fn writeExtra(r: *const CdRecord, w: *std.Io.Writer) !void {
        if (timestampExtra(r.mtime)) |bytes| try w.writeAll(&bytes);
    }
};

const timestamp_extra_len = 9;

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
    self.records = .empty;
    self.finished = false;

    self.compress = try gpa.create(flate.Compress);
    errdefer gpa.destroy(self.compress);

    self.window = try gpa.alloc(u8, flate.max_window_len);
}

/// Frees the records, their names, the compressor and the window. Doesn't touch `out`.
pub fn deinit(self: *Writer) void {
    for (self.records.items) |item| self.gpa.free(item.name);
    self.records.deinit(self.gpa);
    self.gpa.free(self.window);
    self.gpa.destroy(self.compress);
}

/// Writes one entry whose data is fully in memory. The name is copied, `data` isn't kept
/// after the call returns.
///
/// Errors:
/// - `error.WriterFinished` after `finish`.
/// - `error.InvalidName`, see `validateName`.
/// - `error.Zip64Required` when the data, compressed data or offset needs 4 GiB or more.
/// - Whatever the underlying writer or the allocator returns.
pub fn addBytes(
    self: *Writer,
    name: []const u8,
    data: []const u8,
    opts: EntryOptions,
) !void {
    return self.addEntry(name, data, S_IFREG, opts);
}

fn addEntry(self: *Writer, name: []const u8, data: []const u8, file_type: u32, opts: EntryOptions) !void {
    if (self.finished) return error.WriterFinished;
    if (self.poisoned) return error.WriterFailed;

    const utf8 = try validateName(name);
    // A trailing '/' means "directory" to every extractor, so only addDirectory may use it.
    if (file_type != S_IFDIR and name[name.len - 1] == '/') return error.InvalidName;
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

    if (data.len >= 0xFFFF_FFFF or payload.len >= 0xFFFF_FFFF) return error.Zip64Required;

    var flags: format.GeneralPurposeFlags = @bitCast(@as(u16, 0));
    flags.language_encoding = utf8;
    const dos = time.encodeDosDateTime(opts.mtime);
    const offset = self.counter.position();

    if (offset >= 0xFFFF_FFFF) return error.Zip64Required;

    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);

    const is_dir = file_type == S_IFDIR;
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
        // Version needed to extract: 1.0 for stored, 2.0 for deflate (APPNOTE 4.4.3).
        .version_needed = if (compression_method == .deflate or is_dir) 20 else 10,
        .mtime = opts.mtime,
    };

    const w = &self.counter.interface;
    try w.writeStruct(record.localHeader(), .little);
    try w.writeAll(name);
    try record.writeExtra(w);
    try w.writeAll(payload);
    try self.records.append(self.gpa, record);
}

/// Rejects names that are unsafe or unrepresentable. Returns true when the name has
/// non-ASCII bytes, so the caller sets bit 11 (UTF-8, APPNOTE 4.4.4 and appendix D).
///
/// Rules: not empty, at most 0xFFFF bytes, no leading '/', no '\', no ".." segment,
/// and valid UTF-8 when it isn't plain ASCII. Forward slashes only (APPNOTE 4.4.17).
fn validateName(name: []const u8) error{InvalidName}!bool {
    if (name.len == 0 or name.len > 0xFFFF) return error.InvalidName;
    if (name[0] == '/') return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidName;

    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.InvalidName;
    }

    for (name) |c| {
        if (c >= 0x80) {
            if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
            return true;
        }
    }
    return false;
}

test "writer: validateName rejects unsafe names and flags UTF-8" {
    const testing = std.testing;
    try testing.expectError(error.InvalidName, validateName(""));
    try testing.expectError(error.InvalidName, validateName(&([_]u8{'a'} ** 0x10000)));
    try testing.expectError(error.InvalidName, validateName("/etc/passwd"));
    try testing.expectError(error.InvalidName, validateName("dir\\file.txt"));
    try testing.expectError(error.InvalidName, validateName(".."));
    try testing.expectError(error.InvalidName, validateName("../up.txt"));
    try testing.expectError(error.InvalidName, validateName("a/../b.txt"));
    try testing.expectError(error.InvalidName, validateName("a/.."));
    try testing.expectError(error.InvalidName, validateName("bad\xff.txt"));

    try testing.expectEqual(false, try validateName("hello.txt"));
    try testing.expectEqual(false, try validateName("dir/"));
    try testing.expectEqual(false, try validateName("a..b/..c"));
    try testing.expectEqual(false, try validateName(&([_]u8{'a'} ** 0xFFFF)));
    try testing.expectEqual(true, try validateName("caf\xc3\xa9.txt"));
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
/// `error.WriterFinished`. Returns `error.Zip64Required` for 0xFFFF or more entries, or
/// when the central directory itself needs ZIP64.
pub fn finish(self: *Writer) !void {
    if (self.finished) return error.WriterFinished;
    if (self.poisoned) return error.WriterFailed;

    const record_count = self.records.items.len;
    if (record_count >= 0xFFFF) return error.Zip64Required;

    const cd_offset = self.counter.position();
    for (self.records.items) |*record| {
        if (record.compressed_size > 0xFFFF_FFFF or record.uncompressed_size > 0xFFFF_FFFF or
            record.local_header_offset > 0xFFFF_FFFF or record.name.len > 0xFFFF)
        {
            return error.Zip64Required;
        }
    }

    self.finished = true;
    const w = &self.counter.interface;
    for (self.records.items) |*record| {
        try w.writeStruct(record.centralHeader(), .little);
        try w.writeAll(record.name);
        try record.writeExtra(w);
    }

    const cd_size = self.counter.position() - cd_offset;
    if (cd_size > 0xFFFF_FFFF) return error.Zip64Required;

    const count: u16 = @intCast(record_count);
    const eocd = EndOfCentralDirectoryRecord{
        .signature = 0x0605_4B50,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = count,
        .record_count_total = count,
        .central_directory_size = @intCast(cd_size),
        .central_directory_offset = @intCast(cd_offset),
        .comment_len = 0,
    };

    try self.counter.interface.writeStruct(eocd, .little);
    try self.counter.interface.flush();
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

    try self.addEntry(
        dir_name,
        "",
        S_IFDIR,
        .{ .method = .stored, .mode = opts.mode, .mtime = opts.mtime },
    );
}

/// Rejects empty targets and targets containing NUL. Unless `allow_unsafe` is set,
/// also rejects absolute, drive-letter and ".." targets, which an extractor
/// following the link could use to escape the output directory.
fn validateTarget(target: []const u8, allow_unsafe: bool) error{ InvalidSymlinkTarget, UnsafeSymlinkTarget }!void {
    if (target.len == 0) return error.InvalidSymlinkTarget;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return error.InvalidSymlinkTarget;
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
/// stored, with S_IFLNK in the high bits of the external attributes.
pub fn addSymlink(self: *Writer, name: []const u8, target: []const u8, opts: SymlinkOptions) !void {
    try validateTarget(target, opts.allow_unsafe_target);
    try self.addEntry(name, target, S_IFLNK, .{ .method = .stored, .mtime = opts.mtime, .mode = opts.mode });
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
};

/// Adds a regular file whose size isn't known up front, deflating `reader` until it ends.
/// Sets bit 3, so the local header has zero CRC and sizes, and a data descriptor with the
/// real values follows the data (APPNOTE 4.3.9). Once the header is written, any failure
/// poisons the writer, because `out` then holds a partial entry.
///
/// Errors:
/// - `error.WriterFinished` after `finish`.
/// - `error.WriterFailed` after an earlier add call failed partway.
/// - `error.InvalidName`, see `validateName`. Names ending in '/' are rejected too.
/// - `error.Zip64Required` when the offset, data or compressed data needs 4 GiB or more.
/// - Whatever the reader, the underlying writer or the allocator returns.
pub fn addStream(self: *Writer, name: []const u8, reader: *std.Io.Reader, opts: StreamOptions) !void {
    if (self.finished) return error.WriterFinished;
    if (self.poisoned) return error.WriterFailed;

    const utf8 = try validateName(name);
    if (name[name.len - 1] == '/') return error.InvalidName;

    const offset = self.counter.position();
    if (offset >= 0xFFFF_FFFF) return error.Zip64Required;

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
        // Zero in the local header with bit 3 set. The real values go in after streaming.
        .crc32 = 0,
        .compressed_size = 0,
        .uncompressed_size = 0,
        .local_header_offset = offset,
        .external_attributes = ((opts.mode & 0o7777) | S_IFREG) << 16,
        .version_needed = 20,
        .mtime = opts.mtime,
    };

    // From here on `out` may hold part of an entry.
    self.poisoned = true;

    const w = &self.counter.interface;
    try w.writeStruct(record.localHeader(), .little);
    try w.writeAll(name);
    try record.writeExtra(w);

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
    if (record.compressed_size >= 0xFFFF_FFFF or record.uncompressed_size >= 0xFFFF_FFFF) {
        return error.Zip64Required;
    }

    // Data descriptor with the commonly used signature (APPNOTE 4.3.9.3).
    try w.writeInt(u32, 0x08074b50, .little);
    try w.writeInt(u32, record.crc32, .little);
    try w.writeInt(u32, @intCast(record.compressed_size), .little);
    try w.writeInt(u32, @intCast(record.uncompressed_size), .little);

    try self.records.append(self.gpa, record);
    self.poisoned = false;
}
