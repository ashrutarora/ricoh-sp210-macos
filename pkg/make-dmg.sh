#!/bin/sh
# Packs the installer into the disk image people download, with the step-by-step background.
#   pkg/make-dmg.sh out/Ricoh-SP210-macOS-<version>.pkg out/Ricoh-SP210-macOS-<version>.dmg
# Uses dmgbuild (in a build-only virtualenv) so no Finder scripting is needed.
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")/.."
PKG=$1 DMG=$2
VENV=out/build-venv
if ! [ -x "$VENV/bin/dmgbuild" ]; then
  /usr/bin/python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q --disable-pip-version-check 'dmgbuild==1.6.5'
fi
mkdir -p out/pkg
swift pkg/make-background.swift out/pkg
tiffutil -cathidpicheck out/pkg/background.png out/pkg/background@2x.png -out out/pkg/background.tiff 2>/dev/null
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s pkg/dmg-settings.py -D pkg="$PKG" -D background=out/pkg/background.tiff \
  "Ricoh SP 210SU driver" "$DMG"
echo "$DMG"
