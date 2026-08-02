# CLAUDE.md

**Pounce** — a native, scriptable command palette for macOS. A small Swift daemon
(`pkgs/pounce`, Swift sources split one-file-per-concern) plus a shell-scripted command library
(`pkgs/pounce-commands`). Part of the [nebelhaus](https://github.com/nebelhaus) family.

## Am I in the right repo? (routing)

**This repo (`~/code/workshop/pounce`) owns THE PALETTE APP** — the Swift binary and
its command scripts. Nothing else.

| Want to change… | Repo |
|---|---|
| the pounce app (UI, ranking, launcher) or a command script | `~/code/workshop/pounce` ← **you are here** |
| how pounce is *launched* on the system (launchd, signing, ⌘Space) | `~/code/workshop/nebelhaus` → `modules/pounce` |
| pounce's colors | `~/code/workshop/nebelung` |
| this machine's pounce settings (`config.json`) | the rice's `modules/pounce`, or the consumer host |

> **Claude: enforce this.** If a request is about launching/signing pounce, theming
> it, or per-machine settings, STOP and point at the right repo before editing here.

> **Hotkey exception.** The daemon *can* register a global hotkey in-process
> (`HotKey.swift`, config `hotkey`) so ⌘Space→palette skips the shell/client
> spawn — that latency-critical capability lives here. But the *system binding*
> (the launch agent, its exported `POUNCE_*` command dirs, whether ⌘Space is left
> to the daemon vs. an external binder) is still a nebelhaus concern.

## Build

```bash
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

The build shells out to `/usr/bin/xcrun swiftc` (system Swift — avoids compiling the
whole toolchain), so it needs **Xcode Command Line Tools** and the macOS build sandbox
relaxed (Determinate's default). Not a pure build; that's deliberate. CI builds it on
a macOS runner on every push.

To test inside the full rice without pushing: `bench try` from the workshop
(`~/code/workshop`) rebuilds the user's machine against this local checkout; the
`rebuild-pounce` alias on the host does the same. A plain rebuild uses the pinned
GitHub rev — after pushing here, ripple with `bench ship` (or `nix flake update
nebelhaus` in the consumer).

When you open the PR for a `worktree-*` branch, give it a **What / Why / Verify / Watch-out**
body (see the workshop ship skill's Step 3) — the session that wrote the code is gone by the
time the change is feel-tested, so a bug found later has to be recoverable from `gh pr view`
alone, and the **Verify** block is exactly what the workshop's `bench try-batch` checklist
points back to when it feels several PRs together.

## Layout

```
pkgs/pounce/            Swift sources (daemon/UI, one file per concern), Info.plist, emoji.json, ports
pkgs/pounce-commands/   default.nix (runtime command discovery) + commands/*.sh (official plugins)
```

## Patterns

- **New command (plugin)**: a command is ONE self-describing script — its metadata
  lives in a `# pounce: key = value` comment header (`name` / `description` / SF
  Symbol `icon`; `submenu = true` for a two-step command that re-invokes `pounce`).
  Official ones go in `pkgs/pounce-commands/commands/<id>.sh`; there is no registry
  to edit. At runtime the palette also discovers user commands from
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
  other. `config.json` is parsed through `JSONC.swift` (comments + trailing commas),
  which is what lets the file people READ be the file pounce reads.
- **Per-item settings**: `config.json`'s `items` map (`ItemSettings.swift`) carries
  enable / alias / hotkey for anything the palette can address, keyed by the item's
  **frecency key** — `cmd:<id>`, `app:<path>`, plus `mode:<name>` for the built-in
  windows. One map, not three parallel keys, because one entry is one row of a
  settings list. `ItemTarget` is the single parser for that grammar (it also backs
  `pounce run <item-key>`, the escape hatch for external binders). Foundation-only so
  `tests/run.sh` compiles it. Enable/alias apply in `DaemonState.load`; hotkeys are
  registered once at daemon start (`DaemonMode.run`) and reported to `pounce doctor`
  via `DaemonMode.bindingReport` — a binding that loses its combo, or names a command
  that doesn't exist, is invisible otherwise.
- **Leader sequences** (`"opt+space e"`, `Leader.swift`): whitespace separates steps,
  `+` separates modifiers. Sequences sharing a leader share a `HotKeyNode`, so the
  leader is registered once and owns a map of next steps. **Do not reach for a
  CGEventTap here** — the second-step keys are grabbed as ordinary modifier-less
  Carbon hotkeys only while the leader is armed (~2s), which is what keeps the whole
  feature free of an Accessibility grant, unlike the ⌘Tab switcher. The transient
  registrations live in their own `HotKeyManager` under a separate Carbon signature
  so disarming can never unregister the palette key.
- **Accessibility (TCC)**: a store build is adhoc-signed, so its grant is lost on
  rebuild. The *rice* (`nebelhaus/modules/pounce`) re-signs a stable copy to keep the
  grant — that logic lives there, not here. Here, just: `pounce --request-accessibility`
  / `--check-accessibility`.
- **Theming**: colors live in `Palette` (`Theme.swift`). The default **nebelung**
  palette is *generated at build time* from the `nebelung` flake input's `palette`
  output into `Palette+nebelung.generated.swift` (see `pkgs/pounce/default.nix`) —
  don't hand-edit hex for it; change it in the nebelung repo and
  `nix flake update nebelung`. Other palettes (e.g. `mocha`) are inlined literals.
  Pick one at runtime with `"theme"` in `config.json`.

## Conventions

- MIT licensed, public. No secrets, no personal identity in commands.
- The command library is meant to be generic; machine-specific commands belong in the
  consumer, not here.
