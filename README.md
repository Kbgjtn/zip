# zip

A ZIP archive reader and writer for Zig. It reads archives from a file or from memory, writes them to any `std.Io.Writer`, and treats every archive as untrusted input.

Requires Zig 0.16.0. MIT licensed. Section numbers such as "4.3.9" refer to PKWARE's [APPNOTE.TXT](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).

## Features

- **Reading.** Lists entries from the central directory alone, without allocating. Reads an entry into any `std.Io.Writer` or into memory, and extracts one entry or the whole archive into a directory.
- **Writing.** Stored and deflated entries, folders, symlinks, entry and archive comments, Unix permissions and modification times. `addStream` writes an entry of unknown size from any `std.Io.Reader`, using a data descriptor (4.3.9).
- **ZIP64.** Read from the end records, the central and local extra fields and the data descriptor. Written automatically for entries and archives that need it; streamed entries opt in up front.
- **Checked reads.** Every entry's CRC-32 and size are verified. The local header and the data descriptor must agree with the central directory.
- **Limits.** Entry count, entry size, total output and compression ratio are capped by default, and checked before any data is decompressed.
- **Safe extraction.** Names are cleaned and checked before anything touches the disk. Symlinks are refused unless enabled, and then only those that stay inside the destination are created.

Compared with `std.zip` in Zig 0.16.0:

| | `std.zip` | this library |
|---|---|---|
| Write archives | no | yes |
| Read an entry into memory or a writer | no, extract to a directory only | yes |
| CRC-32 of the extracted data | not checked | checked |
| Size and ratio limits | none | on by default |
| Path checks | leading `/` and `..` | also backslashes, drive letters, control bytes, Windows reserved names |
| Symlinks, Unix modes, timestamps | not interpreted | read, written and applied |

## Installation

Fetch the package. The URL below is a placeholder until the repository is public.

```sh
zig fetch --save git+https://codeberg.org/Kbgjtn/zip#v0.1.0
```

Add the module in `build.zig`:

```zig
const zip_dep = b.dependency("zip", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zip", zip_dep.module("zip"));
```

## Examples

These examples are compiled and run by `zig build test` (`src/tests/readme.zig`). A test fails if this section and that file differ.

List the entries of an archive on disk:

```zig
const std = @import("std");
const zip = @import("zip");
```

```zig
/// Writes the name and size of every entry in the archive at `path` to `out`, one per line.
fn list(io: std.Io, dir: std.Io.Dir, path: []const u8, out: *std.Io.Writer) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var archive = try zip.Archive.openFile(&reader, .{});
    var name_buf: [std.math.maxInt(u16)]u8 = undefined;
    while (try archive.next()) |entry| {
        const name = try entry.fileName(&archive.source, &name_buf);
        try out.print("{s} {d}\n", .{ name, entry.uncompressed_size });
    }
}
```

An `Entry` does not hold its name. `fileName` reads it from the archive when needed, so listing never allocates.

Read one entry of an archive held in memory:

```zig
/// Returns the bytes of the entry named `wanted`, or null if there is none.
/// Caller owns returned memory.
fn readOne(gpa: std.mem.Allocator, bytes: []const u8, wanted: []const u8) !?[]u8 {
    var archive = try zip.Archive.openMemory(bytes, .{});
    var name_buf: [std.math.maxInt(u16)]u8 = undefined;
    while (try archive.next()) |entry| {
        const name = try entry.fileName(&archive.source, &name_buf);
        if (std.mem.eql(u8, name, wanted)) return try archive.readEntryAlloc(gpa, &entry, 16 << 20);
    }
    return null;
}
```

`readEntryAlloc` fails with `error.ZipEntryTooLarge` before allocating if the entry is larger than `max_size`.

Write an archive:

```zig
/// Writes a small archive to `path`: a stored file, a folder and a streamed file.
fn write(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var out_buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &out_buf);

    var zw: zip.Writer = undefined;
    try zw.init(gpa, &fw.interface);
    defer zw.deinit();

    try zw.addBytes("hello.txt", "hello\n", .{ .method = .stored });
    try zw.addDirectory("docs", .{});
    var lines: std.Io.Reader = .fixed("line 1\nline 2\n");
    try zw.addStream("docs/log.txt", &lines, .{});
    try zw.setComment("made with zig");
    try zw.finish();
}
```

`addBytes` chooses ZIP64 by itself. `addStream` writes its local header before the data, so an entry that may reach 4 GiB needs `.zip64 = true` in its options. Without it, such an entry fails with `error.Zip64Required`.

Extract an archive with a tighter limit:

```zig
/// Extracts the archive at `path` into the folder `dest_path`, with a 64 MiB cap per
/// entry. Symlink entries are left out.
fn extract(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, dest_path: []const u8) !void {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var limits: zip.Archive.Limits = .default;
    limits.max_entry_size = 64 << 20;
    var archive = try zip.Archive.openFile(&reader, .{ .limits = limits });

    var dest = try dir.createDirPathOpen(io, dest_path, .{});
    defer dest.close(io);
    try archive.extractAll(gpa, io, dest, .{ .symlinks = .skip });
}
```

Handle errors by kind:

