# make        the printer driver and the scanner service (Apple Silicon and Intel, macOS 13 or later)
# make pkg    the installer package, out/Ricoh-SP210-macOS-<version>.pkg
# make dmg    the disk image people download, out/Ricoh-SP210-macOS-<version>.dmg
# make test   the scanner service's security tests (against the installed service) and the
#             printer driver's malformed-input tests
# SPDX-License-Identifier: GPL-2.0-or-later

all:
	$(MAKE) -C native
	$(MAKE) -C scanner

pkg:
	pkg/build.sh

dmg:
	pkg/build.sh --dmg

test:
	test/security/run.sh
	scanner/test_security.sh
	scanner/test_bonjour.sh

clean:
	$(MAKE) -C native clean
	$(MAKE) -C scanner clean
	rm -rf out/pkg

.PHONY: all pkg dmg test clean
