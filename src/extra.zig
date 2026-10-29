const std = @import("std");
const log = std.log.scoped(.zip);
const zip = @import("format.zig");

// TODO change to zip.HeaderId
// Zig enforces ordered must be the same as enum field
pub const Context = union(enum) {
    zip64_extended_extra_field: struct {
        uncompressed_size: ?u32,
        compressed_size: ?u32,
        local_file_header_relative_offset: ?u32,
        disk_number_start: ?u16,
    },
    none: void,
};

// TODO change to zip.HeaderId
// Zig enforces ordered must be the same as enum field
pub const ParsedMetadata = union(enum) {
    zip64_extended_extra_field: Zip64Extended,
    extended_timestamp: ExtendedTimestamp,
    info_zip_unix_new: InfoZipNewUnix,
};

/// What every field parser returns. Data that runs short or has bytes left over is
/// `ZipBadExtraField` (APPNOTE 4.5.1).
const ParseError = error{ZipBadExtraField};

pub const Zip64Extended = struct {
    uncompressed_size: u64 = 0,
    compressed_size: u64 = 0,
    local_file_header_relative_offset: u64 = 0,
    disk_number_start: u32 = 0,

    fn parse(data: []const u8, ctx: Context) ParseError!ParsedMetadata {
        return parseFields(data, ctx) catch return error.ZipBadExtraField;
    }

    /// Fields appear only for header values that are all ones, in a fixed order (APPNOTE 4.5.3).
    fn parseFields(data: []const u8, ctx: Context) !ParsedMetadata {
        var output: Zip64Extended = .{};
        var reader = std.Io.Reader.fixed(data);

        if (ctx.zip64_extended_extra_field.uncompressed_size) |v| {
            output.uncompressed_size =
                if (v == 0xFFFFFFFF) try reader.takeInt(u64, .little) else @intCast(v);
        }

        if (ctx.zip64_extended_extra_field.compressed_size) |v| {
            output.compressed_size =
                if (v == 0xFFFFFFFF) try reader.takeInt(u64, .little) else @intCast(v);
        }

        if (ctx.zip64_extended_extra_field.local_file_header_relative_offset) |v| {
            output.local_file_header_relative_offset =
                if (v == 0xFFFFFFFF)
                    try reader.takeInt(u64, .little)
                else
                    @intCast(v);
        }

        if (ctx.zip64_extended_extra_field.disk_number_start) |v| {
            output.disk_number_start =
                if (v == 0xFFFF)
                    try reader.takeInt(u32, .little)
                else
                    @intCast(v);
        }

        if (reader.seek != data.len) return error.ZipBadExtraField;
        return .{ .zip64_extended_extra_field = output };
    }
};

// TODO add test cases
test "parse ZIP64 extended information" {
    const ef: Field = .{ .data = &[_]u8{ 6, 0, 0, 0, 0, 0, 0, 0 }, .id = 0x1 };
    const parsed = try Zip64Extended.parse(ef.data, .{
        .zip64_extended_extra_field = .{
            .compressed_size = 6,
            .uncompressed_size = 4294967295,
            .local_file_header_relative_offset = 0,
            .disk_number_start = 0,
        },
    });

    try std.testing.expect(parsed.zip64_extended_extra_field.disk_number_start == 0);
    try std.testing.expect(@TypeOf(parsed.zip64_extended_extra_field.disk_number_start) == u32);
    try std.testing.expect(parsed.zip64_extended_extra_field.local_file_header_relative_offset == 0);
    try std.testing.expect(@TypeOf(parsed.zip64_extended_extra_field.local_file_header_relative_offset) == u64);
    try std.testing.expect(parsed.zip64_extended_extra_field.uncompressed_size == 6);
    try std.testing.expect(@TypeOf(parsed.zip64_extended_extra_field.uncompressed_size) == u64);
    try std.testing.expect(parsed.zip64_extended_extra_field.compressed_size == 6);
    try std.testing.expect(@TypeOf(parsed.zip64_extended_extra_field.compressed_size) == u64);
}

pub const ExtendedTimestamp = struct {
    mod_time_unix: ?i32 = null,
    access_time_unix: ?i32 = null,
    creation_time_unix: ?i32 = null,

    // TODO (dapa) unit test
    fn parse(data: []const u8, _: Context) ParseError!ParsedMetadata {
        var output: ExtendedTimestamp = .{};
        if (data.len < 1) return error.ZipBadExtraField;

        const flags = data[0];
        var offset: usize = 1;

        if ((flags & 0x01) != 0 and offset + 4 <= data.len) {
            output.mod_time_unix = std.mem.readInt(i32, data[offset..][0..4], .little);
            offset += 4;
        }

        if ((flags & 0x02) != 0 and offset + 4 <= data.len) {
            output.access_time_unix = std.mem.readInt(i32, data[offset..][0..4], .little);
            offset += 4;
        }

        if ((flags & 0x04) != 0 and offset + 4 <= data.len) {
            output.creation_time_unix = std.mem.readInt(i32, data[offset..][0..4], .little);
            offset += 4;
        }

        if (offset != data.len) return error.ZipBadExtraField;
        return .{ .extended_timestamp = output };
    }
};

