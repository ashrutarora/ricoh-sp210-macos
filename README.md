# Ricoh SP 210SU driver for macOS

Ricoh never made macOS drivers for the SP 210 series of USB laser printers, so on a Mac they show up but
cannot print or scan. This project fixes both: a native printer driver (a CUPS filter), so you print from any
app with Cmd+P, and a scanner service, so the SP 210SU's scanner works in Image Capture and Preview.

It speaks the printer's own print format, worked out from Ricoh's Linux driver with Ghidra for
interoperability (see [FORMAT.md](FORMAT.md)). With Ricoh's dither table swapped in, its output is byte for
byte the same as Ricoh's Linux driver on every test case. No Ricoh code is included or needed.

**Status:** prints and scans on a real SP 210SU, macOS 27 on Apple Silicon. Intel Macs and the other models
should work but are untested; reports welcome. Needs macOS 13 Ventura or later.

| Model | Status |
|---|---|
| SP 210SU | tested |
| SP 210, SP 211, SP 211SU, SP 211SF | same driver family, untested |

## Install

1. Download **Ricoh-SP210-macOS-<version>.dmg** from the
   [latest release](https://github.com/ashrutarora/ricoh-sp210-macos/releases/latest) and open it.
2. Double-click **Install Ricoh SP 210SU**.
3. macOS will probably say it "could not verify" the installer, because it is not registered with Apple
   (that needs a paid developer account). Click **Done**, open **System Settings > Privacy & Security**,
   scroll to the bottom and click **Open Anyway**, then confirm with your password.
4. Follow the installer, then connect the printer by USB and switch it on. macOS adds it with this driver.

The disk image shows these steps too. The installer adds:

- the printer driver, with the printer as **Ricoh SP 210SU (macOS driver)**. Default paper size comes from
  your Printers & Scanners setting, or your region.
- the scanner service, which makes the scanner work in Image Capture and Preview (below).
- **Uninstall Ricoh SP 210SU** in Applications > Utilities.

No Homebrew, Python or Terminal needed. Upgrading from 1.0: run the new installer; it replaces the old
scanner service, and Homebrew's libusb is no longer needed.

### Pick the right printer

When the printer is plugged in before the driver is installed, macOS adds it by itself as **RICOH SP 210SU**
with a "Generic PCL" driver. That one cannot print on this printer (it tells macOS it speaks PCL, but it does
not). The installer removes it when the printer is connected during installation; otherwise delete it in
System Settings > Printers & Scanners and use **Ricoh SP 210SU (macOS driver)**.

### Options

In the print dialog: paper size (A4, Letter, Legal, Executive, Statement, A5, A6, B5, B6, 16K, custom),
paper source (Tray 1, bypass tray), paper type (plain, recycled, thin, thick) and toner save.

### Uninstall

Open **Applications > Utilities > Uninstall Ricoh SP 210SU**. From a copy of this repository, `./uninstall.sh`
does the same.

## Scanning (SP 210SU)

The installer adds a small background service, started at login, that makes the scanner appear as
**Ricoh SP 210SU** in Image Capture, in Preview (File > Import from Scanner) and in System Settings >
Printers & Scanners. It speaks Apple's AirScan (eSCL) protocol on 127.0.0.1 only and is announced to this Mac
only, so nothing else on your network sees it or can scan from your glass, and it refuses requests coming
from web pages. Colour or greyscale, 75 to 600 dpi, any area of the glass, saved as PDF, JPEG or PNG.

macOS lists it as a background item ("ricoh-sp210-scanner") in System Settings > General > Login Items &
Extensions; scanning needs it switched on. Its log is `~/Library/Logs/RicohSP210Scanner.log`.
[SCANNER.md](SCANNER.md) documents the scanner's USB protocol.

## Limitations

- Printing: 600 dpi, black and white, one-sided.
- Scanning: flatbed only, one page at a time. The scanner also does 1200 dpi, but slowly (over 10 minutes a
  page), so the Mac apps are offered up to 600. For 1200 dpi use the command line:
  `/Library/Printers/RicohSP210/ricoh-sp210-scanner scan --dpi 1200 --area 0,0,600,600 scan.png`
  (area in 1/300 inch; `--grey` for greyscale).
- No toner, paper or error status from the printer.

## Troubleshooting

- **The printer is not listed:** check the USB cable at both ends and that the printer is on and its lights
  are steady. A USB-C hub or adapter is fine. `lpinfo -v` should list `usb://RICOH/SP%20210...`.
- **Jobs stay in the queue or fail:** look at `/var/log/cups/error_log` (`cupsctl --debug-logging` for more
  detail) and check you printed to "Ricoh SP 210SU (macOS driver)".
- **Wrong paper size:** pick the size in the print dialog, or set the default in System Settings > Printers &
  Scanners.
- **Scanner not listed or scans fail:** check the printer is on and connected, that the background item is
  switched on (see above), then look at `~/Library/Logs/RicohSP210Scanner.log`. Only one app can scan at a
  time.
- **Image Capture says "Waiting for scanner..." or "Failed to open a session on the device (-9921)":** quit
  Image Capture and open it again; if that is not enough, also run `killall AirScanScanner`. (Version 1.0.0
  also announced the scanner on Wi-Fi, which made this happen often; 1.0.1 and later announce it to this Mac
  only.)

## How it works

```
printing: any app > macOS CUPS (600 dpi greyscale raster) > rastertoricohsp210 > CUPS USB backend > printer
scanning: Image Capture / Preview > AirScan (eSCL) over 127.0.0.1 > ricoh-sp210-scanner > USB > scanner
```

`native/rastertoricohsp210.c` reads CUPS raster, halftones it with its own 24x24 clustered-dot screen
(`tools/make_dither.py`), compresses each 256-row band with JBIG1 (jbigkit), and wraps the bands in the
printer's job and page headers. [FORMAT.md](FORMAT.md) documents the format.

`scanner/` is the scanner service in Swift: USB through Apple's IOUSBHost framework, levels and scaling with
Accelerate, PNG, JPEG and PDF with ImageIO and Core Graphics, Bonjour with macOS's own mDNSResponder.

## Building from source

Needs the Xcode Command Line Tools: `xcode-select --install`.

- `make` builds the printer driver and the scanner service, each one file for Apple Silicon and Intel.
- `make pkg` builds the installer package and `make dmg` the disk image, in `out/`. The disk image's layout
  is made with [dmgbuild](https://github.com/dmgbuild/dmgbuild), which `pkg/make-dmg.sh` installs into a
  build-only Python environment in `out/build-venv`.
- `./install.sh` builds the package and installs it (asks for your password).

## For developers

- `make test`: `test/security/run.sh` runs malformed-input tests on the printer driver under
  AddressSanitizer; `scanner/test_security.sh` checks, against the installed scanner service, that web pages
  cannot drive it and that it refuses ambiguous HTTP requests; `scanner/test_bonjour.sh` that it is announced
  to this Mac only.
- **Byte-for-byte check against Ricoh's driver.** `tools/verify.sh` renders test pages, runs Ricoh's own
  Linux filter in a Docker container and a `make RICOH_DITHER=1` build of this driver on the same input, and
  requires identical output. It needs Docker Desktop and your own copy of Ricoh's filter, which is not
  distributed here; see [vendor/README.md](vendor/README.md).
- **Fallback mode.** `./install.sh --docker` prints through Ricoh's own filter in that container instead of
  the native driver (Docker Desktop must be running). The container listens on 127.0.0.1:9210 only and
  accepts requests only from the bundled filter; it sends the job as "job<number>" rather than its title.
- `tools/gdidump.py` and `tools/gdicompare.py` inspect and diff print jobs; `tools/raster2pgm.py` previews a
  CUPS raster.

## Credits and licence

- [jbigkit](https://www.cl.cam.ac.uk/~mgk25/jbigkit/) by Markus Kuhn (GPL-2.0-or-later) for JBIG
  compression, with one small change described in [third_party/jbigkit/README.md](third_party/jbigkit/README.md).
- [Ghidra](https://github.com/NationalSecurityAgency/ghidra) for studying Ricoh's Linux printer driver and Windows
  scanner driver.
- [AirSane](https://github.com/SimulPiscator/AirSane), whose AirScan notes for macOS shaped the scanner service.
- [Expat](https://libexpat.github.io) (part of macOS) for reading scan settings, and
  [dmgbuild](https://github.com/dmgbuild/dmgbuild) for the disk image.
- [revisitor/ricoh-sp100](https://github.com/revisitor/ricoh-sp100) and
  [PranavDalvi/RICOH-SP-210-Printer-Drivers-Linux](https://github.com/PranavDalvi/RICOH-SP-210-Printer-Drivers-Linux)
  for the Linux driver installation notes that pointed the way.

Licensed under the GNU General Public License v2.0 or later; see [LICENSE](LICENSE).

Ricoh is a trademark of Ricoh Company, Ltd. This project is not affiliated with or endorsed by Ricoh.
