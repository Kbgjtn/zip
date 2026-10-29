//! Hostile archives made with `testing/builder.zig` (design 12.4). Every case starts
//! from a valid archive and changes one field, so the reader error is the one that field causes.
const std = @import("std");
const Builder = @import("../testing/builder.zig");
const Writer = @import("../writer.zig");
const Archive = @import("../Archive.zig");
const Entry = @import("../Entry.zig");

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
    /// The EOCD entry count. 0xFFFF escapes it to the ZIP64 record.
    eocd_entries: u16 = 0xFFFF,
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
    try b.eocd(.{ .entries = c.eocd_entries, .cd_size = 0xFFFF_FFFF, .cd_offset = 0xFFFF_FFFF });
}

/// Writes `bytes` to a temporary file and calls `f(ctx, &iterator)` on it.
fn withArchive(bytes: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Archive) anyerror!void) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.zip", .data = bytes });
    var file = try tmp.dir.openFile(io, "in.zip", .{ .mode = .read_only });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var iter = try Archive.openFile(&reader);
    try f(ctx, &iter);
}

/// Reads every entry of `bytes` with `streamEntry` into `out`. Returns the entry count,
/// or the first error.
fn readAll(bytes: []const u8, out: *std.Io.Writer) !usize {
    const Ctx = struct {
        out: *std.Io.Writer,
        count: usize = 0,
        fn run(c: *@This(), iter: *Archive) !void {
            while (try iter.next()) |fd| : (c.count += 1) _ = try iter.streamEntry(&fd, c.out);
        }
    };
    var ctx: Ctx = .{ .out = out };
    try withArchive(bytes, &ctx, Ctx.run);
    return ctx.count;
}

/// Checks that every entry of `bytes` lists, that all but the last read back as `data`,
/// and that `streamEntry` and `readEntryAlloc` fail the last with exactly `expected`.
/// Listing reads only the central directory, so refusals and local header problems
/// show up here, on the read path, never in `next`.
fn expectListsButReadFails(expected: anyerror, bytes: []const u8) !void {
    const Ctx = struct {
        fn run(want: anyerror, iter: *Archive) !void {
            var last: ?Entry = null;
            while (try iter.next()) |fd| {
                if (last) |prev| {
                    const got = try iter.readEntryAlloc(gpa, &prev, 1 << 20);
                    defer gpa.free(got);
                    try std.testing.expectEqualStrings(data, got);
                }
                last = fd;
            }
            const fd = last orelse return error.TestUnexpectedEmptyArchive;
            var sink: std.Io.Writer.Discarding = .init(&.{});
            try std.testing.expectError(want, iter.streamEntry(&fd, &sink.writer));
            try std.testing.expectError(want, iter.readEntryAlloc(gpa, &fd, 1 << 20));
        }
    };
    try withArchive(bytes, expected, Ctx.run);
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

fn zip64DiskExtra(disk: u32) [8]u8 {
    var e: [8]u8 = undefined;
    std.mem.writeInt(u16, e[0..2], 0x0001, .little);
    std.mem.writeInt(u16, e[2..4], 4, .little);
    std.mem.writeInt(u32, e[4..8], disk, .little);
    return e;
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
    try expectReadError(error.ZipMultiDisk, b.bytes());
}

test "hostile: encrypted entry (flag bit 0) lists, but is refused when read" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .flags = 1 });
    try expectListsButReadFails(error.ZipEncrypted, b.bytes());
}

test "hostile: method 12 (bzip2) lists, but is refused when read" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .method = 12 });
    try expectListsButReadFails(error.ZipUnsupportedMethod, b.bytes());
}

test "hostile: central directory offset past end of file" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .cd_offset = 0x00FF_FFFF });
    try expectReadError(error.ZipMalformed, b.bytes());
}

test "hostile: ZIP64 locator points at the local header" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .eocd64_offset = 0 });
    try expectReadError(error.Zip64Malformed, b.bytes());
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
    try expectReadError(error.ZipCrcMismatch, b.bytes());
}

