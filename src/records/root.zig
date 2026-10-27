//! Wire-format records of a ZIP archive, laid out byte for byte (APPNOTE 4.3).
//! One import for all of them, so callers write `records.LocalFileHeader`.
pub const LocalFileHeader = @import("local_file_header.zig").LocalFileHeader;
pub const CentralDirectoryFileHeader = @import("central_directory.zig").CentralDirectoryFileHeader;
pub const DigitalSignature = @import("central_directory.zig").DigitalSignature;
pub const EndOfCentralDirectoryRecord = @import("eocd.zig").EndOfCentralDirectoryRecord;
pub const EndOfCentralDirectoryRecord64 = @import("eocd64.zig").EndOfCentralDirectoryRecord64;
pub const EndRecord64Locator = @import("eocd64.zig").EndRecord64Locator;
pub const DataDescriptor = @import("data_descriptor.zig").DataDescriptor;

test {
    _ = @import("local_file_header.zig");
    _ = @import("central_directory.zig");
    _ = @import("eocd.zig");
    _ = @import("eocd64.zig");
    _ = @import("data_descriptor.zig");
}
