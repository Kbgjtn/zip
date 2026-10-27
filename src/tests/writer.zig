//! Writer round-trip tests: write an archive with our Writer, read it back with our Iterator.

const std = @import("std");
const Writer = @import("../writer.zig");
const Iterator = @import("../iterator.zig").Iterator;
const CompressionMethod = @import("../format.zig").CompressionMethod;
const HeaderId = @import("../format.zig").HeaderId;
const LocalFileHeader = @import("../records/local_file_header.zig").LocalFileHeader;
const extra = @import("../extra.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

test "writer: addBytes round-trips through the Iterator (empty, stored, deflate, UTF-8 name, mtime)" {
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

    var iter = try Iterator.init(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= entries.len) return error.TestTooManyEntries;
        const want = entries[count];

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(want.name, try fd.filaneme(&reader, &name_buf));
        try std.testing.expectEqual(want.method, fd.compression());
        try std.testing.expectEqual(want.utf8, fd.header.flags.language_encoding);
        try std.testing.expectEqual(false, fd.header.flags.data_descriptor);
        try std.testing.expectEqual(std.hash.Crc32.hash(want.data), fd.crc32Checksum());
        try std.testing.expectEqual(@as(u64, want.data.len), fd.uncompressed_size);
        if (want.method == .deflate) try std.testing.expect(fd.compressed_size < want.data.len);

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const n = try fd.stream(&reader, &out.writer);
        try std.testing.expectEqual(want.data.len, n);
        try std.testing.expectEqualSlices(u8, want.data, out.written());

        // 0x5455 in the local header: mtime read back exactly, or no extra at all past i32.
        const want_mtime = std.math.cast(i32, want.opts.mtime);
        if (want_mtime == null) {
            try std.testing.expectEqual(@as(u16, 0), fd.header.extra_len);
            continue;
        }
        try std.testing.expectEqual(@as(u16, 9), fd.header.extra_len);
        var extra_buf: [9]u8 = undefined;
        try reader.seekTo(fd.offset + LocalFileHeader.size + fd.header.filename_len);
        try reader.interface.readSliceAll(&extra_buf);
        const it: extra.Iterator = .{ .buf = &extra_buf };
        const field = it.find(HeaderId.extended_timestamp) orelse return error.TestMissingTimestamp;
        const ut = (try field.parse(.none)).extended_timestamp;
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

/// A few KB of repeated text, so deflate shrinks it a lot. Caller frees.
fn streamInput() ![]u8 {
    const data = try gpa.alloc(u8, 6 << 10);
    const line = "streamed through addStream, size unknown up front\n";
    for (data, 0..) |*c, i| c.* = line[i % line.len];
    return data;
}

test "writer: addStream round-trips through the Iterator between addBytes entries" {
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

    var iter = try Iterator.init(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= want.len) return error.TestTooManyEntries;
        const w = want[count];

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(w.name, try fd.filaneme(&reader, &name_buf));
        try std.testing.expectEqual(w.method, fd.compression());
        try std.testing.expectEqual(w.bit3, fd.header.flags.data_descriptor);
        try std.testing.expectEqual(std.hash.Crc32.hash(w.data), fd.crc32Checksum());
        try std.testing.expectEqual(@as(u64, w.data.len), fd.uncompressed_size);
        if (w.method == .deflate) try std.testing.expect(fd.compressed_size < w.data.len);

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const n = try fd.stream(&reader, &out.writer);
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
