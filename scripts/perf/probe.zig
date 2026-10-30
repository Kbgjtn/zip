//! Perf probe for the scripts in scripts/: writes the archives `zig build bench` times and
//! reads them back one way at a time, so a profiler or strace sees a single case.
//!
//!     probe gen OUT [--count N] [--size BYTES] [--data random|text] [--method deflate|stored]
//!     probe read ARCHIVE [--source memory|file|file-alloc] [--case CASE] [--runs N] [--buffer BYTES]
//!     probe extract ARCHIVE DEST
//!
//! Cases: `list` (next only), `names` (next and entryName), `stream` (streamEntry into a
//! discarding writer, as `zig build bench` minus the names), `stream-names` (what
//! `zig build bench` times), `alloc` (readEntryAlloc and free), `inflate-std` (std's
//! inflater on each entry's data, no checks and no CRC, memory only) and `crc` (CRC-32
//! over as many bytes as the archive holds uncompressed).
//!
//! `random` data matches tools/bench.zig: a seeded PRNG over a 19-byte alphabet. `text`
//! repeats one English sentence, which deflate shrinks to almost nothing.

const std = @import("std");
const zip = @import("zip");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const name_len = "d000/f0000000.txt".len;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return usage(io);
    if (std.mem.eql(u8, args[1], "gen")) return gen(gpa, io, args[2], args[3..]);
    if (std.mem.eql(u8, args[1], "read")) return read(gpa, io, args[2], args[3..]);
    if (std.mem.eql(u8, args[1], "extract") and args.len == 4) return extract(gpa, io, args[2], args[3]);
    return usage(io);
}

fn usage(io: Io) error{InvalidArgument} {
    var buf: [512]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    stderr.interface.writeAll(
        \\usage: probe gen OUT [--count N] [--size BYTES] [--data random|text] [--method deflate|stored]
        \\       probe read ARCHIVE [--source memory|file|file-alloc] [--case CASE] [--runs N] [--buffer BYTES]
        \\       probe extract ARCHIVE DEST
        \\cases: list names stream stream-names alloc inflate-std crc
        \\
    ) catch {};
    stderr.interface.flush() catch {};
    return error.InvalidArgument;
}

/// Returns the value after `flag` in `args`, or null.
fn option(args: []const [:0]const u8, flag: []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, flag) and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn number(args: []const [:0]const u8, flag: []const u8, default: usize) !usize {
    const text = option(args, flag) orelse return default;
    return std.fmt.parseInt(usize, text, 10);
}

fn gen(gpa: Allocator, io: Io, out_path: []const u8, args: []const [:0]const u8) !void {
    const count = try number(args, "--count", 20_000);
    const size = try number(args, "--size", 132);
    const text = std.mem.eql(u8, option(args, "--data") orelse "random", "text");
    const method: zip.CompressionMethod = if (std.mem.eql(u8, option(args, "--method") orelse "deflate", "stored")) .stored else .deflate;

    const data = try gpa.alloc(u8, count * size);
    defer gpa.free(data);
    if (text) {
        const sentence = "the quick brown fox jumps over the lazy dog ";
        for (data, 0..) |*c, i| c.* = sentence[i % size % sentence.len];
    } else {
        var prng: std.Random.DefaultPrng = .init(0x5a17);
        const random = prng.random();
        const alphabet = "etaoinshrdlucmfwy \n";
        for (data) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
    }

    var file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &out_buf);
    var zw: zip.Writer = undefined;
    try zw.init(gpa, &fw.interface);
    defer zw.deinit();
    var name: [name_len]u8 = undefined;
    for (0..count) |i| {
        _ = try std.fmt.bufPrint(&name, "d{d:0>3}/f{d:0>7}.txt", .{ i / 1000 % 1000, i % 10_000_000 });
        try zw.addBytes(&name, data[i * size ..][0..size], .{ .method = method });
    }
    try zw.finish();
}

const SourceKind = enum { memory, file, @"file-alloc" };

const Case = enum { list, names, stream, @"stream-names", alloc, @"inflate-std", crc };

const Totals = struct { entries: u64 = 0, bytes: u64 = 0 };

