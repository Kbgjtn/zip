//! The README examples, compiled and run as tests. The code between the `README begin`
//! and `README end` lines is the ```zig blocks of the README's "Examples" section, joined
//! by one blank line; the last test fails when the two drift apart. Built by `zig build test` as its own test
//! executable that imports the module as "zip", the way a user does (see build.zig).

// README begin
const std = @import("std");
const zip = @import("zip");

/// Writes the name and size of every entry in the archive at `path` to `out`, one per line.
fn list(io: std.Io, dir: std.Io.Dir, path: []const u8, out: *std.Io.Writer) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var archive = try zip.Archive.openFile(&reader, .{});
    var name_buf: [std.math.maxInt(u16)]u8 = undefined;
    while (try archive.next()) |entry| {
        const name = try entry.fileName(&archive.source, &name_buf);
        try out.print("{s} {d}\n", .{ name, entry.uncompressed_size });
    }
}

/// Returns the bytes of the entry named `wanted`, or null if there is none.
/// Caller owns returned memory.
fn readOne(gpa: std.mem.Allocator, bytes: []const u8, wanted: []const u8) !?[]u8 {
    var archive = try zip.Archive.openMemory(bytes, .{});
    var name_buf: [std.math.maxInt(u16)]u8 = undefined;
    while (try archive.next()) |entry| {
        const name = try entry.fileName(&archive.source, &name_buf);
        if (std.mem.eql(u8, name, wanted)) return try archive.readEntryAlloc(gpa, &entry, 16 << 20);
    }
    return null;
}

/// Writes a small archive to `path`: a stored file, a folder and a streamed file.
fn write(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &out_buf);

    var zw: zip.Writer = undefined;
    try zw.init(gpa, &fw.interface);
    defer zw.deinit();

    try zw.addBytes("hello.txt", "hello\n", .{ .method = .stored });
    try zw.addDirectory("docs", .{});
    var lines: std.Io.Reader = .fixed("line 1\nline 2\n");
    try zw.addStream("docs/log.txt", &lines, .{});
    try zw.setComment("made with zig");
    try zw.finish();
}

/// Extracts the archive at `path` into the folder `dest_path`, with a 64 MiB cap per
/// entry. Symlink entries are left out.
fn extract(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, dest_path: []const u8) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var limits: zip.Archive.Limits = .default;
    limits.max_entry_size = 64 << 20;
    var archive = try zip.Archive.openFile(&reader, .{ .limits = limits });

    var dest = try dir.createDirPathOpen(io, dest_path, .{});
    defer dest.close(io);
    try archive.extractAll(gpa, io, dest, .{ .symlinks = .skip });
}

/// Returns a word for what kind of failure `err` is.
fn describe(err: zip.errors.EntryError) []const u8 {
    return switch (err) {
        error.ZipCrcMismatch, error.ZipSizeMismatch, error.ZipBadDeflate => "corrupt",
        error.ZipEncrypted, error.ZipUnsupportedMethod => "unsupported",
        else => "other",
    };
}
// README end

const testing = std.testing;

test "readme: write, list, read one and extract" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try write(gpa, io, tmp.dir, "a.zip");

    var listing: std.Io.Writer.Allocating = .init(gpa);
    defer listing.deinit();
    try list(io, tmp.dir, "a.zip", &listing.writer);
    try testing.expectEqualStrings("hello.txt 6\ndocs/ 0\ndocs/log.txt 14\n", listing.written());

    const bytes = try tmp.dir.readFileAlloc(io, "a.zip", gpa, .unlimited);
    defer gpa.free(bytes);
    const log = (try readOne(gpa, bytes, "docs/log.txt")).?;
    defer gpa.free(log);
    try testing.expectEqualStrings("line 1\nline 2\n", log);
    try testing.expectEqual(null, try readOne(gpa, bytes, "missing.txt"));

    try extract(gpa, io, tmp.dir, "a.zip", "out");
    const hello = try tmp.dir.readFileAlloc(io, "out/hello.txt", gpa, .unlimited);
    defer gpa.free(hello);
    try testing.expectEqualStrings("hello\n", hello);
}

test "readme: describe sorts errors into kinds" {
    try testing.expectEqualStrings("corrupt", describe(error.ZipCrcMismatch));
    try testing.expectEqualStrings("unsupported", describe(error.ZipEncrypted));
    try testing.expectEqualStrings("other", describe(error.ZipTruncated));
}

test "readme: README.md's examples match this file" {
    const gpa = testing.allocator;
    const io = testing.io;
    // `zig build test` runs from the build root.
    const readme = try std.Io.Dir.cwd().readFileAlloc(io, "README.md", gpa, .unlimited);
    defer gpa.free(readme);
    const self = try std.Io.Dir.cwd().readFileAlloc(io, "src/tests/readme.zig", gpa, .unlimited);
    defer gpa.free(self);

    const begin_marker = "// README begin\n";
    const begin = (std.mem.find(u8, self, begin_marker) orelse return error.NoBeginMarker) + begin_marker.len;
    const end = std.mem.findPos(u8, self, begin, "// README end\n") orelse return error.NoEndMarker;

    var blocks: std.Io.Writer.Allocating = .init(gpa);
    defer blocks.deinit();
    try zigBlocks(try section(readme, "Examples"), &blocks.writer);
    try testing.expectEqualStrings(self[begin..end], blocks.written());
}

/// Returns the body of the level-2 section titled `title` in `markdown`, up to the next
/// level-2 heading or the end.
fn section(markdown: []const u8, title: []const u8) ![]const u8 {
    var heading_buf: [64]u8 = undefined;
    const heading = try std.fmt.bufPrint(&heading_buf, "\n## {s}\n", .{title});
    const start = (std.mem.find(u8, markdown, heading) orelse return error.NoSection) + heading.len;
    const end = std.mem.findPos(u8, markdown, start, "\n## ") orelse markdown.len;
    return markdown[start..end];
}

/// Writes the body of every block fenced with "```zig" in `markdown`, joined by one blank
/// line.
fn zigBlocks(markdown: []const u8, out: *std.Io.Writer) !void {
    const open = "\n```zig\n";
    var pos: usize = 0;
    var first = true;
    while (std.mem.findPos(u8, markdown, pos, open)) |at| {
        const body = at + open.len;
        const close = std.mem.findPos(u8, markdown, body, "\n```\n") orelse return error.UnclosedBlock;
        if (!first) try out.writeByte('\n');
        first = false;
        try out.writeAll(markdown[body .. close + 1]);
        pos = close + 1;
    }
}
