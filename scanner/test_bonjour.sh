#!/bin/sh
# Regression test: the Bonjour announcement must be local to this Mac. Announced on the network
# interfaces, a resolve can answer on Wi-Fi first; macOS's AirScan helper then ties its connection
# to Wi-Fi, connecting to 127.0.0.1 fails with "Can't assign requested address", and Image Capture
# shows -9921 / "Waiting for scanner". Other computers on the network would also list a scanner
# that points at themselves.
# Runs against the installed service.
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
NAME="${RICOH_SCANNER_NAME:-Ricoh SP 210SU}"
OUT=$(mktemp -t ricoh-bonjour)
/usr/bin/dns-sd -L "$NAME" _uscan._tcp local > "$OUT" 2>&1 &
pid=$!
sleep 2
kill "$pid"; wait "$pid" 2>/dev/null
answers=$(grep -o 'can be reached at .*(interface [-0-9]*)' "$OUT" | sed 's/.*(interface \([-0-9]*\))/\1/' | sort -u)
rm -f "$OUT"
if [ -z "$answers" ]; then
  echo "FAIL \"$NAME\" is not announced"; exit 1
elif [ "$answers" = "-1" ]; then
  echo "ok   announced on this Mac only (interface -1)"
else
  echo "FAIL announced on interfaces: $(echo $answers), want only -1 (local only)"; exit 1
fi
