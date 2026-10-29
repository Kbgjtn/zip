//! Writer round-trip tests: write an archive with our Writer, read it back with our Archive.

const std = @import("std");
const Writer = @import("../writer.zig");
const Archive = @import("../Archive.zig");
const CompressionMethod = @import("../format.zig").CompressionMethod;
const HeaderId = @import("../format.zig").HeaderId;
const records = @import("../records/root.zig");
const extra = @import("../extra.zig");
const build_options = @import("build_options");

const io = std.testing.io;
const gpa = std.testing.allocator;

test "writer: addBytes round-trips through the Archive (empty, stored, deflate, UTF-8 name, mtime)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // ~64 KiB of a repeated line, so deflate wins by a lot.
    const repeat = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(repeat);
    const line = "the quick brown fox jumps over the lazy dog\n";
    for (repeat, 0..) |*c, i| c.* = line[i % line.len];

    const Entry = struct {
        name: []const u8,
        data: []const u8,
        opts: Writer.EntryOptions,
        method: CompressionMethod, // what should land on disk
        utf8: bool,
    };
    const entries = [_]Entry{
        // Empty data: deflate isn't smaller, so it falls back to stored.
        .{ .name = "empty.txt", .data = "", .opts = .{}, .method = .stored, .utf8 = false },
        .{ .name = "hello.txt", .data = "hello\n", .opts = .{ .method = .stored, .mtime = 1700000001 }, .method = .stored, .utf8 = false },
        // Odd second: DOS time can't hold it, the 0x5455 field must.
        .{ .name = "dir/repeat.txt", .data = repeat, .opts = .{ .mtime = 1793013477 }, .method = .deflate, .utf8 = false },
        // Past i32: no 0x5455 field, DOS time only.
        .{ .name = "café.txt", .data = "bonjour\n", .opts = .{ .mode = 0o600, .mtime = std.math.maxInt(i32) + 1 }, .method = .stored, .utf8 = true },
    };

    {
        var file = try tmp.dir.createFile(io, "out.zip", .{});
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &file_buf);

        var zw: Writer = undefined;
        try zw.init(gpa, &fw.interface);
        defer zw.deinit();
        for (entries) |e| try zw.addBytes(e.name, e.data, e.opts);
        try zw.finish();
        try std.testing.expectError(error.WriterFinished, zw.addBytes("late.txt", "x", .{}));
    }

    var file = try tmp.dir.openFile(io, "out.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= entries.len) return error.TestTooManyEntries;
        const want = entries[count];

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(want.name, try fd.fileName(&iter.source, &name_buf));
        try std.testing.expectEqual(want.method, fd.compression());
        const lfh = try records.LocalHeader.read(&iter.source, fd.local_header_offset);
        try std.testing.expectEqual(want.utf8, lfh.flags.language_encoding);
        try std.testing.expectEqual(want.utf8, fd.flags.language_encoding);
        try std.testing.expectEqual(false, fd.flags.data_descriptor);
        try std.testing.expectEqual(std.hash.Crc32.hash(want.data), fd.crc32Checksum());
        try std.testing.expectEqual(@as(u64, want.data.len), fd.uncompressed_size);
        if (want.method == .deflate) try std.testing.expect(fd.compressed_size < want.data.len);

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const n = try iter.streamEntry(&fd, &out.writer);
        try std.testing.expectEqual(want.data.len, n);
        try std.testing.expectEqualSlices(u8, want.data, out.written());

        // 0x5455 in the local header: mtime read back exactly, or no extra at all past i32.
        const want_mtime = std.math.cast(i32, want.opts.mtime);
        if (want_mtime == null) {
            try std.testing.expectEqual(@as(u16, 0), lfh.extra_len);
            continue;
        }
        try std.testing.expectEqual(@as(u16, 9), lfh.extra_len);
        var extra_buf: [9]u8 = undefined;
        try reader.seekTo(fd.local_header_offset + records.LocalHeader.size + lfh.filename_len);
        try reader.interface.readSliceAll(&extra_buf);
        const it: extra.Iterator = .{ .buf = &extra_buf };
        const field = (try it.find(HeaderId.extended_timestamp)) orelse return error.TestMissingTimestamp;
        const ut = (try field.parse(.none)).?.extended_timestamp;
        try std.testing.expectEqual(want_mtime.?, ut.mod_time_unix.?);

        // The central header carries the same 9 bytes, so they appear exactly twice in the file.
        try reader.seekTo(0);
        const whole = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(whole);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, whole, &extra_buf));
    }
    try std.testing.expectEqual(entries.len, count);
}

test "writer: addBytes keeps only permission bits from opts.mode, the file type is always regular" {
    // A caller passing a directory mode must not turn a file entry into a directory.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("sneaky.txt", "not a dir\n", .{ .method = .stored, .mode = 0o040755 });
        try zw.finish();
    }

    const bytes = out.written();
    const cd = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    // External file attributes sit at offset 38 of the 46-byte central directory header.
    const attrs = std.mem.readInt(u32, bytes[cd + 38 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0o100755), attrs >> 16);
    try std.testing.expectEqual(@as(u32, 0), attrs & 0x10); // no MS-DOS directory bit
}