test "hostile: one data byte flipped in a stored entry" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{});
    // Data starts right after the 30-byte local header and the name.
    b.bytes()[30 + name.len] ^= 0x01;
    try expectReadError(error.ZipCrcMismatch, b.bytes());
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
    try expectReadError(error.Zip64Malformed, b.bytes());
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
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local name length differs from the central name (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "name", "ab.txt"), central_ok, null);
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local method differs from the central method (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "method", 8), central_ok, null);
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: data descriptor bit set only in the central header (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, local_ok, with(Builder.CentralOptions, central_ok, "flags", bit3), desc_ok);
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local CRC differs from the central CRC" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, with(Builder.LocalOptions, local_ok, "crc32", crc_ok ^ 1), central_ok, null);
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: local sizes differ from the central sizes" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    var lo = local_ok;
    lo.compressed_size = 2;
    lo.uncompressed_size = 2;
    try split(&b, lo, central_ok, null);
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
}

test "hostile: data descriptor sizes differ from the central sizes (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    var d = desc_ok;
    d.compressed_size = 2;
    d.uncompressed_size = 2;
    try split(&b, .{ .flags = bit3, .name = name }, with(Builder.CentralOptions, central_ok, "flags", bit3), d);
    try expectListsButReadFails(error.ZipBadDataDescriptor, b.bytes());
}

test "hostile: data descriptor CRC differs from the central CRC (bug 21)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, .{ .flags = bit3, .name = name }, with(Builder.CentralOptions, central_ok, "flags", bit3), with(Builder.DescriptorOptions, desc_ok, "crc32", crc_ok ^ 1));
    try expectListsButReadFails(error.ZipBadDataDescriptor, b.bytes());
}

test "hostile: local CRC under bit 3 is neither zero nor the central CRC" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, .{ .flags = bit3, .name = name, .crc32 = crc_ok ^ 1 }, with(Builder.CentralOptions, central_ok, "flags", bit3), desc_ok);
    try expectListsButReadFails(error.ZipLocalHeaderMismatch, b.bytes());
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

test "hostile: patched data (flag bit 5) lists, but is refused when read" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .flags = 1 << 5 });
    try expectListsButReadFails(error.ZipPatchedData, b.bytes());
}

test "hostile: strong encryption (flag bit 6) lists, but is refused when read" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .flags = 1 << 6 });
    try expectListsButReadFails(error.ZipEncrypted, b.bytes());
}

test "hostile: masked local header (flag bit 13) lists, but is refused when read" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry(&b, .{ .flags = 1 << 13 });
    try expectListsButReadFails(error.ZipCentralDirectoryEncrypted, b.bytes());
}

test "hostile: masked local name under bit 13 is refused when read, not a name mismatch" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    // APPNOTE 4.4.17.2: the masked local name is a hex counter. Bit 13 only in the local header.
    var lo = local_ok;
    lo.flags = 1 << 13;
    lo.name = "1";
    try split(&b, lo, central_ok, null);
    try expectListsButReadFails(error.ZipCentralDirectoryEncrypted, b.bytes());
}

/// Builds a two-entry archive: `name` with `data`, then the same entry with `flags` and
/// `method` in both headers.
fn mixed(b: *Builder, flags: u16, method: u16) !void {
    const off0 = try b.entry(name, data);
    const off1 = b.pos();
    var lo = local_ok;
    lo.flags = flags;
    lo.method = method;
    try b.local(lo);
    try b.raw(data);
    const cd_offset = b.pos();
    var co = central_ok;
    co.offset = @intCast(off0);
    try b.central(co);
    co.offset = @intCast(off1);
    co.flags = flags;
    co.method = method;
    try b.central(co);
    try b.eocd(.{ .entries = 2, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
}

test "hostile: mixed archive with an encrypted entry (bit 0) lists and reads the other" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try mixed(&b, 1, 0);
    try expectListsButReadFails(error.ZipEncrypted, b.bytes());
}

test "hostile: mixed archive with a patched entry (bit 5) lists and reads the other" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try mixed(&b, 1 << 5, 0);
    try expectListsButReadFails(error.ZipPatchedData, b.bytes());
}

test "hostile: mixed archive with a masked entry (bit 13) lists and reads the other" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try mixed(&b, 1 << 13, 0);
    try expectListsButReadFails(error.ZipCentralDirectoryEncrypted, b.bytes());
}

test "hostile: mixed archive with a bzip2 entry (method 12) lists and reads the other" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try mixed(&b, 0, 12);
    try expectListsButReadFails(error.ZipUnsupportedMethod, b.bytes());
}

