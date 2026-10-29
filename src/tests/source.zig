//! `Source` from memory and from a file gives the same bytes at the same offsets.
const std = @import("std");
const Source = @import("../source.zig").Source;

const io = std.testing.io;

test "source: memory size and readerAt" {
    var s: Source = .fromMemory("0123456789");
    try std.testing.expectEqual(@as(u64, 10), try s.size());

    const r = try s.readerAt(4);
    try std.testing.expectEqualStrings("456", try r.take(3));

    // A second readerAt starts over at its own offset.
    const again = try s.readerAt(0);
    try std.testing.expectEqualStrings("01", try again.take(2));
}

test "source: memory read past the end is EndOfStream" {
    var s: Source = .fromMemory("0123456789");
    try std.testing.expectError(error.EndOfStream, (try s.readerAt(8)).take(3));
    try std.testing.expectError(error.EndOfStream, (try s.readerAt(10)).takeByte());
    try std.testing.expectError(error.EndOfStream, (try s.readerAt(std.math.maxInt(u64))).takeByte());
}

test "source: a copied memory source reads on its own" {
    // Archive holds its Source by value, so a copy must not point back at the original.
    var a: Source = .fromMemory("abcdef");
    _ = try a.readerAt(3);
    var b = a;
    try std.testing.expectEqualStrings("abc", try (try b.readerAt(0)).take(3));
    try std.testing.expectEqualStrings("def", try (try a.readerAt(3)).take(3));
}

test "source: file and memory agree" {
    const data = "PK\x05\x06 some bytes of a file";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "s.bin", .data = data });
    var file = try tmp.dir.openFile(io, "s.bin", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [8]u8 = undefined;
    var reader = file.reader(io, &buf);

    var from_file: Source = .fromFile(&reader);
    var from_memory: Source = .fromMemory(data);
    try std.testing.expectEqual(try from_memory.size(), try from_file.size());

    for ([_]u64{ 0, 1, 4, 17, data.len - 3 }) |offset| {
        const want = try (try from_memory.readerAt(offset)).take(3);
        const got = try (try from_file.readerAt(offset)).take(3);
        try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectError(error.EndOfStream, (try from_file.readerAt(data.len - 1)).take(2));
}
