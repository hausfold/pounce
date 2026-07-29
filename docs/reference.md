# pounce reference

Everything that used to crowd the README. `pounce --help` remains the
authoritative flag list; this is the prose version.

## CLI flags

| flag | meaning |
|------|---------|
| `-p <prompt>` | placeholder / prompt text |
| `-i <sf-symbol>` | prompt icon (an SF Symbol name) |
| `--launcher` | also enumerate & rank installed apps, and launch them natively |
| `--max-empty <n>` | how many rows to show before the user types |
| `--clipboard` / `--emoji` / `--screenshots` / `--camera` | the built-in native modes |
| `--cheatsheet [path]` | overlay a cheatsheet (JSON) |
| `--transform '<filter>'` | act on the current selection: copy it (⌘C), pipe the text through the shell `<filter>`, paste back (⌘V) — e.g. `--transform 'tr "[:lower:]" "[:upper:]"'`. Forwarded to the daemon, which holds the grant. |
| `focus <op>` | Focus/DND (hush): `focus status\|toggle\|on\|off`, forwarded to the daemon |
| `--copy-file <path>` | copy a file (contents) to the clipboard |
| `--daemon` | run the resident daemon (what `launchd` starts; also hosts the ⌘Tab window switcher) |
| `--request-accessibility` / `--check-accessibility` | manage the Accessibility (TCC) grant |
| `--request-bluetooth` / `--check-bluetooth` | manage the Bluetooth (TCC) grant |
| `--version` | print the version |
| `-h`, `--help` | usage (the full flag list) |

## Accessibility (one-time)

Pounce needs Accessibility to place its window and read the frontmost app.

```sh
pounce --request-accessibility   # approve the prompt
pounce --check-accessibility     # prints: true
```

