const std = @import("std");
const truncated = @import("../errors.zig").truncated;
const Source = @import("../source.zig").Source;

const GeneralPurposeFlags = @import("../format.zig").GeneralPurposeFlags;
const CompressionMethod = @import("../format.zig").CompressionMethod;
const escaped32 = @import("../format.zig").escaped32;
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
pub const LocalHeader = extern struct {
    signature: u32 align(1),
    version_needed_to_extract: u16 align(1),
    flags: GeneralPurposeFlags align(1),
    compression_method: CompressionMethod align(1),
    dos_time: u16 align(1),
    dos_date: u16 align(1),
    crc32: u32 align(1),
    compressed_size: u32 align(1),
    uncompressed_size: u32 align(1),
    name_len: u16 align(1),
    extra_len: u16 align(1),
    // ...
    // File name (variable size)
    // Extra field (variable size)

    pub const signature_marker: u32 = 0x0403_4B50;
    pub const size: u64 = 30;

    pub fn read(source: *Source, offset: u64) (Source.ReadError || error{ZipBadSignature})!LocalHeader {
        const r = try source.readerAt(offset);
        const header = r.takeStruct(LocalHeader, .little) catch |err| return truncated(err);
        if (header.signature != signature_marker) return error.ZipBadSignature;

        return header;
    }

    pub fn requiresZip64(s: LocalHeader) bool {
        return s.compressed_size == escaped32 or s.uncompressed_size == escaped32;
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
        try writer.print("last modification time    \t{}\n", .{time.decodeDosTime(self.dos_time)});
        try writer.print("last modification date    \t{}\n", .{time.decodeDosDate(self.dos_date)});
        try writer.print("crc-32 checksum           \t{x}\n", .{self.crc32});
        try writer.print("compressed size           \t{d}\n", .{self.compressed_size});
        try writer.print("uncompressed size         \t{d}\n", .{self.uncompressed_size});
        try writer.print("filename len              \t{d}\n", .{self.name_len});
        try writer.print("extra len                 \t{d}\n\n", .{self.extra_len});
    }
};

comptime {
    // A field of the wrong width or a missing align(1) shifts every field read after it
    // (APPNOTE 4.3.7: 30 fixed bytes).
    std.debug.assert(@sizeOf(LocalHeader) == LocalHeader.size);
    // A byte-order slip in the hex makes every local header a ZipBadSignature (4.3.7).
    std.debug.assert(LocalHeader.signature_marker == std.mem.readInt(u32, "PK\x03\x04", .little));
}
