//! Walks the entries of a ZIP archive through its central directory (APPNOTE 4.3.6, 4.3.12).
//!
//! The central directory is the source of truth for every entry. Each entry's local header
//! (4.3.7) and data descriptor (4.3.9) are read only to cross-check it: a disagreement is an
//! error, never a different value (bug 21).

const std = @import("std");

const extra = @import("extra.zig");
const FileData = @import("entry.zig").FileData;
const HeaderId = @import("format.zig").HeaderId;
const CentralDirectoryFileHeader = @import("records/central_directory.zig").CentralDirectoryFileHeader;
const DataDescriptor = @import("records/data_descriptor.zig").DataDescriptor;
const EndOfCentralDirectoryRecord = @import("records/eocd.zig").EndOfCentralDirectoryRecord;
const EndRecord64Locator = @import("records/eocd64.zig").EndRecord64Locator;
const EndOfCentralDirectoryRecord64 = @import("records/eocd64.zig").EndOfCentralDirectoryRecord64;
const LocalFileHeader = @import("records/local_file_header.zig").LocalFileHeader;

/// Iterates the central directory one entry at a time, without allocating.
///
/// `init` finds the end of central directory record (and the ZIP64 end record when the EOCD
/// fields are escaped), then `next` returns each entry as a `FileData` checked against its
/// local header. `reader` is shared with `FileData.stream`, and both move its position.
pub const Iterator = struct {
    reader: *std.Io.File.Reader,
    /// Index of the entry `next` reads next.
    cd_index: u64 = 0,
    /// Offset of the central directory header `next` reads next.
    cd_offset: u64 = 0,
    cd_size: u64 = 0,
    /// Entry count from the EOCD or ZIP64 end record.
    total_entries: u64 = 0,
    /// One past the last byte of the central directory.
    cd_end: u64 = 0,

    /// Guard against an entry count that would make callers loop for hours.
    const max_reasonable_entries = 10_000_000;

    /// Reads the end records and checks that the central directory lies inside the file.
    pub fn init(reader: *std.Io.File.Reader) !Iterator {
        const file_size = try reader.getSize();

        const eocd = try EndOfCentralDirectoryRecord.read(reader);
        try eocd.record.validateStructure(file_size, eocd.offset);

        var iterator: Iterator = .{ .reader = reader };

        if (eocd.record.requiresZip64()) {
            // An escaped EOCD field means the real values are in the ZIP64 end record,
            // found through the locator just before the EOCD (APPNOTE 4.3.14, 4.3.15).
            const locator = try EndRecord64Locator.read(reader, file_size, eocd.offset);
            const record64 = try EndOfCentralDirectoryRecord64.read(
                reader,
                file_size,
                locator.central_directory_offset,
            );
            iterator.cd_offset = record64.central_directory_offset;
            iterator.cd_size = record64.central_directory_size;
            iterator.total_entries = record64.record_count_total;
        } else {
            try eocd.record.validateSizeFields(file_size);
            iterator.cd_offset = eocd.record.central_directory_offset;
            iterator.cd_size = eocd.record.central_directory_size;
            iterator.total_entries = eocd.record.record_count_total;
        }

        try iterator.validateSizeFields(file_size);
        iterator.cd_end = iterator.cd_offset + iterator.cd_size;
        return iterator;
    }

    /// Returns the next entry, or null after the last one.
    ///
    /// Encrypted entries and methods other than stored and deflate are refused. The local
    /// header must agree with the central header on name, method and bit 3, and on CRC and
    /// sizes (`ZipLocalHeaderMismatch`). With bit 3 the data descriptor must carry the central
    /// CRC and sizes (`ZipBadDataDescriptor`). The returned sizes and CRC are the central ones.
    pub fn next(self: *Iterator) !?FileData {
        if (self.cd_index == self.total_entries) return null;
        if (self.cd_offset >= self.cd_end) return error.ZipMalformed;

        const cdfh = try CentralDirectoryFileHeader.read(self.reader, self.cd_offset);
        if (cdfh.flags.encrypted) return error.ZipUnsupportedEncryption;
        switch (cdfh.compression_method) {
            .stored, .deflate => {},
            else => return error.ZipUnsupportedCompressionMethod,
        }

        const entry_size = try cdfh.computeEntrySize();
        const entry_end = std.math.add(u64, self.cd_offset, entry_size) catch {
            return error.ZipSizeOverflow;
        };
        if (entry_end > self.cd_end) return error.ZipMalformed;

        defer {
            self.cd_index += 1;
            self.cd_offset += entry_size;
        }

        // readSliceAll refills; toss would assert when a field crosses the end of the
        // buffered bytes (bug 23).
        var name_buf: [std.math.maxInt(u16)]u8 = undefined;
        const name = name_buf[0..cdfh.filename_len];
        try self.reader.interface.readSliceAll(name);

        var extra_buf: [std.math.maxInt(u16)]u8 = undefined;
        const central_extra = extra_buf[0..cdfh.extra_len];
        try self.reader.interface.readSliceAll(central_extra);

        const sizes = try centralSizes(cdfh, central_extra);

        var lfh = try LocalFileHeader.read(self.reader, sizes.local_file_header_relative_offset);
        // APPNOTE never says the names must match, but 4.4.17.2 allows a different local name
        // only under bit 13, which we refuse. A mismatch makes tools disagree on the contents.
        if (lfh.filename_len != cdfh.filename_len or
            lfh.compression_method != cdfh.compression_method or
            lfh.flags.data_descriptor != cdfh.flags.data_descriptor or
            !try self.localNameMatches(name))
        {
            return error.ZipLocalHeaderMismatch;
        }

        if (cdfh.flags.data_descriptor) {
            try self.checkDataDescriptor(cdfh, lfh, sizes);
            // FileData.stream checks against the header's CRC, which may be zero under bit 3.
            lfh.crc32 = cdfh.crc32;
        } else {
            try self.checkLocalSizes(cdfh, lfh, sizes);
        }

        return FileData{
            .header = lfh,
            .compressed_size = sizes.compressed_size,
            .uncompressed_size = sizes.uncompressed_size,
            .offset = sizes.local_file_header_relative_offset,
        };
    }

    /// Sizes and local header offset of a central header, taken from its ZIP64 extra field
    /// when the 32-bit fields are escaped (APPNOTE 4.5.3).
    fn centralSizes(cdfh: CentralDirectoryFileHeader, central_extra: []const u8) !extra.Zip64Extended {
        if (!cdfh.requires_zip64()) return .{
            .compressed_size = cdfh.compressed_size,
            .uncompressed_size = cdfh.uncompressed_size,
            .local_file_header_relative_offset = cdfh.local_file_header_relative_offset,
            .disk_number_start = cdfh.disk_number_start,
        };

        const extra_iterator: extra.Iterator = .{ .buf = central_extra };
        const field = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse return error.ZipBadExtra;
        const out = try field.parse(.{ .zip64_extended_extra_field = .{
            .uncompressed_size = cdfh.uncompressed_size,
            .compressed_size = cdfh.compressed_size,
            .disk_number_start = cdfh.disk_number_start,
            .local_file_header_relative_offset = cdfh.local_file_header_relative_offset,
        } });
        return out.zip64_extended_extra_field;
    }

    /// Without bit 3, the local CRC and sizes must equal the central ones. Local sizes come
    /// from the local ZIP64 extra when escaped (APPNOTE 4.5.3).
    fn checkLocalSizes(self: *Iterator, cdfh: CentralDirectoryFileHeader, lfh: LocalFileHeader, sizes: extra.Zip64Extended) !void {
        if (lfh.crc32 != cdfh.crc32) return error.ZipLocalHeaderMismatch;

        var compressed: u64 = lfh.compressed_size;
        var uncompressed: u64 = lfh.uncompressed_size;
        if (compressed == 0xFFFF_FFFF or uncompressed == 0xFFFF_FFFF) {
            var buf: [std.math.maxInt(u16)]u8 = undefined;
            const local_extra = try self.readLocalExtra(sizes.local_file_header_relative_offset, lfh, &buf);
            const extra_iterator: extra.Iterator = .{ .buf = local_extra };
            const field = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse return error.ZipBadExtra;
            const z = (try field.parse(.{ .zip64_extended_extra_field = .{
                .uncompressed_size = lfh.uncompressed_size,
                .compressed_size = lfh.compressed_size,
                .disk_number_start = null,
                .local_file_header_relative_offset = 0,
            } })).zip64_extended_extra_field;
            compressed = z.compressed_size;
            uncompressed = z.uncompressed_size;
        }

        if (compressed != sizes.compressed_size or uncompressed != sizes.uncompressed_size) {
            return error.ZipLocalHeaderMismatch;
        }
    }

    /// With bit 3, the local CRC is zero or the central CRC, and the data descriptor after
    /// the data must carry the central CRC and sizes (APPNOTE 4.3.9, 4.4.4).
    fn checkDataDescriptor(self: *Iterator, cdfh: CentralDirectoryFileHeader, lfh: LocalFileHeader, sizes: extra.Zip64Extended) !void {
        // Local CRC and sizes SHOULD be zero, but some writers fill them in.
        if (lfh.crc32 != 0 and lfh.crc32 != cdfh.crc32) return error.ZipLocalHeaderMismatch;

        const header_offset = sizes.local_file_header_relative_offset;
        const descriptor_offset = header_offset + LocalFileHeader.size +
            lfh.filename_len + lfh.extra_len + sizes.compressed_size;

        // Descriptor sizes are 8 bytes when the local header has a ZIP64 extra, whatever
        // the central directory has (APPNOTE 4.3.9.2).
        var buf: [std.math.maxInt(u16)]u8 = undefined;
        const local_extra = try self.readLocalExtra(header_offset, lfh, &buf);
        const extra_iterator: extra.Iterator = .{ .buf = local_extra };
        const zip64 = extra_iterator.find(HeaderId.zip64_extended_extra_field) != null;

        const descriptor = try DataDescriptor.read(self.reader, descriptor_offset, zip64);
        if (descriptor.crc32 != cdfh.crc32 or
            descriptor.compressed_size != sizes.compressed_size or
            descriptor.uncompressed_size != sizes.uncompressed_size)
        {
            return error.ZipBadDataDescriptor;
        }
    }

    /// Whether the name right after the local header just read equals `name`. The caller has
    /// already checked that the lengths match.
    fn localNameMatches(self: *Iterator, name: []const u8) !bool {
        var chunk: [256]u8 = undefined;
        var i: usize = 0;
        while (i < name.len) {
            const n = @min(chunk.len, name.len - i);
            self.reader.interface.readSliceAll(chunk[0..n]) catch |err| switch (err) {
                error.EndOfStream => return error.ZipTruncated,
                else => return err,
            };
            if (!std.mem.eql(u8, chunk[0..n], name[i..][0..n])) return false;
            i += n;
        }
        return true;
    }

    /// Reads the extra field of the local header at `header_offset` into `buf`.
    fn readLocalExtra(self: *Iterator, header_offset: u64, lfh: LocalFileHeader, buf: *[std.math.maxInt(u16)]u8) ![]u8 {
        const local_extra = buf[0..lfh.extra_len];
        try self.reader.seekTo(header_offset + LocalFileHeader.size + lfh.filename_len);
        self.reader.interface.readSliceAll(local_extra) catch |err| switch (err) {
            error.EndOfStream => return error.ZipTruncated,
            else => return err,
        };
        return local_extra;
    }

    /// Checks the entry count and that the central directory ends inside the file.
    fn validateSizeFields(self: Iterator, file_size: u64) error{ EntryCountExceedsLimit, Zip64SizeOverflow }!void {
        if (self.total_entries > max_reasonable_entries) return error.EntryCountExceedsLimit;
        if (self.cd_offset >= file_size) return error.Zip64SizeOverflow;
        const end = std.math.add(u64, self.cd_offset, self.cd_size) catch return error.Zip64SizeOverflow;
        if (end > file_size) return error.Zip64SizeOverflow;
    }
};
