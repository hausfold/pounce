#!/bin/bash
# pounce: name = Update Pounce
# pounce: description = Update to the latest release
# pounce: icon = arrow.down.circle
# pounce: mutates = true
# pounce: confirm = true
# pounce: network = true

# One-tap self-update for the two non-haus installs (Nix users update via
# their flake, so this bails for them; see the guards):
#
#   brew    brew update && brew upgrade pounce && brew services restart pounce
#   direct  Pounce.app dragged to /Applications from the release download —
#           fetch the latest release tarball, verify its signature, swap the
#           app in place, bounce the daemon. The Developer ID normally keeps
#           TCC stable; the one-time com.local.pounce -> com.hausfold.pounce
#           bundle-ID migration is the deliberate exception and needs a fresh
#           Accessibility approval after the update.
#
# Both run silently in the background with progress via notifications.

# `brew` lives in Homebrew's bindir (/opt/homebrew/bin on Apple Silicon,
# /usr/local/bin on Intel); the daemon inherits launchd's bare PATH without it.
for _d in /opt/homebrew/bin /usr/local/bin /run/current-system/sw/bin \
          "$HOME/.nix-profile/bin" "/etc/profiles/per-user/${USER:-$(id -un)}/bin"; do
    [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
export PATH; unset _d

REPO="hausfold/pounce"
AGENT_LABEL="com.hausfold.pounce.daemon"

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
        "$_bin" send --kind "${2:-note}" "${_sym[@]}" --source pounce.update --title "Update Pounce" --body "$1" \
            >/dev/null 2>&1 && return 0
        break
    done
    # `argv`, not interpolation: a body carrying a double quote used to end the
    # AppleScript string early, which is why callers here stripped them.
    osascript -e 'on run argv
          display notification (item 1 of argv) with title (item 2 of argv)
        end run' -- "$1" "Update Pounce" >/dev/null 2>&1
}

# Resolve the latest release tag from the /releases/latest redirect — no JSON,
# no API quota, nothing to parse but a URL (jq and python3 aren't guaranteed on
# a stock Mac).
latest_tag() {
    local url
    url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" || return 1
    case "$url" in
        */releases/tag/*) printf '%s\n' "${url##*/}" ;;
        *) return 1 ;;
    esac
}

# ── detached worker ──────────────────────────────────────────────────────────
# The foreground re-execs this script as `--run <mode>` inside a fresh session
# (see the perl/setsid line below), so this branch runs in its OWN process
# group, divorced from the pounce daemon that launched us. That divorce is
# load-bearing: both modes end by bouncing that daemon, and launchd SIGKILLs the
# job's whole process group on stop — a worker still in that group would be
# killed after the "stop" and before the "start", leaving the service down. Out
# of the group, we survive the restart and fire the closing notification.
if [ "$1" = "--run" ]; then
    MODE="$2"

    if [ "$MODE" = "brew" ]; then
        if brew update && brew upgrade pounce; then
            brew services restart pounce
            notify "Pounce is up to date ✅"
        else
            notify "Update failed — run 'brew upgrade pounce' in a terminal to see why." fault exclamationmark.triangle
        fi
        exit 0
    fi

    # direct: $3 is the absolute path of the installed Pounce.app.
    APP="$3"
    TAG="$(latest_tag)" || { notify "Couldn't reach GitHub to check for updates."; exit 0; }
    CURRENT="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null)"
    if [ "v$CURRENT" = "$TAG" ]; then
        notify "Pounce $CURRENT is already the latest ✅"
        exit 0
    fi

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    if ! curl -fsSL --retry 3 -o "$WORK/pounce.tar.gz" \
        "https://github.com/$REPO/releases/download/$TAG/pounce-$TAG-macos.tar.gz"; then
        notify "Download failed — see github.com/$REPO/releases" fault exclamationmark.triangle
        exit 0
    fi
    tar -xzf "$WORK/pounce.tar.gz" -C "$WORK"
    NEW_APP="$WORK/pounce-$TAG/Pounce.app"
    # Only swap in what Apple would let launch: a bit-rotted or tampered
    # download must fail HERE, not as a corrupt palette after the swap.
    if [ ! -d "$NEW_APP" ] || ! /usr/bin/codesign --verify --deep --strict "$NEW_APP" 2>/dev/null; then
        notify "Downloaded app failed verification — keeping $CURRENT." fault exclamationmark.triangle
        exit 0
    fi

    # Swap with a rollback path: the old app moves aside, not away, until the
    # new one is in place.
    OLD="$WORK/Pounce.app.old"
    if ! mv "$APP" "$OLD" || ! mv "$NEW_APP" "$APP"; then
        [ -d "$OLD" ] && [ ! -d "$APP" ] && mv "$OLD" "$APP"
        notify "Couldn't replace $APP — is it in a write-protected folder?"
        exit 0
    fi

    # Bounce the daemon so the new binary takes over. kickstart handles the
    # launchd-managed case (the self-registered login item) in place; without an
    # agent, kill the old daemon and relaunch the app — its Finder-launch path
    # (AppLaunchMode) boots the daemon and re-offers the login item.
    if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL"
    else
        pkill -f 'Pounce.app/Contents/MacOS/pounce --daemon' 2>/dev/null
        sleep 1
        open -g "$APP"
    fi
    notify "Pounce updated to ${TAG#v} ✅"
    exit 0
fi

# ── foreground: pick a mode, hand off to the worker, return fast ─────────────

if command -v brew >/dev/null 2>&1 && brew list --formula pounce >/dev/null 2>&1; then
    MODE=(brew)
else
    # Not a brew install. A direct (drag) install is a real Pounce.app at a
    # standard location that is NOT the Nix store or haus's re-signed copy
    # (~/.local/state/pounce) behind a symlink — those update via the flake.
    APP=""
    for cand in "/Applications/Pounce.app" "$HOME/Applications/Pounce.app"; do
        [ -d "$cand" ] || continue
        real="$(readlink -f "$cand" 2>/dev/null || printf '%s' "$cand")"
        case "$real" in
            /nix/store/*|"$HOME/.local/state/pounce/"*) continue ;;
        esac
        APP="$cand"; break
    done
    if [ -z "$APP" ]; then
        # Keep this wording in step with InstallKind.actionHint (UpdateCheck.swift):
        # the daemon's pinned nudge names the same command, and the `.rice` cohort's
        # is `haus update` — "bench ship / rebuild" is the workshop's own verb,
        # not something an end user of haus has ever run.
        if [ -d "$HOME/.local/state/pounce" ]; then
            notify "Pounce comes from the haus desktop — run 'haus update' to pick up the new version."
        else
            notify "Pounce is managed by Nix here — update your pounce flake input to pick up the new version."
        fi
        exit 0
    fi
    MODE=(direct "$APP")
fi

# Launch the worker in a new session (POSIX::setsid) so it outlives the daemon
# restart, with stdio fully detached. /usr/bin/perl ships with every macOS, so
# this needs nothing installed and no `setsid` binary (macOS has none). Then
# notify and return — the palette closes at once and the upgrade churns unseen.
/usr/bin/perl -e 'use POSIX qw(setsid); setsid(); exec("/bin/bash", @ARGV)' "$0" --run "${MODE[@]}" \
    >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true
notify "Updating Pounce in the background… you'll get a notification when it's done."
exit 0