test "hostile: mixed archive with an unknown method (99) lists and reads the other" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try mixed(&b, 0, 99);
    try expectListsButReadFails(error.ZipUnsupportedMethod, b.bytes());
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
    try expectAllocError(error.ZipSizeMismatch, bytes);
}

test "hostile: central says 1 MiB + 10 bytes, deflate stream ends at 1 MiB" {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try deflatedMiB(&out);
    try setUncompressedSize(out.written(), (1 << 20) + 10);

    var got: std.Io.Writer.Allocating = .init(gpa);
    defer got.deinit();
    try std.testing.expectError(error.ZipSizeMismatch, readAll(out.written(), &got.writer));
    try expectAllocError(error.ZipSizeMismatch, out.written());
}

/// Checks that `readEntryAlloc` on the only entry of `bytes` fails with exactly `expected`.
fn expectAllocError(expected: anyerror, bytes: []const u8) !void {
    const Ctx = struct {
        fn run(want: anyerror, iter: *Archive) !void {
            const fd = (try iter.next()) orelse return error.TestUnexpectedEmptyArchive;
            try std.testing.expectError(want, iter.readEntryAlloc(gpa, &fd, 2 << 20));
        }
    };
    try withArchive(bytes, expected, Ctx.run);
}

test "hostile: ZIP64 end record with record_size near the u64 limit" {
    // 12 + record_size fits a u64 but adding the record offset doesn't; that must be an
    // error, not an overflow panic.
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .record_size = std.math.maxInt(u64) - 12 });
    try expectReadError(error.Zip64Malformed, b.bytes());
}

test "hostile: local header offset 10 bytes before end of file gives ZipTruncated" {
    // The 30-byte local header read runs out of file: ZipTruncated, not EndOfStream.
    var probe: Builder = .init(gpa);
    defer probe.deinit();
    try split(&probe, local_ok, central_ok, null);
    const len = probe.bytes().len;

    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(&b, local_ok, with(Builder.CentralOptions, central_ok, "offset", @as(u32, @intCast(len - 10))), null);
    try std.testing.expectEqual(len, b.bytes().len);
    try expectListsButReadFails(error.ZipTruncated, b.bytes());
}

test "hostile: ZIP64 end record cut off by the end of file gives ZipTruncated" {
    // The locator points 4 bytes before the end, so the 56-byte record can't be read.
    var probe: Builder = .init(gpa);
    defer probe.deinit();
    try oneEntry64(&probe, .{});
    const len = probe.bytes().len;

    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .eocd64_offset = len - 4 });
    try std.testing.expectEqual(len, b.bytes().len);
    try expectReadError(error.ZipTruncated, b.bytes());
}

test "hostile: entry data runs into the central directory" {
    // Both headers say 5 more bytes than are stored, so the data would end inside the
    // central directory that follows it.
    var b: Builder = .init(gpa);
    defer b.deinit();
    var lo = local_ok;
    lo.compressed_size = data.len + 5;
    lo.uncompressed_size = data.len + 5;
    var co = central_ok;
    co.compressed_size = data.len + 5;
    co.uncompressed_size = data.len + 5;
    try split(&b, lo, co, null);
    try expectListsButReadFails(error.ZipMalformed, b.bytes());
}

test "hostile: entry data runs past the end of the file" {
    // Only the compressed size is huge, so readEntryAlloc's size limit doesn't fire first.
    var b: Builder = .init(gpa);
    defer b.deinit();
    var lo = local_ok;
    lo.compressed_size = 0x7FFF_FFFF;
    var co = central_ok;
    co.compressed_size = 0x7FFF_FFFF;
    try split(&b, lo, co, null);
    try expectListsButReadFails(error.ZipMalformed, b.bytes());
}

test "hostile: ZIP64 compressed size near 2^64 overflows the data end" {
    // The central compressed size is escaped and its ZIP64 extra (APPNOTE 4.5.3) holds a
    // value that overflows when added to the data start: an error, not a panic.
    var zip64_extra: [12]u8 = undefined;
    std.mem.writeInt(u16, zip64_extra[0..2], 0x0001, .little);
    std.mem.writeInt(u16, zip64_extra[2..4], 8, .little);
    std.mem.writeInt(u64, zip64_extra[4..12], std.math.maxInt(u64) - 10, .little);

    var b: Builder = .init(gpa);
    defer b.deinit();
    var co = central_ok;
    co.compressed_size = 0xFFFF_FFFF;
    co.extra = &zip64_extra;
    try split(&b, local_ok, co, null);
    try expectListsButReadFails(error.ZipMalformed, b.bytes());
}

