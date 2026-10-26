//! Iterator tests that read whole fixture archives. Kept out of iterator.zig to keep that
//! file small. Expected values come from Python's zipfile on the same files.

const std = @import("std");
const Iterator = @import("../iterator.zig").Iterator;

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Reads every entry of `path` into memory (via `stream`) and checks it against `expected`.
fn expectArchiveContents(
    path: []const u8,
    expected: []const struct { name: []const u8, crc32: u32, data: []const u8 },
) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Iterator.init(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= expected.len) return error.TestTooManyEntries;
        const want = expected[count];

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(want.name, try fd.filaneme(&reader, &name_buf));

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const n = try fd.stream(&reader, &out.writer);
        try std.testing.expectEqual(want.data.len, n);
        try std.testing.expectEqualSlices(u8, want.data, out.written());
        try std.testing.expectEqual(want.crc32, std.hash.Crc32.hash(out.written()));
    }
    try std.testing.expectEqual(expected.len, count);
}

test "zip64: local header zip64 extra is honoured" {
    // testdata/as_zip64.zip: one stored entry whose LFH sizes are 0xFFFFFFFF, real sizes in
    // the ZIP64 extra (APPNOTE 4.5.3). Python: 1 entry, a.txt, 6 bytes, crc 0x363a3020.
    try expectArchiveContents("testdata/as_zip64.zip", &.{
        .{ .name = "a.txt", .crc32 = 0x363a3020, .data = "hello\n" },
    });
}

test "zip64: entry extracts to disk with the right bytes" {
    var file = try std.Io.Dir.cwd().openFile(io, "testdata/as_zip64.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var iter = try Iterator.init(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        try fd.extract(io, &reader, tmp.dir, .{});
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    const got = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello\n", got);
}

test "empty archive: 22-byte EOCD-only zip opens and yields no entries" {
    // testdata/hostile/empty.zip == zipfile.ZipFile(p, "w").close(): 22 bytes, 0 entries.
    var file = try std.Io.Dir.cwd().openFile(io, "testdata/hostile/empty.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Iterator.init(&reader);
    try std.testing.expectEqual(null, try iter.next());
}

test "data descriptor: sizes come from the descriptor and the entry reads back" {
    // Regression for the compressed_size vs uncompressed_size typo in Iterator.next.
    // testdata/with_data_descriptor.zip: a.txt, deflate, flag bit 3, 8 -> 6 bytes, crc 0x363a3020.
    try expectArchiveContents("testdata/with_data_descriptor.zip", &.{
        .{ .name = "a.txt", .crc32 = 0x363a3020, .data = "hello\n" },
    });
}

test "deflate: entry without data descriptor reads back (compressed != uncompressed size)" {
    // testdata/with_flated.zip: ascii-1kb.txt, deflate, 11 -> 1024 bytes of 'A', crc 0xb737fb1a.
    try expectArchiveContents("testdata/with_flated.zip", &.{
        .{ .name = "ascii-1kb.txt", .crc32 = 0xb737fb1a, .data = &(.{'A'} ** 1024) },
    });
}

test "stored: entry reads back" {
    // testdata/with_comment.zip: a.txt, stored, 6 bytes, crc 0x363a3020.
    try expectArchiveContents("testdata/with_comment.zip", &.{
        .{ .name = "a.txt", .crc32 = 0x363a3020, .data = "hello\n" },
    });
}
