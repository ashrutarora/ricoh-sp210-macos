# Fallback converter: Ricoh's own 32-bit x86 Linux filter (rastertolilo) under emulation.
# Ricoh's filter is not part of this project: put your own copy at vendor/rastertolilo first
# (see README). Default: HTTP service on 9210 (CUPS raster in, printer bytes out) for
# mac/rastertolilo-docker. `docker run ... --entrypoint render` takes a PDF/PostScript on stdin.
# SPDX-License-Identifier: GPL-2.0-or-later
FROM --platform=linux/386 debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ghostscript libcups2 libcupsimage2 libstdc++6 cups-filters cups-client python3 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --no-create-home ricoh

COPY vendor/rastertolilo /usr/lib/cups/filter/rastertolilo
COPY native/ricoh-sp210.ppd /etc/ricoh/ricoh-sp210.ppd
COPY docker/render.sh /usr/local/bin/render
COPY docker/server.py /usr/local/lib/ricoh/server.py
RUN chmod 0555 /usr/lib/cups/filter/rastertolilo /usr/local/bin/render

USER ricoh
EXPOSE 9210
CMD ["python3", "-u", "/usr/local/lib/ricoh/server.py"]
