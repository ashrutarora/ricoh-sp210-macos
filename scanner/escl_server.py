"""AirScan (eSCL) service for the Ricoh SP 210SU, so macOS apps can scan with it.

macOS finds it through Bonjour (_uscan._tcp) and lists it in Image Capture, Preview
(File > Import from Scanner) and System Settings > Printers & Scanners.

The HTTP service listens on 127.0.0.1 only and Bonjour announces it at 127.0.0.1, so only this
Mac can reach it; nobody else on the network can scan from your glass. Requests from web pages
(Origin header, or a foreign Host name from DNS rebinding) are refused too.

    escl_server.py [--port 8090] [--name "Ricoh SP 210SU"]

SPDX-License-Identifier: GPL-2.0-or-later
"""
import argparse
import io
import os
import signal
import subprocess
import sys
import threading
import time
import uuid
import xml.etree.ElementTree as ET
import xml.parsers.expat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ricoh_scanner import EDGE, GLASS_HEIGHT, GLASS_WIDTH, RESOLUTIONS, Scanner, ScannerError

NS = ("xmlns:pwg='http://www.pwg.org/schemas/2010/12/sm' "
      "xmlns:scan='http://schemas.hp.com/imaging/escl/2011/05/03'")
SCANNER_UUID = str(uuid.uuid5(uuid.NAMESPACE_URL, "ricoh-sp210su-escl"))
BONJOUR_HOST = "ricoh-sp210su-scanner.local"
LOCAL_HOSTS = {"127.0.0.1", "localhost", "[::1]", BONJOUR_HOST, BONJOUR_HOST + "."}
FORMATS = ("application/pdf", "image/jpeg", "image/png")
# Offered to Mac apps. 1200 dpi works but a full page takes over 10 minutes, long enough for apps
# to give up waiting, so it stays out of this list (ricoh_scanner.Scanner.scan still does it).
ESCL_RESOLUTIONS = tuple(r for r in RESOLUTIONS if r <= 600)
MAX_WIDTH, MAX_HEIGHT = GLASS_WIDTH - EDGE, GLASS_HEIGHT - EDGE


def log(*args):
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


def capabilities_xml(name):
    resolutions = "".join(
        f"<scan:DiscreteResolution><scan:XResolution>{r}</scan:XResolution>"
        f"<scan:YResolution>{r}</scan:YResolution></scan:DiscreteResolution>" for r in ESCL_RESOLUTIONS)
    formats = "".join(f"<pwg:DocumentFormat>{f}</pwg:DocumentFormat>" for f in FORMATS)
    intents = "".join(f"<scan:SupportedIntent>{i}</scan:SupportedIntent>"
                      for i in ("Document", "TextAndGraphic", "Photo", "Preview"))
    return f"""<?xml version='1.0' encoding='UTF-8'?>
<scan:ScannerCapabilities {NS}>
<pwg:Version>2.0</pwg:Version>
<pwg:MakeAndModel>{name}</pwg:MakeAndModel>
<pwg:SerialNumber>1</pwg:SerialNumber>
<scan:UUID>{SCANNER_UUID}</scan:UUID>
<scan:Platen><scan:PlatenInputCaps>
<scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>{MAX_WIDTH}</scan:MaxWidth>
<scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>{MAX_HEIGHT}</scan:MaxHeight>
<scan:MaxPhysicalWidth>{MAX_WIDTH}</scan:MaxPhysicalWidth>
<scan:MaxPhysicalHeight>{MAX_HEIGHT}</scan:MaxPhysicalHeight>
<scan:MaxScanRegions>1</scan:MaxScanRegions>
<scan:SettingProfiles><scan:SettingProfile>
<scan:ColorModes><scan:ColorMode>Grayscale8</scan:ColorMode><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
<scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>
<scan:SupportedResolutions><scan:DiscreteResolutions>{resolutions}</scan:DiscreteResolutions></scan:SupportedResolutions>
<scan:DocumentFormats>{formats}</scan:DocumentFormats>
</scan:SettingProfile></scan:SettingProfiles>
<scan:SupportedIntents>{intents}</scan:SupportedIntents>
</scan:PlatenInputCaps></scan:Platen>
</scan:ScannerCapabilities>
"""


def setting(root, name):
    """First element with this local name, ignoring namespaces."""
    for el in root.iter():
        if el.tag.rsplit("}", 1)[-1] == name and el.text:
            return el.text.strip()
    return None


