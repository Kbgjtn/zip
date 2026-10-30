# Test fixtures

Archives the reader tests open from disk. The writer tests don't use these files.
They build their archives in memory or in a temp dir.

- `edge/`: valid archives with unusual features. The reader must read them correctly.
- `hostile/`: broken or malicious archives. The reader must reject them with an
  error. It must not crash, hang, or report success.
- `interop/`: small archives made by other tools (Info-ZIP `zip`, 7-Zip, Python's
  `zipfile`). The reader must open each one, pass `checkLayout`, and read every entry
  back with the bytes it was made from.
- `accessible_epub_3.epub`: one real-world archive.

## Regenerating

`empty.zip`, `os_unknown.zip`, `empty_deflated.zip`, `metadata.zip` and everything in `hostile/` come from
`scripts/gen-testdata.py`. Run it from the repo root:

    python3 scripts/gen-testdata.py

or, through the build:

    zig build gen-testdata

It uses fixed bytes and timestamps, so the output should match what's committed.
Only a change in zlib's deflate output could change the deflate fixtures.

Everything in `interop/` comes from the same script, which runs the tools itself. A tool
that isn't installed is skipped, and its committed fixtures are left alone. Another
version of `zip` or `7z` than the ones below may write different bytes, so the script
warns when it finds one; the tests should still pass on its output.

The other four files in `edge/` can't be regenerated. Their headers show they were
made with Info-ZIP `zip` 3.0 on Unix, but the commands weren't recorded.

## edge/

| File | Contents | Origin |
|---|---|---|
| `as_zip64.zip` | `a.txt` (`hello\n`), stored. The local header sizes are 0xFFFFFFFF, and the real sizes are in the ZIP64 extra field. | Info-ZIP zip 3.0; command not recorded |
| `with_comment.zip` | `a.txt` (`hello\n`), stored, plus the archive comment `this is type comment text` | Info-ZIP zip 3.0; command not recorded |
| `with_data_descriptor.zip` | `a.txt` (`hello\n`), deflated, with flag bit 3 set. The sizes and CRC come after the data. | Info-ZIP zip 3.0; command not recorded |
| `with_flated.zip` | `ascii-1kb.txt`, 1024 bytes of `A` deflated to 11 bytes, with no data descriptor | Info-ZIP zip 3.0; command not recorded |
| `empty.zip` | No entries. It's just the 22-byte end record, the same as `zipfile.ZipFile(p, "w").close()`. | `gen-testdata.py` |
| `os_unknown.zip` | `os.txt`, stored. Its central header says "made by" OS 255, a value APPNOTE reserves. | `gen-testdata.py` |
| `empty_deflated.zip` | `empty.txt`, empty and deflated by Python's `zipfile`. The data is the 2-byte final block `03 00`. | `gen-testdata.py` |
| `metadata.zip` | Five entries made by Unix: `dir/` (040755), `dir/hello.txt` (100644, entry comment `greeting`), `dir/café.txt` (100600, UTF-8 name with bit 11), a CP437 name with a matching 0x7075 Unicode path `dir/naïve.txt`, and the symlink `link` (120777). Every entry has a 0x5455 mtime of 1600000000 (mtime only in the central header) and 0x7875 uid/gid 1000. The reader test checks it against `TZ=UTC zipinfo -v`. | `gen-testdata.py` |

## hostile/

All of these come from `gen-testdata.py`.

| File | What's wrong |
|---|---|
| `tiny.zip` | 10 bytes, shorter than an end record: just the signature and 6 zeros |
| `eocd_bad_comment_len.zip` | A valid archive whose end-record comment length (500) runs past the end of the file |
| `no_eocd_70k.zip` | 70,000 bytes of 0xAA with no end record, so the end-record scan has to give up |
| `deflate_short_output.zip` | The deflate stream is complete but inflates to 500 bytes, while the headers say 600 |
| `deflate_truncated.zip` | An 8192-byte entry whose deflate data is cut in half |
| `stored_bad_crc.zip` | A stored entry with one payload byte flipped. All sizes are right, so only the CRC check can catch it. |
| `deflate_bad_crc.zip` | A deflated entry with one byte flipped in the middle of the compressed data |
| `deflate_trailing_junk.zip` | A complete deflate stream followed by 4 junk bytes that the compressed size counts |
| `deflate_long_output.zip` | The deflate stream is complete but inflates to 500 bytes, while the headers say 400 |

## interop/

All of these come from `gen-testdata.py`, made on Linux with Info-ZIP Zip 3.0 (July
5th 2008), 7-Zip 23.01 (x64) and Python 3.12.3. The script writes the input files into a
temp dir with mtime 1600000000 (2020-09-13 12:26:40 UTC), modes 0644 and 0755, and runs
the tools there with `TZ=UTC`. `zip -X` leaves out the UT and ux extras, so the uid, gid
and run time don't get in. Unless the row says otherwise, the input is `hello.txt`
(`hello\n`), `lorem.txt` (`the quick brown fox jumps over the lazy dog\n` 20 times, 880
bytes), the empty `empty.txt`, the folder `sub/` and `sub/nested.txt` (`nested\n`).

| File | Command | What it exercises |
|---|---|---|
| `zip_fz.zip` | `zip -q -X -r -fz ../out.zip hello.txt lorem.txt empty.txt sub` | ZIP64 extras on every entry, even the folder, though nothing needs them. Version needed is 4.5 on the files. |
| `zip_symlink.zip` | `zip -q -X -y ../out.zip target.txt link`, where `link` is a symlink to `target.txt` (`pointed at\n`) | The symlink itself, stored with mode 0120777 and its target as the data, so `kind()` is `.symlink`. |
| `zip_pipe.zip` | `zip -q -X - -`, with `lorem.txt` on stdin and stdout read from a pipe | A deflated entry named `-`, with a ZIP64 local extra holding zero sizes and a 24-byte data descriptor, but no ZIP64 extra in the central header. zip records the stdin pipe's mode, 0o010600, so `kind()` is `.other`. zip stamps it with the time of the run, so the script sets the DOS time and date in both headers to 2020-01-01 00:00. |
| `python_stream.zip` | `zipfile.ZipFile(stream, "w")` on a stream with no `tell` or `seek`, entries written with `ZipFile.open(info, "w")` | Flag bit 3 and a data descriptor on every entry: `deflated.txt` and `empty.txt` deflated, `stored.txt` stored, and `zip64.txt` with `force_zip64=True`, which gets a ZIP64 local extra and a 24-byte descriptor. DOS time 2020-01-01 00:00. |
| `7z.zip` | `7z a -tzip -bd -bso0 -mx=5 -mmt=1 -mtc=off -mta=off ../out.zip hello.txt lorem.txt empty.txt sub` | 7-Zip's own writer: entries sorted by name, and a 32-byte NTFS extra (0x000a) with the times on every entry. |

The reader tests are in `src/tests/interop.zig`. The other direction, our writer's
output checked by these tools, is `zig build interop` (`tools/interop.zig`), which needs no
fixtures.

## accessible_epub_3.epub

This is *Accessible EPUB 3* by Matt Garrish (O'Reilly Media, 2012, ISBN
9781449328030). The package metadata says "Copyright © 2012 O'Reilly Media, Inc".
The file is byte-for-byte the copy from the IDPF EPUB 3 samples
(<https://github.com/IDPF/epub3-samples>), release `20230704`. That project
licenses its samples under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/)
unless its sample table says otherwise, and this one has no exception.

It's about 4 MB, with 38 files. It's the only large fixture and makes up most of
`testdata/`.