test "writer: addDirectory writes stored, empty entries with a trailing slash and directory attributes" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addDirectory("docs", .{ .mtime = 1793013477 }); // slash added
        try zw.addDirectory("src/", .{ .mode = 0o700 }); // slash kept, not doubled
        try zw.addBytes("src/main.zig", "pub fn main() void {}\n", .{ .method = .stored });
        try std.testing.expectError(error.InvalidName, zw.addDirectory("", .{}));
        try std.testing.expectError(error.InvalidName, zw.addDirectory("/abs", .{}));
        try std.testing.expectError(error.InvalidName, zw.addDirectory("../up", .{}));
        // A file name ending in '/' would be read as a directory by extractors.
        try std.testing.expectError(error.InvalidName, zw.addBytes("x/", "data", .{}));
        try zw.finish();
    }

    const Want = struct { name: []const u8, mode: u32, dir: bool };
    const want = [_]Want{
        .{ .name = "docs/", .mode = 0o040755, .dir = true },
        .{ .name = "src/", .mode = 0o040700, .dir = true },
        .{ .name = "src/main.zig", .mode = 0o100644, .dir = false },
    };

    // Walk the central directory headers straight from the bytes.
    const bytes = out.written();
    var pos = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    for (want) |w| {
        try std.testing.expectEqualSlices(u8, "PK\x01\x02", bytes[pos..][0..4]);
        const h = bytes[pos..][0..46];
        const method = std.mem.readInt(u16, h[10..12], .little);
        const crc = std.mem.readInt(u32, h[16..20], .little);
        const csize = std.mem.readInt(u32, h[20..24], .little);
        const usize_ = std.mem.readInt(u32, h[24..28], .little);
        const name_len = std.mem.readInt(u16, h[28..30], .little);
        const extra_len = std.mem.readInt(u16, h[30..32], .little);
        const comment_len = std.mem.readInt(u16, h[32..34], .little);
        const attrs = std.mem.readInt(u32, h[38..42], .little);
        const needed = std.mem.readInt(u16, h[6..8], .little);

        try std.testing.expectEqualStrings(w.name, bytes[pos + 46 ..][0..name_len]);
        try std.testing.expectEqual(w.mode, attrs >> 16);
        try std.testing.expectEqual(@as(u32, if (w.dir) 0x10 else 0), attrs & 0x10);
        try std.testing.expectEqual(@as(u16, 0), method); // stored
        if (w.dir) {
            try std.testing.expectEqual(@as(u16, 20), needed); // APPNOTE 4.4.3.2
            try std.testing.expectEqual(@as(u32, 0), crc);
            try std.testing.expectEqual(@as(u32, 0), csize);
            try std.testing.expectEqual(@as(u32, 0), usize_);
        }
        pos += 46 + name_len + extra_len + comment_len;
    }
    try std.testing.expectEqualSlices(u8, "PK\x05\x06", bytes[pos..][0..4]);
}

test "writer: addSymlink writes stored entries with the target as data and symlink attributes" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addSymlink("link", "lib/libz.so", .{ .mtime = 1793013477 }); // default mode 0o777
        try zw.addSymlink("exec_link", "lib/libz.so", .{ .mode = 0o755 });
        // Type bits in opts.mode are dropped, the entry stays a symlink.
        try zw.addSymlink("typed_link", "target.txt", .{ .mode = 0o100644 });
        try zw.addSymlink("abs_link", "/abs", .{ .allow_unsafe_target = true });
        try zw.addBytes("readme.txt", "hello\n", .{ .method = .stored });

        // Rejected calls must fail before writing anything, so the entry count below stays at 5.
        try std.testing.expectError(error.InvalidSymlinkTarget, zw.addSymlink("empty", "", .{}));
        try std.testing.expectError(error.UnsafeSymlinkTarget, zw.addSymlink("abs", "/abs", .{}));
        try std.testing.expectError(error.UnsafeSymlinkTarget, zw.addSymlink("up", "../x", .{}));
        try std.testing.expectError(error.InvalidName, zw.addSymlink("x/", "target.txt", .{}));
        try zw.finish();
    }

    const Want = struct { name: []const u8, data: []const u8, mode: u32 };
    const want = [_]Want{
        .{ .name = "link", .data = "lib/libz.so", .mode = 0o120777 },
        .{ .name = "exec_link", .data = "lib/libz.so", .mode = 0o120755 },
        .{ .name = "typed_link", .data = "target.txt", .mode = 0o120644 },
        .{ .name = "abs_link", .data = "/abs", .mode = 0o120777 },
        .{ .name = "readme.txt", .data = "hello\n", .mode = 0o100644 },
    };

    // Walk the central directory headers straight from the bytes, and check each local entry.
    const bytes = out.written();
    var pos = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    for (want) |w| {
        try std.testing.expectEqualSlices(u8, "PK\x01\x02", bytes[pos..][0..4]);
        const h = bytes[pos..][0..46];
        const needed = std.mem.readInt(u16, h[6..8], .little);
        const method = std.mem.readInt(u16, h[10..12], .little);
        const crc = std.mem.readInt(u32, h[16..20], .little);
        const csize = std.mem.readInt(u32, h[20..24], .little);
        const usize_ = std.mem.readInt(u32, h[24..28], .little);
        const name_len = std.mem.readInt(u16, h[28..30], .little);
        const extra_len = std.mem.readInt(u16, h[30..32], .little);
        const comment_len = std.mem.readInt(u16, h[32..34], .little);
        const attrs = std.mem.readInt(u32, h[38..42], .little);
        const lfh_offset = std.mem.readInt(u32, h[42..46], .little);

        try std.testing.expectEqualStrings(w.name, bytes[pos + 46 ..][0..name_len]);
        try std.testing.expectEqual(w.mode, attrs >> 16);
        try std.testing.expectEqual(@as(u32, 0), attrs & 0x10); // no MS-DOS directory bit
        try std.testing.expectEqual(@as(u16, 0), method); // stored
        try std.testing.expectEqual(@as(u16, 10), needed);
        try std.testing.expectEqual(std.hash.Crc32.hash(w.data), crc);
        try std.testing.expectEqual(@as(u32, @intCast(w.data.len)), csize);
        try std.testing.expectEqual(@as(u32, @intCast(w.data.len)), usize_);

        // Local header agrees, and its data is the target bytes as is (no trailing NUL).
        const l = bytes[lfh_offset..][0..30];
        try std.testing.expectEqualSlices(u8, "PK\x03\x04", l[0..4]);
        try std.testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, l[4..6], .little));
        try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, l[8..10], .little));
        try std.testing.expectEqual(crc, std.mem.readInt(u32, l[14..18], .little));
        const l_name_len = std.mem.readInt(u16, l[26..28], .little);
        const l_extra_len = std.mem.readInt(u16, l[28..30], .little);
        const data_start = lfh_offset + 30 + l_name_len + l_extra_len;
        try std.testing.expectEqualSlices(u8, w.data, bytes[data_start..][0..w.data.len]);

        pos += 46 + name_len + extra_len + comment_len;
    }

    // End record right after the last header, counting only the entries that were accepted.
    try std.testing.expectEqualSlices(u8, "PK\x05\x06", bytes[pos..][0..4]);
    const eocd = bytes[pos..][0..22];
    try std.testing.expectEqual(@as(u16, want.len), std.mem.readInt(u16, eocd[8..10], .little));
    try std.testing.expectEqual(@as(u16, want.len), std.mem.readInt(u16, eocd[10..12], .little));
    try std.testing.expectEqual(bytes.len, pos + 22);
}

