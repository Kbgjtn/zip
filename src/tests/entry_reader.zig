//! `Entry.Reader`, from `Archive.entryReader`: the same bytes and the same errors as
//! `streamEntry` whatever the buffer and however it is read, the data checks failing the
//! last read with the cause in `err`, the limits and a too short window refused up front,
//! and readers for several entries used in turn from memory, a file and `openFileAlloc`.
const std = @import("std");
const Archive = @import("../Archive.zig");
const Entry = @import("../Entry.zig");
const Builder = @import("../testing/Builder.zig");
const Writer = @import("../Writer.zig");
const build_options = @import("build_options");

const io = std.testing.io;
const min_buffer_len = Entry.Reader.min_buffer_len;
const gpa = std.testing.allocator;

const fixtures = [_][]const u8{
    "testdata/accessible_epub_3.epub",
    "testdata/edge/as_zip64.zip",
    "testdata/edge/empty_deflated.zip",
    "testdata/edge/os_unknown.zip",
    "testdata/edge/with_comment.zip",
    "testdata/edge/with_data_descriptor.zip",
    "testdata/edge/with_flated.zip",
    "testdata/hostile/deflate_bad_crc.zip",
    "testdata/hostile/deflate_long_output.zip",
    "testdata/hostile/deflate_short_output.zip",
    "testdata/hostile/deflate_trailing_junk.zip",
    "testdata/hostile/deflate_truncated.zip",
    "testdata/hostile/stored_bad_crc.zip",
    "testdata/hostile/tiny.zip",
};

/// How a test pulls the bytes out of `Entry.Reader.interface`.
const Pull = enum { chunks_of_7, bytes, stream_remaining, alloc_remaining };

/// Reads `entry` through an `Entry.Reader` with a buffer of `buffer_len` bytes, pulling
/// as `pull` says, and writes "data <len> <sha256>" or the error to `out`. A deflated
/// entry with a buffer under `min_buffer_len` must be refused; it is then read with
/// `streamEntry`, so the output still matches.
fn readVia(archive: *Archive, entry: *const Entry, buffer_len: usize, pull: Pull, out: *std.Io.Writer) !void {
    const buffer = try gpa.alloc(u8, buffer_len);
    defer gpa.free(buffer);
    if (entry.method == .deflate and buffer_len < min_buffer_len) {
        try std.testing.expectError(error.ZipBufferTooSmall, archive.entryReader(entry, buffer));
        return viaStreamEntry(archive, entry, out);
    }
    var r = archive.entryReader(entry, buffer) catch |err| return out.print("{t}\n", .{err});

    var data: std.Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    const result: anyerror!void = switch (pull) {
        .chunks_of_7 => while (true) {
            var chunk: [7]u8 = undefined;
            const n = r.interface.readSliceShort(&chunk) catch |err| break err;
            if (n == 0) break {};
            try data.writer.writeAll(chunk[0..n]);
        },
        .bytes => while (true) {
            const b = r.interface.takeByte() catch |err| switch (err) {
                error.EndOfStream => break {},
                else => |e| break e,
            };
            try data.writer.writeByte(b);
        },
        .stream_remaining => if (r.interface.streamRemaining(&data.writer)) |_| {} else |err| err,
        .alloc_remaining => blk: {
            const bytes = r.interface.allocRemaining(gpa, .unlimited) catch |err| break :blk err;
            defer gpa.free(bytes);
            try data.writer.writeAll(bytes);
        },
    };
    result catch |err| {
        try std.testing.expectEqual(error.ReadFailed, err);
        return out.print("{t}\n", .{r.err.?});
    };
    try std.testing.expectEqual(null, r.err);
    try printData(data.written(), out);
}

fn printData(bytes: []const u8, out: *std.Io.Writer) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try out.print("data {d} {x}\n", .{ bytes.len, digest });
}

/// What `streamEntry` gives for `entry`, in the format of `readVia`.
fn viaStreamEntry(archive: *Archive, entry: *const Entry, out: *std.Io.Writer) !void {
    var data: std.Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    _ = archive.streamEntry(entry, &data.writer) catch |err| return out.print("{t}\n", .{err});
    try printData(data.written(), out);
}

const Opened = struct {
    archive: Archive,
    file: ?std.Io.File = null,
    file_reader: std.Io.File.Reader = undefined,
    file_buf: [512]u8 = undefined,
    alloc: bool = false,

    fn deinit(o: *Opened) void {
        if (o.alloc) o.archive.deinit(gpa);
        if (o.file) |f| f.close(io);
    }
};

