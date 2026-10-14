# Ricoh SP 210 series print stream

Worked out by studying Ricoh's Linux filter `rastertolilo` (SP-210211-series 0.03) with Ghidra, for
interoperability, and checked byte for byte against it (`tools/verify.sh`). All integers are big-endian.

```
GDIJ  job header      0x78 bytes
GJET  job extension   0xa8 bytes
per page:
  GDIP  page header   0x40 bytes
  GDIB  band          0x20-byte header + JBIG payload      (one per 256 rows)
JIDG  end of job      4 bytes          ("GDIC CANCEL     " before it when a job is cancelled)
```

## GDIJ (0x78)

| off  | size | value |
|------|------|-------|
| 0x00 | 4 | `GDIJ` |
| 0x04 | 4 | 0x78 |
| 0x08 | 2 | 100 |
| 0x0a | 2 | NumCopies from the raster header |
| 0x0c | 1 | toner save (0/1) |
| 0x0d | 1 | edge smoothing (0/1; the PPD has no option) |
| 0x10 | 2 | 8 if Collate, else 0 (duplex models: 0x200 or 0x208) |
| 0x12 | 2 | 0xa8 (size of GJET) |
| 0x20 | 2 | 0x100 |
| 0x22 | 2 | 2 |
| 0x38 | ..0x78 | job title (CUPS argv[3]), not terminated if it fills the field |

## GJET (0xa8)

`GJET`, 0xa8, then zeros.

## GDIP (0x40)

| off  | size | value |
|------|------|-------|
| 0x00 | 4 | `GDIP` |
| 0x04 | 4 | 0x40 |
| 0x08 | 1 | paper size code (A4 9, Letter 1, Legal 5, A5 11, ...; table in the C source), 0xff custom size, 0xfe unknown |
| 0x09 | 1 | input tray (Auto 0, Manual 1, Tray1 2, ...) |
| 0x0a | 1 | media type (PlainRecycled 0, Thin 13, Thick 12, ...) |
| 0x0b | 1 | output tray, 0 |
| 0x0c | 2 | aligned width in pixels: cupsWidth rounded up to 8, then to 128 |
| 0x0e | 2 | height in rows (cupsHeight) |
| 0x10 | 4x2 | top margin in pixels, four times: (PageSize[1] - ImagingBoundingBox[3]) * dpi / 72 |
| 0x18 | 4x2 | left margin in pixels, four times: ImagingBoundingBox[0] * dpi / 72 |
| 0x20 | 1 | 1 |
| 0x21 | 1 | 1 simplex (duplex: 5 or 13; \|0x20 for an inserted blank page) |
| 0x22 | 2 | page number from 1 |
| 0x36 | 2 | number of bands |
| 0x38 | 4 | paper width in micrometres, (float)(PageSize[0] / 72 * 25.4 * 1000), truncated |
| 0x3c | 4 | paper height in micrometres, same |

## GDIB (0x20 + payload)

| off  | size | value |
|------|------|-------|
| 0x00 | 4 | `GDIB` |
| 0x04 | 4 | flags: 1 first band of page, 2 last band (3 if both) |
| 0x08 | 4 | payload length |
| 0x18 | 2 | aligned width |
| 0x1a | 2 | rows in this band (256, or the remainder for the last band) |

Payload: one JBIG1 (T.82) BIE: 20-byte BIH (1 plane, XD = aligned width, YD = rows, L0 = 256, MX = MY = 0,
order 0x03 = ILEAVE|SMID, options 0x40 = LRLTWO only), one stripe, ending `FF 02`. The encoder keeps the 0x00
bytes the arithmetic coder wrote before its final flush (jbigkit trims them; patched under
`JBG_KEEP_TRAILING_ZEROS`). Then zero padding so (length - 20) is a multiple of 32.

## Image

1. Each 8-bit grey raster line (0 white, 255 black) is copied to the left of an aligned-width line; the rest
   is 0. Toner save halves each value.
2. Ordered dither with a 24x24 pattern per grey level: pixel (x, y) is black when bit (7 - x % 8) of
   `pattern[g][y % 24][(x / 8) % 3]` is set. 1 = black, most significant bit leftmost.
3. The printer does not care which patterns are used. This driver uses its own clustered-dot screen
   (`tools/make_dither.py`). A `make RICOH_DITHER=1` build instead uses Ricoh's table, extracted from your own
   copy of their filter, with two Ricoh details that only matter for identical output: grey goes through
   `trunc((g / 255.0) * 255.0)` in x87 arithmetic (one lower for 144 levels) with 255 mapped to 254, and each
   band's dither row phase starts at `band * rows_in_this_band`, so the shorter last band is offset.
