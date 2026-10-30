//! `zig build bench`: times the writer and the reader through the public `zip` API only.
//! Not part of `zig build test`. Built ReleaseFast unless `-Doptimize` names a release mode.
//!
//! Two sets of entries are timed: many small ones (default 20,000 of 132 bytes) and a few
//! large ones (default 100 of 1 MiB). For each set it writes a deflated and a stored
//! archive in memory, reads the deflated one back from memory and from a file, and
//! extracts it into a temporary folder. Each step runs `--runs` times and the table shows
//! the median, in milliseconds, entries per second and MB/s of uncompressed data.
//!
//!     zig build bench -- --count 20000 --size 132 --large-count 100 --large-size 1048576 --runs 5

const std = @import("std");
const zip = @import("zip");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = struct {
    count: usize = 20_000,
    size: usize = 132,
    large_count: usize = 100,
    large_size: usize = 1 << 20,
    runs: usize = 5,
    /// Skip `extractAll`, which creates every entry as a file.
    extract: bool = true,
};

const usage =
    \\usage: bench [--count N] [--size BYTES] [--large-count N] [--large-size BYTES]
    \\             [--runs N] [--no-extract]
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var config: Config = .{};
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-extract")) {
            config.extract = false;
            continue;
        }
        const field: *usize = if (std.mem.eql(u8, arg, "--count"))
            &config.count
        else if (std.mem.eql(u8, arg, "--size"))
            &config.size
        else if (std.mem.eql(u8, arg, "--large-count"))
            &config.large_count
        else if (std.mem.eql(u8, arg, "--large-size"))
            &config.large_size
        else if (std.mem.eql(u8, arg, "--runs"))
            &config.runs
        else
            return fail(io, "unknown argument: {s}\n", .{arg});
        const value = args.next() orelse return fail(io, "{s} needs a number\n", .{arg});
        field.* = std.fmt.parseInt(usize, value, 10) catch return fail(io, "not a number: {s}\n", .{value});
    }
    if (config.runs == 0) return fail(io, "--runs must be at least 1\n", .{});

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;

    const tmp_parent = init.environ_map.get("TMPDIR") orelse "/tmp";
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}/zip-bench", .{tmp_parent});
    defer gpa.free(tmp_path);
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, tmp_path) catch {};
    var tmp = try cwd.createDirPathOpen(io, tmp_path, .{});
    defer {
        tmp.close(io);
        cwd.deleteTree(io, tmp_path) catch {};
    }

    try out.print("median of {d} runs, entries made by a seeded PRNG\n\n", .{config.runs});
    try out.print("{s:<30} {s:>10} {s:>14} {s:>10}\n", .{ "step", "ms", "entries/s", "MB/s" });
    try out.flush();

    const sets = [_]struct { count: usize, size: usize }{
        .{ .count = config.count, .size = config.size },
        .{ .count = config.large_count, .size = config.large_size },
    };
    for (sets) |set| {
        if (set.count == 0) continue;
        var bench: Bench = try .init(gpa, io, tmp, set.count, set.size, config);
        defer bench.deinit();
        try bench.run(out);
    }
}

fn fail(io: Io, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    var buf: [256]u8 = undefined;
    var stderr = Io.File.stderr().writer(io, &buf);
    stderr.interface.print(fmt ++ usage, args) catch {};
    stderr.interface.flush() catch {};
    return error.InvalidArgument;
}

