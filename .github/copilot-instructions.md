# Copilot instructions

**Read [`AGENTS.md`](../AGENTS.md) at the repo root first — it is the full,
authoritative instruction set for every agent working here, and this file is
only a pointer to it.** (Copilot doesn't follow file imports, hence the
duplication below; if the two ever disagree, `AGENTS.md` wins.)

The short version:

- Pounce is a native, scriptable **command palette for macOS**: a Swift daemon
  (`pkgs/pounce`) plus a shell-scripted command library
  (`pkgs/pounce-commands`), in the [hausfold](https://github.com/hausfold)
  family.
- **This repo owns the app and its commands, nothing else.** How pounce is
  *launched* (launchd, signing, ⌘Space, the Accessibility grant) belongs to the
  haus's `modules/launcher`; its colors belong to `nebelung`; per-machine settings
  belong to the consumer. The one exception is the in-process hotkey
  (`HotKey.swift`), which is latency-critical and does live here.
- **A command is one self-describing script.** Metadata rides in a
  `# pounce: key = value` header; there is no registry to edit.
- **A new setting is three places, and the third gets forgotten**: the field on
  the struct in `Config.swift`, the `if let` in `Settings.load()`, and an entry
  in `ConfigSpec.sections`. Never write a default *value* into the spec — spec
  entries read it off a live `Settings()` so the docs can't drift.
- **Quick-answer engines are Foundation-only, synchronous and sub-millisecond**,
  return nil for queries they don't own, and never block a keystroke on I/O
  (background-refreshed cache instead). A new outbound network call needs the
  same gate-plus-cache treatment as `Currency.swift` and `UpdateCheck.swift`.
- **Don't reach for a CGEventTap for leader sequences** — the transient Carbon
  registrations are what keep the feature free of an Accessibility grant.
- The default palette is **generated at build time** from the `nebelung` flake
  input. Don't hand-edit its hex.

For review comments, the same bar applies as anywhere in the family:
correctness and boundaries (does this change belong in *this* repo?) over style.
