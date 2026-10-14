"""Tiny HTTP service: POST CUPS raster to /render, get the printer's byte stream back.

The Mac's CUPS filter (mac/rastertolilo-docker) calls this; the container never touches USB.
The port is published on 127.0.0.1 only (see install.sh), so nothing off this Mac can reach it.
CUPS options travel in the X-Cups-Options header, exactly as CUPS passed them to the filter.

SPDX-License-Identifier: GPL-2.0-or-later
"""
import os
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FILTER = "/usr/lib/cups/filter/rastertolilo"
PPD = "/etc/ricoh/ricoh-sp210.ppd"
MAX_BYTES = 512 * 1024 * 1024
ALLOWED_HOSTS = {"127.0.0.1:9210", "localhost:9210"}


def from_our_filter(headers):
    """Only mac/rastertolilo-docker may call /render, never a web page in the user's browser.

    Browsers can POST to localhost from any site. They cannot add X-Ricoh-Bridge or the raster
    content type without a CORS preflight, which this server never answers; they always send
    Origin on a cross-site POST; and a DNS-rebinding page arrives with its own Host name.
    """
    return (
        headers.get("X-Ricoh-Bridge") == "1"
        and headers.get("Content-Type") == "application/vnd.cups-raster"
        and "Origin" not in headers
        and headers.get("Host") in ALLOWED_HOSTS
    )


class Handler(BaseHTTPRequestHandler):
    timeout = 30  # seconds without data before a stalled request is dropped

    def do_GET(self):
        if self.path == "/health":
            self._reply(200, b"ok\n")
        else:
            self._reply(404, b"not found\n")

    def do_POST(self):
        if self.path != "/render":
            return self._reply(404, b"not found\n")
        if not from_our_filter(self.headers):
            return self._reply(403, b"forbidden\n")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._reply(400, b"bad length\n")
        if not 0 < length <= MAX_BYTES:
            return self._reply(413, b"bad length\n")
        options = self.headers.get("X-Cups-Options", "")
        title = self.headers.get("X-Cups-Title", "job")
        with tempfile.NamedTemporaryFile(suffix=".ras") as raster:
            remaining = length
            while remaining:
                chunk = self.rfile.read(min(remaining, 1 << 20))
                if not chunk:
                    break
                raster.write(chunk)
                remaining -= len(chunk)
            raster.flush()
            # argv list, no shell: options and title are passed as plain arguments.
            result = subprocess.run(
                [FILTER, "1", "user", title, "1", options, raster.name],
                capture_output=True,
                env={**os.environ, "PPD": PPD},
            )
        if result.returncode != 0 or not result.stdout:
            msg = b"rastertolilo failed (exit %d)\n" % result.returncode + result.stderr[-4000:]
            return self._reply(500, msg)
        self._reply(200, result.stdout, "application/octet-stream")

    def _reply(self, code, body, ctype="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9210), Handler).serve_forever()
