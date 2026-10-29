//! Entry reads of the hostile and edge fixtures in testdata/ through `Iterator.streamEntry`:
//! deflate streams that end early, run long, are cut short or carry junk, and flipped bytes.
const std = @import("std");
const Iterator = @import("../iterator.zig").Iterator;

const io = std.testing.io;

/// Streams the first entry of the fixture at `path` and returns the byte count.
fn firstEntryStreamResult(path: []const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Iterator.init(&reader);
    const fd = (try iter.next()) orelse return error.TestUnexpectedEmptyArchive;

    var out_buf: [256]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&out_buf);
    return iter.streamEntry(&fd, &discard.writer);
}

test "entry: deflate stream shorter than the declared uncompressed size is an error" {
    // testdata/hostile/deflate_short_output.zip: a complete deflate stream inflating to 500
    // bytes, headers say 600 (see scripts/gen-hostile.py). Must not report success.
    if (firstEntryStreamResult("testdata/hostile/deflate_short_output.zip")) |n| {
        std.log.err("stream returned {d} bytes instead of an error", .{n});
        return error.TestExpectedError;
    } else |_| {}
}

test "entry: deflate stream cut short is an error" {
    // testdata/hostile/deflate_truncated.zip: 8192-byte entry whose deflate data is cut in half;
    // compressed_size matches the bytes present. Python's zipfile reports Bad CRC-32.

    // std 0.16.0's inflater panicked here; the vendored one returns EndOfStream.
    try std.testing.expectError(
        error.ZipTruncated,
        firstEntryStreamResult("testdata/hostile/deflate_truncated.zip"),
    );
}

test "entry: stored entry with a corrupted byte fails the CRC-32 check" {
    // testdata/hostile/stored_bad_crc.zip: one payload byte flipped, sizes all correct,
    // header CRC is for the original bytes (see scripts/gen-hostile.py).
    try std.testing.expectError(
        error.ZipCRC32Mismatch,
        firstEntryStreamResult("testdata/hostile/stored_bad_crc.zip"),
    );
}

test "entry: deflated entry with a corrupted byte is an error" {
    // testdata/hostile/deflate_bad_crc.zip: one byte flipped mid-stream. Either the
    // inflater or the CRC-32 check must reject it.
    if (firstEntryStreamResult("testdata/hostile/deflate_bad_crc.zip")) |n| {
        std.log.err("stream returned {d} bytes instead of an error", .{n});
        return error.TestExpectedError;
    } else |_| {}
}

test "entry: empty deflated entry from Python's zipfile reads as 0 bytes" {
    // testdata/edge/empty_deflated.zip: method 8, sizes 0/2, data `03 00` (see scripts/gen-hostile.py).
    try std.testing.expectEqual(@as(u64, 0), try firstEntryStreamResult("testdata/edge/empty_deflated.zip"));
}

test "entry: junk after a complete deflate stream is an error" {
    // testdata/hostile/deflate_trailing_junk.zip: compressed_size counts 4 junk bytes past the final block.
    try std.testing.expectError(
        error.ZipTrailingCompressedData,
        firstEntryStreamResult("testdata/hostile/deflate_trailing_junk.zip"),
    );
}

test "entry: deflate stream longer than the declared uncompressed size is an error" {
    // testdata/hostile/deflate_long_output.zip: inflates to 500 bytes, headers say 400.
    try std.testing.expectError(
        error.ZipSizeMismatch,
        firstEntryStreamResult("testdata/hostile/deflate_long_output.zip"),
    );
}

test {
    // The vendored inflater's own tests.
    _ = @import("../vendor/flate/decompress.zig");
    _ = @import("../vendor/flate/token.zig");
}
