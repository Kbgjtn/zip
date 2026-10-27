const std = @import("std");
const Writer = std.Io.Writer;

const CountingWriter = @This();

out: *Writer,
count: u64,
interface: Writer,

pub fn init(out: *Writer, buffer: []u8) CountingWriter {
    return .{
        .out = out,
        .count = 0,
        .interface = .{
            .buffer = buffer,
            .vtable = &.{ .drain = drain },
        },
    };
}

/// Logical position: forwarded bytes plus what's still sitting in our buffer.
pub fn position(self: *const CountingWriter) u64 {
    return self.count + self.interface.end;
}

fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
    const self: *CountingWriter = @alignCast(@fieldParentPtr("interface", w));
    const prev_end = w.end;

    const accepted = try self.out.writeSplatHeader(w.buffered(), data, splat);
    self.count += @as(u64, @intCast(accepted));
    if (accepted < prev_end) {
        // some buffered bytes remain; preserve them for the next drain.
        const remaining = prev_end - accepted;
        @memmove(w.buffer[0..remaining], w.buffer[accepted..prev_end]);
        w.end = remaining;
        return 0;
    }

    // The buffer was fully forwarded. Report only accepted bytes from `data`.
    w.end = 0;
    return accepted - prev_end;
}

test "counting writer: small write stays in our buffer" {
    var out_buf: [64]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var cw: CountingWriter = .init(&out, &buf);

    try cw.interface.writeAll("abc");
    try std.testing.expectEqual(@as(u64, 3), cw.position());
    try std.testing.expectEqual(@as(u64, 0), cw.count);
    try std.testing.expectEqual(@as(usize, 0), out.end);
}

test "counting writer: writes larger than the buffer are counted and forwarded intact" {
    var out_buf: [64]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var cw: CountingWriter = .init(&out, &buf);

    const data = "0123456789abcdefghij"; // 20 bytes
    try cw.interface.writeAll(data[0..5]);
    try cw.interface.writeAll(data[5..]);
    try std.testing.expectEqual(@as(u64, 20), cw.position());

    try cw.interface.flush();
    try std.testing.expectEqual(@as(u64, 20), cw.position());
    try std.testing.expectEqual(@as(u64, 20), cw.count);
    try std.testing.expectEqualStrings(data, out.buffered());
}

test "counting writer: splat is counted" {
    var out_buf: [128]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var cw: CountingWriter = .init(&out, &buf);

    try cw.interface.splatByteAll('x', 100);
    try cw.interface.flush();
    try std.testing.expectEqual(@as(u64, 100), cw.position());
    try std.testing.expectEqual(@as(u64, 100), cw.count);
    try std.testing.expectEqualSlices(u8, &([_]u8{'x'} ** 100), out.buffered());
}

test "counting writer: full output fails and never over-counts" {
    var out_buf: [4]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var buf: [8]u8 = undefined;
    var cw: CountingWriter = .init(&out, &buf);

    const result = blk: {
        cw.interface.writeAll("0123456789") catch |e| break :blk e;
        cw.interface.flush() catch |e| break :blk e;
        break :blk {};
    };
    try std.testing.expectError(error.WriteFailed, result);
    try std.testing.expect(cw.count <= 4);
    // Writer.fixed copies what fits and then fails without reporting it, so `count` can be
    // lower than what reached `out`. That's fine: after WriteFailed the archive is unusable.
}
