#!/bin/sh
# verify.sh: render test PDFs with macOS CUPS, run Ricoh's own filter (in the fallback
# container) and a RICOH_DITHER build of ours on the same raster, and require byte-identical
# output. Needs your own copy of Ricoh's filter at vendor/rastertolilo and Docker Desktop.
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
cd "$(dirname "$0")/.."
PPD=native/ricoh-sp210.ppd
OURS=native/rastertoricohsp210-ricoh
mkdir -p out/verify

[ -f vendor/rastertolilo ] || { echo "vendor/rastertolilo missing; see README"; exit 1; }
make -s -C native RICOH_DITHER=1 || exit 1
if ! curl -fsS --max-time 5 http://127.0.0.1:9210/health >/dev/null 2>&1; then
  echo "Starting the converter container..."
  docker build -q --platform linux/386 -t ricoh-sp210-filter -f docker/Dockerfile . >/dev/null || exit 1
  docker rm -f ricoh-sp210 >/dev/null 2>&1
  docker run -d --name ricoh-sp210 --platform linux/386 -p 127.0.0.1:9210:9210 ricoh-sp210-filter >/dev/null || exit 1
  until curl -fsS http://127.0.0.1:9210/health >/dev/null 2>&1; do sleep 1; done
fi
fail=0

check() { # name pdf "cups options"
  name=$1 pdf=$2 opts=$3
  ras=out/verify/$name.ras
  if ! cupsfilter -p "$PPD" -m application/vnd.cups-raster -o "$opts" "$pdf" > "$ras" 2>/dev/null; then
    echo "FAIL $name: cupsfilter"; fail=1; return
  fi
  ./mac/rastertolilo-docker 1 me job 1 "$opts" "$ras" > out/verify/$name.ricoh 2>/dev/null; a=$?
  ./$OURS 1 me job1 1 "$opts" "$ras" > out/verify/$name.ours 2>/dev/null; b=$?
  if [ $a -ne 0 ] || [ $b -ne 0 ] || ! [ -s out/verify/$name.ricoh ] || ! [ -s out/verify/$name.ours ]; then
    echo "FAIL $name: Ricoh's filter exit $a, ours exit $b (empty output counts as failure)"; fail=1
  elif cmp -s out/verify/$name.ricoh out/verify/$name.ours; then
    echo "ok   $name ($(wc -c < out/verify/$name.ours | tr -d ' ') bytes)"
  else
    echo "FAIL $name"; fail=1
    python3 -I tools/gdicompare.py out/verify/$name.ricoh out/verify/$name.ours | sed 's/^/     /'
  fi
}

check a4-testpage   test/testpage.pdf  "PageSize=A4"
check letter-test   test/testpage.pdf  "PageSize=Letter"
check a4-multipage  test/multipage.pdf "PageSize=A4"
check legal-multi   test/multipage.pdf "PageSize=Legal"
check a5-multi      test/multipage.pdf "PageSize=A5"
check custom-size   test/testpage.pdf  "PageSize=Custom.400x600"
check tonersave     test/multipage.pdf "PageSize=A4 TonerSave=True"
check thick-bypass  test/testpage.pdf  "PageSize=A4 MediaType=Thick InputSlot=Manual"
check copies2       test/testpage.pdf  "PageSize=A4 copies=2"
exit $fail
