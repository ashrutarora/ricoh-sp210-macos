-- Uninstall Ricoh SP 210SU: asks, then runs the uninstaller with the administrator password.
-- SPDX-License-Identifier: GPL-2.0-or-later
set uninstaller to "/Library/Printers/RicohSP210/uninstall.sh"
try
	do shell script "test -x " & quoted form of uninstaller
on error
	display dialog "The Ricoh SP 210SU driver is not installed." buttons {"OK"} default button 1 with icon caution
	return
end try
display dialog "Remove the Ricoh SP 210SU driver?" & return & return & "This removes the printer, the scanner service and their files. Your scans and documents are not touched." buttons {"Cancel", "Uninstall"} default button "Uninstall" cancel button "Cancel" with icon caution
try
	do shell script quoted form of uninstaller with prompt "Uninstall Ricoh SP 210SU wants to remove the driver." with administrator privileges
	display dialog "The Ricoh SP 210SU driver is removed." buttons {"OK"} default button 1
on error message number n
	if n is not -128 then display dialog "Could not uninstall: " & message buttons {"OK"} default button 1 with icon stop
end try
