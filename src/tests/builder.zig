//! Hostile archives made with `testing/builder.zig` (design 12.4). Every case starts
//! from a valid archive and changes one field, so the reader error is the one that field causes.
const std = @import("std");
const Builder = @import("../testing/builder.zig");
const Writer = @import("../writer.zig");
const Iterator = @import("../iterator.zig").Iterator;

const io = std.testing.io;
const gpa = std.testing.allocator;

const name = "a.txt";
const data = "hi\n";

/// The fields a one-entry case changes. Local and central headers get the same value.
const Case = struct {
    flags: u16 = 0,
    method: u16 = 0,
    /// null means the real CRC of `data`.
    crc32: ?u32 = null,
    disk_start: u16 = 0,
    /// null means the real central directory offset.
    cd_offset: ?u32 = null,
};

/// Builds a one-entry stored archive of `name` with `data`, changed by `c`.
fn oneEntry(b: *Builder, c: Case) !void {
    const crc = c.crc32 orelse std.hash.Crc32.hash(data);
    const off = b.pos();
    try b.local(.{
        .flags = c.flags,
        .method = c.method,
        .crc32 = crc,
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .name = name,
    });
    try b.raw(data);

    const cd_offset = b.pos();
    try b.central(.{
        .flags = c.flags,
        .method = c.method,
        .crc32 = crc,
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .disk_start = c.disk_start,
        .offset = @intCast(off),
        .name = name,
    });
    try b.eocd(.{
        .entries = 1,
        .cd_size = @intCast(b.pos() - cd_offset),
        .cd_offset = c.cd_offset orelse @intCast(cd_offset),
    });
}

/// The fields a ZIP64 case changes.
const Case64 = struct {
    record_size: u64 = 44,
    /// null means the real offset of the ZIP64 end record.
    eocd64_offset: ?u64 = null,
};

/// Builds a one-entry archive whose EOCD fields are all 0xFFFF..., so the reader
/// has to take counts and offsets from the ZIP64 end record.
fn oneEntry64(b: *Builder, c: Case64) !void {
    const off = try b.entry(name, data);
    const cd_offset = b.pos();
    try b.central(.{
        .crc32 = std.hash.Crc32.hash(data),
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .offset = @intCast(off),
        .name = name,
    });
    const cd_size = b.pos() - cd_offset;

    const eocd64_offset = b.pos();
    try b.eocd64(.{
        .record_size = c.record_size,
        .entries = 1,
        .cd_size = cd_size,
        .cd_offset = cd_offset,
    });
    try b.locator64(.{ .eocd64_offset = c.eocd64_offset orelse eocd64_offset });
    try b.eocd(.{ .entries = 0xFFFF, .cd_size = 0xFFFF_FFFF, .cd_offset = 0xFFFF_FFFF });
}

/// Reads every entry of `bytes` with the Iterator, streaming the data into `out`.
/// Returns the entry count, or the first error.
fn readAll(bytes: []const u8, out: *std.Io.Writer) !usize {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var iter = try Iterator.init(&reader);
    var count: usize = 0;
    while (try iter.next()) |fd| : (count += 1) {
        _ = try fd.stream(&reader, out);
    }
    return count;
}

/// Checks that `bytes` reads as one entry holding `data`.
fn expectValid(bytes: []const u8) !void {
    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectEqual(1, try readAll(bytes, &got.writer));
    try std.testing.expectEqualStrings(data, got.written());
}

/// Checks that reading `bytes` fails with exactly `expected`.
fn expectReadError(expected: anyerror, bytes: []const u8) !void {
    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectError(expected, readAll(bytes, &got.writer));
}

test "builder: defaults make a valid one-entry archive" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{});
    try expectValid(b.bytes());
}

test "builder: a valid ZIP64 one-entry archive" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{});
    try expectValid(b.bytes());
}

test "builder: a valid entry with a data descriptor" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    const crc = std.hash.Crc32.hash(data);
    // Bit 3: CRC and sizes are zero in the local header and follow the data (APPNOTE 4.4.4).
    try b.local(.{ .flags = 1 << 3, .name = name });
    try b.raw(data);
    try b.descriptor(.{ .crc32 = crc, .compressed_size = data.len, .uncompressed_size = data.len });

    const cd_offset = b.pos();
    try b.central(.{
        .flags = 1 << 3,
        .crc32 = crc,
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .name = name,
    });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
    try expectValid(b.bytes());
}

test "hostile: central header on disk 1" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .disk_start = 1 });
    try expectReadError(error.ZipUnsupportedMultiDisk, b.bytes());
}

test "hostile: encrypted entry (flag bit 0)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .flags = 1 });
    try expectReadError(error.ZipUnsupportedEncryption, b.bytes());
}

test "hostile: method 12 (bzip2)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .method = 12 });
    try expectReadError(error.ZipUnsupportedCompressionMethod, b.bytes());
}