test "writer: directories, files and symlinks list with their kind, mode and mtime" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addDirectory("docs", .{ .mtime = 1793013477 });
        try zw.addBytes("docs/a.txt", "a\n", .{ .method = .stored, .mode = 0o600, .mtime = 1793013477 });
        try zw.addSymlink("link", "docs/a.txt", .{ .mtime = 1793013477 });
        try zw.finish();
    }

    const Kind = @import("../Entry.zig").Kind;
    const want = [_]struct { mode: u32, kind: Kind }{
        .{ .mode = 0o040755, .kind = .directory },
        .{ .mode = 0o100600, .kind = .file },
        .{ .mode = 0o120777, .kind = .symlink },
    };
    var archive = try Archive.openMemory(out.written(), .{});
    for (want) |w| {
        const fd = (try archive.next()) orelse return error.TestTooFewEntries;
        try std.testing.expectEqual(@as(?u32, w.mode), fd.unixMode());
        try std.testing.expectEqual(w.kind, fd.kind());
        // The odd second survives in 0x5455; DOS time alone would drop it.
        try std.testing.expectEqual(@as(?i64, 1793013477), fd.mtime);
        try std.testing.expectEqual(1793013477, fd.modTime());
        try std.testing.expectEqual(@as(?u32, null), fd.uid); // the writer has no 0x7875
        try std.testing.expect(!fd.nameIsUtf8());
    }
    try std.testing.expectEqual(null, try archive.next());
}

/// A few KB of repeated text, so deflate shrinks it a lot. Caller frees.
fn streamInput() ![]u8 {
    const data = try gpa.alloc(u8, 6 << 10);
    const line = "streamed through addStream, size unknown up front\n";
    for (data, 0..) |*c, i| c.* = line[i % line.len];
    return data;
}

test "writer: addStream round-trips through the Archive between addBytes entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input = try streamInput();
    defer gpa.free(input);

    {
        var file = try tmp.dir.createFile(io, "out.zip", .{});
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &file_buf);

        var zw: Writer = undefined;
        try zw.init(gpa, &fw.interface);
        defer zw.deinit();
        try zw.addBytes("before.txt", "before\n", .{ .method = .stored });
        var src: std.Io.Reader = .fixed(input);
        try zw.addStream("streamed.txt", &src, .{ .mtime = 1793013477 });
        try zw.addBytes("after.txt", "after\n", .{ .method = .stored });
        try zw.finish();
        try std.testing.expectError(error.WriterFinished, zw.addStream("late.txt", &src, .{}));
    }

    const Want = struct { name: []const u8, data: []const u8, method: CompressionMethod, bit3: bool };
    const want = [_]Want{
        .{ .name = "before.txt", .data = "before\n", .method = .stored, .bit3 = false },
        .{ .name = "streamed.txt", .data = input, .method = .deflate, .bit3 = true },
        .{ .name = "after.txt", .data = "after\n", .method = .stored, .bit3 = false },
    };

    var file = try tmp.dir.openFile(io, "out.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= want.len) return error.TestTooManyEntries;
        const w = want[count];

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(w.name, try fd.fileName(&iter.source, &name_buf));
        try std.testing.expectEqual(w.method, fd.compression());
        try std.testing.expectEqual(w.bit3, fd.flags.data_descriptor);
        try std.testing.expectEqual(std.hash.Crc32.hash(w.data), fd.crc32Checksum());
        try std.testing.expectEqual(@as(u64, w.data.len), fd.uncompressed_size);
        if (w.method == .deflate) try std.testing.expect(fd.compressed_size < w.data.len);

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const n = try iter.streamEntry(&fd, &out.writer);
        try std.testing.expectEqual(w.data.len, n);
        try std.testing.expectEqualSlices(u8, w.data, out.written());
    }
    try std.testing.expectEqual(want.len, count);
}

