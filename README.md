<div align="center">

# 🐾 pounce

**summon, aim, pounce**

*a keyboard-first command palette for macOS, where every command is a file*

<sub>**pre-release** · every path that could lose your work is either reversible by design or stops to ask you first. that's the intent, not a warranty — `config init` won't clobber a config you already have, and `brew uninstall pounce` is the whole of the way out. tell us what breaks.</sub>

</div>

---

Hit ⌘Space, fuzzy-type three letters, hit return. Pounce is a small Swift daemon
that draws a `dmenu`-style picker over your screen — your apps, your commands,
one ranked list — and is gone again before you've thought about it.

A command is one shell script. The metadata lives in a comment. That's the
whole API:

```sh
#!/bin/bash
# pounce: name = Say Hello
# pounce: icon = hand.wave
osascript -e 'display notification "🐾" with title "Pounce"'
```

That `osascript` line is the *whole API* speaking — a command is any executable,
and pounce neither knows nor cares how it draws. The commands **shipped in this
repo** go through a `notify()` helper instead, so they render through
[trill](https://github.com/hausfold/trill) on a Mac that has it and fall back to
exactly the line above on one that doesn't. Copy that helper if you want the
same; keep the one-liner if you don't.

Save that as `~/.config/pounce/commands/hello.sh` and it's in the palette on the
next open. No registry, no rebuild, no restart, no account.

Want a marketplace of pre-built extensions? Use Raycast. Want a launcher you can
read end to end and change with a text editor? Pounce.

## install

```sh
brew tap hausfold/tap
brew install pounce
brew services start pounce       # the palette daemon
pounce --request-accessibility   # approve the prompt, once
```

macOS gives ⌘Space to Spotlight — free it in **System Settings → Keyboard →
Keyboard Shortcuts → Spotlight**, or pick another combo in `config.json`. If a
key ever does nothing, `pounce doctor` names whatever ate it. If it doesn't,
`pounce report` opens a bug form with that report already pasted into it — there
is no telemetry in pounce, so that form is the only way we find out.

**No Homebrew?** Grab the DMG from the [latest
release](https://github.com/hausfold/pounce/releases/latest), drag `Pounce.app`
to Applications, open it — first launch registers a login item and starts the
daemon. It's Developer ID signed and notarized either way, so there's no
Gatekeeper detour and the Accessibility grant survives upgrades. **On Nix**,
take the flake input, or kick the tyres with `nix run github:hausfold/pounce --
--help`.

Requires macOS 14 Sonoma or later, Apple Silicon. Updating is a nudge, never
automatic: a new release pins *Update Pounce* to the first row until you take it,
or skip that version with ⌘⏎.

## what you get

- **answers, not searches** — type `2*847`, `72 f in c`, `100 usd in eur` or
  `14:00 utc in pst` and the result pins to the top row; ⏎ copies it. No trigger
  prefix, no round-trip.
- **the stuff you'd otherwise hunt for** — clipboard history, screenshot
  browser, file search, camera preview, and every System Settings pane as a
  first-class row that opens *that* pane, not just Settings.
- **every setting, not just every pane** — type `full disk access`, `night
  shift` or `device management` and land on that screen with the pane already
  scrolled to it. Read from macOS's own Settings search index, synonyms and
  all, so it follows the OS instead of a list pounce keeps.
- **your Shortcuts, as rows** — every entry in your Shortcuts library is a
  first-class row; ⏎ runs it. It's also the way to reach an app's
  Shortcuts/Spotlight action: wrap it in a one-action shortcut once and it's a
  keystroke away, since macOS gives no one a way to fire another app's App
  Intent directly.
- **⌘ is a character** — the emoji picker holds symbols too, so typing
  `command` gets you ⌘, and arrows, math and box-drawing come with it. Plain
  Unicode; it pastes anywhere.
- **⌘Tab across windows** *(opt-in)* — MRU, fuzzy-filterable, per *window* not
  per app. With AeroSpace it groups rows by workspace.
- **⌃Tab across workspace pages** *(opt-in, AeroSpace)* — the same MRU gesture
  one level up: a row per page, each showing the windows on it, so you pick the
  page by what's on it. Lands on release; ⎋ leaves you where you were.
- **quit on last window close** *(opt-in)* — the Windows habit macOS never had.
- **transform the selection** — pipe whatever's highlighted through any shell
  filter and paste it back: `pounce --transform 'tr "[:lower:]" "[:upper:]"'`.
- **hotkeys that are yours** — the daemon grabs the key in-process (no client
  spawn, no socket), and leader sequences work: `opt+space e` → emoji.
- **`pounce config init`** — writes a config with *every* setting at its
  default, a sentence above each, all commented out. You learn the settings by
  reading your own config.
- **a Settings window** — `pounce settings`, or the row in the palette. Panes of
  cards, drawn from that same table, writing that same file one line at a time:
  your comments and ordering survive a click, and setting something back to its
  default comments its line out again. No second copy of anything.

MIT, no telemetry, no cloud, no login. The only things it ever calls home for
are currency rates and the update check — both switched off with one line.

## scripting it

Any script can borrow the palette. Pipe lines in, get the chosen one back:

```sh
echo -e "one\ntwo\nthree" | pounce -p "pick one:"
```

A submenu is just a command that re-invokes `pounce` with a new list — pick a
brew service, then pick start/stop — and `--chain` keeps the window up between
steps so it reads as one motion. Optional plugins ship the same way (docker,
ssh, tailscale, spotify, bluetooth, audio, github, caffeinate, perplexity), off
until you name them.

## more

- [hausfold.co/docs/pounce](https://hausfold.co/docs/pounce/) — the manual:
  [installing](https://hausfold.co/docs/pounce/install/),
  [using it](https://hausfold.co/docs/pounce/using/),
  [every config key](https://hausfold.co/docs/pounce/config/),
  [writing a command](https://hausfold.co/docs/pounce/writing-commands/)
- [`docs/reference.md`](./docs/reference.md) — config, command discovery,
  plugins, the hotkey, building from source
- [The Launcher room](https://hausfold.co/docs/haus/rooms/launcher/) — pounce
  inside haus: how the layer installs, signs and configures it
- `pounce --help` — the authoritative flag list

<p align="center"><a href="https://hausfold.co">⌂ hausfold</a></p>
