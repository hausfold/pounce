#!/bin/bash
# pounce: name = Audio Devices
# pounce: description = Switch sound output & input
# pounce: icon = hifispeaker
# pounce: submenu = true
# pounce: mutates = true

# Audio device switcher.
# Needs SwitchAudioSource:  brew install switchaudio-osx

# External tools may live in Homebrew (solo installs) or a Nix profile
# (haus); the daemon inherits launchd's bare PATH with neither. Prepend
# every common package-manager bindir that exists so the tool resolves however
# pounce was installed.
for _d in /opt/homebrew/bin /usr/local/bin /run/current-system/sw/bin \
          "$HOME/.nix-profile/bin" "/etc/profiles/per-user/${USER:-$(id -un)}/bin"; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH; unset _d

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
        "$_bin" send --kind "${2:-note}" "${_sym[@]}" --source pounce.audio --title "Audio Devices" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote used to end the
    # AppleScript string early, which is why callers here stripped them.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Audio Devices" >/dev/null 2>&1
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    printf 'SwitchAudioSource not found\tbrew install switchaudio-osx\texclamationmark.triangle' \
        | pounce -p "Audio Devices" -i "hifispeaker" >/dev/null
    exit 0
fi

current_out=$(SwitchAudioSource -c -t output 2>/dev/null)
current_in=$(SwitchAudioSource -c -t input 2>/dev/null)

list=""
add() { # add <line> — append a tab-separated row
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    if [[ "$dev" == "$current_out" ]]; then
        add "$dev"$'\t'"✓ Current output"$'\t'"speaker.wave.2.fill"$'\t\t'"Output"
    else
        add "$dev"$'\t\t'"speaker.wave.2"$'\t\t'"Output"
    fi
done < <(SwitchAudioSource -a -t output 2>/dev/null)

while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    if [[ "$dev" == "$current_in" ]]; then
        add "$dev"$'\t'"✓ Current input"$'\t'"mic.fill"$'\t\t'"Input"
    else
        add "$dev"$'\t\t'"mic"$'\t\t'"Input"
    fi
done < <(SwitchAudioSource -a -t input 2>/dev/null)

if [[ -z "$list" ]]; then
    printf 'No audio devices found\t\texclamationmark.triangle' \
        | pounce -p "Audio Devices" -i "hifispeaker" >/dev/null
    exit 0
fi

selected=$(printf '%s\n' "$list" | pounce -p "Audio Devices" -i "hifispeaker")
[[ -z "$selected" ]] && exit 0

# Result: action \t title \t subtitle \t icon \t actions \t group
dev=$(printf '%s' "$selected" | cut -f2)
group=$(printf '%s' "$selected" | cut -f6)

kind="output"
[[ "$group" == "Input" ]] && kind="input"

if SwitchAudioSource -t "$kind" -s "$dev" >/dev/null 2>&1; then
    notify "Now using $dev for $kind"
else
    notify "Could not switch $kind to $dev" fault exclamationmark.triangle
fi
