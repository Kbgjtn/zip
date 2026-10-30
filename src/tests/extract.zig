//! `Archive.extractEntry` tests: directory entries, bad names, and each `file_exists_behavior`
//! for top-level and nested paths. `Archive.extractAll` tests: modes, mtimes, the symlink
//! policy, hostile archives that must fail before anything is written, and the EPUB
//! fixture against `unzip -d`. Archives are made with `testing/Builder.zig` and our writer.
const std = @import("std");
const Builder = @import("../testing/Builder.zig");
const Archive = @import("../Archive.zig");
const Entry = @import("../Entry.zig");
const Writer = @import("../Writer.zig");
const builtin = @import("builtin");

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

/// Extracts every entry of `bytes` into `dest`, one `extractEntry` call each.
fn extractEach(bytes: []const u8, dest: std.Io.Dir, options: Entry.ExtractOptions) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Archive.openFile(&reader, .{});
    while (try iter.next()) |fd| try iter.extractEntry(io, &fd, dest, options);
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
    try extractEach(b.bytes(), out.dir, .{});
    var d = try out.dir.openDir(io, "d", .{});
    d.close(io);
}

test "extract: directory entry with a nonzero size is rejected" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneStored(&b, "d/", "hi\n", null);

    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try std.testing.expectError(error.ZipBadDirectorySize, extractEach(b.bytes(), out.dir, .{}));
}

