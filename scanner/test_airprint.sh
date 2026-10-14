#!/bin/sh
# Test: the scanner service announces a Ricoh print queue to iPhones and iPads (AirPrint) exactly
# while the queue is shared, and stops when it is not. Runs against the installed service with a
# temporary queue that uses this driver (it points at a printer that does not exist, so nothing
# can print to it). Needs Printer Sharing on in System Settings > General > Sharing.
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
Q=RicohAirPrintTest
PPD="/Library/Printers/PPDs/Contents/Resources/Ricoh SP 210 series.ppd"
fail=0

if ! cupsctl | grep -q '^_share_printers=1'; then
  echo "skip: Printer Sharing is off (System Settings > General > Sharing)"; exit 0
fi
lpadmin -p "$Q" -E -v "usb://RICOH/SP%20210SU?serial=TEST000000" -P "$PPD" -D "Ricoh AirPrint Test" \
  -o printer-is-shared=false 2>/dev/null || { echo "FAIL could not add the test queue"; exit 1; }
trap 'lpadmin -x "$Q" 2>/dev/null' EXIT

# The names announced as AirPrint printers (the _universal subtype iPhones browse for).
airprint() {
  out=$(mktemp -t ricoh-airprint)
  /usr/bin/dns-sd -B _ipp._tcp,_universal local > "$out" 2>&1 &
  pid=$!
  sleep 3
  kill "$pid"; wait "$pid" 2>/dev/null
  awk '$2 == "Add" { $1 = $2 = $3 = $4 = $5 = $6 = ""; sub(/^ +/, ""); print }' "$out" | sort -u
  rm -f "$out"
}
# Waits up to 40 s (the service looks every 15 s) until the announcement is there or gone.
wait_for() { # present|absent
  i=0
  while [ $i -lt 8 ]; do
    names=$(airprint | grep "Ricoh AirPrint Test")
    [ "$1" = present ] && [ -n "$names" ] && return 0
    [ "$1" = absent ] && [ -z "$names" ] && return 0
    i=$((i + 1)); sleep 2
  done
  return 1
}

if wait_for absent; then echo "ok   not announced while the queue is not shared"
else echo "FAIL announced although the queue is not shared"; fail=1; fi

lpadmin -p "$Q" -o printer-is-shared=true 2>/dev/null
if wait_for present; then
  echo "ok   announced to iPhones once the queue is shared"
  name=$(airprint | grep "Ricoh AirPrint Test" | head -1)
  txt=$(mktemp -t ricoh-airprint-txt)
  /usr/bin/dns-sd -L "$name" _ipp._tcp local > "$txt" 2>&1 &
  pid=$!; sleep 3; kill "$pid"; wait "$pid" 2>/dev/null
  for want in "rp=printers/$Q" "URF=" "pdl=application/pdf" ":631"; do
    if grep -q "$want" "$txt"; then echo "ok   announcement has $want"
    else echo "FAIL announcement lacks $want"; fail=1; fi
  done
  rm -f "$txt"
else
  echo "FAIL not announced to iPhones after sharing the queue"; fail=1
fi

lpadmin -p "$Q" -o printer-is-shared=false 2>/dev/null
if wait_for absent; then echo "ok   announcement gone once the queue is no longer shared"
else echo "FAIL still announced after sharing was turned off"; fail=1; fi
exit $fail