test "builder: fileName gives the central name even when the local name is masked" {
    // Under bit 13 the local name is a placeholder (APPNOTE 4.4.17.2); the listed name is
    // the central one.
    var b: Builder = .init(gpa);
    defer b.deinit();
    var lo = local_ok;
    lo.flags = 1 << 13;
    lo.name = "1";
    try split(&b, lo, central_ok, null);

    const Ctx = struct {
        fn run(_: void, iter: *Archive) !void {
            const fd = (try iter.next()) orelse return error.TestUnexpectedEmptyArchive;
            var buf: [16]u8 = undefined;
            try std.testing.expectEqualStrings(name, try fd.fileName(&iter.source, &buf));
        }
    };
    try withArchive(b.bytes(), {}, Ctx.run);
}

test "builder: disk start 0xFFFF with disk 0 in the ZIP64 extra is accepted (bug 9)" {
    // 0xFFFF means "see the ZIP64 extra" (APPNOTE 4.5.3)
    const extra = zip64DiskExtra(0);
    var b: Builder = .init(gpa);
    defer b.deinit();
    var co = central_ok;
    co.disk_start = 0xFFFF;
    co.extra = &extra;
    try split(&b, local_ok, co, null);
    try expectValid(b.bytes());
}

test "builder: ZIP64 archive whose EOCD count is real and agrees" {
    // Writers like Python's zipfile escape only the fields that overflow (APPNOTE 4.4.1.4).
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .eocd_entries = 1 });
    try expectValid(b.bytes());
}

test "hostile: EOCD entry count disagrees with the ZIP64 end record" {
    // 2 isn't the escape value, so it must equal the ZIP64 count of 1 (APPNOTE 4.3.16).
    var b: Builder = .init(gpa);
    defer b.deinit();
    try oneEntry64(&b, .{ .eocd_entries = 2 });
    try expectReadError(error.ZipCentralDirectoryMismatch, b.bytes());
}

test "hostile: disk start 0xFFFF with disk 1 in the ZIP64 extra (bug 9)" {
    // 0xFFFF means "see the ZIP64 extra" (APPNOTE 4.5.3)
    const extra = zip64DiskExtra(1);
    var b: Builder = .init(gpa);
    defer b.deinit();
    var co = central_ok;
    co.disk_start = 0xFFFF;
    co.extra = &extra;
    try split(&b, local_ok, co, null);
    try expectReadError(error.ZipMultiDisk, b.bytes());
}

test "hostile: malformed local extra under bit 3 (bug 13)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    try split(
        &b,
        .{ .flags = bit3, .name = name, .extra = &.{ 0x01, 0x00, 0x08 } },
        with(Builder.CentralOptions, central_ok, "flags", bit3),
        desc_ok,
    );
    try expectListsButReadFails(error.ZipBadExtraField, b.bytes());
}

test "hostile: central directory holds more headers than the end record counts" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    const off = try b.entry(name, data);
    const cd_offset = b.pos();
    try b.central(central_ok);
    try b.central(with(Builder.CentralOptions, central_ok, "offset", @as(u32, @intCast(off))));
    try b.eocd(.{ .entries = 1, .cd_size = @intCast(b.pos() - cd_offset), .cd_offset = @intCast(cd_offset) });
    try expectReadError(error.ZipCentralDirectoryMismatch, b.bytes());
}

/// An extra field (APPNOTE 4.5.1): id, data size, then `data`.
fn extraField(comptime id: u16, comptime field_data: []const u8) [4 + field_data.len]u8 {
    var e: [4 + field_data.len]u8 = undefined;
    std.mem.writeInt(u16, e[0..2], id, .little);
    std.mem.writeInt(u16, e[2..4], field_data.len, .little);
    @memcpy(e[4..], field_data);
    return e;
}