def parse_settings(data):
    """Parse a ScanSettings document. Scan settings never need a DTD, so one is refused before
    parsing; expat reads the declared encoding, so this also catches a DTD in UTF-16, which a
    byte search would miss. That rules out entity-expansion tricks."""
    checker = xml.parsers.expat.ParserCreate()

    def refuse(*_):
        raise ET.ParseError("DTDs are not accepted")

    checker.StartDoctypeDeclHandler = refuse
    checker.EntityDeclHandler = refuse
    try:
        checker.Parse(data, True)
    except xml.parsers.expat.ExpatError as e:
        raise ET.ParseError(str(e)) from e
    return ET.fromstring(data)


class Job:
    def __init__(self, settings_xml, from_airscan):
        root = parse_settings(settings_xml)
        num = lambda n, d: int(float(setting(root, n) or d))
        self.id = str(uuid.uuid4())
        self.created = time.time()
        self.dpi = num("XResolution", 300)
        if self.dpi not in ESCL_RESOLUTIONS:
            self.dpi = min(ESCL_RESOLUTIONS, key=lambda r: abs(r - self.dpi))
        self.colour = (setting(root, "ColorMode") or "RGB24").startswith("RGB")
        units_300 = (setting(root, "ContentRegionUnits") or "escl:ThreeHundredthsOfInches")
        k = 1 if units_300.endswith("ThreeHundredthsOfInches") else 300 / self.dpi
        self.x = round(num("XOffset", 0) * k)
        self.y = round(num("YOffset", 0) * k)
        self.width = round(num("Width", MAX_WIDTH) * k)
        self.height = round(num("Height", MAX_HEIGHT) * k)
        fmt = setting(root, "DocumentFormatExt") or setting(root, "DocumentFormat") or "image/jpeg"
        if from_airscan and fmt == "image/jpeg":
            fmt = "image/png"            # lossless for Apple's client, as AirSane does
        self.format = fmt if fmt in FORMATS else "image/png"
        self.state = "Pending"           # Pending, Processing, Completed, Canceled, Aborted
        self.done = False

    def info_xml(self):
        return (f"<scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/{self.id}</pwg:JobUri>"
                f"<pwg:JobUuid>{self.id}</pwg:JobUuid><scan:Age>{int(time.time() - self.created)}</scan:Age>"
                f"<pwg:ImagesCompleted>{1 if self.done else 0}</pwg:ImagesCompleted>"
                f"<pwg:ImagesToTransfer>{0 if self.done else 1}</pwg:ImagesToTransfer>"
                f"<pwg:JobState>{self.state}</pwg:JobState></scan:JobInfo>")


def encode(image, fmt, dpi):
    buf = io.BytesIO()
    if fmt == "application/pdf":
        image.save(buf, "PDF", resolution=dpi)
    elif fmt == "image/jpeg":
        image.save(buf, "JPEG", quality=90, dpi=(dpi, dpi))
    else:
        image.save(buf, "PNG", dpi=(dpi, dpi))
    return buf.getvalue()


MAX_JOBS = 20


class Service:
    def __init__(self, name):
        self.name = name
        self.jobs = {}
        self.lock = threading.Lock()      # one scan at a time
        self.busy = False

    def add(self, job):
        """Keep the 20 newest job records; scanning apps only ask about their latest job."""
        self.jobs[job.id] = job
        while len(self.jobs) > MAX_JOBS:
            self.jobs.pop(next(iter(self.jobs)))

    def status_xml(self):
        jobs = "".join(j.info_xml() for j in list(self.jobs.values())[-10:])
        state = "Processing" if self.busy else "Idle"
        return (f"<?xml version='1.0' encoding='UTF-8'?>\n<scan:ScannerStatus {NS}>"
                f"<pwg:Version>2.0</pwg:Version><pwg:State>{state}</pwg:State>"
                f"<scan:Jobs>{jobs}</scan:Jobs></scan:ScannerStatus>\n")

    def run(self, job):
        with self.lock:
            self.busy = True
            job.state = "Processing"
            try:
                t0 = time.time()
                with Scanner() as scanner:
                    image = scanner.scan(job.colour, job.dpi, job.x, job.y, job.width, job.height)
                data = encode(image, job.format, job.dpi)
                log(f"scanned {image.size[0]}x{image.size[1]} {'colour' if job.colour else 'grey'} "
                    f"{job.dpi} dpi {job.format} {len(data)} bytes in {time.time() - t0:.1f}s")
                job.state = "Completed"
                return data
            except Exception:
                job.state = "Aborted"
                raise
            finally:
                job.done = True
                self.busy = False


