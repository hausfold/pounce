#!/bin/bash
# pounce: name = Docker
# pounce: description = Start, stop & inspect containers
# pounce: icon = shippingbox.fill
# pounce: submenu = true

# Container picker for the docker CLI — works with any engine that answers
# `docker ps` (Docker Desktop, OrbStack, colima, …).

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
        "$_bin" send --kind "${2:-note}" "${_sym[@]}" --source pounce.docker --title "Docker" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote used to end the
    # AppleScript string early, which is why callers here stripped them.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Docker" >/dev/null 2>&1
}

# Guards answer through pounce, not a notification: for a submenu command the
# palette is already showing a loading panel, and only a pounce call fills it.
if ! command -v docker >/dev/null 2>&1; then
    printf 'docker not found\tInstall Docker Desktop, OrbStack or colima\texclamationmark.triangle' \
        | pounce -p "Docker" -i "shippingbox.fill" >/dev/null
    exit 0
fi

if ! docker info >/dev/null 2>&1; then
    selected=$(printf 'Start Docker\tThe engine is not running\tplay.circle' \
        | pounce -p "Docker" -i "shippingbox.fill")
    if [[ -n "$selected" ]]; then
        open -a "Docker" 2>/dev/null || open -a "OrbStack" 2>/dev/null \
            || notify "Could not find Docker Desktop or OrbStack to open" fault exclamationmark.triangle
    fi
    exit 0
fi

list=""
add() {
    if [[ -n "$list" ]]; then list="$list"$'\n'"$1"; else list="$1"; fi
}

while IFS=$'\t' read -r name state image; do
    [[ -z "$name" ]] && continue
    case "$state" in
        running)
            add "$name"$'\t'"Running · $image"$'\t'"play.fill"$'\t'"Stop|cmd:Restart|opt:Logs"
            ;;
        paused)
            add "$name"$'\t'"Paused · $image"$'\t'"pause.fill"$'\t'"Unpause|cmd:Stop|opt:Logs"
            ;;
        *)
            add "$name"$'\t'"${state} · $image"$'\t'"stop.fill"$'\t'"Start|cmd:Remove|opt:Logs"
            ;;
    esac
done < <(docker ps -a --format '{{.Names}}\t{{.State}}\t{{.Image}}' 2>/dev/null)

if [[ -z "$list" ]]; then
    printf 'No containers\tThe engine is running — nothing to manage yet\tshippingbox' \
        | pounce -p "Docker" -i "shippingbox.fill" >/dev/null
    exit 0
fi

result=$(printf '%s\n' "$list" | pounce -p "Docker Containers" -i "shippingbox.fill")
[[ -z "$result" ]] && exit 0

# Result: action \t name \t subtitle \t icon \t actions
action=$(printf '%s' "$result" | cut -f1)
name=$(printf '%s' "$result" | cut -f2)
state=$(printf '%s' "$result" | cut -f3)

show_logs() {
    local f="${TMPDIR:-/tmp}/pounce-docker-${name}.log"
    docker logs --tail 500 "$name" >"$f" 2>&1
    open -a "Console" "$f" 2>/dev/null || open "$f"
}

case "$action" in
    enter)
        case "$state" in
            Running*)
                docker stop "$name" >/dev/null 2>&1 && notify "Stopped $name"
                ;;
            Paused*)
                docker unpause "$name" >/dev/null 2>&1 && notify "Unpaused $name"
                ;;
            *)
                if docker start "$name" >/dev/null 2>&1; then
                    notify "Started $name"
                else
                    notify "Could not start $name" fault exclamationmark.triangle
                fi
                ;;
        esac
        ;;
    cmd)
        case "$state" in
            Running*)
                docker restart "$name" >/dev/null 2>&1 && notify "Restarted $name"
                ;;
            Paused*)
                docker stop "$name" >/dev/null 2>&1 && notify "Stopped $name"
                ;;
            *)
                response=$(osascript -e "display dialog \"Remove container ${name//\"/}?\" buttons {\"Cancel\", \"Remove\"} default button \"Cancel\"" 2>/dev/null)
                if [[ "$response" == *"Remove"* ]]; then
                    docker rm "$name" >/dev/null 2>&1 && notify "Removed $name"
                fi
                ;;
        esac
        ;;
    opt)
        show_logs
        ;;
esac
