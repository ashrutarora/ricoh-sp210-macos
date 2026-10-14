# make                  the driver, with this project's own halftone patterns
# make RICOH_DITHER=1   a build that matches Ricoh's filter byte for byte, for tools/verify.sh;
#                       needs your own copy of Ricoh's filter at ../vendor/rastertolilo
# SPDX-License-Identifier: GPL-2.0-or-later

CFLAGS ?= -O2 -Wall -Wextra
# One file for Apple Silicon and Intel Macs, macOS 13 or later (like the scanner service).
ARCHFLAGS ?= -arch arm64 -arch x86_64 -mmacosx-version-min=13.0
JBIG = ../third_party/jbigkit
DEFS = -DJBG_KEEP_TRAILING_ZEROS=1 -Wno-deprecated-declarations
SRC = rastertoricohsp210.c $(JBIG)/jbig.c $(JBIG)/jbig_ar.c

ifeq ($(RICOH_DITHER),1)
TARGET = rastertoricohsp210-ricoh
DEFS += -DRICOH_DITHER
HEADER = dither_ricoh.h
else
TARGET = rastertoricohsp210
HEADER = dither_own.h
endif

$(TARGET): $(SRC) $(HEADER)
	$(CC) $(CFLAGS) $(ARCHFLAGS) $(DEFS) -I$(JBIG) -o $@ $(SRC) -lcups

dither_ricoh.h: ../vendor/rastertolilo ../tools/extract_ricoh_dither.py
	python3 -I ../tools/extract_ricoh_dither.py ../vendor/rastertolilo > $@.tmp && mv $@.tmp $@

clean:
	rm -f rastertoricohsp210 rastertoricohsp210-ricoh dither_ricoh.h
.PHONY: clean
