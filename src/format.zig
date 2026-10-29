/// General purpose bit flag with size 2-bytes.
/// Bit 00: encrypted file
/// Bit 01: compression option
/// Bit 02: compression option
/// Bit 03: data descriptor
/// Bit 04: enhanced deflation
/// Bit 05: compressed patched data
/// Bit 06: strong encryption
/// Bit 07-10: unused
/// Bit 11: language encoding
/// Bit 12: reserved
/// Bit 13: mask header values
/// Bit 14-15: reserved
pub const GeneralPurposeFlags = packed struct(u16) {
    encrypted: bool, // bit 0
    compression_option1: bool, // bit 1
    compression_option2: bool, // bit 2
    data_descriptor: bool, // bit 3
    enhanced_deflation: bool, // bit 4
    compressed_patched_data: bool, // bit 5
    strong_encryption: bool, // bit 6
    _unused1: u4, // bits 7-10
    language_encoding: bool, // bit 11
    _reserved1: bool, // bit 12
    mask_header_values: bool, // bit 13
    _reserved2: u2, // bits 14-15
};

/// Compression method
/// 00: no compression
/// 01: shrunk
/// 02: reduced with compression factor 1
/// 03: reduced with compression factor 2
/// 04: reduced with compression factor 3
/// 05: reduced with compression factor 4
/// 06: imploded
/// 07: reserved
/// 08: deflated
/// 09: enhanced deflated
/// 10: PKWare DCL imploded
/// 11: reserved
/// 12: compressed using BZIP2
/// 13: reserved
/// 14: LZMA
/// 15-17: reserved
/// 18: compressed using IBM TERSE
/// 19: IBM LZ77 z
/// 98: PPMd version I, Rev 1
pub const CompressionMethod = enum(u16) {
    stored = 0x0,
    deflate = 0x8,
    _,
};

pub const OS = enum(u8) {
    /// MS-DOS and OS/2 (FAT|VFAT|FAT32 file systems)
    ms_dos_and_os2 = 0,
    amiga = 1,
    open_vms = 2,
    unix = 3,
    vm_cms = 4,
    atari_st = 5,
    os2_hpfs = 6,
    macintosh = 7,
    z_system = 8,
    cp_m = 9,
    windows_ntfs = 10,
    /// MVS (OS/390|Z/OS)
    mvs = 11,
    vse = 12,
    acorn_risc = 13,
    vfat = 14,
    alternate_mvs = 15,
    be_os = 16,
    tandem = 17,
    /// OS/400
    os400 = 18,
    osx_darwin = 19,

    /// 20..255 reserved by APPNOTE; real archives still use them, so keep the raw value.
    _,
};

pub const Version = packed struct(u16) {
    spec_version: u8, // lower byte
    os: OS, // upper byte
};

// simple ZIP Layout
// [file entries...]
// [Central Directory...]
// [EOCD]
// The classic EOCD Record uses 16-bit and 32-bit fields.
// `u16` for record counts and `u32` for central directory
// size and offset. The limits is max entries only up to (65_535),
// max central directory size 4 GiB, and max offset 4 GiB.
//
// When any of those values exceed those limits, the specs says:
// `Set the field to 0xFFFF or 0xFFFFFFFF and create the ZIP64
// EOCD record.` The reader then takes the real values from the ZIP64 end record, found
// through its locator (APPNOTE 4.3.14, 4.3.15; see `Archive.open`).

