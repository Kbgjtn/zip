//! `Entry.Reader`: a pull-style reader over one entry's decompressed data, checked like
//! `Archive.streamEntry`. Set up by `Archive.entryReader`, read through `interface`.
//!
//! The data stops at the central uncompressed size (APPNOTE 4.4.9). When the read that
//! reaches it also finds the CRC-32 (4.4.7) wrong, the deflate stream (4.4.5, method 8)
//! not ending there, or bytes left over, that read fails instead of handing over the
//! last bytes, so a caller that reads to `EndOfStream` has seen only checked data.
//!
//! For deflate the caller's buffer is also the inflate window, as with
//! `std.compress.flate.Decompress`: `interface` hands over bytes straight from it, and the
//! last 32 KiB handed over stay in it for back-references. Stored data is copied from the
//! archive, through the buffer if it has one.
//!
//! Like `std.Io.File.Reader`, `interface` reports every failure as `error.ReadFailed` and
//! keeps the cause in `err`, and the reader is returned by value but must not be moved or
//! copied once reading starts: the first read points its inner readers at each other.

const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const errors = @import("errors.zig");
const Entry = @import("Entry.zig");
const Source = @import("source.zig").Source;
const Crc32 = @import("crc32.zig").Crc32;
// Vendored: std 0.16.0's inflater panics on truncated or corrupt input.
const Decompress = @import("vendor/flate/decompress.zig");

const Reader = @This();

/// The shortest `buffer` `Archive.entryReader` takes for a deflated entry: the inflate
/// window. Stored entries take any length, 0 included.
pub const min_buffer_len = flate.max_window_len;

/// Read the entry's data from here. Its `buffer` is the one given to `Archive.entryReader`.
interface: std.Io.Reader,
/// Why the last read failed with `error.ReadFailed`, or null. Once set, every later read
/// fails the same way. `ReadFailed` here means the file underneath failed; its own
/// `std.Io.File.Reader.err` has the cause.
err: ?errors.EntryDataError = null,

/// The archive file, to seek back to `inputPos` when something else moved it. Null for
/// memory, where `memory` holds exactly the compressed bytes.
file: ?*std.Io.File.Reader,
memory: std.Io.Reader,
/// Whether `limited` and `decompress` are set up. They point into this reader, so the
/// first read sets them up, once the reader is where it stays.
wired: bool = false,
/// Offset of the first compressed byte, and how many there are (APPNOTE 4.4.8).
data_start: u64,
compressed_size: u64,
/// Uncompressed bytes not yet handed over.
remaining: u64,
expected_crc: u32,
crc: Crc32 = .init(),
/// Set by `finish` once the end checked out; reads then give `EndOfStream`.
done: bool = false,
method: enum { stored, deflate },
/// From a file: the compressed bytes, bounded to `compressed_size`, and its buffer, which
/// only has to be long enough to keep the vtable calls rare. Set by `wire`.
limited: std.Io.Reader.Limited = undefined,
limited_buffer: [512]u8 = undefined,
/// Inflates `memory` or `limited` into `interface.buffer`. Set by `wire`, for deflate
/// entries only. Its own `reader` is not used.
decompress: Decompress = undefined,

const stored_vtable: std.Io.Reader.VTable = .{ .stream = stream, .discard = discard };
const deflate_vtable: std.Io.Reader.VTable = .{
    .stream = inflateStream,
    .discard = inflateDiscard,
    .readVec = inflateReadVec,
    .rebase = rebase,
};

/// Returns a reader for `entry`, whose data starts at `data_start` in `source`. Not for
/// callers: `Archive.entryReader` checks the entry and `buffer`, then calls this. Holds no
/// pointer into itself until the first read, so it can be returned by value.
pub fn init(source: *const Source, entry: *const Entry, data_start: u64, buffer: []u8) Reader {
    const method: @FieldType(Reader, "method") = if (entry.method == .stored) .stored else .deflate;
    assert(method == .stored or buffer.len >= min_buffer_len);
    // Field by field: a struct literal would also have to give `limited` and `decompress`,
    // and copied about 3.4 KiB of template per entry for them, only for `wire` to
    // overwrite it.
    var r: Reader = undefined;
    r.interface = .{
        .vtable = switch (method) {
            .stored => &stored_vtable,
            .deflate => &deflate_vtable,
        },
        .buffer = buffer,
        .seek = 0,
        .end = 0,
    };
    r.err = null;
    switch (source.*) {
        .file => |file| r.file = file,
        .memory => |m| {
            r.file = null;
            // dataRange checked that the data lies inside the archive. The fixed reader
            // points at the archive bytes, not at itself, so it may be copied.
            const start: usize = @intCast(data_start - m.base);
            r.memory = .fixed(m.bytes[start..][0..@intCast(entry.compressed_size)]);
        },
    }
    r.wired = false;
    r.data_start = data_start;
    r.compressed_size = entry.compressed_size;
    r.remaining = entry.uncompressed_size;
    r.expected_crc = entry.crc32;
    r.crc = .init();
    r.done = false;
    r.method = method;
    return r;
}

