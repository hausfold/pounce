# AGENTS.md

**Pounce** — a native, scriptable command palette for macOS: a Swift daemon
(`pkgs/pounce`, one file per concern) plus a shell command library
(`pkgs/pounce-commands`), in the [hausfold](https://github.com/hausfold) family.
One instruction file for every client; per-client wiring is
[`.agents/README.md`](./.agents/README.md).

## Am I in the right repo? (routing)

No `haus.*` option is defined here.

| Want to change… | Repo |
|---|---|
| the app (UI, ranking, launcher), a command script, signing and notarizing (`release.yml`) | `~/code/workshop/pounce` ← **you are here** |
| the bug-report door: `pounce report [--print]` (`ReportMode` in `Entry.swift`, `BugReport.swift`), the palette row `report-issue-pounce.sh`, the Settings window's app menu | here; the form's `DIAG_HINT` in the workshop's `script/issue-templates.sh` names all three, and nothing checks they agree |
| how pounce is *launched*: launchd, the launch agent, its exported `POUNCE_*` command dirs, who owns ⌘Space | `~/code/workshop/haus` → `modules/launcher` |
| pounce's colors | `~/code/workshop/nebelung` |
| this machine's `config.json` | haus's `modules/launcher`, or the consumer host |
| the Homebrew formula | `homebrew-tap`, CI-owned |

**If a request is about launching pounce, theming it, or per-machine
settings, stop and point at the right repo before editing here.** The one
exception to the launcher row is the in-process global hotkey (`HotKey.swift`,
config `hotkey`), here because it is latency-critical.

## Build, test, release

```bash
nix build                  # -> ./result/Applications/Pounce.app + ./result/bin/pounce
pkgs/pounce/tests/run.sh   # pure-logic tests, pounce-palette parse, header grammar
script/check-skills.sh     # skill guards; CI and pkgs/pounce-skill both run it
```

CI (`build.yml`, `macos-15`) runs those, `shellcheck --severity=warning` over
the command scripts, and fails on any bare `display notification`.

`build.sh` shells out to `/usr/bin/xcrun swiftc`: **Xcode Command Line Tools
16+**, and the macOS build sandbox relaxed (Determinate's default). *SDK* floor
15: `Window.swift` overrides `contextMenuKeyDown:` /
`showContextMenuForSelection:`, which `NSResponder.h` declares only there, and
`brew install --build-from-source` needs it too. *Deployment* floor 14, from
`MACOS_MIN` in `build.sh` alone — it feeds `-target` and the
`LSMinimumSystemVersion` `plutil` writes; `tests/run.sh` seds it back out of
`build.sh` rather than repeating it, and exits 1 if that assignment is renamed
or reshaped. Raising either is user-facing: the README's "macOS 14 Sonoma or
later" and the `#available` guards move with it. `default.nix` passes
`POUNCE_TARGET_ARCH` from `stdenvNoCC.hostPlatform.darwinArch`; `build.sh`'s
`uname -m` fallback is wrong under Rosetta or an `x86_64-darwin` nix.

**A build under test cannot reach its own window while the installed daemon
runs**: `pounce -p …` goes over `~/.local/share/pounce/pounce.sock`, and
`$HOME` does not redirect it (`SocketConfig.path` reads
`homeDirectoryForCurrentUser`). Keep it in-process:

```bash
printf '' | POUNCE_NO_DAEMON=1 ./result/bin/pounce --actions "Go|ctrl:Other" -p "test"
```

`bench try` from `~/code/workshop` (or the host's `rebuild-pounce` alias)
builds this package, re-signs it and injects it through the `prebuilt` input;
ripple a push downstream with `bench ship`.

**What haus installs is the CI-built release, not this build**:
`pkgs.pounce-app` (`nix/app-prebuilt.nix`), the Developer-ID signed and
notarized app pinned by version + sha256 in `nix/release.nix`. `release.yml`
rewrites that CI-owned pin on main after every tag — never hand-bump it, and a
source change reaches haus machines only after the next release. `pounce` stays
the from-source dev package.

Releases are CalVer: `bench release pounce` stamps `version` in
`pkgs/pounce/default.nix` and tags `v<date>`; `release.yml` checks they match,
signs, notarizes, publishes the tarball and bumps the Homebrew tap. Never type
a version or hand-bump the formula.

## Layout

```
pkgs/pounce/            Swift sources, Info.plist, emoji.json, ports
                        Config*.swift = the settings table + its two renderers
                        Settings*.swift = the Settings window over them
                        AppIcon.iconset/ = app-icon slots for iconutil (here: `src = ./.` is this dir alone)
                        Json.swift = the one writer behind every --json
                        Skill.swift = `pounce skill`, over the embedded ai/SKILL.md
pkgs/pounce-commands/   default.nix (runtime command discovery) + commands/*.sh
pkgs/pounce-skill/      the agent skill as a derivation, for consumers
ai/SKILL.md             its source, also embedded in the binary by build.sh
script/check-skills.sh  the skill guards, run by BOTH CI and that derivation
```

## The agent surface (`ai/SKILL.md`)

[`ai/SKILL.md`](./ai/SKILL.md) is for an agent **using** pounce with no
checkout, bound by the workshop's
[`docs/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/docs/agent-surface.md):
≤150 lines, no flag dumps (that's `--help`), a `description` naming the phrases
a user says. A verb, flag or exit code that changes changes it in the same PR.
**It leads with pounce as a picker an agent hands a decision to, not as the
launcher** — that is the capability worth loading a skill for.

**The output shape is published surface — keep it stable.** Pipe lines in, get
`"<action>\t<the whole raw line>"` on stdout, exit 1 with no output on
dismissal. Exit sites `ClientMode.run` / `ClientMode.runDirect`
(`Entry.swift`); built in `State.swift`'s commit path, fired through
`Window.swift`'s `resultSink`; `force-quit.sh` and `brew-services.sh` parse it
already. `--dial` (`Dials.swift`) is the one variation: a middle field
(`action\tname=value;…\traw`), only when the caller passed the flag.

**`pounce skill` (`Skill.swift`) and `pounce skill install` are not optional
surface** — Homebrew and the DMG ship no haus to install the skill. `build.sh`
renders `ai/SKILL.md` into `Skill.generated.swift`; Nix passes it as
`POUNCE_SKILL_MD`, everyone else gets the relative default. `Skill.markdown`
re-adds the trailing newline the multiline literal drops, or every re-run
reports "exists and differs". `install` follows agent-surface's A3 refusals: it
names haus on a Nix symlink, writes `.differs` beside a file it will not
clobber, and gives a client haus doesn't manage (today `~/.codex/skills`) a
real file. `pkgs/pounce-skill` ships the same bytes as `pkgs.pounce-skill`
(`$out/<skill>/SKILL.md`) for haus; guards in `script/check-skills.sh`.

## Patterns

- **New command (plugin)**: one script in
  `pkgs/pounce-commands/commands/<id>.sh` (no registry), metadata in a
  `# pounce: key = value` header — `name`, `description`, SF Symbol `icon`,
  `submenu = true` for a two-step command that re-invokes `pounce` and reads
  the line it prints. `mutates` / `confirm` / `network` (`CommandRisk`,
  `CommandRegistry.swift`) are unverified claims shown by `pounce list
  [--json]`; only `confirm` acts — a sheet (`Confirm.swift`) before the script
  runs, so before a `submenu` picker opens, and `pounce run cmd:<id>` and
  hotkeys never ask. Booleans are `true` or `1` only (`confirm = yes` is
  false). `whenFile = <path>` hides the row while the file's first line is a
  literal `0`; missing or empty lists it, and `pounce doctor` names hidden
  rows. A file and not a command because `CommandRegistry.refresh()` runs
  synchronously inside `presentLauncher` on every ⌘Space — nothing on that path
  may block on a subprocess. **Every key lives in both parsers** —
  `CommandRegistry.swift` and the bash `pounce-palette` — pinned by
  `tests/fixtures/header-grammar.tsv` (haus's Nix copy reads only `cheat`).
  Discovery also reads `~/.config/pounce/commands`, `$POUNCE_COMMAND_PATH` and
  Nix `extraCommandDirs`; later wins on a clash.
- **Ranking** is calibrated across `Frecency.swift` (decayed averages `short`,
  24h half-life, and `long`, 30d; `shortWeight` 15; `rankWeight`, a logarithm),
  `QueryMemory.swift` (`rescueBoost` 2.5, the bar set between one pick and two),
  `ContextMemory.swift` (promotion-only, β 0.08), `StageSlots.swift` (tiles on
  `long` alone, positions held because ⌘1–⌘9 fire them — held still, not held
  wrong: `reorderMargin` 2× swaps one adjacent pair per summon, and `staleLead`
  3d drops `promoteMargin` to 1.0 against an incumbent idler than its
  challenger, which is why candidates carry an `idle`) and `NextAction.swift`
  (a bigram over a five-minute `window`, outside scoring — the NEXT card, taken
  with ⇥, never ⏎): change one number and re-derive the rest, against
  `tests/frecency_tests.swift`. A new signal is a lookup precomputed in
  `rankedMatches` or `load`, never a second `Fuzzy` pass. Stores live under
  `~/.local/share/pounce`, written off the main thread.
- **Stage info cards** (`Stage.swift`, `InfoCards`): NEXT, CLIPBOARD, TODAY as
  the resting face. A new card needs a predicate, not just a value.
- **Quick-answer engine**: the contract is `QuickAnswer.swift`; register in
  `QuickAnswerHub.engines`, cases in `tests/quickanswer_tests.swift`.
  Foundation-only, `evaluate(query)` synchronous and sub-millisecond, nil when
  not owned, no trigger prefix. External data comes off a background cache,
  never I/O on a keystroke — `Currency.swift` (`quickAnswers.currency`: ECB
  rates at a 12h `maxAge`, re-checked every 6h, disk fallback) and
  `UpdateCheck.swift` (`updates.check`, hourly) are the only outbound calls, and
  a third needs the same gate-plus-cache.
- **Picker glyph**: `emoji.json` (filtered at load to what Apple Color Emoji
  draws) plus `symbols.json`. Add to `symbols.json`, never a new mode, and
  ordinary characters only — SF Symbols paste as tofu and stay row icons
  (`icon =`). Symbols skip `Emoji.swift`'s `renders` filter;
  `tests/symbols_tests.swift` guards dupes. The mode key stays `emoji`
  (`ItemSettings.modes`) or `mode:emoji` hotkeys break.
- **Adding a setting**: field + default in `Config.swift`, the `if let` in
  `Settings.load()`, an entry in **`ConfigSpec.sections`** (feeds `pounce config
  init` and the Settings window; `control:` and `pane:` required). The third is
  the step that gets forgotten, because a setting missing from the spec still
  works — it is just absent from the annotated config and from the window. Never
  write the default into the spec: entries read a live `Settings()`
  (`json(s.clipboard.maxEntries)`). `config.json` is parsed `.json5Allowed`.
- **The Settings window** (`pounce settings` / `mode:settings`):
  `SettingsView.swift`, `SettingsControls.swift` (`ConfigControl`),
  `SettingsStore.swift`. No copy of the settings —
  `ConfigSpec.sections(defaults:)` over a live `Settings.load()`, written line
  by line by `ConfigWriter.apply`. **Never re-serialise config.json**
  (`JSONSerialization` deletes every comment); `ConfigWriter` refuses rather
  than guesses, and `Outcome.refused` is a user sentence. `SettingsChrome.swift`
  is a verbatim copy of trill's `Trill/UI/SettingsChrome.swift` — keep it
  diffable against that and perch's, and put pounce-only shapes in the other
  three files.
- **A new `--json` or read verb**: through `Json.swift` — sorted keys,
  unescaped slashes, `schema` from `Json.record`; renaming or removing a key
  moves that number. Additive only: `drafts <key> list` keeps TSV (haus's
  `spawn-agent.sh` reads it), `focus status` keeps bare `on`/`off`. A read verb
  answers on stdout even for "no" (`drafts get --json` prints `"found": false`,
  exits 1); a write verb prints a receipt; `Json.value(_:)` keeps unknowns
  `null` (`doctor --json` with no daemon: `accessibility` present-and-null).
  Exit codes are `pounce --help`'s table (0 ok · 1 nothing came back · 2 usage ·
  3 refused); `focus` keeps its own. A daemon verb checks capability
  first — an unknown payload falls through `handleClient` and draws as a
  one-row picker — so `STATUS` carries `commands: true` and `ListMode` gates on
  it.
- **Per-item settings**: `config.json`'s `items` map (`ItemSettings.swift`),
  keyed by frecency key — `cmd:<id>`, `app:<path>`, `shortcut:<uuid>`,
  `mode:<name>`. `ItemTarget` is the one parser (also behind `pounce run
  <item-key>`), Foundation-only. `enabled` and `alias` apply in
  `DaemonState.load`, `workspaces` / `bundleIds` scope the row to a context and
  never its `hotkey`, `hint` draws a trailing keycap for a binding pounce does
  not register, `state` runs a read-only command whose first stdout line becomes
  the row's badge (`Badges.swift`), and hotkeys register at `DaemonMode.run`,
  reaching `pounce doctor` via `DaemonMode.bindingReport`.
- **A new launcher item source** (`AppScanner.swift`, `Shortcuts.swift`): rows
  in `DaemonState.load`'s `launcher` branch, off a background snapshot
  (`ShortcutsStore.coldWaitBudget`). Act in `Commit`, never a new
  `clientString` verb — `appLaunch` / `shortcutRun` are daemon-side because
  only the in-process hotkey path could interpret one. App Intents are not
  invocable.
- **`SystemSettings.swift`**: rows come from each pane extension's
  `.searchTerms` plist, never a table here. The `title` is Apple's sentence,
  not the UI label, so synonyms carry half the search and match term by term.
  Sub-items are gated by `systemSettings.subItemMinQuery` plus a per-pane cap.
- **Leader sequences** (`"opt+space e"`, `Leader.swift`): whitespace separates
  steps, `+` modifiers, one `HotKeyNode` per leader. No CGEventTap —
  second-step keys are transient Carbon hotkeys while armed (~2s), so no
  Accessibility grant, in their own `HotKeyManager` under a separate Carbon
  signature.
- **Window population** (⌘Tab switcher, auto-quit):
  `DaemonMode.sharedWindowTracker()`, never a fresh `WindowTracker()`;
  subscribe to `onCensus`, which reports "answered" apart from window count —
  `AutoQuitPolicy` must not confuse the two.
- **TCC**: an adhoc build loses its Accessibility grant on rebuild — hence haus
  runs `pkgs.pounce-app` and `bench try` re-signs (`pounce
  --request-accessibility` / `--check-accessibility`). Automation is separate:
  `tell application` (`lock.sh`, `force-quit.sh`) needs
  `com.apple.security.automation.apple-events` in `Pounce.entitlements` or is
  dropped silently, a bare `osascript` without `tell` does not, and
  `NSAppleEventsUsageDescription` in `Info.plist` must keep naming the
  commands. No `--check-automation`, on purpose.
- **Anything that moves**: one spring, `Motion.spring` (`Motion.swift`,
  response 0.25 / damping 0.85), read by every move — a second
  `.spring(response:…)` literal is the bug. Nil under Reduce motion;
  `SkeletonRow`'s pulse is the one non-spring and reads `Motion.reduceMotion` by
  hand. A typed re-rank snaps. Animate only frames SwiftUI was already drawing:
  never delay first render, and never read disk to animate
  (`Motion.reduceMotion` is cached — don't inline the `NSWorkspace` property);
  never let a transaction reach the resize (`pendingContentHeight` →
  `PounceUI.resizeToFit`, so scope `.animation(_:value:)` below the sizing
  frame); animate only a move the user made (`glideArmed`).
- **Theming**: `Palette` (`Theme.swift`). The nebelung palette is generated
  into `Palette+nebelung.generated.swift` (`pkgs/pounce/default.nix`) from the
  `nebelung` input's `palette` output — change it there, then `nix flake update
  nebelung`. Other palettes (`mocha`) are inlined; `"theme"` in `config.json`
  picks one.

## Before you open a PR

Give the PR a **What / Why / Verify / Watch-out** body (the workshop ship
skill's Step 3): `gh pr view` is all a later bug report has, and the Verify
block is what `bench try-batch`'s checklist points back to.

**Run the pre-PR assurance pass on every PR, not just `/ship`s.** Hand `git diff
main...HEAD` to a clean-context subagent whose only inputs are that diff and
this file; the full checklist is the ship skill's Step 2.5. Here it hunts:
launchd / ⌘Space *system binding* work that belongs in haus's
`modules/launcher`; a color that belongs in nebelung; a command script or
`config.json` key with no doc edit; a hotkey colliding with one the system
binds. Advisory, never a gate — fix anything ≥3/5 first, carry the rest into
**Watch out**, say so in one line when it comes back clean. **Spawning that
subagent is user-requested**: this instruction is the standing request, so a
harness rule against unasked subagents is already satisfied. If your client has
no subagent mechanism, say so in one line.

## Notifications

**Never write a bare `osascript -e 'display notification …'`** — CI fails on
one. Every banner goes through the `notify()` helper each command carries
(Swift: `UpdateCheck.postBanner`): trill when Trill.app is on the Mac, Apple's
banner otherwise. Copying it:

- Resolve the bundle; never look for `trill` on PATH — the daemon's launchd
  PATH names nothing anybody installed.
- Every command gets its own `--source` (`pounce.ports`,
  `pounce.brew-services`, …): that is what `~/.config/trill/rules.json` matches
  on.
- Fall back always: trill exiting non-zero (exit 2, no daemon) is normal.
- The shell fallback passes both strings as `argv` (`on run argv`);
  `UpdateCheck`'s interpolates only a regex-vetted version and a constant —
  anything a user or server could influence needs `argv` too.

Exit 0 from trill means the daemon took the send, not that the user saw it
(rules, digests and quiet hours route to the inbox). That is the user's dial;
never add a second banner.

## Conventions

- MIT licensed, public. No secrets, no personal identity in commands.
- The command library is generic; machine-specific commands belong in the
  consumer.