test "writer: addStream writes zeroed local sizes, a data descriptor and the real values in the central directory" {
    const input = try streamInput();
    defer gpa.free(input);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("before.txt", "before\n", .{ .method = .stored });
        var src: std.Io.Reader = .fixed(input);
        try zw.addStream("streamed.txt", &src, .{ .mtime = 1793013477 });
        try zw.finish();
    }

    const bytes = out.written();
    const crc = std.hash.Crc32.hash(input);

    // The streamed entry starts right after the first one: header, name, 9-byte UT extra, data.
    const offset = 30 + "before.txt".len + 9 + "before\n".len;
    const l = bytes[offset..][0..30];
    try std.testing.expectEqualSlices(u8, "PK\x03\x04", l[0..4]);
    try std.testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, l[4..6], .little));
    const l_flags = std.mem.readInt(u16, l[6..8], .little);
    try std.testing.expect(l_flags & 0x0008 != 0); // bit 3
    try std.testing.expect(l_flags & 0x0800 == 0); // ASCII name, no bit 11
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, l[8..10], .little)); // deflate
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, l[14..18], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, l[18..22], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, l[22..26], .little));
    const l_name_len = std.mem.readInt(u16, l[26..28], .little);
    const l_extra_len = std.mem.readInt(u16, l[28..30], .little);
    try std.testing.expectEqualStrings("streamed.txt", bytes[offset + 30 ..][0..l_name_len]);
    try std.testing.expectEqual(@as(u16, 9), l_extra_len);
    const data_start = offset + 30 + l_name_len + l_extra_len;

    // The central directory: the first entry, then the streamed one.
    var pos = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    pos += 46 + "before.txt".len + 9;
    const h = bytes[pos..][0..46];
    try std.testing.expectEqualSlices(u8, "PK\x01\x02", h[0..4]);
    try std.testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, h[6..8], .little));
    try std.testing.expect(std.mem.readInt(u16, h[8..10], .little) & 0x0008 != 0);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, h[10..12], .little));
    try std.testing.expectEqual(crc, std.mem.readInt(u32, h[16..20], .little));
    const csize = std.mem.readInt(u32, h[20..24], .little);
    try std.testing.expect(csize > 0 and csize < input.len);
    try std.testing.expectEqual(@as(u32, @intCast(input.len)), std.mem.readInt(u32, h[24..28], .little));
    const name_len = std.mem.readInt(u16, h[28..30], .little);
    const extra_len = std.mem.readInt(u16, h[30..32], .little);
    try std.testing.expectEqualStrings("streamed.txt", bytes[pos + 46 ..][0..name_len]);
    try std.testing.expectEqual(@as(u32, 0o100644), std.mem.readInt(u32, h[38..42], .little) >> 16);
    try std.testing.expectEqual(@as(u32, offset), std.mem.readInt(u32, h[42..46], .little));

    // The 16-byte descriptor sits right after the compressed data.
    const d = bytes[data_start + csize ..][0..16];
    try std.testing.expectEqualSlices(u8, "PK\x07\x08", d[0..4]);
    try std.testing.expectEqual(crc, std.mem.readInt(u32, d[4..8], .little));
    try std.testing.expectEqual(csize, std.mem.readInt(u32, d[8..12], .little));
    try std.testing.expectEqual(@as(u32, @intCast(input.len)), std.mem.readInt(u32, d[12..16], .little));
    // The central directory follows the descriptor directly.
    try std.testing.expectEqualSlices(u8, "PK\x01\x02", bytes[data_start + csize + 16 ..][0..4]);

    // The data itself inflates back to the input.
    var compressed: std.Io.Reader = .fixed(bytes[data_start..][0..csize]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&compressed, .raw, &window);
    const inflated = try inflate.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(inflated);
    try std.testing.expectEqualSlices(u8, input, inflated);

    pos += 46 + name_len + extra_len;
    try std.testing.expectEqualSlices(u8, "PK\x05\x06", bytes[pos..][0..4]);
    const eocd = bytes[pos..][0..22];
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, eocd[8..10], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, eocd[10..12], .little));
    try std.testing.expectEqual(bytes.len, pos + 22);
}

test "writer: addStream sets bit 11 for a UTF-8 name" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        var src: std.Io.Reader = .fixed("bonjour\n");
        try zw.addStream("café.txt", &src, .{});
        try zw.finish();
    }

    const bytes = out.written();
    try std.testing.expect(std.mem.readInt(u16, bytes[6..8], .little) & 0x0800 != 0);
    const cd = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    try std.testing.expect(std.mem.readInt(u16, bytes[cd + 8 ..][0..2], .little) & 0x0800 != 0);
}

test "writer: addStream of an empty reader writes CRC 0, size 0 and a descriptor" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        var src: std.Io.Reader = .fixed("");
        try zw.addStream("empty.txt", &src, .{});
        try zw.finish();
    }

    const bytes = out.written();
    // mtime 0 fits in i32, so the 9-byte UT extra is there.
    const data_start = 30 + "empty.txt".len + 9;
    const cd = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    // An empty deflate stream still has its final block, so csize is a few bytes.
    const csize = std.mem.readInt(u32, bytes[cd + 20 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[cd + 16 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[cd + 24 ..][0..4], .little));

    const d = bytes[data_start + csize ..][0..16];
    try std.testing.expectEqualSlices(u8, "PK\x07\x08", d[0..4]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, d[4..8], .little));
    try std.testing.expectEqual(csize, std.mem.readInt(u32, d[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, d[12..16], .little));
    try std.testing.expectEqual(cd, data_start + csize + 16);
}

test "writer: addStream rejects bad names without writing, and the writer stays usable" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        var src: std.Io.Reader = .fixed("data");
        try std.testing.expectError(error.InvalidName, zw.addStream("", &src, .{}));
        try std.testing.expectError(error.InvalidName, zw.addStream("../x", &src, .{}));
        try std.testing.expectError(error.InvalidName, zw.addStream("dir/", &src, .{}));
        try std.testing.expectEqual(@as(usize, 0), zw.counter.position());
        try zw.addBytes("ok.txt", "ok\n", .{ .method = .stored });
        try zw.finish();
    }

    // Only the one accepted entry made it in.
    const bytes = out.written();
    try std.testing.expectEqualSlices(u8, "PK\x03\x04", bytes[0..4]);
    const eocd = bytes[bytes.len - 22 ..];
    try std.testing.expectEqualSlices(u8, "PK\x05\x06", eocd[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, eocd[10..12], .little));
}

test "writer: a reader failing partway poisons the writer" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();

    // Hands out its buffered bytes, then fails on the next read.
    var src: std.Io.Reader = .failing;
    const partial = "some bytes before the failure";
    src.buffer = @constCast(partial);
    src.end = partial.len;

    try std.testing.expectError(error.ReadFailed, zw.addStream("broken.txt", &src, .{}));
    try std.testing.expectError(error.WriterFailed, zw.addBytes("next.txt", "x", .{}));
    var ok: std.Io.Reader = .fixed("x");
    try std.testing.expectError(error.WriterFailed, zw.addStream("next.txt", &ok, .{}));
    try std.testing.expectError(error.WriterFailed, zw.finish());
}

