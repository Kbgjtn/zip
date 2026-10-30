//! Baseline reader for scripts/perf-baseline.sh: reads every entry of an archive with
//! Zig's std.zip, the way `std.zip.Iterator.Entry.extract` does, but into a discarding
//! writer. Like std.zip it checks no CRC. With `--extract` it runs `std.zip.extract`.
//!
//!     std_zip_read ARCHIVE
//!     std_zip_read --extract ARCHIVE DEST

const std = @import("std");

const Io = std.Io;
const flate = std.compress.flate;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // The same file buffer as the probe and the bench.
    var buf: [4096]u8 = undefined;

    if (args.len == 4 and std.mem.eql(u8, args[1], "--extract")) {
        var file = try Io.Dir.cwd().openFile(io, args[2], .{});
        defer file.close(io);
        var reader = file.reader(io, &buf);
        var dest = try Io.Dir.cwd().createDirPathOpen(io, args[3], .{});
        defer dest.close(io);
        return std.zip.extract(dest, &reader, .{});
    }
    if (args.len != 2) return error.InvalidArgument;

    var file = try Io.Dir.cwd().openFile(io, args[1], .{});
    defer file.close(io);
    var reader = file.reader(io, &buf);
    var discard_buf: [64 * 1024]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&discard_buf);
    var window: [flate.max_window_len]u8 = undefined;

    var iter = try std.zip.Iterator.init(&reader);
    while (try iter.next()) |entry| {
        try reader.seekTo(entry.file_offset);
        const lfh = try reader.interface.takeStruct(std.zip.LocalFileHeader, .little);
        try reader.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + lfh.filename_len + lfh.extra_len);
        switch (entry.compression_method) {
            .store => try reader.interface.streamExact64(&discard.writer, entry.uncompressed_size),
            .deflate => {
                var inflate: flate.Decompress = .init(&reader.interface, .raw, &window);
                try inflate.reader.streamExact64(&discard.writer, entry.uncompressed_size);
            },
            else => return error.UnsupportedCompressionMethod,
        }
    }
}
