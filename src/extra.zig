//! Extra field parsing for local and central file headers.
//!
//! An extra block is a sequence of fields with no padding between them. Each field is a
//! little-endian `u16` header id, a `u16` data size, and that many bytes of data
//! (APPNOTE 4.5.1). `Iterator` splits a block into `Field`s; the payload structs parse
//! the data of the fields this library reads:
//!
//! * 0x0001, ZIP64 extended information: `Zip64` (APPNOTE 4.5.3).
//! * 0x5455, extended timestamp: `ExtendedTimestamp` (Info-ZIP extrafld.txt).
//! * 0x7875, Info-ZIP New Unix: `InfoZipUnixNew` (Info-ZIP extrafld.txt).
//! * 0x7075, Info-ZIP Unicode Path: `InfoZipUnicodePath` (APPNOTE 4.6.9, Info-ZIP extrafld.txt).
//!
//! All parsers are strict: data that runs short, or has bytes left over after the
//! fields it declares, is `error.ZipBadExtraField`.
//!
//! Specifications:
//! * https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt
//! * https://libzip.org/specifications/extrafld.txt

const std = @import("std");
const zip = @import("format.zig");
const escaped32 = zip.escaped32;
const escaped16 = zip.escaped16;

/// The only error extra field parsing returns: a block or field whose bytes don't match
/// its layout.
pub const Error = error{ZipBadExtraField};

/// The 32-bit header values a ZIP64 extended information field extends.
///
/// A value of all ones (0xFFFFFFFF, or 0xFFFF for `disk_number_start`) means its real
/// value is in the field. Null means the header has no such value, as for the offset and
/// disk number of a local header, and the field holds nothing for it.
pub const Zip64Header = struct {
    /// Uncompressed size from the header.
    uncompressed_size: ?u32 = null,
    /// Compressed size from the header.
    compressed_size: ?u32 = null,
    /// Offset of the local header, from a central header.
    local_header_offset: ?u32 = null,
    /// Number of the disk the entry starts on, from a central header.
    disk_number_start: ?u16 = null,
};

/// ZIP64 extended information extra field, header id 0x0001 (APPNOTE 4.5.3).
///
/// Values are the header's own unless it escaped them; absent values are zero.
pub const Zip64 = struct {
    /// Uncompressed size of the entry.
    uncompressed_size: u64 = 0,
    /// Compressed size of the entry.
    compressed_size: u64 = 0,
    /// Offset of the local header from the start of the disk it is on.
    local_header_offset: u64 = 0,
    /// Number of the disk the entry starts on.
    disk_number_start: u32 = 0,

    /// Parses `data`, the data of a 0x0001 field, against the header values in `header`.
    ///
    /// The field holds a value only for each header value that is all ones, in a fixed
    /// order: uncompressed size, compressed size and local header offset as `u64`, then the
    /// disk number as `u32` (APPNOTE 4.5.3). Other values are copied from `header`.
    ///
    /// Returns `error.ZipBadExtraField` if `data` is shorter or longer than the values it
    /// must hold.
    pub fn parse(data: []const u8, header: Zip64Header) Error!Zip64 {
        return parseValues(data, header) catch return error.ZipBadExtraField;
    }

    fn parseValues(data: []const u8, header: Zip64Header) !Zip64 {
        var self: Zip64 = .{};
        var reader: std.Io.Reader = .fixed(data);

        if (header.uncompressed_size) |v| {
            self.uncompressed_size = if (v == escaped32) try reader.takeInt(u64, .little) else v;
        }
        if (header.compressed_size) |v| {
            self.compressed_size = if (v == escaped32) try reader.takeInt(u64, .little) else v;
        }
        if (header.local_header_offset) |v| {
            self.local_header_offset = if (v == escaped32) try reader.takeInt(u64, .little) else v;
        }
        if (header.disk_number_start) |v| {
            self.disk_number_start = if (v == escaped16) try reader.takeInt(u32, .little) else v;
        }

        if (reader.seek != data.len) return error.ZipBadExtraField;
        return self;
    }
};

/// Extended timestamp extra field, header id 0x5455 (Info-ZIP extrafld.txt).
///
/// Times are Unix seconds. A null time is not in the field.
pub const ExtendedTimestamp = struct {
    /// Last modification time.
    mtime: ?i32 = null,
    /// Last access time.
    atime: ?i32 = null,
    /// Creation time.
    ctime: ?i32 = null,

    /// Parses `data`, the data of a 0x5455 field.
    ///
    /// The first byte holds flags: bit 0 for the modification time, bit 1 for the access
    /// time, bit 2 for the creation time. Each time that is flagged and still fits follows
    /// as an `i32`, in that order. A time that doesn't fit is absent, because the central
    /// directory copy keeps the local flags but stores the modification time only.
    ///
    /// Returns `error.ZipBadExtraField` if `data` is empty or has bytes left over.
    pub fn parse(data: []const u8) Error!ExtendedTimestamp {
        var self: ExtendedTimestamp = .{};
        if (data.len < 1) return error.ZipBadExtraField;

        const flags = data[0];
        var offset: usize = 1;

        if ((flags & 0x01) != 0 and offset + 4 <= data.len) {
            self.mtime = std.mem.readInt(i32, data[offset..][0..4], .little);
            offset += 4;
        }
        if ((flags & 0x02) != 0 and offset + 4 <= data.len) {
            self.atime = std.mem.readInt(i32, data[offset..][0..4], .little);
            offset += 4;
        }
        if ((flags & 0x04) != 0 and offset + 4 <= data.len) {
            self.ctime = std.mem.readInt(i32, data[offset..][0..4], .little);
            offset += 4;
        }

        if (offset != data.len) return error.ZipBadExtraField;
        return self;
    }
};

