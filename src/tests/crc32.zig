//! The slicing-by-8 CRC-32 gives the same values as `std.hash.Crc32`.
const std = @import("std");
const Crc32 = @import("../crc32.zig").Crc32;

test "crc32: check value" {
    // The CRC-32/ISO-HDLC check value.
    try std.testing.expectEqual(@as(u32, 0xCBF4_3926), Crc32.hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0), Crc32.hash(""));
}

test "crc32: matches std for every length and alignment" {
    var buf: [1024 + 8]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    for (0..8) |start| {
        for (0..1024) |len| {
            const bytes = buf[start..][0..len];
            try std.testing.expectEqual(std.hash.Crc32.hash(bytes), Crc32.hash(bytes));
        }
    }
}

test "crc32: update in pieces equals one update" {
    var buf: [300]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5a17);
    prng.random().bytes(&buf);
    const want = std.hash.Crc32.hash(&buf);
    for (0..buf.len + 1) |split| {
        var c: Crc32 = .init();
        c.update(buf[0..split]);
        c.update(buf[split..]);
        try std.testing.expectEqual(want, c.final());
    }
}
