"""gdicompare.py ricoh.bin mine.bin: compare two jobs chunk by chunk; bands by BIH, bitmap and bytes.
SPDX-License-Identifier: GPL-2.0-or-later
"""
import subprocess
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from gdidump import walk  # noqa: E402


def dec(pl):
    i = pl.rfind(b"\xff\x02")
    r = subprocess.run(["jbigtopnm"], input=pl[: i + 2], capture_output=True)
    return r.stdout.split(b"\n", 2)[2] if r.returncode == 0 else None


a = list(walk(open(sys.argv[1], "rb").read()))
b = list(walk(open(sys.argv[2], "rb").read()))
print("chunks", len(a), len(b))
n = bad = 0
for (_, ta, ha, pa), (_, tb, hb, pb) in zip(a, b):
    if ta != b"GDIB":
        print(ta.decode(errors="replace"), "same" if ha == hb else "DIFF\n  " + ha.hex() + "\n  " + hb.hex())
        continue
    if ha != hb or pa != pb:
        bad += 1
        if bad <= 5:
            da, db = dec(pa), dec(pb)
            first = next((i for i, (x, y) in enumerate(zip(pa, pb)) if x != y), None)
            print(f"band {n}: hdr same={ha == hb} sizes {len(pa)}/{len(pb)} bitmap same={da == db} "
                  f"first byte diff at {first}")
    n += 1
print(f"{n} bands, {bad} differ")
