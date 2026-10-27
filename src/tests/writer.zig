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
        .{ .name = "café.txt", .data = "bonjour\n", .opts = .{ .mode = 0o100600, .mtime = std.math.maxInt(i32) + 1 }, .method = .stored, .utf8 = true },
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
