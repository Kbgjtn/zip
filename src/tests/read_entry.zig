//! Round trips through `Archive.streamEntry` and `Archive.readEntryAlloc` on archives
//! made by our writer.
const std = @import("std");
const Writer = @import("../Writer.zig");
const Archive = @import("../Archive.zig");
const CompressionMethod = @import("../format.zig").CompressionMethod;

const io = std.testing.io;
const gpa = std.testing.allocator;

const text = "the quick brown fox jumps over the lazy dog\n" ** 64;

/// Writes `text` as one entry with `method`, and checks both read paths give it back.
fn expectRoundTrip(method: CompressionMethod) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    try zw.addBytes("fox.txt", text, .{ .method = method });
    try zw.finish();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = out.written() });
    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var iter = try Archive.openFile(&reader, .{});

    const fd = (try iter.next()) orelse return error.TestUnexpectedEmptyArchive;
    try std.testing.expectEqual(method, fd.compression());
    try std.testing.expectEqual(null, try iter.next());

    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectEqual(@as(u64, text.len), try iter.streamEntry(&fd, &got.writer));
    try std.testing.expectEqualStrings(text, got.written());

    const bytes = try iter.readEntryAlloc(gpa, &fd, text.len);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(text, bytes);

    try std.testing.expectError(error.ZipEntryTooLarge, iter.readEntryAlloc(gpa, &fd, text.len - 1));
}

test "read entry: stored round trip through streamEntry and readEntryAlloc" {
    try expectRoundTrip(.stored);
}

test "read entry: deflated round trip through streamEntry and readEntryAlloc" {
    try expectRoundTrip(.deflate);
}
