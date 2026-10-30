//! Read fuzz target (design M15): any bytes at all go through `Archive.openMemory`, `next`,
//! `Entry.cleanName`, `streamEntry` and `checkLayout`. Every error is a fine answer; a
//! panic, a hang or a leak (`std.testing.allocator` checks every input) is a bug.
//!
//! - `zig build test` runs the fixtures and a fixed set of seeded mutations of them.
//! - `zig build test --fuzz` hands `readAnything` to the fuzzer, starting from the
//!   `testdata/edge/` and `testdata/hostile/` fixtures.
const std = @import("std");
const Archive = @import("../Archive.zig");
const Smith = std.testing.Smith;

const io = std.testing.io;
const gpa = std.testing.allocator;

/// Fuzz starting points, relative to the repo root where `zig build test` runs. The EPUB
/// is left out: at 4 MB it would make every input slow.
const fixtures = [_][]const u8{
    "testdata/edge/as_zip64.zip",
    "testdata/edge/empty.zip",
    "testdata/edge/empty_deflated.zip",
    "testdata/edge/metadata.zip",
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

/// Largest input, past the biggest fixture (70,000 bytes) and the 64 KiB EOCD scan window
/// (APPNOTE 4.3.16: 22 bytes plus a comment of up to 65,535).
const max_input = 128 << 10;

/// Tight limits, so a forged size or count fails fast instead of making one input slow.
const limits: Archive.Limits = .{
    .max_entries = 256,
    .max_entry_size = 1 << 20,
    .max_total_size = 4 << 20,
};

/// One input's bytes. The fuzzer runs one input at a time, so one buffer will do.
var input_buf: [max_input]u8 = undefined;

/// One fuzz input: the bytes of a would-be archive.
fn readAnything(_: void, smith: *Smith) anyerror!void {
    const len = smith.slice(&input_buf);
    _ = readAll(input_buf[0..len]);
}

/// Opens `bytes` and reads everything the reader offers, ignoring every error: listing,
/// the archive comment, each cleaned name and each entry's data, then `checkLayout`.
/// Returns how many entries streamed without an error.
fn readAll(bytes: []const u8) usize {
    var archive = Archive.openMemory(bytes, .{ .limits = limits }) catch return 0;

    var comment_buf: [std.math.maxInt(u16)]u8 = undefined;
    _ = archive.comment(&comment_buf) catch {};

    var sink_buf: [256]u8 = undefined;
    var sink: std.Io.Writer.Discarding = .init(&sink_buf);
    var name_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var read: usize = 0;
    // `next` fails or ends within `max_entries`, so this can't spin.
    while (archive.next() catch null) |entry| {
        _ = archive.cleanEntryName(&entry, &name_buf) catch {};
        if (archive.streamEntry(&entry, &sink.writer)) |_| read += 1 else |_| {}
    }
    archive.checkLayout(gpa) catch {};
    return read;
}

/// Reads every fixture into `corpus` as a `Smith` slice input: a little-endian u32 length,
/// then the bytes. Caller frees each element and the list.
fn loadCorpus(corpus: *std.ArrayList([]const u8)) !void {
    for (fixtures) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input));
        defer gpa.free(bytes);
        const input = try gpa.alloc(u8, 4 + bytes.len);
        std.mem.writeInt(u32, input[0..4], @intCast(bytes.len), .little);
        @memcpy(input[4..], bytes);
        corpus.append(gpa, input) catch |err| {
            gpa.free(input);
            return err;
        };
    }
}

fn freeCorpus(corpus: *std.ArrayList([]const u8)) void {
    for (corpus.items) |input| gpa.free(input);
    corpus.deinit(gpa);
}

test "fuzz read: open and read anything" {
    // Damaged archives make the reader warn; only errors are news here.
    std.testing.log_level = .err;
    var corpus: std.ArrayList([]const u8) = .empty;
    defer freeCorpus(&corpus);
    try loadCorpus(&corpus);
    try std.testing.fuzz({}, readAnything, .{ .corpus = corpus.items });
}

test "fuzz read: over 240 seeded mutations of each fixture" {
    // The same target on fixed pseudo-random damage, so plain `zig build test` covers it.
    std.testing.log_level = .err;
    var prng: std.Random.DefaultPrng = .init(0x2EAD_2026);
    const random = prng.random();
    var buf: [max_input]u8 = undefined;
    var read: usize = 0;
    for (fixtures) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_input));
        defer gpa.free(bytes);
        _ = readAll(bytes);
        for (0..240) |_| read += readAll(mutate(random, bytes, &buf));
    }
    // Guards the mutator: if nearly every input failed to open, this would test little.
    // 512 entries read cleanly from this seed.
    try std.testing.expect(read >= 400);
}

/// A damaged copy of `bytes` in `buf`: a few bytes set at random, then maybe cut short, or
/// a run of bytes duplicated in place, which shifts every offset after it.
fn mutate(random: std.Random, bytes: []const u8, buf: *[max_input]u8) []const u8 {
    var len = bytes.len;
    @memcpy(buf[0..len], bytes);
    if (len == 0) return buf[0..0];
    for (0..random.intRangeAtMost(u8, 1, 4)) |_| buf[random.uintLessThan(usize, len)] = random.int(u8);
    switch (random.uintLessThan(u8, 4)) {
        0 => len = random.uintLessThan(usize, len),
        1 => {
            const at = random.uintLessThan(usize, len);
            const run = @min(random.intRangeAtMost(usize, 1, 32), len - at, buf.len - len);
            std.mem.copyBackwards(u8, buf[at + run .. len + run], buf[at..len]);
            len += run;
        },
        else => {},
    }
    return buf[0..len];
}
