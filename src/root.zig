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

pub const time = @import("time.zig");
pub const extra = @import("extra.zig");

const format = @import("format.zig");
pub const GeneralPurposeFlags = format.GeneralPurposeFlags;
pub const CompressionMethod = format.CompressionMethod;
pub const HeaderId = format.HeaderId;

pub const LocalFileHeader = @import("records/local_file_header.zig").LocalFileHeader;
pub const CentralDirectoryFileHeader = @import("records/central_directory.zig").CentralDirectoryFileHeader;
pub const DigitalSignature = @import("records/central_directory.zig").DigitalSignature;
pub const EndOfCentralDirectoryRecord = @import("records/eocd.zig").EndOfCentralDirectoryRecord;
pub const EndOfCentralDirectoryRecord64 = @import("records/eocd64.zig").EndOfCentralDirectoryRecord64;
pub const EndRecord64Locator = @import("records/eocd64.zig").EndRecord64Locator;
pub const DataDescriptor = @import("records/data_descriptor.zig").DataDescriptor;

pub const FileData = @import("entry.zig").FileData;
pub const Iterator = @import("iterator.zig").Iterator;
pub const Writer = @import("writer.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("format.zig");
    _ = @import("records/local_file_header.zig");
    _ = @import("records/central_directory.zig");
    _ = @import("records/eocd.zig");
    _ = @import("records/eocd64.zig");
    _ = @import("records/data_descriptor.zig");
    _ = @import("entry.zig");
    _ = @import("iterator.zig");
    _ = @import("tests/iterator.zig");
    _ = @import("counting_writer.zig");
    _ = @import("hashing_writer.zig");
    _ = @import("writer.zig");
    _ = @import("tests/writer.zig");
    _ = @import("tests/builder.zig");
    _ = @import("tests/extract.zig");
    _ = @import("tests/extra.zig");
    _ = @import("tests/sweep.zig");
    _ = @import("tests/fuzz_writer.zig");
}
