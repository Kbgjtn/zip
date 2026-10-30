//! Damage sweeps: take valid archives and damage them every way at once.
//! - Prefix cuts: every length 0..n-1. Must always be an error.
//! - Holes: drop 1, 4 or 16 bytes anywhere before the EOCD, which is kept whole.
//! - Flips: invert every byte, one at a time.
//! Holes and flips may still read fine (a flipped date byte is valid), so they only have to
//! finish without a panic or a hang. A panic or hang shows up as this test crashing or stalling.
const std = @import("std");
const Writer = @import("../Writer.zig");
const Archive = @import("../Archive.zig");

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Every `testdata/edge/` fixture, relative to the repo root where `zig build test` runs.
/// Each one must read fine undamaged.
const fixtures = [_][]const u8{
    "testdata/edge/as_zip64.zip",
    "testdata/edge/empty.zip",
    "testdata/edge/empty_deflated.zip",
    "testdata/edge/os_unknown.zip",
    "testdata/edge/with_comment.zip",
    "testdata/edge/with_data_descriptor.zip",
    "testdata/edge/with_flated.zip",
};

/// Lists and streams every entry of `bytes`, throwing the data away. Reads from memory:
/// tests/source_parity.zig shows file and memory reads agree, and memory skips thousands of
/// temp file writes.
fn read(bytes: []const u8) !void {
    var sink_buf: [256]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);
    var archive = try Archive.openMemory(bytes, .{});
    while (try archive.next()) |fd| {
        _ = try archive.streamEntry(&fd, &sink.writer);
    }
}

/// Runs all three sweeps over `bytes`, which must read fine undamaged.
fn sweep(label: []const u8, bytes: []u8) !void {
    try read(bytes);

    // Prefix cuts: losing the tail always loses part of the EOCD, so nothing may succeed.
    for (0..bytes.len) |len| {
        if (read(bytes[0..len])) |_| {
            std.debug.print("{s}: prefix of {d}/{d} bytes read as valid\n", .{ label, len, bytes.len });
            return error.TestExpectedError;
        } else |_| {}
    }

    // Holes before the EOCD. With no EOCD found (a fixture that's somehow odd), skip them.
    const holed = try gpa.alloc(u8, bytes.len);
    defer gpa.free(holed);
    if (std.mem.lastIndexOf(u8, bytes, "PK\x05\x06")) |eocd_start| {
        for ([_]usize{ 1, 4, 16 }) |hole| {
            var at: usize = 0;
            while (at + hole <= eocd_start) : (at += 1) {
                @memcpy(holed[0..at], bytes[0..at]);
                @memcpy(holed[at .. bytes.len - hole], bytes[at + hole ..]);
                read(holed[0 .. bytes.len - hole]) catch {};
            }
        }
    }

    // Flips, restored after each read.
    for (bytes) |*b| {
        b.* ^= 0xFF;
        defer b.* ^= 0xFF;
        read(bytes) catch {};
    }
}

test "sweep: edge fixtures survive prefix cuts, holes and byte flips" {
    // Damaged archives make the reader warn thousands of times; only errors are news here.
    // The test runner resets this before each test.
    std.testing.log_level = .err;
    for (fixtures) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try sweep(path, bytes);
    }
}

test "sweep: writer archives (stored, deflated, streamed ZIP64) survive prefix cuts, holes and byte flips" {
    // Damaged archives make the reader warn thousands of times; only errors are news here.
    // The test runner resets this before each test.
    std.testing.log_level = .err;

    // A few hundred bytes that deflate shrinks, so flips land inside real deflate data.
    var text: [600]u8 = undefined;
    const line = "the quick brown fox jumps over the lazy dog 0123456789\n";
    for (&text, 0..) |*c, i| c.* = line[(i * 7 + i / 31) % line.len];

    const Kind = enum { stored, deflated, streamed_zip64 };
    for (std.enums.values(Kind)) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        {
            var zw: Writer = undefined;
            try zw.init(gpa, &out.writer);
            defer zw.deinit();
            switch (kind) {
                .stored => {
                    try zw.addBytes("a.txt", "hello\n", .{ .method = .stored });
                    try zw.addBytes("dir/b.txt", text[0..40], .{ .method = .stored });
                },
                .deflated => try zw.addBytes("dir/text.txt", &text, .{}),
                .streamed_zip64 => {
                    var src: std.Io.Reader = .fixed(&text);
                    try zw.addStream("stream.txt", &src, .{ .zip64 = true });
                },
            }
            try zw.finish();
        }
        try sweep(@tagName(kind), out.written());
    }
}
