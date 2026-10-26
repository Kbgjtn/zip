const std = @import("std");
const log = std.log.scoped(.zip);

const GeneralPurposeFlags = @import("../format.zig").GeneralPurposeFlags;
const CompressionMethod = @import("../format.zig").CompressionMethod;
const time = @import("../time.zig");

/// Local File Headers
///
/// The Local File Header of each entry represents information about the file such as comment,
/// file size and file name. The extra data fields (optional) can accommodate information for
/// extensibility options of the ZIP format. The Local File Header has specific field structure
/// consisting of multi-byte values.
///
/// All the values are stored in little-endian byte order where the field lenght counts the
/// length in bytes. All the structures ZIP file use 4-byte signatures for each file entry.
/// So basically, need to store the metadata in a way that produces a byte-exact layout which
/// matches the binary format.
pub const LocalFileHeader = extern struct {
    signature: u32 align(1),
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
    // ...
    // File name (variable size)
    // Extra field (variable size)

    const signature_marker: u32 = 0x04_03_4B_50;
    pub const size: u64 = 30;

    pub fn read(r: *std.Io.File.Reader, offset: u64) !LocalFileHeader {
        try r.seekTo(offset);

        // const start_seek = r.interface.seek;
        const header = try r.interface.takeStruct(LocalFileHeader, .little);
        if (header.signature != signature_marker) return error.ZipBadSignature;
        // if (r.interface.seek - start_seek != size) return error.BadFileHeader;
        if (header.flags.encrypted) return error.ZipUnsupportedEncryption;

        return header;
    }

    pub fn requiresZip64(s: LocalFileHeader) bool {
        return s.compressed_size == 0xFFFFFFFF or s.uncompressed_size == 0xFFFFFFFF;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("Local File Header\n", .{});
        try writer.print("-------------------------------\n", .{});
        try writer.print("signature                 \t0x{x}\n", .{self.signature});
        try writer.print("version needed to extract \t{d:.2}\n", .{@as(f32, @floatFromInt(self.version_needed_to_extract)) / 10.0});
        try writer.print("flags                     \t{}\n", .{self.flags});
        try writer.print("compression method        \t{any}\n", .{self.compression_method});
        try writer.print("last modification time    \t{}\n", .{time.decodeDOSTime(self.last_modification_time)});
        try writer.print("last modification date    \t{}\n", .{time.decodeDosDate(self.last_modification_date)});
        try writer.print("crc-32 checksum           \t{x}\n", .{self.crc32});
        try writer.print("compressed size           \t{d}\n", .{self.compressed_size});
        try writer.print("uncompressed size         \t{d}\n", .{self.uncompressed_size});
        try writer.print("filename len              \t{d}\n", .{self.filename_len});
        try writer.print("extra len                 \t{d}\n\n", .{self.extra_len});
    }
};

test "local file header structure" {
    try std.testing.expectEqual(@sizeOf(LocalFileHeader), LocalFileHeader.size);
    try std.testing.expectEqual(@bitSizeOf(LocalFileHeader), LocalFileHeader.size * 8);
    try std.testing.expectEqual(std.mem.readInt(u32, &[_]u8{ 'P', 'K', 3, 4 }, .little), LocalFileHeader.signature_marker);
}
