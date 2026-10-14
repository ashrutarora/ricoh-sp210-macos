#!/bin/sh
# Installs the Ricoh SP 210SU scanner service for the current user: macOS apps (Image Capture,
# Preview > Import from Scanner, Printers & Scanners) then list "Ricoh SP 210SU" as a scanner.
# Needs Homebrew's libusb (brew install libusb) and python3 (Xcode Command Line Tools).
#   ./install-scanner.sh            install or update, start now and at every login
#   ./install-scanner.sh --remove   stop and remove it
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")"

LABEL="io.github.ashrutarora.ricoh-sp210-scanner"
APP="$HOME/Library/Application Support/RicohSP210Scanner"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/RicohSP210Scanner.log"
PORT="${RICOH_SCANNER_PORT:-8090}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "Removed the scanner service."
  exit 0
fi

if ! [ -e /opt/homebrew/lib/libusb-1.0.dylib ] && ! [ -e /usr/local/lib/libusb-1.0.dylib ]; then
  echo "libusb is missing. Install it with:  brew install libusb" >&2
  exit 1
fi

echo "1/3 Setting up Python in $APP ..."
mkdir -p "$APP"
[ -x "$APP/venv/bin/python" ] || /usr/bin/python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install -q --disable-pip-version-check -r requirements.txt
cp ricoh_scanner.py escl_server.py "$APP/"

echo "2/3 Adding the login item..."
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/venv/bin/python</string>
    <string>-I</string>
    <string>$APP/escl_server.py</string>
    <string>--port</string>
    <string>$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

echo "3/3 Starting it..."
launchctl bootstrap "gui/$(id -u)" "$PLIST"
i=0
until curl -fsS "http://127.0.0.1:$PORT/eSCL/ScannerStatus" >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -gt 20 ] && { echo "The service did not start; see $LOG" >&2; exit 1; }
  sleep 0.5
done
echo "Done. \"Ricoh SP 210SU\" now appears in Image Capture and in Preview > File > Import from Scanner."
echo "Log: $LOG"
