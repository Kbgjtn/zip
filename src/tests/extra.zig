//! Tests for extra field parsing (APPNOTE 4.5): the `Iterator`, `Field` and the payload
//! parsers.
const std = @import("std");
const testing = std.testing;
const extra = @import("../extra.zig");
const HeaderId = @import("../format.zig").HeaderId;

test "extra: zip64 field with every value escaped" {
    // All four header values are all ones, so the field holds three u64s and a u32 (APPNOTE 4.5.3).
    const data = std.mem.toBytes(@as(u64, 5_000_000_000)) ++ std.mem.toBytes(@as(u64, 4_500_000_000)) ++
        std.mem.toBytes(@as(u64, 6_000_000_000)) ++ std.mem.toBytes(@as(u32, 0));
    const z = try extra.Zip64.parse(&data, .{
        .uncompressed_size = 0xFFFF_FFFF,
        .compressed_size = 0xFFFF_FFFF,
        .local_header_offset = 0xFFFF_FFFF,
        .disk_number_start = 0xFFFF,
    });
    try testing.expectEqual(5_000_000_000, z.uncompressed_size);
    try testing.expectEqual(4_500_000_000, z.compressed_size);
    try testing.expectEqual(6_000_000_000, z.local_header_offset);
    try testing.expectEqual(0, z.disk_number_start);
}

test "extra: zip64 field with one value escaped keeps the header's others" {
    const z = try extra.Zip64.parse(&.{ 6, 0, 0, 0, 0, 0, 0, 0 }, .{
        .uncompressed_size = 0xFFFF_FFFF,
        .compressed_size = 6,
        .local_header_offset = 0,
        .disk_number_start = 0,
    });
    try testing.expectEqual(6, z.uncompressed_size);
    try testing.expectEqual(6, z.compressed_size);
    try testing.expectEqual(0, z.local_header_offset);
    try testing.expectEqual(0, z.disk_number_start);
}

test "extra: zip64 field with nothing escaped is empty" {
    const z = try extra.Zip64.parse(&.{}, .{
        .uncompressed_size = 0,
        .compressed_size = 0,
        .local_header_offset = 0,
        .disk_number_start = 0,
    });
    try testing.expectEqual(extra.Zip64{}, z);
}

