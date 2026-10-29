//! Every error the reader returns, grouped by what went wrong.
//!
//! Groups:
//! - `FormatError`: the archive's structure is broken or inconsistent.
//! - `UnsupportedError`: the archive is valid, but uses a feature this library refuses.
//! - `IntegrityError`: an entry's data doesn't match what its headers promise.
//! - `LimitError`: the archive is over a safety limit.
//! - `ExtractError`: refused by `Entry.extract`. Replaced by path errors in M14.
//! - `IoError`: errors from the file or reader underneath, passed through unchanged.
//!
//! Each public reader function returns one of the composed sets at the bottom
//! (`OpenError`, `IterError`, `EntryError`), so the compiler lists exactly what a caller
//! can see.
//!
//! Passthrough rule: errors from the file itself (`ReadFailed`, seek and stat errors) and
//! from the caller's writer (`WriteFailed`) pass through unchanged. Running out of bytes in
//! the middle of a record is a fact about the archive, not the file, so it is
//! `ZipTruncated`, never `EndOfStream`.
//!
//! Error names in Zig are global: `error.ZipTruncated` is the same value in every set that
//! lists it. So each name here has one meaning, wherever it is returned. Sets only decide
//! which names a function may return.
//!
//! To handle a whole category, switch on its names:
//!
//! ```zig
//! while (try it.next()) |entry| {
//!     _ = it.streamEntry(&entry, &out.writer) catch |err| switch (err) {
//!         // UnsupportedError: skip what we can't read, keep going.
//!         error.ZipEncrypted,
//!         error.ZipCentralDirectoryEncrypted,
//!         error.ZipPatchedData,
//!         error.ZipUnsupportedMethod,
//!         => continue,
//!         else => |e| return e,
//!     };
//! }
//! ```
//!
//! APPNOTE sections are from PKWARE's APPNOTE.TXT.

const std = @import("std");

/// The archive's structure is broken or its records disagree.
pub const FormatError = error{
    /// No end of central directory record (APPNOTE 4.3.16) whose comment ends exactly at
    /// the end of the file, or the file is shorter than 22 bytes.
    ZipNoEndRecord,
    /// A record or field runs past the end of the file, or a deflate stream ends before
    /// its final block.
    ZipTruncated,
    /// A local (4.3.7) or central (4.3.12) header doesn't start with its signature.
    ZipBadSignature,
    /// A count, offset or length points outside where it must be: the end of central
    /// directory comment doesn't end at the end of the file, the central directory lies
    /// outside the file, or a central header runs past the central directory.
    ZipMalformed,
    /// An extra field (4.5.1) runs past the end of its block, a known field has the wrong
    /// length or version, or a ZIP64 field (4.5.3) is missing when a header escapes a value.
    ZipBadExtraField,
    /// The ZIP64 end record (4.3.14) or its locator (4.3.15) is missing, has a bad
    /// signature, a size below 44, or doesn't fit where it claims to be.
    Zip64Malformed,
    /// The end record (4.3.16, or 4.3.14 for ZIP64) promises more entries than fit in the
    /// central directory: the walk reaches its end first.
    ZipCentralDirectoryMismatch,
    /// The local header (4.3.7) disagrees with the central header (4.3.12) on name,
    /// method, bit 3, CRC-32 or sizes. The central directory is the source of truth.
    ZipLocalHeaderMismatch,
    /// With bit 3 set, the data descriptor (4.3.9) doesn't carry the central CRC-32 and sizes.
    ZipBadDataDescriptor,
};

/// The archive may be valid, but it uses something this library refuses to read.
/// Listing still works; reading the entry fails.
pub const UnsupportedError = error{
    /// Bit 0 or bit 6 of the general purpose flags: the entry is encrypted (4.4.4).
    ZipEncrypted,
    /// Bit 13 of the general purpose flags: values in the local header are masked
    /// because the central directory is encrypted (4.4.4).
    ZipCentralDirectoryEncrypted,
    /// Bit 5 of the general purpose flags: compressed patched data (4.4.4).
    ZipPatchedData,
    /// A disk number other than 0, or more than one disk (4.4.13, 4.4.19, 4.4.20, 4.3.15).
    ZipMultiDisk,
    /// A compression method other than 0 (stored) or 8 (deflate) (4.4.5).
    ZipUnsupportedMethod,
};

/// An entry's data doesn't match its headers.
pub const IntegrityError = error{
    /// The CRC-32 of the data read differs from the central one (4.4.7).
    ZipCrcMismatch,
    /// The data has more or fewer bytes than the central sizes say (4.4.8, 4.4.9), bytes
    /// are left after a complete deflate stream, or a stored entry's two sizes differ.
    ZipSizeMismatch,
    /// The deflate data is corrupt: the inflater can't decode it (4.4.5, method 8).
    ZipBadDeflate,
};

/// The archive is over a safety limit.
pub const LimitError = error{
    /// The end record claims more entries than the reader will walk.
    ZipTooManyEntries,
    /// The entry is larger than the size the caller allowed.
    ZipEntryTooLarge,
};

/// Refused by `Entry.extract`. Both are replaced by the path errors in M14.
pub const ExtractError = error{
    /// The name is empty, starts with '/', or has a ".." segment.
    ZipBadFileName,
    /// A directory entry (name ending in '/') has a nonzero size.
    ZipBadDirectorySize,
};

/// Errors from the file underneath, passed through unchanged.
pub const IoError = std.Io.File.Reader.SizeError || std.Io.File.Reader.SeekError || error{ReadFailed};

/// Maps running out of bytes while reading a record of the archive to `ZipTruncated`.
/// `ReadFailed` from the file underneath passes through.
pub fn truncated(err: std.Io.Reader.Error) error{ ZipTruncated, ReadFailed } {
    return switch (err) {
        error.EndOfStream => error.ZipTruncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// `Archive.open`: finding and checking the end records.
pub const OpenError = FormatError || UnsupportedError || LimitError || IoError;
/// `Archive.next`: walking the central directory and cross-checking each local header.
pub const IterError = FormatError || UnsupportedError || LimitError || IoError;
/// `Archive.streamEntry`: reading one entry's data into the caller's writer.
pub const EntryError = FormatError || UnsupportedError || IntegrityError || LimitError || IoError || std.Io.Writer.Error;
