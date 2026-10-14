#!/bin/sh
# Removes the Ricoh SP 210SU driver, however it was installed: the printer, the scanner service and
# their files (the same as Applications > Utilities > Uninstall Ricoh SP 210SU), plus the --docker
# fallback's filter and container. The Docker image is kept; remove it with: docker rmi ricoh-sp210-filter
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
cd "$(dirname "$0")"
if ! [ -t 0 ]; then
  export SUDO_ASKPASS="$PWD/tools/askpass.sh"
  sudo() { command sudo -A "$@"; }
fi

# pkg/uninstall.sh is the uninstaller the package installs; it reads common.sh next to it.
TMP=$(mktemp -d -t ricoh-uninstall)
trap 'rm -rf "$TMP"' EXIT
cp pkg/uninstall.sh pkg/scripts/common.sh "$TMP/"
if ! sudo /bin/sh -c '"$1/uninstall.sh" && rm -rf /Library/Printers/RicohSP210Docker' uninstall "$TMP"; then
  echo "Could not uninstall (wrong password or no permission)." >&2
  exit 1
fi
if command -v docker >/dev/null 2>&1 && docker rm -f ricoh-sp210 >/dev/null 2>&1; then
  echo "Removed the fallback container."
fi
