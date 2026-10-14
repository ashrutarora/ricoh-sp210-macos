# dmgbuild settings for the disk image people download; pkg/make-dmg.sh passes the defines.
# Positions are in points from the top left of the window, and match pkg/make-background.swift.
# SPDX-License-Identifier: GPL-2.0-or-later
name = "Install Ricoh SP 210SU.pkg"
link = "Open Privacy & Security.inetloc"   # opens Settings at the "Open Anyway" button
files = [(defines["pkg"], name), (defines["link"], link)]
hide_extensions = [name, link]
icon_locations = {name: (142, 160), link: (142, 350)}
background = defines["background"]
format = "ULFO"
filesystem = "APFS"
window_rect = ((200, 140), (760, 532))   # the 504-point picture plus the title bar
default_view = "icon-view"
icon_size = 96
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
