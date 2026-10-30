// A ZIP file is correctly identified by the presence of an EOCDR (`End of Central Directory
// Record`) which is located at the end of the archive structure in order to allow the easy
// appending of new files.
//
// If the EOCDR record indicates a non empty archive, the name of each file or directory of
// within the archive should be specified in a EOCDR entry, along with other metdata about
// the entry, and an offset into the ZIP file, pointing to the actual entry data.
//
// ZIP file format uses 32-bit CRC algorithm for archiving purpose. In order to render the
// compressed files, a ZIP archive holds a directory at its end that keeps the entry of the
// contained files and their location in the archive file. It, thus, plays the role of encoding
// for encapsulation information necessary to render the compressed files. ZIP readers use the
// directory to load the list of files without reading the entire ZIP archive. The format keeps
// dual copies of the directory structure to provide greater protection against loss of data.
//
// references:
// [APPNOTE.TXT - .ZIP File Format Specification](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)

const std = @import("std");
const log = std.log.scoped(.zip);

const format = @import("format.zig");
pub const records = @import("records/root.zig");

pub const time = @import("time.zig");
pub const extra = @import("extra.zig");
pub const errors = @import("errors.zig");
pub const path = @import("path.zig");

pub const Entry = @import("Entry.zig");
pub const Archive = @import("Archive.zig");
pub const Source = @import("source.zig").Source;
pub const Writer = @import("Writer.zig");

pub const GeneralPurposeFlags = format.GeneralPurposeFlags;
pub const CompressionMethod = format.CompressionMethod;
pub const HeaderId = format.HeaderId;

test {
    std.testing.refAllDecls(@This());
    _ = @import("format.zig");
    _ = @import("records/root.zig");
    _ = @import("Entry.zig");
    _ = @import("Archive.zig");
    _ = @import("tests/archive.zig");
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
    _ = @import("tests/source.zig");
    _ = @import("tests/source_parity.zig");
}
