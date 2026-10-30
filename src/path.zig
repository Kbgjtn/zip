//! Turns an entry name into a safe relative path before anything touches the disk.
//!
//! APPNOTE 4.4.17.1: the name "MUST NOT contain a drive or device letter, or a leading
//! slash. All slashes MUST be forward slashes '/'". A name that breaks those rules, or
//! that climbs out with "..", is how zip slip writes outside the destination, so such
//! names are refused, never repaired.
const std = @import("std");
const builtin = @import("builtin");

const PathError = @import("errors.zig").PathError;

pub const SanitizeOptions = struct {
    /// Treat '\' as '/' instead of refusing it with `ZipBackslashInPath`. For archives
    /// made by old Windows tools that broke 4.4.17.1.
    allow_backslashes: bool = false,
    /// Also refuse what Windows can't create or would read as something else: ':'
    /// anywhere (drives, alternate data streams), the reserved device names, and
    /// segments ending in '.' or ' ', which Windows silently trims.
    windows_rules: bool = builtin.os.tag == .windows,
    /// The name must be UTF-8: bit 11 is set (4.4.4, Appendix D). Pass
    /// `entry.nameIsUtf8()`. Without bit 11 the name is CP437 and its bytes pass through.
    utf8: bool,
};

/// Cleans `name` into `buffer` and returns the cleaned path, a slice of `buffer`.
/// Never touches the filesystem.
///
/// Empty and "." segments are dropped, so "./a//b" gives "a/b". A trailing '/' is kept,
/// since it is what marks a directory entry (4.4.17.1).
///
/// Refused on:
/// - `ZipBackslashInPath`: a '\' when `allow_backslashes` is off.
/// - `ZipUnsafePath`: an empty name, a NUL, control byte (below 0x20) or DEL, a leading
///   separator, a ".." segment, a drive prefix like "C:" as the first segment, nothing
///   left after cleaning, or a segment that `windows_rules` refuses.
/// - `ZipInvalidUtf8Name`: `utf8` is set and the name isn't valid UTF-8.
/// - `ZipNameTooLong`: the cleaned path is longer than `buffer`. To extract, pass a buffer
///   of `std.Io.Dir.max_path_bytes`, the longest path the OS takes.
///
/// Cleaning twice gives the same result, so a name is clean exactly when `sanitize`
/// returns it unchanged.
pub fn sanitize(name: []const u8, buffer: []u8, opts: SanitizeOptions) PathError![]const u8 {
    if (name.len == 0) return error.ZipUnsafePath;

    // One pass over the bytes for everything that doesn't depend on segments.
    const has_non_ascii = try scanBytes(name, opts.allow_backslashes);
    if (opts.utf8 and has_non_ascii and !std.unicode.utf8ValidateSlice(name))
        return error.ZipInvalidUtf8Name;

    // A leading separator is an absolute path (or "//server/share").
    if (isSeparator(name[0], opts.allow_backslashes)) return error.ZipUnsafePath;

    const limit = buffer.len;
    var written: usize = 0;
    var start: usize = 0;
    while (start < name.len) {
        const end = nextSeparator(name, start, opts.allow_backslashes);
        const segment = name[start..end];
        start = end + 1;

        if (segment.len == 0) continue;
        if (segment[0] == '.') {
            if (segment.len == 1) continue;
            if (segment.len == 2 and segment[1] == '.') return error.ZipUnsafePath;
        }

        // Checked on the first segment written, not on name[0]: "./C:/x" cleans to "C:/x".
        if (written == 0 and isDrivePrefix(segment)) return error.ZipUnsafePath;
        if (opts.windows_rules and windowsSegmentIsUnsafe(segment)) return error.ZipUnsafePath;

        const sep_len = @intFromBool(written != 0);
        if (written + sep_len + segment.len > limit) return error.ZipNameTooLong;
        if (sep_len != 0) buffer[written] = '/';
        written += sep_len;
        @memcpy(buffer[written..][0..segment.len], segment);
        written += segment.len;
    }

    if (written == 0) return error.ZipUnsafePath;
    if (isSeparator(name[name.len - 1], opts.allow_backslashes)) {
        if (written >= limit) return error.ZipNameTooLong;
        buffer[written] = '/';
        written += 1;
    }
    return buffer[0..written];
}