/// One set of `count` entries of `size` bytes, and the archives made from it.
const Bench = struct {
    gpa: Allocator,
    io: Io,
    tmp: Io.Dir,
    config: Config,
    count: usize,
    size: usize,
    /// Every entry's data, back to back.
    data: []u8,
    /// Every entry's name, back to back, `name_len` bytes each.
    names: []u8,
    deflated: []u8 = &.{},
    times: []u64,
    /// Runs of `extract` so far; each extracts into its own folder.
    extract_runs: usize = 0,

    const name_len = "d000/f0000000.txt".len;

    fn init(gpa: Allocator, io: Io, tmp: Io.Dir, count: usize, size: usize, config: Config) !Bench {
        const data = try gpa.alloc(u8, count * size);
        errdefer gpa.free(data);
        // Words from a small alphabet: deflate gets about 2:1, like text, not 1000:1.
        var prng: std.Random.DefaultPrng = .init(0x5a17);
        const random = prng.random();
        const alphabet = "etaoinshrdlucmfwy \n";
        for (data) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];

        const names = try gpa.alloc(u8, count * name_len);
        errdefer gpa.free(names);
        for (0..count) |i| {
            _ = std.fmt.bufPrint(names[i * name_len ..][0..name_len], "d{d:0>3}/f{d:0>7}.txt", .{ i / 1000 % 1000, i % 10_000_000 }) catch unreachable;
        }
        return .{
            .gpa = gpa,
            .io = io,
            .tmp = tmp,
            .config = config,
            .count = count,
            .size = size,
            .data = data,
            .names = names,
            .times = try gpa.alloc(u64, config.runs),
        };
    }

    fn deinit(self: *Bench) void {
        self.gpa.free(self.data);
        self.gpa.free(self.names);
        self.gpa.free(self.deflated);
        self.gpa.free(self.times);
    }

    fn run(self: *Bench, out: *Io.Writer) !void {
        var label_buf: [64]u8 = undefined;
        const set = try std.fmt.bufPrint(&label_buf, "{d} x {Bi}", .{ self.count, self.size });
        try out.print("\n{s}\n", .{set});

        try self.report(out, "write deflate", try self.time(writeDeflate));
        try self.report(out, "write stored", try self.time(writeStored));
        self.deflated = try self.write(.deflate);
        try out.print("  (deflated archive: {d} bytes, stored data: {d} bytes)\n", .{ self.deflated.len, self.data.len });
        try self.report(out, "read from memory", try self.time(readMemory));
        try self.tmp.writeFile(self.io, .{ .sub_path = "bench.zip", .data = self.deflated });
        try self.report(out, "read from file", try self.time(readFile));
        if (self.config.extract) {
            try self.report(out, "extractAll to a temp folder", try self.time(extract));
            // Deleting is left out of the timing.
            var path_buf: [32]u8 = undefined;
            for (0..self.extract_runs) |i| {
                try self.tmp.deleteTree(self.io, try std.fmt.bufPrint(&path_buf, "out{d}", .{i}));
            }
        }
    }

    /// Runs `step` `config.runs` times and returns the median in nanoseconds.
    fn time(self: *Bench, comptime step: fn (*Bench) anyerror!void) !u64 {
        for (self.times) |*t| {
            const start = Io.Timestamp.now(self.io, .awake);
            try step(self);
            const elapsed = start.durationTo(Io.Timestamp.now(self.io, .awake));
            t.* = @intCast(elapsed.nanoseconds);
        }
        std.mem.sort(u64, self.times, {}, std.sort.asc(u64));
        return self.times[self.times.len / 2];
    }

    fn report(self: *const Bench, out: *Io.Writer, step: []const u8, ns: u64) !void {
        const seconds = @as(f64, @floatFromInt(@max(ns, 1))) / std.time.ns_per_s;
        const entries_per_s = @as(f64, @floatFromInt(self.count)) / seconds;
        const mb_per_s = @as(f64, @floatFromInt(self.data.len)) / 1e6 / seconds;
        try out.print("  {s:<28} {d:>10.2} {d:>14.0} {d:>10.1}\n", .{ step, seconds * 1000, entries_per_s, mb_per_s });
        try out.flush();
    }

    fn name(self: *const Bench, i: usize) []const u8 {
        return self.names[i * name_len ..][0..name_len];
    }

    fn write(self: *Bench, method: zip.CompressionMethod) ![]u8 {
        var archive: Io.Writer.Allocating = try .initCapacity(self.gpa, self.data.len + self.count * 128);
        errdefer archive.deinit();
        var zw: zip.Writer = undefined;
        try zw.init(self.gpa, &archive.writer);
        defer zw.deinit();
        for (0..self.count) |i| {
            try zw.addBytes(self.name(i), self.data[i * self.size ..][0..self.size], .{ .method = method });
        }
        try zw.finish();
        return archive.toOwnedSlice();
    }

    fn writeDeflate(self: *Bench) !void {
        self.gpa.free(try self.write(.deflate));
    }

    fn writeStored(self: *Bench) !void {
        self.gpa.free(try self.write(.stored));
    }

    fn readAll(self: *Bench, archive: *zip.Archive) !void {
        var buf: [64 * 1024]u8 = undefined;
        var discard: Io.Writer.Discarding = .init(&buf);
        var name_buf: [name_len]u8 = undefined;
        var n: usize = 0;
        while (try archive.next()) |entry| : (n += 1) {
            _ = try archive.entryName(&entry, &name_buf);
            _ = try archive.streamEntry(&entry, &discard.writer);
        }
        if (n != self.count) return error.WrongEntryCount;
    }

    fn readMemory(self: *Bench) !void {
        var archive = try zip.Archive.openMemory(self.deflated, .{});
        try self.readAll(&archive);
    }

    fn readFile(self: *Bench) !void {
        var file = try self.tmp.openFile(self.io, "bench.zip", .{});
        defer file.close(self.io);
        var buf: [64 * 1024]u8 = undefined;
        var reader = file.reader(self.io, &buf);
        var archive = try zip.Archive.openFile(&reader, .{});
        try self.readAll(&archive);
    }

    fn extract(self: *Bench) !void {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "out{d}", .{self.extract_runs});
        self.extract_runs += 1;
        var dest = try self.tmp.createDirPathOpen(self.io, path, .{});
        defer dest.close(self.io);
        var archive = try zip.Archive.openMemory(self.deflated, .{});
        try archive.extractAll(self.gpa, self.io, dest, .{});
    }
};
