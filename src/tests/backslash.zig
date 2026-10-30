//! `OpenOptions.allow_backslashes`: names written with '\' by old Windows tools. Refused by
//! default (APPNOTE 4.4.17.1 requires '/'); with the option, '\' is a separator in
//! `cleanEntryName`, `checkLayout`, `extractEntry` and `extractAll` alike, and every other
//! path rule still holds. Archives are built with `testing/Builder.zig`, since our writer
//! refuses such names.
const std = @import("std");
const Archive = @import("../Archive.zig");
const Builder = @import("../testing/Builder.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

const lenient: Archive.OpenOptions = .{ .allow_backslashes = true };

/// Builds a stored archive with one entry per name, made by MS-DOS (version made by 2.0,
/// host 0) like the Windows tools that wrote '\'. A name ending in '/' or '\' is an empty
/// folder (attribute 0x10), the others are files (0x20) holding their own name as data.
fn build(b: *Builder, names: []const []const u8) !void {
    var offsets: [8]u64 = undefined;
    for (names, 0..) |n, i| offsets[i] = try b.entry(n, dataOf(n));
    const cd_offset = b.pos();
    for (names, 0..) |n, i| {
        const d = dataOf(n);
        try b.central(.{
            .crc32 = std.hash.Crc32.hash(d),
            .compressed_size = @intCast(d.len),
            .uncompressed_size = @intCast(d.len),
            .offset = @intCast(offsets[i]),
            .version_made_by = 20,
            .external_attributes = if (d.len == 0) 0x10 else 0x20,
            .name = n,
        });
    }
    try b.eocd(.{ .entries = @intCast(names.len), .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
}

fn dataOf(name: []const u8) []const u8 {
    const last = name[name.len - 1];
    return if (last == '/' or last == '\\') "" else name;
}

/// Cleans the name of the first entry of an archive holding `name` alone.
fn cleanOne(name: []const u8, options: Archive.OpenOptions, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try build(&b, &.{name});
    var archive = try Archive.openMemory(b.bytes(), options);
    const entry = (try archive.next()).?;
    return archive.cleanEntryName(&entry, buffer);
}

fn checkLayoutOf(names: []const []const u8, options: Archive.OpenOptions) !void {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try build(&b, names);
    const archive = try Archive.openMemory(b.bytes(), options);
    try archive.checkLayout(gpa);
}

test "backslash: names with '\\' are refused by default" {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.ZipBackslashInPath, cleanOne("dir\\file.txt", .{}, &buf));
    try std.testing.expectError(error.ZipBackslashInPath, checkLayoutOf(&.{"dir\\file.txt"}, .{}));

    var b: Builder = .init(gpa);
    defer b.deinit();
    try build(&b, &.{"dir\\file.txt"});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = try Archive.openMemory(b.bytes(), .{});
    try std.testing.expectError(error.ZipBackslashInPath, archive.extractAll(gpa, io, tmp.dir, .{}));
}

test "backslash: a trailing '\\' is a directory only with allow_backslashes" {
    // Attribute 0x20, a file, so only the name can make it a directory.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const offset = try b.entry("dir\\", "");
    const cd_offset = b.pos();
    try b.central(.{ .version_made_by = 20, .external_attributes = 0x20, .offset = @intCast(offset), .name = "dir\\" });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
    var strict = try Archive.openMemory(b.bytes(), .{});
    try std.testing.expectEqual(.file, (try strict.next()).?.kind());
    var archive = try Archive.openMemory(b.bytes(), lenient);
    const entry = (try archive.next()).?;
    try std.testing.expectEqual(.directory, entry.kind());
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("dir/", try archive.cleanEntryName(&entry, &buf));
}

test "backslash: allow_backslashes cleans '\\' to '/' and entryName keeps the stored bytes" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try build(&b, &.{"dir\\sub\\file.txt"});
    var archive = try Archive.openMemory(b.bytes(), lenient);
    const entry = (try archive.next()).?;
    var clean_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("dir/sub/file.txt", try archive.cleanEntryName(&entry, &clean_buf));
    var raw_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("dir\\sub\\file.txt", try archive.entryName(&entry, &raw_buf));
}

test "backslash: allow_backslashes still refuses traversal, absolute names and drives" {
    const names = [_][]const u8{ "\\x", "\\\\server\\share\\x", "..\\x", "a\\..\\..\\x", "a\\..\\x", "C:\\x", "c:x\\y", ".\\..\\x" };
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (names) |n| {
        std.testing.expectError(error.ZipUnsafePath, cleanOne(n, lenient, &buf)) catch |err| {
            std.debug.print("name: {s}\n", .{n});
            return err;
        };
        try std.testing.expectError(error.ZipUnsafePath, checkLayoutOf(&.{n}, lenient));
    }
}

test "backslash: checkLayout sees 'a\\b' and 'a/b' as one path" {
    try std.testing.expectError(error.ZipDuplicateName, checkLayoutOf(&.{ "a\\b", "a/b" }, lenient));
    try std.testing.expectError(error.ZipDuplicateName, checkLayoutOf(&.{ "d\\", "d" }, lenient));
    try std.testing.expectError(error.ZipPathConflict, checkLayoutOf(&.{ "a", "a\\b" }, lenient));
    try std.testing.expectError(error.ZipPathConflict, checkLayoutOf(&.{ "a\\b\\c", "a/b" }, lenient));
    try checkLayoutOf(&.{ "a\\", "a\\b", "a/c\\d" }, lenient);
}

test "backslash: extractAll and extractEntry write '\\' names as folders" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try build(&b, &.{ "dir\\", "dir\\file.txt", "dir\\sub\\deep.txt" });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var archive = try Archive.openMemory(b.bytes(), lenient);
    try archive.extractAll(gpa, io, tmp.dir, .{});
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("dir\\file.txt", try tmp.dir.readFile(io, "dir/file.txt", &buf));
    try std.testing.expectEqualStrings("dir\\sub\\deep.txt", try tmp.dir.readFile(io, "dir/sub/deep.txt", &buf));

    var one = std.testing.tmpDir(.{});
    defer one.cleanup();
    var again = try Archive.openMemory(b.bytes(), lenient);
    while (try again.next()) |entry| try again.extractEntry(io, &entry, one.dir, .{});
    try std.testing.expectEqualStrings("dir\\sub\\deep.txt", try one.dir.readFile(io, "dir/sub/deep.txt", &buf));
}

test "backslash: openFile and openFileAlloc carry allow_backslashes" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try build(&b, &.{"dir\\file.txt"});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = b.bytes() });
    var file = try tmp.dir.openFile(io, "in.zip", .{});
    defer file.close(io);
    var file_buf: [256]u8 = undefined;
    var clean_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var reader = file.reader(io, &file_buf);
    var plain = try Archive.openFile(&reader, lenient);
    const e1 = (try plain.next()).?;
    try std.testing.expectEqualStrings("dir/file.txt", try plain.cleanEntryName(&e1, &clean_buf));

    reader = file.reader(io, &file_buf);
    var alloc = try Archive.openFileAlloc(gpa, &reader, lenient);
    defer alloc.deinit(gpa);
    const e2 = (try alloc.next()).?;
    try std.testing.expectEqualStrings("dir/file.txt", try alloc.cleanEntryName(&e2, &clean_buf));
}
