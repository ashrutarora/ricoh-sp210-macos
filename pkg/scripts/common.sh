# Shared by the installer scripts and the uninstaller. Runs as root.
# SPDX-License-Identifier: GPL-2.0-or-later
DEST=/Library/Printers/RicohSP210
PPD="/Library/Printers/PPDs/Contents/Resources/Ricoh SP 210 series.ppd"
LABEL=io.github.ashrutarora.ricoh-sp210-scanner
AGENT="/Library/LaunchAgents/$LABEL.plist"
QUEUE=Ricoh_SP210SU
QUEUE_NAME="Ricoh SP 210SU (macOS driver)"

# User ids with a desktop session (each has its own loginwindow).
gui_users() {
  ps -axo uid=,comm= | awk '$2 ~ /\/loginwindow$/ {print $1}' | sort -u
}

stop_scanner_service() {
  for uid in $(gui_users); do
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
  done
  return 0
}

# Version 1.0 installed the scanner per user from a Terminal script, with a Python copy. The files
# are removed as the home folder's owner, never as root: a home folder (or the world-writable
# /Users/Shared) could hold symbolic links that would make root delete something else.
remove_old_scanner_service() {
  for home in /Users/*; do
    uid=$(stat -f %u "$home") || continue
    [ "$uid" -ge 500 ] || continue
    old="$home/Library/LaunchAgents/$LABEL.plist"
    [ -f "$old" ] || continue
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
    sudo -u "#$uid" /bin/rm -f "$old"
    sudo -u "#$uid" /bin/rm -rf "$home/Library/Application Support/RicohSP210Scanner"
  done
  return 0
}

# The USB address of a connected SP 210 / 211, if any.
printer_uri() {
  lpinfo -v 2>/dev/null | awk '$2 ~ /^usb:\/\/RICOH\/SP%20(210|211)/ {print $2; exit}'
}

# Print queues on this USB address that do not use this driver.
other_queues() { # uri
  lpstat -v 2>/dev/null | awk -v u="$1" -v q="$QUEUE" '$NF == u { sub(/:$/, "", $3); if ($3 != q) print $3 }'
}