test "writer: addStream with zip64 writes a ZIP64 local extra and a 24-byte descriptor" {
    const input = try streamInput();
    defer gpa.free(input);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("before.txt", "before\n", .{ .method = .stored });
        var src: std.Io.Reader = .fixed(input);
        try zw.addStream("streamed.txt", &src, .{ .mtime = 1793013477, .zip64 = true });
        try zw.finish();
    }

    const bytes = out.written();
    const crc = std.hash.Crc32.hash(input);

    // Local header: version 4.5, bit 3, CRC 0 and both sizes 0xFFFFFFFF (APPNOTE 4.5.3).
    const offset = 30 + "before.txt".len + 9 + "before\n".len;
    const l = bytes[offset..][0..30];
    try std.testing.expectEqualSlices(u8, "PK\x03\x04", l[0..4]);
    try std.testing.expectEqual(@as(u16, 45), std.mem.readInt(u16, l[4..6], .little));
    try std.testing.expect(std.mem.readInt(u16, l[6..8], .little) & 0x0008 != 0);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, l[8..10], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, l[14..18], .little));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, l[18..22], .little));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, l[22..26], .little));
    const l_name_len = std.mem.readInt(u16, l[26..28], .little);
    const l_extra_len = std.mem.readInt(u16, l[28..30], .little);
    try std.testing.expectEqualStrings("streamed.txt", bytes[offset + 30 ..][0..l_name_len]);

    // Extra: the 9-byte UT field, then 0x0001 with two zero u64 sizes.
    try std.testing.expectEqual(@as(u16, 9 + 20), l_extra_len);
    const l_extra = bytes[offset + 30 + l_name_len ..][0..l_extra_len];
    try std.testing.expectEqualSlices(u8, &.{ 'U', 'T', 5, 0 }, l_extra[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 16, 0x00 }, l_extra[9..13]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 16), l_extra[13..29]);
    const data_start = offset + 30 + l_name_len + l_extra_len;

    // Central directory: real 32-bit sizes, so no ZIP64 extra there, but version needed stays
    // 4.5 like the local header, the same as Info-ZIP and Python write.
    var pos = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    pos += 46 + "before.txt".len + 9;
    const h = bytes[pos..][0..46];
    try std.testing.expectEqualSlices(u8, "PK\x01\x02", h[0..4]);
    try std.testing.expectEqual(@as(u16, 45), std.mem.readInt(u16, h[6..8], .little));
    try std.testing.expectEqual(crc, std.mem.readInt(u32, h[16..20], .little));
    const csize = std.mem.readInt(u32, h[20..24], .little);
    try std.testing.expect(csize > 0 and csize < input.len);
    try std.testing.expectEqual(@as(u32, @intCast(input.len)), std.mem.readInt(u32, h[24..28], .little));
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, h[30..32], .little));
    try std.testing.expectEqual(@as(u32, offset), std.mem.readInt(u32, h[42..46], .little));

    // The 24-byte descriptor: signature, CRC, then u64 compressed and uncompressed sizes,
    // directly followed by the central directory.
    const d = bytes[data_start + csize ..][0..24];
    try std.testing.expectEqualSlices(u8, "PK\x07\x08", d[0..4]);
    try std.testing.expectEqual(crc, std.mem.readInt(u32, d[4..8], .little));
    try std.testing.expectEqual(@as(u64, csize), std.mem.readInt(u64, d[8..16], .little));
    try std.testing.expectEqual(@as(u64, input.len), std.mem.readInt(u64, d[16..24], .little));
    try std.testing.expectEqual(pos - 46 - "before.txt".len - 9, data_start + csize + 24);

    var compressed: std.Io.Reader = .fixed(bytes[data_start..][0..csize]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&compressed, .raw, &window);
    const inflated = try inflate.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(inflated);
    try std.testing.expectEqualSlices(u8, input, inflated);
}

test "writer: addStream with zip64 round-trips through the Archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const input = try streamInput();
    defer gpa.free(input);

    {
        var file = try tmp.dir.createFile(io, "out.zip", .{});
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var fw = file.writer(io, &file_buf);

        var zw: Writer = undefined;
        try zw.init(gpa, &fw.interface);
        defer zw.deinit();
        var src: std.Io.Reader = .fixed(input);
        try zw.addStream("streamed.txt", &src, .{ .zip64 = true });
        try zw.addBytes("after.txt", "after\n", .{ .method = .stored });
        try zw.finish();
    }

    const want = [_][]const u8{ input, "after\n" };

    var file = try tmp.dir.openFile(io, "out.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= want.len) return error.TestTooManyEntries;
        try std.testing.expectEqual(std.hash.Crc32.hash(want[count]), fd.crc32Checksum());
        try std.testing.expectEqual(@as(u64, want[count].len), fd.uncompressed_size);

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        _ = try iter.streamEntry(&fd, &out.writer);
        try std.testing.expectEqualSlices(u8, want[count], out.written());
    }
    try std.testing.expectEqual(want.len, count);
}

test "writer: addStream without zip64 still writes the 16-byte descriptor and version 2.0" {
    // The default must stay byte-compatible with what M8 wrote.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        var src: std.Io.Reader = .fixed("hello\n");
        try zw.addStream("s.txt", &src, .{});
        try zw.finish();
    }
    const bytes = out.written();
    try std.testing.expectEqual(@as(u16, 20), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, bytes[28..30], .little));
    const cd = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    const csize = std.mem.readInt(u32, bytes[cd + 20 ..][0..4], .little);
    try std.testing.expectEqual(cd, 30 + "s.txt".len + 9 + csize + 16);
}