fn isSeparator(b: u8, allow_backslashes: bool) bool {
    return b == '/' or (allow_backslashes and b == '\\');
}

/// Index of the next separator at or after `start`, or `name.len`.
fn nextSeparator(name: []const u8, start: usize, allow_backslashes: bool) usize {
    // `findScalarPos` is vectorized; the two-byte search isn't, so take it only when needed.
    if (!allow_backslashes) return std.mem.findScalarPos(u8, name, start, '/') orelse name.len;
    return std.mem.findAnyPos(u8, name, start, "/\\") orelse name.len;
}

/// Refuses NUL, control bytes, DEL, and '\' unless allowed, and reports whether any byte
/// is 0x80 or above, so plain ASCII names skip UTF-8 validation. Checks a vector at a
/// time, then the tail byte by byte.
fn scanBytes(name: []const u8, allow_backslashes: bool) PathError!bool {
    var non_ascii = false;
    var i: usize = 0;
    if (std.simd.suggestVectorLength(u8)) |n| {
        const V = @Vector(n, u8);
        const space: V = @splat(0x20);
        const del: V = @splat(0x7F);
        const backslash: V = @splat('\\');
        const high: V = @splat(0x80);
        while (i + n <= name.len) : (i += n) {
            const v: V = name[i..][0..n].*;
            if (@reduce(.Or, v < space) or @reduce(.Or, v == del)) return error.ZipUnsafePath;
            if (!allow_backslashes and @reduce(.Or, v == backslash)) return error.ZipBackslashInPath;
            non_ascii = non_ascii or @reduce(.Or, v >= high);
        }
    }
    for (name[i..]) |b| {
        if (b < 0x20 or b == 0x7F) return error.ZipUnsafePath;
        if (b == '\\' and !allow_backslashes) return error.ZipBackslashInPath;
        non_ascii = non_ascii or b >= 0x80;
    }
    return non_ascii;
}

/// Reports whether `segment` starts with a drive letter, as in "C:" or "c:x"
/// (APPNOTE 4.4.17.1). On Windows each of these leaves the current folder.
pub fn isDrivePrefix(segment: []const u8) bool {
    return segment.len >= 2 and std.ascii.isAlphabetic(segment[0]) and segment[1] == ':';
}

fn windowsSegmentIsUnsafe(segment: []const u8) bool {
    const last = segment[segment.len - 1];
    if (last == '.' or last == ' ') return true;
    if (std.mem.findScalar(u8, segment, ':') != null) return true;
    return isReservedName(segment);
}

/// CON, PRN, AUX, NUL, COM1 to COM9 and LPT1 to LPT9, in any case and with any
/// extension ("con.txt", "Aux.tar.gz"): Windows opens the device instead of a file.
///
/// The stem is read as one little-endian integer with 0x20 ORed into every byte, which
/// lowercases ASCII letters. Only control bytes could collide with a letter that way, and
/// `scanBytes` has already refused those. Digits already have 0x20 set, so they are
/// unchanged.
fn isReservedName(segment: []const u8) bool {
    const stem = segment[0 .. std.mem.findScalar(u8, segment, '.') orelse segment.len];
    switch (stem.len) {
        3 => {
            const w = std.mem.readInt(u24, stem[0..3], .little) | 0x202020;
            return w == tag24("con") or w == tag24("prn") or w == tag24("aux") or w == tag24("nul");
        },
        4 => {
            if (stem[3] < '1' or stem[3] > '9') return false;
            const w = std.mem.readInt(u24, stem[0..3], .little) | 0x202020;
            return w == tag24("com") or w == tag24("lpt");
        },
        else => return false,
    }
}

fn tag24(comptime s: *const [3]u8) u24 {
    return comptime std.mem.readInt(u24, s, .little);
}