/// Currently stores Unix UIDs/GIDs up to 32 bits.
///         Value         Size        Description
///         -----         ----        -----------
/// (UnixN) 0x7875        Short       tag for this extra block type ("ux")
///         TSize         Short       total data size for this block
///         Version       1 byte      version of this extra field, currently 1
///         UIDSize       1 byte      Size of UID field
///         UID           Variable    UID for this entry
///         GIDSize       1 byte      Size of GID field
///         GID           Variable    GID for this entry
const InfoZipNewUnix = struct {
    version: ?u8,
    uid: ?u32,
    gid: ?u32,

    // TODO (dapa) unit test
    fn parse(data: []const u8, _: Context) ParseError!ParsedMetadata {
        return parseFields(data) catch return error.ZipBadExtraField;
    }

    fn parseFields(data: []const u8) !ParsedMetadata {
        var output: InfoZipNewUnix = .{ .gid = null, .uid = null, .version = null };
        if (data.len < 1) return error.ZipBadExtraField;

        var reader: std.Io.Reader = .fixed(data);

        // version of this extra field, currently 1
        output.version = try reader.takeByte();
        if (output.version != 1) return error.ZipBadExtraField;

        const uid_size = try reader.takeByte();
        if (uid_size > 4) return error.ZipBadExtraField;
        output.uid = if (uid_size == 0)
            null
        else
            std.mem.readVarInt(u32, try reader.take(uid_size), .little);

        const gid_size = try reader.takeByte();
        if (gid_size > 4) return error.ZipBadExtraField;
        output.gid = if (gid_size == 0)
            null
        else
            std.mem.readVarInt(u32, try reader.take(gid_size), .little);

        if (reader.seek != data.len) return error.ZipBadExtraField;
        return .{ .info_zip_unix_new = output };
    }
};

pub const Field = struct {
    id: u16,
    data: []const u8,

    pub fn asHeaderID(self: Field) ?zip.HeaderId {
        return std.enums.fromInt(zip.HeaderId, self.id) orelse null;
    }

    /// Parses the field, or returns null for an id this library doesn't parse, known or
    /// not, so callers skip it instead of failing. The field layout is APPNOTE 4.5.1.
    pub fn parse(self: Field, ctx: Context) ParseError!?ParsedMetadata {
        const id = self.asHeaderID() orelse return null;
        return switch (id) {
            .zip64_extended_extra_field => try Zip64Extended.parse(self.data, ctx),
            .extended_timestamp => try ExtendedTimestamp.parse(self.data, ctx),
            .info_zip_unix_new => try InfoZipNewUnix.parse(self.data, ctx),
            else => null,
        };
    }
};

test "extra field header id" {
    {
        const f: Field = .{ .id = 0x0001, .data = undefined };
        try std.testing.expect(f.asHeaderID() == zip.HeaderId.zip64_extended_extra_field);
    }

    {
        const f: Field = .{ .id = 0xFFFF, .data = undefined };
        try std.testing.expect(f.asHeaderID() == null);
    }
}

test "extra field parse" {
    // zero fields
    {
        const f: Field = .{ .id = 0x0001, .data = &.{} };
        const output = try f.parse(.{
            .zip64_extended_extra_field = .{
                .compressed_size = 0,
                .uncompressed_size = 0,
                .disk_number_start = 0,
                .local_file_header_relative_offset = 0,
            },
        });

        const expected: ParsedMetadata = .{
            .zip64_extended_extra_field = .{
                .compressed_size = 0,
                .uncompressed_size = 0,
                .disk_number_start = 0,
                .local_file_header_relative_offset = 0,
            },
        };

        try std.testing.expectEqualDeep(output.?, expected);
    }
}

// TODO (dapa) unit test
pub const Iterator = struct {
    buf: []const u8,
    offset: usize = 0,

    pub fn find(self: Iterator, header_id: zip.HeaderId) ?Field {
        var it = self;
        while (true) {
            const field = it.next() catch return null;
            if (field == null) return null;
            if (field.?.id == @intFromEnum(header_id)) return field.?;
        }
    }

    pub fn next(self: *Iterator) !?Field {
        if (self.offset == self.buf.len) {
            return null;
        }

        if (self.offset + 4 > self.buf.len) {
            return error.ZipBadExtraField;
        }

        const id = std.mem.readInt(u16, self.buf[self.offset..][0..2], .little);
        const size = std.mem.readInt(u16, self.buf[self.offset + 2 ..][0..2], .little);
        self.offset += 4;

        if (self.offset + size > self.buf.len) {
            return error.ZipBadExtraField;
        }

        const data = self.buf[self.offset .. self.offset + size];
        defer {
            self.offset += size;
        }
        return Field{ .id = id, .data = data };
    }
};

