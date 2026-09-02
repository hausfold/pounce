#!/bin/bash
# pounce: name = Lock Screen
# pounce: description = Lock the display
# pounce: icon = lock
# pounce: mutates = true
# Lock the screen using Cmd+Ctrl+Q
osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}'
