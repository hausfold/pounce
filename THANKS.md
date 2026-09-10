# Thanks

## Founding testers

The people who ran pounce before it was public, on their own machines, with no
help from me while they did it. Each one chose how they appear here, and the
order is the order they reported in. It stays that way.

*The early alpha hasn't started yet. This is where the list goes.*

What a founding tester gets, and the limits on it, are written down once:
[FOUNDING.md](https://github.com/hausfold/workshop/blob/main/FOUNDING.md).

## Standing on

pounce has no third-party dependencies. Not as a boast: it is a launcher that
reads your keystrokes and runs commands as you, so every library in it would be
one more thing to trust, and there was no good reason to add any. What it is
built on instead:

| | |
|---|---|
| Apple's own frameworks | AppKit, SwiftUI, Carbon's hotkey API, ApplicationServices, ServiceManagement. The whole app is these |
| [Homebrew](https://brew.sh) | The door most people come in through: `brew install hausfold/tap/pounce` |
| [Swift](https://swift.org) | The language and its toolchain |

The palette's colours come from [nebelung](https://github.com/hausfold/nebelung),
which is a [Catppuccin](https://catppuccin.com) flavor. Catppuccin did the hard
part of deciding what a readable dark theme is; we changed the greys.
