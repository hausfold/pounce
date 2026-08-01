#!/bin/bash
# pounce: name = Emoji & Symbols
# pounce: description = Search & paste emoji, ⌘ ⌥ ⇧, arrows, math
# pounce: icon = face.smiling
# pounce: submenu = true

# Emoji Picker: open the character grid with fuzzy name/keyword search — emoji
# plus the curated plain-text symbols (type "command" for ⌘). Enter copies the
# highlighted glyph to the clipboard — and, when clipboard.autoPaste is enabled
# and the daemon holds Accessibility, pastes it straight at the cursor of the
# previously focused app, like clipboard history. Frecency floats frequently
# used glyphs to the top.
#
# Asks the daemon to run `mode:emoji`; it swaps it into the live palette
# window (this command is registered submenu=true), so there's no close→reopen
# flash between the palette and the picker.
exec pounce run mode:emoji
