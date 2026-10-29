//! Archive tests that read whole fixture archives. Kept out of Archive.zig to keep that
//! file small. Expected values come from Python's zipfile on the same files, or from
//! `zipinfo -v` where the test says so.

const std = @import("std");
const Archive = @import("../Archive.zig");
const Entry = @import("../Entry.zig");
const time = @import("../time.zig");
const records = @import("../records/root.zig");

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

    var iter = try Archive.openFile(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= expected.len) return error.TestTooManyEntries;
        const want = expected[count];

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(want.name, try fd.fileName(&iter.source, &name_buf));

        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const n = try iter.streamEntry(&fd, &out.writer);
        try std.testing.expectEqual(want.data.len, n);
        try std.testing.expectEqualSlices(u8, want.data, out.written());
        try std.testing.expectEqual(want.crc32, std.hash.Crc32.hash(out.written()));
    }
    try std.testing.expectEqual(expected.len, count);
}

test "zip64: local header zip64 extra is honoured" {
    // testdata/edge/as_zip64.zip: one stored entry whose LFH sizes are 0xFFFFFFFF, real sizes in
    // the ZIP64 extra (APPNOTE 4.5.3). Python: 1 entry, a.txt, 6 bytes, crc 0x363a3020.
    try expectArchiveContents("testdata/edge/as_zip64.zip", &.{
        .{ .name = "a.txt", .crc32 = 0x363a3020, .data = "hello\n" },
    });
}

