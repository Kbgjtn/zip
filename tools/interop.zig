//! `zig build interop` (design M16): archives from our writer, checked by other tools.
//! Not part of `zig build test`, since it needs those tools and is slower.
//!
//! Each archive is written to a temp file, then:
//! - `unzip -t` and `7z t` test every entry's data and CRC-32.
//! - Python's `zipfile.ZipFile.testzip()` does the same.
//! - `zipinfo` must list it; for the forced ZIP64 archive, `zipinfo -v` must show the
//!   ZIP64 extra (APPNOTE 4.5.3) and version 4.5 needed to extract (4.4.3.2).
//! - `std.zip.extract` writes it out, and every regular file must hold its data.
//!
//! A tool that isn't installed is skipped with a note. If none is, the test is skipped.
//! Runs as a test executable so the writer's test-only `force_zip64` is available.
const std = @import("std");
const zip = @import("zip");

const io = std.testing.io;
const gpa = std.testing.allocator;

const Item = struct {
    name: []const u8,
    data: []const u8 = "",
    kind: enum { bytes_stored, bytes_deflate, stream, stream_zip64, directory, symlink } = .bytes_deflate,
    comment: []const u8 = "",
};

/// Text that deflate shrinks, so deflated entries really are deflated.
const text = "the quick brown fox jumps over the lazy dog\n" ** 40;

/// Writes `items` with our writer. Caller frees the bytes.
fn written(items: []const Item, comment: []const u8, force_zip64: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var zw: zip.Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    zw.force_zip64 = force_zip64;
    try zw.setComment(comment);
    for (items) |it| {
        const mtime = 1_700_000_000;
        switch (it.kind) {
            .bytes_stored => try zw.addBytes(it.name, it.data, .{ .method = .stored, .mtime = mtime, .comment = it.comment }),
            .bytes_deflate => try zw.addBytes(it.name, it.data, .{ .mtime = mtime, .comment = it.comment }),
            .stream, .stream_zip64 => {
                var src: std.Io.Reader = .fixed(it.data);
                try zw.addStream(it.name, &src, .{ .mtime = mtime, .zip64 = it.kind == .stream_zip64, .comment = it.comment });
            },
            .directory => try zw.addDirectory(it.name, .{ .mtime = mtime }),
            .symlink => try zw.addSymlink(it.name, it.data, .{ .mtime = mtime }),
        }
    }
    try zw.finish();
    return out.toOwnedSlice();
}

/// Runs `argv` inside `cwd`. Returns its stdout (caller frees) if it exited 0, null if the tool isn't
/// installed, and fails the test otherwise, printing what the tool said.
fn runTool(cwd: std.Io.Dir, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv, .cwd = .{ .dir = cwd } }) catch |err|
        switch (err) {
            error.FileNotFound => {
                std.debug.print("interop: {s} not found, skipped\n", .{argv[0]});
                return null;
            },
            else => |e| return e,
        };

    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("interop: {s} failed ({any}):\n{s}{s}\n", .{ argv[0], result.term, result.stdout, result.stderr });
        return error.TestToolFailed;
    }
    return result.stdout;
}

