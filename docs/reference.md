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
| `--chain [keys]` | these free-text commits feed another `pounce` step — hold the window up with the loading skeleton instead of fading out. Comma-separated actions, default `enter`. See [Submenus](#submenus-two-step-commands) |
| `--actions <spec>` | label the action bar for a step that shows no rows: `"Spawn\|shift:New line\|cmd:Screenshot\|opt:Drafts"`. See [A step that asks for a paragraph](#a-step-that-asks-for-a-paragraph) |
| `--draft <key>` | keep the typed text on Esc / click-away, filed under `<key>`. See [A step that asks for a paragraph](#a-step-that-asks-for-a-paragraph) |
| `drafts <key> <op>` | read back what `--draft` kept: `save` (stdin) / `list` / `get <i>` / `rm <i>` / `clear` |
| `--cheatsheet [path]` | overlay a cheatsheet (JSON) |
| `--transform '<filter>'` | act on the current selection: copy it (⌘C), pipe the text through the shell `<filter>`, paste back (⌘V) — e.g. `--transform 'tr "[:lower:]" "[:upper:]"'`. Forwarded to the daemon, which holds the grant. |
| `focus <op>` | Focus/DND (hush): `focus status\|toggle\|on\|off`, forwarded to the daemon |
| `run <item-key>` | run one item by the key `items` uses — `cmd:emoji`, `mode:clipboard`, `app:/Applications/Foo.app`. **Also how the built-in windows are opened**: `mode:clipboard` / `mode:emoji` / `mode:screenshots` / `mode:camera` / `mode:filesearch` / `mode:launcher` (they had a flag each until 2026-07-30). For binders that already own the keystroke; see [Driving pounce from another binder](#driving-pounce-from-another-binder) |
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

Run **Update Pounce** from the palette to self-update in place. What it does
depends on how Pounce was installed: a Homebrew build runs `brew update && brew
upgrade pounce && brew services restart pounce`; a copy dragged to
`/Applications` downloads the latest release, verifies its signature, and swaps
the app in place (the Developer ID matches on both sides, so the Accessibility
grant survives). A Nix or nebelhaus-rice install updates through the store
instead, so the command no-ops there with a hint to run `haus update` or bump
your flake input. Either way it runs in the background and reports via
notifications.

Staying current is nudged, never automatic: the daemon checks for a new release
hourly, and while one is pending *Update Pounce* is renamed with the new version
and pinned to the palette's first row (`⌘⏎` on that row skips the version). Set
`"updates": { "check": false }` in `config.json` to turn the check off.

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
answers from an in-memory cache, so a keystroke never blocks on I/O. It's **on
by default** — set `"quickAnswers": { "currency": false }` (and
`"updates": { "check": false }`) for a pounce that makes no network requests at
all.

## The emoji picker (emoji + symbols)

`mode:emoji` opens one grid over two datasets: the emoji set, and a curated set
of plain-text Unicode **symbols** — the mac modifier keys, arrows, math,
typography, currency, box drawing.

| you type | you get |
|----------|---------|
| `command` | ⌘ &nbsp;(also `option` ⌥, `shift` ⇧, `control` ⌃, `escape` ⎋, `delete` ⌫, `tab` ⇥) |
| `arrow` | ← → ⇐ ⇒ ⟶ ⇄ ↻ … alongside the emoji arrows |
| `em dash` | — &nbsp;(and `ellipsis` …, `bullet` •, `interrobang` ‽) |
| `not equal` | ≠ &nbsp;(and `approximately` ≈, `infinity` ∞, `sum` ∑, `degree` °) |
| `sparkline` | ▁▂▃▄▅▆▇█ |

They're **ordinary characters**, not icon-font glyphs — ⌘ is `U+2318`, so it
pastes into Slack, a browser, or a commit message and survives. (SF Symbols
would be private-use glyphs that render as tofu outside Apple apps; that's why
this is a codepoint dataset. SF Symbols stay what they are elsewhere in pounce:
the `icon =` for a command's row.) The footer shows the selected symbol's
codepoint.

One picker, not two, because the point is *not* having to know which set holds
the thing you want — you type the word and it's there. The mode is still named
`emoji`, so `mode:emoji` / `cmd:emoji` keys and hotkeys are unchanged.

With an empty query the grid is the emoji browse grid it has always been;
symbols appear there once you've used one, floated in by the same frecency that
ranks emoji. ⏎ copies (and auto-pastes, with `clipboard.autoPaste` and the
Accessibility grant) exactly like emoji.

## Writing a command

A command is one self-describing shell script. The metadata lives in a
`# pounce:` comment header, and the palette discovers commands at runtime.
Command filenames must end in `.sh`; other files in a command directory are
treated as support data and are not shown in the launcher.

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
# commands/brew-services.sh — pick a service, then toggle it
service=$(list_services | pounce -p "Service:")
[ -n "$service" ] && toggle_service "$service"
```

**Piped lists keep your order.** The launcher sorts its own apps and commands by
title, because their input order is meaningless. A list you pipe in is the
opposite — you already ranked it — so pounce shows it in the order you gave
(frecency still floats rows the user has picked before). Want it alphabetical?
`sort` it yourself.

**A prompt whose Enter starts a search: `--chain`.** When nothing in the list
matches what the user typed, Enter hands the raw text back as `enter\t<text>`.
A script that answers that by *searching* — hitting the network, shelling out —
leaves a gap: the window fades out while the search runs, then a new one fades
in. `--chain` says "my next act is another `pounce`", so that commit holds the
window with the loading skeleton and step 2 swaps straight in:

```sh
# ask for a query, search, show the hits — no fade between the three
query=$(printf '' | pounce --chain -p "App Store — type a search, then Enter" | cut -f2)
search_the_store "$query" | pounce -p "App Store — results"
```

Only free-text commits change; picking a row still lingers, since a row's
follow-up is just as often a terminal action. If step 2 never arrives the window
fades out on its own after a few seconds, so a `--chain` prompt can't wedge it.

`--chain` takes an optional comma-separated action list (`--chain enter,opt`),
because a step can chain on one Return and not another: `⌥↵ "show my drafts"` is
another palette and should hold the window, while `⌘↵ "let me drag out a
screenshot"` needs the palette *off* the screen first. Bare `--chain` means
`enter`, which is what it always meant.

### A step that asks for a paragraph

A picker step whose answer is a sentence — "what should the agent do?" — is a
different animal from one that filters a list, and three flags exist for it.

**Several verbs on one box.** Return on text that matched no row hands it back as
`<action>\t<text>`, where the action is `enter` / `cmd` / `opt` / `ctrl` — the
same shape a row commit uses. So one prompt can offer more than one thing to do
with what was typed. `--actions` labels them in the action bar, which is
otherwise drawn only for a selected row, i.e. never on a step with no rows:

```sh
sel=$(printf '' | pounce --chain enter,opt --draft my-prompt \
        --actions "Go|shift:New line|cmd:With a screenshot|opt:Drafts" \
        -p "What should it do?")
case "$(printf '%s' "$sel" | cut -f1)" in
  enter) go   "$(printf '%s' "$sel" | cut -f2-)" ;;
  cmd)   shot "$(printf '%s' "$sel" | cut -f2-)" ;;
  opt)   show_drafts ;;
esac
```

**Writing more than one line.** ⇧↵ inserts a newline (plain ↵ still commits), and
the box grows with the text up to half the screen. `shift:` in an `--actions`
spec is a label only — it renders `⇧↵` in the bar and is never delivered as an
action.

**Not losing it.** The palette dismisses on Esc and on a click into any other
app, which is right for "pick a row" and unforgiving for "type a paragraph".
`--draft <key>` files the query under `<key>` on every dismissal that isn't a
commit, and Esc clears the box before a second Esc dismisses it. Read them back
with `pounce drafts`:

```sh
pounce drafts my-prompt list          # 0<TAB>one-line preview<TAB>4m ago
pounce drafts my-prompt get 0         # the full text, newlines intact
printf '%s' "$text" | pounce drafts my-prompt save
pounce drafts my-prompt rm 0
pounce drafts my-prompt clear
```

`list` is guaranteed one line per draft (previews are whitespace-folded), so a
`while read` loop over it is safe; `get` is what hands back the real multi-line
text. Drafts live in `~/.local/state/pounce/drafts/<key>.tsv`, newest first,
capped at 20.

The batteries-included set (clipboard, emoji, screenshots, brew-services,
lock, force-quit, …) all live in `commands/` as worked examples — copy one and
go. (The `ports` command is the exception: it ships from `pkgs/pounce/ports`,
installed as `$out/bin/ports`.)

### System Settings deeplinks

Every macOS System Settings pane is its own top-level palette item — typing
"Displays", "Bluetooth", or "Accessibility" jumps straight to that pane via its
`x-apple.systempreferences:` URL, skipping the Settings window's sidebar
entirely. There is no per-pane script: the commands are generated at build time
from [`pkgs/pounce-commands/settings-panes.tsv`](../pkgs/pounce-commands/settings-panes.tsv),
one row per pane (real ExtensionKit bundle ids, verified against the OS — the
file's header documents how to re-dump the authoritative list on a new macOS).
Like any built-in, a pane command can be shadowed from
`~/.config/pounce/commands` by reusing its filename (`settings-<slug>.sh`).

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
| `perplexity` | type a question → a fresh Perplexity thread in the browser | a browser (and a Perplexity account, for anything beyond the free tier) |
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
every open, so edits apply on the next launch — no restart needed. (The two
exceptions are the things the daemon has to *grab* at startup: `windows` and the
`items` hotkeys.) Every key is optional and falls back to a default.

**Start from a config that documents itself:**

```sh
pounce config init      # writes ~/.config/pounce/config.json
pounce config print     # …or just look at it, touching nothing
```

That writes **every** setting at its default, with a sentence above it, all
commented out — so the file changes nothing until you uncomment a line, and you
make it minimal by deleting the lines you never touched. It never overwrites a
config you already have (it writes `config.json.new` beside it instead; `--force`
replaces). On a machine managed by the nebelhaus rice it refuses outright: that
config.json is generated from `nebelhaus.pounce.*`, and the next rebuild would
put the generated one straight back.

**Comments and trailing commas are fine** — pounce parses config.json as JSON5,
which is what lets you uncomment any subset of lines without fixing up commas by
hand. `//` and `/* */` inside a string value are left alone, so a URL in a
setting is safe. Unknown keys are ignored, so an older pounce never chokes on a
config written by a newer one.

```jsonc
{
  // Omit all three and pounce follows macOS: nebelung dark / nebelung-latte
  // light. Set "theme" alone to PIN one palette. See "Theme" below.
  "theme": "nebelung",      // "nebelung", "mocha", or a themes/ file
  "themeLight": "nebelung-latte",  // used when macOS is in Light Mode
  "themeDark": "nebelung",         // used when macOS is in Dark Mode
  "windowMode": "default",  // "default" or "compact" — the launcher's proportions
  "scale": 1.0,             // 0.8–2.0 — how BIG the whole UI is drawn
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
  "updates": {
    "check": true           // hourly check for a new release — nudge only, never auto-installs
  },
  "apps": {
    "demoteBundleIds": [],  // apps ranked lower in the launcher (bundle IDs)
    "hideBundleIds": []     // apps hidden from the launcher entirely (bundle IDs)
  },
  "items": {}               // per-item enable / alias / hotkey — see below
}
```

### Sizing: `windowMode` and `scale`

Two independent knobs. `windowMode` picks the launcher's *proportions* —
`"compact"` is a narrower window with tighter rows that hides its list until you
type. `scale` picks how *big* the whole thing is drawn: every size in the UI —
text, rows, icons, the emoji grid, clipboard history, Find Files, the cheatsheet —
is multiplied by it. They compose, so a compact launcher at `1.4` is still the
compact layout, just readable from further away.

Sizes are resolved before layout rather than by scaling the rendered window, so
text stays crisp at any value. Out-of-range values are clamped to 0.8–2.0 rather
than rejected: a config asking for `3.0` wants the biggest palette pounce can
draw, and handing it back the smallest would be the opposite of the ask.

Two things adapt on their own so a large scale can't push the window off the
screen: the launcher shows fewer rows when the scaled rows no longer fit under it,
and every panel's width is held inside the visible screen. That matters most on a
Mac that has *also* been set to a lower-resolution "larger text" display mode —
both make things bigger, and they multiply.

On the [nebelhaus](https://github.com/nebelhaus/nebelhaus) rice this is written
for you from `nebelhaus.ui.scale`, so the palette grows with the rest of the
desktop.

The **nebelung** palette and its light counterpart **nebelung-latte** are both
compiled into the binary straight from the
[nebelung](https://github.com/nebelhaus/nebelung) flake, so they never drift from
the rest of the theme. Set `"theme": "mocha"` for stock Catppuccin.

### Following macOS light/dark

`theme` is the fallback for both appearances; `themeLight` and `themeDark`
override it when macOS is in that appearance. The appearance is read on the same
per-open path as config.json, so flipping System Settings shows on your next
summon — no restart.

| you set | Dark Mode | Light Mode |
|---|---|---|
| nothing | `nebelung` | `nebelung-latte` |
| `theme` only | `theme` | `theme` — one theme **pins** it |
| `theme` + `themeLight` | `theme` | `themeLight` |
| `theme` + `themeDark` | `themeDark` | `theme` |

So a zero-config pounce follows the system, and any pair works — not just the
built-ins:

```jsonc
{ "theme": "gruvbox-light", "themeDark": "gruvbox-dark" }
```

Setting one theme and nothing else keeps that theme around the clock, which is
why `"theme": "gruvbox-dark"` never turns pale at noon.

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
falls back to the built-in default. A file also *shadows* a built-in of the same
name, so `themes/nebelung.json` wins over the compiled-in one. On the nebelhaus
rice you never do this by hand — `nebelhaus.theme.{flavor,contrast}` installs the
matching variant and points `"theme"` at it.

The window chrome (blur material, appearance, border, fill opacity) follows the
**palette's** own lightness, not the system's — a light palette in Dark Mode
still renders as a light panel.

### Per-item settings (`items`)

One map covers the three things you'd otherwise want three keys for — hide it,
give it a shorthand, give it a key. Each entry is keyed by an **item key**:

| Item key | What it addresses |
|---|---|
| `cmd:<id>` | a command script, by filename without `.sh` |
| `app:/Applications/Foo.app` | an application, by path |
| `mode:<name>` | a built-in window: `launcher`, `clipboard`, `emoji`, `screenshots`, `camera`, `filesearch` |

```jsonc
{
  "items": {
    "cmd:emoji":                     { "alias": "emo", "hotkey": "opt+e" },
    "cmd:brew-services":             { "enabled": false },
    "app:/Applications/Ghostty.app": { "alias": "term", "hotkey": "opt+t" },
    "mode:clipboard":                { "hotkey": "cmd+shift+v" }
  }
}
```

- **`enabled: false`** drops the row from the launcher. It does *not* disarm that
  item's hotkey — binding a key to something you keep out of the list is a
  legitimate setup. (`apps.hideBundleIds` still works and hides by bundle ID
  instead of path; use whichever you have to hand.)
- **`alias`** is a search shorthand. It matches at a bonus over the item's real
  name, so typing your alias lands on your item rather than on whatever app
  happens to fuzzy-match the same letters.
- **`hotkey`** is a global key that runs the item directly, skipping the palette.
  Written as `"cmd+shift+v"` — the last segment is the key, the rest are
  modifiers (`cmd` / `shift` / `opt` / `ctrl`). The object form
  `{"key": "v", "modifiers": ["cmd","shift"]}` used by the `hotkey` and `windows`
  blocks is accepted here too. Add a **space** for a two-step sequence — see
  below.

`enabled` and `alias` only mean something for things the palette lists, so a
`mode:` entry carries just a hotkey.

### Leader sequences (two-step keys)

Whitespace separates **steps**, `+` separates **modifiers**. So `"opt+space e"`
means press ⌥Space, then E — the notation Emacs and VS Code use:

```jsonc
{
  "items": {
    "cmd:emoji":       { "hotkey": "opt+space e" },
    "mode:clipboard":  { "hotkey": "opt+space c" },
    "cmd:lock":        { "hotkey": "opt+space l" },
    "app:/Applications/Ghostty.app": { "hotkey": "opt+space t" }
  }
}
```

Sequences sharing a leader share it: ⌥Space is registered **once** and owns a map
of next keys. Steps can carry their own modifiers (`"cmd+k cmd+c"`), sequences can
be longer than two (`"opt+space g s"`), and a settings UI can record them as an
array (`["opt+space", "e"]`).

**Why this is the interesting one on a tiling setup:** a leader opens a namespace
that can't collide with the ⌥/⌘ chords AeroSpace has already claimed. And it needs
**no Accessibility grant** — pressing the leader registers its next-step keys as
ordinary global hotkeys for ~2 seconds and releases them the moment one fires, so
there's no event tap and no TCC prompt.

Consequences of that, worth knowing:

- While a leader is armed, its next-step keys are swallowed **system-wide**. The
  window is 2s, Escape cancels, and a misfire costs one keystroke.
- Hesitate ~0.45s and an overlay appears listing the available next keys. Press
  through quickly and nothing ever shows.
- A key can't be both a leader and a binding of its own: `"opt+space"` and
  `"opt+space e"` collide, and `doctor` names whichever can never fire.
- If another app permanently holds a next-step key, only that branch dies. The
  daemon probes for this at startup and says so.

### Driving pounce from another binder

If a tool already owns your keystrokes — AeroSpace binding modes, skhd,
Shortcuts, a Stream Deck — let it do the chord and have pounce do the action:

```sh
pounce run cmd:emoji
pounce run mode:clipboard
pounce run app:/Applications/Ghostty.app
```

Same target grammar as `items`, dispatched through the identical path a native
binding takes. Exits non-zero with a reason if the target is malformed, so a typo
in a config fails loudly instead of producing a key that does nothing. In an
AeroSpace binding mode that's a two-step keystroke without pounce owning a key
at all:

```toml
[mode.pounce.binding]
e = ['exec-and-forget pounce run cmd:emoji', 'mode main']
c = ['exec-and-forget pounce run mode:clipboard', 'mode main']
```

Unlike the rest of config.json, **hotkeys are read once at daemon start** — the
same contract as `windows`. After adding one, restart the daemon:

```sh
brew services restart pounce                            # Homebrew
launchctl kickstart -k gui/$(id -u)/org.nixos.pounce    # nebelhaus / Nix
```

Then check it armed. A binding whose combo another app already owns fails
silently from your side, so `doctor` reports what the daemon actually got:

```sh
pounce doctor        # ✔ binding opt+e → cmd:emoji
```

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