test "extra: zip64 field with leftover bytes is malformed" {
    // Only uncompressed_size is all ones, so exactly 8 bytes belong here; 8 more are junk.
    const data = [_]u8{ 6, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{0xAA} ** 8;
    try testing.expectError(error.ZipBadExtraField, extra.Zip64.parse(&data, .{
        .uncompressed_size = 0xFFFF_FFFF,
        .compressed_size = 6,
        .local_header_offset = 0,
        .disk_number_start = 0,
    }));
}

test "extra: zip64 field shorter than its escaped values is malformed" {
    try testing.expectError(error.ZipBadExtraField, extra.Zip64.parse(&.{ 6, 0, 0, 0 }, .{
        .uncompressed_size = 0xFFFF_FFFF,
    }));
}

test "extra: Info-ZIP Unix field reads ids by their declared size" {
    // version 1, uid_size 4, uid 1000, gid_size 4, gid 1000 (what Info-ZIP writes on Linux)
    const full = [_]u8{ 1, 4, 0xE8, 0x03, 0, 0, 4, 0xE8, 0x03, 0, 0 };
    const p = try extra.InfoZipUnixNew.parse(&full);
    try testing.expectEqual(1, p.version);
    try testing.expectEqual(1000, p.uid);
    try testing.expectEqual(1000, p.gid);

    // 2-byte ids must not be read as u32, overrunning into the gid_size byte.
    const s = try extra.InfoZipUnixNew.parse(&.{ 1, 2, 0x39, 0x30, 2, 0x31, 0xD4 });
    try testing.expectEqual(12345, s.uid);
    try testing.expectEqual(54321, s.gid);

    // Zero-size ids are absent.
    const n = try extra.InfoZipUnixNew.parse(&.{ 1, 0, 0 });
    try testing.expectEqual(null, n.uid);
    try testing.expectEqual(null, n.gid);

    try testing.expectError(error.ZipBadExtraField, extra.InfoZipUnixNew.parse(&(full ++ [_]u8{0})));
    try testing.expectError(error.ZipBadExtraField, extra.InfoZipUnixNew.parse(&.{ 1, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
}

test "extra: Info-ZIP Unix field reads 8-byte ids, null when they don't fit in u32" {
    // extrafld.txt gives each id a size byte, not a fixed width: 8-byte ids are valid.
    const small = try extra.InfoZipUnixNew.parse(&.{ 1, 8, 0xE8, 0x03, 0, 0, 0, 0, 0, 0, 8, 0x64, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(1000, small.uid);
    try testing.expectEqual(100, small.gid);

    const big = try extra.InfoZipUnixNew.parse(&.{ 1, 8, 0, 0, 0, 0, 1, 0, 0, 0, 1, 7 });
    try testing.expectEqual(null, big.uid);
    try testing.expectEqual(7, big.gid);
}

test "extra: Info-ZIP Unix field with an unknown version" {
    // Only version 1 of the 0x7875 field exists.
    try testing.expectError(
        error.ZipBadExtraField,
        extra.InfoZipUnixNew.parse(&.{ 2, 4, 0xE8, 3, 0, 0, 4, 0xE8, 3, 0, 0 }),
    );
}

test "extra: extended timestamp with all three times, and the central short form" {
    // flags 0x07, mtime 1_600_000_000, atime 1_600_000_100, ctime 1_600_000_200
    var data: [13]u8 = undefined;
    data[0] = 0x07;
    std.mem.writeInt(u32, data[1..5], 1_600_000_000, .little);
    std.mem.writeInt(u32, data[5..9], 1_600_000_100, .little);
    std.mem.writeInt(u32, data[9..13], 1_600_000_200, .little);
    const t = try extra.ExtendedTimestamp.parse(&data);
    try testing.expectEqual(1_600_000_000, t.mtime);
    try testing.expectEqual(1_600_000_100, t.atime);
    try testing.expectEqual(1_600_000_200, t.ctime);

    // In the central directory the flags still say 0x07 but only mtime is stored (5 bytes).
    const c = try extra.ExtendedTimestamp.parse(data[0..5]);
    try testing.expectEqual(1_600_000_000, c.mtime);
    try testing.expectEqual(null, c.atime);
    try testing.expectEqual(null, c.ctime);

    try testing.expectError(error.ZipBadExtraField, extra.ExtendedTimestamp.parse(&(data ++ [_]u8{0})));
    try testing.expectError(error.ZipBadExtraField, extra.ExtendedTimestamp.parse(&.{}));
}

test "extra: Unicode Path field points into the block" {
    const data = [_]u8{ 1, 0x78, 0x56, 0x34, 0x12 } ++ "caf\xc3\xa9".*;
    const u = try extra.InfoZipUnicodePath.parse(&data);
    try testing.expectEqual(1, u.version);
    try testing.expectEqual(0x12345678, u.name_crc32);
    try testing.expectEqualStrings("caf\xc3\xa9", u.name);
    try testing.expectEqual(@as([*]const u8, &data) + 5, u.name.ptr);

    try testing.expectError(error.ZipBadExtraField, extra.InfoZipUnicodePath.parse(data[0..4]));
}

test "extra: field header id" {
    const known: extra.Field = .{ .id = 0x0001, .data = &.{} };
    try testing.expectEqual(HeaderId.zip64, known.asHeaderId());
    const unknown: extra.Field = .{ .id = 0xFFFF, .data = &.{} };
    try testing.expectEqual(null, unknown.asHeaderId());
}

test "extra: iterator returns a known header id with no parser" {
    // 0x000a (NTFS) is a known id the library doesn't parse; next() still returns it.
    var it: extra.Iterator = .{ .buf = &.{ 0x0a, 0x00, 0x00, 0x00 } };
    const f = (try it.next()).?;
    try testing.expectEqual(0x000a, f.id);
    try testing.expectEqual(HeaderId.ntfs, f.asHeaderId());
    try testing.expectEqual(0, f.data.len);
    try testing.expectEqual(null, try it.next());

    try testing.expectEqual(null, try it.find(.zip64));
    const from_start: extra.Iterator = .{ .buf = it.buf };
    try testing.expectEqual(null, try from_start.find(.zip64));
}

test "extra: iterator returns an unknown header id" {
    var it: extra.Iterator = .{ .buf = &.{ 0xFE, 0xCA, 0x03, 0x00, 1, 2, 3 } };
    const f = (try it.next()).?;
    try testing.expectEqual(0xCAFE, f.id);
    try testing.expectEqual(null, f.asHeaderId());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, f.data);
    try testing.expectEqual(null, try it.next());

    const from_start: extra.Iterator = .{ .buf = it.buf };
    try testing.expectEqual(null, try from_start.find(.zip64));
}

test "extra: find skips other fields to the one it looks for" {
    const block = [_]u8{ 0x55, 0x54, 5, 0, 3, 4, 210, 153, 105 } ++ // 0x5455
        [_]u8{ 0x75, 0x78, 11, 0, 1, 4, 232, 3, 0, 0, 4, 232, 3, 0, 0 } ++ // 0x7875
        [_]u8{ 0x01, 0x00, 8, 0, 6, 0, 0, 0, 0, 0, 0, 0 }; // 0x0001
    const it: extra.Iterator = .{ .buf = &block };
    const f = (try it.find(.zip64)).?;
    try testing.expectEqualSlices(u8, &.{ 6, 0, 0, 0, 0, 0, 0, 0 }, f.data);
    // find works on a copy, so the iterator has not moved.
    try testing.expectEqual(0, it.offset);
}

test "extra: iterator rejects a truncated field header" {
    // One whole empty field, then 3 bytes: too short for the next 4-byte id and size.
    var it: extra.Iterator = .{ .buf = &.{ 0x55, 0x54, 0, 0, 0x75, 0x78, 0 } };
    try testing.expect((try it.next()) != null);
    try testing.expectError(error.ZipBadExtraField, it.next());
}

test "extra: find rejects a partial field header" {
    const it: extra.Iterator = .{ .buf = &.{ 0x01, 0x00, 0x08 } };
    try testing.expectError(error.ZipBadExtraField, it.find(.zip64));
}

test "extra: find rejects a field whose size runs past the block" {
    const it: extra.Iterator = .{ .buf = &.{ 0x01, 0x00, 0x08, 0x00, 0xAA } };
    try testing.expectError(error.ZipBadExtraField, it.find(.zip64));
}

test "extra: find rejects junk before the field it looks for" {
    const it: extra.Iterator = .{ .buf = &.{ 0x55, 0x54, 0x00, 0x00, 0x00 } };
    try testing.expectError(error.ZipBadExtraField, it.find(.zip64));
}

test "extra: find gives null for an empty block or a missing id" {
    const it: extra.Iterator = .{ .buf = &.{} };
    try testing.expectEqual(null, it.find(.zip64));
    const other: extra.Iterator = .{ .buf = &.{ 0x55, 0x54, 0x00, 0x00 } };
    try testing.expectEqual(null, other.find(.zip64));
}
