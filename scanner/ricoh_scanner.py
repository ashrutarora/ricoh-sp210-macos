"""Scanner side of the Ricoh SP 210SU over USB (interface 1, bulk endpoints 0x02 out, 0x82 in).

Commands are 4-byte little-endian numbers on the OUT endpoint; replies and image data come back
on the IN endpoint. Worked out from Ricoh's Windows scanner driver for interoperability; see
SCANNER.md.

SPDX-License-Identifier: GPL-2.0-or-later
"""
import struct
import time

import usb.backend.libusb1
from PIL import Image
import usb.core
import usb.util

VENDOR, PRODUCT = 0x05CA, 0x044F
INTERFACE, EP_OUT, EP_IN = 1, 0x02, 0x82

CMD_STATUS = 1
CMD_SET_PARAMETERS = 3
CMD_START = 4
CMD_STOP = 5
CMD_GAMMA = 9
CMD_CANCEL = 0x0C
CMD_DRIVER_CLOSE = 0x0D
CMD_FINISH = 0x1E
CMD_UNLOCK = 0x24
CMD_WAKE = 0x32

GREY, COLOUR = 1, 2
HARDWARE_DPI = (300, 600, 1200)  # the scanner ignores lower values and scans at 300
RESOLUTIONS = (75, 100, 150, 200, 300, 600, 1200)   # below 300: scanned at 300, scaled down
# 1200 dpi is slow: about 30 s per square inch, so over 10 minutes for a full page.
GLASS_WIDTH = 2546               # 1/300 inch: 215.5 mm
GLASS_HEIGHT = 3508              # 1/300 inch: 297 mm (A4)
EDGE = 10                        # 1/300 inch of dark glass edge at the top and left, skipped

# Raw readings: ink about 20; white paper about 195 in grey, and red 198, green 189, blue 210 in
# colour. levels() stretches black..white to 0..255 per channel, so paper comes out white.
BLACK_LEVEL = 30
WHITE_GREY = 190
WHITE_RGB = (193, 184, 205)


class ScannerError(Exception):
    pass


def _libusb_backend():
    for path in ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib"):
        try:
            backend = usb.backend.libusb1.get_backend(find_library=lambda _x, p=path: p)
        except OSError:
            continue
        if backend:
            return backend
    return usb.backend.libusb1.get_backend()


def _lut(white, black=BLACK_LEVEL):
    return [min(255, max(0, round((v - black) * 255 / (white - black)))) for v in range(256)]


def levels(image):
    """White and black levels for a scan returned as a PIL image ("L" or "RGB")."""
    if image.mode == "L":
        return image.point(_lut(WHITE_GREY))
    return image.point(sum((_lut(w) for w in WHITE_RGB), []))


# The scanner accepts a tone curve (1024 entries per channel) but does not appear to apply it, so
# a straight one is sent, as Ricoh's driver does, and levels() does the work.
LINEAR_CURVE = bytes(i >> 2 for i in range(1024)) * 3


class Scanner:
    def __init__(self):
        self.dev = usb.core.find(idVendor=VENDOR, idProduct=PRODUCT, backend=_libusb_backend())
        if self.dev is None:
            raise ScannerError("Ricoh SP 210SU not found on USB")
        usb.util.claim_interface(self.dev, INTERFACE)

    def close(self):
        usb.util.release_interface(self.dev, INTERFACE)
        usb.util.dispose_resources(self.dev)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _cmd(self, n, extra=b""):
        self.dev.write(EP_OUT, struct.pack("<I", n) + extra, 5000)

    def _read(self, size, timeout):
        try:
            return bytes(self.dev.read(EP_IN, size, timeout))
        except usb.core.USBTimeoutError:
            return None

    def status(self):
        """8 status bytes; byte 0 is 1 when the scanner is ready."""
        self._cmd(CMD_STATUS)
        reply = self._read(512, 5000)
        if reply is None:
            raise ScannerError("scanner did not answer a status request")
        return reply

    def scan(self, colour=False, dpi=300, x=0, y=0, width=None, height=None, progress=None):
        """Scan an area of the glass and return a PIL image ("L" or "RGB") at `dpi`, levelled so
        paper is white. x, y, width and height are in 1/300 inch from the top left corner;
        width and height default to the rest of the glass."""
        if dpi not in RESOLUTIONS:
            raise ValueError(f"dpi must be one of {RESOLUTIONS}")
        x, y = max(0, x), max(0, y)
        width = min(width or GLASS_WIDTH, GLASS_WIDTH - EDGE - x)
        height = min(height or GLASS_HEIGHT, GLASS_HEIGHT - EDGE - y)
        if width <= 0 or height <= 0:
            raise ValueError("scan area is outside the glass")
        hw = 1200 if dpi > 600 else 600 if dpi > 300 else 300
        k = hw // 300
        w, h, data = self._scan_raw(COLOUR if colour else GREY, hw, (x + EDGE) * k, (y + EDGE) * k,
                                    width * k, height * k, progress)
        image = levels(Image.frombytes("RGB" if colour else "L", (w, h), data))
        if dpi != hw:
            image = image.resize((round(w * dpi / hw), round(h * dpi / hw)), Image.LANCZOS)
        return image

    def _scan_raw(self, mode, resolution, x, y, width, height, progress):
        """One scan at a hardware resolution; area in pixels at that resolution. Returns
        (width, height, bytes): 8-bit grey, or RGB with 3 bytes per pixel."""
        width &= ~7
        self.status()
        self._cmd(CMD_WAKE)

        params = bytearray(32)
        params[0] = 1                                 # flatbed
        params[1] = 1
        params[2] = mode
        struct.pack_into("<H", params, 0x04, resolution)
        struct.pack_into("<H", params, 0x08, resolution)
        struct.pack_into("<I", params, 0x0C, width)
        struct.pack_into("<I", params, 0x10, height)
        struct.pack_into("<H", params, 0x14, x)
        struct.pack_into("<H", params, 0x18, y)
        params[0x1C] = 8                              # bits per channel
        self._cmd(CMD_SET_PARAMETERS)
        self.dev.write(EP_OUT, bytes(params), 5000)

        self._cmd(CMD_GAMMA, struct.pack("<H", 0x400))
        self.dev.write(EP_OUT, LINEAR_CURVE, 5000)

        time.sleep(0.5)
        self._cmd(CMD_START)
        want = width * height * (3 if mode == COLOUR else 1)
        data = bytearray()
        try:
            # The scanner warms its lamp first, so the first data can take several seconds.
            while len(data) < want:
                chunk = self._read(256 * 1024, 30000)
                if chunk is None:
                    raise ScannerError(f"scan stopped after {len(data)} of {want} bytes")
                data += chunk
                if progress:
                    progress(min(len(data), want), want)
        except BaseException:
            self._cmd(CMD_CANCEL)
            raise
        finally:
            self._cmd(CMD_FINISH)
            self._cmd(CMD_STOP)
            # Without these the printer's display stays on "Scanning (USB)..." after the scan.
            self._cmd(CMD_DRIVER_CLOSE)
            self._cmd(CMD_UNLOCK)
        if len(data) - want == 8 and data[0] == 1:
            del data[:8]          # a late 8-byte status reply that arrived ahead of the image
        return width, height, bytes(data[:want])