```zig
/// Returns a word for what kind of failure `err` is.
fn describe(err: zip.errors.EntryError) []const u8 {
    return switch (err) {
        error.ZipCrcMismatch, error.ZipSizeMismatch, error.ZipBadDeflate => "corrupt",
        error.ZipEncrypted, error.ZipUnsupportedMethod => "unsupported",
        else => "other",
    };
}
```

## Limits

`Archive.Limits` is set through `Archive.OpenOptions.limits`. Every check uses the sizes in the central directory and runs before any data is read. Output never exceeds the declared size, so the declared size is the most a read can produce.

| Field | Default | Error |
|---|---|---|
| `max_entries` | 1,000,000 | `ZipTooManyEntries`, from `open` |
| `max_entry_size` | 1 GiB | `ZipEntryTooLarge` |
| `max_total_size` | 4 GiB, all reads through one `Archive` | `ZipTotalTooLarge` |
| `max_ratio` | 1100 (uncompressed / compressed) | `ZipRatioExceeded` |
| `ratio_grace` | 1 MiB; smaller entries skip the ratio check | |

`Limits.default` holds these values. `Limits.unlimited` disables every check, for trusted archives only. The ratio default sits above what deflate can reach (about 1032:1), so it rejects only sizes that are false.

## Safety

- **Paths.** `path.sanitize` rejects empty names, NUL and control bytes, backslashes, absolute paths, drive letters such as `C:`, and any `..` segment (4.4.17.1). Names are rejected, never repaired. On Windows it also rejects reserved device names and segments ending in `.` or a space.
- **Symlinks.** `extractAll` refuses symlink entries by default (`.refuse`). `.skip` leaves them out. `.create_safe` creates only relative links that stay inside the destination and do not pass through another link, after every file and folder is written.
- **Layout.** `Archive.checkLayout` rejects overlapping entries (the overlap form of a zip bomb), duplicate names after cleaning, a file where another entry needs a folder, and a total size over `max_total_size`. `extractAll` runs it first by default.
- **Consistency.** The central directory is authoritative. A local header whose name, method or sizes differ from it fails with `ZipLocalHeaderMismatch`; a data descriptor that differs fails with `ZipBadDataDescriptor`.
- **Writing.** The writer refuses names that the reader would refuse or rewrite, and symlink targets that are absolute or contain `..`, unless `allow_unsafe_target` is set.
- **Extraction.** Existing files are not overwritten unless `file_exists_behavior` says so. Only permission bits are applied, never setuid, setgid or sticky. Owner ids are read but never applied.

## Not supported yet

| Feature | Behavior |
|---|---|
| Encryption (ZipCrypto, AES, strong encryption) | Listed; reading fails with `ZipEncrypted` |
| Encrypted central directory (bit 13) | Reading fails with `ZipCentralDirectoryEncrypted` |
| Patched data (bit 5) | Reading fails with `ZipPatchedData` |
| Methods other than stored (0) and deflate (8) | Listed; reading fails with `ZipUnsupportedMethod` |
| Split and multi-disk archives | `open` or `next` fails with `ZipMultiDisk` |
| Editing an archive in place | No API |
| 8-byte data descriptor with no ZIP64 field in the local header (written by Go's `archive/zip` for entries over 4 GiB) | Reading fails with `ZipBadDataDescriptor` |
| Names without the UTF-8 flag | Returned as raw bytes, not converted from CP437 |

Unsupported entries still list, so a mixed archive can be inspected and its other entries read.

## Errors

Reader functions return named error sets from `zip.errors`: `OpenError`, `CommentError`, `IterError`, `EntryError`, `ReadAllocError` and `LayoutError`. Each lists exactly the errors its function can return. The names fall into groups:

| Group | Meaning |
|---|---|
| `FormatError` | The structure is broken or its records disagree. |
| `UnsupportedError` | Valid, but uses a feature this library refuses. |
| `IntegrityError` | The data does not match its CRC-32 or declared size. |
| `LimitError` | Over a limit in `Archive.Limits`. |
| `PathError` | A name or symlink target is unsafe to extract. |

Errors from the file and from the caller's writer pass through unchanged. Running out of bytes inside a record is `ZipTruncated`, never `EndOfStream`.

The writer returns `WriterFinished` after `finish`, and `WriterFailed` once a call has failed after writing part of an entry or of the central directory. The output is then incomplete and the writer accepts no further calls.

## Testing

| Command | Runs |
|---|---|
| `zig build test` | Unit, round-trip, hostile-archive and README tests, plus the fuzz targets on fixed seeds |
| `zig build test -Doptimize=ReleaseSafe` | The same in ReleaseSafe |
| `zig build test -Dslow-tests` | Adds a 4.1 GiB streamed ZIP64 entry, written and read back |
| `zig build interop` | Checks writer output with `unzip`, `zipinfo`, Python's `zipfile`, `7z` and `std.zip`; missing tools are skipped |
| `zig build test --fuzz -Dllvm -Dtest-filter="fuzz: open and read anything"` | Fuzzes the reader; `"fuzz: writer round-trip"` fuzzes the writer |

Fuzzing needs `-Dllvm`: the self-hosted x86_64 backend in Zig 0.16.0 emits no coverage instrumentation. Fixtures are in `testdata/` and are generated by `zig build gen-testdata`.

## License

MIT. See [LICENSE](LICENSE).
