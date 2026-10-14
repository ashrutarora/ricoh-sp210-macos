#!/bin/sh
# Regression tests: a web page must not be able to drive the scanner service, either directly
# (cross-site requests carry Origin) or through DNS rebinding (a foreign Host name).
# Runs against the installed service. A request that is wrongly accepted creates a job, which is
# deleted again before it scans anything.
# SPDX-License-Identifier: GPL-2.0-or-later
set -u
URL="http://127.0.0.1:${RICOH_SCANNER_PORT:-8090}"
BODY='<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03"><scan:XResolution>75</scan:XResolution></scan:ScanSettings>'
fail=0

expect() { # name expected-status curl-args...
  name=$1 want=$2; shift 2
  out=$(curl -s -D - -o /dev/null "$@")
  got=$(printf '%s' "$out" | awk 'NR==1 {print $2}')
  loc=$(printf '%s' "$out" | awk -F': ' 'tolower($1)=="location" {print $2}' | tr -d '\r')
  [ -n "$loc" ] && curl -s -o /dev/null -X DELETE "$URL$loc"
  if [ "$got" = "$want" ]; then echo "ok   $name ($got)"; else echo "FAIL $name: got $got, want $want"; fail=1; fi
}

expect "rebinding Host on capabilities" 403 -H "Host: evil.example:8090" "$URL/eSCL/ScannerCapabilities"
expect "rebinding Host on new job"      403 -H "Host: evil.example:8090" -H "Content-Type: text/xml" --data "$BODY" "$URL/eSCL/ScanJobs"
expect "cross-site form post"           403 -H "Origin: https://evil.example" -H "Content-Type: text/plain" --data "$BODY" "$URL/eSCL/ScanJobs"
expect "cross-site read"                403 -H "Origin: https://evil.example" "$URL/eSCL/ScannerStatus"
expect "local client, 127.0.0.1"        200 "$URL/eSCL/ScannerCapabilities"
expect "local client, Bonjour name"     200 -H "Host: ricoh-sp210su-scanner.local:8090" "$URL/eSCL/ScannerCapabilities"

# A refused request must not leave its body to be read as a second, clean request on the same
# connection (request smuggling past the Origin check).
replies=$(python3 -I - "${RICOH_SCANNER_PORT:-8090}" "$BODY" <<'PY'
import socket, sys, time
port, body = int(sys.argv[1]), sys.argv[2].encode()
inner = (b"POST /eSCL/ScanJobs HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: text/xml\r\n"
         b"Content-Length: %d\r\n\r\n" % (port, len(body))) + body
outer = (b"POST /eSCL/ScanJobs HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: https://evil.example\r\n"
         b"Content-Type: text/plain\r\nContent-Length: %d\r\n\r\n" % (port, len(inner))) + inner
s = socket.create_connection(("127.0.0.1", port)); s.sendall(outer); s.settimeout(3)
data = b""
try:
    while chunk := s.recv(65536):
        data += chunk
except socket.timeout:
    pass
print(data.count(b"HTTP/1.1 "))
for line in data.split(b"\r\n"):
    if line.lower().startswith(b"location: "):
        print(line.split(b" ", 1)[1].decode())
PY
)
n=$(printf '%s\n' "$replies" | head -1)
for loc in $(printf '%s\n' "$replies" | tail -n +2); do curl -s -o /dev/null -X DELETE "$URL$loc"; done
if [ "$n" = 1 ]; then echo "ok   smuggled request after a refusal (1 reply, connection closed)"
else echo "FAIL smuggled request after a refusal: $n replies on one connection"; fail=1; fi

# Request framing: anything ambiguous about where a body ends is refused and the connection closed.
framing=$(python3 -I - "${RICOH_SCANNER_PORT:-8090}" <<'PY'
import re, socket, sys
port = int(sys.argv[1])
host = b"Host: 127.0.0.1:%d\r\n" % port
def ask(raw):
    s = socket.create_connection(("127.0.0.1", port)); s.settimeout(3)
    try:
        s.sendall(raw)
    except OSError:
        pass
    data = b""
    try:
        while chunk := s.recv(65536):
            data += chunk
    except (socket.timeout, ConnectionResetError):
        pass
    s.close()
    codes = [c.decode() for c in re.findall(rb"HTTP/1\.1 (\d{3}) ", data)]
    return ",".join(codes) or "none"
status = b"GET /eSCL/ScannerStatus HTTP/1.1\r\n" + host
print("chunked", ask(b"POST /eSCL/ScanJobs HTTP/1.1\r\n" + host + b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n" + status + b"\r\n"))
print("two-lengths", ask(b"POST /eSCL/ScanJobs HTTP/1.1\r\n" + host + b"Content-Length: 0\r\nContent-Length: 40\r\n\r\n" + status + b"\r\n"))
print("huge-headers", ask(b"GET /eSCL/ScannerStatus HTTP/1.1\r\n" + host + b"X-Pad: " + b"a" * 40000 + b"\r\n\r\n"))
print("huge-body", ask(b"POST /eSCL/ScanJobs HTTP/1.1\r\n" + host + b"Content-Length: 2000000\r\n\r\n"))
print("keep-alive", ask(status + b"\r\n" + status + b"Connection: close\r\n\r\n"))
PY
)
check_framing() { # name expected
  got=$(printf '%s\n' "$framing" | awk -v n="$1" '$1 == n {print $2}')
  if [ "$got" = "$2" ]; then echo "ok   $1 ($got)"; else echo "FAIL $1: got $got, want $2"; fail=1; fi
}
check_framing chunked 411
check_framing two-lengths 400
check_framing huge-headers 431
check_framing huge-body 413
check_framing keep-alive 200,200

# DTDs must be refused whatever the text encoding (a UTF-16 body hides "<!DOCTYPE" from a byte search).
DTD=$(mktemp -t ricoh-dtd)
python3 -I - > "$DTD" <<'PY'
import sys
xml = ('<?xml version="1.0" encoding="UTF-16"?><!DOCTYPE s [<!ENTITY a "aaaaaaaaaa">]>'
       '<scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">'
       '<scan:XResolution>75</scan:XResolution><scan:Intent>&a;</scan:Intent></scan:ScanSettings>')
sys.stdout.buffer.write(xml.encode("utf-16"))
PY
expect "DTD in a UTF-16 body"           400 -H "Content-Type: text/xml" --data-binary "@$DTD" "$URL/eSCL/ScanJobs"
rm -f "$DTD"

# Job records must not pile up without limit: after 60 abandoned jobs the first is gone.
first=$(curl -s -D - -o /dev/null -H "Content-Type: text/xml" --data "$BODY" "$URL/eSCL/ScanJobs" | awk -F': ' 'tolower($1)=="location" {print $2}' | tr -d '\r')
for i in $(seq 1 60); do curl -s -o /dev/null -H "Content-Type: text/xml" --data "$BODY" "$URL/eSCL/ScanJobs"; done
expect "60 abandoned jobs: the oldest is dropped" 404 -X DELETE "$URL$first"
for j in $(curl -s "$URL/eSCL/ScannerStatus" | grep -o '<pwg:JobUuid>[^<]*' | sed 's/.*>//'); do curl -s -o /dev/null -X DELETE "$URL/eSCL/ScanJobs/$j"; done
exit $fail
