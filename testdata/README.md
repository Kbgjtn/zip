# Test fixtures

Archives the reader tests open from disk. The writer tests don't use these files.
They build their archives in memory or in a temp dir.

- `edge/`: valid archives with unusual features. The reader must read them correctly.
- `hostile/`: broken or malicious archives. The reader must reject them with an
  error. It must not crash, hang, or report success.
- `accessible_epub_3.epub`: one real-world archive.

## Regenerating

`empty.zip`, `os_unknown.zip`, `empty_deflated.zip` and everything in `hostile/` come from
`scripts/gen-testdata.py`. Run it from the repo root:

    python3 scripts/gen-testdata.py

It uses fixed bytes and timestamps, so the output should match what's committed.
Only a change in zlib's deflate output could change the deflate fixtures.

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

## accessible_epub_3.epub

This is *Accessible EPUB 3* by Matt Garrish (O'Reilly Media, 2012, ISBN
9781449328030). The package metadata says "Copyright © 2012 O'Reilly Media, Inc".
The file is byte-for-byte the copy from the IDPF EPUB 3 samples
(<https://github.com/IDPF/epub3-samples>), release `20230704`. That project
licenses its samples under [CC BY-SA 3.0](https://creativecommons.org/licenses/by-sa/3.0/)
unless its sample table says otherwise, and this one has no exception.

It's about 4 MB, with 38 files. It's the only large fixture and makes up most of
`testdata/`.
