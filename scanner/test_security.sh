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
