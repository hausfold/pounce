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
| `--query <text>` | open with the box already holding `<text>`, caret at the end — a draft handed back for editing, not a filter |
| `drafts <key> <op>` | read back what `--draft` kept: `save` (stdin) / `list` / `get <i>` / `rm <i>` / `clear` |
| `--cheatsheet [path]` | overlay a cheatsheet (JSON) |
| `--transform '<filter>'` | act on the current selection: copy it (⌘C), pipe the text through the shell `<filter>`, paste back (⌘V) — e.g. `--transform 'tr "[:lower:]" "[:upper:]"'`. Forwarded to the daemon, which holds the grant. |
| `focus <op>` | Focus/DND (haus's Focus room): `focus status\|toggle\|on\|off`, forwarded to the daemon |
| `run <item-key>` | run one item by the key `items` uses — `cmd:emoji`, `mode:clipboard`, `app:/Applications/Foo.app`. **Also how the built-in windows are opened**: `mode:clipboard` / `mode:emoji` / `mode:screenshots` / `mode:camera` / `mode:filesearch` / `mode:launcher` (they had a flag each until 2026-07-30) — plus `mode:settings`, which opens the Settings **window** rather than swapping the palette's contents. For binders that already own the keystroke; see [Driving pounce from another binder](#driving-pounce-from-another-binder) |
| `settings` | open the Settings window — every setting in config.json, drawn from the same table `config print` writes. Handed to the daemon when one is running, so a second invocation raises the window you already have; runs in-process when it isn't. See [The Settings window](#the-settings-window) |
| `doctor` | check the hotkey path end to end — daemon up, hotkey registered, whether it has actually *fired*, per-item bindings, scoped rows, and what else on this Mac is holding the combo. See [When doctor says everything is fine](#when-doctor-says-everything-is-fine) |
| `report [--print]` | open pounce's bug form with `doctor`'s whole report, the version, macOS and the install cohort already filled in. `--print` writes the block and the URL to stdout and opens nothing. See [When doctor says everything is fine](#when-doctor-says-everything-is-fine) |
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
[`haus`](https://github.com/hausfold/haus) for a working `launchd`
wrapper that does exactly this. The Homebrew build is Developer ID signed and
does not have this problem.

## Updating

Run **Update Pounce** from the palette to self-update in place. What it does
depends on how Pounce was installed: a Homebrew build runs `brew update && brew
upgrade pounce && brew services restart pounce`; a copy dragged to
`/Applications` downloads the latest release, verifies its signature, and swaps
the app in place. The stable Developer ID normally preserves Accessibility.
Upgrading from a build identified as `com.local.pounce` to
`com.hausfold.pounce` is the one exception: approve Pounce in Accessibility
once more. A Nix or haus-desktop install updates through the store
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

## Shortcuts — and why not App Intents

Every shortcut in your Shortcuts library is an ordinary launcher row: type its
name, press ⏎, it runs. No mode, no prefix, no submenu. They rank by frecency
like everything else, and accept the same per-item `alias` / `hotkey` /
`enabled` overrides under the key `shortcut:<uuid>` (see below). Turn the whole
source off with:

```jsonc
{ "shortcuts": { "enabled": false } }
```

**Why they start at the bottom.** A shortcut carries a small negative rank so a
sixty-entry library can't take over the seven empty-query slots on the day you
install this. Typed search is unaffected — the penalty only applies when you
haven't typed anything — and using a shortcut once lifts it back out.

**App Intents are a different thing, and pounce can't run them.** macOS 26's
Spotlight fires an app's App Intents directly — type *Add to Perch Shelf*, press
⏎, done. Pounce lists none of them, and that isn't an oversight:

- *Discovering* them is easy. Any app that exposes intents ships
  `Contents/Resources/Metadata.appintents/extract.actionsdata` — plain JSON with
  each action's title, description and SF Symbol.
- *Running* one has no public API. Spotlight goes through private, entitled
  system frameworks, and the `shortcuts` CLI deliberately lists only your saved
  library — never an app's App Shortcuts. A row parsed out of that JSON would
  have nothing behind it, which is worse than no row.

The supported bridge is a shortcut. In Shortcuts.app, make a new shortcut whose
single action is the app's intent, name it what you'd type, and it becomes a
normal library entry — which pounce then shows and runs like any other row. One
setup step, then it behaves exactly like the Spotlight action you were after.

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

That `osascript` line is the *whole API* speaking — a command is any executable,
and pounce neither knows nor cares how it draws. The commands **shipped in this
repo** go through a `notify()` helper instead, so they render through
[trill](https://github.com/hausfold/trill) on a Mac that has it and fall back to
exactly the line above on one that doesn't. Copy that helper if you want the
same; keep the one-liner if you don't.

Header keys (all optional — the filename is the fallback name/id):

| key | meaning |
|-----|---------|
| `name` | title shown in the palette |
| `description` | subtitle |
| `icon` | an SF Symbol name |
| `submenu` | `true` if the script re-invokes `pounce` |
| `whenFile` | a file that can veto the row — see below |

Spacing is forgiving, because the header is hand-typed and a header that fails to
parse has no symptom — the row just quietly carries its filename instead of its
name. The line may be indented, the `#` may be followed by any run of spaces or
tabs, and `=` may have any spacing (or none) around it; the value is trimmed at
both ends. The one thing required is *some* whitespace after the `#`, so
`#pounce: name = x` stays an ordinary comment. Unknown keys are ignored, which is
what lets a consumer add its own — haus writes `cheat` and `cheatWhen` into the
same header for its cheatsheet, and pounce passes over them.

### Listing a command only when it has something to act on

`workspaces` and `bundleIds` ask **where you are**. The other question a row can
want asked is *is there anything here for me to act on at all* — a pages picker
on a Mac with no page on it, a lane picker with no lanes — and no name can answer
that. `whenFile` names a file that can:

```sh
# pounce: whenFile = ~/.local/state/haus/any-page
```

The file is a **veto**, read on every summon: the row is hidden only while the
file's first line, trimmed of surrounding whitespace, is `0`. A missing file, an unreadable one, an empty one
and any other content all list the row — a row that hid whenever nobody was
answering would hide forever, with nothing in any log.

Whatever already knows the answer writes it. That is a hook you have, the same
shape as `pages.mruFile`: `0` or `1`, written where a summon can stat it. **It is
a file rather than a command on purpose** — `refresh()` runs on the keystroke,
and the whole build phase is ~35 ms; one `aerospace` fork would be half that
again, on every ⌘Space, for a row that is usually listed anyway.

Like the `items` scoping it hides the **row**, never the command: `pounce run
cmd:<id>` and any hotkey on it keep working. `pounce doctor` names every command
that declares one, the file it watches and whether that file is hiding it right
now — without that, a vetoed row is indistinguishable from a row you never
installed. Give doctor the palette's own `POUNCE_BUILTIN_DIR` /
`POUNCE_EXTRA_COMMAND_DIRS` if a packager sets them only for the daemon; it says
so when it can't see them.

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

`--query <text>` closes the loop: hand a chosen draft straight back to the same
prompt, box pre-filled and caret at the end, so it can be edited rather than
just re-run.

```sh
text=$(pounce drafts my-prompt get "$i")
printf '' | pounce --draft my-prompt --query "$text" -p "What should it do?"
```

The batteries-included set (clipboard, emoji, screenshots, brew-services,
lock, force-quit, …) all live in `commands/` as worked examples — copy one and
go. (The `ports` command is the exception: it ships from `pkgs/pounce/ports`,
installed as `$out/bin/ports`.)

### System Settings, down to the individual setting

Every System Settings pane is a first-class row — typing "Displays",
"Bluetooth" or "Device Management" opens that pane directly, skipping the
sidebar. So is every setting *inside* a pane: "full disk access", "night shift"
and "login items" each open the pane already scrolled to the thing you named,
about 700 of them in total.

None of it is a table pounce maintains. macOS ships its own search index for
Settings — each pane's ExtensionKit bundle carries a `.searchTerms` plist keyed
by the anchor that `x-apple.systempreferences:<pane>?<anchor>` takes, holding
the setting's title and Apple's own synonyms. Pounce reads that at startup, in
your language, so a macOS update that adds, renames or moves a setting is
picked up on the next launch rather than in a later release of pounce.

**The synonyms are why it finds things.** Apple's title for the Full Disk Access
screen is *"Allow applications to access all user files"* — the words you'd
actually type live only in the keyword list. Pounce searches both, which is how
"full disk access" gets you there and why some rows are worded like sentences.

Rows carry their pane's real icon, and sub-items inherit it, so a list of
settings stays scannable.

```jsonc
{
  "systemSettings": {
    "enabled": true,
    "subItemMinQuery": 3,   // panes always show; settings inside them wait for 3 characters
    "maxPerPane": 8         // …and no single pane may flood one result list
  }
}
```

Both numbers exist to keep a palette whose main job is opening apps from being
taken over by 700 settings. Panes are always searchable; the settings inside
them join the list only once your query is `subItemMinQuery` characters long,
so "sa" still means Safari. `maxPerPane` then caps how many settings any one
pane contributes to a single result list — Accessibility alone ships 342 of
them. Set `subItemMinQuery: 0` to drop the gate, `maxPerPane: 0` to drop the
cap, or `enabled: false` to drop the whole source.

Panes start ranked below everything at an empty query and climb by use, the
same way shortcuts do.

**Upgrading from the generated pane commands.** Panes used to ship as generated
command scripts keyed `cmd:settings-<slug>`. They're now native rows keyed
`setting:<pane-bundle-id>[?<anchor>]`, so an `items` override or hotkey pointed
at the old key needs repointing — `pounce doctor` reports a binding whose target
no longer exists. `pounce run setting:com.apple.Displays-Settings.extension` opens a pane by the
new key; the frecency history under the old keys is not carried over.

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
every open, so edits apply on the next launch — no restart needed. (The
exceptions are the things the daemon sets up at startup: `windows`, `autoQuit`,
`appHotkeys`, `pages`, `mouseChords` and the `items` hotkeys.) Every key is optional and falls
back to a default.

**Start from a config that documents itself:**

```sh
pounce config init      # writes ~/.config/pounce/config.json
pounce config print     # …or just look at it, touching nothing
```

That writes **every** setting at its default, with a sentence above it, all
commented out — so the file changes nothing until you uncomment a line, and you
make it minimal by deleting the lines you never touched. It never overwrites a
config you already have (it writes `config.json.new` beside it instead; `--force`
replaces). On a machine managed by the haus desktop it refuses outright: that
config.json is generated from `haus.launcher.*`, and the next rebuild would
put the generated one straight back.

### The Settings window

```sh
pounce settings         # or the "Pounce Settings" row in the palette
```

A sidebar of panes, each a scrolling column of cards — the same shape perch and
trill use. **It is not a second place your settings live**: every control reads
its value out of config.json and every click rewrites exactly one line of it,
leaving your comments, your ordering and any key pounce has never heard of
untouched. Edit the file in your editor with the window open and it catches up
the next time it comes forward.

Both surfaces are generated from one table (`ConfigSpec`), so the sentence under
a switch is the sentence above that key in the file, and a setting cannot exist
in one and be missing from the other.

Three things worth knowing:

- **Setting something back to its default comments its line out again.** That is
  this file's grammar for "unset", so the config only ever accumulates the
  decisions you actually made, and switching a thing on and off leaves the file
  byte-for-byte where it started. A row that is *not* at its default grows a ↺
  button — the only marker of what you have changed.
- **A config that doesn't exist yet is created annotated**, exactly as `config
  init` would, by the first switch you flip.
- **It refuses rather than guesses.** On a haus-managed Mac (config.json is a
  symlink into the Nix store) every control is read-only and says why. And
  because it is a line editor, a section you folded onto one line — `"clipboard":
  { "maxEntries": 50 }` — is refused with a note rather than rewritten; put each
  key on its own line, or change that one in the file.

A few settings are structured past what a row can honestly draw
(`appHotkeys.scopes`, `mouseChords.chords`, the whole `items` map). Those show
what one entry looks like and open the file.

Bind it like anything else — but not to ⌘, : that comma is not a key name pounce
parses, and an item hotkey is a *global* registration, so binding the universal
Preferences chord would take it away from every other app on the Mac. A leader
sequence stays out of everyone's way:

```jsonc
"items": { "mode:settings": { "hotkey": "opt+space s" } }
```

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
    "key": "space",         // "space", "return", "tab", "esc",
                            // "a"…"z", "0"…"9", "f13"…"f20"
    "modifiers": ["cmd"]    // any of "cmd" / "shift" / "opt" / "ctrl"
  },
  "windows": {
    "enabled": false,       // MRU window switcher on ⌘Tab (needs Accessibility)
    "key": "tab",
    "modifiers": ["cmd"]
  },
  "autoQuit": {
    "enabled": false,       // quit an app when you close its last window
    "delay": 2,             // seconds to wait, then look again before quitting
    "exclude": ["com.apple.finder"]  // never auto-quit these; REPLACES the default
  },
  "appHotkeys": {
    "enabled": false,       // chords consumed only over named apps (needs Accessibility)
    "scopes": [             // per app: which chords, and what each one runs
      // { "bundleId": "com.mitchellh.ghostty",
      //   "keys": [ { "key": "p", "modifiers": ["cmd"], "target": "cmd:shell-here" } ] }
    ]
  },
  "pages": {
    "enabled": false,       // MRU walk over prefix/* AeroSpace workspaces, with a HUD (needs Accessibility)
    "key": "tab",
    "modifiers": ["ctrl"],
    "prefix": "T",          // walks workspaces named prefix or prefix/…
    "bundleId": null,       // scope the chord to one app; null = anywhere
    "mruFile": null         // recency file your WM hook maintains, newest first ("~" ok)
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
  "stage": {
    "enabled": true,        // the empty query opens on tiles + a glance line
    "tiles": 5              // how many tiles the strip holds (1–8)
  },
  "items": {}               // per-item enable / alias / hotkey — see below
}
```

### The Stage (`stage`)

What you see **before you type**. On (the default), an empty launcher query is
three zones instead of one list:

- a **strip of tiles** for the handful of things you actually reach for — the
  top of the same frecency ranking the list has always used;
- the **familiar list** beneath it, unchanged;
- a quiet **glance line** above: the time, the date, and what you last copied.

Type a single character and the whole thing yields to today's ranked results —
search itself is untouched. A tile is not a new kind of thing: it is the same
row, promoted. Same frecency key, same `items` override, same per-item hotkey,
same ⏎. `←` / `→` walk the strip, `↓` drops into the list, `↑` comes back.

The list keeps its full length when the Stage is on — tiles are taken off the
top of the ranking *in addition to*, not out of, the rows below, so turning it
on never costs you list.

```jsonc
"stage": { "enabled": false }   // the flat list pounce has always shown
"stage": { "tiles": 3 }         // fewer, wider tiles — suits "compact"
```

In `"windowMode": "compact"` there is no Stage at all: compact means an empty
query shows *nothing* until you type or press ↓, and a strip of tiles is
emphatically something. The two are answers to the same question, and the
narrower one wins.

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

On the [haus](https://github.com/hausfold/haus) rice this is written
for you from `haus.ui.scale`, so the palette grows with the rest of the
desktop.

The **nebelung** palette and its light counterpart **nebelung-latte** are both
compiled into the binary straight from the
[nebelung](https://github.com/hausfold/nebelung) flake, so they never drift from
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
  https://raw.githubusercontent.com/hausfold/nebelung/main/palette/nebelung-latte.hex.json
# then in config.json:  "theme": "nebelung-latte"
```

Pounce uses these keys: `base`, `surface0`–`surface2`, `text`, `subtext0`,
`overlay0`, `mauve`, `blue`. A file missing any of them (or an unknown name)
falls back to the built-in default. A file also *shadows* a built-in of the same
name, so `themes/nebelung.json` wins over the compiled-in one. On a haus
desktop you never do this by hand — `haus.theme.{flavor,contrast}` installs the
matching variant and points `"theme"` at it.

The window chrome (blur material, appearance, border, fill opacity) follows the
**palette's** own lightness, not the system's — a light palette in Dark Mode
still renders as a light panel.

### Per-item settings (`items`)

One map covers the things you'd otherwise want a key each for — hide it, give it
a shorthand, give it a key, list it only where it's useful. Each entry is keyed
by an **item key**:

| Item key | What it addresses |
|---|---|
| `cmd:<id>` | a command script, by filename without `.sh` |
| `app:/Applications/Foo.app` | an application, by path |
| `shortcut:<uuid>` | a Shortcuts-library entry, by its identifier (`shortcuts list --show-identifiers`) |
| `setting:<pane>[?<anchor>]` | a System Settings pane, or one setting in it — `setting:com.apple.Displays-Settings.extension?nightShiftSection`. Where one anchor backs several settings the key gains a `#<slug>` tail to stay unique; the URL still uses the bare anchor. `pounce doctor` prints the exact key. |
| `mode:<name>` | a built-in window: `launcher`, `clipboard`, `emoji`, `screenshots`, `camera`, `filesearch` |

```jsonc
{
  "items": {
    "cmd:emoji":                     { "alias": "emo", "hotkey": "opt+e" },
    "cmd:brew-services":             { "enabled": false },
    "app:/Applications/Ghostty.app": { "alias": "term", "hotkey": "opt+t" },
    "shortcut:0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7": { "alias": "shelf" },
    "setting:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles": { "alias": "fda" },
    "mode:clipboard":                { "hotkey": "cmd+shift+v" }
  }
}
```

- **`enabled: false`** drops the row from the launcher. It does *not* disarm that
  item's hotkey — binding a key to something you keep out of the list is a
  legitimate setup. (`apps.hideBundleIds` still works and hides by bundle ID
  instead of path; use whichever you have to hand.)
- **`workspaces`** and **`bundleIds`** list the row only where it is useful — on
  certain workspaces, or with a certain app in front. See [Scoping a row to
  where you are](#scoping-a-row-to-where-you-are), below.
- **`alias`** is a search shorthand. It matches at a bonus over the item's real
  name, so typing your alias lands on your item rather than on whatever app
  happens to fuzzy-match the same letters.
- **`hotkey`** is a global key that runs the item directly, skipping the palette.
  Written as `"cmd+shift+v"` — the last segment is the key, the rest are
  modifiers (`cmd` / `shift` / `opt` / `ctrl`). The object form
  `{"key": "v", "modifiers": ["cmd","shift"]}` used by the `hotkey` and `windows`
  blocks is accepted here too. Add a **space** for a two-step sequence — see
  below.

  The laptop **Fn/Globe key** is a special one-step binding: for example,
  `"mode:emoji": { "hotkey": "fn" }`. `"globe"` and `"function"` are accepted
  aliases, and only a bare one-step `fn` is supported — no modifiers, not as a
  leader. There are two ways Pounce can carry it, chosen by the top-level
  **`"fnKey"`** setting.

  #### `"fnKey": "tap"` (default) — shares the key with macOS

  Reads Fn with a keyboard event tap, so it needs Pounce's Accessibility grant
  (`pounce --request-accessibility`), and it fires only when Fn is tapped alone,
  leaving Fn combinations to the hardware.

  **It cannot be made exclusive**, and it's worth being precise about why, since
  the symptom (macOS's Character Viewer opening too, seemingly at random) has
  cost real debugging time. HIToolbox is linked into *every* process and carries
  its own Globe handler, which reads the key **below** the CGEvent stream a tap
  can see. Captured with the tap installed and healthy — zero `tapDisabled`
  events across a whole session's log:

  ```
  05:18:27.713  pounce    [HIToolbox:CharacterPalette] TSMLaunchCharacterPalette called
  05:18:33.890  ghostty   [HIToolbox:CharacterPalette] TSMLaunchCharacterPalette called
  05:18:40.187  Obsidian  [HIToolbox:CharacterPalette] TSMLaunchCharacterPalette called
  ```

  Four native pickers, and **zero** corresponding Fn transitions in the tap —
  one of them launched by HIToolbox inside Pounce's own process. There was
  nothing for the tap to suppress, because the press never reached it. No
  CGEventTap placement changes that.

  Turning off macOS's own action (System Settings → Keyboard → "Press 🌐 key
  to" → **Do Nothing**) is the only lever this mode has, and it is a partial
  one: that value is read from **login-session state**, so `defaults write
  com.apple.HIToolbox AppleFnUsageType -int 0` is honored by nothing already
  running — use the System Settings toggle, and log out once. The pref is
  normally *unset* on a fresh Mac, and unset does not mean "Do Nothing", which
  is why a new `fn` binding starts out racy. `pounce doctor` flags it.

  #### `"fnKey": "remap"` — takes the key away from macOS

  ```jsonc
  { "fnKey": "remap", "items": { "mode:emoji": { "hotkey": "fn" } } }
  ```

  Remaps Fn to **F19** at the HID layer (IOKit's `UserKeyMapping`, the same
  thing `hidutil` writes), so it stops being Fn before HIToolbox — or anything
  else — can see it. Pounce then binds F19 with the ordinary Carbon call it uses
  for every other hotkey. **No Accessibility grant, and nothing left to race.**

  The cost, and the reason this is opt-in: Fn stops being Fn *everywhere*. No
  Fn+arrows (Home/End/PageUp/PageDown), no Fn+Delete, no Fn+F1–F12.

  Three things worth knowing before you turn it on:

  - **F19 is a real key on the full-size Magic Keyboard** (the one with a numeric
    keypad), where it's the last key of the F-row — on that keyboard, pressing
    F19 fires this binding too. Every key below F13 is one people actually bind,
    so this is the least-bad choice rather than a free one.
  - **A keyboard that re-enumerates loses the mapping.** `hidutil` attaches to
    the HID services present when it runs, so unplugging and replugging an
    external keyboard (and some sleep/wake cycles) drops it — the binding then
    quietly stops working. `pounce doctor` says so; restarting the daemon
    reinstalls it.
  - **`UserKeyMapping` is one shared list.** Pounce merges into whatever is
    already there (a Karabiner rule, a Caps→F18 leader) and puts back what it
    found on exit, including an Fn mapping of your own that it had to displace.
    It refuses to write at all if it couldn't read the list first. What it can't
    do is notice a mapping added by something *else* while the daemon was
    running and preserve that too — if you add one mid-session, re-apply it
    after pounce exits.

  The mapping is applied while the daemon runs and removed when it exits. It is
  never persistent: a reboot clears it even if the daemon dies badly. To check or
  clear it by hand:

  ```bash
  hidutil property --get UserKeyMapping
  hidutil property --set '{"UserKeyMapping":[]}'   # clears ALL mappings, not just ours
  ```

`enabled`, `alias`, `workspaces` and `bundleIds` only mean something for things
the palette lists, so a `mode:` entry carries just a hotkey.

#### Scoping a row to where you are

`enabled` is a decision you make once. **`workspaces`** and **`bundleIds`** are
asked again on every summon, so a row can be listed only where it means
something — a command that acts on "the focused terminal window" is noise in a
palette opened over a browser, and worse than noise if it falls back to `$HOME`
and does something you didn't mean.

```jsonc
{
  "items": {
    // an agent lane, only from the terminal pages…
    "cmd:lane-here":  { "workspaces": ["T"] },
    // …or only with the terminal itself in front, wherever its window is
    "cmd:shell-here": { "bundleIds": ["com.mitchellh.ghostty"] }
  }
}
```

- **`workspaces`** is a list of workspace names (a bare string is accepted for
  one). `"T"` matches the page `T` **and every `T/…` child** — the same rule
  `pages.prefix` uses, because a tiling desktop names its pages that way. `"T/*"`
  matches the children only, and `"T/main"` matches exactly that page.
  Case-insensitive — unlike `pages.prefix` itself, which matches case-sensitively
  and has no `/*` form.

  Which workspace you are on is read from **`pages.mruFile`** — the recency file
  the window manager's own workspace-change hook writes, head line first (the
  `pages` block in [Configuration](#configuration)). That file is the whole
  mechanism: set it even if you never turn the ⌃⇥ walk on. **Unset or missing,
  `workspaces` filters nothing** — a Mac with no tiler can't answer the
  question, and hiding a row there would hide it forever. It is read once per
  summon, not polled, and never shells out to the window manager: the palette
  opens on a keypress and nothing on that path may wait on a subprocess.

- **`bundleIds`** is a list of bundle IDs; the row is listed only while one of
  them is the frontmost app. Case-insensitive.

- Both together **AND**: the row wants that page *and* that app.

- They ask **where you are**, from a file, with no subprocess. *Is there anything
  to act on at all* is a different question, and it belongs to the command script:
  a [`whenFile`](#listing-a-command-only-when-it-has-something-to-act-on) header
  names a file that can veto its row.

- They scope the **row**, never the item's `hotkey` — a key you bound stays
  bound, exactly as it does under `enabled: false`. Scoping a *chord* to an app
  is the `appHotkeys` block instead, which has to consume the keystroke to do
  it.

- **`pounce doctor` is where a scoped row explains itself.** A row that is never
  listed looks exactly like a row you never installed, so the report names every
  scoped item, what it asks for, which workspace you are on, and which rows that
  leaves out from here — and it fails outright when something asks about
  `workspaces` while `pages.mruFile` is unset or unreadable, which is the case
  that would otherwise look like the setting quietly doing nothing.

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
launchctl kickstart -k gui/$(id -u)/com.hausfold.pounce # haus / Nix
```

Then check it armed. A binding whose combo another app already owns fails
silently from your side, so `doctor` reports what the daemon actually got:

```sh
pounce doctor        # ✔ binding opt+e → cmd:emoji
```

### When doctor says everything is fine

`pounce report` opens pounce's bug form with doctor's whole report already in
it, above a header naming the version, your macOS build, your Mac model and
which of the four installs this copy is. `--print` writes the block and the URL
to stdout and opens nothing — for a Mac you reached over ssh, or for pasting into
`gh issue create`.

The same door is in the palette (**Report Pounce Issue**) and in the Settings
window's app menu. Your home directory is written back as `~` before the block
goes anywhere; nothing is sent by opening the form, and **there is no telemetry
in pounce**, which is why the door exists at all.

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
| `POUNCE_NO_DAEMON` | `1` keeps a palette invocation in the calling process instead of handing it to the running daemon — for feel-testing a build while the installed daemon owns the socket |

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
  another workspace. No HUD, no ceremony. (Under AeroSpace this means the last
  window on a *different* workspace family — see below.)
- **hold ⌘, keep tapping ⇥** — walk every window, most-recently-used first
  (⌘⇧⇥ walks backwards; ↑/↓ also move).
- **hold ⌘ and type** — fuzzy-filter the list, ranked by frecency. ↵ commits, ⎋
  cancels, releasing ⌘ always lands on the selection.

**Running AeroSpace, a bare tap looks past the workspace you're on.** With two
windows tiled side by side, the most recent one is a window you are *looking
at* — landing there isn't a switch, and nudging focus between visible tiles is
the window manager's job (AeroSpace's own focus keys), not the switcher's. So a
tap-and-release takes the most recent window on a *different* workspace, which
is what makes ⌘⇥ mean "get me back to where I was" again.

**Pages count as the workspace they belong to.** A workspace name with a `/` in
it — `T/haus`, `T/main` — is a page of `T`, and the whole `T` family is one
place as far as a bare tap is concerned. Getting *between* pages is what
[the page walk](#the-page-walk-tab-opt-in) is for, so
walking a few pages and then tapping ⌘⇥ takes you off `T` altogether rather
than dropping you back on the page you just left. The rule is the name before
the first `/`, and it is deliberately not keyed on `pages.prefix`: ⌘⇥'s default
shouldn't change shape depending on whether the page chord is configured.

Two details worth knowing. The candidate's workspace has to be *known* and
different, not merely "somewhere else" — a window AeroSpace hasn't placed is
never the default, so the rule can only ever land you somewhere `aerospace focus
--window-id` can actually reach. And it prefers not to un-minimize: a minimized
window becomes the default only if every other window is minimized too.

Nothing is hidden from the list — the skipped siblings, pages included, are the
rows immediately below you. To get one, hold ⌘ and step *back* with ⇧⇥ from
where the default put you. (A ⌘⇧⇥ tap-and-release is the other gesture
entirely: it starts from the far end of the list and walks forwards.)

None of this engages without AeroSpace, and it also stands down when every
window happens to be in one workspace family: the default falls back to plain
MRU. The one thing a machine with no AeroSpace does feel is the HUD delay — the
list appears after a quarter second of holding ⌘ rather than a tenth, so a
quick bounce between two windows never flashes it.

macOS doesn't let ⌘Tab be rebound — the daemon takes it with an event tap, which
the system gates behind the **Accessibility** grant. Without the grant (or during
Secure Input, e.g. password fields) the tap stands down and stock ⌘Tab keeps
working, so enabling this can never leave you unable to switch windows. Grant
Accessibility while the daemon is running and the switcher arms itself within a
couple of seconds — no restart; revoke it and the tap drops live. Flipping
`windows.enabled` itself does need a daemon restart.

Running [AeroSpace](https://github.com/nikitabobko/AeroSpace)? The list gathers
windows by workspace, each group under its own header — workspace order is
itself MRU, so it reads as "here, then where I was before, then before that" —
and focusing goes through `aerospace focus --window-id` so a window parked on
another workspace surfaces correctly. That's the pairing the
[haus](https://hausfold.co) desktop ships enabled.

Headers appear only when there are two or more groups to tell apart; with
everything on one workspace the list is plain. Filtered results are ranked by
score rather than gathered, so they drop the headers and carry a per-row
workspace badge instead.

## The page walk (⌃Tab, opt-in)

⌘⇥ moves between windows; **⌃⇥ moves between the pages of the workspace you're
on**. A page is an AeroSpace workspace with a `/` in its name — `T/haus`,
`T/pounce` — and the `pages` block in [Configuration](#configuration) turns the
chord on, names the family it walks (`prefix`, `"T"` by default) and optionally
scopes it to one app so a browser keeps its own ⌃⇥.

- **⌃⇥, release** — the page you were on before this one.
- **hold ⌃, keep tapping ⇥** — walk the family's pages, most-recently-used
  first; ⌃⇧⇥ walks backwards. ↵ lands without waiting for the release, ⎋
  abandons the walk and leaves you exactly where you were.

Holding the modifier brings up a HUD after a quarter second — the ⌘⇥ switcher's
list one level up. **Each row is a page, with the windows on it listed
underneath**, most-recently-used first, so a page is chosen by recognising what
is on it rather than by remembering which letter it got. A dot marks the page
the walk started from. Pages with more windows than the card draws end in a
"+N more" line; a long list scrolls to the selection.

**Only the family's live pages are ever listed** — a page is live when it holds
a window, since AeroSpace workspaces evaporate when their last window closes.
Everything else on the Mac is ⌘⇥'s business: a page walk that listed workspaces
the next tap cannot reach would be advertising a move it won't make.

**Nothing is focused until you land.** The walk moves a selection, not the
screen; the one `aerospace workspace` call happens on the release. That is also
what keeps recency honest: the window manager's hook pushes every workspace you
*visit* onto the MRU file, so a walk that travelled would rank the pages it
merely passed through above the one you came from, and the next single tap
would land in a corridor.

Recency itself is read, never tracked: `pages.mruFile` names the file the
window manager's own workspace-change hook writes (newest first, one workspace
per line; `~` is expanded, and any line ending will do — it is the same read the
palette's [`workspaces` scoping](#scoping-a-row-to-where-you-are) makes, so the
two can never disagree about where you are). The hook hears about every change — chords, the mouse, a script —
where anything pounce tracked itself would only see the changes pounce caused.
Pages the file has never seen are still reachable; they queue behind the known
ones, sorted by name.

Same footing as ⌘Tab underneath: it's a consuming event tap, so it needs
**Accessibility**, it stands down during Secure Input, and with no live pages at
all the chord passes straight through to whatever it meant before (a terminal
multiplexer's own tab history, typically).

## Mouse chords (opt-in)

A window-manager keybind can only reach the window you are already in. A **mouse
chord** — a modifier plus a click — acts on the window **under the pointer**, so
"zoom that one over there" is one gesture instead of focus-then-zoom.

```json
"mouseChords": {
  "enabled": true,
  "chords": [
    { "button": "right", "modifiers": ["alt"], "action": "fullscreen" }
  ]
}
```

That makes **⌥ + right-click** zoom whichever window you clicked to fill its own
workspace, focusing it on the way. `fullscreen` is a toggle, so the same chord
puts it back. Needs [AeroSpace](https://github.com/nikitabobko/AeroSpace) (the
action runs `aerospace fullscreen --window-id`) and the Accessibility grant every
consuming event tap needs; read once at daemon start.

**Choosing a chord.** The click is consumed over *every* app, so pick one nothing
else claims:

| chord | what it costs |
|---|---|
| **⌥ + right-click** | the least of the three: macOS's ⌥ *variant* of a context menu (in Finder, "Copy as Pathname"), and ⌥ + right-drag where an app uses it |
| ⌥ + left-click | multi-cursor in GUI editors, ⌥-click-a-link to download, ⌥-click a menu extra, and every ⌥-drag (the down is swallowed, so the drag never starts) |
| ctrl + click | context menus machine-wide — macOS's own secondary click |

A chord with no modifier is refused outright and logged: it would swallow every
click on the machine, including the ones you'd need to fix the config.

Clicking the desktop passes through untouched, so ⌥ + right-click still gets
Finder's menu there, and anything drawn above ordinary windows — the menu bar,
the Dock, a status bar like SketchyBar — is transparent to the chord rather than
being "clicked".

## Quit on last window close (opt-in)

macOS keeps an app running after you close its last window. On Windows that
closes the program, and if that is the muscle memory you have, every windowless
app is a ⌘Q you forgot. With `"autoQuit": { "enabled": true }` pounce closes that
gap: when an app's last window goes away, it is asked to quit.

**Asked, not killed.** The quit is the same Quit event ⌘Q sends, so an app with
unsaved work puts its sheet up and stays open — and pounce won't ask it again
until it has a window once more. Nothing here can lose work that ⌘Q wouldn't.

**The delay is load-bearing.** `delay` (2s by default, clamped to 0.25–3600) is
not politeness — it is what tells "I'm done with this app" apart from "close this
window, open another", which is what a browser does when you close its last window
and hit ⌘N. After the wait pounce looks again, and anything open at all —
including panels and dialogs the ⌘Tab switcher wouldn't list — calls the quit off.
Two seconds is the responsive end of that trade; it is not enough for a cold IDE
reopening a project, which is a case for `exclude` rather than for a delay you'd
feel on every app.

**`exclude` replaces its default; it doesn't extend it.** Out of the box the list
is `["com.apple.finder"]`, because Finder is the one app macOS runs windowless by
design (quit it and the desktop blinks out while it relaunches). Write your own
list and Finder is only in it if you put it there. Read a bundle id off any
running app with `osascript -e 'id of app "Notes"'`.

It reads the same window snapshot as the ⌘Tab switcher, so it wants the same
**Accessibility** grant, and it shares that snapshot rather than taking its own —
turning both on costs one set of observers, not two. Without the grant auto-quit
stays off and says so in the log rather than guessing (an app pounce can't see
into looks exactly like an app with nothing open, and acting on that would quit
whatever was busy). Grant it while the daemon runs and auto-quit arms itself
within a couple of seconds; revoke it and it stands down live. Flipping
`autoQuit.enabled` itself needs a daemon restart.

**The one thing that will surprise you: an app doing work in the background is
still just an app with a window.** Close the Docker Desktop dashboard and Docker
is asked to quit, which stops your containers; the same shape catches media
players (⌘W on Music stops playback), torrent clients, and chat and mail apps you
keep running for their notifications. Nothing here can lose work that ⌘Q wouldn't
— it's the same quit — but ⌘Q is something you *chose*. That class of app is what
`exclude` is for, so expect to spend the first week adding to the list. The
shipped default has only Finder in it because Finder is the only app macOS itself
structurally needs; everything else is a judgement about *your* apps, and a list
guessed here would be both incomplete and stale.

Two things it never touches at all: an app that has been windowless since the
daemon started (that's every menu-bar app, and quitting them on sight would be a
rout), and an app with no bundle id — there'd be no way to name it in `exclude`,
so it never becomes a candidate. Note the first is about the app's *whole* run
under the daemon: a menu-bar app that opens a window once and has it closed is a
candidate from then on.

## Building from source

```sh
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

Building from source needs the **Xcode Command Line Tools 16 or newer** — that
path compiles against the system Swift toolchain via `xcrun`
(`xcode-select --install`). 16 is the floor because pounce overrides two
`NSResponder` methods that only the macOS 15 SDK declares; an older SDK fails
the build with `method does not override any method from its superclass`, which
does not otherwise explain itself. Note this is the SDK you *build* with — the
app itself still runs on macOS 14 and later.

Hacking on pounce as part of the wider rice? The
[workshop](https://github.com/hausfold/workshop)'s `bench try` rebuilds a whole
haus machine against your local checkout, uncommitted edits included.
