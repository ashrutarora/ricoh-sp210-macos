#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# SUDO_ASKPASS helper: asks for the password in a macOS dialog when there is no terminal.
/usr/bin/osascript -e 'text returned of (display dialog "The Ricoh SP 210SU installer needs your Mac password to install the printer driver." with title "Ricoh SP 210SU" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with icon caution)'