class Handler(BaseHTTPRequestHandler):
    service = None
    protocol_version = "HTTP/1.1"

    def from_local_app(self):
        """Only scanning apps on this Mac, never a web page. Pages always send Origin on
        cross-site requests, and a DNS-rebinding page arrives with its own host name."""
        host = (self.headers.get("Host") or "").lower()
        name = host.rsplit(":", 1)[0] if not host.endswith("]") else host
        if name in LOCAL_HOSTS and "Origin" not in self.headers:
            return True
        log(f"refused {self.command} {self.path}: Host {host!r}, Origin {self.headers.get('Origin')!r}")
        self.reply(403, "")
        return False

    def read_body(self):
        """The whole request body, or None (after a 4xx reply) if it is chunked, unsized or
        too big. Anything not read would otherwise be parsed as a further request on this
        connection."""
        if self.headers.get("Transfer-Encoding"):
            self.reply(411, "")
            return None
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if not 0 <= length <= 1 << 20:
            self.reply(413, "")
            return None
        return self.rfile.read(length)

    def log_message(self, fmt, *args):
        log(self.command, self.path, fmt % args if "%" in fmt else "")

    def reply(self, code, body=b"", ctype="text/xml", headers=()):
        if isinstance(body, str):
            body = body.encode()
        if code >= 400:
            # After a refusal or error, stop: never read on into a request body we did not want.
            self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.from_local_app():
            return
        s = self.service
        if self.path == "/eSCL/ScannerCapabilities":
            return self.reply(200, capabilities_xml(s.name))
        if self.path == "/eSCL/ScannerStatus":
            return self.reply(200, s.status_xml())
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[:2] == ["eSCL", "ScanJobs"] and parts[3] == "NextDocument":
            job = s.jobs.get(parts[2])
            if not job or job.done:
                return self.reply(404, "")
            try:
                data = s.run(job)
            except ScannerError as e:
                log("scan failed:", e)
                return self.reply(503, "")
            except Exception as e:
                log("scan failed:", repr(e))
                return self.reply(500, "")
            return self.reply(200, data, job.format)
        self.reply(404, "")

    def do_POST(self):
        if not self.from_local_app():
            return
        if self.path != "/eSCL/ScanJobs":
            return self.reply(404, "")
        body = self.read_body()
        if body is None:
            return
        try:
            job = Job(body, "AirScanScanner" in (self.headers.get("User-Agent") or ""))
        except ET.ParseError:
            return self.reply(400, "")
        if self.service.busy:
            return self.reply(503, "")
        self.service.add(job)
        log(f"job {job.id[:8]}: {'colour' if job.colour else 'grey'} {job.dpi} dpi, "
            f"area {job.x},{job.y} {job.width}x{job.height}/300 in, {job.format}")
        self.reply(201, "", headers=[("Location", f"/eSCL/ScanJobs/{job.id}")])

    def do_DELETE(self):
        if not self.from_local_app():
            return
        parts = self.path.strip("/").split("/")
        job = self.service.jobs.get(parts[2]) if len(parts) == 3 else None
        if not job:
            return self.reply(404, "")
        if not job.done:
            job.state, job.done = "Canceled", True
        self.reply(200, "")


def announce(name, port):
    """Register with macOS's own mDNSResponder, as a proxy record pointing at 127.0.0.1.
    A dns-sd left behind by a previous run that was killed outright is stopped first, so the
    scanner is not listed twice."""
    subprocess.run(["/usr/bin/pkill", "-u", str(os.getuid()), "-f",
                    f"^/usr/bin/dns-sd -P {name} _uscan._tcp "], check=False)
    txt = ["txtvers=1", "vers=2.0", "rs=eSCL", f"ty={name}", "note=This Mac",
           f"uuid={SCANNER_UUID}", f"pdl={','.join(FORMATS)}", "cs=color,grayscale",
           "is=platen", "duplex=F"]
    return subprocess.Popen(["/usr/bin/dns-sd", "-P", name, "_uscan._tcp", "local", str(port),
                             BONJOUR_HOST, "127.0.0.1", *txt],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--name", default="Ricoh SP 210SU")
    args = ap.parse_args()
    Handler.service = Service(args.name)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    mdns = announce(args.name, args.port)
    # launchd stops the service with SIGTERM; turn it into a normal exit so the announcement goes.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"AirScan service for {args.name} on http://127.0.0.1:{args.port}/eSCL")
    try:
        server.serve_forever()
    finally:
        mdns.terminate()


if __name__ == "__main__":
    main()
