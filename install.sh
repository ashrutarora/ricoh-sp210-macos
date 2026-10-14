#!/bin/sh
# Installs the Ricoh SP 210 series driver on macOS from this source tree.
#   ./install.sh            builds the installer package (printer driver and scanner service)
#                           and installs it, the same as the downloadable disk image
#   ./install.sh --docker   fallback printing: Ricoh's own Linux filter in a Docker container
#                           (needs your own copy of it at vendor/rastertolilo, see README)
# Run as yourself, not root; it asks for your password once.
# Environment for --docker: RICOH_URI=usb://...  pick the printer yourself
#                           RICOH_PAGESIZE=A4  default paper size (otherwise from macOS settings / region)
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")"

QUEUE="Ricoh_SP210SU"
NAME="Ricoh SP 210SU (macOS driver)"
DEST="/Library/Printers/RicohSP210Docker"   # --docker only; the package owns RicohSP210
MODE="${1:-native}"

if [ "$(id -u)" = 0 ]; then
  echo "Run as yourself, not with sudo; the script calls sudo where it needs to." >&2
  exit 1
fi

# Without a terminal, sudo asks in a macOS dialog instead.
if ! [ -t 0 ]; then
  export SUDO_ASKPASS="$PWD/tools/askpass.sh"
  sudo() { command sudo -A "$@"; }
fi

if [ "$MODE" = native ]; then
  echo "1/2 Building the installer..."
  PKG=$(pkg/build.sh | tail -1)
  echo "2/2 Installing it (asks for your password)..."
  sudo installer -pkg "$PKG" -target /
  echo "Done. Print with \"Ricoh SP 210SU (macOS driver)\"; scan with Image Capture or Preview."
  exit 0
fi

echo "1/4 Finding the printer on USB..."
URI="${RICOH_URI:-$(lpinfo -v 2>/dev/null | awk '$2 ~ /^usb:\/\/RICOH\/SP%20(210|211)/ {print $2; exit}')}"
if [ -z "$URI" ]; then
  echo "No Ricoh SP 210/211 found on USB. Plug it in, switch it on, and run again." >&2
  echo "(Or set RICOH_URI=usb://... yourself; 'lpinfo -v' lists what macOS sees.)" >&2
  exit 1
fi
echo "    $URI"

# Default paper size: macOS's own setting (Printers & Scanners > Default paper size) if set,
# otherwise Letter in the US, Canada, Mexico and other Letter countries, A4 elsewhere.
if [ -z "${RICOH_PAGESIZE:-}" ]; then
  case "$(defaults read org.cups.PrintingPrefs DefaultPaperID 2>/dev/null)" in
    iso-a4) RICOH_PAGESIZE=A4 ;;
    na-letter) RICOH_PAGESIZE=Letter ;;
    na-legal) RICOH_PAGESIZE=Legal ;;
    iso-a5) RICOH_PAGESIZE=A5 ;;
    *)
      region=$(defaults read -g AppleLocale 2>/dev/null | sed 's/.*_//; s/@.*//')
      case "$region" in
        US|CA|MX|PH|CL|CO|VE|GT|CR|PA|DO|PR|SV|NI|HN|BO) RICOH_PAGESIZE=Letter ;;
        *) RICOH_PAGESIZE=A4 ;;
      esac
      ;;
  esac
fi

PPD_SRC=native/ricoh-sp210.ppd
case "$MODE" in
  --docker)
    if ! [ -f vendor/rastertolilo ]; then
      echo "Fallback mode needs Ricoh's filter at vendor/rastertolilo; see README." >&2
      exit 1
    fi
    echo "2/4 Building and starting the converter container..."
    docker build -q --platform linux/386 -t ricoh-sp210-filter -f docker/Dockerfile . >/dev/null
    docker rm -f ricoh-sp210 >/dev/null 2>&1 || true
    docker run -d --name ricoh-sp210 --platform linux/386 --restart unless-stopped \
      -p 127.0.0.1:9210:9210 ricoh-sp210-filter >/dev/null
    i=0
    until curl -fsS http://127.0.0.1:9210/health >/dev/null 2>&1; do
      i=$((i + 1)); [ $i -gt 60 ] && { echo "Converter did not start." >&2; exit 1; }
      sleep 1
    done
    FILTER=mac/rastertolilo-docker
    ;;
  *)
    echo "Unknown option $MODE (use --docker or nothing)." >&2
    exit 1
    ;;
esac

# The PPD names its filter by absolute path; point it at the one this mode installs.
PPD=$(mktemp -t ricoh-ppd)
trap 'rm -f "$PPD"' EXIT
sed "s#/Library/Printers/RicohSP210/rastertoricohsp210#$DEST/$(basename "$FILTER")#" "$PPD_SRC" > "$PPD"

echo "3/4 Installing the filter and adding the printer (asks for your password once)..."
# One sudo call for every root step, so the password is asked once even without a terminal.
sudo /bin/sh -eu -c '
  rm -rf "$1"
  mkdir -p "$1"
  install -o root -g wheel -m 0755 "$2" "$1/$(basename "$2")"
  install -o root -g wheel -m 0644 "$3" "$1/ricoh-sp210.ppd"
  lpadmin -p "$4" -E -v "$5" -P "$1/ricoh-sp210.ppd" -D "$6" \
    -o printer-is-shared=false -o PageSize="$7"
  cupsenable "$4"
  cupsaccept "$4"
' install-root "$DEST" "$FILTER" "$PPD" "$QUEUE" "$URI" "$NAME" "$RICOH_PAGESIZE"

echo "4/4 Checking..."
lpstat -p "$QUEUE"
echo
echo "Done. In the print dialog choose \"$NAME\". Default paper: $RICOH_PAGESIZE."

# macOS adds its own queue for this printer with a Generic PCL driver, which cannot print on it.
OTHERS=$(lpstat -v 2>/dev/null | awk -v u="$URI" -v q="$QUEUE" '$NF == u { sub(/:$/, "", $3); if ($3 != q) print $3 }')
if [ -n "$OTHERS" ]; then
  echo
  echo "macOS also added this printer with a driver that does not work for it: $OTHERS"
  if [ -t 0 ]; then
    printf "Remove it? [y/N] "
    read -r answer
  else
    answer=n
  fi
  case "$answer" in
    y|Y) for q in $OTHERS; do sudo lpadmin -x "$q" && echo "Removed $q."; done ;;
    *) echo "To remove it later:  sudo lpadmin -x <name>  (or System Settings > Printers & Scanners)" ;;
  esac
fi
echo "Test page:  lp -d $QUEUE test/testpage.pdf"
[ "$MODE" = --docker ] && echo "Docker Desktop must be running to print."
exit 0