test "writer: addStream with zip64 past 4 GiB puts the size in the central ZIP64 extra (slow)" {
    if (!build_options.slow_tests) return error.SkipZigTest;

    // 4.1 GiB of zeros from /dev/zero. Deflate turns them into a few MB, so the archive stays
    // in memory and `finish` works: only the uncompressed size needs ZIP64, the central
    // directory's offset and size don't.
    const len: u64 = (4 << 30) + (100 << 20);
    var zero_file = try std.Io.Dir.cwd().openFile(io, "/dev/zero", .{ .mode = .read_only });
    defer zero_file.close(io);
    var zero_buf: [64 << 10]u8 = undefined;
    var zeros = zero_file.reader(io, &zero_buf);
    var limited_buf: [64 << 10]u8 = undefined;
    var src: std.Io.Reader.Limited = .init(&zeros.interface, .limited(len), &limited_buf);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addStream("zeros.bin", &src.interface, .{ .zip64 = true, .level = .fastest });
        try zw.finish();
    }

    const bytes = out.written();
    const cd = std.mem.indexOf(u8, bytes, "PK\x01\x02") orelse return error.TestNoCentralDirectory;
    const h = bytes[cd..][0..46];
    try std.testing.expectEqual(@as(u16, 45), std.mem.readInt(u16, h[6..8], .little));
    const csize = std.mem.readInt(u32, h[20..24], .little);
    try std.testing.expect(csize < 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), std.mem.readInt(u32, h[24..28], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, h[42..46], .little));

    // Central extra: UT, then 0x0001 with only the uncompressed size.
    const name_len = std.mem.readInt(u16, h[28..30], .little);
    try std.testing.expectEqual(@as(u16, 9 + 12), std.mem.readInt(u16, h[30..32], .little));
    const z = bytes[cd + 46 + name_len + 9 ..][0..12];
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 8, 0x00 }, z[0..4]);
    try std.testing.expectEqual(len, std.mem.readInt(u64, z[4..12], .little));

    // The 24-byte descriptor right before the central directory agrees.
    const d = bytes[cd - 24 ..][0..24];
    try std.testing.expectEqualSlices(u8, "PK\x07\x08", d[0..4]);
    try std.testing.expectEqual(std.mem.readInt(u32, h[16..20], .little), std.mem.readInt(u32, d[4..8], .little));
    try std.testing.expectEqual(@as(u64, csize), std.mem.readInt(u64, d[8..16], .little));
    try std.testing.expectEqual(len, std.mem.readInt(u64, d[16..24], .little));
}

test "writer: addStream without zip64 past 4 GiB returns Zip64Required and poisons the writer (slow)" {
    if (!build_options.slow_tests) return error.SkipZigTest;

    const len: u64 = 4 << 30;
    var zero_file = try std.Io.Dir.cwd().openFile(io, "/dev/zero", .{ .mode = .read_only });
    defer zero_file.close(io);
    var zero_buf: [64 << 10]u8 = undefined;
    var zeros = zero_file.reader(io, &zero_buf);
    var limited_buf: [64 << 10]u8 = undefined;
    var src: std.Io.Reader.Limited = .init(&zeros.interface, .limited(len), &limited_buf);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    try std.testing.expectError(error.Zip64Required, zw.addStream("zeros.bin", &src.interface, .{ .level = .fastest }));
    try std.testing.expectError(error.WriterFailed, zw.finish());
}

test "writer: 65536 entries write the ZIP64 end records and round-trip through the Archive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One past the u16 count, so only the entry count needs ZIP64.
    const n: usize = 0x1_0000;
    var name_buf: [16]u8 = undefined;
    {
        var file = try tmp.dir.createFile(io, "out.zip", .{});
        defer file.close(io);
        var file_buf: [64 << 10]u8 = undefined;
        var fw = file.writer(io, &file_buf);

        var zw: Writer = undefined;
        try zw.init(gpa, &fw.interface);
        defer zw.deinit();
        for (0..n) |i| try zw.addBytes(try std.fmt.bufPrint(&name_buf, "f{d}", .{i}), "", .{ .method = .stored });
        try zw.finish();
    }

    const bytes = try tmp.dir.readFileAlloc(io, "out.zip", gpa, .unlimited);
    defer gpa.free(bytes);

    // Tail: 56-byte ZIP64 end record, 20-byte locator, 22-byte classic end record.
    const eocd = bytes[bytes.len - 22 ..];
    const locator = bytes[bytes.len - 42 ..][0..20];
    const eocd64_offset = bytes.len - 98;
    const eocd64 = bytes[eocd64_offset..][0..56];

    try std.testing.expectEqualSlices(u8, "PK\x05\x06", eocd[0..4]);
    try std.testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, eocd[8..10], .little));
    try std.testing.expectEqual(@as(u16, 0xFFFF), std.mem.readInt(u16, eocd[10..12], .little));
    // Size and offset still fit, so they stay real.
    const cd_size = std.mem.readInt(u32, eocd[12..16], .little);
    const cd_offset = std.mem.readInt(u32, eocd[16..20], .little);
    try std.testing.expectEqual(eocd64_offset, @as(usize, cd_offset) + cd_size);

    try std.testing.expectEqualSlices(u8, "PK\x06\x07", locator[0..4]);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, locator[4..8], .little));
    try std.testing.expectEqual(@as(u64, eocd64_offset), std.mem.readInt(u64, locator[8..16], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, locator[16..20], .little));

    try std.testing.expectEqualSlices(u8, "PK\x06\x06", eocd64[0..4]);
    try std.testing.expectEqual(@as(u64, 44), std.mem.readInt(u64, eocd64[4..12], .little));
    try std.testing.expectEqual(@as(u16, 45), std.mem.readInt(u16, eocd64[14..16], .little));
    try std.testing.expectEqual(@as(u64, n), std.mem.readInt(u64, eocd64[24..32], .little));
    try std.testing.expectEqual(@as(u64, n), std.mem.readInt(u64, eocd64[32..40], .little));
    try std.testing.expectEqual(@as(u64, cd_size), std.mem.readInt(u64, eocd64[40..48], .little));
    try std.testing.expectEqual(@as(u64, cd_offset), std.mem.readInt(u64, eocd64[48..56], .little));

    var file = try tmp.dir.openFile(io, "out.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    try std.testing.expectEqual(@as(u64, n), iter.total_entries);
    var count: usize = 0;
    var got_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |fd| : (count += 1) {
        try std.testing.expectEqualStrings(
            try std.fmt.bufPrint(&name_buf, "f{d}", .{count}),
            try fd.fileName(&iter.source, &got_buf),
        );
        try std.testing.expectEqual(@as(u64, 0), fd.uncompressed_size);
    }
    try std.testing.expectEqual(n, count);
}

