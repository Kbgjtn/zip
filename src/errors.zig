//! Every error the reader returns, grouped by what went wrong.
//!
//! Groups:
//! - `FormatError`: the archive's structure is broken or inconsistent.
//! - `UnsupportedError`: the archive is valid, but uses a feature this library refuses.
//! - `IntegrityError`: an entry's data doesn't match what its headers promise.
//! - `LimitError`: the archive is over a safety limit.
//! - `ExtractError`: refused by `Archive.extractEntry`. Replaced by path errors in M14.
//! - `IoError`: errors from the file or reader underneath, passed through unchanged.
//!
//! Each public reader function returns one of the sets at the bottom (`OpenError`,
//! `CommentError`, `IterError`, `EntryError`, `ReadAllocError`, `LayoutError`), so the
//! compiler lists what a caller can see. They are listed name by name, not built from the
//! groups above: each step reads different records, so each can fail in fewer ways than
//! whole groups would claim. Each set is exactly what its function can return, so a
//! caller's `switch` never needs a branch for an error that can't happen.
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
    /// the end of the file (or before it, with `OpenOptions.strict_trailing_bytes = false`),
    /// or the file is shorter than 22 bytes.
    ZipNoEndRecord,
    /// A record or field runs past the end of the file, or a deflate stream ends before
    /// its final block.
    ZipTruncated,
    /// A local (4.3.7) or central (4.3.12) header doesn't start with its signature.
    ZipBadSignature,
    /// A count, offset or length points outside where it must be: the end of central
    /// directory comment doesn't end at the end of the file, the central directory lies
    /// outside the file, a central header runs past the central directory, or an entry's
    /// data runs into the central directory or past the end of the file (4.3.6).
    ZipMalformed,
    /// An extra field (4.5.1) runs past the end of its block, a known field has the wrong
    /// length or version, or a ZIP64 field (4.5.3) is missing when a header escapes a value.
    ZipBadExtraField,
    /// The ZIP64 end record (4.3.14) or its locator (4.3.15) is missing, has a bad
    /// signature, a size below 44, or doesn't fit where it claims to be.
    Zip64Malformed,
    /// The end records and the central directory describe different archives: an EOCD
    /// field that isn't escaped differs from the ZIP64 end record (4.3.16, 4.3.14), or the
    /// entry count and the central directory size disagree, so the walk runs out of
    /// headers early or has headers left over once the count is reached (4.3.12).
    ZipCentralDirectoryMismatch,
    /// The local header (4.3.7) disagrees with the central header (4.3.12) on name,
    /// method, bit 3, CRC-32 or sizes. The central directory is the source of truth.
    ZipLocalHeaderMismatch,
    /// With bit 3 set, the data descriptor (4.3.9) doesn't carry the central CRC-32 and sizes.
    ZipBadDataDescriptor,
    /// Two entries share bytes: their local headers, data or data descriptors overlap
    /// (4.3.6), as in an overlap bomb where many central headers point at one stream.
    ZipOverlappingEntries,
    /// Two entries have the same name (4.4.17), so tools disagree on which one is the file.
    ZipDuplicateName,
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
/// Each limit is a field of `Archive.Limits`, set through `OpenOptions.limits`.
pub const LimitError = error{
    /// The end record counts more entries than `max_entries`.
    ZipTooManyEntries,
    /// The entry's central uncompressed size is over `max_entry_size`, or over the
    /// `max_size` given to `readEntryAlloc`.
    ZipEntryTooLarge,
    /// Reading the entry would take the decompressed bytes of all reads through the
    /// `Archive` past `max_total_size`.
    ZipTotalTooLarge,
    /// The entry's uncompressed size over its compressed size (4.4.8, 4.4.9) is above
    /// `max_ratio`, and the entry is larger than `ratio_grace`.
    ZipRatioExceeded,
};