/// Writes `items` to a temp file and puts it through every tool. Fails the test if any tool
/// that is installed refuses it; skips it if none is installed.
fn check(label: []const u8, items: []const Item, comment: []const u8, force_zip64: bool) !void {
    const bytes = try written(items, comment, force_zip64);
    defer gpa.free(bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zip", .data = bytes });

    var ran: usize = 0;
    const testzip =
        \\import sys, zipfile
        \\with zipfile.ZipFile(sys.argv[1]) as z:
        \\    bad = z.testzip()
        \\    sys.exit(f"bad entry {bad}" if bad else 0)
    ;
    const plain = [_][]const []const u8{
        &.{ "unzip", "-tqq", "a.zip" },
        &.{ "7z", "t", "-bd", "-bso0", "a.zip" },
        &.{ "python3", "-c", testzip, "a.zip" },
    };
    for (plain) |argv| {
        const out = try runTool(tmp.dir, argv) orelse continue;
        gpa.free(out);
        ran += 1;
    }

    const zipinfo: []const []const u8 = if (force_zip64)
        &.{ "zipinfo", "-v", "a.zip" }
    else
        &.{ "zipinfo", "a.zip" };

    if (try runTool(tmp.dir, zipinfo)) |out| {
        defer gpa.free(out);
        ran += 1;
        if (force_zip64) {
            const zip64_extras = std.mem.count(u8, out, "ID 0x0001 (PKWARE 64-bit sizes)");
            const version_45 = std.mem.count(u8, out, "minimum software version required to extract:   4.5");
            std.testing.expectEqual(items.len, zip64_extras) catch |err| {
                std.debug.print("interop: {s}: zipinfo -v shows {d} ZIP64 extras\n", .{ label, zip64_extras });
                return err;
            };
            try std.testing.expectEqual(items.len, version_45);
        }
    }

    try checkStdZip(tmp.dir, items);
    if (ran == 0) return error.SkipZigTest;
}

/// Extracts `a.zip` in `dir` with `std.zip` and checks every regular file it wrote. Symlinks
/// are left out: std.zip writes them as files holding the target.
fn checkStdZip(dir: std.Io.Dir, items: []const Item) !void {
    var file = try dir.openFile(io, "a.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var out = try dir.createDirPathOpen(io, "std", .{});
    defer out.close(io);
    try std.zip.extract(out, &reader, .{});

    for (items) |it| switch (it.kind) {
        .directory => {
            var d = try out.openDir(io, it.name, .{});
            d.close(io);
        },
        .symlink => {},
        else => {
            const got = try out.readFileAlloc(io, it.name, gpa, .unlimited);
            defer gpa.free(got);
            try std.testing.expectEqualSlices(u8, it.data, got);
        },
    };
}

/// A small tree that touches every kind of entry the writer makes.
const mixed = [_]Item{
    .{ .name = "stored.txt", .data = "hello\n", .kind = .bytes_stored, .comment = "a stored file" },
    .{ .name = "empty.txt", .kind = .bytes_stored },
    .{ .name = "dir/", .kind = .directory },
    .{ .name = "dir/deflated.txt", .data = text },
    .{ .name = "dir/caf\xc3\xa9.txt", .data = "bonjour\n" },
    .{ .name = "streamed.txt", .data = text, .kind = .stream, .comment = "streamed" },
    .{ .name = "streamed64.txt", .data = text, .kind = .stream_zip64 },
    .{ .name = "link", .data = "stored.txt", .kind = .symlink },
};

test "interop: stored entries" {
    try check("stored", &.{
        .{ .name = "a.txt", .data = "hello\n", .kind = .bytes_stored },
        .{ .name = "b/c.txt", .data = text, .kind = .bytes_stored },
        .{ .name = "empty.txt", .kind = .bytes_stored },
    }, "", false);
}

test "interop: deflated entries with comments" {
    try check("deflated", &.{
        .{ .name = "a.txt", .data = text, .comment = "first" },
        .{ .name = "b.txt", .data = text ++ "and more\n" },
    }, "archive comment", false);
}

test "interop: streamed entries, with and without ZIP64 descriptors" {
    try check("streamed", &.{
        .{ .name = "s.txt", .data = text, .kind = .stream },
        .{ .name = "empty.txt", .kind = .stream },
        .{ .name = "s64.txt", .data = text, .kind = .stream_zip64 },
    }, "", false);
}

test "interop: every entry kind" {
    try check("mixed", &mixed, "mixed", false);
}

test "interop: forced ZIP64 on every entry and the end records" {
    try check("forced ZIP64", &mixed, "forced", true);
}

test "interop: 65,536 entries need the ZIP64 end records" {
    const n = 0x1_0000;
    const items = try gpa.alloc(Item, n);
    defer gpa.free(items);
    const names = try gpa.alloc([8]u8, n);
    defer gpa.free(names);
    for (items, names, 0..) |*it, *name, i| {
        _ = std.fmt.bufPrint(name, "f{x:0>5}.t", .{i}) catch unreachable;
        it.* = .{ .name = name, .data = name, .kind = .bytes_stored };
    }
    try check("65,536 entries", items, "", false);
}