test "extract: file_exists_behavior for top-level and nested paths" {
    // Top-level names go through dest.createFile; nested ones through the parent directory.
    for ([_][]const u8{ "a.txt", "sub/a.txt" }) |path| {
        var b: Builder = .init(gpa);
        defer b.deinit();
        try oneStored(&b, path, "new\n", null);

        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        if (std.fs.path.dirname(path)) |dir| try out.dir.createDirPath(io, dir);
        try out.dir.writeFile(io, .{ .sub_path = path, .data = "old\n" });

        try std.testing.expectError(error.PathAlreadyExists, extractEach(b.bytes(), out.dir, .{}));
        try expectFile(out.dir, path, "old\n");

        try extractEach(b.bytes(), out.dir, .{ .file_exists_behavior = .skip });
        try expectFile(out.dir, path, "old\n");

        try extractEach(b.bytes(), out.dir, .{ .file_exists_behavior = .overwrite });
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
        try std.testing.expectError(error.ZipUnsafePath, extractEach(b.bytes(), out.dir, .{}));
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
    try std.testing.expectError(expected, extractEach(bytes, out.dir, .{}));
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

/// One entry for `written`: a file with `data`, a folder when `name` ends in '/', or a
/// symlink when `target` is set. Unsafe targets are allowed, so hostile rows can be built.
const Item = struct {
    name: []const u8,
    data: []const u8 = "",
    target: ?[]const u8 = null,
    mode: ?u32 = null,
    mtime: i64 = 0,
};

/// Writes `items` with our writer. Caller frees the bytes.
fn written(items: []const Item) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    for (items) |it| {
        if (it.target) |target| {
            try zw.addSymlink(it.name, target, .{ .mtime = it.mtime, .allow_unsafe_target = true });
        } else if (it.name[it.name.len - 1] == '/') {
            try zw.addDirectory(it.name, .{ .mtime = it.mtime, .mode = it.mode orelse 0o755 });
        } else {
            try zw.addBytes(it.name, it.data, .{ .mtime = it.mtime, .mode = it.mode orelse 0o644 });
        }
    }
    try zw.finish();
    return out.toOwnedSlice();
}

fn extractAllOf(bytes: []const u8, dest: std.Io.Dir, options: Archive.ExtractAllOptions) !void {
    var archive = try Archive.openMemory(bytes, .{});
    try archive.extractAll(gpa, io, dest, options);
}

/// Fails unless `dir` is empty: a refused archive must not have written anything.
fn expectEmpty(dir: std.Io.Dir) !void {
    var d = try dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    if (try it.next(io)) |entry| {
        std.debug.print("unexpected {s} in the output folder\n", .{entry.name});
        return error.TestExpectedEmptyDir;
    }
}

/// Extracts `items` with `options` and expects `expected` with nothing written.
fn expectRefusedEmpty(expected: anyerror, items: []const Item, options: Archive.ExtractAllOptions) !void {
    const bytes = try written(items);
    defer gpa.free(bytes);
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try std.testing.expectError(expected, extractAllOf(bytes, out.dir, options));
    try expectEmpty(out.dir);
}

test "extract: extractAll sets Unix modes and mtimes on files and folders" {
    if (comptime !@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    const bytes = try written(&.{
        .{ .name = "d/", .mode = 0o750, .mtime = 1_000_000_000 },
        .{ .name = "d/run.sh", .data = "#!/bin/sh\n", .mode = 0o755, .mtime = 1_100_000_000 },
        .{ .name = "top.txt", .data = "hi\n", .mode = 0o600, .mtime = 1_200_000_000 },
        // A folder entry listed after its contents still gets its attributes last.
        .{ .name = "late/x.txt", .data = "x\n" },
        .{ .name = "late/", .mode = 0o700, .mtime = 1_300_000_000 },
    });
    defer gpa.free(bytes);
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try extractAllOf(bytes, out.dir, .{});

    const Want = struct { path: []const u8, mode: u32, mtime: i64 };
    for ([_]Want{
        .{ .path = "d", .mode = 0o750, .mtime = 1_000_000_000 },
        .{ .path = "d/run.sh", .mode = 0o755, .mtime = 1_100_000_000 },
        .{ .path = "top.txt", .mode = 0o600, .mtime = 1_200_000_000 },
        .{ .path = "late", .mode = 0o700, .mtime = 1_300_000_000 },
    }) |w| {
        const st = try out.dir.statFile(io, w.path, .{});
        try std.testing.expectEqual(w.mode, @as(u32, @intCast(st.permissions.toMode())) & 0o7777);
        try std.testing.expectEqual(@as(i96, w.mtime) * std.time.ns_per_s, st.mtime.nanoseconds);
    }
    try expectFile(out.dir, "d/run.sh", "#!/bin/sh\n");
}

test "extract: extractEntry sets Unix modes and mtimes too, unless asked not to" {
    if (comptime !@hasDecl(std.Io.File.Permissions, "fromMode")) return error.SkipZigTest;
    // The folder comes after its file: extractEntry sets a folder's attributes right away.
    const bytes = try written(&.{
        .{ .name = "d/run.sh", .data = "#!/bin/sh\n", .mode = 0o755, .mtime = 1_100_000_000 },
        .{ .name = "d/", .mode = 0o750, .mtime = 1_000_000_000 },
    });
    defer gpa.free(bytes);
    {
        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        try extractEach(bytes, out.dir, .{});
        const Want = struct { path: []const u8, mode: u32, mtime: i64 };
        for ([_]Want{
            .{ .path = "d", .mode = 0o750, .mtime = 1_000_000_000 },
            .{ .path = "d/run.sh", .mode = 0o755, .mtime = 1_100_000_000 },
        }) |w| {
            const st = try out.dir.statFile(io, w.path, .{});
            try std.testing.expectEqual(w.mode, @as(u32, @intCast(st.permissions.toMode())) & 0o7777);
            try std.testing.expectEqual(@as(i96, w.mtime) * std.time.ns_per_s, st.mtime.nanoseconds);
        }
    }
    {
        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        try extractEach(bytes, out.dir, .{ .apply_unix_mode = false, .apply_mtime = false });
        const st = try out.dir.statFile(io, "d/run.sh", .{});
        try std.testing.expect(st.mtime.nanoseconds != @as(i96, 1_100_000_000) * std.time.ns_per_s);
    }
}

test "extract: extractAll with apply_unix_mode and apply_mtime off leaves OS defaults" {
    const bytes = try written(&.{.{ .name = "a.txt", .data = "a\n", .mode = 0o600, .mtime = 1_000_000_000 }});
    defer gpa.free(bytes);
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try extractAllOf(bytes, out.dir, .{ .apply_unix_mode = false, .apply_mtime = false });
    const st = try out.dir.statFile(io, "a.txt", .{});
    try std.testing.expect(st.mtime.nanoseconds != @as(i96, 1_000_000_000) * std.time.ns_per_s);
}

test "extract: extractAll refuses symlinks by default, before writing anything" {
    try expectRefusedEmpty(error.ZipUnsafeSymlink, &.{
        .{ .name = "a.txt", .data = "a\n" },
        .{ .name = "link", .target = "a.txt" },
    }, .{});
}

test "extract: extractAll and extractEntry skip symlinks under .skip" {
    const bytes = try written(&.{
        .{ .name = "link", .target = "a.txt" },
        .{ .name = "a.txt", .data = "a\n" },
    });
    defer gpa.free(bytes);
    {
        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        try extractAllOf(bytes, out.dir, .{ .symlinks = .skip });
        try expectFile(out.dir, "a.txt", "a\n");
        try std.testing.expectError(error.FileNotFound, out.dir.access(io, "link", .{}));
    }
    {
        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        var archive = try Archive.openMemory(bytes, .{});
        const link = (try archive.next()).?;
        try std.testing.expectError(error.ZipUnsafeSymlink, archive.extractEntry(io, &link, out.dir, .{}));
        try archive.extractEntry(io, &link, out.dir, .{ .symlinks = .skip });
        try expectEmpty(out.dir);
    }
}

test "extract: extractAll creates safe symlinks under .create_safe" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const bytes = try written(&.{
        .{ .name = "lib/libz.so", .target = "libz.so.1" },
        .{ .name = "lib/libz.so.1", .data = "elf\n" },
        .{ .name = "up", .target = "lib/./../lib/libz.so" },
        .{ .name = "dangling", .target = "nowhere" },
    });
    defer gpa.free(bytes);
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    try extractAllOf(bytes, out.dir, .{ .symlinks = .create_safe });

    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("libz.so.1", buf[0..try out.dir.readLink(io, "lib/libz.so", &buf)]);
    try std.testing.expectEqualStrings("lib/./../lib/libz.so", buf[0..try out.dir.readLink(io, "up", &buf)]);
    try std.testing.expectEqualStrings("nowhere", buf[0..try out.dir.readLink(io, "dangling", &buf)]);
    try expectFile(out.dir, "up", "elf\n");
}

test "hostile: the unsafe names of design 12.4 fail extractAll before writing" {
    const Row = struct { name: []const u8, want: anyerror };
    for ([_]Row{
        .{ .name = "../x", .want = error.ZipUnsafePath },
        .{ .name = "/etc/x", .want = error.ZipUnsafePath },
        .{ .name = "a/../../x", .want = error.ZipUnsafePath },
        // A '\' is refused before the drive or ".." it would spell (APPNOTE 4.4.17.1).
        .{ .name = "C:\\x", .want = error.ZipBackslashInPath },
        .{ .name = "a\\..\\x", .want = error.ZipBackslashInPath },
        .{ .name = "a\x00b", .want = error.ZipUnsafePath },
    }) |row| {
        var b: Builder = .init(gpa);
        defer b.deinit();
        try oneStored(&b, row.name, "x", null);
        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        try std.testing.expectError(row.want, extractAllOf(b.bytes(), out.dir, .{}));
        try expectEmpty(out.dir);
    }
}

test "hostile: symlink a -> /etc then file a/passwd writes nothing" {
    const items = [_]Item{
        .{ .name = "a", .target = "/etc" },
        .{ .name = "a/passwd", .data = "root::0:0::/:/bin/sh\n" },
    };
    // checkLayout sees a file under the link's path first...
    try expectRefusedEmpty(error.ZipPathConflict, &items, .{ .symlinks = .create_safe });
    // ...and without it, the symlink policy and the under-a-link check still refuse it.
    try expectRefusedEmpty(error.ZipUnsafeSymlink, &items, .{ .check_layout = false });
    try expectRefusedEmpty(error.ZipUnsafeSymlink, &items, .{ .symlinks = .create_safe, .check_layout = false });
}

test "hostile: unsafe symlink targets fail .create_safe before writing anything" {
    const rows = [_][]const Item{
        // Climbs out of the destination.
        &.{.{ .name = "a", .target = "../x" }},
        &.{.{ .name = "d/a", .target = "../../x" }},
        &.{.{ .name = "a", .target = "b/../../x" }},
        // Drive prefix, backslash, control byte, empty.
        &.{.{ .name = "a", .target = "C:x" }},
        &.{.{ .name = "a", .target = "x\\..\\..\\y" }},
        &.{.{ .name = "a", .target = "x\ty" }},
        // A safe link, but a file is written through it.
        &.{ .{ .name = "a", .target = "b" }, .{ .name = "a/passwd", .data = "x" } },
        // A link inside a link lands wherever the outer one points.
        &.{ .{ .name = "y", .target = "sub" }, .{ .name = "y/z", .target = "x" } },
        // y points up a level, so "e/y/../../.." escapes though the text alone stays inside.
        &.{ .{ .name = "d/e/y", .target = ".." }, .{ .name = "d/z", .target = "e/y/../../.." } },
    };
    // Without checkLayout, which would call the last three rows a ZipPathConflict, so the
    // symlink checks themselves are what refuses them.
    for (rows) |items| {
        try expectRefusedEmpty(error.ZipUnsafeSymlink, items, .{ .symlinks = .create_safe, .check_layout = false });
    }
}

test "hostile: extractAll checks every name before writing any" {
    // The unsafe name is last, so an extractor that writes as it goes would have made ok.txt.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const names = [_][]const u8{ "ok.txt", "../x" };
    var offsets: [names.len]u64 = undefined;
    for (names, 0..) |n, i| offsets[i] = try b.entry(n, "x");
    const cd_offset = b.pos();
    for (names, 0..) |n, i| {
        try b.central(.{ .crc32 = std.hash.Crc32.hash("x"), .compressed_size = 1, .uncompressed_size = 1, .offset = @intCast(offsets[i]), .name = n });
    }
    try b.eocd(.{ .entries = names.len, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });

    for ([_]bool{ true, false }) |check_layout| {
        var out = std.testing.tmpDir(.{});
        defer out.cleanup();
        try std.testing.expectError(error.ZipUnsafePath, extractAllOf(b.bytes(), out.dir, .{ .check_layout = check_layout }));
        try expectEmpty(out.dir);
    }
}

test "hostile: duplicate names fail extractAll's layout check before writing" {
    try expectRefusedEmpty(error.ZipDuplicateName, &.{
        .{ .name = "a/b.txt", .data = "one\n" },
        .{ .name = "a/", .mode = 0o755 },
        .{ .name = "a/b.txt", .data = "two\n" },
    }, .{});
}

test "hostile: a symlink or file where a folder is needed fails before writing" {
    // checkLayout catches the symlink even under .skip, where nothing else looks at it.
    for ([_]Archive.SymlinkPolicy{ .refuse, .skip, .create_safe }) |policy| {
        try expectRefusedEmpty(error.ZipPathConflict, &.{
            .{ .name = "ok.txt", .data = "ok\n" },
            .{ .name = "a", .target = "elsewhere" },
            .{ .name = "a/b", .data = "x" },
        }, .{ .symlinks = policy });
    }
    try expectRefusedEmpty(error.ZipPathConflict, &.{
        .{ .name = "a", .data = "file\n" },
        .{ .name = "a/b", .data = "x" },
    }, .{});
}

test "extract: extractAll leaves the listing position where it was" {
    const bytes = try written(&.{ .{ .name = "a.txt", .data = "a\n" }, .{ .name = "b.txt", .data = "b\n" } });
    defer gpa.free(bytes);
    var out = std.testing.tmpDir(.{});
    defer out.cleanup();
    var archive = try Archive.openMemory(bytes, .{});
    _ = (try archive.next()).?;
    try archive.extractAll(gpa, io, out.dir, .{});
    var name_buf: [16]u8 = undefined;
    const second = (try archive.next()).?;
    try std.testing.expectEqualStrings("b.txt", try archive.entryName(&second, &name_buf));
}

/// Runs `argv` and fails unless it exits 0 with nothing on stdout, which is what `unzip -q`
/// and `diff -r` print when all is well. Stdout is compared as text, so a `diff -r` mismatch
/// shows up in the failure.
fn expectQuietRun(argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "extract: extractAll of the EPUB matches unzip -d under diff -r" {
    const unzip = "/usr/bin/unzip";
    const diff = "/usr/bin/diff";
    for ([_][]const u8{ unzip, diff }) |tool| {
        std.Io.Dir.accessAbsolute(io, tool, .{}) catch return error.SkipZigTest;
    }
    const epub = "testdata/accessible_epub_3.epub";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ours_dir = try tmp.dir.createDirPathOpen(io, "ours", .{});
    defer ours_dir.close(io);

    var file = try std.Io.Dir.cwd().openFile(io, epub, .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var archive = try Archive.openFile(&reader, .{});
    try archive.extractAll(gpa, io, ours_dir, .{});

    // The tools run from the same working directory as the test, where tmpDir lives.
    var ours_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ours = try std.fmt.bufPrint(&ours_buf, ".zig-cache/tmp/{s}/ours", .{tmp.sub_path});
    var theirs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const theirs = try std.fmt.bufPrint(&theirs_buf, ".zig-cache/tmp/{s}/unzip", .{tmp.sub_path});

    try expectQuietRun(&.{ unzip, "-q", "-d", theirs, epub });
    // Same paths, same kinds (a file where the other has a folder is reported) and same bytes.
    try expectQuietRun(&.{ diff, "-r", ours, theirs });
}