test "hostile: central directory offset past end of file" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .cd_offset = 0x00FF_FFFF });
    try expectReadError(error.ZipSizeOverflow, b.bytes());
}

test "hostile: ZIP64 locator points at the local header" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .eocd64_offset = 0 });
    try expectReadError(error.Zip64InvalidSignature, b.bytes());
}

test "hostile: ZIP64 end record with record_size < 44" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .record_size = 43 });
    try expectReadError(error.Zip64Malformed, b.bytes());
}

test "hostile: CRC field wrong in both headers" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .crc32 = std.hash.Crc32.hash(data) ^ 1 });
    try expectReadError(error.ZipCRC32Mismatch, b.bytes());
}

test "hostile: one data byte flipped in a stored entry" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{});
    // Data starts right after the 30-byte local header and the name.
    b.bytes()[30 + name.len] ^= 0x01;
    try expectReadError(error.ZipCRC32Mismatch, b.bytes());
}

test "regression: a central name that crosses the reader buffer (bug 23)" {
    // The reader skipped names and comments with toss(), which asserts unless the bytes are
    // already buffered. Streaming entry 0 refills the buffer from the end of its 30-byte
    // local header, leaving bytes [30, 30 + 4096) buffered. Entry 0's central comment is
    // sized so entry 1's central header ends 5 bytes before that edge, and its 20-byte
    // name runs past the buffered bytes. The archive comment keeps the file well past that
    // edge, so the fill can't stop at end of file instead.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const buf_len = 4096; // readAll's buffer
    const name1 = "b" ** 20;

    const off0 = try b.entry("a", data);
    const off1 = try b.entry(name1, data);
    const cd_offset = b.pos();
    const header_len = 46; // fixed part of a central header (APPNOTE 4.3.12)
    const edge = 30 + buf_len;
    const cd1 = edge - header_len - 5;
    const filler = "c" ** buf_len;
    const comment0 = filler[0 .. cd1 - (cd_offset + header_len + 1)];
    try b.central(.{
        .crc32 = std.hash.Crc32.hash(data),
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .offset = @intCast(off0),
        .name = "a",
        .comment = comment0,
    });
    try std.testing.expectEqual(cd1, b.pos());
    try b.central(.{
        .crc32 = std.hash.Crc32.hash(data),
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .offset = @intCast(off1),
        .name = name1,
    });
    try b.eocd(.{
        .entries = 2,
        .cd_size = @intCast(b.pos() - cd_offset),
        .cd_offset = @intCast(cd_offset),
        .comment = filler,
    });

    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectEqual(2, try readAll(b.bytes(), &got.writer));
    try std.testing.expectEqualStrings(data ++ data, got.written());
}

test "builder: ZIP64 end record with extensible data is skipped" {
    // record_size counts everything after itself (APPNOTE 4.3.14.1), so 60 means 16 bytes of
    // extensible data follow the fixed fields. The reader skips them.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const off = try b.entry(name, data);
    const cd_offset = b.pos();
    try b.central(.{
        .crc32 = std.hash.Crc32.hash(data),
        .compressed_size = data.len,
        .uncompressed_size = data.len,
        .offset = @intCast(off),
        .name = name,
    });
    const cd_size = b.pos() - cd_offset;
    const eocd64_offset = b.pos();
    try b.eocd64(.{ .record_size = 44 + 16, .entries = 1, .cd_size = cd_size, .cd_offset = cd_offset });
    try b.raw(&([_]u8{0xEE} ** 16));
    try b.locator64(.{ .eocd64_offset = eocd64_offset });
    try b.eocd(.{ .entries = 0xFFFF, .cd_size = 0xFFFF_FFFF, .cd_offset = 0xFFFF_FFFF });
    try expectValid(b.bytes());
}

test "hostile: ZIP64 end record extensible data runs past end of file" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .record_size = 44 + 4096 });
    try expectReadError(error.Zip64SizeOverflow, b.bytes());
}

test "hostile: ZIP64 EOCD with no room for a locator before it" {
    // An EOCD at offset 0 that asks for ZIP64 can't have the 20-byte locator in front of it.
    var b: Builder = .init(gpa);
    defer b.deinit();
    try b.eocd(.{ .entries = 0xFFFF, .cd_size = 0xFFFF_FFFF, .cd_offset = 0xFFFF_FFFF });
    try expectReadError(error.Zip64Malformed, b.bytes());
}

test "hostile: stored entry whose compressed and uncompressed sizes differ" {
    // Method 0 stores bytes as-is, so the two sizes must match.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const crc = std.hash.Crc32.hash(data);
    try b.local(.{ .crc32 = crc, .compressed_size = data.len, .uncompressed_size = data.len + 1, .name = name });
    try b.raw(data);
    const cd_offset = b.pos();
    try b.central(.{
        .crc32 = crc,
        .compressed_size = data.len,
        .uncompressed_size = data.len + 1,
        .name = name,
    });
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
    try expectReadError(error.ZipSizeMismatch, b.bytes());
}