/// Writes `bytes` to a temp file and streams its first entry into a discarding writer.
fn streamFirstEntry(bytes: []const u8) !u64 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });

    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    const fd = (try iter.next()) orelse return error.TestUnexpectedEmptyArchive;
    var out_buf: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&out_buf);
    return iter.streamEntry(&fd, &discard.writer);
}

test "writer: an empty addStream entry reads back as 0 bytes" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        var src: std.Io.Reader = .fixed("");
        try zw.addStream("empty.txt", &src, .{});
        try zw.finish();
    }
    try std.testing.expectEqual(@as(u64, 0), try streamFirstEntry(out.written()));
}

test "writer: one byte flipped in a deflated entry is an error, not a panic" {
    // The bug 18 repro: std 0.16.0's inflater panicked in peekBitsEnding on many of these
    // flips (848, 851 and 858, for example). Bytes 829..869 are all inside the deflate data.
    const data = try gpa.alloc(u8, 200 << 10);
    defer gpa.free(data);
    for (data, 0..) |*c, i| c.* = @truncate(i * 7 + i / 13);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("dir/big.txt", data, .{});
        try zw.finish();
    }
    const bytes = out.written();
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, bytes[8..10], .little));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "PK\x01\x02").? > 869);

    for (829..870) |off| {
        bytes[off] ^= 0xFF;
        defer bytes[off] ^= 0xFF;
        if (streamFirstEntry(bytes)) |n| {
            std.log.err("flip at {d}: stream returned {d} bytes instead of an error", .{ off, n });
            return error.TestExpectedError;
        } else |_| {}
    }
}

/// Fills `buf` from a fixed LCG. With `alphabet`, only its letters, so deflate shrinks the
/// data but not by much.
fn noise(buf: []u8, alphabet: ?[]const u8) void {
    var x: u64 = 0x9E37_79B9_7F4A_7C15;
    for (buf) |*c| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        const v: u8 = @truncate(x >> 33);
        c.* = if (alphabet) |a| a[v % a.len] else v;
    }
}

/// Every add call and `finish` refuse a poisoned writer.
fn expectPoisoned(zw: *Writer) !void {
    try std.testing.expect(zw.poisoned);
    try std.testing.expectError(error.WriterFailed, zw.addBytes("next.txt", "x", .{}));
    try std.testing.expectError(error.WriterFailed, zw.addDirectory("next", .{}));
    try std.testing.expectError(error.WriterFailed, zw.addSymlink("link", "next.txt", .{}));
    var src: std.Io.Reader = .fixed("x");
    try std.testing.expectError(error.WriterFailed, zw.addStream("streamed.txt", &src, .{}));
    try std.testing.expectError(error.WriterFailed, zw.finish());
}

const Expected = struct { name: []const u8, data: []const u8 };

/// Writes `bytes` to a temp file and checks the Archive reads back exactly `want`.
fn expectArchive(bytes: []const u8, want: []const Expected) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });

    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= want.len) return error.TestTooManyEntries;
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(want[count].name, try fd.fileName(&iter.source, &name_buf));
        var got: std.Io.Writer.Allocating = .init(gpa);
        defer got.deinit();
        _ = try iter.streamEntry(&fd, &got.writer);
        try std.testing.expectEqualSlices(u8, want[count].data, got.written());
    }
    try std.testing.expectEqual(want.len, count);
}

/// Writes "first.txt", then `name` with `data` into an `out` that takes `limit` bytes.
fn expectAddFailsAt(limit: usize, name: []const u8, data: []const u8, opts: Writer.EntryOptions) !void {
    const out_buf = try gpa.alloc(u8, limit);
    defer gpa.free(out_buf);
    var out: std.Io.Writer = .fixed(out_buf);

    var zw: Writer = undefined;
    try zw.init(gpa, &out);
    defer zw.deinit();
    try zw.addBytes("first.txt", "hello\n", .{ .method = .stored });
    try std.testing.expectError(error.WriteFailed, zw.addBytes(name, data, opts));
    try std.testing.expectEqual(limit, out.end);
    try expectPoisoned(&zw);
}

test "writer: out failing anywhere inside an addBytes entry poisons the writer" {
    // Writer keeps 8 KiB in front of `out`, so only a payload bigger than that reaches `out`
    // inside addBytes. The limit then picks where in the second entry `out` gives up.
    const stored = try gpa.alloc(u8, 16 << 10);
    defer gpa.free(stored);
    noise(stored, null);
    // ~64 KiB of 16 letters deflates to about half, still well past 8 KiB.
    const deflated = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(deflated);
    noise(deflated, "abcdefghijklmnop");

    const first_len = 30 + "first.txt".len + 9 + "hello\n".len;
    const name = "second.bin";
    const payload_start = 30 + name.len + 9; // header, name, 0x5455 extra

    for ([_]Writer.EntryOptions{ .{ .method = .stored }, .{} }, [_][]const u8{ stored, deflated }) |opts, data| {
        // Every byte of the header, name and extra, the payload's start, then a few deep ones.
        for (0..payload_start + 16) |j| try expectAddFailsAt(first_len + j, name, data, opts);
        for ([_]usize{ 1000, 5000, 9000 }) |j| try expectAddFailsAt(first_len + payload_start + j, name, data, opts);
    }

    // The deflated case really is deflated, and the second header starts where we think.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("first.txt", "hello\n", .{ .method = .stored });
        try zw.addBytes(name, deflated, .{});
        try zw.finish();
    }
    const second = out.written()[first_len..];
    try std.testing.expectEqualSlices(u8, "PK\x03\x04", second[0..4]);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, second[8..10], .little));
    try std.testing.expect(std.mem.readInt(u32, second[18..22], .little) > 9000 + 8192);
}

