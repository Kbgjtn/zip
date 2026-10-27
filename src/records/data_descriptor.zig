const std = @import("std");
const log = std.log.scoped(.zip);

/// 4.3.9  Data descriptor:
///    crc-32                          4 bytes
///    compressed size                 4 bytes
///    uncompressed size               4 bytes
///
///  4.3.9.1 This descriptor MUST exist if bit 3 of the general purpose bit flag is set (see below).
///  It is byte aligned and immediately follows the last byte of compressed data. This descriptor
///  SHOULD be used only when it was not possible to seek in the output .ZIP file, e.g., when the
///  output .ZIP file was standard output or a non-seekable device.  For ZIP64(tm) format archives,
///  the compressed and uncompressed sizes are 8 bytes each.
///
///  4.3.9.3 Although not originally assigned a signature, the value 0x08074b50 has commonly been
///  adopted as a signature value for the data descriptor record.  Implementers SHOULD be aware
///  that ZIP files MAY be encountered with or without this signature marking data descriptors and
///  SHOULD account for either case when reading ZIP files to ensure compatibility.
pub const DataDescriptor = packed struct {
    signature: u32,
    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,

    pub const signature_marker: u32 = 0x0807_4B50;

    pub fn read(
        r: *std.Io.File.Reader,
        offset: u64,
        is_zip64: bool,
    ) !DataDescriptor {
        try r.seekTo(offset);
        const signature: u32 = try r.interface.takeInt(u32, .little);
        const crc32: u32 = switch (signature) {
            signature_marker => try r.interface.takeInt(u32, .little),
            else => signature,
        };

        const compressed_size: u64 = switch (is_zip64) {
            true => try r.interface.takeInt(u64, .little),
            false => @as(u64, try r.interface.takeInt(u32, .little)),
        };

        const uncompressed_size: u64 = switch (is_zip64) {
            true => try r.interface.takeInt(u64, .little),
            false => @as(u64, try r.interface.takeInt(u32, .little)),
        };

        return .{
            .signature = signature,
            .crc32 = crc32,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
        };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("Data Descriptor\n", .{});
        try writer.print("-------------------------------\n", .{});
        try writer.print("signature                  \t0x{x}\n", .{self.signature});
        try writer.print("compressed size            \t{d}\n", .{self.compressed_size});
        try writer.print("uncompressed size          \t{d}\n", .{self.uncompressed_size});
        try writer.print("crc-32 checksum            \t{x}\n\n", .{self.crc32});
    }
};

// NOTE! Archive decryption header
// The Archive Decryption Header is introduced in version 6.2 of the ZIP format specification.
// This record exists in support of the Central Directory Encryption Feature implemented as part
// of the Strong Encryption Specification. When the Central Directory Structure is encrypted,
// this decryption header MUST precede the encrypted data segment.
