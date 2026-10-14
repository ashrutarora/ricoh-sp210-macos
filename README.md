# Ricoh SP 210SU driver for macOS

Ricoh never made a macOS driver for the SP 210 series of USB laser printers, so on a Mac they show up but
cannot print. This is a native macOS printer driver (a CUPS filter) for them: install it and print from any
app with Cmd+P.

It speaks the printer's own print format, worked out from Ricoh's Linux driver with Ghidra for
interoperability (see [FORMAT.md](FORMAT.md)). With Ricoh's dither table swapped in, its output is byte for
byte the same as Ricoh's Linux driver on every test case. No Ricoh code is included or needed.

**Status:** prints on a real SP 210SU, macOS 27 on Apple Silicon. Other models and Intel Macs should work but
are untested; reports welcome.

| Model | Status |
|---|---|
| SP 210SU | tested |
| SP 210, SP 211, SP 211SU, SP 211SF | same driver family, untested |

## Install

Needs the Xcode Command Line Tools (for `make` and the CUPS headers): `xcode-select --install`.

1. Connect the printer by USB and switch it on. `lpinfo -v` should list `usb://RICOH/SP%20210...`.
2. Download this repository and run:

   ```
   ./install.sh
   ```

   Run it as yourself, not with sudo. It builds the driver, asks for your password once, and adds a printer
   called **Ricoh SP 210SU (macOS driver)**. The default paper size comes from macOS's default paper size
   setting, or your region; set `RICOH_PAGESIZE=A4` (or `Letter`, ...) to choose.
3. Print a test page: `lp -d Ricoh_SP210SU test/testpage.pdf`

### Pick the right printer

When the printer is plugged in, macOS adds it by itself as **RICOH SP 210SU** with a "Generic PCL" driver.
That one cannot print on this printer (it tells macOS it speaks PCL, but it does not). In the print
dialog choose **Ricoh SP 210SU (macOS driver)**. The installer offers to remove the generic one; you can
also delete it in System Settings > Printers & Scanners.

### Options

In the print dialog: paper size (A4, Letter, Legal, Executive, Statement, A5, A6, B5, B6, 16K, custom),
paper source (Tray 1, bypass tray), paper type (plain, recycled, thin, thick) and toner save.

### Uninstall

```
./uninstall.sh
```

## Limitations

- Printing only. The SP 210SU's scanner is not supported.
- 600 dpi, black and white, one-sided.
- No toner, paper or error status from the printer.

## Troubleshooting

- **The installer says no printer found / `lpinfo -v` shows nothing:** check the USB cable at both ends and
  that the printer is on and its lights are steady. A USB-C hub or adapter is fine.
- **Jobs stay in the queue or fail:** look at `/var/log/cups/error_log` (`cupsctl --debug-logging` for more
  detail) and check you printed to "Ricoh SP 210SU (macOS driver)".
- **Wrong paper size:** pick the size in the print dialog, or reinstall with `RICOH_PAGESIZE=...`.

## How it works

```
any app > macOS CUPS (600 dpi greyscale raster) > rastertoricohsp210 > CUPS USB backend > printer
```

`native/rastertoricohsp210.c` reads CUPS raster, halftones it with its own 24x24 clustered-dot screen
(`tools/make_dither.py`), compresses each 256-row band with JBIG1 (jbigkit), and wraps the bands in the
printer's job and page headers. [FORMAT.md](FORMAT.md) documents the format.

## For developers

- `make -C native` builds the driver; `test/security/run.sh` runs malformed-input tests under
  AddressSanitizer.
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
- [Ghidra](https://github.com/NationalSecurityAgency/ghidra) for studying Ricoh's Linux driver.
- [revisitor/ricoh-sp100](https://github.com/revisitor/ricoh-sp100) and
  [PranavDalvi/RICOH-SP-210-Printer-Drivers-Linux](https://github.com/PranavDalvi/RICOH-SP-210-Printer-Drivers-Linux)
  for the Linux driver installation notes that pointed the way.

Licensed under the GNU General Public License v2.0 or later; see [LICENSE](LICENSE).

Ricoh is a trademark of Ricoh Company, Ltd. This project is not affiliated with or endorsed by Ricoh.
