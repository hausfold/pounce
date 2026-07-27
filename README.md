<div align="center">

<!-- identity banner — peach wordmark (assets/pounce-banner-rounded.png) -->
<img src="./assets/pounce-banner-rounded.png" alt="pounce" width="480">

**summon, aim, pounce**

the palette — a keyboard-first launcher for macOS, where every command is a file.

![part of nebelhaus](https://img.shields.io/badge/part_of-nebelhaus-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![brew](https://img.shields.io/badge/brew-nebelhaus%2Ftap-f5b58e?labelColor=202020)
![license](https://img.shields.io/badge/license-MIT-d7d7d7?labelColor=202020)

<!-- assets/demo.webp — trigger hotkey, fuzzy-type an app, then a command with a submenu -->
![pounce demo](./assets/demo.webp)

</div>

---

Hit a hotkey, fuzzy-type, hit return. Pounce is a small Swift daemon that draws a
fast `dmenu`-style picker over your screen — your installed apps and your own
commands, one list, gone again before you've thought about it.

It's the launcher for people who'd rather write a five-line shell script than
learn a plugin SDK.

## why pounce

- **every command is a file** — one self-describing shell script, dropped in a folder. no plugin API, no extension store, no account.
- **native and tiny** — a single Swift `LSUIElement` binary. no Electron.
- **scriptable end to end** — a submenu is just a script that re-invokes `pounce` with a new list. pipe anything in, act on whatever comes out.
- **yours** — MIT, no telemetry, no cloud, no login.

The trade-off is deliberate minimalism. Want a marketplace of pre-built
extensions? Use Raycast. Want to *own* your launcher? Pounce.

## install

```sh
brew tap nebelhaus/tap
brew install pounce
brew services start pounce       # the palette daemon
pounce --request-accessibility   # approve the prompt, once
```

The formula installs a prebuilt `Pounce.app`, signed with our Developer ID and
notarized — no compile step, no Xcode CLT. The signing identity is stable across
releases, so the Accessibility grant survives `brew upgrade`.

On Nix, take the flake input, or kick the tyres with
`nix run github:nebelhaus/pounce -- --help`.

Requires macOS 14 Sonoma or later, Apple Silicon.

## the taste

```sh
# dmenu-style: a bare picker over stdin
echo -e "one\ntwo\nthree" | pounce -p "pick one:"

# launcher mode: rank installed apps, merge your commands
pounce --launcher -p "Search apps & actions..."
```

A command is one script. That's the whole API:

```sh
#!/bin/bash
# pounce: name = Say Hello
# pounce: icon = hand.wave
osascript -e 'display notification "🐾" with title "Pounce"'
```

Drop it in `~/.config/pounce/commands/hello.sh` and it's in the palette on the
next open. No registry, no rebuild, no restart.

## what's in the box

- **quick answers** — type `2*847`, `72 f in c`, `100 usd in eur`, or `14:00 utc in pst` and the answer pins to the top row. ⏎ copies it. (currency is the one engine that touches the network, and it's off by default.)
- **the hotkey** — the daemon grabs ⌘Space in-process, so a press lands in an already-warm process: no shell, no client spawn, no socket round-trip.
- **⌘Tab window switcher** — opt-in MRU switcher across *windows*, fuzzy-filterable, with workspace badges when AeroSpace is running.
- **native modes** — clipboard history, emoji, screenshots, camera, cheatsheets.
- **optional plugins** — docker, ssh, tailscale, spotify, bluetooth, audio, github, caffeinate. off by default; enable by id.
- **`pounce doctor`** — one command: is the daemon up, is Accessibility granted, is a macOS shortcut or another hotkey daemon quietly eating your key.

## more

`pounce --help` prints the full flag list. Deeper reference —
config, command discovery, plugins, hotkey troubleshooting, building from
source — lives in [`docs/reference.md`](./docs/reference.md).

Using pounce inside the rice? See the
[pounce guide](https://nebelhaus.com/guides/pounce/) and
[writing pounce commands](https://nebelhaus.com/guides/pounce-commands/).

## the family

- 🏠 [**nebelhaus**](https://github.com/nebelhaus/nebelhaus) — the house. the whole rice, one Nix flake. start here.
- 🐾 [**pounce**](https://github.com/nebelhaus/pounce) — the palette. keyboard-first launcher; every command a file. *(you are here)*
- 🐦 [**trill**](https://github.com/nebelhaus/trill) — the messages. native iMessage/SMS/RCS, read from `chat.db`.
- 🪺 [**perch**](https://github.com/nebelhaus/perch) — the shelf. files, caught in the notch.
- 🌫️ [**nebelung**](https://github.com/nebelhaus/nebelung) — the theme. the silver-mist palette.
- 🧰 [**workshop**](https://github.com/nebelhaus/workshop) — the bench. where the family is built.

Each one stands alone. Together they're a house.

## license

MIT © nebelhaus
