//! Writer round-trip fuzz target (design M10): random sequences of `addBytes`, `addStream`
//! (with and without ZIP64), `addDirectory` and `addSymlink`, with random names, sizes,
//! contents and mtimes. Every archive must read back through the Iterator with the same
//! names and bytes, in order.
//!
//! - `zig build test` runs a fixed set of seeded inputs, so normal runs cover it too.
//! - `zig build test --fuzz` hands `roundTrip` to the fuzzer, which runs it until stopped.
const std = @import("std");
const Writer = @import("../writer.zig");
const Iterator = @import("../iterator.zig").Iterator;
const Smith = std.testing.Smith;

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Caps that keep one input fast: a fuzzer wants thousands of runs a second.
const max_entries: u8 = 12;
const max_name_len = 24;
const max_data_len = 80 << 10;

/// Path characters, weighted toward letters. Includes '/' and '.' so names like "a/../b",
/// "/x" and "a//b" come up and exercise `validateName`.
const name_alphabet = "abcdefghij0123456789abcdefghij._-/";

const Kind = enum { bytes_stored, bytes_deflate, stream, stream_zip64, directory, symlink };

/// Where the target's choices come from: the fuzzer's `Smith`, or a seeded PRNG.
/// Smith alone can't drive the seeded test: on plain byte inputs it turns any out-of-range
/// integer into the range minimum, so nearly every choice would be 0 and archives empty.
const Source = union(enum) {
    smith: *Smith,
    rng: std.Random,

    fn range(self: Source, comptime T: type, at_least: T, at_most: T) T {
        return switch (self) {
            .smith => |s| s.valueRangeAtMost(T, at_least, at_most),
            .rng => |r| r.intRangeAtMost(T, at_least, at_most),
        };
    }

    fn value(self: Source, comptime T: type) T {
        return switch (self) {
            .smith => |s| s.value(T),
            .rng => |r| switch (@typeInfo(T)) {
                .bool => r.boolean(),
                .@"enum" => r.enumValue(T),
                else => r.int(T),
            },
        };
    }

    /// True about one time in `1 + false_weight / true_weight`.
    fn chance(self: Source, false_weight: u32, true_weight: u32) bool {
        return switch (self) {
            .smith => |s| s.boolWeighted(false_weight, true_weight),
            .rng => |r| r.uintLessThan(u32, false_weight + true_weight) >= false_weight,
        };
    }

    fn index(self: Source, len: usize) usize {
        return switch (self) {
            .smith => |s| s.index(len),
            .rng => |r| r.uintLessThan(usize, len),
        };
    }

    fn bytes(self: Source, out: []u8) void {
        switch (self) {
            .smith => |s| s.bytes(out),
            .rng => |r| r.bytes(out),
        }
    }
};

/// What the archive should hold for one accepted add call.
const Expected = struct {
    name: []const u8,
    data: []const u8,
};

/// Fills `buf` with a random name from `name_alphabet` and returns the used part.
/// May be empty or unsafe; the writer decides.
fn randomName(src: Source, buf: []u8) []u8 {
    const len = src.range(u32, 0, @intCast(buf.len));
    for (buf[0..len]) |*c| c.* = name_alphabet[src.index(name_alphabet.len)];
    return buf[0..len];
}

/// Random entry data: mostly small, sometimes past the writer's 8 KiB buffer and deflate's
/// window. Either raw fuzz bytes (deflate falls back to stored) or a short repeated pattern
/// (deflate wins).
fn randomData(src: Source) ![]u8 {
    const len = if (src.chance(3, 1))
        src.range(u32, 0, max_data_len)
    else
        src.range(u32, 0, 300);
    const data = try gpa.alloc(u8, len);
    errdefer gpa.free(data);
    if (src.value(bool)) {
        src.bytes(data);
    } else {
        var pattern: [7]u8 = undefined;
        src.bytes(&pattern);
        const period = src.range(u32, 1, pattern.len);
        for (data, 0..) |*c, i| c.* = pattern[i % period];
    }
    return data;
}

/// The writer's documented rejections for bad names and targets. They come before anything
/// is written, so the writer stays usable and the entry is simply not in the archive.
fn isRejection(err: anyerror) bool {
    return err == error.InvalidName or
        err == error.InvalidSymlinkTarget or
        err == error.UnsafeSymlinkTarget;
}

