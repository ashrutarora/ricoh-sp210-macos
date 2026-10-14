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
# "._" entries, so the payload and scripts archives are rebuilt here. Every entry gets an explicit
# owner and mode; folders that already exist on every Mac get exactly the owner and mode they have
# there, and the package is told to leave existing folders' permissions alone, so installing never
# changes, say, /Applications (root:admin 775) to root:wheel 755.
meta() { # path in the payload -> "mode uid gid"
  case "$1" in
    .|./Applications/Utilities|./Library|./Library/LaunchAgents) echo "40755 0 0" ;;
    ./Applications) echo "40775 0 80" ;;
    ./Library/Printers) echo "40555 0 0" ;;
    ./Library/Printers/PPDs|./Library/Printers/PPDs/Contents|./Library/Printers/PPDs/Contents/Resources) echo "40755 0 80" ;;
    *) echo "$(stat -f %p "$B/root/$1") 0 0" ;;
  esac
}
(cd "$B/root" && find . | sort) | while IFS= read -r f; do
  set -- $(meta "$f")
  printf '%s\t%s\t%s\t%s\n' "$f" "$1" "$2" "$3"
done > "$B/entries.txt"
# The archive is written from an mtree list, which carries those owners and modes.
awk -F'\t' '{
  path = $1; gsub(/ /, "\\040", path)
  type = substr($2, 1, 1) == "4" ? "dir" : "file"
  printf "%s type=%s uid=%s gid=%s mode=%s\n", path, type, $3, $4, substr($2, length($2) - 3)
}' "$B/entries.txt" > "$B/payload.mtree"
cpio_gz() { # dir [mtree] > archive
  if [ -n "${2:-}" ]; then
    (cd "$1" && bsdtar -c --format cpio -f - "@$2") | gzip -9n
  else
    (cd "$1" && bsdtar -c --format cpio --no-mac-metadata --no-xattrs --no-acls \
      --uid 0 --gid 0 --uname root --gname wheel -f - .) | gzip -9n
  fi
}
pkgutil --expand "$B/component.pkg" "$B/expanded"
C="$B/component"
mkdir "$C"
cp "$B/expanded/PackageInfo" "$C/"
cpio_gz "$B/root" "$PWD/$B/payload.mtree" > "$C/Payload"
cpio_gz "$B/scripts" > "$C/Scripts"
# The bill of materials (mkbom -i: path, mode, uid/gid, and for files size and checksum).
while IFS="$(printf '\t')" read -r f mode uid gid; do
  if [ -d "$B/root/$f" ]; then
    printf '%s\t%s\t%s/%s\n' "$f" "$mode" "$uid" "$gid"
  else
    printf '%s\t%s\t%s/%s\t%s\t%s\n' "$f" "$mode" "$uid" "$gid" "$(stat -f %z "$B/root/$f")" \
      "$(cksum < "$B/root/$f" | cut -d' ' -f1)"
  fi
done < "$B/entries.txt" > "$B/bom.txt"
mkbom -i "$B/bom.txt" "$C/Bom"
files=$(wc -l < "$B/bom.txt" | tr -d ' ')
sed -i '' -e "s/numberOfFiles=\"[0-9]*\"/numberOfFiles=\"$files\"/" \
  -e 's/overwrite-permissions="true"/overwrite-permissions="false"/' "$C/PackageInfo"
(cd "$C" && xar --compression none -cf ../ricoh-sp210.pkg Bom PackageInfo Payload Scripts)
sed "s/\"VERSION\"/\"$VERSION\"/" pkg/Distribution.xml > "$B/Distribution.xml"
productbuild --quiet --distribution "$B/Distribution.xml" --resources "$B/resources" --package-path "$B" "$PKG"
echo "$PKG"

if [ "${1:-}" = --dmg ]; then
  pkg/make-dmg.sh "$PKG" "out/Ricoh-SP210-macOS-$VERSION.dmg"
fi
