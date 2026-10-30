//! `path.sanitize` table tests: every name either cleans to an exact relative path or fails
//! with an exact `PathError`. Rules are design section 11.1 and APPNOTE 4.4.17.1 ("MUST NOT
//! contain a drive or device letter, or a leading slash. All slashes MUST be forward
//! slashes").
//!
//! Options are always spelled out, so the table gives the same results on every host:
//! `windows_rules` defaults to the build target.
const std = @import("std");
const path = @import("../path.zig");
const errors = @import("../errors.zig");

const PathError = errors.PathError;
const max_path_bytes = std.Io.Dir.max_path_bytes;

const posix: path.SanitizeOptions = .{ .allow_backslashes = false, .windows_rules = false, .utf8 = false };
const backslashes: path.SanitizeOptions = .{ .allow_backslashes = true, .windows_rules = false, .utf8 = false };
const windows: path.SanitizeOptions = .{ .allow_backslashes = false, .windows_rules = true, .utf8 = false };
const utf8: path.SanitizeOptions = .{ .allow_backslashes = false, .windows_rules = false, .utf8 = true };

const Case = struct {
    name: []const u8,
    options: path.SanitizeOptions = posix,
    /// The cleaned name, or the error `sanitize` must return.
    want: PathError![]const u8,
};

const cases = [_]Case{
    // Plain names pass through unchanged.
    .{ .name = "hello.txt", .want = "hello.txt" },
    .{ .name = "a/b/c.txt", .want = "a/b/c.txt" },
    .{ .name = "dir/", .want = "dir/" },
    .{ .name = "a/b/", .want = "a/b/" },
    // Dots that aren't a whole "." or ".." segment are ordinary names.
    .{ .name = "...", .want = "..." },
    .{ .name = "a..b", .want = "a..b" },
    .{ .name = "..a/b..", .want = "..a/b.." },
    .{ .name = ".hidden", .want = ".hidden" },

    // Empty and "." segments are dropped; a trailing '/' (a directory) is kept.
    .{ .name = "a//b", .want = "a/b" },
    .{ .name = "./a", .want = "a" },
    .{ .name = "a/./b", .want = "a/b" },
    .{ .name = "a/.", .want = "a" },
    .{ .name = "d//", .want = "d/" },
    .{ .name = "././a/./", .want = "a/" },

    // Nothing left after cleaning.
    .{ .name = "", .want = error.ZipUnsafePath },
    .{ .name = ".", .want = error.ZipUnsafePath },
    .{ .name = "./", .want = error.ZipUnsafePath },
    .{ .name = "./././", .want = error.ZipUnsafePath },

    // Zip slip: any ".." segment is refused, never resolved.
    .{ .name = "..", .want = error.ZipUnsafePath },
    .{ .name = "../x", .want = error.ZipUnsafePath },
    .{ .name = "a/..", .want = error.ZipUnsafePath },
    .{ .name = "a/../b", .want = error.ZipUnsafePath },
    .{ .name = "a/../../x", .want = error.ZipUnsafePath },
    .{ .name = "./../x", .want = error.ZipUnsafePath },
    .{ .name = "a//../x", .want = error.ZipUnsafePath },

    // Absolute paths and drive prefixes (4.4.17.1), on every host.
    .{ .name = "/", .want = error.ZipUnsafePath },
    .{ .name = "/etc/passwd", .want = error.ZipUnsafePath },
    .{ .name = "//server/share/x", .want = error.ZipUnsafePath },
    .{ .name = "C:x", .want = error.ZipUnsafePath },
    .{ .name = "c:/x", .want = error.ZipUnsafePath },
    // The drive check runs on the cleaned name: stripping "./" must not leave "C:" first.
    .{ .name = "./C:/x", .want = error.ZipUnsafePath },
    .{ .name = ".//c:", .want = error.ZipUnsafePath },
    // Only a first segment can be a drive.
    .{ .name = "a/C:", .want = "a/C:" },

    // NUL, control bytes (below 0x20) and DEL (0x7F).
    .{ .name = "a\x00b", .want = error.ZipUnsafePath },
    .{ .name = "a\nb", .want = error.ZipUnsafePath },
    .{ .name = "\x1b[31mred", .want = error.ZipUnsafePath },
    .{ .name = "a\x1f", .want = error.ZipUnsafePath },
    .{ .name = "a\x7fb", .want = error.ZipUnsafePath },

    // Backslashes: refused by default. The backslash check comes before the others, so
    // "C:\x" and "a\..\x" report the backslash.
    .{ .name = "a\\b", .want = error.ZipBackslashInPath },
    .{ .name = "C:\\x", .want = error.ZipBackslashInPath },
    .{ .name = "a\\..\\x", .want = error.ZipBackslashInPath },
    // With allow_backslashes they become '/', then the usual rules apply.
    .{ .name = "a\\b", .options = backslashes, .want = "a/b" },
    .{ .name = "dir\\", .options = backslashes, .want = "dir/" },
    .{ .name = "a\\..\\x", .options = backslashes, .want = error.ZipUnsafePath },
    .{ .name = "C:\\x", .options = backslashes, .want = error.ZipUnsafePath },
    .{ .name = "\\\\server\\share", .options = backslashes, .want = error.ZipUnsafePath },

    // Without Windows rules, a ':' that isn't a drive prefix and device names are just names.
    .{ .name = "ab:c", .want = "ab:c" },
    .{ .name = "x/a:b", .want = "x/a:b" },
    .{ .name = "CON", .want = "CON" },
    .{ .name = "dir/nul.txt", .want = "dir/nul.txt" },
    .{ .name = "trailing.", .want = "trailing." },
    .{ .name = "trailing ", .want = "trailing " },

    // Windows rules: ':' anywhere, reserved device names in any case and with any
    // extension, and segments ending in '.' or ' '.
    .{ .name = "ab:c", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "file.txt:stream", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "CON", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "con.txt", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "dir/NUL", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "Aux.tar.gz", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "COM1", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "lpt9.log", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "PRN/x", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "trailing.", .options = windows, .want = error.ZipUnsafePath },
    .{ .name = "trailing /x", .options = windows, .want = error.ZipUnsafePath },
    // Only the exact names are reserved.
    .{ .name = "CONSOLE", .options = windows, .want = "CONSOLE" },
    .{ .name = "com10", .options = windows, .want = "com10" },
    .{ .name = "xcon.txt", .options = windows, .want = "xcon.txt" },
    .{ .name = "a/b.txt", .options = windows, .want = "a/b.txt" },

    // UTF-8: only checked when bit 11 is set (Appendix D). Without it the name is raw
    // bytes (CP437 by the spec) and passes through as is.
    .{ .name = "caf\xc3\xa9.txt", .options = utf8, .want = "caf\xc3\xa9.txt" },
    .{ .name = "\xe6\x97\xa5\xe6\x9c\xac/\xf0\x9f\x93\x81", .options = utf8, .want = "\xe6\x97\xa5\xe6\x9c\xac/\xf0\x9f\x93\x81" },
    .{ .name = "bad\xff.txt", .options = utf8, .want = error.ZipInvalidUtf8Name },
    .{ .name = "cut\xc3", .options = utf8, .want = error.ZipInvalidUtf8Name },
    // Overlong encoding of '/': must not sneak a separator past the split.
    .{ .name = "a\xc0\xafb", .options = utf8, .want = error.ZipInvalidUtf8Name },
    // UTF-16 surrogate half.
    .{ .name = "\xed\xa0\x80", .options = utf8, .want = error.ZipInvalidUtf8Name },
    .{ .name = "bad\xff.txt", .want = "bad\xff.txt" },
    .{ .name = "\x82\xa0", .want = "\x82\xa0" },
};

