const std = @import("std");
const truncated = @import("../errors.zig").truncated;
const Source = @import("../source.zig").Source;
const log = std.log.scoped(.zip);

const GeneralPurposeFlags = @import("../format.zig").GeneralPurposeFlags;
const CompressionMethod = @import("../format.zig").CompressionMethod;
const Version = @import("../format.zig").Version;
const cdfh_size = @import("../format.zig").cdfh_size;
const time = @import("../time.zig");

/// Central directory structure
/// [ file header 1 ]
/// [ file header 2 ]
/// ...
/// [ file header n ]
/// [digital signature]
/// [ Zip64 end of central directory record ]
/// [ Zip64 end of central directory locator ]
/// [ End of central directory record ]
///
/// The file header are similar to the local file headers, but contain some extra information.
/// The Zip64 entries handle the case of a 64-bit Zip arhive, and the end central directory
/// record contains information about the archive itself.
pub const CentralDirectoryFileHeader = extern struct {
    signature: u32 align(1),
    version_made_by: Version align(1),
    version_needed_to_extract: u16 align(1),
    flags: GeneralPurposeFlags align(1),
    compression_method: CompressionMethod align(1),
    last_modification_time: u16 align(1),
    last_modification_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    filename_len: u16 align(1),
    extra_len: u16 align(1),
    comment_len: u16 align(1),
    disk_number_start: u16 align(1),
    internal_file_attributes: u16 align(1),
    external_file_attributes: u32 align(1),
    local_file_header_relative_offset: u32 align(1),
    // fixed size is 46
    // ...
    // filename (variable size)
    // extra field (variable size)
    // file comment (variable size)

    pub const signature_marker: u32 = 0x0201_4B50;
    pub const size: u64 = 46;

    pub fn read(
        source: *Source,
        offset: u64,
    ) !CentralDirectoryFileHeader {
        const reader = try source.readerAt(offset);
        const cdfh = reader.takeStruct(CentralDirectoryFileHeader, .little) catch |err| return truncated(err);
        if (cdfh.signature != signature_marker) return error.ZipBadSignature;
        if (cdfh.disk_number_start != 0) return error.ZipMultiDisk;
        return cdfh;
    }

    /// Bytes this header takes in the central directory: the fixed part, then the name,
    /// extra field and comment (APPNOTE 4.3.12).
    pub fn computeEntrySize(self: CentralDirectoryFileHeader) u64 {
        return size + @as(u64, self.filename_len) + self.extra_len + self.comment_len;
    }

    pub fn requires_zip64(self: CentralDirectoryFileHeader) bool {
        return @as(u64, self.local_file_header_relative_offset) == 0xFFFF_FFFF or
            @as(u64, self.compressed_size) == 0xFFFF_FFFF or
            @as(u64, self.uncompressed_size) == 0xFFFF_FFFF or
            @as(u32, self.disk_number_start) == 0xFFFF;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("Central Directory File Header\n", .{});
        try writer.print("-------------------------------\n", .{});
        try writer.print("signature:                   \t0x{x}\n", .{self.signature});
        try writer.print("version made by:             \t[version {d}] [os {any}]\n", self.version_made_by);
        try writer.print("version needed to extract:   \t{d:.1}\n", .{@as(f64, @floatFromInt(self.version_needed_to_extract)) / 10.0});
        try writer.print("flags:                       \t{}\n", .{self.flags});
        try writer.print("compression method:          \t{any}\n", .{self.compression_method});
        try writer.print("last modification time:      \t{}\n", .{time.decodeDOSTime(self.last_modification_time)});
        try writer.print("last modification date:      \t{}\n", .{time.decodeDosDate(self.last_modification_date)});
        try writer.print("crc-32 checksum:                       \t{x}\n", .{self.crc32});
        try writer.print("compressed size:             \t{d}\n", .{self.compressed_size});
        try writer.print("uncompressed size:           \t{d}\n", .{self.uncompressed_size});
        try writer.print("filename len:                \t{d}\n", .{self.filename_len});
        try writer.print("extra len:                   \t{d}\n", .{self.extra_len});
        try writer.print("comment len:                 \t{d}\n", .{self.comment_len});
        try writer.print("disk number start:           \t{d}\n", .{self.disk_number_start});
        try writer.print("internal file attributes:    \t{d}\n", .{self.internal_file_attributes});
        try writer.print("external file attributes:    \t0x{x}\n", .{self.external_file_attributes});
        try writer.print("local file header offset:    \t{d}\n\n", .{self.local_file_header_relative_offset});
    }
};

pub const DigitalSignature = struct {
    signature: u32,
    size_of_data: u16,
    // ...
    // signature_data (variable size)

    pub const signature_marker: u32 = 0x0505_4B50;
};

test "central directory file header structure" {
    try std.testing.expectEqual(
        @sizeOf(CentralDirectoryFileHeader),
        cdfh_size,
    );

    try std.testing.expectEqual(
        @bitSizeOf(CentralDirectoryFileHeader),
        cdfh_size * 8,
    );

    try std.testing.expectEqual(
        std.mem.readInt(u32, &[_]u8{ 'P', 'K', 1, 2 }, .little),
        CentralDirectoryFileHeader.signature_marker,
    );
}
