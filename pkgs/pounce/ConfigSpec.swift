// The settings table `pounce config init` writes out: one entry per key
// `Settings.load()` reads, with the prose a user needs and the default it
// actually has.
//
// THE DEFAULTS ARE NOT WRITTEN DOWN HERE. Each entry reads its value off a live
// `Settings()` — `json(s.clipboard.maxEntries)`, not `json(200)` — so the
// generated file cannot document a default that the struct doesn't have. That's
// the one kind of drift a config template makes worse than no template: a
// confident, wrong number in a file that looks authoritative.
//
// What DOES have to be kept in step by hand is coverage: a setting added to
// `Settings` and to `load()` but not added here is simply absent from the
// generated file. It still works; it's just undiscoverable, which is the exact
// problem this feature exists to fix. When you add a setting, add it here — the
// section order below mirrors `Settings.load()` on purpose so the two read as
// one list.
//
// The prose is the USER-FACING half. The comments on the structs in Config.swift
// are the maintainer-facing half — why the default is what it is, what breaks if
// you change it. Neither should try to be the other.
//
// Rendering, wrapping and the JSON-with-comments shape live in
// ConfigTemplate.swift, which is Foundation-only so it can be tested.

import Foundation

enum ConfigSpec {
    /// Render any Swift value as a JSON literal. Arrays come back
    /// pretty-printed, which is what keeps a thirteen-entry bundle-id list from
    /// becoming one 500-character line in a file people are meant to read.
    static func json(_ value: Any) -> String {
        // `Set` isn't a JSON type, and its iteration order isn't stable — a
        // template that reordered itself between runs would make `haus`-style
        // "is it current?" comparisons meaningless.
        let normalized: Any
        if let set = value as? Set<String> {
            normalized = set.sorted()
        } else if let d = value as? CGFloat {
            normalized = Double(d)
        } else {
            normalized = value
        }

        var options: JSONSerialization.WritingOptions = [
            .fragmentsAllowed, .withoutEscapingSlashes,
        ]
        if let array = normalized as? [Any], array.count > 3 { options.insert(.prettyPrinted) }

        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: options),
              let text = String(data: data, encoding: .utf8)
        else { return "null" }
        return text
    }

    /// Every section of config.json, in the order `Settings.load()` reads them.
    static func sections(defaults s: Settings = Settings()) -> [ConfigSection] {
        [
            ConfigSection(
                name: nil,
                doc: "The palette itself — its proportions, its size, and its colours.",
                fields: [
                    ConfigField(
                        name: "windowMode",
                        doc: "How tightly the launcher reads: \"default\", or \"compact\" for a narrower window with shorter rows. Independent of \"scale\" below — a compact palette can still be drawn large.",
                        json: json(s.windowMode.rawValue)),
                    ConfigField(
                        name: "scale",
                        doc: "Multiplies every size in the UI — text, rows, icons, and the emoji / clipboard / screenshot panels behind the palette. 1.0 is the tuned look; 0.8 to 2.0 is the range, and anything outside it is clamped rather than rejected.",
                        json: json(s.scale)),
                    ConfigField(
                        name: "theme",
                        doc: "Colour palette: a built-in name, or a ~/.config/pounce/themes/<name>.json. Unset (null) means the nebelung / nebelung-latte pair, so pounce follows macOS light and dark by itself. Setting this PINS one palette for both appearances.",
                        json: json(s.theme as Any)),
                    ConfigField(
                        name: "themeLight",
                        doc: "The palette to use when macOS is in Light appearance, overriding \"theme\". Set this alongside \"theme\" to get a following pair again: \"theme\": \"gruvbox-dark\" + \"themeLight\": \"gruvbox\".",
                        json: json(s.themeLight as Any)),
                    ConfigField(
                        name: "themeDark",
                        doc: "The palette to use when macOS is in Dark appearance, overriding \"theme\".",
                        json: json(s.themeDark as Any)),
                ]),

            ConfigSection(
                name: "clipboard",
                doc: "Clipboard history — the ⌘⇧V panel.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Record copies at all. Off means the clipboard panel stays empty and nothing is written to disk.",
                        json: json(s.clipboard.enabled)),
                    ConfigField(
                        name: "maxEntries",
                        doc: "How many copies to remember. The oldest fall off the end.",
                        json: json(s.clipboard.maxEntries)),
                    ConfigField(
                        name: "blacklistBundleIds",
                        doc: "Copies made while one of these apps is frontmost are never recorded. Belt and braces on top of the concealed-type filter that already drops password-manager copies.",
                        json: json(s.clipboard.blacklistBundleIds)),
                    ConfigField(
                        name: "autoPaste",
                        doc: "Paste a chosen entry straight into the app you came from (a synthesized ⌘V) instead of only setting the clipboard. Needs the daemon's Accessibility grant; without it, pounce falls back to clipboard-only rather than failing. Off by default so a fresh install never quietly needs a permission.",
                        json: json(s.clipboard.autoPaste)),
                ]),

            ConfigSection(
                name: "quickAnswers",
                doc: "The inline answer engines — maths, unit and time conversion, currency.",
                fields: [
                    ConfigField(
                        name: "currency",
                        doc: "Convert currencies, which needs daily reference rates over the network — pounce's only outbound call. Set false (with \"updates\".\"check\" too) for a fully offline pounce. The other engines are pure arithmetic and are always on.",
                        json: json(s.quickAnswers.currency)),
                ]),

            ConfigSection(
                name: "updates",
                doc: "The daily release check.",
                fields: [
                    ConfigField(
                        name: "check",
                        doc: "Look once a day for a newer pounce and nudge — a palette row and one notification. It never installs anything. Already off by itself on Nix-managed installs, whose updates ride the flake.",
                        json: json(s.updates.check)),
                ]),

            ConfigSection(
                name: "fileSearch",
                doc: "Find Files — the local Spotlight-index search.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Offer file search at all. Read-only and local (the Spotlight index, no network), so it's on by default.",
                        json: json(s.fileSearch.enabled)),
                    ConfigField(
                        name: "homeOnly",
                        doc: "Search only your home directory. False searches everything indexed on the machine.",
                        json: json(s.fileSearch.homeOnly)),
                    ConfigField(
                        name: "maxResults",
                        doc: "How many hits the list shows.",
                        json: json(s.fileSearch.maxResults)),
                ]),

            ConfigSection(
                name: "shortcuts",
                doc: "Your Shortcuts library, as ordinary launcher rows.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "List the shortcuts from Shortcuts.app alongside apps and commands; ⏎ runs one. This is also how you reach an app's Shortcuts/Spotlight action from pounce — wrap it in a one-action shortcut and it shows up here, since macOS gives no way to fire another app's App Intent directly. Shortcuts start ranked below everything at an empty query and climb by use.",
                        json: json(s.shortcuts.enabled)),
                ]),

            ConfigSection(
                name: "apps",
                doc: "The app launcher's opinions about which apps matter.",
                fields: [
                    ConfigField(
                        name: "demoteBundleIds",
                        doc: "Apps that sink below everything else on an empty query and have to climb back by actual use. Defaults to Apple utilities nobody launches on purpose — the fix for Feedback Assistant squatting the top slot. Set [] to disable, or list your own; unknown ids are harmless.",
                        json: json(s.appLauncher.demoteBundleIds)),
                    ConfigField(
                        name: "hideBundleIds",
                        doc: "Apps dropped from the launcher entirely, on top of the built-in filter that already hides background agents and droplet bridges.",
                        json: json(s.appLauncher.hideBundleIds)),
                ]),

            ConfigSection(
                name: "hotkey",
                doc: "The global key that summons the palette. Read ONCE when the daemon starts — changing it needs a daemon restart, unlike everything above.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Let pounce bind the key itself. False leaves it to an external binder (skhd, AeroSpace, a launch agent spawning pounce-palette).",
                        json: json(s.hotkey.enabled)),
                    ConfigField(
                        name: "key",
                        doc: "A named key: \"space\", \"return\", \"tab\", \"escape\", a letter, a digit, or \"f13\"-\"f20\" (the F-keys no laptop has, where a hardware macro key or a HID remap lands).",
                        json: json(s.hotkey.key)),
                    ConfigField(
                        name: "modifiers",
                        doc: "Any of \"cmd\", \"shift\", \"opt\", \"ctrl\".",
                        json: json(s.hotkey.modifiers)),
                ]),

            ConfigSection(
                name: "windows",
                doc: "The most-recently-used window switcher: hold the modifiers, tap the key to walk windows, release to land. Off by default — taking over ⌘Tab is a bold move, and the event tap needs the Accessibility grant. Read once at daemon start, like \"hotkey\".",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Turn the switcher on.",
                        json: json(s.windows.enabled)),
                    ConfigField(
                        name: "key",
                        doc: "The key you tap to advance.",
                        json: json(s.windows.key)),
                    ConfigField(
                        name: "modifiers",
                        doc: "The modifiers you hold. Releasing them lands on the highlighted window.",
                        json: json(s.windows.modifiers)),
                ]),

            ConfigSection(
                name: "appHotkeys",
                doc: "Chords consumed ONLY while a named app is frontmost, passed through untouched everywhere else — what a plain global hotkey can't do (it swallows the chord machine-wide or not at all). Each scope is {\"bundleId\": …, \"keys\": [{\"key\": …, \"modifiers\": […], \"target\": \"cmd:…\"}]}; targets use the same grammar as \"items\" keys. Needs the Accessibility grant, and is read once at daemon start.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Turn scoped chords on.",
                        json: json(s.appHotkeys.enabled)),
                    ConfigField(
                        name: "scopes",
                        doc: "The apps and their chords. Empty means nothing is consumed anywhere.",
                        json: json(s.appHotkeys.scopes.map { scope in
                            ["bundleId": scope.bundleId,
                             "keys": scope.keys.map {
                                 ["key": $0.key, "modifiers": $0.modifiers, "target": $0.target]
                             }] as [String: Any]
                        })),
                ]),

            ConfigSection(
                name: "pages",
                doc: "A most-recently-used walk over the AeroSpace workspaces named \"prefix\" or \"prefix/…\": hold the modifiers, tap the key to step focus through the non-empty ones newest-first (add shift to walk backwards), release to stay. No panel — every step focuses the workspace live. Recency comes from \"mruFile\", a newest-first list your window manager's workspace-change hook maintains; pounce only reads it. Needs the Accessibility grant, and is read once at daemon start.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Turn the page walk on.",
                        json: json(s.pages.enabled)),
                    ConfigField(
                        name: "key",
                        doc: "The key you tap to advance.",
                        json: json(s.pages.key)),
                    ConfigField(
                        name: "modifiers",
                        doc: "The modifiers you hold. Releasing them ends the walk where it stands.",
                        json: json(s.pages.modifiers)),
                    ConfigField(
                        name: "prefix",
                        doc: "Only workspaces named exactly this, or this + \"/…\", are walked.",
                        json: json(s.pages.prefix)),
                    ConfigField(
                        name: "bundleId",
                        doc: "Scope the chord to one app, like an appHotkeys scope — over any other app it passes through untouched (a browser keeps its ⌃⇥ tabs). null means the chord is consumed everywhere.",
                        json: json(s.pages.bundleId as Any)),
                    ConfigField(
                        name: "mruFile",
                        doc: "Path to the newest-first workspace list your WM hook writes. null means no recency — the walk still works, ordered by name.",
                        json: json(s.pages.mruFile as Any)),
                ]),

            ConfigSection(
                name: "mouseChords",
                doc: "A modifier plus a click, acting on the window UNDER THE POINTER — what a window-manager keybind can't do, since a keybind can only reach the window you are already in. Each chord is {\"button\": \"left\"|\"right\", \"modifiers\": […], \"action\": \"fullscreen\"}. Every chord must carry a modifier (a bare one would swallow every click on the machine), and the click is consumed over every app, so pick a chord nothing else claims — ⌥ + right-click is the quietest (it costs only macOS's ⌥ variant of a context menu); ctrl + click is macOS's own secondary-click and would cost you context menus everywhere. Needs AeroSpace and the Accessibility grant, and is read once at daemon start.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Turn mouse chords on.",
                        json: json(s.mouseChords.enabled)),
                    ConfigField(
                        name: "chords",
                        doc: "The chords. Empty means no click is consumed anywhere.",
                        json: json(s.mouseChords.chords.map { chord in
                            ["button": chord.button.rawValue,
                             "modifiers": chord.modifiers,
                             "action": chord.action.rawValue] as [String: Any]
                        })),
                ]),

            ConfigSection(
                name: "autoQuit",
                doc: "Quit an app when you close its last window — what Windows does and macOS doesn't. Off by default. Reads the same window snapshot as \"windows\", so it wants the same Accessibility grant, and is read once at daemon start. The quit is the polite one ⌘Q sends: an app with unsaved work puts its sheet up and stays.",
                fields: [
                    ConfigField(
                        name: "enabled",
                        doc: "Turn auto-quit on.",
                        json: json(s.autoQuit.enabled)),
                    ConfigField(
                        name: "delay",
                        doc: "Seconds to wait, then look again before quitting. This is what lets an app close one window and open another — a browser replacing its last window, an editor switching projects — without being quit out from under you.",
                        json: json(s.autoQuit.delay)),
                    ConfigField(
                        name: "exclude",
                        doc: "Bundle ids that are never auto-quit. Setting this REPLACES the default rather than adding to it — keep Finder in your list unless you want the desktop to blink out and relaunch.",
                        json: json(s.autoQuit.exclude)),
                ]),

            ConfigSection(
                name: nil,
                doc: "How a \"hotkey\": \"fn\" item binding (below) gets the Fn/Globe key.",
                fields: [
                    ConfigField(
                        name: "fnKey",
                        doc: "\"tap\" reads Fn with an event tap: it needs Accessibility, and it SHARES the key with macOS — HIToolbox carries its own Globe handler inside every process, below the event stream, so macOS's Emoji & Symbols picker can still open alongside pounce's (turning off System Settings > Keyboard > \"Press 🌐 key to\" helps, but that value is read from login-session state, so it wants a logout). \"remap\" instead takes Fn away at the HID layer — it becomes F19, which pounce binds like any ordinary key: no Accessibility, and nothing left for macOS to race. The cost is that Fn stops being Fn everywhere: no Fn+arrows, Fn+Delete, or Fn+F1-F12. Applied while the daemon runs, removed when it exits, and never persistent — a reboot clears it.",
                        json: json(s.fnKey.rawValue)),
                ]),

            // `items` is the one setting with no fixed key list — it's keyed by
            // pounce's own stable item keys, of which there are dozens, and which
            // you discover with `pounce --help`. Enumerating them here would be a
            // second, staler copy of that list; an example that shows all four
            // per-item fields is the honest documentation.
            ConfigSection(
                name: "items",
                doc: "Per-item overrides, keyed by item key (\"cmd:emoji\", \"mode:clipboard\", \"app:/Applications/Safari.app\", \"shortcut:<uuid>\"). Empty by default — an untouched config behaves as if this section didn't exist. `pounce --help` lists the keys. A bare \"fn\"/\"globe\" hotkey is supported too — see \"fnKey\" above for the two ways it can be carried.",
                // Three fields, and only three — see ItemSettings.parse.
                raw: """
                // "cmd:emoji": {
                //   "enabled": true,   // false removes the item from the palette
                //   "alias": "emo",    // an extra name it answers to in search
                //   "hotkey": "opt+e", // a global key straight to this item
                // },
                // "app:/Applications/Ghostty.app": { "hotkey": "opt+t" },
                // "mode:emoji": { "hotkey": "fn" },
                """),
        ]
    }

    /// The whole file. Fails rather than returns if what it produced isn't valid
    /// JSON once comments are stripped — writing a config pounce can't read would
    /// turn "here are your settings" into "your settings are gone", silently,
    /// since `load()` falls back to defaults on a parse failure.
    static func render(version: String) throws -> String {
        let text = ConfigTemplate.render(sections(), version: version)
        // Through the SAME parser `Settings.load()` uses, flag and all — a check
        // against a stricter or looser one would be checking the wrong thing.
        guard (try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.json5Allowed])) != nil
        else { throw ConfigTemplateError.invalidJSON }
        return text
    }
}

enum ConfigTemplateError: Error { case invalidJSON }