/// The compressed bytes: `memory`, or `limited` over the file.
fn input(er: *Reader) *std.Io.Reader {
    return if (er.file != null) &er.limited.interface else &er.memory;
}

/// Points `limited` at the file and `decompress` at the compressed bytes, on the first
/// read. After that the reader must stay put; checked where safety checks are on.
fn wire(er: *Reader) void {
    if (er.wired) {
        // These point into this reader, so a moved or copied reader shows here.
        if (er.file != null) assert(er.limited.interface.buffer.ptr == &er.limited_buffer);
        if (er.method == .deflate) assert(er.decompress.input == er.input());
        return;
    }
    if (er.file) |file| er.limited = .init(&file.interface, .limited64(er.compressed_size), &er.limited_buffer);
    if (er.method == .deflate) er.decompress.initInPlace(er.input(), .raw, &.{});
    er.wired = true;
}

/// The archive offset the compressed reads go on from: what `limited` has taken so far.
fn inputPos(er: *const Reader) u64 {
    return er.data_start + (er.compressed_size - @intFromEnum(er.limited.remaining));
}

fn fail(er: *Reader, err: errors.EntryDataError) error{ReadFailed} {
    er.err = err;
    return error.ReadFailed;
}

/// Maps a failed read of the compressed or inflated data to its cause.
fn readFailure(er: *Reader) errors.EntryDataError {
    if (er.method == .deflate) {
        // The inflater reports its own failures as ReadFailed and keeps the cause.
        if (er.decompress.err) |cause| return switch (cause) {
            error.EndOfStream => error.ZipTruncated,
            error.ReadFailed => error.ReadFailed,
            else => error.ZipBadDeflate,
        };
    }
    return error.ReadFailed; // the file underneath
}

/// What every read does first: fails as before, wires, and moves the shared file reader
/// back to this entry's data.
fn begin(er: *Reader) error{ ReadFailed, EndOfStream }!void {
    if (er.err != null) return error.ReadFailed;
    if (er.done) return error.EndOfStream;
    er.wire();
    if (er.file) |file| {
        // Something else moved the shared file reader: `openEntry` itself, which reads
        // past the data for a data descriptor, a second entry, or `next` without
        // `openFileAlloc`.
        const pos = er.inputPos();
        if (file.logicalPos() != pos) file.seekTo(pos) catch |err| return er.fail(switch (err) {
            // A file that can't seek reads forward to get there, and ended first.
            error.EndOfStream => error.ZipTruncated,
            else => |e| e,
        });
    }
    if (er.remaining == 0) {
        // An empty entry: its end is checked on the first read.
        try er.finish(null);
        return error.EndOfStream;
    }
}

/// Reads up to `dest.len` checked bytes of a stored entry into `dest`. Returns 0 only for
/// an empty `dest`. On the read that hands over the last byte, checks the end first (see
/// the file docs).
fn readInto(er: *Reader, dest: []u8) error{ ReadFailed, EndOfStream }!usize {
    try er.begin();
    const len: usize = @intCast(@min(dest.len, er.remaining));
    if (len == 0) return 0;
    const out = dest[0..len];
    const n = er.input().readSliceShort(out) catch return er.fail(error.ReadFailed);
    if (n == 0) return er.fail(error.ZipTruncated);
    er.crc.update(out[0..n]);
    if (n == er.remaining) try er.finish(null);
    er.remaining -= n;
    return n;
}

