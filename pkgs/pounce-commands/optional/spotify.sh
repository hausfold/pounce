#!/bin/bash
# pounce: name = Spotify
# pounce: description = Playback controls
# pounce: icon = music.note
# pounce: submenu = true
# pounce: mutates = true

# Spotify remote — drives the desktop app over AppleScript. No login, no API
# keys; just needs Spotify.app installed.

# Draws through trill when this Mac has it, macOS's own banner when it doesn't.
# The bundle is resolved at call time rather than through a `trill` on PATH,
# because pounce installs standalone and cannot assume either. `--source` is
# what `~/.config/trill/rules.json` matches on, so this one command can be
# routed or silenced without silencing pounce. See AGENTS.md § Notifications.
#
#   notify <body> [kind] [sf-symbol]     kind: note (default) | fault | "done"
#
# Quote `done` when you pass it: it is a shell keyword, and unquoted it
# makes shellcheck read the line as a broken loop (SC1010).
#
# The kind is what trill colours the card by, so a failure and a confirmation
# do not arrive looking identical. macOS has nowhere to put either, which is
# why the fallback drops them rather than faking them.
notify() {
    local _bin
    # An array, not `${3:+--symbol "$3"}`: that form is word-split after
    # expansion, so a value with a space in it would arrive as two arguments.
    local _sym=()
    [ -n "${3:-}" ] && _sym=(--symbol "$3")
    for _bin in "${TRILL_APP:-}/Contents/MacOS/Trill" \
                "$HOME/Applications/Trill.app/Contents/MacOS/Trill" \
                "/Applications/Trill.app/Contents/MacOS/Trill"; do
        [ -x "$_bin" ] || continue
        "$_bin" send --kind "${2:-note}" "${_sym[@]}" --source pounce.spotify --title "Spotify" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote used to end the
    # AppleScript string early, which is why callers here stripped them.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Spotify" >/dev/null 2>&1
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if [[ ! -d "/Applications/Spotify.app" && ! -d "$HOME/Applications/Spotify.app" ]]; then
    printf 'Spotify.app not found\tbrew install --cask spotify\texclamationmark.triangle' \
        | pounce -p "Spotify" -i "music.note" >/dev/null
    exit 0
fi

if [[ "$(osascript -e 'application "Spotify" is running' 2>/dev/null)" != "true" ]]; then
    selected=$(printf 'Open Spotify\tSpotify is not running\tmusic.note' \
        | pounce -p "Spotify" -i "music.note")
    [[ -n "$selected" ]] && open -a "Spotify"
    exit 0
fi

state=$(osascript -e 'tell application "Spotify" to player state as string' 2>/dev/null)
track=$(osascript -e 'tell application "Spotify" to name of current track' 2>/dev/null)
artist=$(osascript -e 'tell application "Spotify" to artist of current track' 2>/dev/null)
shuffle=$(osascript -e 'tell application "Spotify" to shuffling' 2>/dev/null)

now="$track — $artist"
[[ -z "$track" ]] && now="Nothing queued"

list=""
add() {
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

if [[ "$state" == "playing" ]]; then
    add "Pause"$'\t'"$now"$'\t'"pause.fill"
else
    add "Play"$'\t'"$now"$'\t'"play.fill"
fi
add "Next Track"$'\t\t'"forward.fill"
add "Previous Track"$'\t\t'"backward.fill"
if [[ "$shuffle" == "true" ]]; then
    add "Shuffle Off"$'\t'"Shuffle is on"$'\t'"shuffle"
else
    add "Shuffle On"$'\t'"Shuffle is off"$'\t'"shuffle"
fi
add "Copy Song Link"$'\t'"$now"$'\t'"link"
add "Open Spotify"$'\t\t'"music.note"

selected=$(printf '%s\n' "$list" | pounce -p "Spotify" -i "music.note")
[[ -z "$selected" ]] && exit 0

choice=$(printf '%s' "$selected" | cut -f2)
case "$choice" in
    "Play"|"Pause")
        osascript -e 'tell application "Spotify" to playpause'
        ;;
    "Next Track")
        osascript -e 'tell application "Spotify" to next track'
        ;;
    "Previous Track")
        osascript -e 'tell application "Spotify" to previous track'
        ;;
    "Shuffle On")
        osascript -e 'tell application "Spotify" to set shuffling to true'
        notify "Shuffle on"
        ;;
    "Shuffle Off")
        osascript -e 'tell application "Spotify" to set shuffling to false'
        notify "Shuffle off"
        ;;
    "Copy Song Link")
        # spotify:track:<id> → https://open.spotify.com/track/<id>
        uri=$(osascript -e 'tell application "Spotify" to spotify url of current track' 2>/dev/null)
        id="${uri##*:}"
        if [[ "$uri" == spotify:track:* && -n "$id" ]]; then
            printf 'https://open.spotify.com/track/%s' "$id" | pbcopy
            notify "Link copied: $now"
        else
            notify "No track playing"
        fi
        ;;
    "Open Spotify")
        open -a "Spotify"
        ;;
esac
