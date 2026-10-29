const std = @import("std");
const log = std.log.scoped(.zip);

const FileData = @import("entry.zig").FileData;
const CompressionMethod = @import("format.zig").CompressionMethod;
const max_u16 = @import("format.zig").max_u16;
const HeaderId = @import("format.zig").HeaderId;
const CentralDirectoryFileHeader = @import("records/central_directory.zig").CentralDirectoryFileHeader;
const DataDescriptor = @import("records/data_descriptor.zig").DataDescriptor;
const EndOfCentralDirectoryRecord = @import("records/eocd.zig").EndOfCentralDirectoryRecord;
const EndRecord64Locator = @import("records/eocd64.zig").EndRecord64Locator;
const EndOfCentralDirectoryRecord64 = @import("records/eocd64.zig").EndOfCentralDirectoryRecord64;
const LocalFileHeader = @import("records/local_file_header.zig").LocalFileHeader;
const extra = @import("extra.zig");

pub const Iterator = struct {
    reader: *std.Io.File.Reader,
    cd_index: u64 = 0,
    cd_offset: u64 = 0,
    cd_size: u64 = 0,
    total_entries: u64 = 0,
    cd_end: u64 = 0,
    cd_start: u64 = 0,
    file_size: u64,

    /// entries count DoS guard
    const max_reasonable_entries = 10_000_000;

    pub fn init(reader: *std.Io.File.Reader) !Iterator {
        const file_size = try reader.getSize();
        // read eocd record
        const eocd = try EndOfCentralDirectoryRecord.read(reader);
        try eocd.record.validateStructure(file_size, eocd.offset);

        var iterator: Iterator = .{
            .reader = reader,
            .file_size = file_size,
        };

        const requires_zip64 = eocd.record.requiresZip64();
        switch (requires_zip64) {
            false => {
                try eocd.record.validateSizeFields(file_size);
                iterator.cd_size = eocd.record.central_directory_size;
                iterator.cd_offset = eocd.record.central_directory_offset;
                iterator.total_entries = eocd.record.record_count_total;
            },
            true => {
                // the archive is zip64 structure path
                // eocd zip64 allocator check
                const locator = try EndRecord64Locator.read(reader, file_size, eocd.offset);

                const record64 = try EndOfCentralDirectoryRecord64.read(
                    reader,
                    file_size,
                    locator.central_directory_offset,
                );

                iterator.cd_offset = record64.central_directory_offset;
                iterator.cd_size = record64.central_directory_size;
                iterator.total_entries = record64.record_count_total;
            },
        }

        iterator.cd_start = iterator.cd_offset;
        iterator.cd_end = iterator.cd_offset + iterator.cd_size;

        try iterator.validateSizeFields(file_size);
        return iterator;
    }

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
        const entry_end = std.math.add(u64, self.cd_offset, entry_size) catch return error.ZipSizeOverflow;
        if (entry_end > self.cd_end) return error.ZipMalformed;

        // log.debug("entry_size {}", .{entry_size});
        // log.debug("entry_end {}", .{entry_end});

        defer {
            self.cd_index += 1;
            self.cd_offset += entry_size;
        }

        // var file_name_buf: [256]u8 = undefined;
        // const file_name = file_name_buf[0..cdfh.filename_len];
        // try self.reader.interface.readSliceAll(file_name);
        // Kept to compare with the local header's name. readSliceAll refills; toss
        // would assert when the name crosses the end of the buffered bytes (bug 23).
        var name_buf: [max_u16]u8 = undefined;
        const cd_name = name_buf[0..cdfh.filename_len];
        try self.reader.interface.readSliceAll(cd_name);

        // log.debug("Entry #{d} [{d}] - {s}", .{ self.cd_index + 1, self.cd_offset, "idk yet!" });
        // log.debug("{f}", .{cdfh});

        var extra_buf: [max_u16]u8 = undefined;
        const extra_slice = extra_buf[0..cdfh.extra_len];
        try self.reader.interface.readSliceAll(extra_slice);

        if (cdfh.comment_len > 0) {
            try self.reader.interface.discardAll(cdfh.comment_len);
        }

        const requires_zip64 = cdfh.requires_zip64();

        // APPNOTE explicitly forbids unnecessary Zip64 fields.
        const extended_data: extra.Zip64Extended = switch (requires_zip64) {
            true => parse_zip64: {
                const extra_iterator: extra.Iterator = .{ .buf = extra_slice };
                const field = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse {
                    return error.ZipBadExtra;
                };

                const ctx: extra.Context = .{
                    .zip64_extended_extra_field = .{
                        .uncompressed_size = cdfh.uncompressed_size,
                        .compressed_size = cdfh.compressed_size,
                        .disk_number_start = cdfh.disk_number_start,
                        .local_file_header_relative_offset = cdfh.local_file_header_relative_offset,
                    },
                };
                const out = try field.parse(ctx);
                break :parse_zip64 out.zip64_extended_extra_field;
            },
            false => .{
                .compressed_size = @intCast(cdfh.compressed_size),
                .uncompressed_size = @intCast(cdfh.uncompressed_size),
                .local_file_header_relative_offset = @intCast(cdfh.local_file_header_relative_offset),
                .disk_number_start = @intCast(cdfh.disk_number_start),
            },
        };

        // The central directory is the source of truth. The local header
        // and descriptor can only reject the entry, never change what is read (bug 21).
        var local_file_header = try LocalFileHeader.read(
            self.reader,
            extended_data.local_file_header_relative_offset,
        );

        // APPNOTE never says the two must match, but 4.4.17.2 only allows a different name
        // under bit 13, which we refuse. A mismatch makes tools disagree on what is inside.
        if (local_file_header.filename_len != cdfh.filename_len or
            local_file_header.compression_method != cdfh.compression_method or
            local_file_header.flags.data_descriptor != cdfh.flags.data_descriptor or
            !try self.localNameMatches(cd_name))
        {
            return error.ZipLocalHeaderMismatch;
        }

        if (cdfh.flags.data_descriptor) {
            // Bit 3: local CRC and sizes SHOULD be zero (APPNOTE 4.4.4); some writers fill
            // them in, so accept zero or the central value.
            if (local_file_header.crc32 != 0 and local_file_header.crc32 != cdfh.crc32) {
                return error.ZipLocalHeaderMismatch;
            }

            const data_descriptor_offset: u64 =
                extended_data.local_file_header_relative_offset +
                LocalFileHeader.size +
                local_file_header.filename_len +
                local_file_header.extra_len +
                extended_data.compressed_size;

            // Descriptor sizes are 8 bytes when the local header has a ZIP64 extra, whatever
            // the central directory has (APPNOTE 4.3.9.2).
            const data_descriptor = try DataDescriptor.read(
                self.reader,
                data_descriptor_offset,
                try self.localHasZip64Extra(extended_data.local_file_header_relative_offset, local_file_header),
            );
            if (data_descriptor.crc32 != cdfh.crc32 or
                data_descriptor.compressed_size != extended_data.compressed_size or
                data_descriptor.uncompressed_size != extended_data.uncompressed_size)
            {
                return error.ZipBadDataDescriptor;
            }
            // stream checks against the header's CRC, which may be zero here.
            local_file_header.crc32 = cdfh.crc32;
        } else {
            if (local_file_header.crc32 != cdfh.crc32) return error.ZipLocalHeaderMismatch;

            var lfh_csize: u64 = local_file_header.compressed_size;
            var lfh_usize: u64 = local_file_header.uncompressed_size;

            if (lfh_csize == 0xFFFFFFFF or lfh_usize == 0xFFFFFFFF) {
                var buf: [max_u16]u8 = undefined;
                const header_offset = extended_data.local_file_header_relative_offset;
                const extra_offset = header_offset + LocalFileHeader.size + @as(u64, local_file_header.filename_len);
                try self.reader.seekTo(extra_offset);

                const lfh_extra = buf[0..local_file_header.extra_len];
                self.reader.interface.readSliceAll(lfh_extra) catch |err| switch (err) {
                    error.EndOfStream => return error.ZipTruncated,
                    else => return err,
                };

                const ctx: extra.Context = .{
                    .zip64_extended_extra_field = .{
                        .uncompressed_size = local_file_header.uncompressed_size,
                        .compressed_size = local_file_header.compressed_size,
                        .disk_number_start = null,
                        .local_file_header_relative_offset = 0,
                    },
                };

                const extra_iterator: extra.Iterator = .{ .buf = lfh_extra };
                const f = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse return error.ZipBadExtra;
                const z = (try f.parse(ctx)).zip64_extended_extra_field;
                lfh_csize = z.compressed_size;
                lfh_usize = z.uncompressed_size;
            }

            if (lfh_csize != extended_data.compressed_size or lfh_usize != extended_data.uncompressed_size) {
                return error.ZipLocalHeaderMismatch;
            }
        }

        return FileData{
            .header = local_file_header,
            .compressed_size = extended_data.compressed_size,
            .uncompressed_size = extended_data.uncompressed_size,
            .offset = extended_data.local_file_header_relative_offset,
        };
    }

    // TODO (dapa) should i re-check on local file header too?
    // which one should be the trusted canonical sources?
    // zip64_extra = .{
    //     .compressed_size = @intCast(file_header.compressed_size),
    //     .uncompressed_size = @intCast(file_header.uncompressed_size),
    //     .disk_number_start = null,
    //     .local_file_header_relative_offset = null,
    // };
    //
    // if (file_header.requires_zip64()) {
    //     const extra_iterator: Extra.Iterator = .{ .buf = extra };
    //     const field = extra_iterator.find(HeaderId.zip64_extended_extra_field) orelse return error.Zip64Malformed;
    //     const ctx: Extra.Context = .{
    //         .zip64_extended_extra_field = .{
    //             .uncompressed_size = file_header.uncompressed_size,
    //             .compressed_size = file_header.compressed_size,
    //             .local_file_header_relative_offset = null,
    //             .disk_number_start = null,
    //         },
    //     };
    //     const out = try field.parse(ctx);
    //     zip64_extra = out.zip64_extended_extra_field;
    // }
    //
    // log.debug("{f}", .{file_header});

    /// Whether the name after the local header just read equals `cd_name`. The caller has
    /// already checked the lengths match.
    fn localNameMatches(self: *Iterator, cd_name: []const u8) !bool {
        var chunk: [256]u8 = undefined;
        var i: usize = 0;
        while (i < cd_name.len) {
            const n = @min(chunk.len, cd_name.len - i);
            self.reader.interface.readSliceAll(chunk[0..n]) catch |err| switch (err) {
                error.EndOfStream => return error.ZipTruncated,
                else => return err,
            };
            if (!std.mem.eql(u8, chunk[0..n], cd_name[i..][0..n])) return false;
            i += n;
        }
        return true;
    }

    /// Whether the local header at `header_offset` has a ZIP64 extra field (0x0001).
    fn localHasZip64Extra(self: *Iterator, header_offset: u64, lfh: LocalFileHeader) !bool {
        if (lfh.extra_len == 0) return false;
        var buf: [max_u16]u8 = undefined;
        const lfh_extra = buf[0..lfh.extra_len];
        try self.reader.seekTo(header_offset + LocalFileHeader.size + @as(u64, lfh.filename_len));
        self.reader.interface.readSliceAll(lfh_extra) catch |err| switch (err) {
            error.EndOfStream => return error.ZipTruncated,
            else => return err,
        };
        const extra_iterator: extra.Iterator = .{ .buf = lfh_extra };
        return extra_iterator.find(HeaderId.zip64_extended_extra_field) != null;
    }

    fn validateSizeFields(self: Iterator, file_size: u64) error{ EntryCountExceedsLimit, Zip64SizeOverflow }!void {
        // validate unified central directory bounds
        if (self.total_entries > max_reasonable_entries) return error.EntryCountExceedsLimit;

        if (self.cd_offset >= file_size) return error.Zip64SizeOverflow;
        const end = std.math.add(u64, self.cd_offset, self.cd_size) catch return error.Zip64SizeOverflow;
        if (end > file_size) return error.Zip64SizeOverflow;
    }
};