const SourceKind = enum { memory, file, file_alloc };

/// Opens the archive at `path` in `dir`, which holds `bytes`, as `kind` says, into `o`,
/// which must not move after.
fn open(o: *Opened, kind: SourceKind, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    o.* = .{ .archive = undefined };
    switch (kind) {
        .memory => o.archive = try Archive.openMemory(bytes, .{}),
        .file, .file_alloc => {
            o.file = try dir.openFile(io, path, .{ .mode = .read_only });
            o.file_reader = o.file.?.reader(io, &o.file_buf);
            if (kind == .file) {
                o.archive = try Archive.openFile(&o.file_reader, .{});
            } else {
                o.archive = try Archive.openFileAlloc(gpa, &o.file_reader, .{});
                o.alloc = true;
            }
        },
    }
}

/// The parity matrix. Without `-Dslow-tests` a subset that still covers each path: a
/// tiny buffer (refused by deflate) and the window, small reads and streamRemaining, from
/// memory and a file, without the big EPUB.
const Matrix = struct {
    kinds: []const SourceKind,
    buffer_lens: []const usize,
    pulls: []const Pull,
    big_fixtures: bool,
};
const matrix: Matrix = if (build_options.slow_tests) .{
    .kinds = std.enums.values(SourceKind),
    .buffer_lens = &.{ 0, 1, 16, 4096, min_buffer_len, min_buffer_len + 4096 },
    .pulls = std.enums.values(Pull),
    .big_fixtures = true,
} else .{
    .kinds = &.{ .memory, .file },
    .buffer_lens = &.{ 16, min_buffer_len },
    .pulls = &.{ .chunks_of_7, .stream_remaining },
    .big_fixtures = false,
};

test "entry reader: same bytes and errors as streamEntry on every fixture, any buffer, any pull" {
    std.testing.log_level = .err;
    for (fixtures) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20));
        defer gpa.free(bytes);
        const big = bytes.len > 64 << 10;
        if (big and !matrix.big_fixtures) continue;

        var want: std.Io.Writer.Allocating = .init(gpa);
        defer want.deinit();
        {
            // Archives that don't open have nothing to read.
            var archive = Archive.openMemory(bytes, .{}) catch continue;
            while (try archive.next()) |entry| try viaStreamEntry(&archive, &entry, &want.writer);
        }

        for (matrix.kinds) |kind| {
            for (matrix.buffer_lens) |buffer_len| {
                for (matrix.pulls) |pull| {
                    // takeByte and allocRemaining go through the buffer.
                    if (buffer_len == 0 and (pull == .bytes or pull == .alloc_remaining)) continue;
                    // On the big EPUB, tiny reads only make the test slow in Debug.
                    if (big and (buffer_len < min_buffer_len or pull == .bytes or pull == .chunks_of_7)) continue;
                    var got: std.Io.Writer.Allocating = .init(gpa);
                    defer got.deinit();
                    var o: Opened = undefined;
                    try open(&o, kind, std.Io.Dir.cwd(), path, bytes);
                    defer o.deinit();
                    while (try o.archive.next()) |entry| try readVia(&o.archive, &entry, buffer_len, pull, &got.writer);
                    std.testing.expectEqualStrings(want.written(), got.written()) catch |err| {
                        std.debug.print("{s}: {t}, buffer {d}, {t}\n", .{ path, kind, buffer_len, pull });
                        return err;
                    };
                }
            }
        }
    }
}

/// A stored entry "hello\n" whose central and local CRC-32 is `crc`.
fn storedHello(b: *Builder, crc: u32) !void {
    const data = "hello\n";
    try b.local(.{ .crc32 = crc, .compressed_size = data.len, .uncompressed_size = data.len, .name = "a.txt" });
    try b.raw(data);
    const cd_offset = b.pos();
    try b.central(.{ .crc32 = crc, .compressed_size = data.len, .uncompressed_size = data.len, .name = "a.txt" });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
}