/// Extensible Data Fields are documented in PKWARE's appnote.txt and are intended to allow for
/// backward/forward compatible extensions to the zipfile format. Multiple extra-field data is
/// less than 64KB. (In fact, PKWARE requires that the total length of the entire file header,
/// including timestamp, file attributes, file name, comment, extra field, etc., be no more than
/// 64KB). Each extra-field type must contain a four-byte header consisting of a two-byte Header ID
/// and a two-byte length in least significant order byte (little-endian) for the remaining data
/// in the subblock. If there are extra additional subblocks within the extra field, the header for
/// each one will appear immediately following the data for the previous subblock (i.e., with no
/// padding or alignment).
///
/// All integer fields in the description below are in little-endian format unless otherwise
/// specified. Note that "Short" means two bytes, "Long" means four bytes, and "Long-Long" means
/// eight bytes, regardless of their native sizes. Unless specifically noted, all integer fields
/// should be interpreted as unsigned (non-negative) numbers.
///
/// references:
/// [4.5 Extensible Data Fields](https://pkwaredownloads.blob.core.windows.net/pem/APPNOTE.txt)
/// [Extra Fields](https://libzip.org/specifications/extrafld.txt)
pub const HeaderId = enum(u16) {
    // The current Header ID mappings defined by PKWARE are:
    /// Zip64 extended information extra field
    zip64_extended_extra_field = 0x0001,
    /// AV Info
    av_info = 0x0007,
    /// https://en.wikipedia.org/wiki/OS/2
    os2_extended_attributes = 0x0009, // also Info-ZIP
    /// Win9x/WinNT FileTimes
    ntfs = 0x000a,
    /// OpenVMS
    open_vms = 0x000c, // also Info-ZIP
    /// Unix
    unix = 0x000d,
    /// Patch Descriptor
    patch_descriptor = 0x000f,
    /// PKCS#7 Store for X.509 Certificates
    pkcs7_certs = 0x0014,
    /// X.509 Certificate ID and Signature for individual file
    x509_certificate_id_and_signature = 0x0015,
    // X.509 Certificate ID for Central Directory
    x509_certificate_id_for_central_directory = 0x0016,
    // The Header ID mappings defined by Info-ZIP and third parties are:
    /// IBM S/390 attributes - uncompressed
    ibm_s390_attributes_uncompressed = 0x0065,
    /// IBM S/390 attributes - compressed
    ibm_s390_attributes_compressed = 0x0066,
    /// Info-ZIP Macintosh (old, J. Lee)
    info_zip_macintosh = 0x07c8,
    /// ZipIt Macintosh (first version)
    zipit_macintosh = 0x2605,
    /// 0x2705        ZipIt Macintosh v 1.3.5 and newer (w//o full filename)
    zipit_macintosh_v1_3_5 = 0x2705,
    /// Info-ZIP Macintosh (new, D. Haase's 'Mac3' field)
    info_zip_macintosh_mac3 = 0x334d,
    /// 0x4154        Tandem NSK
    tandem_nsk = 0x4154,
    /// 0x4341        Acorn//SparkFS (David Pilling)
    acorn_sparkfs = 0x4341,
    /// 0x4453        Windows NT security descriptor (binary ACL)
    windows_nt_security_descriptor = 0x4453,
    /// 0x4704        VM//CMS
    vm_cms = 0x4704,
    /// 0x470f        MVS
    mvs = 0x470f,
    /// 0x4854        Theos, old inofficial port
    theos_old = 0x4854,
    /// 0x4b46        FWKCS MD5 (see below)
    fwkcs_md5 = 0x4b46,
    /// 0x4c41        OS//2 access control list (text ACL)
    os2_acl = 0x4c41,
    /// 0x4d49        Info-ZIP OpenVMS (obsolete)
    info_zip_openvms_obsolete = 0x4d49,
    /// 0x4d63        Macintosh SmartZIP, by Macro Bambini
    macintosh_smartzip = 0x4d63,
    /// 0x4f4c        Xceed original location extra field
    xceed_original_location = 0x4f4c,
    /// 0x5356        AOS//VS (binary ACL)
    aos_vs = 0x5356,
    /// 0x5455        extended timestamp
    extended_timestamp = 0x5455,
    /// 0x5855        Info-ZIP Unix (original; also OS//2, NT, etc.)
    info_zip_unix = 0x5855,
    /// 0x554e        Xceed unicode extra field
    xceed_unicode_field = 0x554e,
    /// 0x6375        Info-ZIP Unicode Comment
    info_zip_unicode_comment = 0x6375,
    /// 0x6542        BeOS (BeBox, PowerMac, etc.)
    beos = 0x6542,
    /// 0x6854        Theos
    theos = 0x6854,
    /// 0x7075        Info-ZIP Unicode Path
    info_zip_unicode_path = 0x7075,
    /// 0x756e        ASi Unix
    asi_unix = 0x756e,
    /// 0x7855        Info-ZIP Unix (previous new)
    info_zip_unix_previous = 0x7855,
    /// 0x7875        Info-ZIP Unix (new)
    info_zip_unix_new = 0x7875,
    /// 0xfb4a        SMS//QDOS
    sms_qdos = 0xfb4a,
};