fn read(gpa: Allocator, io: Io, path: []const u8, args: []const [:0]const u8) !void {
    const runs = try number(args, "--runs", 5);
    const buffer_len = try number(args, "--buffer", 4096);
    const source = std.meta.stringToEnum(SourceKind, option(args, "--source") orelse "memory") orelse return usage(io);
    const from_file = source != .memory;
    const case = std.meta.stringToEnum(Case, option(args, "--case") orelse "stream-names") orelse return usage(io);
    if (case == .@"inflate-std" and from_file) return usage(io);

    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const file_buf = try gpa.alloc(u8, buffer_len);
    defer gpa.free(file_buf);

    const times = try gpa.alloc(u64, @max(runs, 1));
    defer gpa.free(times);
    var totals: Totals = .{};
    for (times) |*t| {
        var reader = file.reader(io, file_buf);
        const start = Io.Timestamp.now(io, .awake);
        var archive = switch (source) {
            .memory => try zip.Archive.openMemory(bytes, .{}),
            .file => try zip.Archive.openFile(&reader, .{}),
            .@"file-alloc" => try zip.Archive.openFileAlloc(gpa, &reader, .{}),
        };
        defer archive.deinit(gpa);
        totals = try runCase(gpa, &archive, bytes, case);
        t.* = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    const ns = times[times.len / 2];
    const seconds = @as(f64, @floatFromInt(@max(ns, 1))) / std.time.ns_per_s;

    var out_buf: [256]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    try stdout.interface.print("{s:<13} {s:<10} {d:>10.2} ms {d:>12.0} entries/s {d:>8.1} MB/s\n", .{
        @tagName(case),
        @tagName(source),
        seconds * 1000,
        @as(f64, @floatFromInt(totals.entries)) / seconds,
        @as(f64, @floatFromInt(totals.bytes)) / 1e6 / seconds,
    });
    try stdout.interface.flush();
}

fn runCase(gpa: Allocator, archive: *zip.Archive, bytes: []const u8, case: Case) !Totals {
    var discard_buf: [64 * 1024]u8 = undefined;
    var discard: Io.Writer.Discarding = .init(&discard_buf);
    var name_buf: [std.math.maxInt(u16)]u8 = undefined;
    var totals: Totals = .{};
    var crc_buf: [64 * 1024]u8 = @splat('a');
    var crc: std.hash.Crc32 = .init();
    var window: [std.compress.flate.max_window_len]u8 = undefined;

    while (try archive.next()) |entry| {
        totals.entries += 1;
        totals.bytes += entry.uncompressed_size;
        switch (case) {
            .list => {},
            .names => _ = try archive.entryName(&entry, &name_buf),
            .stream => _ = try archive.streamEntry(&entry, &discard.writer),
            .@"stream-names" => {
                _ = try archive.entryName(&entry, &name_buf);
                _ = try archive.streamEntry(&entry, &discard.writer);
            },
            .alloc => gpa.free(try archive.readEntryAlloc(gpa, &entry, std.math.maxInt(u64))),
            .@"inflate-std" => {
                const lfh = bytes[entry.local_header_offset..][0..30];
                const start = entry.local_header_offset + 30 +
                    std.mem.readInt(u16, lfh[26..28], .little) + std.mem.readInt(u16, lfh[28..30], .little);
                var in: Io.Reader = .fixed(bytes[start..][0..entry.compressed_size]);
                if (entry.method == .stored) {
                    try in.streamExact64(&discard.writer, entry.uncompressed_size);
                } else {
                    var inflate: std.compress.flate.Decompress = .init(&in, .raw, &window);
                    try inflate.reader.streamExact64(&discard.writer, entry.uncompressed_size);
                }
            },
            .crc => {
                var left = entry.uncompressed_size;
                while (left > 0) {
                    const n: usize = @intCast(@min(left, crc_buf.len));
                    crc.update(crc_buf[0..n]);
                    left -= n;
                }
            },
        }
    }
    std.mem.doNotOptimizeAway(crc.final());
    return totals;
}

/// Extracts `path` into the new folder `dest_path` with `extractAll`'s defaults.
fn extract(gpa: Allocator, io: Io, path: []const u8, dest_path: []const u8) !void {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var archive = try zip.Archive.openFile(&reader, .{});
    var dest = try Io.Dir.cwd().createDirPathOpen(io, dest_path, .{});
    defer dest.close(io);
    try archive.extractAll(gpa, io, dest, .{});
}
