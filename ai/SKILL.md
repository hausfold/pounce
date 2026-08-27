---
name: pounce
description: Drive the Mac's command palette from a script — and, most usefully, put a native picker in front of the user to choose from a list you generate, instead of asking them to type an answer. Use when the user says "ask me which one", "let me pick", "give me a menu", "show me my clipboard history", "make my Mac quiet", "turn on do not disturb", "uppercase what I've got selected", "copy this file to my clipboard", or when you need a human decision mid-task and a terminal prompt would be the wrong place for it.
---

# Pounce — the scriptable command palette

Pounce is a native macOS command palette: a daemon plus a window the user
summons with ⌘Space. Everything it does is reachable from the `pounce` command,
which is what makes it useful to you.

The capability worth knowing about is not "open the launcher". It is that
**`pounce` is a picker you can put in front of a human**: pipe it lines, it
shows a native fuzzy-searchable window, and it prints back the one they chose.
When you need a decision and a terminal prompt is the wrong place for it — the
user is in another app, the list is long, the options need scanning — this is
better than asking.

## Ask the user to choose

```sh
printf 'staging\nproduction\n' | pounce -p "Deploy where?" -i shippingbox
```

**Read the output carefully — it is not the bare line.** Every commit prints
`"<action>\t<what they committed>"`, so choosing `production` gives you
`enter⇥production`. Split on the first tab: the left half is `enter`, `cmd`,
`opt` or `ctrl` (so one step can offer several verbs), the right half is the
**whole stdin line** they picked — if you fed it TSV rows, you get every column
back, not just the label. Free-typed text that matched no row comes back in
exactly the same shape.

Dismissal is **exit 1 with no output**. Always handle it: a dismissed picker is
the user saying no, not a reason to retry.

| flag | what it does |
|---|---|
| `-p <prompt>` | the placeholder text in the box |
| `-i <sf-symbol>` | the icon beside it — a **real** SF Symbol name; an unknown one silently draws nothing |
| `--query <text>` | open with the box pre-filled, caret at the end |
| `--actions <spec>` | label the action bar — **only when there are no rows**: `"Spawn\|cmd:Screenshot\|opt:Drafts"` |
| `--chain [keys]` | this commit feeds *another* pounce step — holds the window up instead of fading |
| `--draft <key>` | keep typed text on dismissal, filed under `<key>` |
| `--dial <spec>` | an option the user cycles in place with ⇥ / ⇧⇥: `"model=sonnet\|opus\|haiku"`. Repeatable. **Changes the output shape** — see below |
| `--grid` | lay the rows out as cards, two to a row — ↑↓ move by a card row, ←→ by one card (at the ends of the typed text; inside it they still move the caret). Purely a shape; output is unchanged |

`--grid` is for a step offering **things** rather than names — projects,
machines, images, environments — where each option wants an icon and a line of
description rather than a filename you scan. Feed it the same `title⇥subtitle⇥icon`
lines and it draws them two to a row; typing still filters, ⏎ still commits, and
the printed result is byte-for-byte what the list would have printed. Group
fields are still honoured as ORDER but no group headers are drawn, and
`--launcher` ignores the flag.

```sh
printf 'nebelung\tthe palette\tpaintpalette\npounce\tthe launcher\tbolt\n' \
  | pounce --grid -p "Which repo?"
```

`--dial` puts a small chip in the action bar the user steps through without
leaving the box — "which model", "public or private" — so one step can carry a
side-question that doesn't deserve its own picker. When you passed it, the
output grows **one extra middle field** with the committed values:
`enter⇥model=opus⇥<line-or-text>`. Only `--dial` callers see three fields, so
nothing existing breaks — but *you* must split accordingly, and tolerate the
middle field being absent (a resident daemon older than this flag ignores it
and answers in the two-field shape). Each dial re-opens on the value the user
committed last time, remembered per option-set; the first option is the
default until then.

The picker works whether or not the daemon is running — it falls back to
drawing the window itself.

## Other verbs

