#!/bin/bash
# pounce: name = Pounce Settings
# pounce: description = Every setting pounce has, in a window
# pounce: icon = gearshape.fill

# Pounce's own settings — not macOS's (that's the "System Settings" row, and
# every individual macOS setting is searchable from the palette directly).
#
# Opens the Settings window: a sidebar of panes, each a scrolling column of
# cards, reading and writing ~/.config/pounce/config.json as the one source of
# truth. Every switch rewrites exactly one line of that file and leaves your
# comments and ordering alone, so the window and a text editor are two doors
# into the same room.
#
# Deliberately NOT submenu=true: this opens a real window of its own rather
# than swapping the palette's contents, so the palette should dismiss.
#
# `pounce settings` hands the request to the daemon when one is running, so the
# window belongs to the resident process and a second invocation raises the
# window you already have.
exec pounce settings