test "iterator" {
    var extra = [_]u8{
        85, 84, 5, 0, 3, 4, 210, 153, 105, // 0x5455
        117, 120, 11, 0, 1, 4, 232, 3, 0, 0, 4, 232, 3, 0, 0, //   0x7875
        1, 0, 8, 0, 6, 0, 0, 0, 0, 0, 0, 0, // 0x0001
    };

    var iter: Iterator = .{ .buf = &extra };
    var extraMeta: ParsedMetadata = undefined;

    while (try iter.next()) |f| {
        const id = f.asHeaderID() orelse return error.BadHeaderId;
        switch (id) {
            .extended_timestamp, .info_zip_unix_new => {
                extraMeta = (try f.parse(.none)).?;
            },
            .zip64_extended_extra_field => {
                const ctx: Context = .{
                    .zip64_extended_extra_field = .{
                        .compressed_size = 6,
                        .disk_number_start = 0,
                        .uncompressed_size = 4294967295,
                        .local_file_header_relative_offset = 0,
                    },
                };
                extraMeta = (try f.parse(ctx)).?;
            },
            else => {
                log.warn("unsupported parser for the given HeaderId {}", .{id});
                continue;
            },
        }
    }
}

test "zip64 extra: leftover bytes after the declared fields are malformed" {
    // Only uncompressed_size is 0xFFFFFFFF, so exactly 8 bytes belong here; 8 more are junk.
    const data = [_]u8{ 6, 0, 0, 0, 0, 0, 0, 0 } ++ [_]u8{0xAA} ** 8;
    try std.testing.expectError(error.ZipBadExtraField, Zip64Extended.parse(&data, .{
        .zip64_extended_extra_field = .{
            .uncompressed_size = 0xFFFFFFFF,
            .compressed_size = 6,
            .local_file_header_relative_offset = 0,
            .disk_number_start = 0,
        },
    }));
}

test "info-zip unix extra: reads uid/gid by declared size and rejects trailing bytes" {
    // version 1, uid_size 4, uid 1000, gid_size 4, gid 1000 (what Info-ZIP writes on Linux)
    const full = [_]u8{ 1, 4, 0xE8, 0x03, 0, 0, 4, 0xE8, 0x03, 0, 0 };
    const p = (try InfoZipNewUnix.parse(&full, .none)).info_zip_unix_new;
    try std.testing.expectEqual(@as(?u8, 1), p.version);
    try std.testing.expectEqual(@as(?u32, 1000), p.uid);
    try std.testing.expectEqual(@as(?u32, 1000), p.gid);

    // 2-byte ids: previously read as u32, overrunning into the gid_size byte
    const short = [_]u8{ 1, 2, 0x39, 0x30, 2, 0x31, 0xD4 };
    const s = (try InfoZipNewUnix.parse(&short, .none)).info_zip_unix_new;
    try std.testing.expectEqual(@as(?u32, 12345), s.uid);
    try std.testing.expectEqual(@as(?u32, 54321), s.gid);

    // zero-size ids are absent, not garbage
    const none = [_]u8{ 1, 0, 0 };
    const n = (try InfoZipNewUnix.parse(&none, .none)).info_zip_unix_new;
    try std.testing.expectEqual(@as(?u32, null), n.uid);
    try std.testing.expectEqual(@as(?u32, null), n.gid);

    try std.testing.expectError(error.ZipBadExtraField, InfoZipNewUnix.parse(&(full ++ [_]u8{0}), .none));
    try std.testing.expectError(error.ZipBadExtraField, InfoZipNewUnix.parse(&[_]u8{ 1, 5, 0, 0, 0, 0, 0, 0 }, .none));
}

test "extended timestamp extra: all three times, and the central-directory short form" {
    // flags 0x07, mtime 1_600_000_000, atime 1_600_000_100, ctime 1_600_000_200
    var data: [13]u8 = undefined;
    data[0] = 0x07;
    std.mem.writeInt(u32, data[1..5], 1_600_000_000, .little);
    std.mem.writeInt(u32, data[5..9], 1_600_000_100, .little);
    std.mem.writeInt(u32, data[9..13], 1_600_000_200, .little);
    const t = (try ExtendedTimestamp.parse(&data, .none)).extended_timestamp;
    try std.testing.expectEqual(@as(?i32, 1_600_000_000), t.mod_time_unix);
    try std.testing.expectEqual(@as(?i32, 1_600_000_100), t.access_time_unix);
    try std.testing.expectEqual(@as(?i32, 1_600_000_200), t.creation_time_unix);

    // In the central directory the flags still say 0x07 but only mtime is stored (5 bytes).
    const c = (try ExtendedTimestamp.parse(data[0..5], .none)).extended_timestamp;
    try std.testing.expectEqual(@as(?i32, 1_600_000_000), c.mod_time_unix);
    try std.testing.expectEqual(@as(?i32, null), c.access_time_unix);
    try std.testing.expectEqual(@as(?i32, null), c.creation_time_unix);

    try std.testing.expectError(error.ZipBadExtraField, ExtendedTimestamp.parse(&(data ++ [_]u8{0}), .none));
}