test {
    const src_dir = "testdata/accessible_epub_3.epub";
    const io = std.testing.io;

    var file = try std.Io.Dir.cwd().openFile(io, src_dir, .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);

    var zip_iter: std.zip.Iterator = try .init(&reader);

    var filename_buf: [128]u8 = undefined;
    var count: usize = 0;

    while (try zip_iter.next()) |entry| {
        // log.debug("entry: {}", .{entry});
        const filename = filename_buf[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(filename);
        // entry.extract()

        // log.debug("filename: {s}", .{filename});
        // log.debug("size of CentralDirectoryFileHeader: {d}", .{@sizeOf(CentralDirectoryFileHeader)});
        count += 1;
    }
}

test "eocd_structure" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var file = try std.Io.Dir.cwd().openFile(io, "testdata/accessible_epub_3.epub", .{ .mode = .read_only });
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var freader = file.reader(io, &buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var iter = try Iterator.init(&freader);
    var count: usize = 0;
    while (try iter.next()) |fd| {
        try fd.extract(io, &freader, tmp.dir, .{ .file_exists_behavior = .overwrite });
        count += 1;
    }

    // Expected values come from Python's zipfile on the same archive.
    try std.testing.expectEqual(@as(usize, 38), count);

    // Stored entry: exact bytes.
    const mimetype = try tmp.dir.readFileAlloc(io, "mimetype", gpa, .limited(64));
    defer gpa.free(mimetype);
    try std.testing.expectEqualStrings("application/epub+zip", mimetype);

    // Deflated entry: size and CRC-32 of the extracted file.
    const ch01 = try tmp.dir.readFileAlloc(io, "EPUB/ch01.xhtml", gpa, .limited(1 << 20));
    defer gpa.free(ch01);
    try std.testing.expectEqual(@as(usize, 6853), ch01.len);
    try std.testing.expectEqual(@as(u32, 0x4a8c67f2), std.hash.Crc32.hash(ch01));
}

// var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
// r.interface.toss(header.filename_len);
// log.debug("seek after reading lfh.filename {}", .{r.logicalPos()});
//
// var extra_buf: [max_u16]u8 = undefined;
// const extra = extra_buf[0..header.extra_len];
// try r.interface.readSliceAll(extra);
//
// log.debug("seek after reading lfh.filename {}", .{r.logicalPos()});
// log.debug("extra ok: {}", .{extra.len == header.extra_len});
//
// var zip64_extended_extra: Extra.Zip64Extended = .{
//     .compressed_size = header.compressed_size,
//     .uncompressed_size = header.uncompressed_size,
// };
//
// if (header.requires_zip64()) {
//     var iter: Extra.Iterator = .{ .buf = extra };
//     while (try iter.next()) |field| {
//         const id = field.asHeaderID() orelse return error.BadHeaderID;
//         if (id == HeaderId.zip64_extended_extra_field) {
//             const ctx: Extra.Context = .{
//                 .zip64_extended_extra_field = .{
//                     .uncompressed_size = header.uncompressed_size,
//                     .compressed_size = header.compressed_size,
//                     .disk_number_start = null,
//                     .local_file_header_relative_offset = null,
//                 },
//             };
//
//             const out = try field.parse(ctx);
//             zip64_extended_extra = out.zip64_extended_extra_field;
//         }
//     }
// }
//
// log.debug("extra metadata [lfh]: {}", .{zip64_extended_extra});
// log.debug("{f}", .{header});
// log.debug("seek after reading lfh.extra {}", .{r.logicalPos()});
//
// if (header.compression_method == CompressionMethod.deflate) {
//     var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
//     var decompress: std.compress.flate.Decompress = .init(&r.interface, .raw, &flate_buf);
//     log.debug("data decompressed:", .{});
//
//     while (true) {
//         const byte = decompress.reader.takeByte() catch |err| switch (err) {
//             error.EndOfStream => break,
//             else => return err,
//         };
//
//         log.debug("{c}", .{byte});
//     }
// } else if (header.compression_method == CompressionMethod.stored) {
//     var data_buf: [4096]u8 = undefined; // output buffer
//     // try r.seekTo(zip64_extended_extra.compressed_size);
//     const data = data_buf[0..zip64_extended_extra.compressed_size];
//     try r.interface.readSliceAll(data);
//     log.debug("data (0): {s}", .{data});
// }
