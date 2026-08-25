#!/bin/bash
# pounce: name = Force Quit
# pounce: description = Force quit a running app
# pounce: icon = xmark.octagon
# pounce: submenu = true

# Force Quit: list running processes grouped into foreground apps and background
# agents/daemons, then kill -9 the selected one. Scoped to System Events'
# process list (the user session) so everything shown is kill-able without sudo —
# the same set macOS's own Force Quit / Activity Monitor user view operates on.

# Enumerate both groups in a SINGLE osascript call. AppleScript is the reliable
# way to get the user-facing list and split it on `background only`; ps alone
# can't distinguish GUI apps from agents.
#
# Performance: each group is one bulk read — `{name, unix id} of (every process
# whose …)` — not a per-process `repeat` loop. The old loop fired an Apple Event
# per process (~100 round-trips) and took ~10s to open; this is a couple of
# events in one process spawn and returns in well under a second. Requesting both
# properties in the same event also keeps names and PIDs aligned by index (no
# race can mislabel a PID — important for a kill tool). The pairing repeats run
# over in-memory lists, so they cost no round-trips.
#
# Output: "<group>\t<name>\t<pid>" lines (group is "Applications" or "Background").
raw=$(osascript 2>/dev/null <<'EOF'
on emit(procs, label)
    set ns to item 1 of procs
    set us to item 2 of procs
    set out to ""
    repeat with i from 1 to count of ns
        set out to out & label & tab & (item i of ns) & tab & (item i of us) & linefeed
    end repeat
    return out
end emit

tell application "System Events"
    set fg to {name, unix id} of (every process whose background only is false)
    set bg to {name, unix id} of (every process whose background only is true)
end tell
return emit(fg, "Applications") & emit(bg, "Background")
EOF
)

# Build pounce rows: title<TAB>subtitle<TAB>icon<TAB>action<TAB>group
# (the trailing group column drives pounce's section headers). Sort by group
# then name (-k1,1 -k2,2f): "Applications" sorts before "Background", and the
# section order in pounce follows first appearance, so apps render first.
rows=$(echo "$raw" | sed '/^$/d' | sort -t$'\t' -k1,1 -k2,2f | \
    while IFS=$'\t' read -r group name pid; do
        [[ -z "$pid" ]] && continue
        if [[ "$group" == "Applications" ]]; then icon="macwindow"; else icon="gearshape.2"; fi
        printf '%s\tpid %s\t%s\tForce Quit\t%s\n' "$name" "$pid" "$icon" "$group"
    done)

if [[ -z "$rows" ]]; then
    printf 'No running processes found\t(nothing to quit)\txmark.circle\n' | pounce
    exit 0
fi

# Draws through trill when this Mac has it, macOS's own banner when it doesn't.
# The bundle is resolved at call time rather than through a `trill` on PATH,
# because pounce installs standalone and cannot assume either. `--source` is
# what `~/.config/trill/rules.json` matches on, so this one command can be
# routed or silenced without silencing pounce. See AGENTS.md § Notifications.
notify() {
    local _bin
    for _bin in "${TRILL_APP:-}/Contents/MacOS/Trill" \
                "$HOME/Applications/Trill.app/Contents/MacOS/Trill" \
                "/Applications/Trill.app/Contents/MacOS/Trill"; do
        [ -x "$_bin" ] || continue
        "$_bin" send --source pounce.force-quit --title "Force Quit" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote would end the
    # AppleScript string early.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Force Quit" >/dev/null 2>&1
}

# Show picker. pounce emits its selection as: action<TAB>raw_line, where raw_line
# is the full tab-separated row we sent (so pid is in field 3 of the output).
selected=$(echo "$rows" | pounce -p "Force Quit" -i "xmark.octagon")

if [[ -n "$selected" ]]; then
    name=$(echo "$selected" | cut -f2)
    pid=$(echo "$selected" | cut -f3 | grep -oE '[0-9]+')

    if [[ -n "$pid" ]]; then
        if kill -9 "$pid" 2>/dev/null; then
            notify "Force quit $name"
        else
            notify "Failed to quit $name"
        fi
    fi
fi
