#!/bin/bash
# pounce: name = Caffeinate
# pounce: description = Keep the Mac awake
# pounce: icon = cup.and.saucer
# pounce: submenu = true

# Keep-awake toggle on top of the system `caffeinate` (no extra installs):
# -d keeps the display on, -i blocks idle sleep. Picking "Let the Mac Sleep"
# (or the timer running out) ends it.

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
        "$_bin" send --source pounce.caffeinate --title "Caffeinate" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote used to end the
    # AppleScript string early, which is why callers here stripped them.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Caffeinate" >/dev/null 2>&1
}

# Only track the caffeinate WE started (other processes spawn their own —
# Claude Code, for one — and those are not ours to report or kill).
pidfile="${TMPDIR:-/tmp}/pounce-caffeinate.pid"

if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    selected=$(printf 'Let the Mac Sleep\tKeeping the Mac awake — select to stop\tmoon.zzz' \
        | pounce -p "Caffeinate" -i "cup.and.saucer")
    if [[ -n "$selected" ]]; then
        kill "$(cat "$pidfile")" 2>/dev/null
        rm -f "$pidfile"
        notify "Sleep re-enabled"
    fi
    exit 0
fi
rm -f "$pidfile"

list="Keep Awake Indefinitely"$'\t'"Until you turn it off"$'\t'"infinity"
list="$list"$'\n'"Keep Awake 30 Minutes"$'\t\t'"clock"
list="$list"$'\n'"Keep Awake 1 Hour"$'\t\t'"clock"
list="$list"$'\n'"Keep Awake 2 Hours"$'\t\t'"clock"

selected=$(printf '%s\n' "$list" | pounce -p "Keep the Mac awake…" -i "cup.and.saucer")
[[ -z "$selected" ]] && exit 0

choice=$(printf '%s' "$selected" | cut -f2)
case "$choice" in
    "Keep Awake Indefinitely")
        nohup caffeinate -di >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake until you turn it off"
        ;;
    "Keep Awake 30 Minutes")
        nohup caffeinate -di -t 1800 >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake for 30 minutes"
        ;;
    "Keep Awake 1 Hour")
        nohup caffeinate -di -t 3600 >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake for 1 hour"
        ;;
    "Keep Awake 2 Hours")
        nohup caffeinate -di -t 7200 >/dev/null 2>&1 & echo $! >"$pidfile"
        notify "Staying awake for 2 hours"
        ;;
esac
