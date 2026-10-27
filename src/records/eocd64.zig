const std = @import("std");
const log = std.log.scoped(.zip);

const Version = @import("../format.zig").Version;
const eocd64_locator_size = @import("../format.zig").eocd64_locator_size;

// Overall .ZIP file format
// [local file header 1]
// [encryption header 1]
// [file data 1]
// [data descriptor 1]
// .
// .
// .
// [local file header n]
// [encryption header n]
// [file data n]
// [data descriptor n]
// [archive decryption header]
// [archive extra data record]
// [central directory header 1]
// .
// .
// .
// [central directory header n]
// [zip64 end of central directory record]
// [zip64 end of central directory locator]
// [end of central directory record]
pub const EndRecord64Locator = extern struct {
    signature: u32 align(1),
    central_directory_disk: u32 align(1),
    central_directory_offset: u64 align(1),
    total_disks: u32 align(1),

    pub const signature_marker: u32 = 0x07_06_4B_50;
    pub const size: u32 = 20;

    pub fn read(reader: *std.Io.File.Reader, file_size: u64, offset: u64) !EndRecord64Locator {
        if (offset < size) {
            return error.Zip64Malformed;
        }

        const locator_offset: u64 = offset - eocd64_locator_size;
        try reader.seekTo(locator_offset);
        const locator = try reader.interface.takeStruct(EndRecord64Locator, .little);
        if (locator.signature != signature_marker) {
            return error.Zip64InvalidSignature;
        }

        try locator.validateStructure(file_size, locator_offset, offset);
        return locator;
    }

    fn validateStructure(
        self: EndRecord64Locator,
        file_size: u64,
        locator_offset: u64,
        eocd_offset: u64,
    ) error{ ZipUnsupportedMultiDisk, ZipMalformed }!void {
        // TODO (dapa)
        // must be a single disk
        if (self.central_directory_disk != 0 or self.total_disks != 1) {
            return error.ZipUnsupportedMultiDisk;
        }

        // must be adjacent to EOCD
        if (locator_offset + size != eocd_offset) {
            return error.ZipMalformed;
        }

        if (self.central_directory_offset >= file_size) {
            return error.ZipMalformed;
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("End Of Central Directory Record ZIP64 Locator\n", .{});
        try writer.print("signature 0x{x}\n", .{self.signature});
        try writer.print("central_directory_disk {}\n", .{self.central_directory_disk});
        try writer.print("central_directory_offset {}\n", .{self.central_directory_offset});
        try writer.print("total_disks {}\n", .{self.total_disks});
    }
};

test "eocd64_locator_structure" {
    try std.testing.expectEqual(@sizeOf(EndRecord64Locator), eocd64_locator_size);
    try std.testing.expectEqual(@bitSizeOf(EndRecord64Locator), eocd64_locator_size * 8);
}

// The value store into the "size of zip64 eocd record" SHOULD be the size of the
// remaining record and SHOULD NOT include the leading 12 bytes.
// size = (sizeof_fixed_fields + size_of_variable_data - 12)
pub const EndOfCentralDirectoryRecord64 = extern struct {
    version_made_by: Version align(1),
    version_needed_to_extract: u16 align(1),
    disk_number: u32 align(1),
    central_directory_disk_number: u32 align(1),
    record_count_disk: u64 align(1),
    record_count_total: u64 align(1),
    central_directory_size: u64 align(1),
    central_directory_offset: u64 align(1),
    // size is 44 bytes
    // ...
    // Data sector (variable size) [optional]

    /// 4.3.14.1 The value stored into the "size of zip64 end of central
    ///          directory record" SHOULD be the size of the remaining
    ///          record and SHOULD NOT include the leading 12 bytes.
    ///
    ///          Size = SizeOfFixedFields + SizeOfVariableData - 12.
    pub const header64 = extern struct {
        signature: u32 align(1),
        record_size: u64 align(1),
    };

    pub const signature_marker: u32 = 0x06_06_4b_50;
    pub const size: u64 = 44;

    pub fn read(reader: *std.Io.File.Reader, file_size: u64, offset: u64) !EndOfCentralDirectoryRecord64 {
        try reader.seekTo(offset);

        const header = try reader.interface.takeStruct(
            header64,
            .little,
        );

        if (header.signature != signature_marker) {
            return error.Zip64InvalidSignature;
        }

        if (header.record_size < size) {
            return error.Zip64Malformed;
        }

        const total_size: u64 = std.math.add(u64, 12, header.record_size) catch return error.Zip64SizeOverflow;
        if (offset + total_size > file_size) {
            return error.Zip64SizeOverflow;
        }

        const record = try reader.interface.takeStruct(EndOfCentralDirectoryRecord64, .little);

        // check if there's extensible data record remaining
        if (header.record_size > size) {
            // TODO (dapa)
            // Parse The Extensible Data?
            // unimplemented supported:
            // Central directory encryption
            // Strong encryption (spec 6.2+)
            // PKWARE proprietary extensions

            const remaining = header.record_size - size;
            // try reader.seekBy(@as(i64, @intCast(remaining)));
            reader.interface.toss(remaining);
        }

        try record.validateStructure(offset);
        return record;
    }

    fn validateStructure(
        self: EndOfCentralDirectoryRecord64,
        offset: u64,
    ) error{ Zip64UnsupportedMultiDisk, Zip64SizeOverflow, Zip64Malformed }!void {
        if (self.disk_number != 0 or
            self.central_directory_disk_number != 0 or
            self.record_count_disk != self.record_count_total)
        {
            return error.Zip64UnsupportedMultiDisk;
        }

        const end = std.math.add(u64, self.central_directory_offset, self.central_directory_size) catch return error.Zip64SizeOverflow;
        if (end > offset) {
            return error.Zip64SizeOverflow;
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("End Of Central Directory Record ZIP64\n", .{});
        try writer.print("version_made_by {}\n", .{self.version_made_by});
        try writer.print("version_needed_to_extract {}\n", .{self.version_needed_to_extract});
        try writer.print("disk_number {}\n", .{self.disk_number});
        try writer.print("central_directory_disk_number {}\n", .{self.central_directory_disk_number});
        try writer.print("record_count_disk {}\n", .{self.record_count_disk});
        try writer.print("record_count_total {}\n", .{self.record_count_total});
        try writer.print("central_directory_size {}\n", .{self.central_directory_size});
        try writer.print("central_directory_offset {}\n", .{self.central_directory_offset});
    }
};

test "End of Central Directory Record ZIP64" {
    try std.testing.expectEqual(@sizeOf(EndOfCentralDirectoryRecord64.header64), 12);
    try std.testing.expectEqual(@bitSizeOf(EndOfCentralDirectoryRecord64.header64), 12 * 8);

    // signature
    try std.testing.expectEqual(EndOfCentralDirectoryRecord64.signature_marker, 0x06_06_4b_50);
    try std.testing.expectEqual(EndOfCentralDirectoryRecord64.size, 44);

    try std.testing.expectEqual(@sizeOf(EndOfCentralDirectoryRecord64), EndOfCentralDirectoryRecord64.size);
    try std.testing.expectEqual(@bitSizeOf(EndOfCentralDirectoryRecord64), EndOfCentralDirectoryRecord64.size * 8);
}
