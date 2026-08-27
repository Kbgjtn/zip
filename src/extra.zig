const std = @import("std");
const zip = @import("zip.zig");

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

fn Handler(comptime id: zip.HeaderId) type {
    return switch (id) {
        .zip64_extended_extra_field => Zip64Extended,
        .extended_timestamp => ExtendedTimestamp,
        .info_zip_unix_new => InfoZipNewUnix,
        else => UnimplementedParser,
    };
}

const UnimplementedParser = struct {
    pub fn parse(data: []const u8, ctx: Context) !ParsedMetadata {
        _ = data;
        _ = ctx;
        return error.Unimplemented;
    }
};

pub const Zip64Extended = struct {
    uncompressed_size: u64 = 0,
    compressed_size: u64 = 0,
    local_file_header_relative_offset: u64 = 0,
    disk_number_start: u32 = 0,

    fn parse(
        data: []const u8,
        ctx: Context,
    ) !ParsedMetadata {
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

        if (reader.end != data.len) return error.Malformed;
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
    mod_time_unix: ?u32 = null,
    access_time_unix: ?u32 = null,
    creation_time_unix: ?u32 = null,

    // TODO (dapa) unit test
    fn parse(data: []const u8, _: Context) !ParsedMetadata {
        var output: ExtendedTimestamp = .{};
        if (data.len < 1) return error.Empty;

        const flags = data[0];
        var offset: usize = 1;

        if ((flags & 0x01) != 0 and offset + 4 <= data.len) {
            output.mod_time_unix = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
        }

        if ((flags & 0x02) != 0 and offset + 4 <= data.len) {
            output.access_time_unix = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;
        }

        if ((flags & 0x04) != 0 and offset + 4 <= data.len) {
            output.creation_time_unix = std.mem.readInt(u32, data[offset..][0..4], .little);
        }

        if (offset != data.len) {
            return error.Malformed;
        }

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
    fn parse(data: []const u8, _: Context) !ParsedMetadata {
        var output: InfoZipNewUnix = undefined;
        if (data.len < 1) return error.Empty;

        var reader: std.Io.Reader = .fixed(data);

        // version of this extra field, currently 1
        output.version = try reader.takeByte();
        if (output.version != 1) {
            return error.BadVersion;
        }

        const uid_size = try reader.takeByte();
        if (uid_size > 0 and reader.seek + uid_size <= data.len) {
            output.uid = try reader.takeInt(u32, .little);
        }

        const gid_size = try reader.takeByte();
        if (gid_size > 0 and reader.seek + gid_size <= data.len) {
            output.gid = try reader.takeInt(u32, .little);
        }

        if (reader.end != data.len) {
            return error.Malformed;
        }

        return .{ .info_zip_unix_new = output };
    }
};

pub const Field = struct {
    id: u16,
    data: []const u8,

    pub fn asHeaderID(self: Field) ?zip.HeaderId {
        return std.enums.fromInt(zip.HeaderId, self.id) orelse null;
    }

    pub fn parse(self: Field, ctx: Context) !ParsedMetadata {
        // NOTE (dapa)
        // converting runtime ID into enum HeaderId type, handling unknown
        // correct me if Im wrong, because value known at runtime cannot be
        // used at comptime.
        // we do not need asHeaderID to comptime, anyway!
        const id = self.asHeaderID() orelse return error.Unknown;

        // then, we dispatch to the correct parser using compile-time mapping
        return switch (id) {
            inline else => |comptime_id| {
                return try Handler(comptime_id).parse(self.data, ctx);
            },
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
        const f: Field = .{ .id = 0x0001, .data = &[_]u8{0} ** 8 };
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

        try std.testing.expectEqualDeep(output, expected);
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
            return error.BadExtraField;
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
                extraMeta = try f.parse(.none);
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
                extraMeta = try f.parse(ctx);
            },
            else => {
                std.debug.print("unsupported parser for the given HeaderId {}\n", .{id});
                continue;
            },
        }
    }
}