| do this | run this |
|---|---|
| make the Mac quiet | `pounce focus on` / `off` / `toggle` |
| is it quiet? | `pounce focus status` → `on` or `off` |
| open clipboard history | `pounce run mode:clipboard` |
| open the emoji / screenshot / file-search window | `pounce run mode:emoji` · `mode:screenshots` · `mode:filesearch` |
| open the launcher itself | `pounce run mode:launcher` |
| run one configured item | `pounce run cmd:emoji` · `app:/Applications/Foo.app` · `shortcut:<uuid>` |
| open a System Settings pane, or one setting in it | `pounce run setting:com.apple.Displays-Settings.extension[?<anchor>]` |
| transform the user's current selection | `pounce --transform 'tr "[:lower:]" "[:upper:]"'` |
| put a file on the clipboard | `pounce --copy-file <path>` |
| list / read / drop drafts | `pounce drafts <key> list \| get <n> \| rm <n> \| clear` |
| where is the config? | `pounce config` |
| what settings exist, with defaults? | `pounce config print` |
| let the user change a setting themselves | `pounce settings` opens the Settings window |
| is the hotkey actually working? | `pounce doctor` |
| **doctor looks fine and it's still broken** | `pounce report --print` — the doctor report plus version, macOS and install cohort, ready to paste into an issue (drop `--print` to open the form) |
| everything, exhaustively | `pounce --help` |

`pounce config print` is the honest answer to "what can I configure?" — it
prints every setting at its default, annotated. Read that rather than guessing
key names. `pounce config init` writes the same thing as the user's own
`config.json` with everything commented out.

`pounce settings` opens the same list as a window the USER clicks through —
reach for it when they want to change something themselves rather than have you
edit the file. It writes one line of `config.json` per click and leaves the rest
alone, so it and a hand edit are the same door. It is read-only on a
haus-managed Mac (see below), and says so.

`pounce drafts <key> list` prints `<index>\t<preview>\t<age>`, newest first —
ready to turn back into picker rows.

## When to reach for this

- **You need the user to choose.** Generate the lines, pipe them in. This is
  the reason to know pounce exists.
- "make my Mac quiet" / "turn on do not disturb" / "hush" → `pounce focus on`
- "uppercase / reformat what I've got selected" → `pounce --transform '<filter>'`
- "what did I copy earlier?" → `pounce run mode:clipboard` opens the window.
  You **cannot read the history yourself** — say so rather than guessing.
- "the ⌘Space palette stopped working" → `pounce doctor` names what is
  shadowing the hotkey (skhd, AeroSpace, Raycast, a macOS shortcut).

## When NOT to

- **The question is small and the user is in the terminal with you.** Just ask.
  A window that steals attention for a yes/no is worse than a line of text.
- **You want machine-readable output.** There is no `--json` anywhere in pounce
  yet. Read verbs print human text or TSV; parse them carefully or not at all.
- **You want to change what's in the palette.** Items, commands and the hotkey
  live in `~/.config/pounce/config.json` and
  `~/.config/pounce/commands` — edit those files, or hand the user `pounce
  settings`. On a machine running haus, they are generated: change
  `haus.launcher.*` instead and rebuild, or the next rebuild reverts you (the
  Settings window is read-only there for exactly that reason).
- **You want a notification.** That's `trill send`.
- **You want to hold a file for dragging.** That's `perch add`.
- **You are not on a logged-in macOS GUI session.** Every window verb needs one;
  there is no headless mode.

## Traps

- **The picker's output is `action⇥line`, never the bare line.** This is the
  single most common way to misuse pounce: you compare the result to
  `production`, it is actually `enter⇥production`, no branch matches, and you
  re-prompt a user who already answered. Split on the first tab, every time.
- **A dismissed picker is a real outcome.** Esc, click-away and empty stdin all
  end with nothing chosen — exit 1, no output. Treat it as "the user declined",
  never as a reason to re-prompt.
- **`pounce run …` needs the daemon; the picker doesn't.** Every `mode:`,
  `cmd:`, `app:`, `shortcut:` and `setting:` row exits 1 with "daemon not running" if it
  isn't up. That is a different failure from the user dismissing something.
- **Never put a picker in a loop or a background script.** It takes the screen.
  One decision, then get out of the way.
- **`--transform` acts on whatever is selected *right now*.** It copies, filters
  and pastes back. If the user has moved on, it edits the wrong thing — only
  reach for it immediately after they've asked.
- **`focus` needs Accessibility and Full Disk Access**, held by the signed
  `Pounce.app`. A caller without them forwards to the daemon automatically, so
  don't try to grant anything yourself.
- **The daemon runs on launchd's bare `PATH`** — no Homebrew, no Nix. A command
  script that shells out to an external tool must carry its own bindir prelude.
- **No `--json`, anywhere.** If you find yourself writing a parser for pounce's
  output, stop and tell the user what you'd need instead.
