#!/bin/sh
# Hardware test: the scanner service's USB code finds the SP 210SU's scanner interface and gets a
# status reply. Needs the printer connected and switched on. Uses the build in this folder, or the
# installed one with --installed.
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
BIN="$(dirname "$0")/ricoh-sp210-scanner"
[ "${1:-}" = --installed ] && BIN=/Library/Printers/RicohSP210/ricoh-sp210-scanner
out=$("$BIN" status 2>&1)
case "$out" in
  ready|busy*) echo "ok   scanner answers over USB: $out" ;;
  *) echo "FAIL scanner over USB: $out"; exit 1 ;;
esac