test "writer: out failing in each write of addBytes, addDirectory and addSymlink poisons the writer" {
    // `out` takes exactly the first entry, which leaves our 8 KiB buffer k bytes short of
    // full. The drain, and with it the failure, then comes from whichever write of the second
    // entry crosses the buffer end: the header, the name, the extra or the payload.
    const buf_len = 8 << 10;
    const first_fixed = 30 + "first.bin".len + 9;
    const first_data = try gpa.alloc(u8, buf_len);
    defer gpa.free(first_data);
    noise(first_data, null);

    const Kind = enum {
        stored,
        deflated,
        directory,
        symlink,

        const text = "the quick brown fox jumps over the lazy dog\n" ** 8;

        fn add(kind: @This(), zw: *Writer) !void {
            switch (kind) {
                .stored => try zw.addBytes("second.txt", text, .{ .method = .stored }),
                .deflated => try zw.addBytes("second.txt", text, .{}),
                .directory => try zw.addDirectory("second", .{}),
                .symlink => try zw.addSymlink("second", "first.bin", .{}),
            }
        }
    };

    for (std.enums.values(Kind)) |kind| {
        // Size of the second entry, from a run that succeeds.
        const second_len = blk: {
            var dry: std.Io.Writer.Allocating = .init(gpa);
            defer dry.deinit();
            var zw: Writer = undefined;
            try zw.init(gpa, &dry.writer);
            defer zw.deinit();
            try kind.add(&zw);
            break :blk zw.counter.position();
        };

        // k == second_len would fit the buffer exactly, so nothing drains inside the call.
        for (0..second_len) |k| {
            const first_len = buf_len - k;
            const out_buf = try gpa.alloc(u8, first_len);
            defer gpa.free(out_buf);
            var out: std.Io.Writer = .fixed(out_buf);

            var zw: Writer = undefined;
            try zw.init(gpa, &out);
            defer zw.deinit();
            try zw.addBytes("first.bin", first_data[0 .. first_len - first_fixed], .{ .method = .stored });
            try std.testing.expectEqual(@as(u64, first_len), zw.counter.position());
            try std.testing.expectError(error.WriteFailed, kind.add(&zw));
            try std.testing.expectEqual(first_len, out.end);
            try expectPoisoned(&zw);
        }
    }
}

test "writer: an allocation failing in addBytes poisons the writer only once bytes are out" {
    // Fails each allocation of one addBytes in turn. Before the first byte (buffer, deflate,
    // name copy) the writer must carry on; after it (the records append) it must be poisoned.
    var letters: [4 << 10]u8 = undefined;
    noise(&letters, "abcdefghijklmnop");

    for ([_]Writer.EntryOptions{ .{ .method = .stored }, .{} }) |opts| {
        var saw_clean = false;
        var saw_poisoned = false;
        var fail_at: usize = 0;
        while (true) : (fail_at += 1) {
            var fa: std.testing.FailingAllocator = .init(gpa, .{});
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();

            var zw: Writer = undefined;
            try zw.init(fa.allocator(), &out.writer);
            defer zw.deinit();

            fa.fail_index = fa.alloc_index + fail_at;
            zw.addBytes("a.txt", &letters, opts) catch |err| {
                fa.fail_index = std.math.maxInt(usize);
                if (zw.counter.position() == 0) {
                    // Allocating turns a failed grow while deflating into WriteFailed.
                    if (err != error.OutOfMemory and err != error.WriteFailed) return err;
                    saw_clean = true;
                    try std.testing.expect(!zw.poisoned);
                    try zw.addBytes("b.txt", "ok\n", .{});
                    try zw.finish();
                    try expectArchive(out.written(), &.{.{ .name = "b.txt", .data = "ok\n" }});
                } else {
                    if (err != error.OutOfMemory) return err;
                    saw_poisoned = true;
                    try expectPoisoned(&zw);
                }
                continue;
            };

            try std.testing.expect(!zw.poisoned);
            try zw.finish();
            try expectArchive(out.written(), &.{.{ .name = "a.txt", .data = &letters }});
            break;
        }
        try std.testing.expect(saw_clean and saw_poisoned);
    }
}

test "writer: rejected names and targets don't poison the writer" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("first.txt", "one\n", .{});
        const pos = zw.counter.position();

        for ([_][]const u8{ "", "../x", "/abs", "a\\b", "dir/" }) |bad| {
            try std.testing.expectError(error.InvalidName, zw.addBytes(bad, "x", .{}));
            try std.testing.expectError(error.InvalidName, zw.addSymlink(bad, "first.txt", .{}));
        }
        try std.testing.expectError(error.InvalidName, zw.addDirectory("", .{}));
        try std.testing.expectError(error.InvalidName, zw.addDirectory("../x", .{}));
        try std.testing.expectError(error.UnsafeSymlinkTarget, zw.addSymlink("link", "../x", .{}));
        try std.testing.expectError(error.InvalidSymlinkTarget, zw.addSymlink("link", "", .{}));

        try std.testing.expect(!zw.poisoned);
        try std.testing.expectEqual(pos, zw.counter.position());
        try zw.addBytes("second.txt", "two\n", .{ .method = .stored });
        try zw.addDirectory("dir", .{});
        try zw.addSymlink("link", "first.txt", .{});
        try zw.finish();
    }
    try expectArchive(out.written(), &.{
        .{ .name = "first.txt", .data = "one\n" },
        .{ .name = "second.txt", .data = "two\n" },
        .{ .name = "dir/", .data = "" },
        .{ .name = "link", .data = "first.txt" },
    });
}

test "writer: a finish that fails partway poisons the writer" {
    // Small entries stay in our buffer, so the failure only shows up in finish.
    var buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var zw: Writer = undefined;
    try zw.init(gpa, &out);
    defer zw.deinit();
    try zw.addBytes("a.txt", "hello\n", .{});
    try std.testing.expectError(error.WriteFailed, zw.finish());
    try expectPoisoned(&zw);
}

test "writer: finish twice says WriterFinished" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    try zw.finish();
    try std.testing.expectError(error.WriterFinished, zw.finish());
    try std.testing.expectError(error.WriterFinished, zw.addBytes("late.txt", "x", .{}));
}
