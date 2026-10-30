//! M11 acceptance: an archive read from a file and the same bytes read from memory give the
//! same listing, the same entry bytes and the same errors. Each read is written out as a
//! transcript, one line per step, and the two transcripts must be equal.
const std = @import("std");
const Archive = @import("../Archive.zig");
const Builder = @import("../testing/Builder.zig");
const Writer = @import("../Writer.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Every file under `testdata/`, relative to the repo root where `zig build test` runs.
const fixtures = [_][]const u8{
    "testdata/accessible_epub_3.epub",
    "testdata/edge/as_zip64.zip",
    "testdata/edge/empty.zip",
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
    "testdata/hostile/eocd_bad_comment_len.zip",
    "testdata/hostile/no_eocd_70k.zip",
    "testdata/hostile/stored_bad_crc.zip",
    "testdata/hostile/tiny.zip",
};

/// Writes what reading `archive` sees into `out`: per entry its name, sizes, CRC, method,
/// flags and a SHA-256 of its bytes, or the error at each step. Stops at the first `next`
/// error; a failed entry read is recorded and the walk goes on.
fn transcript(archive: *Archive, out: *std.Io.Writer) !void {
    var data: std.Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    while (true) {
        const next = archive.next() catch |err| return out.print("next: {t}\n", .{err});
        const e = next orelse break;

        var name_buf: [std.math.maxInt(u16)]u8 = undefined;
        if (archive.entryName(&e, &name_buf)) |name| {
            try out.print("name {s}\n", .{name});
        } else |err| try out.print("name: {t}\n", .{err});
        try out.print("sizes {d} {d} crc {x:0>8} method {d} flags {x:0>4}\n", .{
            e.compressed_size,
            e.uncompressed_size,
            e.crc32,
            @intFromEnum(e.method),
            @as(u16, @bitCast(e.flags)),
        });

        data.clearRetainingCapacity();
        if (archive.streamEntry(&e, &data.writer)) |n| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data.written(), &digest, .{});
            try out.print("data {d} {x}\n", .{ n, digest });
        } else |err| try out.print("data: {t}\n", .{err});
    }
    try out.writeAll("end\n");
}

/// Reads `bytes` from memory, and from a file at `path` that holds the same bytes, and
/// checks that both transcripts are equal.
fn expectParity(label: []const u8, path: []const u8, dir: std.Io.Dir, bytes: []const u8) !void {
    var from_memory: std.Io.Writer.Allocating = .init(gpa);
    defer from_memory.deinit();
    if (Archive.openMemory(bytes, .{})) |archive| {
        var a = archive;
        try transcript(&a, &from_memory.writer);
    } else |err| try from_memory.writer.print("open: {t}\n", .{err});

    var from_file: std.Io.Writer.Allocating = .init(gpa);
    defer from_file.deinit();
    var file = try dir.openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    if (Archive.openFile(&reader, .{})) |archive| {
        var a = archive;
        try transcript(&a, &from_file.writer);
    } else |err| try from_file.writer.print("open: {t}\n", .{err});

    std.testing.expectEqualStrings(from_file.written(), from_memory.written()) catch |err| {
        std.debug.print("{s}: file and memory reads differ\n", .{label});
        return err;
    };
}

/// Writes `bytes` to a temporary file, then checks parity on it.
fn expectParityBytes(label: []const u8, bytes: []const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });
    try expectParity(label, "in.zip", tmp.dir, bytes);
}

test "source parity: every testdata fixture reads the same from a file and from memory" {
    // Hostile fixtures make the reader warn; only differences are news here.
    std.testing.log_level = .err;
    for (fixtures) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20));
        defer gpa.free(bytes);
        try expectParity(path, path, std.Io.Dir.cwd(), bytes);
    }
}

test "source parity: writer archives and every prefix of them read the same both ways" {
    std.testing.log_level = .err;
    var text: [600]u8 = undefined;
    const line = "the quick brown fox jumps over the lazy dog 0123456789\n";
    for (&text, 0..) |*c, i| c.* = line[(i * 7 + i / 31) % line.len];

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();
        try zw.addBytes("a.txt", "hello\n", .{ .method = .stored });
        try zw.addBytes("dir/text.txt", &text, .{});
        var src: std.Io.Reader = .fixed(&text);
        try zw.addStream("stream.txt", &src, .{ .zip64 = true });
        try zw.finish();
    }
    const bytes = out.written();

    // Cuts hit every record at every offset, so both sources must fail the same way.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..bytes.len + 1) |len| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes[0..len] });
        try expectParity("writer prefix", "in.zip", tmp.dir, bytes[0..len]);
    }
}

test "source parity: hostile builder archives fail the same way both ways" {
    std.testing.log_level = .err;
    const data = "hi\n";
    const crc = comptime std.hash.Crc32.hash(data);
    const Case = struct { flags: u16 = 0, method: u16 = 0, crc32: u32 = crc, local_offset: ?u32 = null };
    const cases = [_]Case{
        .{}, // valid
        .{ .crc32 = crc ^ 1 }, // ZipCrcMismatch
        .{ .flags = 1 }, // ZipEncrypted
        .{ .method = 99 }, // ZipUnsupportedMethod
        .{ .local_offset = 105 }, // 6 bytes before the end of the 111-byte archive: ZipTruncated
    };
    for (cases) |c| {
        var b: Builder = .init(gpa);
        defer b.deinit();
        try b.local(.{ .flags = c.flags, .method = c.method, .crc32 = c.crc32, .compressed_size = data.len, .uncompressed_size = data.len, .name = "a.txt" });
        try b.raw(data);
        const cd_offset = b.pos();
        try b.central(.{ .flags = c.flags, .method = c.method, .crc32 = c.crc32, .compressed_size = data.len, .uncompressed_size = data.len, .offset = c.local_offset orelse 0, .name = "a.txt" });
        try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
        try expectParityBytes("builder case", b.bytes());
    }
}