test "path: sanitize table" {
    var out: [max_path_bytes]u8 = undefined;
    for (cases, 0..) |case, i| {
        const got = path.sanitize(case.name, &out, case.options);
        if (case.want) |want| {
            const name = got catch |err| {
                std.debug.print("case {d} \"{f}\": want \"{f}\", got {t}\n", .{ i, std.zig.fmtString(case.name), std.zig.fmtString(want), err });
                return err;
            };
            std.testing.expectEqualStrings(want, name) catch |err| {
                std.debug.print("case {d} \"{f}\"\n", .{ i, std.zig.fmtString(case.name) });
                return err;
            };
        } else |want_err| {
            std.testing.expectError(want_err, got) catch |err| {
                std.debug.print("case {d} \"{f}\"\n", .{ i, std.zig.fmtString(case.name) });
                return err;
            };
        }
    }
}

test "path: sanitize output is already clean" {
    // Cleaning twice changes nothing. The writer relies on this: a name is valid to
    // write only when `sanitize` would return it unchanged.
    var out: [max_path_bytes]u8 = undefined;
    var again: [max_path_bytes]u8 = undefined;
    for (cases) |case| {
        const once = path.sanitize(case.name, &out, case.options) catch continue;
        try std.testing.expectEqualStrings(once, try path.sanitize(once, &again, case.options));
    }
}

test "path: names longer than max_path_bytes are ZipNameTooLong" {
    var out: [max_path_bytes]u8 = undefined;
    const long = "a" ** (max_path_bytes + 1);
    try std.testing.expectError(error.ZipNameTooLong, path.sanitize(long, &out, posix));
    // Under the limit once cleaned: the length is checked after dropping "./".
    const dotted = "./" ** max_path_bytes ++ "a";
    try std.testing.expectEqualStrings("a", try path.sanitize(dotted, &out, posix));
}

test "path: a buffer shorter than the cleaned name is ZipNameTooLong" {
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.ZipNameTooLong, path.sanitize("abcde", &small, posix));
    try std.testing.expectEqualStrings("abcd", try path.sanitize("abcd", &small, posix));
    // The input may be longer than the buffer if the cleaned name fits.
    try std.testing.expectEqualStrings("a/b", try path.sanitize("a//./b", &small, posix));
}
