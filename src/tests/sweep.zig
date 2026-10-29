//! Damage sweeps (design M10): take valid archives and damage them every way at once.
//! - Prefix cuts: every length 0..n-1. Must always be an error.
//! - Holes: drop 1, 4 or 16 bytes anywhere before the EOCD, which is kept whole.
//! - Flips: invert every byte, one at a time.
//! Holes and flips may still read fine (a flipped date byte is valid), so they only have to
//! finish without a panic or a hang. A panic or hang shows up as this test crashing or stalling.
const std = @import("std");
const Writer = @import("../writer.zig");
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

/// One scratch file, rewritten for every damaged archive, so a sweep doesn't make
/// thousands of temp dirs.
const Scratch = struct {
    tmp: std.testing.TmpDir,

    /// Makes the temp dir. Call `deinit` to remove it.
    fn init() Scratch {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    /// Removes the temp dir and the scratch file.
    fn deinit(self: *Scratch) void {
        self.tmp.cleanup();
    }

    /// Lists and streams every entry of `bytes`, throwing the data away.
    fn read(self: *Scratch, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });
        var file = try self.tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);

        var sink_buf: [256]u8 = undefined;
        var sink: std.Io.Writer.Discarding = .init(&sink_buf);
        var iter = try Archive.init(&reader);
        while (try iter.next()) |fd| {
            _ = try iter.streamEntry(&fd, &sink.writer);
        }
    }
};

/// Runs all three sweeps over `bytes`, which must read fine undamaged.
fn sweep(s: *Scratch, label: []const u8, bytes: []u8) !void {
    try s.read(bytes);

    // Prefix cuts: losing the tail always loses part of the EOCD, so nothing may succeed.
    for (0..bytes.len) |len| {
        if (s.read(bytes[0..len])) |_| {
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
                s.read(holed[0 .. bytes.len - hole]) catch {};
            }
        }
    }

    // Flips, restored after each read.
    for (bytes) |*b| {
        b.* ^= 0xFF;
        defer b.* ^= 0xFF;
        s.read(bytes) catch {};
    }
}

test "sweep: edge fixtures survive prefix cuts, holes and byte flips" {
    // Damaged archives make the reader warn thousands of times; only errors are news here.
    // The test runner resets this before each test.
    std.testing.log_level = .err;
    var s: Scratch = .init();
    defer s.deinit();
    for (fixtures) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try sweep(&s, path, bytes);
    }
}

test "sweep: writer archives (stored, deflated, streamed ZIP64) survive prefix cuts, holes and byte flips" {
    // Damaged archives make the reader warn thousands of times; only errors are news here.
    // The test runner resets this before each test.
    std.testing.log_level = .err;
    var s: Scratch = .init();
    defer s.deinit();

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
        try sweep(&s, @tagName(kind), out.written());
    }
}
