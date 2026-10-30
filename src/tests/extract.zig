//! `Archive.extractEntry` tests: directory entries, bad names, and each `file_exists_behavior`
//! for top-level and nested paths. Archives are made with `testing/builder.zig`.
const std = @import("std");
const Builder = @import("../testing/builder.zig");
const Archive = @import("../Archive.zig");
const Entry = @import("../Entry.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Builds a one-entry stored archive. `size` overrides both sizes in the headers.
fn oneStored(b: *Builder, name: []const u8, data: []const u8, size: ?u32) !void {
    const crc = std.hash.Crc32.hash(data);
    const len: u32 = size orelse @intCast(data.len);
    try b.local(.{ .crc32 = crc, .compressed_size = len, .uncompressed_size = len, .name = name });
    try b.raw(data);
    const cd_offset = b.pos();
    try b.central(.{ .crc32 = crc, .compressed_size = len, .uncompressed_size = len, .name = name });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
}

/// Extracts every entry of `bytes` into `dst`.
fn extractAll(bytes: []const u8, dst: std.Io.Dir, options: Entry.ExtractOptions) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    while (try iter.next()) |fd| try iter.extractEntry(io, &fd, dst, options);
}

fn expectFile(dir: std.Io.Dir, path: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(io, path, gpa, .limited(64));
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "extract: directory entry creates a directory" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneStored(&b, "d/", "", null);

    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try extractAll(b.bytes(), out.dir, .{});
    var d = try out.dir.openDir(io, "d", .{});
    d.close(io);
}

test "extract: directory entry with a nonzero size is rejected" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneStored(&b, "d/", "hi\n", null);

    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try std.testing.expectError(error.ZipBadDirectorySize, extractAll(b.bytes(), out.dir, .{}));
}

test "extract: file_exists_behavior for top-level and nested paths" {
    // Top-level names go through dst.createFile; nested ones through the parent directory.
    for ([_][]const u8{ "a.txt", "sub/a.txt" }) |path| {
        var b: Builder = .init(gpa);
        defer b.deinit();
        try oneStored(&b, path, "new\n", null);

        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        if (std.fs.path.dirname(path)) |dir| try out.dir.createDirPath(io, dir);
        try out.dir.writeFile(io, .{ .sub_path = path, .data = "old\n" });

        try std.testing.expectError(error.PathAlreadyExists, extractAll(b.bytes(), out.dir, .{}));
        try expectFile(out.dir, path, "old\n");

        try extractAll(b.bytes(), out.dir, .{ .file_exists_behavior = .skip });
        try expectFile(out.dir, path, "old\n");

        try extractAll(b.bytes(), out.dir, .{ .file_exists_behavior = .overwrite });
        try expectFile(out.dir, path, "new\n");
    }
}

test "extract: unsafe names are ZipUnsafePath" {
    for ([_][]const u8{ "/etc/x", "a/../../x", "a/../b", "", "./", "C:x", "a\x00b" }) |path| {
        var b: Builder = .init(gpa);
        defer b.deinit();
        try oneStored(&b, path, "x", null);

        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        try std.testing.expectError(error.ZipUnsafePath, extractAll(b.bytes(), out.dir, .{}));
    }
}

/// Builds a one-entry archive of "a.txt" whose headers say `flags` and `method`.
fn oneRefused(b: *Builder, flags: u16, method: u16) !void {
    const data = "hi\n";
    const crc = std.hash.Crc32.hash(data);
    try b.local(.{ .flags = flags, .method = method, .crc32 = crc, .compressed_size = data.len, .uncompressed_size = data.len, .name = "a.txt" });
    try b.raw(data);
    const cd_offset = b.pos();
    try b.central(.{ .flags = flags, .method = method, .crc32 = crc, .compressed_size = data.len, .uncompressed_size = data.len, .name = "a.txt" });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
}

/// Checks that extracting `bytes` fails with exactly `expected` and leaves no "a.txt".
fn expectRefusedNoFile(expected: anyerror, bytes: []const u8) !void {
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try std.testing.expectError(expected, extractAll(bytes, out.dir, .{}));
    try std.testing.expectError(error.FileNotFound, out.dir.access(io, "a.txt", .{}));
}

test "extract: an encrypted entry is refused before a file is created" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneRefused(&b, 1, 0);
    try expectRefusedNoFile(error.ZipEncrypted, b.bytes());
}

test "extract: an unsupported method is refused before a file is created" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneRefused(&b, 0, 99);
    try expectRefusedNoFile(error.ZipUnsupportedMethod, b.bytes());
}
