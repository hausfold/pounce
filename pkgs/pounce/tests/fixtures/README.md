# Header-grammar fixtures

`header-grammar/` is a command directory whose scripts each exercise ONE
whitespace shape of the `# pounce: key = value` comment header.
`header-grammar.tsv` is what parsing that directory must produce — one
`CommandRegistry.Entry.registryLine` per LISTED command, in id order:

    name <TAB> description <TAB> icon <TAB> id <TAB> submenu(1|0)

## Why a table instead of assertions

This grammar has **three** parsers, and no two of them are the same language:

| parser | where | reads |
|---|---|---|
| awk | `pkgs/pounce-commands/pounce-palette` | the shell launcher's registry |
| Swift | `pkgs/pounce/CommandRegistry.swift` | the daemon's registry — what ⌘Space uses |
| Nix | haus's `modules/launcher/header-grammar.nix` | `cheat` / `cheatWhen`, which pounce ignores |

They cannot be collapsed into one. haus parses headers at **Nix eval time**, where
running a pounce binary would be import-from-derivation on every rebuild — which
is precisely why its copy is a regex and not a call. So the grammar is mirrored
three times on purpose, and the only thing that can keep three copies honest is a
table all three are pinned to.

It has already drifted twice, both times silently and both times found by hand:
haus#451 (only the Nix copy rejected `key  = value`) and haus#459 / pounce#95
(only the Swift copy accepted an indented header line; none accepted a stray
second space after `#`). A parse miss has no failure mode a person can see — the
row simply carries the filename instead of its name, or the cheatsheet caption
loses a clause — so nothing reports it and nobody looks.

## The decisions this table pins

Each is a fixture whose name says which shape it is:

- **Forgiving around `=`, `pounce:`, and the leading `#`** — `wide-equals`,
  `tight-equals`, `indented`, `wide-hash`, `tab-hash`, `tight-colon` all parse.
  A header is hand-typed, so irregular spacing must not be a silent no-op.
- **Whitespace after `#` is REQUIRED** — `tight-hash` (`#pounce:`) does *not*
  parse, and falls back to its filename. No parser has ever accepted it; allowing
  it would widen the grammar rather than converge it, and `#pounce` is a shape a
  shell comment can plausibly mean something else by. Changing that means
  changing this line, which is the point of writing it down.
- **A key is whole, not a prefix** — `key-collision` declares `names`, which must
  not satisfy `name`.
- **Values are trimmed at BOTH ends** — `trailing-space`, and `submenu-spaced`,
  which is the sharper case: `submenu = true ` with one trailing space parsed as
  `true` in the daemon and as **false** in the shell launcher until pounce#95, so
  the same command was a submenu on one path and a leaf on the other.
- **`whenFile` vetoes, and `~` expands the same way in both** — `listed` and
  `vetoed` name `~/state/yes` and `~/state/no`; the harnesses write those under a
  controlled `HOME`, and `vetoed` is absent from the table rather than present
  with a marker, because that is what a vetoed row is.

## Adding a case

Add a script, add its expected line in id order, and run `tests/run.sh`. If only
one parser changes, the table is what says so. When you change the grammar
deliberately, change the table in the same commit — a fixture whose expected line
you had to discover by running the code is a test that ratifies a bug.

haus keeps its own copy of this table for the Nix parser
(`modules/launcher/header-grammar-table.txt`), pinned to the same fixture names.
Once the lock moves past pounce#95 it can read these files directly instead, the
way `pounce-item-grammar` already reads `ItemSettings.swift`.
