const std = @import("std");
const truncated = @import("../errors.zig").truncated;
const Source = @import("../source.zig").Source;

const Version = @import("../format.zig").Version;

/// The ZIP64 end of central directory locator (APPNOTE 4.3.15), right before the end of
/// central directory record. It points at the ZIP64 end record.
pub const EndRecord64Locator = extern struct {
    signature: u32 align(1),
    /// Disk that holds the ZIP64 end record (APPNOTE 4.3.15).
    record_disk: u32 align(1),
    /// Offset of the ZIP64 end record (4.3.14), not of the central directory.
    record_offset: u64 align(1),
    total_disks: u32 align(1),

    pub const signature_marker: u32 = 0x0706_4B50;
    /// Bytes in the record, which has no variable part.
    pub const size: u64 = 20;

    pub fn read(source: *Source, offset: u64, file_size: u64) (Source.ReadError || error{ ZipMultiDisk, Zip64Malformed })!EndRecord64Locator {
        if (offset < size) {
            return error.Zip64Malformed;
        }

        const locator_offset: u64 = offset - size;
        const reader = try source.readerAt(locator_offset);
        const locator = reader.takeStruct(EndRecord64Locator, .little) catch |err| return truncated(err);
        if (locator.signature != signature_marker) {
            return error.Zip64Malformed;
        }

        try locator.validateStructure(file_size);
        return locator;
    }

    fn validateStructure(
        self: EndRecord64Locator,
        file_size: u64,
    ) error{ ZipMultiDisk, Zip64Malformed }!void {
        // Only single-disk archives are supported.
        if (self.record_disk != 0 or self.total_disks != 1) {
            return error.ZipMultiDisk;
        }

        // The locator points at the ZIP64 end record (4.3.15), so a pointer outside the
        // file is a broken ZIP64 end, like a bad signature or size.
        if (self.record_offset >= file_size) {
            return error.Zip64Malformed;
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("End Of Central Directory Record ZIP64 Locator\n", .{});
        try writer.print("signature 0x{x}\n", .{self.signature});
        try writer.print("record_disk {}\n", .{self.record_disk});
        try writer.print("record_offset {}\n", .{self.record_offset});
        try writer.print("total_disks {}\n", .{self.total_disks});
    }
};

comptime {
    // `read` steps back `size` bytes from the EOCD to find the locator, so a wrong field
    // width reads it from the wrong place (APPNOTE 4.3.15: 20 bytes).
    std.debug.assert(@sizeOf(EndRecord64Locator) == EndRecord64Locator.size);
    // A byte-order slip in the hex makes every ZIP64 archive Zip64Malformed (4.3.15).
    std.debug.assert(EndRecord64Locator.signature_marker == std.mem.readInt(u32, "PK\x06\x07", .little));
}

/// The ZIP64 end of central directory record (APPNOTE 4.3.14), from the field after the
/// 12-byte `Header`. Its fields are little-endian; the extensible data sector follows them.
pub const EndRecord64 = extern struct {
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

    /// The signature and the size of the rest of the record, which doesn't count these
    /// 12 bytes (APPNOTE 4.3.14.1).
    pub const Header = extern struct {
        signature: u32 align(1),
        record_size: u64 align(1),
    };

    pub const signature_marker: u32 = 0x0606_4B50;
    /// Bytes in the fixed part after `Header`, before the extensible data sector.
    pub const size: u64 = 44;

    pub fn read(source: *Source, offset: u64, file_size: u64) (Source.ReadError || error{ ZipMultiDisk, Zip64Malformed })!EndRecord64 {
        const reader = try source.readerAt(offset);

        const header = reader.takeStruct(
            Header,
            .little,
        ) catch |err| return truncated(err);

        if (header.signature != signature_marker) {
            return error.Zip64Malformed;
        }

        if (header.record_size < size) {
            return error.Zip64Malformed;
        }

        const total_size: u64 = std.math.add(u64, 12, header.record_size) catch return error.Zip64Malformed;
        const end = std.math.add(u64, offset, total_size) catch return error.Zip64Malformed;
        if (end > file_size) {
            return error.Zip64Malformed;
        }

        const record = reader.takeStruct(EndRecord64, .little) catch |err| return truncated(err);

        // check if there's extensible data record remaining
        if (header.record_size > size) {
            // The extensible data sector (4.3.14.2) only holds PKWARE extensions we don't
            // support, so it is skipped.
            const remaining = header.record_size - size;
            // discardAll refills; toss would assert when the bytes aren't buffered.
            reader.discardAll(remaining) catch |err| return truncated(err);
        }

        try record.validateStructure(offset);
        return record;
    }

    fn validateStructure(
        self: EndRecord64,
        offset: u64,
    ) error{ ZipMultiDisk, Zip64Malformed }!void {
        if (self.disk_number != 0 or
            self.central_directory_disk_number != 0 or
            self.record_count_disk != self.record_count_total)
        {
            return error.ZipMultiDisk;
        }

        const end = std.math.add(u64, self.central_directory_offset, self.central_directory_size) catch return error.Zip64Malformed;
        if (end > offset) {
            return error.Zip64Malformed;
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

comptime {
    // `size` is what `record_size` counts, the record minus its leading 12 bytes (APPNOTE
    // 4.3.14.1). A wrong field width breaks the `record_size < size` check and the writer.
    std.debug.assert(@sizeOf(EndRecord64) == EndRecord64.size);
    // Signature and record_size, then the rest: 56 fixed bytes in all (4.3.14).
    std.debug.assert(@sizeOf(EndRecord64.Header) + EndRecord64.size == 56);
    // A byte-order slip in the hex makes every ZIP64 archive Zip64Malformed (4.3.14).
    std.debug.assert(EndRecord64.signature_marker == std.mem.readInt(u32, "PK\x06\x06", .little));
}
