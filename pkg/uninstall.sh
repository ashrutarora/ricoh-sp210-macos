#!/bin/sh
# Removes the Ricoh SP 210SU driver: the printer, the scanner service and all their files.
# Installed as /Library/Printers/RicohSP210/uninstall.sh; run it as root (the Uninstall app does).
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
. "$(dirname "$0")/common.sh"

stop_scanner_service
remove_old_scanner_service
rm -f "$AGENT"

# Every print queue that uses this driver (or the --docker fallback), whatever its name.
for q in $(lpstat -v 2>/dev/null | awk '{ sub(/:$/, "", $3); print $3 }'); do
  if grep -qE "rastertoricohsp210|rastertolilo-docker" "/etc/cups/ppd/$q.ppd" 2>/dev/null; then
    lpadmin -x "$q" && echo "Removed the printer $q."
  fi
done

rm -f "$PPD" "/Library/Printers/PPDs/Contents/Resources/Ricoh SP 210 series.ppd.gz"
rm -rf "/Applications/Utilities/Uninstall Ricoh SP 210SU.app"
pkgutil --forget io.github.ashrutarora.ricoh-sp210 >/dev/null 2>&1
rm -rf "$DEST"
echo "The Ricoh SP 210SU driver is removed."
