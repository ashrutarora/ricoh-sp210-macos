# make    the scanner service, one file for Apple Silicon and Intel Macs (macOS 13 or later)
# SPDX-License-Identifier: GPL-2.0-or-later

SRC = main.swift Scanner.swift Image.swift ESCL.swift HTTP.swift Bonjour.swift AirPrint.swift
SWIFTFLAGS = -O -swift-version 5 -I CExpat
MIN_MACOS = 13.0

ricoh-sp210-scanner: $(SRC) CExpat/module.modulemap CExpat/shim.h
	swiftc $(SWIFTFLAGS) -target arm64-apple-macos$(MIN_MACOS) -o $@.arm64 $(SRC)
	swiftc $(SWIFTFLAGS) -target x86_64-apple-macos$(MIN_MACOS) -o $@.x86_64 $(SRC)
	lipo -create -output $@ $@.arm64 $@.x86_64
	rm -f $@.arm64 $@.x86_64
	codesign -s - -f $@

clean:
	rm -f ricoh-sp210-scanner ricoh-sp210-scanner.arm64 ricoh-sp210-scanner.x86_64
.PHONY: clean
