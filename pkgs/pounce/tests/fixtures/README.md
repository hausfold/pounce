# Header-grammar fixtures

`header-grammar/` is a command directory whose scripts each exercise ONE
whitespace shape of the `# pounce: key = value` comment header.
`header-grammar.tsv` is what parsing that directory must produce — one
`CommandRegistry.Entry.registryLine` per LISTED command, in id order:

    name <TAB> description <TAB> icon <TAB> id <TAB> submenu <TAB> mutates <TAB> confirm <TAB> network

(every flag `1|0`). The three trailing flags are the declarations a command
makes about itself (`CommandRisk`); they were APPENDED to the five-field line
that predates them, which is why every row of this table gained three columns in
one commit and why `PounceItem.parseCommand` reads each of them only if it is
there.

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
- **Trimming is space and tab ONLY** — `nbsp-tail` keeps its U+00A0, and its
  expected name keeps it too. Swift's `.trimmingCharacters(in: .whitespaces)`
  would have removed it and awk's `[ \t]` cannot follow, which is the
  `submenu-spaced` split again in a character nobody can see — and ⌥Space types
  one on macOS. The grammar stays narrow so the two stay converged.
- **A repeated key: FIRST wins** — `submenu-repeated` declares `false` then
  `true` and must render `0`. The awk has always been first-wins (`&& s == ""`);
  Swift's `submenu` was the one field with no such guard, so it was last-wins
  there until pounce#95. Under last-wins this fixture renders `1`.
- **The three declarations parse, first-wins, `1` counts** — `declares` says
  `mutates = true`, `confirm = false` then `confirm = true`, `network = 1`, and
  must render `1 0 1`. `confirm` carries the first-wins case here rather than
  `submenu` carrying it alone because this is the field where the two parsers
  disagreeing is a confirmation sheet one path shows and the other doesn't.
- **…and anything that isn't `true` or `1` is FALSE** — `declares-loose` says
  `yes` / `TRUE` / `on` and must render `0 0 0`. A widened grammar is how the
  three copies drift apart, so the narrow one is pinned deliberately: a header
  that misspells its own value gets no sheet, and `pounce list` is where an
  author sees what actually parsed. These two are the only cases haus has no
  counterpart for — its Nix parser knows nothing of these keys, and ignoring
  them is correct there.
- **`whenFile` vetoes, and `~` expands the same way in both** — `listed` and
  `vetoed` name `~/state/yes` and `~/state/no`; the harnesses write those under a
  controlled `HOME`, and `vetoed` is absent from the table rather than present
  with a marker, because that is what a vetoed row is.

## Adding a case

Add a script, add its expected line in id order, and run `tests/run.sh`. If only
one parser changes, the table is what says so. When you change the grammar
deliberately, change the table in the same commit — a fixture whose expected line
you had to discover by running the code is a test that ratifies a bug.

**If your case turns on whitespace, check whether stripping it would change the
expected value.** If it would not, the fixture can be defused silently by any
reformat and belongs in `palette_header_test.sh`'s `intact` list — that is what
protects `trailing-space`, `submenu-spaced`, `tab-hash`, `indented` and
`wide-hash`, and why `nbsp-tail` deliberately is not there.

haus keeps its own table for the Nix parser — `expectedHeaderGrammarTable` in its
`flake.nix`, checked by `pounce-header-grammar` — pinned to these same case
names. It is a different shape (haus asks for one field; this asks for a whole
registry line), and it is deliberately not a copy of this file: once the lock
moves past pounce#95 that check can read these files directly instead, the way
`pounce-item-grammar` already reads `ItemSettings.swift`.

⚠️ **haus is a PRODUCER of these headers, so its tolerance is not symmetric with
ours.** Anything haus's reader accepts that the pounce it is locked against does
not is a header haus writes and the daemon drops — losing the row's name, its
description and its `whenFile`. haus keeps its own shipped headers canonical for
that reason, enforced separately by its `pounce-command-headers` check.
