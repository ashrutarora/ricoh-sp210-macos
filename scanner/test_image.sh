#!/bin/sh
# Builds and runs tests/main.swift: levels, scaling and the PNG, JPEG and PDF output.
# No printer needed.
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
cd "$(dirname "$0")"
OUT=$(mktemp -d -t ricoh-image-test)
trap 'rm -rf "$OUT"' EXIT
swiftc -O -swift-version 5 -I CExpat -o "$OUT/image-tests" tests/main.swift Scanner.swift Image.swift
"$OUT/image-tests"
