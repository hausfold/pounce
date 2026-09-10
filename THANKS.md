# Thanks

## Founding testers

The people who run pounce before it is public, on their own machines, with no
help from me while they do it. Each one chooses how they appear here, and the
order is the order they report in. It stays that way.

*The early alpha hasn't started yet.*

What a founding tester gets, and the limits on it, are written down once:
[FOUNDING.md](https://github.com/hausfold/workshop/blob/main/FOUNDING.md).

## Standing on

pounce links no third-party libraries. It reads your keystrokes and runs
commands as you, so every library in it would be one more thing to trust, and
there was no good reason to add any. There is no `Package.swift`, no
submodule, nothing fetched at build time: `build.sh` hands `swiftc` a pile of
`.swift` files and a list of Apple frameworks.

That leaves three things that came from somebody else, and they are the ones
worth naming.

| | |
|---|---|
| [gemoji](https://github.com/github/gemoji) | The glyphs, names and search keywords behind the emoji picker, vendored as `emoji.json` and shipped inside the app. GitHub's, and MIT, so the notice travels with it: [NOTICE](./NOTICE) at the repo root and a copy inside every bundle at `Contents/Resources/NOTICE` |
| [Frankfurter](https://frankfurter.app) | The ECB reference rates behind currency conversions. Free, keyless, no account, and pounce's only outbound network call |
| [nebelung](https://github.com/hausfold/nebelung) and [Catppuccin](https://catppuccin.com) | The colours. nebelung is a Catppuccin flavor, and pounce bakes in its dark palette and its latte counterpart, which is what lets a zero-config install follow macOS light and dark. Catppuccin did the hard part of deciding what a readable theme is in either; I changed the greys |

Everything else is Apple's: AppKit and SwiftUI over Foundation, Carbon's
hotkey API for ⌘Space, ApplicationServices, ServiceManagement for the login
item, and AVFoundation and CoreBluetooth for the camera and bluetooth
commands.

[Homebrew](https://brew.sh) is how to install it outside Nix:
`brew install hausfold/tap/pounce`.

None of these projects asked to be part of this. If you find pounce useful,
some of that belongs upstream.