/// Inflates more of a deflated entry onto the end of `interface.buffer`. Hands nothing
/// over: `interface.end` moves only once the new bytes are checked.
fn inflate(er: *Reader) error{ ReadFailed, EndOfStream }!void {
    try er.begin();
    const r = &er.interface;
    if (r.buffer.len - r.end < flate.history_len) rebaseKeep(r, flate.history_len);
    const room = r.buffer.len - r.end;
    // The interface only reads when it needs room, and `rebase` makes it.
    assert(room != 0);
    var w: std.Io.Writer = .{
        .buffer = r.buffer,
        .end = r.end,
        .vtable = &.{ .drain = std.Io.Writer.unreachableDrain, .rebase = std.Io.Writer.unreachableRebase },
    };
    const limit: usize = @intCast(@min(room, er.remaining));
    while (w.end == r.end) {
        // 0 with no error: a block or the stream ended. The next call says which.
        _ = er.decompress.streamFallible(&w, .limited(limit)) catch |err| return er.fail(switch (err) {
            error.WriteFailed => unreachable,
            // A clean end of the deflate stream before the declared size: it is whole
            // but shorter.
            error.EndOfStream => error.ZipSizeMismatch,
            error.ReadFailed => er.readFailure(),
        });
        // The inflater writes a match whole or not at all. There is always room for one
        // (see `rebase`), so a match that doesn't fit is longer than the declared size.
        if (w.end == r.end) switch (er.decompress.state) {
            .fixed_block_match, .dynamic_block_match => return er.fail(error.ZipSizeMismatch),
            else => {},
        };
    }
    const n = w.end - r.end;
    er.crc.update(r.buffer[r.end..w.end]);
    if (n == er.remaining) try er.finish(&w);
    er.remaining -= n;
    r.end = w.end;
}

/// Checks the end of the data: the deflate stream ends exactly here, no compressed bytes
/// are left, and the CRC-32 matches. `w` is the writer over the window, for deflate.
fn finish(er: *Reader, w: ?*std.Io.Writer) error{ReadFailed}!void {
    if (er.method == .deflate) {
        // Needed even for an empty entry: its stream is still a final block (`03 00`).
        var empty: std.Io.Writer = .fixed(&.{});
        const out = w orelse &empty;
        // With no room the inflater stops at the next byte it would write, so any state
        // other than these means more data.
        while (true) switch (er.decompress.state) {
            .end => break,
            .protocol_header, .block_header, .fixed_block, .dynamic_block, .protocol_footer => {
                _ = er.decompress.streamFallible(out, .limited(0)) catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.WriteFailed => unreachable,
                    error.ReadFailed => return er.fail(er.readFailure()),
                };
            },
            else => return er.fail(error.ZipSizeMismatch),
        };
    }
    var rest: [1]u8 = undefined;
    const left = er.input().readSliceShort(&rest) catch return er.fail(error.ReadFailed);
    if (left != 0) return er.fail(error.ZipSizeMismatch);
    if (er.crc.final() != er.expected_crc) return er.fail(error.ZipCrcMismatch);
    er.done = true;
}

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const er: *Reader = @alignCast(@fieldParentPtr("interface", r));
    // Before asking `w` for room: a full writer must still see the end.
    if (er.done) return error.EndOfStream;
    if (er.remaining == 0) return er.readInto(&.{});
    if (w.buffer.len == 0) {
        // An unbuffered writer has no slice to read into.
        var chunk: [4 << 10]u8 = undefined;
        const n = try er.readInto(limit.slice(&chunk));
        try w.writeAll(chunk[0..n]);
        return n;
    }
    const dest = limit.slice(try w.writableSliceGreedy(1));
    const n = try er.readInto(dest);
    w.advance(n);
    return n;
}

fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    const er: *Reader = @alignCast(@fieldParentPtr("interface", r));
    // The bytes still count toward the CRC-32, so they are read like any others.
    var chunk: [4 << 10]u8 = undefined;
    return er.readInto(limit.slice(&chunk));
}

fn inflateStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    _ = w;
    _ = limit;
    const er: *Reader = @alignCast(@fieldParentPtr("interface", r));
    try er.inflate();
    return 0;
}

fn inflateReadVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
    _ = data;
    const er: *Reader = @alignCast(@fieldParentPtr("interface", r));
    try er.inflate();
    return 0;
}

fn inflateDiscard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    const er: *Reader = @alignCast(@fieldParentPtr("interface", r));
    try er.inflate();
    const n = limit.minInt(r.end - r.seek);
    r.seek += n;
    return n;
}

/// Makes room as `std.Io.Reader.rebase` asks, keeping the last 32 KiB handed over for
/// back-references. Asserts `capacity` leaves room for them, as
/// `std.compress.flate.Decompress` does: deflate peeks see at most
/// `buffer.len - 32 KiB` bytes at once.
fn rebase(r: *std.Io.Reader, capacity: usize) std.Io.Reader.RebaseError!void {
    rebaseKeep(r, capacity);
}

fn rebaseKeep(r: *std.Io.Reader, capacity: usize) void {
    assert(capacity <= r.buffer.len - flate.history_len);
    const discard_n = @min(r.seek, r.end -| flate.history_len);
    const keep = r.buffer[discard_n..r.end];
    @memmove(r.buffer[0..keep.len], keep);
    r.end = keep.len;
    r.seek -= discard_n;
}
