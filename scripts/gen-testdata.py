#!/usr/bin/env python3
"""Generate the small generated fixtures in testdata/.

Valid-but-unusual archives go to testdata/edge/, broken or malicious ones to
testdata/hostile/, and archives made by other tools (Info-ZIP zip, 7-Zip, Python's
zipfile writing to a pipe) to testdata/interop/. See testdata/README.md for what each
file is.

Run from the project root:  python3 scripts/gen-testdata.py

Every file is built from fixed bytes (fixed timestamps, no randomness), so
running it again gives the same output. The deflate data comes from zlib at
level 6; zlib's output has been stable for years, but if a fixture ever
changes after a zlib upgrade, that is why.

The interop fixtures run `zip` and `7z` on files with fixed mtimes, under TZ=UTC, and
skip a tool that isn't installed. They were made with the versions in TOOL_VERSIONS;
another version may write different bytes, so the script warns when it finds one.
"""
import io
import os
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

TESTDATA = os.path.join(os.path.dirname(__file__), "..", "testdata")
EDGE = os.path.join(TESTDATA, "edge")
HOSTILE = os.path.join(TESTDATA, "hostile")
INTEROP = os.path.join(TESTDATA, "interop")
DOS_TIME = (0 << 11) | (0 << 5) | 0  # 00:00:00
DOS_DATE = ((2020 - 1980) << 9) | (1 << 5) | 1  # 2020-01-01


def write(out_dir, name, data):
    path = os.path.join(out_dir, name)
    with open(path, "wb") as f:
        f.write(data)
    print(f"{os.path.basename(out_dir) + '/' + name:40} {len(data):7} bytes")


def raw_deflate(data):
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    return c.compress(data) + c.flush()


def one_entry_zip(name, payload, method, crc, csize, usize):
    """Hand-build a single-entry archive (LFH + data + CDFH + EOCD).

    `payload` is written as-is; `csize`/`usize`/`crc` go into both headers,
    so they can lie about the payload.
    """
    fname = name.encode()
    lfh = struct.pack(
        "<IHHHHHIIIHH", 0x04034B50, 20, 0, method, DOS_TIME, DOS_DATE,
        crc, csize, usize, len(fname), 0,
    ) + fname
    cd_offset = len(lfh) + len(payload)
    cdfh = struct.pack(
        "<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, method, DOS_TIME, DOS_DATE,
        crc, csize, usize, len(fname), 0, 0, 0, 0, 0, 0,
    ) + fname
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, len(cdfh), cd_offset, 0)
    return lfh + payload + cdfh + eocd


