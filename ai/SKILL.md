---
name: pounce
description: Drive the Mac's command palette from a script — and, most usefully, put a native picker in front of the user to choose from a list you generate, instead of asking them to type an answer. Use when the user says "ask me which one", "let me pick", "give me a menu", "show me my clipboard history", "make my Mac quiet", "turn on do not disturb", "uppercase what I've got selected", "copy this file to my clipboard", or when you need a human decision mid-task and a terminal prompt would be the wrong place for it.
---

# Pounce — the scriptable command palette

Pounce is a native macOS command palette: a daemon plus a window the user summons
with ⌘Space, and everything it does is reachable from the `pounce` command.

The capability worth knowing about is not "open the launcher". It is that
**`pounce` is a picker you can put in front of a human**: pipe it lines, it shows
a native fuzzy-searchable window, and prints back the one they chose. Reach for
it when a terminal prompt is the wrong place for a decision — the user is in
another app, the list is long, the options need scanning.

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
| `--grid` | lay the rows out as cards, two to a row — ↑↓ move by a card row, ←→ by one card (at the ends of the typed text; inside it they still move the caret). Purely a shape; output is unchanged, and `--launcher` ignores it |

`--grid` suits a step offering **things** rather than names — projects, machines,
images — each with an icon and a line of description. Groups order but draw no headers.

`--dial` puts a chip in the action bar the user steps through without leaving
the box — "which model", "public or private" — so one step carries a
side-question that doesn't deserve its own picker. Passing it grows the output by
**one extra middle field**: `enter⇥model=opus⇥<line-or-text>`. Only `--dial`
callers see three fields, so split accordingly, and tolerate it being absent (a
daemon older than the flag answers in the two-field shape). Each dial re-opens
on the value committed last time.

The picker works with or without the daemon — it falls back to drawing the window.

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
| …as data, with each draft's whole text | `pounce drafts <key> list --json` |
| where is the config — and is it mine to edit? | `pounce config --json` |
| what settings exist, with defaults? | `pounce config print` |
| what are the settings *right now*? | `pounce config print --json` |
| let the user change a setting themselves | `pounce settings` opens the Settings window |
| is the hotkey actually working? | `pounce doctor` (`--json` for the checks as data) |
| teach an agent about pounce on this Mac | `pounce skill` · `pounce skill install` |
| **doctor looks fine and it's still broken** | `pounce report --print` — the doctor report plus version, macOS and install cohort, ready to paste into an issue (drop `--print` to open the form) |
| everything, exhaustively | `pounce --help` |

`pounce config print` answers "what can I configure?" — every setting at its
default, annotated. `--json` answers a different question: the values pounce will
**actually use**, plus `set`, the keys the user's file really names, so "unset"
and "set to the default" stop looking alike. Read one rather than guess key names.

`pounce settings` opens that same list as a window the USER clicks through, for
when they'd rather change something themselves than have you edit the file. It
writes one line of `config.json` per click, and is read-only on a haus Mac.

`pounce drafts <key> list` prints `<index>\t<preview>\t<age>`, newest first —
ready to turn back into picker rows; `--json` adds each draft's full text.

Exit codes: **0** ok · **1** nothing came back (dismissed picker, missing draft,
unhealthy doctor, no daemon) · **2** usage · **3** refused. `focus` has its own.

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
- **You want to read the clipboard or the palette's item list.** Neither has a
  read verb — `pounce run mode:clipboard` opens a window for the user, and that
  is all. Say so rather than inventing one.
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
- **`--json` is on the read verbs, never on the picker.** `drafts`, `config`,
  `doctor`, `focus` and `autostart` take it; a committed row stays `action⇥line`
  and always will. If you are writing a parser for anything else, stop and ask.