/// Refused by `Archive.extractEntry`. Both are replaced by the path errors in M14.
pub const ExtractError = error{
    /// The name is empty, starts with '/', or has a ".." segment.
    ZipBadFileName,
    /// A directory entry (name ending in '/') has a nonzero size.
    ZipBadDirectorySize,
};

/// Errors from the file underneath, passed through unchanged. A seek that falls back to
/// reading and runs out of file is not one of them: `Source.readerAt` reports it as
/// `ZipTruncated`.
pub const IoError = std.Io.File.Reader.SizeError || std.Io.File.SeekError || error{ReadFailed};

/// Maps running out of bytes while reading a record of the archive to `ZipTruncated`.
/// `ReadFailed` from the file underneath passes through.
pub fn truncated(err: std.Io.Reader.Error) error{ ZipTruncated, ReadFailed } {
    return switch (err) {
        error.EndOfStream => error.ZipTruncated,
        error.ReadFailed => error.ReadFailed,
    };
}

/// `Archive.open`: finding and checking the end records (APPNOTE 4.3.14 to 4.3.16). Only
/// these end records are read, so no central or local header error can happen here.
/// `ZipCentralDirectoryMismatch` comes from the end records disagreeing with each other;
/// checking them against the central directory itself is left to `next`.
pub const OpenError = error{
    ZipNoEndRecord,
    ZipTruncated,
    ZipMalformed,
    Zip64Malformed,
    ZipMultiDisk,
    ZipTooManyEntries,
    ZipCentralDirectoryMismatch,
} || IoError;

/// `Archive.comment`: copying the archive comment (4.4.26) into the caller's buffer.
/// `open` already checked that the comment fits in the file, so `ZipTruncated` means the
/// file got shorter since.
pub const CommentError = error{
    /// The caller's buffer is shorter than the comment.
    InsufficientBufferSize,
    ZipTruncated,
} || std.Io.File.SeekError || error{ReadFailed};

/// `Archive.next`: one pass over the central directory (4.3.12). Local header problems and
/// refusals come later, from the read functions (`EntryError`). The archive size was
/// already read by `open`, so stat errors can't happen here.
pub const IterError = error{
    ZipTruncated,
    ZipBadSignature,
    ZipMalformed,
    ZipBadExtraField,
    ZipCentralDirectoryMismatch,
    ZipMultiDisk,
} || std.Io.File.SeekError || error{ReadFailed};

/// `Archive.streamEntry`: checking the entry against the limits and the local header (4.3.7)
/// against the central one, then reading one entry's data into the caller's writer. Disks
/// were already checked by `open` and `next`, so `ZipMultiDisk` can't happen here.
pub const EntryError = error{
    ZipTruncated,
    ZipBadSignature,
    ZipMalformed,
    ZipBadExtraField,
    ZipLocalHeaderMismatch,
    ZipBadDataDescriptor,
    ZipEncrypted,
    ZipCentralDirectoryEncrypted,
    ZipPatchedData,
    ZipUnsupportedMethod,
    ZipEntryTooLarge,
    ZipRatioExceeded,
    ZipTotalTooLarge,
} || IntegrityError || std.Io.File.SeekError || error{ReadFailed} || std.Io.Writer.Error;

/// `Archive.readEntryAlloc`: `EntryError`, where `ZipEntryTooLarge` also covers the
/// caller's `max_size`, plus running out of memory for the bytes.
pub const ReadAllocError = EntryError || std.mem.Allocator.Error;

/// `Archive.checkLayout`: a full pass over the central directory (`IterError`), each entry's
/// local header (4.3.7) and, under bit 3, its data descriptor (4.3.9), then the layout
/// checks themselves. Allocates for the names and byte ranges.
pub const LayoutError = error{
    ZipTruncated,
    ZipBadSignature,
    ZipMalformed,
    ZipBadExtraField,
    ZipCentralDirectoryMismatch,
    ZipMultiDisk,
    ZipOverlappingEntries,
    ZipDuplicateName,
    ZipTotalTooLarge,
} || std.Io.File.SeekError || error{ReadFailed} || std.mem.Allocator.Error;