# Fixed metadata for edge/metadata.zip: 2020-09-13 12:26:40 UTC, as Unix seconds for 0x5455
# and as the same wall-clock time in the DOS fields (APPNOTE 4.4.6).
META_MTIME = 1_600_000_000
META_ATIME = 1_600_000_100
META_DOS_TIME = (12 << 11) | (26 << 5) | (40 // 2)
META_DOS_DATE = ((2020 - 1980) << 9) | (9 << 5) | 13
META_UID = META_GID = 1000
MADE_BY_UNIX = (3 << 8) | 30  # Unix, spec 3.0 (APPNOTE 4.4.2)


def extra_field(header_id, data):
    return struct.pack("<HH", header_id, len(data)) + data


def metadata_zip():
    """Hand-build edge/metadata.zip: entries made by Unix with Info-ZIP style metadata.

    Laid out the way Info-ZIP's zip writes on Linux: the local 0x5455 has mtime and atime
    (flags 0x03), the central one mtime only with the same flags (extrafld.txt), and both
    headers carry 0x7875 with uid/gid 1000.
    """
    ut_local = extra_field(0x5455, struct.pack("<Bii", 0x03, META_MTIME, META_ATIME))
    ut_central = extra_field(0x5455, struct.pack("<Bi", 0x03, META_MTIME))
    ux = extra_field(0x7875, struct.pack("<BBIBI", 1, 4, META_UID, 4, META_GID))

    cp437_name = b"dir/na\x8bve.txt"  # 0x8B is CP437 for U+00EF, i with diaeresis
    up = extra_field(0x7075, struct.pack("<BI", 1, zlib.crc32(cp437_name)) + "dir/naïve.txt".encode())

    # name, data, st_mode, flags, extra for both headers, comment
    entries = [
        (b"dir/", b"", 0o040755, 0, b"", b""),
        (b"dir/hello.txt", b"hello\n", 0o100644, 0, b"", b"greeting"),
        ("dir/café.txt".encode(), b"bonjour\n", 0o100600, 1 << 11, b"", b""),
        (cp437_name, b"naive\n", 0o100644, 0, up, b""),
        (b"link", b"dir/hello.txt", 0o120777, 0, b"", b""),
    ]

    out = b""
    central = b""
    for name, data, mode, flags, extra, comment in entries:
        crc = zlib.crc32(data)
        attrs = (mode << 16) | (0x10 if name.endswith(b"/") else 0)
        local_extra = ut_local + ux + extra
        central_extra = ut_central + ux + extra
        offset = len(out)
        out += struct.pack(
            "<IHHHHHIIIHH", 0x04034B50, 10, flags, 0, META_DOS_TIME, META_DOS_DATE,
            crc, len(data), len(data), len(name), len(local_extra),
        ) + name + local_extra + data
        central += struct.pack(
            "<IHHHHHHIIIHHHHHII", 0x02014B50, MADE_BY_UNIX, 10, flags, 0,
            META_DOS_TIME, META_DOS_DATE, crc, len(data), len(data), len(name),
            len(central_extra), len(comment), 0, 0, attrs, offset,
        ) + name + central_extra + comment
    eocd = struct.pack(
        "<IHHHHIIH", 0x06054B50, 0, 0, len(entries), len(entries), len(central), len(out), 0,
    )
    return out + central + eocd


# The versions the committed interop fixtures came from, as the first line of
# `zip -v` and the banner line of `7z`.
TOOL_VERSIONS = {
    "zip": "This is Zip 3.0 (July 5th 2008), by Info-ZIP.",
    "7z": "7-Zip 23.01 (x64) : Copyright (c) 1999-2023 Igor Pavlov : 2023-06-20",
}
# 2020-09-13 12:26:40 UTC, the mtime of every file the tools are given.
INTEROP_MTIME = 1_600_000_000
LOREM = b"the quick brown fox jumps over the lazy dog\n" * 20
# The tree the zip and 7z fixtures archive, in archive order. A trailing / is a directory.
TREE = [
    ("hello.txt", b"hello\n"),
    ("lorem.txt", LOREM),
    ("empty.txt", b""),
    ("sub/", None),
    ("sub/nested.txt", b"nested\n"),
]
TOOL_ENV = dict(os.environ, TZ="UTC", LC_ALL="C")


def have_tool(tool):
    """True if `tool` is installed. Warns if it isn't the version in TOOL_VERSIONS."""
    if shutil.which(tool) is None:
        print(f"interop: {tool} not found, its fixtures were not regenerated")
        return False
    banner = subprocess.run(
        [tool, "-v"] if tool == "zip" else [tool], capture_output=True, text=True, env=TOOL_ENV,
    ).stdout
    if TOOL_VERSIONS[tool] not in banner:
        print(f"interop: warning: {tool} isn't {TOOL_VERSIONS[tool]!r}; its fixtures may differ")
    return True


def make_tree(root, tree):
    """Writes `tree` under `root` and sets every mtime, symlinks' own included, to INTEROP_MTIME."""
    for name, data in tree:
        path = os.path.join(root, name)
        if name.endswith("/"):
            os.makedirs(path, exist_ok=True)
        elif isinstance(data, str):  # a symlink to `data`
            os.symlink(data, path)
        else:
            with open(path, "wb") as f:
                f.write(data)
    # Fixed modes, so the umask doesn't reach the external attributes (APPNOTE 4.4.15).
    for name, data in tree:
        if not isinstance(data, str):
            os.chmod(os.path.join(root, name), 0o755 if name.endswith("/") else 0o644)
    # Deepest first, so writing a file doesn't bump its directory's mtime afterwards.
    for name, _ in sorted(tree, key=lambda t: -t[0].count("/")):
        os.utime(os.path.join(root, name), (INTEROP_MTIME, INTEROP_MTIME), follow_symlinks=False)


def run_tool(argv, cwd, stdin=None):
    try:
        return subprocess.run(argv, cwd=cwd, input=stdin, capture_output=True, check=True, env=TOOL_ENV).stdout
    except subprocess.CalledProcessError as e:
        print(f"interop: {' '.join(argv)} failed with {e.returncode}:\n{e.stderr.decode(errors='replace')}")
        raise


def top_level(tree):
    """The names directly under the tree root, folders without their trailing slash."""
    return [n.rstrip("/") for n, _ in tree if "/" not in n.rstrip("/")]


def tool_archive(tool_argv, out_name, tree):
    """Runs `tool_argv` (which writes out.zip) on `tree` in a temp dir and saves out.zip."""
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        os.mkdir(src)
        make_tree(src, tree)
        run_tool(tool_argv + ["../out.zip"] + top_level(tree), src)
        with open(os.path.join(tmp, "out.zip"), "rb") as f:
            write(INTEROP, out_name, f.read())


def set_dos_times(data):
    """Sets every local and central header's DOS time and date (APPNOTE 4.4.6) to
    DOS_TIME/DOS_DATE. Used where a tool stamps the time of the run."""
    data = bytearray(data)
    eocd = data.rindex(b"PK\x05\x06")
    count, _, cd_offset = struct.unpack_from("<HII", data, eocd + 10)
    pos = cd_offset
    for _ in range(count):
        assert data[pos:pos + 4] == b"PK\x01\x02"
        name_len, extra_len, comment_len = struct.unpack_from("<HHH", data, pos + 28)
        (local,) = struct.unpack_from("<I", data, pos + 42)
        assert data[local:local + 4] == b"PK\x03\x04"
        struct.pack_into("<HH", data, pos + 12, DOS_TIME, DOS_DATE)
        struct.pack_into("<HH", data, local + 10, DOS_TIME, DOS_DATE)
        pos += 46 + name_len + extra_len + comment_len
    return bytes(data)


class Unseekable:
    """A write-only stream with no tell() or seek(), like a pipe. zipfile then writes
    every entry with a data descriptor (APPNOTE 4.3.9), since it can't go back."""

    def __init__(self):
        self.buf = io.BytesIO()

    def write(self, b):
        return self.buf.write(b)

    def flush(self):
        pass


def python_stream_zip():
    out = Unseekable()
    entries = [
        ("deflated.txt", LOREM, zipfile.ZIP_DEFLATED, False),
        ("stored.txt", b"hello\n", zipfile.ZIP_STORED, False),
        ("empty.txt", b"", zipfile.ZIP_DEFLATED, False),
        ("zip64.txt", LOREM, zipfile.ZIP_DEFLATED, True),
    ]
    with zipfile.ZipFile(out, "w") as z:
        for name, data, method, force_zip64 in entries:
            info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            info.compress_type = method
            info.external_attr = 0o100644 << 16
            with z.open(info, "w", force_zip64=force_zip64) as f:
                f.write(data)
    return out.buf.getvalue()


def interop_fixtures():
    """testdata/interop/: archives made by other tools, for the reader to open."""
    os.makedirs(INTEROP, exist_ok=True)
    if have_tool("zip"):
        # 14. zip -fz: ZIP64 extras on every entry even though nothing needs them.
        tool_archive(["zip", "-q", "-X", "-r", "-fz"], "zip_fz.zip", TREE)
        # 15. zip -y: the symlink itself, not the file it points to.
        tool_archive(["zip", "-q", "-X", "-y"], "zip_symlink.zip",
                     [("target.txt", b"pointed at\n"), ("link", "target.txt")])
        # 16. zip - -: data from stdin, archive to stdout, both pipes. The entry is named
        #     "-", and zip stamps it with the current time, which is overwritten.
        with tempfile.TemporaryDirectory() as tmp:
            data = run_tool(["zip", "-q", "-X", "-", "-"], tmp, stdin=LOREM)
        write(INTEROP, "zip_pipe.zip", set_dos_times(data))
    # 17. zipfile writing to an unseekable stream, one entry with force_zip64.
    write(INTEROP, "python_stream.zip", python_stream_zip())
    if have_tool("7z"):
        # 18. 7z a -tzip: Deflate, mtime-only NTFS extra (0x000a).
        tool_archive(["7z", "a", "-tzip", "-bd", "-bso0", "-mx=5", "-mmt=1", "-mtc=off", "-mta=off"],
                     "7z.zip", TREE)


def main():
    os.makedirs(EDGE, exist_ok=True)
    os.makedirs(HOSTILE, exist_ok=True)

    # 1. Valid empty archive: just a 22-byte EOCD. Same as zipfile.ZipFile(p, "w").
    buf = io.BytesIO()
    zipfile.ZipFile(buf, "w").close()
    assert len(buf.getvalue()) == 22
    write(EDGE, "empty.zip", buf.getvalue())

    # 2. Smaller than an EOCD record (22 bytes): only a signature and a few zeros.
    write(HOSTILE, "tiny.zip", b"PK\x05\x06" + b"\x00" * 6)

    # 3. Valid one-entry archive whose EOCD comment_len (500) points past the end of the file.
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(zipfile.ZipInfo("a.txt", (2020, 1, 1, 0, 0, 0)), b"hello\n")
    data = bytearray(buf.getvalue())
    assert data[-22:-18] == b"PK\x05\x06"
    struct.pack_into("<H", data, len(data) - 2, 500)
    write(HOSTILE, "eocd_bad_comment_len.zip", bytes(data))

    # 4. Bigger than 22 + 65535 bytes with no EOCD anywhere: the EOCD scan has to try
    #    every comment length 0..65535 and then give up cleanly.
    write(HOSTILE, "no_eocd_70k.zip", b"\xAA" * 70_000)

    # 5. Deflate stream is complete, but the headers claim 100 more uncompressed bytes
    #    than it inflates to. A reader must report an error, not success.
    text = b"hello zip\n" * 50  # 500 bytes
    comp = raw_deflate(text)
    write(HOSTILE, "deflate_short_output.zip", one_entry_zip(
        "short.txt", comp, 8, zlib.crc32(text), len(comp), len(text) + 100,
    ))

    # 6. Deflate stream cut in half; headers keep the true uncompressed size and CRC,
    #    and compressed_size matches the bytes actually present.
    big = bytes((i * 7 + i // 13) & 0xFF for i in range(8192))
    comp = raw_deflate(big)
    cut = comp[: len(comp) // 2]
    write(HOSTILE, "deflate_truncated.zip", one_entry_zip(
        "cut.bin", cut, 8, zlib.crc32(big), len(cut), len(big),
    ))

    # 7. Stored entry with one payload byte flipped; headers keep the CRC of the
    #    original bytes. Sizes all match, so only a CRC-32 check can catch it.
    text = b"the quick brown fox jumps over the lazy dog\n" * 4
    bad = bytearray(text)
    bad[10] ^= 0x01
    write(HOSTILE, "stored_bad_crc.zip", one_entry_zip(
        "fox.txt", bytes(bad), 0, zlib.crc32(text), len(bad), len(text),
    ))

    # 8. Deflated entry with one byte flipped in the middle of the compressed data.
    #    Depending on where the flip lands the inflater either errors or produces
    #    wrong bytes; either way the reader must not report success.
    data = b"A" * 512 + bytes(range(256)) * 2
    comp = bytearray(raw_deflate(data))
    comp[len(comp) // 2] ^= 0x01
    write(HOSTILE, "deflate_bad_crc.zip", one_entry_zip(
        "flip.bin", bytes(comp), 8, zlib.crc32(data), len(comp), len(data),
    ))

    # 9. Valid stored entry whose central header says "made by" OS 255. APPNOTE
    #    reserves 20..255, but real tools write them; a reader must not crash on it.
    #    The OS is the high byte of version_made_by, at CDFH offset 5.
    text = b"made on an unknown OS\n"
    zf = bytearray(one_entry_zip(
        "os.txt", text, 0, zlib.crc32(text), len(text), len(text),
    ))
    cd_offset = 30 + len(b"os.txt") + len(text)
    zf[cd_offset + 5] = 255
    write(EDGE, "os_unknown.zip", bytes(zf))

    # 10. Valid empty file, deflated by zipfile: an empty deflate stream is still a
    #     2-byte final block (03 00), so compressed_size is 2 and uncompressed_size 0.
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr(zipfile.ZipInfo("empty.txt", (2020, 1, 1, 0, 0, 0)), b"",
                   compress_type=zipfile.ZIP_DEFLATED)
    write(EDGE, "empty_deflated.zip", buf.getvalue())

    # 11. Complete deflate stream followed by 4 junk bytes that compressed_size counts.
    text = b"hello zip\n" * 50
    comp = raw_deflate(text) + b"JUNK"
    write(HOSTILE, "deflate_trailing_junk.zip", one_entry_zip(
        "junk.txt", comp, 8, zlib.crc32(text), len(comp), len(text),
    ))

    # 12. Complete deflate stream that inflates to 500 bytes while the headers say 400.
    comp = raw_deflate(text)
    write(HOSTILE, "deflate_long_output.zip", one_entry_zip(
        "long.txt", comp, 8, zlib.crc32(text[:400]), len(comp), 400,
    ))

    # 13. Valid archive made by Unix with metadata in every form the reader decodes: a
    #     0o040755 directory, 0o100644 and 0o100600 files and a 0o120777 symlink, 0x5455
    #     (central: mtime only) and 0x7875 (uid/gid 1000) on each, a UTF-8 name with bit
    #     11, a CP437 name with a matching 0x7075 Unicode Path, and an entry comment.
    write(EDGE, "metadata.zip", metadata_zip())

    interop_fixtures()


if __name__ == "__main__":
    main()
