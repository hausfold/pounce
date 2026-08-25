#!/bin/bash
# pounce: name = Bluetooth
# pounce: description = Connect & disconnect devices
# pounce: icon = wave.3.right
# pounce: submenu = true

# Bluetooth device picker (AirPods, keyboards, controllers, …).
# Needs blueutil:  brew install blueutil

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
        "$_bin" send --kind "${2:-note}" "${_sym[@]}" --source pounce.bluetooth --title "Bluetooth" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote used to end the
    # AppleScript string early, which is why callers here stripped them.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Bluetooth" >/dev/null 2>&1
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if ! command -v blueutil >/dev/null 2>&1; then
    printf 'blueutil not found\tbrew install blueutil\texclamationmark.triangle' \
        | pounce -p "Bluetooth" -i "wave.3.right" >/dev/null
    exit 0
fi

if [[ "$(blueutil --power 2>/dev/null)" == "0" ]]; then
    selected=$(printf 'Turn Bluetooth On\tBluetooth is currently off\twave.3.right' \
        | pounce -p "Bluetooth" -i "wave.3.right")
    if [[ -n "$selected" ]]; then
        blueutil --power 1
        notify "Bluetooth turned on"
    fi
    exit 0
fi

devicon() { # guess an SF Symbol from the device name
    case "$1" in
        *[Aa]ir[Pp]ods*|*[Bb]uds*) echo "airpods" ;;
        *[Hh]eadphone*|*WH-*)      echo "headphones" ;;
        *[Kk]eyboard*)             echo "keyboard" ;;
        *[Mm]ouse*)                echo "magicmouse" ;;
        *[Ss]peaker*)              echo "hifispeaker" ;;
        *[Cc]ontroller*|*Xbox*)    echo "gamecontroller" ;;
        *)                         echo "wave.3.right" ;;
    esac
}

list=""
add() {
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

# blueutil --paired lines look like:
#   address: 12-34-56-78-9a-bc, connected (-60 dBm), not favourite, paired, name: "Buds", ...
while IFS= read -r line; do
    [[ "$line" != address:* ]] && continue
    addr="${line#address: }"; addr="${addr%%,*}"
    name=$(printf '%s' "$line" | sed -En 's/.*name: "([^"]*)".*/\1/p')
    [[ -z "$name" ]] && name="$addr"
    # The MAC rides along as a hidden trailing field; the UI ignores fields
    # past `group` but echoes the full line back on selection.
    if [[ "$line" == *", not connected,"* ]]; then
        add "$name"$'\t'"Not connected"$'\t'"$(devicon "$name")"$'\t'"Connect"$'\t'"Devices"$'\t'"$addr"
    else
        add "$name"$'\t'"✓ Connected"$'\t'"$(devicon "$name")"$'\t'"Disconnect"$'\t'"Devices"$'\t'"$addr"
    fi
done < <(blueutil --paired 2>/dev/null)

# Power is on but no devices listed: blueutil enumerates nothing when the
# calling app (here: the pounce daemon) lacks the Bluetooth TCC grant — and
# its classic-API denial is silent. Raise the real system prompt through
# CoreBluetooth (older binaries lack the flag, hence the --help probe), then
# rebuild the list; if that can't help, point at the Settings pane.
if [[ -z "$list" ]]; then
    if [[ -z "${POUNCE_BT_REQUESTED:-}" ]] && pounce --help 2>/dev/null | grep -q -- --request-bluetooth \
        && pounce --request-bluetooth >/dev/null 2>&1; then
        POUNCE_BT_REQUESTED=1 exec "$0" "$@"
    fi
    selected=$(printf 'No devices found\tIf devices are paired, grant Pounce Bluetooth access\tlock.shield' \
        | pounce -p "Bluetooth" -i "wave.3.right")
    [[ -n "$selected" ]] && open "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
    exit 0
fi

add "Turn Bluetooth Off"$'\t\t'"power"$'\t\t'"Power"

selected=$(printf '%s\n' "$list" | pounce -p "Bluetooth" -i "wave.3.right")
[[ -z "$selected" ]] && exit 0

# Result: action \t title \t subtitle \t icon \t actions \t group \t addr
name=$(printf '%s' "$selected" | cut -f2)
status=$(printf '%s' "$selected" | cut -f3)
addr=$(printf '%s' "$selected" | cut -f7)

if [[ "$name" == "Turn Bluetooth Off" ]]; then
    blueutil --power 0
    notify "Bluetooth turned off"
    exit 0
fi

if [[ "$status" == "✓ Connected" ]]; then
    if blueutil --disconnect "$addr" 2>/dev/null; then
        notify "Disconnected $name"
    else
        notify "Could not disconnect $name" fault exclamationmark.triangle
    fi
else
    notify "Connecting to $name…"
    if blueutil --connect "$addr" 2>/dev/null; then
        notify "Connected $name"
    else
        notify "Could not connect $name — is it in range?" fault exclamationmark.triangle
    fi
fi
