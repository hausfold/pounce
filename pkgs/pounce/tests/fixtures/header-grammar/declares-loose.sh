#!/bin/bash
# Anything but `true` or `1` is FALSE, in both parsers. A header that says
# `confirm = yes` gets no sheet — which is why `pounce list` prints what was
# actually parsed rather than what the file says.
# pounce: name = Declares Loose
# pounce: mutates = yes
# pounce: confirm = TRUE
# pounce: network = on
