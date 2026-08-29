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
whole toolchain), so it needs **Xcode Command Line Tools 16 or newer** and the macOS
build sandbox relaxed (Determinate's default). Not a pure build; that's deliberate.
CI builds it on a `macos-15` runner on every push.

**Two different macOS versions are in play; don't conflate them.** The *SDK* floor is
15 — `Window.swift` overrides `contextMenuKeyDown:` / `showContextMenuForSelection:`,
which `NSResponder.h` only declares at macOS 15, and an SDK that lacks a method cannot
have it overridden at any target. That is why CLT 16+ is required to compile, and it
bites `brew install --build-from-source` too, since `build.sh` is the shared compile
step. The *deployment* floor is 14, and it has exactly one source: `MACOS_MIN` in
`build.sh`, which feeds both the compiler's `-target` and the `LSMinimumSystemVersion`
that `plutil` writes into the bundle — so the version the app refuses to launch on can
never disagree with the version it was compiled for. `tests/run.sh` carries the same
target by hand; keep the two in step. Raising either floor is user-facing — README's
stated requirement (currently "macOS 14 Sonoma or later") and the `#available` guards
in the sources move with it.

The *arch* half of that triple is a build input, not a guess: `default.nix` passes
`POUNCE_TARGET_ARCH` from `stdenvNoCC.hostPlatform.darwinArch`. `build.sh` falls back to
`uname -m` for non-Nix packagers, which is the builder's kernel and so is wrong under
Rosetta or an `x86_64-darwin` nix on Apple Silicon.

**A build under test cannot reach its own window while the installed daemon is
running.** `pounce -p …` hands the whole invocation to the daemon over
`~/.local/share/pounce/pounce.sock`, so the palette that appears is the DAEMON's
build and the binary you just compiled draws nothing — a fix can be feel-tested
twice against the old code without any sign that it never ran. `$HOME` is no help
(`SocketConfig.path` comes from `homeDirectoryForCurrentUser`, which reads
`getpwuid` and ignores the environment). Set `POUNCE_NO_DAEMON=1` to keep the
request in-process:

```bash
printf '' | POUNCE_NO_DAEMON=1 ./result/bin/pounce --actions "Go|ctrl:Other" -p "test"
```

To test inside a full machine without pushing: `bench try` from the workshop
(`~/code/workshop`) rebuilds the user's machine against this local checkout; the
`rebuild-pounce` alias on the host does the same. A plain rebuild uses the
pinned GitHub rev — after pushing here, ripple with `bench ship` (or `nix flake
update haus` in the consumer — whatever that flake names the input).

## Layout

```
pkgs/pounce/            Swift sources (daemon/UI, one file per concern), Info.plist, emoji.json, ports
                        Config*.swift = the settings table + its two renderers;
                        Settings*.swift = the Settings window over them
                        AppIcon.iconset/ = the app-icon slots build.sh feeds to iconutil.
                        Here, not ../assets, because `src = ./.` is this dir alone
pkgs/pounce-commands/   default.nix (runtime command discovery) + commands/*.sh (official plugins)
pkgs/pounce-skill/      the agent skill as a derivation — see below
ai/SKILL.md             its source
```

## The agent surface (`ai/SKILL.md`)

**Don't confuse it with this file.** `AGENTS.md` is for an agent working **on**
pounce, from a checkout. [`ai/SKILL.md`](./ai/SKILL.md) is for an agent **using**
it — on a stranger's Mac, with no checkout. It is bound by the family standard,
[the workshop's
`docs/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/docs/agent-surface.md):
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
third consumer, not the first. The one sanctioned variation is `--dial`
(`Dials.swift`): a step that declared dials gets its committed values back as
an extra MIDDLE field (`action\tname=value;…\traw`) — strictly opt-in per
invocation, so a caller that never passed the flag keeps the two-field shape
forever.

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
- **Changing how the launcher ranks**: a handful of numbers, spread over five
  files, and they are calibrated against each other — move one and the others
  need re-deriving.
  `Frecency.swift` holds usage as TWO decayed averages (`short`, 24h half-life —
  what I'm doing today; `long`, 30d — who I am), each decayed **at write time**,
  which is what stops one click un-decaying a whole history the way the old
  single-timestamp `count` did. `shortWeight` (15) is what makes a burst able to
  outrank a habit, and it is only meaningful against the plateaus those two
  half-lives produce — `tests/frecency_tests.swift` pins both, so changing a
  half-life fails there rather than silently rescaling the launcher.
  `rankWeight` is how habit enters a TYPED query: a logarithm, because the
  `s/(s+5)` it replaced saturated by a score of 20 and real stores span 0–350,
  which left habit worth ~4% of the decision. `QueryMemory.swift` is the pairing
  memory — query (and each prefix) → the row taken — and is the only thing that
  can rank an item the fuzzy pass rejects outright (`rescueBoost`, two picks
  minimum). `ContextMemory.swift` conditions all of it on WHERE you were — the
  frontmost app, the workspace, a four-hour block of the day, weekday/weekend —
  as a multiplicative `× (1 + β·lift)` where the lift is how much likelier an
  item is under its strongest facet than in general. Deliberately small (β 0.08)
  and promotion-only: context settles near-ties, it never buries a row for being
  new somewhere, and typing a name still means that name. `StageSlots.swift`
  ranks the tile strip on `long` ALONE and holds its positions, because ⌘1–⌘9
  fire tiles and a number that moves is worse than no number.
  `NextAction.swift` is the odd one out and stays that way ON PURPOSE: a bigram
  (what you committed → what you committed next, inside five minutes) that never
  enters the scoring pass at all. A confident one becomes the Stage's NEXT card,
  taken with ⇥ — never ⏎, which belongs to the selection — so a wrong guess costs
  a glance and can't displace the row you were reaching for.
  All of it is pure statics over data already in memory: the scoring pass
  runs on every keystroke over every item, so a new signal is a dictionary lookup
  precomputed once per query in `rankedMatches` (or once per SUMMON in `load`,
  where the context nudge and the prediction are built), never a second `Fuzzy`
  pass. The stores each own one JSON file under `~/.local/share/pounce`, written
  off the main thread on the commit path, and each splits its math into pure
  statics so `tests/run.sh` can pin it without a clock or a disk.
- **The Stage's info cards** (`Stage.swift`, `InfoCards`): **a card draws when it
  has something to say.** The clock taught that rule by breaking it — `TODAY
  14:32` drew on every summon, saying what the menu bar says all day, and a panel
  element that is never new trains the eye to skip the whole strip. So the row is
  news-first: NEXT (the prediction, rare and actionable), CLIPBOARD (invisible
  otherwise), and TODAY only as the resting face when neither has anything. A new
  card needs a predicate, not just a value.
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
  `Settings.load()`, and an entry in **`ConfigSpec.sections`** — the table that feeds
  BOTH `pounce config init` and the Settings window. A setting missing from the spec
  still works; it's just absent from the annotated config and from the window, i.e.
  undiscoverable, which is the problem both exist to fix. The spec entry can't be
  half-written: `control:` on the field and `pane:` on the section have no defaults,
  so a new setting with no widget and no home in the sidebar doesn't compile. Never
  write the default *value* into the spec: entries read it off a live `Settings()`
  (`json(s.clipboard.maxEntries)`), so a documented default can't drift from the real
  one. Prose in the spec is user-facing; the comments on the structs are
  maintainer-facing — neither should try to be the other. `config.json` is parsed with
  `.json5Allowed` (comments + trailing commas — Foundation's own flag, not a
  hand-rolled stripper), which is what lets the file people READ be the file pounce
  reads.
- **The Settings window** (`pounce settings` / `mode:settings` / the palette row):
  panes of cards over that same spec — `SettingsView.swift` arranges,
  `SettingsControls.swift` draws a `ConfigControl`, `SettingsStore.swift` reads and
  writes. It holds **no copy of the settings**: values are read back by handing
  `ConfigSpec.sections(defaults:)` a live `Settings.load()` (so the window shows the
  post-clamp value pounce will actually use) and written one line at a time with
  `ConfigWriter.apply`. **Never re-serialise config.json** — it is JSON5 with
  generated prose in it, and a round trip through `JSONSerialization` deletes every
  comment the user was invited to write. `ConfigWriter` refuses rather than guesses
  (a section folded onto one line has no line to edit); its `Outcome.refused` is a
  sentence for the user, not a log line. `SettingsChrome.swift` is a **verbatim copy**
  of trill's `Trill/UI/SettingsChrome.swift` — keep it diffable against that and
  perch's, and put pounce-only shapes in the other three files. A shared package was
  weighed and rejected: those two build through Xcode, this builds through a bare
  `swiftc` in Nix.
- **Per-item settings**: `config.json`'s `items` map (`ItemSettings.swift`) carries
  enable / alias / hotkey / hint / state for anything the palette can address, keyed by the item's
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
- **Anything that moves**: there is ONE spring — `Motion.spring` (`Motion.swift`),
  response 0.25 / damping 0.85 — and every *move* reads it: the selection glide
  between rows (`SelectionGlide`, one highlight body tied across rows by
  `matchedGeometryEffect` in a namespace the LIST owns), the dial roll, the action
  bar's press blink. A typed re-rank is deliberately NOT one of them: the list
  snaps into its new order the instant scoring returns — a reorder driven by
  keystrokes retargets several times a second, and springing it both reads as
  churn and taxes the keystroke being handled. A second
  `.spring(response:…)` literal in the sources IS the bug. `Motion.spring` is nil
  under System Settings › Accessibility › Reduce motion, so a new animation
  inherits that by using it and loses it by hand-rolling one — `SkeletonRow`'s
  loading pulse is the one deliberate non-spring (a "still working" signal has no
  destination, and a spring has no forever), and it consults `Motion.reduceMotion`
  by hand precisely because an indefinitely repeating pulse is what that setting
  exists to stop. Three rules:
  - **Latency.** Animate only frames SwiftUI was already drawing. Never delay
    first render, and never read anything off disk to decide how to animate
    (`Motion.reduceMotion` is cached behind an AppKit notification for that
    reason — don't inline the `NSWorkspace` property into a row body).
  - **Never let a transaction reach the resize.** The window's height is
    arithmetic and instant (`pendingContentHeight` → `PounceUI.resizeToFit`, with
    implicit animation off). Scope `.animation(_:value:)` to the subtree that
    moves, never to an ancestor of the frame that sizes the window.
  - **Animate a move the USER made.** A selection that jumps because the list
    re-ranked under a keystroke is leaving a row that may be scrolled out of the
    viewport, culled by the `LazyVStack`, or gone from the results — matched
    geometry given a source like that swoops in from outside the panel. Both
    lists gate on a `glideArmed` flag (disarmed in the query hook, re-armed when
    the selection settles); a new animated list wants the same gate.
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

## Notifications

**Never write a bare `osascript -e 'display notification …'`.** Every banner
pounce draws goes through the `notify()` helper each command carries: it sends
to **trill** — the family's notification compositor — when Trill.app is on the
Mac, and falls back to Apple's banner when it isn't. The Swift side does the
same in `UpdateCheck.postBanner`.

Three things about that helper are load-bearing, and copying it without them
breaks one of pounce's own rules:

- **Resolve the bundle, don't look for `trill` on PATH.** pounce installs
  standalone — Homebrew, a release ZIP, nix — and can assume neither that trill
  is present nor that anything put its CLI on PATH. The daemon's launchd PATH
  in particular names nothing anybody installed, which is the same trap the
  package-manager-bindir prelude exists for.
- **Give every command its own `--source`** (`pounce.ports`,
  `pounce.brew-services`, …). That string is what `~/.config/trill/rules.json`
  matches on, so it is the difference between a user silencing one chatty
  command and silencing pounce.
- **Fall back, always.** trill exiting non-zero (no daemon, exit 2) is the
  normal case on a Mac without it, not an error worth reporting — the message
  still has to reach the screen.

The AppleScript fallback in the **shell** helper passes both strings as `argv`
rather than interpolating them. It used to interpolate, which is why several
commands stripped double quotes out of their own bodies first: one in a body
ended the script string early. `UpdateCheck`'s fallback still interpolates, and
may only keep doing so while both halves stay what they are today — a
regex-vetted version string and a compile-time-constant hint. Put anything a
user or a server could influence in either and it needs `on run argv` too.

**A send trill accepts is not a send the user sees, and that is deliberate.**
Exit 0 means the daemon took the event; a rule, a digest or quiet hours can
still route it to the inbox instead of the screen. So on a Mac with trill and
quiet hours set, a confirmation you asked for by pressing a key — "force quit
Safari", "could not connect" — may land silently in the inbox where an
`osascript` banner would have shown. That is the user's own dial and pounce
must not second-guess it with a second banner; it is worth knowing before you
conclude a command stopped working.

## Conventions

- MIT licensed, public. No secrets, no personal identity in commands.
- The command library is meant to be generic; machine-specific commands belong in the
  consumer, not here.
