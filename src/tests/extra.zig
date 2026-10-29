//! Extra field parsing (APPNOTE 4.5) through the public `Field` and `Iterator`.
const std = @import("std");
const extra = @import("../extra.zig");

test "extra: zip64 field with every value escaped" {
    // All four header values are 0xFF..., so the field holds three u64s and a u32 (APPNOTE 4.5.3).
    const data = std.mem.toBytes(@as(u64, 5_000_000_000)) ++ std.mem.toBytes(@as(u64, 4_500_000_000)) ++
        std.mem.toBytes(@as(u64, 6_000_000_000)) ++ std.mem.toBytes(@as(u32, 0));
    const f: extra.Field = .{ .id = 0x0001, .data = &data };
    const parsed = (try f.parse(.{ .zip64_extended_extra_field = .{
        .uncompressed_size = 0xFFFF_FFFF,
        .compressed_size = 0xFFFF_FFFF,
        .local_file_header_relative_offset = 0xFFFF_FFFF,
        .disk_number_start = 0xFFFF,
    } })).?;
    const z = parsed.zip64_extended_extra_field;
    try std.testing.expectEqual(5_000_000_000, z.uncompressed_size);
    try std.testing.expectEqual(4_500_000_000, z.compressed_size);
    try std.testing.expectEqual(6_000_000_000, z.local_file_header_relative_offset);
    try std.testing.expectEqual(0, z.disk_number_start);
}

test "extra: Info-ZIP Unix field with an unknown version" {
    // Only version 1 of the 0x7875 field exists.
    const f: extra.Field = .{ .id = 0x7875, .data = &.{ 2, 4, 0xE8, 3, 0, 0, 4, 0xE8, 3, 0, 0 } };
    try std.testing.expectError(error.ZipBadExtraField, f.parse(.none));
}

test "extra: known header id with no parser is skipped" {
    // 0x000a (NTFS) is a known id the library doesn't parse.
    const f: extra.Field = .{ .id = 0x000a, .data = &.{} };
    try std.testing.expectEqual(null, try f.parse(.none));
}

test "extra: unknown header id is skipped" {
    const f: extra.Field = .{ .id = 0xCAFE, .data = &.{ 1, 2, 3 } };
    try std.testing.expectEqual(null, try f.parse(.none));
}

test "extra: iterator rejects a truncated field header" {
    // One whole empty field, then 3 bytes: too short for the next 4-byte id and size.
    var it: extra.Iterator = .{ .buf = &.{ 0x55, 0x54, 0, 0, 0x75, 0x78, 0 } };
    try std.testing.expect((try it.next()) != null);
    try std.testing.expectError(error.ZipBadExtraField, it.next());
}