test "entry reader: a bad CRC-32 fails the read that reaches the end, with the cause in err" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try storedHello(&b, std.hash.Crc32.hash("hello\n") ^ 1);
    var archive = try Archive.openMemory(b.bytes(), .{});
    const entry = (try archive.next()).?;

    // One byte at a time: the first five come out, the sixth never does.
    var buf: [1]u8 = undefined;
    var r = try archive.entryReader(&entry, &buf);
    for ("hello") |c| try std.testing.expectEqual(c, try r.interface.takeByte());
    try std.testing.expectError(error.ReadFailed, r.interface.takeByte());
    try std.testing.expectEqual(error.ZipCrcMismatch, r.err.?);
    // It stays failed.
    try std.testing.expectError(error.ReadFailed, r.interface.takeByte());

    // All at once: nothing is handed over.
    var all: [6]u8 = undefined;
    r = try archive.entryReader(&entry, &.{});
    try std.testing.expectError(error.ReadFailed, r.interface.readSliceAll(&all));
    try std.testing.expectEqual(error.ZipCrcMismatch, r.err.?);
}

test "entry reader: a good entry ends with EndOfStream, also when the buffer is exactly full" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try storedHello(&b, std.hash.Crc32.hash("hello\n"));
    var archive = try Archive.openMemory(b.bytes(), .{});
    const entry = (try archive.next()).?;
    var buf: [6]u8 = undefined;
    var r = try archive.entryReader(&entry, &buf);
    try std.testing.expectEqualStrings("hello\n", try r.interface.peek(6));
    try std.testing.expectEqualStrings("hello\n", try r.interface.take(6));
    try std.testing.expectError(error.EndOfStream, r.interface.takeByte());
    try std.testing.expectEqual(null, r.err);
}

test "entry reader: limits and refusals fail entryReader before any data is read" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try storedHello(&b, std.hash.Crc32.hash("hello\n"));
    var limits: Archive.Limits = .default;
    limits.max_entry_size = 5;
    var small = try Archive.openMemory(b.bytes(), .{ .limits = limits });
    try std.testing.expectError(error.ZipEntryTooLarge, small.entryReader(&(try small.next()).?, &.{}));

    limits = .default;
    limits.max_total_size = 11;
    var total = try Archive.openMemory(b.bytes(), .{ .limits = limits });
    const entry = (try total.next()).?;
    _ = try total.entryReader(&entry, &.{});
    // The first reader charged 6 bytes, so a second is over 11.
    try std.testing.expectError(error.ZipTotalTooLarge, total.entryReader(&entry, &.{}));
}

test "entry reader: a deflate bomb is refused by its ratio before inflating" {
    // 1 GiB declared from 1 KiB of compressed bytes: 1,048,576:1.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const declared = 1 << 30;
    try b.local(.{ .method = 8, .compressed_size = 1024, .uncompressed_size = declared, .name = "bomb" });
    try b.raw(&([_]u8{0} ** 1024));
    const cd_offset = b.pos();
    try b.central(.{ .method = 8, .compressed_size = 1024, .uncompressed_size = declared, .name = "bomb" });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
    var archive = try Archive.openMemory(b.bytes(), .{});
    var buf: [min_buffer_len]u8 = undefined;
    try std.testing.expectError(error.ZipRatioExceeded, archive.entryReader(&(try archive.next()).?, &buf));
}

/// A deflated archive of "a.txt" holding `lines` lines of "line N\n", then "b.txt".
fn textArchive(out: *std.Io.Writer.Allocating, lines: usize) !void {
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (0..lines) |i| try text.writer.print("line {d}\n", .{i});
    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    try zw.addBytes("a.txt", text.written(), .{});
    try zw.addBytes("b.txt", "bravo\n" ** 50, .{});
    try zw.finish();
}

test "entry reader: takeDelimiter reads a deflated text entry line by line" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try textArchive(&out, 500);
    var archive = try Archive.openMemory(out.written(), .{});
    const entry = (try archive.next()).?;
    try std.testing.expectEqual(.deflate, entry.method);

    var buf: [min_buffer_len]u8 = undefined;
    var r = try archive.entryReader(&entry, &buf);
    var expected: [16]u8 = undefined;
    var i: usize = 0;
    while (try r.interface.takeDelimiter('\n')) |line| : (i += 1) {
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "line {d}", .{i}), line);
    }
    try std.testing.expectEqual(500, i);
    try std.testing.expectEqual(null, r.err);
}

