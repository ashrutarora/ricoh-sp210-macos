#!/bin/sh
# Regression tests for malformed rasters: the filter must refuse them, never overrun memory.
# Builds an AddressSanitizer copy of the filter.
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
cd "$(dirname "$0")/../.."
J=third_party/jbigkit
mkdir -p out
cupsfilter -p native/ricoh-sp210.ppd -m application/vnd.cups-raster -o PageSize=A4 test/testpage.pdf \
  > out/security-base.ras 2>/dev/null || { echo "cupsfilter failed"; exit 1; }
cc -g -O1 -fsanitize=address -DJBG_KEEP_TRAILING_ZEROS=1 -Wno-deprecated-declarations -I$J \
  -o out/rastertoricohsp210-asan native/rastertoricohsp210.c $J/jbig.c $J/jbig_ar.c -lcups || exit 1
fail=0
t() { # name fields...
  name=$1; shift
  python3 -I test/security/make_bad_raster.py out/security-base.ras out/bad-$name.ras "$@"
  ASAN_OPTIONS=abort_on_error=0 ./out/rastertoricohsp210-asan 1 u t 1 "" out/bad-$name.ras \
    > /dev/null 2> out/bad-$name.err
  rc=$?
  if grep -q AddressSanitizer out/bad-$name.err; then
    echo "FAIL $name: memory error"; grep -m1 'ERROR: AddressSanitizer' out/bad-$name.err; fail=1
  elif [ $rc -eq 1 ] && grep -q 'ERROR: Unsupported raster' out/bad-$name.err; then
    echo "ok   $name: $(grep -m1 ERROR out/bad-$name.err)"
  else
    echo "FAIL $name: exit $rc, $(grep -m1 ERROR out/bad-$name.err)"; fail=1
  fi
}
t bytes-per-line-too-big cupsBytesPerLine=100000
t width-wraps            cupsWidth=0xffffff80 cupsBytesPerLine=4758
t width-over-16bit       cupsWidth=70000 cupsBytesPerLine=70000
t height-over-16bit      cupsHeight=70000
t zero-width             cupsWidth=0 cupsBytesPerLine=0
t resolution-300         HWResolution0=300 HWResolution1=300
exit $fail
