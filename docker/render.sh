#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# render [options]  < document.pdf  > job.bin
# Turns a PDF/PostScript document into CUPS raster with Ghostscript, then runs
# Ricoh's filter on it. Options use CUPS syntax, e.g. "PageSize=A4 TonerSave=False".
set -eu
OPTIONS="${1:-PageSize=A4}"
export PPD=/etc/ricoh/ricoh-sp210.ppd
TMP=$(mktemp -d)
cat > "$TMP/in"

gs -q -dSAFER -dBATCH -dNOPAUSE -dNOINTERPOLATE \
   -sDEVICE=cups -r600 -dcupsColorSpace=3 -dcupsBitsPerColor=8 \
   -sPAPERSIZE=a4 -dFIXEDMEDIA -dPDFFitPage \
   -sOutputFile="$TMP/raster" "$TMP/in" >&2

/usr/lib/cups/filter/rastertolilo 1 user job 1 "$OPTIONS" "$TMP/raster"
rm -rf "$TMP"