test "entry reader: readers for two entries can be used in turn" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try textArchive(&out, 2000);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = out.written() });

    for (std.enums.values(SourceKind)) |kind| {
        var o: Opened = undefined;
        try open(&o, kind, tmp.dir, "in.zip", out.written());
        defer o.deinit();

        const a = (try o.archive.next()).?;
        const b = (try o.archive.next()).?;
        var a_buf: [min_buffer_len]u8 = undefined;
        var b_buf: [min_buffer_len]u8 = undefined;
        var ra = try o.archive.entryReader(&a, &a_buf);
        var rb = try o.archive.entryReader(&b, &b_buf);

        var got_a: std.Io.Writer.Allocating = .init(gpa);
        defer got_a.deinit();
        var got_b: std.Io.Writer.Allocating = .init(gpa);
        defer got_b.deinit();
        var name_buf: [16]u8 = undefined;
        var a_done = false;
        var b_done = false;
        while (!a_done or !b_done) {
            if (!a_done) a_done = try pullSome(&ra, &got_a.writer);
            if (!b_done) b_done = try pullSome(&rb, &got_b.writer);
            // The name readers move a plain openFile's file reader too.
            _ = try o.archive.entryName(&a, &name_buf);
        }

        const want_a = try o.archive.readEntryAlloc(gpa, &a, 1 << 20);
        defer gpa.free(want_a);
        try std.testing.expectEqualStrings(want_a, got_a.written());
        try std.testing.expectEqualStrings("bravo\n" ** 50, got_b.written());
    }
}

/// Reads up to 100 bytes from `r` into `out`. Returns whether the entry ended.
fn pullSome(r: *Entry.Reader, out: *std.Io.Writer) !bool {
    var chunk: [100]u8 = undefined;
    const n = try r.interface.readSliceShort(&chunk);
    try out.writeAll(chunk[0..n]);
    return n < chunk.len;
}

test "entry reader: empty stored and deflated entries end cleanly" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("stored", "", .{ .method = .stored });
        var empty: std.Io.Reader = .fixed("");
        try zw.addStream("deflated", &empty, .{});
        try zw.finish();
    }
    var archive = try Archive.openMemory(out.written(), .{});
    var buf: [min_buffer_len]u8 = undefined;
    while (try archive.next()) |entry| {
        var r = try archive.entryReader(&entry, if (entry.method == .stored) &.{} else &buf);
        var one: [1]u8 = undefined;
        try std.testing.expectEqual(0, try r.interface.readSliceShort(&one));
        try std.testing.expectEqual(null, r.err);
    }
}

/// Returns a reader for the first entry of `archive`, to move it once before reading.
fn firstEntryReader(archive: *Archive, buffer: []u8) !Entry.Reader {
    const entry = (try archive.next()).?;
    return archive.entryReader(&entry, buffer);
}

test "entry reader: a reader may be moved until its first read" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try textArchive(&out, 50);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = out.written() });

    for (std.enums.values(SourceKind)) |kind| {
        var o: Opened = undefined;
        try open(&o, kind, tmp.dir, "in.zip", out.written());
        defer o.deinit();
        var buf: [min_buffer_len]u8 = undefined;
        // Returned by value twice, then copied once more, all before reading.
        const first = try firstEntryReader(&o.archive, &buf);
        var r = first;
        var lines: usize = 0;
        while (try r.interface.takeDelimiter('\n')) |_| lines += 1;
        try std.testing.expectEqual(50, lines);
        try std.testing.expectEqual(null, r.err);
    }
}

test "entry reader: deflate needs min_buffer_len, refused before the limits; stored takes any" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("stored", "hello\n", .{ .method = .stored });
        try zw.addBytes("deflated", "hello\n" ** 1000, .{});
        try zw.finish();
    }
    var limits: Archive.Limits = .default;
    limits.max_total_size = 6 + 6000;
    var archive = try Archive.openMemory(out.written(), .{ .limits = limits });
    const stored = (try archive.next()).?;
    const deflated = (try archive.next()).?;
    try std.testing.expectEqual(.deflate, deflated.method);

    // One byte short of the window: refused, and nothing charged to max_total_size.
    var buf: [min_buffer_len]u8 = undefined;
    for (0..3) |_| {
        try std.testing.expectError(error.ZipBufferTooSmall, archive.entryReader(&deflated, buf[0 .. min_buffer_len - 1]));
    }
    try std.testing.expectError(error.ZipBufferTooSmall, archive.entryReader(&deflated, &.{}));

    var s = try archive.entryReader(&stored, &.{});
    var got: [6]u8 = undefined;
    try s.interface.readSliceAll(&got);
    try std.testing.expectEqualStrings("hello\n", &got);

    var d = try archive.entryReader(&deflated, &buf);
    const all = try d.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(all);
    try std.testing.expectEqualStrings("hello\n" ** 1000, all);
    try std.testing.expectEqual(null, d.err);
}

test "entry reader: the reader is small; the window is the caller's" {
    try std.testing.expect(@sizeOf(Entry.Reader) <= 4 << 10);
}
