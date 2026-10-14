"""gdidump.py job.bin [--bands DIR]: walk a Ricoh SP 210 job and print its chunks.

Working notes on the format (from rastertolilo output; all integers big-endian):
  GDIJ  job header,  length field = chunk size (0x78)
  GJET  job extra,   length field = chunk size (0xa8)
  GDIP  page header, length field = chunk size (0x40)
  GDIB  band: tag, flags (u32: 1 first band, 2 last), payload length (u32), 12 zero bytes,
        width (u16), rows (u16), 4 zero bytes; then payload = JBIG BIE (20-byte BIH + data)
With --bands DIR, each band's JBIG payload is written to DIR/bandNNNN.jbg.

SPDX-License-Identifier: GPL-2.0-or-later
"""
import os
import struct
import sys

FIXED = {b"GDIJ", b"GJET", b"GDIP"}


def walk(d):
    i = 0
    while i < len(d):
        tag = d[i:i + 4]
        if tag in FIXED:
            size = struct.unpack(">I", d[i + 4:i + 8])[0]
            yield i, tag, d[i:i + size], None
            i += size
        elif tag == b"GDIB":
            num, plen = struct.unpack(">II", d[i + 4:i + 12])
            hdr = d[i:i + 0x20]
            yield i, tag, hdr, d[i + 0x20:i + 0x20 + plen]
            i += 0x20 + plen
        else:
            yield i, b"????", d[i:i + 64], None
            return


def main():
    d = open(sys.argv[1], "rb").read()
    outdir = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--bands" else None
    if outdir:
        os.makedirs(outdir, exist_ok=True)
    nbands = 0
    for off, tag, hdr, payload in walk(d):
        if tag == b"GDIB":
            num = struct.unpack(">I", hdr[4:8])[0]
            w, rows = struct.unpack(">HH", hdr[0x18:0x1c])
            bih = payload[:20]
            xd, yd, l0 = struct.unpack(">III", bih[4:16])
            if nbands < 3 or os.environ.get("ALL"):
                print(f"{off:#08x} GDIB band={num} payload={len(payload)} w={w} rows={rows} "
                      f"BIH xd={xd} yd={yd} l0={l0} order={bih[18]:#x} options={bih[19]:#x} "
                      f"rest={hdr[8:].hex(' ')}")
            if outdir:
                open(os.path.join(outdir, f"band{nbands:04d}.jbg"), "wb").write(payload)
            nbands += 1
        else:
            if nbands > 3 and not os.environ.get("ALL"):
                print(f"           ... {nbands} bands total")
            print(f"{off:#08x} {tag.decode()} {len(hdr):#x} bytes: {hdr[8:].rstrip(bytes(1)).hex(' ')}")
            nbands = 0 if tag == b"GDIP" else nbands
    print(f"end at {len(d):#x}")


if __name__ == "__main__":
    main()
