"""raster2pgm.py in.ras out.pgm [scale] - first page of an uncompressed CUPS raster (v3) to a PGM preview.
SPDX-License-Identifier: GPL-2.0-or-later
"""
import struct, sys
data = open(sys.argv[1], "rb").read()
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 8
sync = data[:4]
end = "<" if sync == b"3SaR" else ">"
h = data[4:4 + 1796]
u = lambda off: struct.unpack(end + "I", h[off:off + 4])[0]
w, ht, bpc, bpp, bpl, order, cs, comp = (u(o) for o in (372, 376, 384, 388, 392, 396, 400, 404))
res = (u(256 + 20), u(256 + 24))
print(f"sync={sync} res={res} width={w} height={ht} bitsPerColor={bpc} bitsPerPixel={bpp} bytesPerLine={bpl} colorSpace={cs}")
px = data[4 + 1796:4 + 1796 + bpl * ht]
ink = sum(1 for i in range(0, len(px), 97) if px[i] > 128) / (len(px) // 97)
print(f"pixels={len(px)} expected={bpl*ht} sampled ink fraction (byte>128)={ink:.4f}")
ow, oh = w // scale, ht // scale
out = bytearray()
for y in range(oh):
    row = px[y * scale * bpl:(y * scale + 1) * bpl]
    for x in range(ow):
        v = row[x * scale] if bpp == 8 else 0
        out.append(255 - v if cs == 3 else v)
open(sys.argv[2], "wb").write(b"P5 %d %d 255\n" % (ow, oh) + bytes(out))