**On rebuilds:** a Nix store build is ad-hoc signed, so its code signature
changes every rebuild and macOS silently drops the Accessibility grant. If you
run pounce as a launch agent from Nix, copy the app to a stable path and re-sign
it with a consistent identity once, then point the agent there. See
[`nebelhaus`](https://github.com/nebelhaus/nebelhaus) for a working `launchd`
wrapper that does exactly this. The Homebrew build is Developer ID signed and
does not have this problem.

## Updating

Run **Update Pounce** from the palette — it runs `brew update && brew upgrade
pounce && brew services restart pounce` in the background and notifies you when
it's done. The command no-ops with a hint on non-Homebrew installs.

## Quick answers (inline calculator)

Type an expression-shaped query into the launcher and pounce answers it right in
the palette — pinned as the first row — instead of fuzzy-matching it against your
apps. There's no trigger prefix: a query either parses as an answer or it stays
an ordinary search. Hit ⏎ to copy the result.

| you type | you get |
|----------|---------|
| `2*847` | **1,694** — arithmetic, parentheses, `pi`/`tau`, functions |
| `72 f in c` | **22.2 °C** — units (length, mass, temperature, …) |
| `100 usd in eur` | live currency, from offline ECB rates |
| `14:00 utc in pst` | timezone conversion |

Currency is the one engine that touches the network: it refreshes European
Central Bank reference rates in the background (pounce's only network call) and
answers from an in-memory cache, so a keystroke never blocks on I/O. It's **off
by default** — enable with `"quickAnswers": { "currency": true }`.

## Writing a command

A command is one self-describing shell script. The metadata lives in a
`# pounce:` comment header, and the palette discovers commands at runtime.

```sh
#!/bin/bash
# pounce: name = Say Hello
# pounce: description = A friendly notification
# pounce: icon = hand.wave
osascript -e 'display notification "🐾" with title "Pounce"'
```

Header keys (all optional — the filename is the fallback name/id):

| key | meaning |
|-----|---------|
| `name` | title shown in the palette |
| `description` | subtitle |
| `icon` | an SF Symbol name |
| `submenu` | `true` if the script re-invokes `pounce` |

### Where commands come from

The palette merges commands from these locations, in order — on a filename clash
the **later one wins**, so you can shadow any built-in by reusing its filename:

1. the built-in set shipped with `pounce-commands` (the "official plugins")
2. directories baked in by Nix consumers:
   `pounce-commands.override { extraCommandDirs = [ ./my-commands ]; }`
3. `$POUNCE_COMMAND_PATH` (colon-separated directories)
4. `~/.config/pounce/commands` — yours, highest precedence

### Submenus (two-step commands)

Set `# pounce: submenu = true` and have your script feed a new list back into
`pounce`. The daemon keeps the window up with a loading state instead of fading
between steps, so it feels like one continuous flow:

```sh
# commands/wifi.sh — pick a network, then join it
network=$(list_networks | pounce -p "WiFi network:")
[ -n "$network" ] && join_network "$network"
```

The batteries-included set (wifi, clipboard, emoji, screenshots, brew-services,
lock, force-quit, …) all live in `commands/` as worked examples — copy one and
go. (The `ports` command is the exception: it ships from `pkgs/pounce/ports`,
installed as `$out/bin/ports`.)

### Optional plugins (off by default)

Beyond the built-in set there's a shelf of optional plugins in
[`pkgs/pounce-commands/optional/`](../pkgs/pounce-commands/optional). They ship
off by default because each assumes a specific tool, service, or app:

| id | what it does | assumes |
|----|--------------|---------|
| `audio` | switch sound output / input device | `brew install switchaudio-osx` |
| `bluetooth` | connect & disconnect paired devices (AirPods…) | `brew install blueutil` |
| `caffeinate` | keep the Mac awake (indefinitely or on a timer) | — (system `caffeinate`) |
| `docker` | start / stop / restart containers, tail logs | a docker engine (Docker Desktop, OrbStack, colima) |
| `github` | jump to your PRs, review requests, issues, repos | `brew install gh` + `gh auth login` |
| `spotify` | play / pause / skip / shuffle, copy song link | Spotify.app |
| `ssh` | pick a host from `~/.ssh/config`, connects (see `$POUNCE_TERMINAL_LAUNCHER`) | hosts in `~/.ssh/config` |
| `tailscale` | connect toggle, copy your / any peer's tailnet IP | Tailscale |

Enable the ones you use by id:

```nix
pounce-commands.override { plugins = [ "docker" "ssh" "tailscale" ]; }
```

An enabled plugin behaves exactly like a built-in — same palette discovery, same
`pounce-<id>` bin for hotkey bindings, still shadowable from your user dir. Not
on Nix? Every plugin is still just one script: copy it into
`~/.config/pounce/commands/`.

## Configuration

Optional settings live in `~/.config/pounce/config.json`. The file is re-read on
every open, so edits apply on the next launch — no restart needed. Every key is
optional and falls back to a default.

```jsonc
{
  "theme": "nebelung",      // "nebelung" (default), "mocha", or a themes/ file
  "windowMode": "default",  // "default" or "compact"
  "hotkey": {
    "enabled": true,        // daemon grabs a global hotkey in-process
    "key": "space",         // "space", "return", "a"…"z", "0"…"9"
    "modifiers": ["cmd"]    // any of "cmd" / "shift" / "opt" / "ctrl"
  },
  "windows": {
    "enabled": false,       // MRU window switcher on ⌘Tab (needs Accessibility)
    "key": "tab",
    "modifiers": ["cmd"]
  },
  "clipboard": {
    "enabled": true,
    "maxEntries": 200,
    "autoPaste": false,     // synthesize ⌘V into the prior app (needs Accessibility)
    "blacklistBundleIds": [] // apps whose copies are never recorded (password managers…)
  },
  "quickAnswers": {
    "currency": false       // enable the currency engine (its only network call)
  },
  "apps": {
    "demoteBundleIds": [],  // apps ranked lower in the launcher (bundle IDs)
    "hideBundleIds": []     // apps hidden from the launcher entirely (bundle IDs)
  }
}
```

The default **nebelung** palette is compiled into the binary straight from the
[nebelung](https://github.com/nebelhaus/nebelung) flake, so it never drifts from
the rest of the theme. Set `"theme": "mocha"` for stock Catppuccin.

Any other `"theme"` value resolves to `~/.config/pounce/themes/<name>.json` — a
flat catppuccin-style `name → "#hex"` map (nebelung's `palette/*.hex.json` files
verbatim), read alongside config.json on each open. So switching to a nebelung
variant, or any palette of your own, needs no rebuild — Nix installs and
Homebrew installs alike:

```sh
mkdir -p ~/.config/pounce/themes
curl -fsSLo ~/.config/pounce/themes/nebelung-latte.json \
  https://raw.githubusercontent.com/nebelhaus/nebelung/main/palette/nebelung-latte.hex.json
# then in config.json:  "theme": "nebelung-latte"
```

Pounce uses these keys: `base`, `surface0`–`surface2`, `text`, `subtext0`,
`overlay0`, `mauve`, `blue`. A file missing any of them (or an unknown name)
falls back to the built-in default. On the nebelhaus rice you never do this by
hand — `nebelhaus.theme.{flavor,contrast}` installs the matching variant and
points `"theme"` at it.

## The hotkey (near-instant open)

When the daemon is running it registers `hotkey` in-process (Carbon
`RegisterEventHotKey`). The keypress lands straight in the already-warm daemon —
no shell, no client spawn, no socket round-trip. This replaces binding ⌘Space to
`pounce-palette` in an external hotkey daemon; if you keep such a binding,
disable it (or set `"hotkey": { "enabled": false }`) so the combo doesn't fire
twice.

For the daemon to serve commands on that path it discovers them from its **own
environment** — the same contract `pounce-palette` uses, so the launch agent that
starts the daemon should export them:

| var | meaning |
|---|---|
| `POUNCE_BUILTIN_DIR` | the built-in command set |
| `POUNCE_EXTRA_COMMAND_DIRS` | colon-separated dirs a packager layers on |
| `POUNCE_COMMAND_PATH` | colon-separated dirs for ad-hoc layering |

`~/.config/pounce/commands` is always searched last (highest precedence). When
the launch agent exports none of these (e.g. the Homebrew service), the daemon
falls back to `<prefix>/share/pounce/commands` derived from its own binary — so
the built-in commands still appear.

### When the hotkey is swallowed

The case that actually bites is quieter, and comes in two flavours — both of
which `RegisterEventHotKey` *succeeds* on, so the daemon holds a registration it
never receives a press for:

- **A macOS shortcut owns the combo** — Spotlight on ⌘Space is the classic. At
  startup the daemon reads `com.apple.symbolichotkeys`, names the colliding
  shortcut, and warns: free the key in System Settings → Keyboard → Keyboard
  Shortcuts, then restart pounce.
- **An external hotkey tool owns the combo** — skhd, AeroSpace, or Raycast bound
  to the same key runs its own event tap *ahead* of Carbon, so it wins the press
  (and, if it's bound to `pounce-palette`, spawns a slow client every summon
  while the fast in-process path sits idle). The daemon logs a hint naming the
  likely culprit when it's asked to open the launcher over the socket while its
  own hotkey has never fired.

The daemon also logs the hotkey's **first press**, so a swallowed hotkey is
distinguishable from a working one in the log. `pounce doctor` rolls all of this
into one command — run it first whenever the palette is slow to open or doesn't
respond to the key.

## The window switcher (⌘Tab, opt-in)

With `"windows": { "enabled": true }` the daemon replaces the stock ⌘Tab app
switcher with an MRU **window** switcher:

- **⌘⇥, release** — toggle straight to the last window you were in, even on
  another workspace. No HUD, no ceremony.
- **hold ⌘, keep tapping ⇥** — walk every window, most-recently-used first
  (⌘⇧⇥ walks backwards; ↑/↓ also move).
- **hold ⌘ and type** — fuzzy-filter the list, ranked by frecency. ↵ commits, ⎋
  cancels, releasing ⌘ always lands on the selection.

macOS doesn't let ⌘Tab be rebound — the daemon takes it with an event tap, which
the system gates behind the **Accessibility** grant. Without the grant (or during
Secure Input, e.g. password fields) the tap stands down and stock ⌘Tab keeps
working, so enabling this can never leave you unable to switch windows. Grant
Accessibility while the daemon is running and the switcher arms itself within a
couple of seconds — no restart; revoke it and the tap drops live. Flipping
`windows.enabled` itself does need a daemon restart.

Running [AeroSpace](https://github.com/nikitabobko/AeroSpace)? Each row gets a
workspace badge, and focusing goes through `aerospace focus --window-id` so a
window parked on another workspace surfaces correctly — that's the pairing the
[nebelhaus](https://nebelhaus.com) rice ships enabled.

## Building from source

```sh
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

Building from source needs the **Xcode Command Line Tools** — that path compiles
against the system Swift toolchain via `xcrun` (`xcode-select --install`).

Hacking on pounce as part of the wider rice? The
[workshop](https://github.com/nebelhaus/workshop)'s `bench try` rebuilds a whole
nebelhaus machine against your local checkout, uncommitted edits included.
