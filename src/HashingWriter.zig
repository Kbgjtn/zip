//! Writer that computes CRC-32 and counts bytes on their way to `out`.
//! Initialise it in place with `init` and never copy it: `drain` finds the
//! struct again through `@fieldParentPtr` on `interface`.

const std = @import("std");
const Writer = std.Io.Writer;
const Crc32 = std.hash.Crc32;

const HashingWriter = @This();

out: *Writer,
crc: Crc32,
/// Bytes forwarded to `out`, not counting what's still in our buffer.
count: u64,
interface: Writer,

/// Returns a hashing writer that forwards to `out` through `buffer`.
pub fn init(out: *Writer, buffer: []u8) HashingWriter {
    return .{
        .out = out,
        .count = 0,
        .crc = .init(),
        .interface = .{
            .buffer = buffer,
            .vtable = &.{ .drain = drain },
        },
    };
}

/// CRC-32 of everything forwarded so far. Call `interface.flush()` first, or bytes still
/// in the buffer are left out.
pub fn final(self: *const HashingWriter) u32 {
    return self.crc.final();
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *HashingWriter = @alignCast(@fieldParentPtr("interface", w));

    // Forward everything, so the CRC never has to track a partial write.
    try self.forward(w.buffered());
    w.end = 0;

    var consumed: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        try self.forward(bytes);
        consumed += bytes.len;
    }

    const pattern = data[data.len - 1];
    for (0..splat) |_| try self.forward(pattern);
    return consumed + pattern.len * splat;
}

fn forward(self: *HashingWriter, bytes: []const u8) Writer.Error!void {
    self.crc.update(bytes);
    self.count += bytes.len;
    try self.out.writeAll(bytes);
}

test "hashing writer: small write stays in our buffer until flush" {
    var out_buf: [64]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var hw: HashingWriter = .init(&out, &buf);

    try hw.interface.writeAll("abc");
    try std.testing.expectEqual(@as(u64, 0), hw.count);
    try std.testing.expectEqual(@as(usize, 0), out.end);

    try hw.interface.flush();
    try std.testing.expectEqual(@as(u64, 3), hw.count);
    try std.testing.expectEqual(Crc32.hash("abc"), hw.final());
    try std.testing.expectEqualStrings("abc", out.buffered());
}

test "hashing writer: writes larger than the buffer hash the same as one shot" {
    var out_buf: [64]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var hw: HashingWriter = .init(&out, &buf);

    const data = "0123456789abcdefghijklmnopqrstuvwxyz"; // 36 bytes
    try hw.interface.writeAll(data[0..5]);
    try hw.interface.writeAll(data[5..20]);
    try hw.interface.writeAll(data[20..]);
    try hw.interface.flush();
    try std.testing.expectEqual(@as(u64, data.len), hw.count);
    try std.testing.expectEqual(Crc32.hash(data), hw.final());
    try std.testing.expectEqualStrings(data, out.buffered());
}

test "hashing writer: splat is hashed and counted" {
    var out_buf: [128]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var hw: HashingWriter = .init(&out, &buf);

    const want = [_]u8{'x'} ** 100;
    try hw.interface.splatByteAll('x', 100);
    try hw.interface.flush();
    try std.testing.expectEqual(@as(u64, 100), hw.count);
    try std.testing.expectEqual(Crc32.hash(&want), hw.final());
    try std.testing.expectEqualSlices(u8, &want, out.buffered());
}

test "hashing writer: empty input" {
    var out_buf: [8]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var hw: HashingWriter = .init(&out, &buf);

    try hw.interface.flush();
    try std.testing.expectEqual(@as(u64, 0), hw.count);
    try std.testing.expectEqual(@as(u32, 0), hw.final());
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "hashing writer: full output fails" {
    var out_buf: [4]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var hw: HashingWriter = .init(&out, &buf);

    const result = blk: {
        hw.interface.writeAll("0123456789") catch |e| break :blk e;
        hw.interface.flush() catch |e| break :blk e;
        break :blk {};
    };
    try std.testing.expectError(error.WriteFailed, result);
}
