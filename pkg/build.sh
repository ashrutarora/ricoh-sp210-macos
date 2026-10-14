#!/bin/sh
# Builds the installer, out/Ricoh-SP210-macOS-<version>.pkg, and with --dmg the disk image
# people download, out/Ricoh-SP210-macOS-<version>.dmg.
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
ID=io.github.ashrutarora.ricoh-sp210
B=out/pkg
PKG="out/Ricoh-SP210-macOS-$VERSION.pkg"

make -s -C native
make -s -C scanner

rm -rf "$B"
DEST="$B/root/Library/Printers/RicohSP210"
mkdir -p "$DEST" "$B/root/Library/Printers/PPDs/Contents/Resources" "$B/root/Library/LaunchAgents" \
  "$B/root/Applications/Utilities" "$B/scripts" "$B/resources"
install -m 755 native/rastertoricohsp210 scanner/ricoh-sp210-scanner pkg/uninstall.sh "$DEST/"
install -m 644 pkg/scripts/common.sh "$DEST/"
install -m 644 native/ricoh-sp210.ppd "$B/root/Library/Printers/PPDs/Contents/Resources/Ricoh SP 210 series.ppd"
install -m 644 pkg/io.github.ashrutarora.ricoh-sp210-scanner.plist "$B/root/Library/LaunchAgents/"
APP="$B/root/Applications/Utilities/Uninstall Ricoh SP 210SU.app"
osacompile -o "$APP" pkg/Uninstaller.applescript
plutil -replace CFBundleIdentifier -string "$ID.uninstall" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
codesign -s - -f "$APP"
xattr -cr "$B/root"
install -m 755 pkg/scripts/preinstall pkg/scripts/postinstall "$B/scripts/"
install -m 644 pkg/scripts/common.sh "$B/scripts/"
cp pkg/resources/*.html "$B/resources/"

# The Uninstall app must land in Applications > Utilities even if a copy exists elsewhere.
pkgbuild --analyze --root "$B/root" "$B/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$B/components.plist"
pkgbuild --quiet --root "$B/root" --component-plist "$B/components.plist" --scripts "$B/scripts" \
  --identifier "$ID" --version "$VERSION" --install-location / --ownership recommended "$B/component.pkg"

# pkgbuild also packs macOS's file labels (com.apple.provenance, which cannot be removed) as
# "._" entries. Rebuild the payload and scripts archives without them, owned by root:wheel.
cpio_gz() { # dir > archive
  (cd "$1" && bsdtar -c --format cpio --no-mac-metadata --no-xattrs --no-acls \
    --uid 0 --gid 0 --uname root --gname wheel -f - .) | gzip -9n
}
pkgutil --expand "$B/component.pkg" "$B/expanded"
C="$B/component"
mkdir "$C"
cp "$B/expanded/PackageInfo" "$C/"
cpio_gz "$B/root" > "$C/Payload"
cpio_gz "$B/scripts" > "$C/Scripts"
# The bill of materials, every entry owned by root:wheel (mkbom -i: path, mode, uid/gid, size, crc).
(cd "$B/root" && find . | while IFS= read -r f; do
  if [ -d "$f" ]; then
    printf '%s\t%s\t0/0\n' "$f" "$(stat -f %p "$f")"
  else
    printf '%s\t%s\t0/0\t%s\t%s\n' "$f" "$(stat -f %p "$f")" "$(stat -f %z "$f")" "$(cksum < "$f" | cut -d' ' -f1)"
  fi
done) > "$B/bom.txt"
mkbom -i "$B/bom.txt" "$C/Bom"
files=$(wc -l < "$B/bom.txt" | tr -d ' ')
sed -i '' "s/numberOfFiles=\"[0-9]*\"/numberOfFiles=\"$files\"/" "$C/PackageInfo"
(cd "$C" && xar --compression none -cf ../ricoh-sp210.pkg Bom PackageInfo Payload Scripts)
sed "s/\"VERSION\"/\"$VERSION\"/" pkg/Distribution.xml > "$B/Distribution.xml"
productbuild --quiet --distribution "$B/Distribution.xml" --resources "$B/resources" --package-path "$B" "$PKG"
echo "$PKG"

if [ "${1:-}" = --dmg ]; then
  pkg/make-dmg.sh "$PKG" "out/Ricoh-SP210-macOS-$VERSION.dmg"
fi
