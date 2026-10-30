//! Reads and writes ZIP archives. `Archive` lists and reads an archive from a file or
//! from memory; `Writer` writes one to any `std.Io.Writer`.
//!
//! An archive ends with the end of central directory record (APPNOTE 4.3.16). It points at
//! the central directory, one header per entry with its name, sizes, CRC-32 and the offset
//! of its local header and data (4.3.12), so the entries can be listed without reading
//! their data.
//!
//! [APPNOTE.TXT - .ZIP File Format Specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)

const std = @import("std");

const format = @import("format.zig");

pub const time = @import("time.zig");
pub const errors = @import("errors.zig");
pub const path = @import("path.zig");

pub const Entry = @import("Entry.zig");
pub const Archive = @import("Archive.zig");
pub const Writer = @import("Writer.zig");

pub const GeneralPurposeFlags = format.GeneralPurposeFlags;
pub const CompressionMethod = format.CompressionMethod;
pub const Version = format.Version;
pub const Os = format.Os;

test {
    std.testing.refAllDecls(@This());
    _ = @import("format.zig");
    _ = @import("records/root.zig");
    _ = @import("Entry.zig");
    _ = @import("Archive.zig");
    _ = @import("tests/archive.zig");
    _ = @import("tests/interop.zig");
    _ = @import("CountingWriter.zig");
    _ = @import("HashingWriter.zig");
    _ = @import("Writer.zig");
    _ = @import("tests/writer.zig");
    _ = @import("tests/builder.zig");
    _ = @import("tests/extract.zig");
    _ = @import("tests/path.zig");
    _ = @import("tests/read_entry.zig");
    _ = @import("tests/entry.zig");
    _ = @import("tests/extra.zig");
    _ = @import("tests/sweep.zig");
    _ = @import("tests/fuzz_writer.zig");
    _ = @import("tests/fuzz_read.zig");
    _ = @import("tests/source.zig");
    _ = @import("tests/source_parity.zig");
}
