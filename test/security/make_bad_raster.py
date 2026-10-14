"""make_bad_raster.py good.ras out.ras field=value ...: copy a CUPS raster v3 page header with fields patched.

Fields are byte offsets into the 1796-byte page header (after the 4-byte sync word), e.g.
cupsWidth=372, cupsHeight=376, cupsBytesPerLine=392. The rest of the file is copied unchanged.

SPDX-License-Identifier: GPL-2.0-or-later
"""
import struct
import sys

OFF = {"HWResolution0": 276, "HWResolution1": 280, "cupsWidth": 372, "cupsHeight": 376,
       "cupsBytesPerLine": 392}
d = bytearray(open(sys.argv[1], "rb").read())
for arg in sys.argv[3:]:
    k, v = arg.split("=")
    struct.pack_into("<I", d, 4 + OFF[k], int(v, 0))
open(sys.argv[2], "wb").write(d)
