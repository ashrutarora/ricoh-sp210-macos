# Ricoh SP 210SU scanner protocol

Worked out from Ricoh's Windows scanner driver (`RtScan64.dll` in "USB TWAIN/WIA Driver" 1.02) with Ghidra, for
interoperability, and tested on a real SP 210SU. Implemented in [scanner/Scanner.swift](scanner/Scanner.swift).

## USB

The device (05ca:044f) has two interfaces. Interface 0 is the printer (class 7). Interface 1 is the scanner
(class 255/255/255) with bulk endpoints 0x02 (out) and 0x82 (in). Ricoh's SANE backend `ricoh2`, for the
SP 100SU/111SU, speaks a different protocol and gets no reply here.

## Commands

A command is a 4-byte little-endian number written to 0x02. Replies and image data are read from 0x82.

| value | name in the Windows driver | what follows |
|---|---|---|
| 1 | GetStatus_B | read 8 bytes; byte 0 is 1 when ready |
| 2 | GetParameter_B | read the parameter block |
| 3 | SetParameter_B | write the 32-byte parameter block |
| 4 | StartScan_B | image data follows on 0x82 (the driver waits 500 ms before sending it) |
| 5 | StopScan_B | |
| 9 | (gamma) | 6-byte command: 9 then u16 0x0400; then 3 x 1024 bytes of tone curve (R, G, B) |
| 0x0c | SetCancelScan_B | |
| 0x0d | SetDriverClose_B | |
| 0x1e | SetFinish_B | |
| 0x24 | DrvRequestUnlockScanner | |
| 0x32 | ActiveScanner_B | wake |

A scan: status (1), wake (0x32), parameters (3 + block), tone curve (9 + 3 KB), start (4), read
`width x height x bytes-per-pixel` bytes, finish (0x1e), stop (5), driver close (0x0d), unlock (0x24). Without
the last two the printer's display stays on "Scanning (USB)..." after the scan. A status request sent after the parameters is
answered only when the scan is ready, ahead of the image data, so it is better not to send one.

## Parameter block (32 bytes, little-endian)

| off | size | value |
|---|---|---|
| 0x00 | 1 | source: 1 flatbed |
| 0x01 | 1 | 1 |
| 0x02 | 1 | mode: 0 line art, 1 grey, 2 colour |
| 0x04 | 2 | x resolution |
| 0x08 | 2 | y resolution |
| 0x0c | 4 | width in pixels (a multiple of 8) |
| 0x10 | 4 | height in lines |
| 0x14 | 2 | x offset in pixels |
| 0x18 | 2 | y offset in lines |
| 0x1c | 1 | bits per channel, 8 |
| 0x1e | 1 | 0 |

## Image

Rows of 8-bit grey, or RGB interleaved per pixel, top to bottom, no headers. Notes from testing:

- Hardware resolutions are 300, 600 and 1200 dpi; asked for less, the scanner scans at 300. 1200 dpi runs at
  about 30 s per square inch.
- The glass is 5092 pixels wide at 600 dpi (215.5 mm); the first ~10 pixels (at 300 dpi) of the top and left are
  the dark edge of the glass.
- The tone curve does not seem to be applied. Raw white paper reads about 195 in grey and about R 198, G 189,
  B 210 in colour, ink about 20; the driver here stretches those to 0..255 in software.