/// A 0x7075 Unicode Path field (APPNOTE 4.6.9): `version`, the CRC-32 `crc`, then `utf8`.
fn unicodePathExtra(comptime version: u8, comptime crc: u32, comptime utf8: []const u8) [9 + utf8.len]u8 {
    const crc_bytes = comptime std.mem.toBytes(std.mem.nativeToLittle(u32, crc));
    return extraField(0x7075, &([_]u8{version} ++ crc_bytes ++ utf8[0..utf8.len].*));
}

/// Builds one entry named `name` whose central header has `co`'s made-by, attributes,
/// times and extra, then lists it from memory.
fn listOne(b: *Builder, co: Builder.CentralOptions) !struct { Archive, Entry } {
    var lo = local_ok;
    lo.name = co.name;
    try split(b, lo, co, null);
    var archive = try Archive.openMemory(b.bytes());
    const fd = (try archive.next()) orelse return error.TestUnexpectedEmptyArchive;
    return .{ archive, fd };
}

test "builder: 0x7075 Unicode path whose CRC matches the name gives the UTF-8 name" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    const up = unicodePathExtra(1, comptime std.hash.Crc32.hash(name), "ä.txt");
    var archive, const fd = try listOne(&b, with(Builder.CentralOptions, central_ok, "extra", &up));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ä.txt", (try fd.unicodeName(&archive.source, &buf)).?);
    try std.testing.expectError(error.InsufficientBufferSize, fd.unicodeName(&archive.source, buf[0..2]));
}

test "builder: 0x7075 Unicode path with a stale CRC is ignored (APPNOTE 4.6.9)" {
    // The CRC is of another name, as when a tool renames the entry and keeps the field.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const up = unicodePathExtra(1, comptime std.hash.Crc32.hash("old.txt"), "ä.txt");
    var archive, const fd = try listOne(&b, with(Builder.CentralOptions, central_ok, "extra", &up));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(null, try fd.unicodeName(&archive.source, &buf));
}

test "builder: 0x7075 Unicode path of an unknown version is ignored (APPNOTE 4.6.9)" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    const up = unicodePathExtra(2, comptime std.hash.Crc32.hash(name), "ä.txt");
    var archive, const fd = try listOne(&b, with(Builder.CentralOptions, central_ok, "extra", &up));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(null, try fd.unicodeName(&archive.source, &buf));
}

test "builder: no 0x7075 field gives no Unicode name" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    var archive, const fd = try listOne(&b, central_ok);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(null, try fd.unicodeName(&archive.source, &buf));
}

test "hostile: 0x7075 Unicode path too short for its version and CRC" {
    // Listing doesn't parse 0x7075, so only unicodeName sees the broken field.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const up = extraField(0x7075, &.{ 1, 0, 0, 0 });
    var archive, const fd = try listOne(&b, with(Builder.CentralOptions, central_ok, "extra", &up));
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.ZipBadExtraField, fd.unicodeName(&archive.source, &buf));
}

test "hostile: malformed 0x5455 in the central extra fails next" {
    // Flags say mtime, but 3 bytes follow instead of 4 (Info-ZIP extrafld.txt).
    var b: Builder = .init(gpa);
    defer b.deinit();
    const ut = extraField(0x5455, &.{ 0x01, 0, 0, 0 });
    try split(&b, local_ok, with(Builder.CentralOptions, central_ok, "extra", &ut), null);
    try expectReadError(error.ZipBadExtraField, b.bytes());
}

test "hostile: malformed 0x7875 in the central extra fails next" {
    // uid_size says 4 bytes, only 2 are there (Info-ZIP extrafld.txt).
    var b: Builder = .init(gpa);
    defer b.deinit();
    const ux = extraField(0x7875, &.{ 1, 4, 0xE8, 0x03 });
    try split(&b, local_ok, with(Builder.CentralOptions, central_ok, "extra", &ux), null);
    try expectReadError(error.ZipBadExtraField, b.bytes());
}

