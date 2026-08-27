//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const zip = @import("zip.zig");
pub const extra = @import("extra.zig");

test {
    std.testing.refAllDecls(@This());
}