test "zip64: entry extracts to disk with the right bytes" {
    var file = try std.Io.Dir.cwd().openFile(io, "testdata/edge/as_zip64.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var iter = try Archive.openFile(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        try iter.extractEntry(io, &fd, tmp.dir, .{});
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    const got = try tmp.dir.readFileAlloc(io, "a.txt", gpa, .limited(64));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("hello\n", got);
}

test "empty archive: 22-byte EOCD-only zip opens and yields no entries" {
    // testdata/edge/empty.zip == zipfile.ZipFile(p, "w").close(): 22 bytes, 0 entries.
    var file = try std.Io.Dir.cwd().openFile(io, "testdata/edge/empty.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader);
    try std.testing.expectEqual(null, try iter.next());
}

test "data descriptor: sizes come from the descriptor and the entry reads back" {
    // Regression for the compressed_size vs uncompressed_size typo in Archive.next.
    // testdata/edge/with_data_descriptor.zip: a.txt, deflate, flag bit 3, 8 -> 6 bytes, crc 0x363a3020.
    try expectArchiveContents("testdata/edge/with_data_descriptor.zip", &.{
        .{ .name = "a.txt", .crc32 = 0x363a3020, .data = "hello\n" },
    });
}

test "deflate: entry without data descriptor reads back (compressed != uncompressed size)" {
    // testdata/edge/with_flated.zip: ascii-1kb.txt, deflate, 11 -> 1024 bytes of 'A', crc 0xb737fb1a.
    try expectArchiveContents("testdata/edge/with_flated.zip", &.{
        .{ .name = "ascii-1kb.txt", .crc32 = 0xb737fb1a, .data = &(.{'A'} ** 1024) },
    });
}

test "stored: entry reads back" {
    // testdata/edge/with_comment.zip: a.txt, stored, 6 bytes, crc 0x363a3020.
    try expectArchiveContents("testdata/edge/with_comment.zip", &.{
        .{ .name = "a.txt", .crc32 = 0x363a3020, .data = "hello\n" },
    });
}

test "unknown OS: version_made_by OS 255 is kept, formats, and the entry reads back" {
    // testdata/edge/os_unknown.zip: one stored entry whose CDFH version_made_by high byte
    // is 255 (APPNOTE reserves 20..255). Python's zipfile reports create_system 255.
    const path = "testdata/edge/os_unknown.zip";
    {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);

        var iter = try Archive.openFile(&reader);
        const cdfh = try records.CentralHeader.read(&iter.source, iter.cd_offset);
        try std.testing.expectEqual(@as(u8, 255), @intFromEnum(cdfh.version_made_by.os));

        // Formatting must not panic on an OS value with no name.
        var discard: std.Io.Writer.Discarding = .init(&.{});
        try discard.writer.print("{f}", .{cdfh});
    }
    try expectArchiveContents(path, &.{
        .{ .name = "os.txt", .crc32 = 0xe89fe1d0, .data = "made on an unknown OS\n" },
    });
}

test "metadata: Entry fields match zipinfo -v on edge/metadata.zip" {
    // Expected values are what this prints (ZipInfo 3.00), per entry:
    //     TZ=UTC zipinfo -v testdata/edge/metadata.zip
    // Shared by all five: "operating system of origin: Unix", "version of encoding
    // software: 3.0", "file last modified on (DOS date/time): 2020 Sep 13 12:26:40",
    // "(UT extra field modtime): 2020 Sep 13 12:26:40 UTC", and the 0x7875 bytes
    // "01 04 e8 03 00 00 04 e8 03 00 00" (uid and gid 1000). Bit 11 isn't printed by
    // zipinfo; Python's zipfile gives flag_bits 0x800 for café.txt only.
    const Want = struct {
        /// The header name as stored: zipinfo prints entry #4 from its 0x7075 field.
        name: []const u8,
        /// "UTF8 data of the extra field (V1, ASCII name CRC `411e1f1c')".
        unicode_name: ?[]const u8 = null,
        /// "Unix file attributes (... octal)".
        mode: u32,
        kind: Entry.Kind,
        utf8: bool = false,
        /// "32-bit CRC value (hex)".
        crc32: u32,
        /// "uncompressed size", which equals "compressed size" (stored).
        size: u64,
        /// "length of extra field".
        extra_len: u16 = 24,
        /// Between "file comment begins" and "file comment ends".
        comment: []const u8 = "",
    };
    const want = [_]Want{
        // "MS-DOS file attributes (10 hex): dir".
        .{ .name = "dir/", .mode = 0o040755, .kind = .directory, .crc32 = 0, .size = 0 },
        .{ .name = "dir/hello.txt", .mode = 0o100644, .kind = .file, .crc32 = 0x363a3020, .size = 6, .comment = "greeting" },
        .{ .name = "dir/café.txt", .mode = 0o100600, .kind = .file, .utf8 = true, .crc32 = 0xa7cdfae1, .size = 8 },
        .{
            .name = "dir/na\x8bve.txt", // CP437 0x8B is U+00EF
            .unicode_name = "dir/naïve.txt",
            .mode = 0o100644,
            .kind = .file,
            .crc32 = 0xc9634be3,
            .size = 6,
            .extra_len = 47,
        },
        .{ .name = "link", .mode = 0o120777, .kind = .symlink, .crc32 = 0x98b4c9a9, .size = 13 },
    };
    // 2020-09-13 12:26:40 UTC.
    const mtime: i64 = 1_600_000_000;

    var file = try std.Io.Dir.cwd().openFile(io, "testdata/edge/metadata.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        if (count >= want.len) return error.TestTooManyEntries;
        const w = want[count];

        var name_buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(w.name, try fd.fileName(&iter.source, &name_buf));
        const unicode_name = try fd.unicodeName(&iter.source, &name_buf);
        if (w.unicode_name) |u| {
            try std.testing.expectEqualStrings(u, unicode_name orelse return error.TestMissingUnicodeName);
        } else try std.testing.expectEqual(null, unicode_name);
        try std.testing.expectEqual(w.utf8, fd.nameIsUtf8());

        try std.testing.expectEqual(.unix, fd.version_made_by.os);
        try std.testing.expectEqual(@as(u8, 30), fd.version_made_by.spec_version);
        try std.testing.expectEqual(@as(?u32, w.mode), fd.unixMode());
        try std.testing.expectEqual(w.kind, fd.kind());

        try std.testing.expectEqual(@as(?i64, mtime), fd.mtime);
        try std.testing.expectEqual(mtime, fd.modTime());
        // The DOS fields hold the same wall-clock time, read as UTC.
        try std.testing.expectEqual(mtime, time.decodeDosDateTime(.{ .time = fd.dos_time, .date = fd.dos_date }));
        try std.testing.expectEqual(@as(?u32, 1000), fd.uid);
        try std.testing.expectEqual(@as(?u32, 1000), fd.gid);

        try std.testing.expectEqual(w.crc32, fd.crc32);
        try std.testing.expectEqual(w.size, fd.uncompressed_size);
        try std.testing.expectEqual(w.size, fd.compressed_size);
        try std.testing.expectEqual(w.extra_len, fd.extra_len);
        var comment_buf: [16]u8 = undefined;
        try std.testing.expectEqualStrings(w.comment, try fd.fileComment(&iter.source, &comment_buf));

        // The local headers carry a longer 0x5455 (mtime and atime) and still read.
        const got = try iter.readEntryAlloc(gpa, &fd, 64);
        defer gpa.free(got);
        try std.testing.expectEqual(w.crc32, std.hash.Crc32.hash(got));
    }
    try std.testing.expectEqual(want.len, count);
}
