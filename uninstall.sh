#!/bin/sh
# Removes everything install.sh added: the printer queue, the filter and PPD, and the
# fallback container. The Docker image is kept; remove it with: docker rmi ricoh-sp210-filter
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
cd "$(dirname "$0")"
if ! [ -t 0 ]; then
  export SUDO_ASKPASS="$PWD/tools/askpass.sh"
  sudo() { command sudo -A "$@"; }
fi

if sudo /bin/sh -c '
  if lpstat -p Ricoh_SP210SU >/dev/null 2>&1; then lpadmin -x Ricoh_SP210SU || exit 1; fi
  rm -rf /Library/Printers/RicohSP210
'; then
  echo "Removed the printer and its driver files."
else
  echo "Could not remove the printer (wrong password or no permission)." >&2
  exit 1
fi
if command -v docker >/dev/null 2>&1 && docker rm -f ricoh-sp210 >/dev/null 2>&1; then
  echo "Removed the fallback container."
fi
