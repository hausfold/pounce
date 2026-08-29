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

Save that as `~/.config/pounce/commands/hello.sh` and it's in the palette on the
next open. No registry, no rebuild, no restart, no account.

Want a marketplace of pre-built extensions? Use Raycast. Want a launcher you can
read end to end and change with a text editor? Pounce.

```sh
brew tap hausfold/tap
brew install pounce
brew services start pounce       # the palette daemon
pounce --request-accessibility   # approve the prompt, once
```

macOS gives ⌘Space to Spotlight; [installing](https://hausfold.co/docs/pounce/install/)
is where you take it back. MIT, no telemetry, no cloud, no login. macOS 14
Sonoma or later, Apple Silicon.

## the manual

📖 **[hausfold.co/docs/pounce](https://hausfold.co/docs/pounce/)** — and it only
lives there: [installing](https://hausfold.co/docs/pounce/install/) (including
freeing ⌘Space from Spotlight),
[using the palette](https://hausfold.co/docs/pounce/using/),
[what ships in it](https://hausfold.co/docs/pounce/commands/),
[writing a command](https://hausfold.co/docs/pounce/writing-commands/),
[every config key](https://hausfold.co/docs/pounce/config/),
[every flag](https://hausfold.co/docs/pounce/cli/).

Inside a haus machine it's [the Launcher
room](https://hausfold.co/docs/haus/rooms/launcher/), which installs, signs and
configures all of the above for you.

## in this repo

- [`ai/SKILL.md`](ai/SKILL.md) — the agent surface, so *"add a command that…"* works first try
- [`AGENTS.md`](./AGENTS.md) — hacking on pounce: the build, the layout, the invariants
- `pounce --help` · `pounce doctor` — the authoritative flag list, and what to run when a key does nothing

<p align="center"><a href="https://hausfold.co">⌂ hausfold</a></p>
