//! CRC-32 as ZIP uses it (APPNOTE 4.4.7): the IEEE 802.3 polynomial, reflected, with
//! initial value and final xor 0xFFFFFFFF. Same values as `std.hash.Crc32`, which takes
//! one byte per table lookup; this takes eight (slicing-by-8), several times faster on
//! large inputs.

const std = @import("std");

pub const Crc32 = struct {
    crc: u32 = 0xFFFF_FFFF,

    /// Returns the state for an empty input.
    pub fn init() Crc32 {
        return .{};
    }

    /// Adds `bytes` to the checksum.
    pub fn update(self: *Crc32, bytes: []const u8) void {
        var c = self.crc;
        var p = bytes;
        while (p.len >= 8) {
            const lo = std.mem.readInt(u32, p[0..4], .little) ^ c;
            const hi = std.mem.readInt(u32, p[4..8], .little);
            c = tables[7][lo & 0xFF] ^ tables[6][(lo >> 8) & 0xFF] ^
                tables[5][(lo >> 16) & 0xFF] ^ tables[4][lo >> 24] ^
                tables[3][hi & 0xFF] ^ tables[2][(hi >> 8) & 0xFF] ^
                tables[1][(hi >> 16) & 0xFF] ^ tables[0][hi >> 24];
            p = p[8..];
        }
        for (p) |b| c = tables[0][(c ^ b) & 0xFF] ^ (c >> 8);
        self.crc = c;
    }

    /// Returns the checksum of everything added so far.
    pub fn final(self: Crc32) u32 {
        return ~self.crc;
    }

    /// Returns the checksum of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        var c: Crc32 = .init();
        c.update(bytes);
        return c.final();
    }
};

/// tables[0][b] is the CRC of byte b; tables[k][b] is that of b followed by k zero bytes,
/// so eight lookups advance the CRC by eight bytes.
const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB8_8320 ^ (c >> 1) else c >> 1;
        t[0][i] = c;
    }
    for (0..256) |i| {
        for (1..8) |k| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xFF];
    }
    break :blk t;
};
