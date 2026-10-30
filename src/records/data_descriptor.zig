const std = @import("std");
const truncated = @import("../errors.zig").truncated;
const Source = @import("../source.zig").Source;

/// The data descriptor (APPNOTE 4.3.9): the CRC-32 and sizes of an entry written with bit 3
/// set, right after its data. The sizes take 8 bytes each in ZIP64 archives (4.3.9.2) and 4
/// otherwise. The 0x08074b50 signature is optional (4.3.9.3), so `read` takes both forms;
/// without it, `signature` holds the CRC-32.
pub const DataDescriptor = struct {
    signature: u32,
    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,

    pub const signature_marker: u32 = 0x0807_4B50;

    pub fn read(source: *Source, offset: u64, is_zip64: bool) Source.ReadError!DataDescriptor {
        const r = try source.readerAt(offset);
        const signature: u32 = (r.takeInt(u32, .little) catch |err| return truncated(err));
        const crc32: u32 = switch (signature) {
            signature_marker => (r.takeInt(u32, .little) catch |err| return truncated(err)),
            else => signature,
        };

        const compressed_size: u64 = switch (is_zip64) {
            true => (r.takeInt(u64, .little) catch |err| return truncated(err)),
            false => @as(u64, (r.takeInt(u32, .little) catch |err| return truncated(err))),
        };

        const uncompressed_size: u64 = switch (is_zip64) {
            true => (r.takeInt(u64, .little) catch |err| return truncated(err)),
            false => @as(u64, (r.takeInt(u32, .little) catch |err| return truncated(err))),
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
