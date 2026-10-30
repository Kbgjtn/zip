//! Where the archive bytes come from: an open file or a slice already in memory.
//!
//! Every record reader asks the source for a reader positioned at an offset, then takes
//! its bytes from that reader. The ZIP format is read by offsets (the central directory
//! points back at local headers, APPNOTE 4.3.12), so a source only has to answer two
//! questions: how big is the archive, and give me a reader at this offset.
//!
//! A memory source never fails I/O. Reading past the end of its bytes gives
//! `EndOfStream`, which the record readers report as `ZipTruncated`, just as a file that
//! ends early does.

const std = @import("std");

pub const Source = union(enum) {
    /// The caller owns the file reader and keeps it alive while the source is used.
    file: *std.Io.File.Reader,
    memory: Memory,

    /// The whole archive in memory. The caller owns `bytes` and keeps them alive.
    pub const Memory = struct {
        bytes: []const u8,
        /// Reads from `bytes`. Reset by `readerAt`. Points at `bytes`, never at the
        /// `Memory` itself, so a `Source` can be copied or returned by value.
        reader: std.Io.Reader,
    };

    pub fn fromFile(reader: *std.Io.File.Reader) Source {
        return .{ .file = reader };
    }

    pub fn fromMemory(bytes: []const u8) Source {
        return .{ .memory = .{ .bytes = bytes, .reader = .fixed(bytes) } };
    }

    /// The errors of `readerAt`: a failed seek or read, or `ZipTruncated` when a file
    /// that can't seek ends before the offset.
    pub const ReadError = std.Io.File.SeekError || error{ ReadFailed, ZipTruncated };

    /// Size of the archive in bytes.
    pub fn size(s: *const Source) std.Io.File.Reader.SizeError!u64 {
        return switch (s.*) {
            .file => |r| r.getSize(),
            .memory => |m| m.bytes.len,
        };
    }

    /// Returns a reader positioned at `offset`. The reader stays valid until the next
    /// `readerAt` call on this source. For memory, an offset past the end gives a reader
    /// that is already at its end.
    ///
    /// A file that can't seek (a pipe, say) seeks forward by reading. If it ends before
    /// `offset`, that is `ZipTruncated`, as for any read past the end, never `EndOfStream`.
    pub fn readerAt(s: *Source, offset: u64) ReadError!*std.Io.Reader {
        switch (s.*) {
            .file => |r| {
                r.seekTo(offset) catch |err| return switch (err) {
                    error.EndOfStream => error.ZipTruncated,
                    else => |e| e,
                };
                return &r.interface;
            },
            .memory => |*m| {
                const start: usize = @intCast(@min(offset, m.bytes.len));
                m.reader = .fixed(m.bytes[start..]);
                return &m.reader;
            },
        }
    }
};