/// Builds a one-entry stored archive of `data` from separate local and central options,
/// so a case can make the two headers disagree. `d` adds a data descriptor after the data.
fn split(b: *Builder, lo: Builder.LocalOptions, co: Builder.CentralOptions, d: ?Builder.DescriptorOptions) !void {
    try b.local(lo);
    try b.raw(data);
    if (d) |o| try b.descriptor(o);
    const cd_offset = b.pos();
    try b.central(co);
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
}

const crc_ok = std.hash.Crc32.hash(data);
const local_ok: Builder.LocalOptions = .{ .name = name, .crc32 = crc_ok, .compressed_size = data.len, .uncompressed_size = data.len };
const central_ok: Builder.CentralOptions = .{ .name = name, .crc32 = crc_ok, .compressed_size = data.len, .uncompressed_size = data.len };
const bit3: u16 = 1 << 3;
const desc_ok: Builder.DescriptorOptions = .{ .crc32 = crc_ok, .compressed_size = data.len, .uncompressed_size = data.len };

fn with(comptime T: type, base: T, comptime field: []const u8, value: anytype) T {
    var v = base;
    @field(v, field) = value;
    return v;
}

test "hostile: local name differs from the central name (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "name", "b.txt"), central_ok, null);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local name length differs from the central name (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "name", "ab.txt"), central_ok, null);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local method differs from the central method (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "method", 8), central_ok, null);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: data descriptor bit set only in the central header (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, local_ok, with(Builder.CentralOptions, central_ok, "flags", bit3), desc_ok);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local CRC differs from the central CRC" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "crc32", crc_ok ^ 1), central_ok, null);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local sizes differ from the central sizes" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    var lo = local_ok;
    lo.compressed_size = 2;
    lo.uncompressed_size = 2;
    try split(&b, lo, central_ok, null);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: data descriptor sizes differ from the central sizes (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    var d = desc_ok;
    d.compressed_size = 2;
    d.uncompressed_size = 2;
    try split(&b, .{ .flags = bit3, .name = name }, with(Builder.CentralOptions, central_ok, "flags", bit3), d);
    try expectReadError(error.ZipBadDataDescriptor, b.bytes());
}

test "hostile: data descriptor CRC differs from the central CRC (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, .{ .flags = bit3, .name = name }, with(Builder.CentralOptions, central_ok, "flags", bit3), with(Builder.DescriptorOptions, desc_ok, "crc32", crc_ok ^ 1));
    try expectReadError(error.ZipBadDataDescriptor, b.bytes());
}

test "hostile: local CRC under bit 3 is neither zero nor the central CRC" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, .{ .flags = bit3, .name = name, .crc32 = crc_ok ^ 1 }, with(Builder.CentralOptions, central_ok, "flags", bit3), desc_ok);
    try expectReadError(error.ZipLocalHeaderMismatch, b.bytes());
}

test "builder: bit 3 with real values in the local header is accepted" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "flags", bit3), with(Builder.CentralOptions, central_ok, "flags", bit3), desc_ok);
    try expectValid(b.bytes());
}

test "builder: a data descriptor without its signature is accepted" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, .{ .flags = bit3, .name = name }, with(Builder.CentralOptions, central_ok, "flags", bit3), with(Builder.DescriptorOptions, desc_ok, "signed", false));
    try expectValid(b.bytes());
}

/// Writes a one-entry archive of 1 MiB of 'A', deflated, into `out`.
fn deflatedMiB(out: *std.Io.Writer.Allocating) !void {
    const big = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(big);
    @memset(big, 'A');
    var zw: Writer = undefined;
    try zw.init(gpa, &out.writer);
    defer zw.deinit();
    try zw.addBytes(name, big, .{ .method = .deflate });
    try zw.finish();
}

/// Rewrites the uncompressed size in both headers of a one-entry archive: local header
/// offset 22 (APPNOTE 4.3.7), central header offset 24 (4.3.12). Checks the entry is deflated.
fn setUncompressedSize(bytes: []u8, size: u32) !void {
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, bytes[8..10], .little));
    std.mem.writeInt(u32, bytes[22..26], size, .little);
    const cd = std.mem.lastIndexOf(u8, bytes, "PK\x01\x02").?;
    std.mem.writeInt(u32, bytes[cd + 24 ..][0..4], size, .little);
}

test "hostile: central says 10 bytes, deflate stream gives 1 MiB (size lie)" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try deflatedMiB(&out);
    const bytes = out.written();
    try setUncompressedSize(bytes, 10);

    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectError(error.ZipSizeMismatch, readAll(bytes, &got.writer));
    try std.testing.expect(got.written().len <= 10);
}

test "hostile: central says 1 MiB + 10 bytes, deflate stream ends at 1 MiB" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try deflatedMiB(&out);
    try setUncompressedSize(out.written(), (1 << 20) + 10);

    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectError(error.ZipSizeMismatch, readAll(out.written(), &got.writer));
}
