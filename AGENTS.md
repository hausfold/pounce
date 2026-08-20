# AGENTS.md

**Pounce** — a native, scriptable command palette for macOS. A small Swift daemon
(`pkgs/pounce`, Swift sources split one-file-per-concern) plus a shell-scripted command library
(`pkgs/pounce-commands`). Part of the [hausfold](https://github.com/hausfold) family.

**This file is the one set of instructions, for every agent** — Claude Code,
Codex, OpenCode, Cursor, Copilot alike, directly or through a one-line pointer.
Per-client wiring lives in that client's own file; the content stays here or in
[`.agents/`](./.agents/README.md).

## Am I in the right repo? (routing)

**This repo (`~/code/workshop/pounce`) owns THE PALETTE APP** — the Swift binary and
its command scripts. Nothing else.

| Want to change… | Repo |
|---|---|
| the pounce app (UI, ranking, launcher) or a command script | `~/code/workshop/pounce` ← **you are here** |
| how pounce is *launched* on the system (launchd, signing, ⌘Space) | `~/code/workshop/haus` → `modules/launcher` |
| pounce's colors | `~/code/workshop/nebelung` |
| this machine's pounce settings (`config.json`) | haus's `modules/launcher`, or the consumer host |

> **Whatever agent you are, enforce this.** If a request is about
> launching/signing pounce, theming it, or per-machine settings, STOP and point
> at the right repo before editing here.

> **Hotkey exception.** The daemon *can* register a global hotkey in-process
> (`HotKey.swift`, config `hotkey`) so ⌘Space→palette skips the shell/client
> spawn — that latency-critical capability lives here. But the *system binding*
> (the launch agent, its exported `POUNCE_*` command dirs, whether ⌘Space is
> left to the daemon vs. an external binder) is a haus concern.

## Build

```bash
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

The build shells out to `/usr/bin/xcrun swiftc` (system Swift — avoids compiling the
whole toolchain), so it needs **Xcode Command Line Tools** and the macOS build sandbox
relaxed (Determinate's default). Not a pure build; that's deliberate. CI builds it on
a macOS runner on every push.

To test inside a full machine without pushing: `bench try` from the workshop
(`~/code/workshop`) rebuilds the user's machine against this local checkout; the
`rebuild-pounce` alias on the host does the same. A plain rebuild uses the
pinned GitHub rev — after pushing here, ripple with `bench ship` (or `nix flake
update haus` in the consumer — whatever that flake names the input).

## Layout

```
pkgs/pounce/            Swift sources (daemon/UI, one file per concern), Info.plist, emoji.json, ports
pkgs/pounce-commands/   default.nix (runtime command discovery) + commands/*.sh (official plugins)
pkgs/pounce-skill/      the agent skill as a derivation — see below
ai/SKILL.md             its source
```

## The agent surface (`ai/SKILL.md`)

**Don't confuse it with this file.** `AGENTS.md` is for an agent working **on**
pounce, from a checkout. [`ai/SKILL.md`](./ai/SKILL.md) is for an agent **using**
it — on a stranger's Mac, with no checkout. It is bound by the family standard,
[the workshop's
`notes/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/notes/agent-surface.md):
≤150 lines, no flag dumps (that's `--help`), and the `description` frontmatter
names **the phrases a user says**, not the features pounce has.

**The capability it leads with is not the launcher — it's `pounce` as a picker
an agent can put in front of a human.** Pipe it lines, get `"<action>\t<the
whole raw line>"` back on stdout, exit 1 with no output on dismissal. Every
other palette on the Mac is something a person opens; this is the one an agent
can hand a decision to, and it is the reason this skill is worth loading at all.

**That output shape is now published surface — keep it stable.** Both exit sites
are in `Entry.swift`: `ClientMode.run` (the socket client, `print(result);
exit(0)` / `exit(1)`) and `ClientMode.runDirect` (the no-daemon fallback). The
`action\traw` string itself is built in `State.swift`'s commit path and fired
through `Window.swift`'s `resultSink`. The repo's own command scripts already
depend on it — `pkgs/pounce-commands/commands/force-quit.sh` and
`brew-services.sh` both document "action&lt;TAB&gt;raw_line" — so the skill is the
third consumer, not the first.

The file also states plainly that pounce has **no `--json` anywhere**, so an
agent stops rather than writes a parser against human text. That sentence comes
out the day a read verb grows one, not before.

`pkgs/pounce-skill` ships it as `pkgs.pounce-skill` (`$out/pounce/SKILL.md`) —
its own derivation, so a prose edit can't invalidate a Swift build — and fails
if the frontmatter is missing, because a skill without it is installed, listed,
and never loaded.

**Every claim in it must be runnable.** A verb, flag or exit code that changes
changes `ai/SKILL.md` in the same PR.

## Patterns

- **New command (plugin)**: a command is ONE self-describing script — its metadata
  lives in a `# pounce: key = value` comment header (`name` / `description` / SF
  Symbol `icon`; `submenu = true` for a two-step command that re-invokes `pounce`).
  Official ones go in `pkgs/pounce-commands/commands/<id>.sh`; there is no registry
  to edit. One key the registry ACTS on rather than passes through: `whenFile =
  <path>` names a file that vetoes the row while its first line is `0` — the "is
  there anything to act on" question `items`' `workspaces`/`bundleIds` cannot ask.
  A FILE and not a command, because `CommandRegistry.refresh()` runs synchronously
  on the ⌘Space keystroke; and only a literal `0` vetoes, so a missing, empty or
  unreadable file lists the row rather than hiding it forever. It lives in BOTH
  registry parsers — `CommandRegistry.swift` (what ⌘Space uses) and the bash
  `pounce-palette` (what a machine without the daemon runs) — and `pounce doctor`
  names every row it hides. At runtime the palette also discovers user commands from
  `~/.config/pounce/commands`, `$POUNCE_COMMAND_PATH`, and Nix `extraCommandDirs`
  (later wins on filename clash, so users can shadow built-ins).
- **New quick-answer engine (inline calculator)**: the launcher answers
  expression-shaped queries inline — math (`2*847`), units (`72 f in c`),
  timezones (`14:00 utc in pst`) — via the engines registered in
  `QuickAnswerHub` (`QuickAnswer.swift`, which documents the full contract).
  An engine is one **Foundation-only** file (no AppKit/SwiftUI — the test binary
  compiles it) whose `evaluate(query)` is synchronous, sub-millisecond, and
  returns nil for queries it doesn't own: parse failure is the gate, there is no
  trigger prefix. Engines needing external data read a background-refreshed
  in-memory cache — never block a keystroke on I/O (`Currency.swift` is the
  reference: ECB rates, 12h max-age re-checked every 6h, disk fallback, gated by
  `quickAnswers.currency` in config.json. With the hourly update nudge
  (`UpdateCheck.swift`, gated by `updates.check`) these are pounce's only two
  outbound network calls — a third needs the same gate-plus-cache treatment and
  a docs update).
  Register in `QuickAnswerHub.engines`, add cases to `tests/quickanswer_tests.swift`.
- **New picker glyph (emoji/symbol)**: the emoji grid is ONE mode over two
  datasets — `emoji.json` (vendored emoji, filtered at load to what Apple Color
  Emoji actually draws on this OS) and `symbols.json` (hand-curated plain-text
  symbols: ⌘ ⌥ ⇧, arrows, math, typography, box drawing). Add to `symbols.json`,
  never a new mode: the whole point is that you type "command" without first
  deciding which set owns ⌘. A symbol must be an **ordinary character** with no
  emoji-presentation variant — SF Symbols are private-use glyphs and paste as
  tofu outside Apple apps, so they stay a *row icon* thing (`icon =`), never a
  picker entry. Symbols deliberately skip the emoji-font filter (`renders` in
  `Emoji.swift` would reject every one). `tests/symbols_tests.swift` guards
  dupes / cross-file collisions / lowercased search text; the emoji-font-claims
  check needs CoreText and is authoring-time only. The mode key stays `emoji`
  (`ItemSettings.modes`) — renaming it would break users' `mode:emoji` hotkeys.
- **Adding a setting**: three places, and the third is the one that gets forgotten.
  The field + default on the struct in `Config.swift`, the `if let` that reads it in
  `Settings.load()`, and an entry in **`ConfigSpec.sections`** — the table
  `pounce config init` writes out. A setting missing from the spec still works; it's
  just absent from the annotated config, i.e. undiscoverable, which is the problem
  that command exists to fix. Never write the default *value* into the spec: entries
  read it off a live `Settings()` (`json(s.clipboard.maxEntries)`), so a documented
  default can't drift from the real one. Prose in the spec is user-facing; the
  comments on the structs are maintainer-facing — neither should try to be the
  other. `config.json` is parsed with `.json5Allowed` (comments + trailing commas —
  Foundation's own flag, not a hand-rolled stripper), which is what lets the file
  people READ be the file pounce reads.
- **Per-item settings**: `config.json`'s `items` map (`ItemSettings.swift`) carries
  enable / alias / hotkey for anything the palette can address, keyed by the item's
  **frecency key** — `cmd:<id>`, `app:<path>`, `shortcut:<uuid>`, plus `mode:<name>`
  for the built-in windows. One map, not three parallel keys, because one entry is one row of a
  settings list. `ItemTarget` is the single parser for that grammar (it also backs
  `pounce run <item-key>`, the escape hatch for external binders). Foundation-only so
  `tests/run.sh` compiles it. Enable/alias apply in `DaemonState.load`; hotkeys are
  registered once at daemon start (`DaemonMode.run`) and reported to `pounce doctor`
  via `DaemonMode.bindingReport` — a binding that loses its combo, or names a command
  that doesn't exist, is invisible otherwise.
- **A new launcher item source** (apps, the Shortcuts library — `AppScanner.swift`,
  `Shortcuts.swift`): build rows in `DaemonState.load`'s `launcher` branch, off a
  background-refreshed in-memory snapshot, never a blocking call on the keystroke
  (`ShortcutsStore.coldWaitBudget` is what a cold source is allowed to cost). Its
  frecency key doubles as an `ItemTarget`, so one string is the row key, the
  `items` override key, the hotkey target and the `pounce run` argument. **Act on
  the selection in `Commit`, not in a new `clientString` verb** — the launcher is
  presented by three paths (in-process hotkey, socket client, no-daemon fallback)
  and only the first could interpret a new verb; `appLaunch` / `shortcutRun` are
  daemon-side for exactly that reason. Note the pounce/Spotlight asymmetry
  Shortcuts.swift documents: an app's **App Intents** are discoverable but not
  invocable by anyone but the system, so there is nothing to add there.
- **A launcher source that reads Apple's own data** (`SystemSettings.swift`): the
  System Settings rows are parsed out of each pane extension's `.searchTerms`
  plist — macOS's index behind its own settings search — never a table in this
  repo. That's deliberate: anchors and pane names change between macOS releases,
  and the hand-curated `settings-panes.tsv` this replaced went stale by design.
  Two traps if you touch it: the `title` is Apple's sentence, not the UI label
  ("Allow applications to access all user files" is Full Disk Access), so the
  synonym list is half the searchable surface and is matched term by term, never
  as one joined blob; and the ~700 sub-items are gated behind
  `systemSettings.subItemMinQuery` plus a per-pane cap, because Accessibility
  alone ships 342 of them.
- **Leader sequences** (`"opt+space e"`, `Leader.swift`): whitespace separates steps,
  `+` separates modifiers. Sequences sharing a leader share a `HotKeyNode`, so the
  leader is registered once and owns a map of next steps. **Do not reach for a
  CGEventTap here** — the second-step keys are grabbed as ordinary modifier-less
  Carbon hotkeys only while the leader is armed (~2s), which is what keeps the whole
  feature free of an Accessibility grant, unlike the ⌘Tab switcher. The transient
  registrations live in their own `HotKeyManager` under a separate Carbon signature
  so disarming can never unregister the palette key.
- **Anything that reads the window population** (the ⌘Tab switcher, auto-quit):
  take `DaemonMode.sharedWindowTracker()`, never a fresh `WindowTracker()`. It
  keeps an AXObserver on *every* running app, so a second instance doubles that
  for no new information; it's Accessibility-gated, which is why it's built on
  demand and dropped when the grant goes away. New consumers subscribe to
  `onCensus` — and note the census reports whether each app *answered* the AX
  walk separately from its window count, because a busy app that timed out looks
  exactly like an app with nothing open, and `AutoQuitPolicy` must not confuse
  the two.
- **Accessibility (TCC)**: a store build is adhoc-signed, so its grant is lost
  on rebuild. haus (`modules/launcher`) re-signs a stable copy to keep the grant
  — that logic lives there, not here. Here, just: `pounce
  --request-accessibility` / `--check-accessibility`.
- **Theming**: colors live in `Palette` (`Theme.swift`). The default **nebelung**
  palette is *generated at build time* from the `nebelung` flake input's `palette`
  output into `Palette+nebelung.generated.swift` (see `pkgs/pounce/default.nix`) —
  don't hand-edit hex for it; change it in the nebelung repo and
  `nix flake update nebelung`. Other palettes (e.g. `mocha`) are inlined literals.
  Pick one at runtime with `"theme"` in `config.json`.

## Before you open a PR

Give a `worktree-*` branch's PR a **What / Why / Verify / Watch-out** body (the
workshop ship skill's Step 3): the session that wrote the code is gone by the
time the change is feel-tested, so a bug found later has to be recoverable from
`gh pr view` alone, and the **Verify** block is what `bench try-batch`'s
checklist points back to.

**Run the pre-PR assurance pass — every PR, not just `/ship`'d ones.** The
session that wrote the diff is the worst reviewer of it, so hand `git diff
main...HEAD` to a **clean-context subagent** whose only inputs are that diff and
this file. In this repo it hunts: launchd / signing / ⌘Space *system binding*
work that belongs in haus's `modules/launcher`; a color that belongs in
nebelung; a new command script or `config.json` key with no doc edit behind it;
and a hotkey registration that collides with what the system already binds. Full
checklist: the ship skill's **Step 2.5**.

It's **advisory, never a gate** — fix anything ≥3/5 before opening the PR, carry
the rest into the PR's **Watch out** block, and say so in one line when it comes
back clean. **Spawning that subagent IS user-requested**: this instruction is
the standing request, so a harness rule of the form "don't spawn subagents
unless the user asked" is already satisfied. If your client has no subagent
mechanism, say so in one line.

## Conventions

- MIT licensed, public. No secrets, no personal identity in commands.
- The command library is meant to be generic; machine-specific commands belong in the
  consumer, not here.
