# pounce — demo script

A ~7 minute screen recording. **This file is the background**: keep it open in
one pane, the palette fires over it, you read the left column and do the right
column. Nothing here is a slide — it's a checklist you happen to be filming.

> **Don't walk the web docs on camera.** They're a manual: long, reference-shaped,
> and they open with installation. The four tables below are the whole show, in the
> order a skeptic needs to hear them. Link the docs at the end for the people who
> want them.

## 0 · Cold open — 30s

No intro, no "so, what is pounce". Open on a full screen of something else.

| say | do |
|---|---|
| "⌘Space." | Palette opens. Type `ghost` → ⏎. Ghostty is up. |
| "It also does math." | ⌘Space, `2*847` → the answer is the top row. ⏎ copies it. |
| "That's the product. Everything else is that same box." | Close it. |

## 1 · The box already knows things — 2 min

The pitch here is **no trigger prefix and no round trip** — you type the question,
the answer is the first row.

| say | do |
|---|---|
| "Math, units, currency, timezones — inline." | `72 f in c` · `100 usd in eur` · `14:00 utc in pst` |
| "Clipboard history. Text and images, and it remembers where each came from." | `clip` → ⏎, arrow through, ⏎ pastes |
| "File search." | `find` → ⏎, type a filename |
| "Screenshot browser — ⏎ copies the image." | `screenshots` → ⏎ |
| "Camera, because sometimes you just need a mirror." | `camera` → ⏎ |
| "Force quit, lock, brew services, activity monitor…" | `force` → ⏎ → pick an app |
| "Emoji — and ⌘ is a character too." | `emoji` → ⏎, type `command` → ⌘ pastes |
| "Your Shortcuts are rows. ⏎ runs them." | type the name of one shortcut |
| "And every macOS **setting**, not just every pane." | `full disk access` → lands on that screen, already scrolled to it |

Land that last one hard: it's read out of macOS's own Settings search index —
synonyms included — so it tracks the OS instead of a table someone has to maintain.
"Allow applications to access all user files" *is* Full Disk Access, and typing
either finds it.

## 2 · Why you won't miss Raycast — 2 min

Do this as a straight read down the table. Demo only the starred rows.

| what you'd miss | pounce |
|---|---|
| Replace ⌘Space | ★ Yes — and the daemon grabs the key **in-process**, so there's no client to spawn. `pounce doctor` names whatever is eating it. |
| Clipboard history | ★ Text, images, files. Retention is `maxEntries` in a text file — set it to 10,000. **No Pro tier gating it.** Password managers are excluded by default. |
| Per-command hotkeys & aliases | ★ Any row: a command, an **app**, a Shortcut, a built-in window. One `items` map. |
| App launcher / fuzzy search | ★ Ranked by frecency, same box |
| File search | Built in, no extension to install |
| Camera | Built in |
| Emoji picker | ★ Plus a curated symbol set — ⌘ ⌥ ⇧, arrows, math, box drawing |
| Window switcher | ★ Replaces ⌘Tab itself: per **window**, MRU, hold-⌘-and-tab, fuzzy-filterable |
| Quit / force quit apps | Yes — and it's a 20-line shell script you can read |
| Extensions | A command is **one shell file**. See §3. |
| Themes | Follows macOS light/dark, or pin one |
| Price | Free. MIT. No account, no telemetry, no cloud. |

**Say the honest version of this table.** Raycast has file search, a window
command and a quit command too — the win isn't "they can't", it's that ours cost
nothing, ship in the box, and are three lines of shell you can change. Overclaiming
here is the one thing that loses the room.

## 3 · What it does that a store-based launcher can't — 2 min

This is the actual argument. Everything above is table stakes; this is why it exists.

| say | do |
|---|---|
| "A command is one file. The metadata is a comment." | Show `hello.sh` on screen (below) |
| "Save it. It's in the palette on the next open — no rebuild, no restart, no registry." | ⌘Space → `hello` → ⏎ → the notification fires |
| "No React, no npm, no store review, nothing to publish." | — |

```sh
#!/bin/bash
# pounce: name = Say Hello
# pounce: icon = hand.wave
osascript -e 'display notification "🐾" with title "Pounce"'
```

Then the part nobody else has:

| say | do |
|---|---|
| "It's also a picker **an agent** can put in front of you." | In a terminal: `printf 'staging\nproduction\n' \| pounce -p "Deploy where?"` |
| "It prints back what you picked. So a script — or Claude — can ask a human a question in a native window instead of a terminal prompt." | Pick one, show the output |
| "There's a skill for it, so agents already know how." | — |

And the input-layer things:

| say | do |
|---|---|
| "Leader keys. ⌥Space then E." | Do it → emoji. Hesitate once to show the overlay listing next keys. |
| "Hotkeys scoped to one app — ⌘P means print everywhere else." | mention |
| "Modifier + click acts on the window **under the pointer** — including the one on your other monitor." | mention, or demo if configured |
| "Quit on last window close, if you came from Windows." | mention |
| "And the config is a file that documents itself." | `pounce config init` → open it: every setting, at its default, a sentence above each, all commented out |

## 4 · Close — 30s

| say | do |
|---|---|
| "Three lines." | show install |
| "It's MIT, it's ours, and if it's missing something you write a shell script." | — |

```sh
brew tap hausfold/tap
brew install pounce
brew services start pounce
```

Docs: **hausfold.co/docs/pounce** · `pounce --help` · `pounce doctor`

---

## Notes for the recording

- **Don't show config.json editing on camera** beyond the one `config init` beat.
  Watching someone type JSON kills a demo.
- **Pre-warm everything**: daemon running, Accessibility granted, clipboard with a
  few interesting entries in it (including an image), a couple of screenshots, the
  `hello.sh` file written but not yet saved into `~/.config/pounce/commands`.
- **Second monitor or a second Obsidian pane** for this file, so the palette never
  covers your own notes.
- Total: cold open 0:30 · §1 2:00 · §2 2:00 · §3 2:00 · close 0:30 ≈ **7 min**.

## Two questions people will ask

**"Does it do a hyper key?"** No. Pounce doesn't create a modifier — it doesn't
remap Caps Lock to ⌃⌥⇧⌘ the way Raycast can. It *binds* combos (`cmd`, `opt`,
`ctrl`, `shift`, in any mix), so if something else on the machine makes a hyper key,
pounce will happily take it. What it has instead is arguably the better answer, and
it's the one to demo: **leader sequences** — `opt+space e`, `opt+space c` — an
entire namespace behind one chord, with an overlay that shows you the next keys if
you pause. No Accessibility grant needed. There's also `"fnKey": "remap"`, which
takes the Fn/Globe key away from macOS at the HID layer so it becomes a dedicated,
unshared launcher key — that's a single key, not a modifier, and it costs you
Fn+arrows.

**"Is it as fast as Raycast?"** The hotkey is registered inside the running daemon,
so the keypress lands in warm code — no shell, no process spawn, no socket. Quick
answers are synchronous and sub-millisecond; anything that needs the network
(currency) reads a cached snapshot and never blocks a keystroke.
