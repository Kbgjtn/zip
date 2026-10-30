//! Reader tests on testdata/interop/: archives written by Info-ZIP zip, 7-Zip and Python's
//! zipfile (see testdata/README.md). Each must open, pass `checkLayout`, and give back every
//! entry, in central directory order, with the kind and bytes it was made from. The
//! `zig build interop` step checks the other direction, our writer against those tools.

const std = @import("std");
const Archive = @import("../Archive.zig");
const Entry = @import("../Entry.zig");
const CompressionMethod = @import("../format.zig").CompressionMethod;

const io = std.testing.io;
const gpa = std.testing.allocator;

const Want = struct {
    name: []const u8,
    kind: Entry.Kind = .file,
    /// The file's bytes, or a symlink's target.
    data: []const u8 = "",
    method: CompressionMethod = .stored,
    /// Flag bit 3: sizes and CRC in a data descriptor after the data (APPNOTE 4.3.9).
    descriptor: bool = false,
};

/// What gen-testdata.py gives the tools, as in its LOREM and TREE.
const lorem = "the quick brown fox jumps over the lazy dog\n" ** 20;
const hello = "hello\n";
const nested = "nested\n";

/// Opens `path`, runs `checkLayout`, and checks every entry against `want`.
fn expectFixture(path: []const u8, want: []const Want) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var archive = try Archive.openFile(&reader, .{});
    try archive.checkLayout(gpa);
    var count: usize = 0;
    while (try archive.next()) |entry| : (count += 1) {
        if (count >= want.len) return error.TestTooManyEntries;
        const w = want[count];
        errdefer std.debug.print("{s}: entry {d} ({s})\n", .{ path, count, w.name });

        var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.testing.expectEqualStrings(w.name, try archive.entryName(&entry, &name_buf));
        try std.testing.expectEqual(w.kind, entry.kind());
        try std.testing.expectEqual(w.method, entry.method);
        try std.testing.expectEqual(w.descriptor, entry.flags.data_descriptor);

        const got = try archive.readEntryAlloc(gpa, &entry, 1 << 16);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(w.data, got);
    }
    try std.testing.expectEqual(want.len, count);
}

test "interop fixture: zip -fz, ZIP64 extras on entries that don't need them" {
    try expectFixture("testdata/interop/zip_fz.zip", &.{
        .{ .name = "hello.txt", .data = hello },
        .{ .name = "lorem.txt", .data = lorem, .method = .deflate },
        .{ .name = "empty.txt" },
        .{ .name = "sub/", .kind = .directory },
        .{ .name = "sub/nested.txt", .data = nested },
    });
}

test "interop fixture: zip -y stores the symlink, not its target" {
    try expectFixture("testdata/interop/zip_symlink.zip", &.{
        .{ .name = "target.txt", .data = "pointed at\n" },
        .{ .name = "link", .kind = .symlink, .data = "target.txt" },
    });
}

test "interop fixture: zip - - from a pipe, ZIP64 local extra and 24-byte descriptor" {
    // Stdin was a pipe, so zip recorded its mode, 0o010600: a fifo, which `kind` reports
    // as `other` (extract writes it as a regular file).
    try expectFixture("testdata/interop/zip_pipe.zip", &.{
        .{ .name = "-", .kind = .other, .data = lorem, .method = .deflate, .descriptor = true },
    });
}

test "interop fixture: Python zipfile on an unseekable stream, descriptors on every entry" {
    try expectFixture("testdata/interop/python_stream.zip", &.{
        .{ .name = "deflated.txt", .data = lorem, .method = .deflate, .descriptor = true },
        .{ .name = "stored.txt", .data = hello, .descriptor = true },
        .{ .name = "empty.txt", .method = .deflate, .descriptor = true },
        // force_zip64: ZIP64 local extra and descriptor, plain central header.
        .{ .name = "zip64.txt", .data = lorem, .method = .deflate, .descriptor = true },
    });
}

test "interop fixture: 7z a -tzip, NTFS time extras, entries sorted by name" {
    try expectFixture("testdata/interop/7z.zip", &.{
        .{ .name = "empty.txt" },
        .{ .name = "hello.txt", .data = hello },
        .{ .name = "lorem.txt", .data = lorem, .method = .deflate },
        .{ .name = "sub/", .kind = .directory },
        .{ .name = "sub/nested.txt", .data = nested },
    });
}