/// Info-ZIP New Unix extra field, header id 0x7875 (Info-ZIP extrafld.txt).
///
/// Holds the owner's user and group ids, each stored in as many bytes as its size byte
/// says. Ids of up to 8 bytes are read; one that doesn't fit in `u32` is null.
pub const InfoZipUnixNew = struct {
    /// Version of the field. Always 1.
    version: u8,
    /// User id, or null if the field stores none or it doesn't fit in `u32`.
    uid: ?u32 = null,
    /// Group id, or null if the field stores none or it doesn't fit in `u32`.
    gid: ?u32 = null,

    /// Parses `data`, the data of a 0x7875 field.
    ///
    /// The layout is a version byte, then for the user id and then the group id a size
    /// byte followed by that many little-endian bytes. A size of zero means no id.
    ///
    /// Returns `error.ZipBadExtraField` if the version is not 1, an id is larger than
    /// 8 bytes, or `data` is shorter or longer than its sizes declare.
    pub fn parse(data: []const u8) Error!InfoZipUnixNew {
        return parseIds(data) catch return error.ZipBadExtraField;
    }

    fn parseIds(data: []const u8) !InfoZipUnixNew {
        var reader: std.Io.Reader = .fixed(data);

        const version = try reader.takeByte();
        if (version != 1) return error.ZipBadExtraField;
        var self: InfoZipUnixNew = .{ .version = version };

        self.uid = try takeId(&reader);
        self.gid = try takeId(&reader);

        if (reader.seek != data.len) return error.ZipBadExtraField;
        return self;
    }

    /// Reads one size byte and that many little-endian bytes of id. Null for a size of 0,
    /// or an id that doesn't fit in `u32`.
    fn takeId(reader: *std.Io.Reader) !?u32 {
        const size = try reader.takeByte();
        if (size > 8) return error.ZipBadExtraField;
        if (size == 0) return null;
        return std.math.cast(u32, std.mem.readVarInt(u64, try reader.take(size), .little));
    }
};

/// Info-ZIP Unicode Path extra field, header id 0x7075 (APPNOTE 4.6.9, Info-ZIP
/// extrafld.txt).
///
/// A UTF-8 copy of the header's file name. Only the layout is checked; whether the copy
/// may be used, version 1 and a CRC matching the header name, is for the caller to decide.
pub const InfoZipUnicodePath = struct {
    /// Version of the field. Only 1 is defined; others should not be used.
    version: u8,
    /// CRC-32 of the header name this copy was made from.
    name_crc32: u32,
    /// The UTF-8 name. It points into the extra block and is valid as long as that
    /// buffer is.
    name: []const u8,

    /// Parses `data`, the data of a 0x7075 field: a version byte, a little-endian CRC-32,
    /// and the name in the remaining bytes.
    ///
    /// Returns `error.ZipBadExtraField` if `data` is shorter than 5 bytes.
    pub fn parse(data: []const u8) Error!InfoZipUnicodePath {
        if (data.len < 5) return error.ZipBadExtraField;
        return .{
            .version = data[0],
            .name_crc32 = std.mem.readInt(u32, data[1..5], .little),
            .name = data[5..],
        };
    }
};

/// One field of an extra block, as returned by `Iterator`.
pub const Field = struct {
    /// Header id, which may be one `zip.HeaderId` doesn't name.
    id: u16,
    /// Data of the field, without its id and size. It points into the extra block and is
    /// valid as long as that buffer is.
    data: []const u8,

    /// Returns the field's id as a `HeaderId`, or null if the enum doesn't name it.
    pub fn asHeaderId(self: Field) ?zip.HeaderId {
        return std.enums.fromInt(zip.HeaderId, self.id);
    }
};

/// Splits an extra block into its fields, in order (APPNOTE 4.5.1).
///
/// Initialize with `.{ .buf = block }`. Returned fields point into `buf`.
pub const Iterator = struct {
    /// The extra block.
    buf: []const u8,
    /// Offset of the next field in `buf`.
    offset: usize = 0,

    /// Returns the first field with id `header_id` from the current position on, or null
    /// if there is none. Does not advance the iterator.
    ///
    /// Returns `error.ZipBadExtraField` if the block runs short before such a field is
    /// found.
    pub fn find(self: Iterator, header_id: zip.HeaderId) Error!?Field {
        var it = self;
        while (try it.next()) |field| {
            if (field.id == @intFromEnum(header_id)) return field;
        }
        return null;
    }

    /// Returns the next field, or null at the end of the block. Fields of any id are
    /// returned, including ones this library doesn't parse.
    ///
    /// Returns `error.ZipBadExtraField` if fewer than 4 bytes remain for the id and size,
    /// or the size runs past the end of the block.
    pub fn next(self: *Iterator) Error!?Field {
        if (self.offset == self.buf.len) return null;
        if (self.buf.len - self.offset < 4) return error.ZipBadExtraField;

        const id = std.mem.readInt(u16, self.buf[self.offset..][0..2], .little);
        const size = std.mem.readInt(u16, self.buf[self.offset + 2 ..][0..2], .little);
        const start = self.offset + 4;
        if (self.buf.len - start < size) return error.ZipBadExtraField;

        self.offset = start + size;
        return .{ .id = id, .data = self.buf[start..self.offset] };
    }
};