test "builder: central 0x5455 whose flags claim three times holds only mtime" {
    // extrafld.txt: the central flags refer to the local field; only mtime is stored.
    var b: Builder = .init(gpa);
    defer b.deinit();
    const ut = extraField(0x5455, &[_]u8{0x07} ++ std.mem.toBytes(std.mem.nativeToLittle(i32, 1_600_000_000)));
    const ux = extraField(0x7875, &.{ 1, 2, 0x39, 0x30, 0 });
    _, const fd = try listOne(&b, with(Builder.CentralOptions, central_ok, "extra", &(ut ++ ux)));
    try std.testing.expectEqual(@as(?i64, 1_600_000_000), fd.mtime);
    try std.testing.expectEqual(1_600_000_000, fd.modTime());
    try std.testing.expectEqual(@as(?u32, 12345), fd.uid);
    try std.testing.expectEqual(@as(?u32, null), fd.gid); // gid_size 0
}

test "builder: without 0x5455, modTime reads the DOS fields as UTC" {
    // 2020-09-13 12:26:40 in DOS format (APPNOTE 4.4.6).
    var b: Builder = .init(gpa);
    defer b.deinit();
    var co = central_ok;
    co.time = (12 << 11) | (26 << 5) | (40 / 2);
    co.date = ((2020 - 1980) << 9) | (9 << 5) | 13;
    _, const fd = try listOne(&b, co);
    try std.testing.expectEqual(@as(?i64, null), fd.mtime);
    try std.testing.expectEqual(1_600_000_000, fd.modTime());
    try std.testing.expectEqual(@as(?u32, null), fd.uid);
    try std.testing.expectEqual(@as(?u32, null), fd.gid);
}

test "builder: unixMode and kind from the made-by OS, the attributes and the name" {
    const unix: u16 = (3 << 8) | 30;
    const osx: u16 = (19 << 8) | 30;
    const ms_dos: u16 = (0 << 8) | 20;
    const ntfs: u16 = (10 << 8) | 20;
    const Row = struct { made_by: u16, attrs: u32, name: []const u8 = name, mode: ?u32, kind: Entry.Kind };
    const rows = [_]Row{
        .{ .made_by = unix, .attrs = 0o100644 << 16, .mode = 0o100644, .kind = .file },
        .{ .made_by = osx, .attrs = (0o040755 << 16) | 0x10, .mode = 0o040755, .kind = .directory },
        .{ .made_by = unix, .attrs = 0o120777 << 16, .mode = 0o120777, .kind = .symlink },
        .{ .made_by = unix, .attrs = 0o010644 << 16, .mode = 0o010644, .kind = .other }, // fifo
        // No type bits: some Unix writers leave the mode 0, so the MS-DOS byte decides.
        .{ .made_by = unix, .attrs = 0x10, .mode = 0, .kind = .directory },
        .{ .made_by = unix, .attrs = 0, .mode = 0, .kind = .file },
        // Not Unix: the high bits aren't a mode, whatever they hold (APPNOTE 4.4.15).
        .{ .made_by = ms_dos, .attrs = (0o120777 << 16) | 0x10, .mode = null, .kind = .directory },
        .{ .made_by = ntfs, .attrs = 0x20, .mode = null, .kind = .file }, // archive bit
        // A trailing '/' wins over the attributes, as in extractEntry.
        .{ .made_by = unix, .attrs = 0o100644 << 16, .name = "d/", .mode = 0o100644, .kind = .directory },
        .{ .made_by = ms_dos, .attrs = 0, .name = "d/", .mode = null, .kind = .directory },
    };
    for (rows) |r| {
        var b: Builder = .init(gpa);
        defer b.deinit();
        var co = central_ok;
        co.version_made_by = r.made_by;
        co.external_attributes = r.attrs;
        co.name = r.name;
        _, const fd = try listOne(&b, co);
        try std.testing.expectEqual(r.mode, fd.unixMode());
        try std.testing.expectEqual(r.kind, fd.kind());
    }
}

test "builder: nameIsUtf8 reports bit 11 and fileComment reads the comment" {
    var b: Builder = .init(gpa);
    defer b.deinit();
    var co = central_ok;
    // An unknown field before the comment, so the comment offset has to skip it.
    const unknown = extraField(0xCAFE, "x");
    co.flags = 1 << 11;
    co.extra = &unknown;
    co.comment = "note";
    var archive, const fd = try listOne(&b, co);
    try std.testing.expect(fd.nameIsUtf8());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("note", try fd.fileComment(&archive.source, &buf));
    try std.testing.expectError(error.InsufficientBufferSize, fd.fileComment(&archive.source, buf[0..3]));
}