/// One fuzz input: build an archive from the fuzzer's choices, then read it back and compare.
fn roundTrip(_: void, smith: *Smith) anyerror!void {
    _ = try roundTripCount(.{ .smith = smith });
}

/// `roundTrip`, returning how many entries the archive held, so the seeded test can check
/// that inputs aren't all rejected names.
fn roundTripCount(src: Source) !usize {
    var expected: std.ArrayList(Expected) = .empty;
    defer {
        for (expected.items) |e| {
            gpa.free(e.name);
            gpa.free(e.data);
        }
        expected.deinit(gpa);
    }

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    {
        var zw: Writer = undefined;
        try zw.init(gpa, &out.writer);
        defer zw.deinit();

        const adds = src.range(u8, 0, max_entries);
        for (0..adds) |_| {
            var name_buf: [max_name_len]u8 = undefined;
            const name = randomName(src, &name_buf);
            const mtime = src.value(i64);
            const data = try randomData(src);
            var keep = false;
            defer if (!keep) gpa.free(data);

            const kind = src.value(Kind);
            const result = switch (kind) {
                .bytes_stored => zw.addBytes(name, data, .{ .method = .stored, .mtime = mtime }),
                .bytes_deflate => zw.addBytes(name, data, .{ .mtime = mtime }),
                .stream, .stream_zip64 => blk: {
                    var reader: std.Io.Reader = .fixed(data);
                    break :blk zw.addStream(name, &reader, .{ .mtime = mtime, .zip64 = kind == .stream_zip64 });
                },
                .directory => zw.addDirectory(name, .{ .mtime = mtime }),
                // Random bytes would mostly be rejected for NUL, so the target is a random name too.
                .symlink => {
                    var target_buf: [max_name_len]u8 = undefined;
                    const target = randomName(src, &target_buf);
                    gpa.free(data);
                    keep = true;
                    const owned = try gpa.dupe(u8, target);
                    zw.addSymlink(name, target, .{ .mtime = mtime }) catch |err| {
                        gpa.free(owned);
                        if (isRejection(err)) continue;
                        return err;
                    };
                    try appendExpected(&expected, name, owned);
                    continue;
                },
            };
            result catch |err| {
                if (isRejection(err)) continue;
                return err;
            };

            // A directory holds no data, and its name gets a trailing '/' if it had none.
            if (kind == .directory) {
                const dir_name = if (std.mem.endsWith(u8, name, "/"))
                    try gpa.dupe(u8, name)
                else
                    try std.mem.concat(gpa, u8, &.{ name, "/" });
                errdefer gpa.free(dir_name);
                const empty = try gpa.alloc(u8, 0);
                try expected.append(gpa, .{ .name = dir_name, .data = empty });
                continue;
            }
            keep = true;
            appendExpected(&expected, name, data) catch |err| {
                gpa.free(data);
                return err;
            };
        }
        try zw.finish();
    }

    try expectReadBack(out.written(), expected.items);
    return expected.items.len;
}

/// Appends an entry, taking ownership of `data` only on success.
fn appendExpected(expected: *std.ArrayList(Expected), name: []const u8, data: []u8) !void {
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    try expected.append(gpa, .{ .name = owned_name, .data = data });
}

/// Reads `bytes` with the Iterator and checks it holds exactly `expected`, in order.
fn expectReadBack(bytes: []const u8, expected: []const Expected) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "fuzz.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "fuzz.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    var name_buf: [1024]u8 = undefined;

    var iter = try Iterator.init(&reader);
    for (expected) |e| {
        const fd = (try iter.next()) orelse return error.TestMissingEntry;
        try std.testing.expectEqualStrings(e.name, try fd.filaneme(&reader, &name_buf));
        got.clearRetainingCapacity();
        _ = try fd.stream(&reader, &got.writer);
        try std.testing.expectEqualSlices(u8, e.data, got.written());
    }
    try std.testing.expectEqual(null, try iter.next());
}

test "fuzz: writer round-trip" {
    try std.testing.fuzz({}, roundTrip, .{});
}

test "fuzz: writer round-trip over 200 seeded inputs" {
    // The same target on fixed pseudo-random inputs, so plain `zig build test` covers it.
    var prng: std.Random.DefaultPrng = .init(0x5A1F_2026);
    var entries: usize = 0;
    for (0..200) |_| entries += try roundTripCount(.{ .rng = prng.random() });
    // Guards the generator: if nearly every name were rejected, this would test nothing.
    try std.testing.expect(entries >= 200);
}
