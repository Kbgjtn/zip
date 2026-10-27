#!/usr/bin/env python3
"""Generate the small generated fixtures in testdata/.

Valid-but-unusual archives go to testdata/edge/, broken or malicious ones to
testdata/hostile/. See testdata/README.md for what each file is.

Run from the project root:  python3 scripts/gen-hostile.py

Every file is built from fixed bytes (fixed timestamps, no randomness), so
running it again gives the same output. The deflate data comes from zlib at
level 6; zlib's output has been stable for years, but if a fixture ever
changes after a zlib upgrade, that is why.
"""
import io
import os
import struct
import zipfile
import zlib

TESTDATA = os.path.join(os.path.dirname(__file__), "..", "testdata")
EDGE = os.path.join(TESTDATA, "edge")
HOSTILE = os.path.join(TESTDATA, "hostile")
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


if __name__ == "__main__":
    main()
