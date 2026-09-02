#!/bin/bash
# pounce: name = Brew Services
# pounce: description = Start/Stop/Restart services
# pounce: icon = shippingbox
# pounce: submenu = true
# pounce: mutates = true

# Brew Services Manager
# Lists all brew services with status and allows start/stop/restart

# `brew` lives in Homebrew's bindir (/opt/homebrew/bin on Apple Silicon,
# /usr/local/bin on Intel); the daemon inherits launchd's bare PATH without it,
# so `brew` fails to resolve and this menu comes up empty (stuck on the loading
# skeleton). Prepend every common package-manager bindir that exists — same
# idiom the optional plugins use.
for _d in /opt/homebrew/bin /usr/local/bin /run/current-system/sw/bin \
          "$HOME/.nix-profile/bin" "/etc/profiles/per-user/${USER:-$(id -un)}/bin"; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH; unset _d

# Get list of services with status
get_services() {
    brew services list 2>/dev/null | tail -n +2 | while read -r line; do
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')

        [[ -z "$name" ]] && continue

        # Determine icon and actions based on status
        case "$status" in
            started|running)
                icon="checkmark.circle.fill"
                subtitle="Running"
                # Running: default=Stop, cmd=Restart, opt=Open logs
                actions="Stop|cmd:Restart"
                ;;
            stopped|none|"")
                icon="circle"
                subtitle="Stopped"
                # Stopped: default=Start, cmd=Remove
                actions="Start|cmd:Uninstall"
                ;;
            error)
                icon="exclamationmark.circle.fill"
                subtitle="Error"
                actions="Restart|cmd:Stop|opt:View Logs"
                ;;
            *)
                icon="questionmark.circle"
                subtitle="$status"
                actions="Start|cmd:Stop|opt:Restart"
                ;;
        esac

        echo -e "${name}\t${subtitle}\t${icon}\t${actions}"
    done
}

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
        "$_bin" send --kind "${2:-note}" "${_sym[@]}" --source pounce.brew-services --title "Brew Services" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote would end the
    # AppleScript string early.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Brew Services" >/dev/null 2>&1
}

# Show the picker
services=$(get_services)

if [[ -z "$services" ]]; then
    notify "No brew services found"
    exit 0
fi

# Run pounce and capture output (format: action\traw_line)
result=$(echo "$services" | pounce -p "Brew Services" -i "shippingbox")

if [[ -z "$result" ]]; then
    exit 0
fi

# Parse the result
action=$(echo "$result" | cut -f1)
service_line=$(echo "$result" | cut -f2-)
service_name=$(echo "$service_line" | cut -f1)
current_status=$(echo "$service_line" | cut -f2)

# Execute the action
case "$action" in
    enter)
        # Default action based on status
        if [[ "$current_status" == "Running" ]]; then
            brew services stop "$service_name"
            notify "Stopped $service_name"
        else
            brew services start "$service_name"
            notify "Started $service_name"
        fi
        ;;
    cmd)
        # Cmd action: Restart if running, Uninstall if stopped
        if [[ "$current_status" == "Running" ]]; then
            brew services restart "$service_name"
            notify "Restarted $service_name"
        else
            # Confirm before uninstalling
            response=$(osascript -e "display dialog \"Uninstall $service_name?\" buttons {\"Cancel\", \"Uninstall\"} default button \"Cancel\"" 2>/dev/null)
            if [[ "$response" == *"Uninstall"* ]]; then
                brew uninstall "$service_name"
                notify "Uninstalled $service_name"
            fi
        fi
        ;;
    opt)
        # Option action: View logs
        log_path="/opt/homebrew/var/log/${service_name}"
        if [[ -d "$log_path" ]]; then
            open "$log_path"
        else
            # Try common log locations
            log_file=$(find /opt/homebrew/var/log -name "*${service_name}*" -type f 2>/dev/null | head -1)
            if [[ -n "$log_file" ]]; then
                open -a "Console" "$log_file"
            else
                notify "No logs found for $service_name"
            fi
        fi
        ;;
    ctrl)
        # Ctrl action: Show info
        brew info "$service_name"
        ;;
esac
