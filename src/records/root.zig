//! Wire-format records of a ZIP archive, laid out byte for byte (APPNOTE 4.3).
//! One import for all of them, so callers write `records.LocalHeader`.
pub const LocalHeader = @import("local_file_header.zig").LocalHeader;
pub const CentralHeader = @import("central_directory.zig").CentralHeader;
pub const DigitalSignature = @import("central_directory.zig").DigitalSignature;
pub const EndRecord = @import("eocd.zig").EndRecord;
pub const EndRecord64 = @import("eocd64.zig").EndRecord64;
pub const EndRecord64Locator = @import("eocd64.zig").EndRecord64Locator;
pub const DataDescriptor = @import("data_descriptor.zig").DataDescriptor;

test {
    _ = @import("local_file_header.zig");
    _ = @import("central_directory.zig");
    _ = @import("eocd.zig");
    _ = @import("eocd64.zig");
    _ = @import("data_descriptor.zig");
}
