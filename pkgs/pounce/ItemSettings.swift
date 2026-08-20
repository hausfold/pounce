import Foundation

// MARK: - Per-item settings (config.json's `items` map)
//
// The things you'd otherwise want a config key each for — hide it, give it a
// shorthand, give it a key, list it only on certain pages or over certain apps —
// expressed as ONE map keyed by an item key. That
// keying is the point: a single entry is exactly one row of a settings list, so
// a UI that edits these mutates one key rather than reconciling three parallel
// arrays.
//
// Foundation-only by design (no AppKit/SwiftUI), like the quick-answer engines,
// so tests/run.sh can compile it — see tests/itemsettings_tests.swift. Settings
// (Config.swift) owns the disk read and hands the raw `items` value here.

// A key + modifier combination, as written anywhere in config.json. Two
// spellings are accepted so neither surface is awkward:
//
//   "opt+e"                            the string form, used in `items`
//   {"key": "e", "modifiers": ["opt"]} the object form, used by the `hotkey`
//                                      and `windows` blocks (which shipped
//                                      before the string form existed)
//
// Both parse to the same thing, so a settings UI can emit whichever it likes and
// a hand-written config can mix them.
struct HotKeySpec: Equatable {
    var key: String
    var modifiers: [String]

    // "cmd+shift+v" → key "v", modifiers ["cmd","shift"]. The LAST segment is
    // the key; everything before it is a modifier. Returns nil when there's no
    // key left to bind ("", "cmd+"), which can never be a usable binding —
    // hence omittingEmptySubsequences: false, so a trailing "+" leaves an empty
    // last segment to reject rather than silently promoting "cmd" to the key.
    static func parse(_ string: String) -> HotKeySpec? {
        let parts = string.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let key = parts.last, !key.isEmpty else { return nil }
        return HotKeySpec(key: key, modifiers: parts.dropLast().filter { !$0.isEmpty })
    }

    static func parse(_ any: Any?) -> HotKeySpec? {
        if let s = any as? String { return parse(s) }
        if let obj = any as? [String: Any] {
            guard let k = obj["key"] as? String, !k.isEmpty else { return nil }
            return HotKeySpec(key: k.lowercased(),
                              modifiers: ((obj["modifiers"] as? [String]) ?? []).map { $0.lowercased() })
        }
        return nil
    }

    // Log/diagnostic form, matching how the shipped blocks are already logged.
    var display: String {
        modifiers.isEmpty ? key : modifiers.joined(separator: "+") + "+" + key
    }
}

// One or more steps pressed in ORDER. A single step is an ordinary chord
// (⌥E); several are a leader sequence (⌥Space then E), written space-separated
// the way Emacs and VS Code write them:
//
//   "opt+e"          one step  — fires immediately
//   "opt+space e"    two steps — ⌥Space arms, E fires
//   ["opt+space","e"] the array form, for a settings UI recording step by step
//
// Steps are separated by whitespace and modifiers by "+", so spacing around a
// "+" is normalized away first ("cmd + shift + v" is ONE step, not three).
struct HotKeySequence: Equatable {
    var steps: [HotKeySpec]        // never empty — parse returns nil instead

    var isLeader: Bool { steps.count > 1 }
    var display: String { steps.map(\.display).joined(separator: " ") }

    static func parse(_ any: Any?) -> HotKeySequence? {
        // Array form: each element is one step.
        if let array = any as? [Any] {
            let steps = array.compactMap { HotKeySpec.parse($0) }
            guard steps.count == array.count, !steps.isEmpty else { return nil }
            return HotKeySequence(steps: steps)
        }
        if let string = any as? String {
            let tokens = normalizingModifierSpacing(string)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            let steps = tokens.compactMap { HotKeySpec.parse(String($0)) }
            guard steps.count == tokens.count, !steps.isEmpty else { return nil }
            return HotKeySequence(steps: steps)
        }
        // Object form ({key, modifiers}) is a single step by construction.
        return HotKeySpec.parse(any).map { HotKeySequence(steps: [$0]) }
    }

    // Drop whitespace that merely surrounds a "+", so the only whitespace left
    // is a genuine step separator: "cmd + shift + v" → "cmd+shift+v", while
    // "opt+space e" keeps its one space.
    static func normalizingModifierSpacing(_ string: String) -> String {
        var out = ""
        var pending = ""      // whitespace seen since the last real character
        for ch in string {
            if ch == " " || ch == "\t" { pending.append(ch); continue }
            if ch == "+" {
                pending = ""                                  // drop space BEFORE a "+"
            } else if !out.isEmpty && out.last != "+" {
                out += pending                                // keep a real separator
            }                                                 // else: space AFTER "+", drop
            pending = ""
            out.append(ch)
        }
        return out
    }
}

// Where the palette was summoned from, as far as a row's visibility is
// concerned. Both fields are OPTIONAL because both can be genuinely unknown — a
// Mac with no tiler has no workspace, and a summon that raced our own
// activation has no other app in front — and an unknown value must not filter:
// losing a row you can no longer reach, on a machine that simply can't answer
// the question, is worse than showing one that won't help. So a predicate whose
// context is nil passes. Foundation-only (the caller reads the frontmost app —
// see State.swift's `ItemContext.current`), which is what keeps this file
// compilable by tests/run.sh.
struct ItemContext: Equatable {
    var workspace: String?     // the WM workspace in front, e.g. "T/pounce"
    var bundleId: String?      // the frontmost app, e.g. "com.mitchellh.ghostty"

    // Nothing known — every scoped row passes. Also what a non-scoped config
    // costs, since State only builds a real context when one is asked for.
    static let unknown = ItemContext()
}

// One item's overrides. `enabled`, `alias`, `workspaces` and `bundleIds` apply
// to things the palette LISTS (commands and apps); a "mode:" entry only
// meaningfully carries a hotkey, since no palette row corresponds to it.
//
// `workspaces`/`bundleIds` are the CONTEXT-scoped pair, and they scope the ROW
// alone — never the item's `hotkey`, which stays global exactly as `enabled:
// false` leaves it. A key is a promise you made once; a row is a suggestion the
// palette makes every time it opens, and only the second one is worth making
// conditional. (Scoping a chord is `appHotkeys` — see AppScoped.swift, which
// has to consume the event to do it.)
struct ItemSetting: Equatable {
    var enabled: Bool = true
    var alias: String?
    var hotkey: HotKeySequence?
    // Empty means "anywhere" for both, which is what an entry that never
    // mentions them keeps meaning.
    var workspaces: [String] = []
    var bundleIds: [String] = []

    var isScoped: Bool { !workspaces.isEmpty || !bundleIds.isEmpty }

    // Does this row belong in a palette summoned from `context`? The two
    // predicates AND (a row asking for both wants both), and each one passes
    // when its half of the context is unknown — see ItemContext.
    func matches(_ context: ItemContext) -> Bool {
        if !workspaces.isEmpty, let workspace = context.workspace,
           !workspaces.contains(where: { ItemSetting.workspaceMatches($0, workspace) }) {
            return false
        }
        if !bundleIds.isEmpty, let bundleId = context.bundleId,
           // Both sides lowercased HERE rather than trusting `parse` to have
           // done it: `entries` is an ordinary var, so a settings UI building an
           // ItemSetting directly would otherwise hide the row everywhere, with
           // every test (all of which go through `parse`) still green.
           !bundleIds.contains(where: { $0.lowercased() == bundleId.lowercased() }) {
            return false
        }
        return true
    }

    // One `workspaces` pattern against the workspace in front. The bare-name
    // shape is the one `pages.prefix` already taught this config file — "T" is
    // the page AND its children — because a tiling desktop names its pages that
    // way and asking for T almost never means "T alone". Not the identical
    // predicate, though, and the difference is deliberate: AppScoped's walk
    // matches case-SENSITIVELY and has no "/*" form, while this one adds both.
    //
    //   "T"      T, and every T/… child          (prefix, the pages.prefix rule)
    //   "T/*"    the children only, never T itself
    //   "T/main" that page exactly
    //
    // Case-insensitive: AeroSpace will focus `t` when you asked for `T`, so a
    // config that disagreed with the MRU file's spelling by one letter would
    // hide the row forever with nothing to see.
    static func workspaceMatches(_ pattern: String, _ workspace: String) -> Bool {
        let pattern = pattern.lowercased()
        let workspace = workspace.lowercased()
        if pattern.hasSuffix("/*") {
            let parent = String(pattern.dropLast())      // "t/*" -> "t/"
            return workspace.hasPrefix(parent) && workspace.count > parent.count
        }
        return workspace == pattern || workspace.hasPrefix(pattern + "/")
    }

    // A JSON value that may be one string or a list of them. Both spellings are
    // accepted for the same reason HotKeySpec takes two: a hand-written config
    // wants `"workspaces": "T"`, and a generated one emits a list.
    static func stringList(_ any: Any?) -> [String] {
        var raw: [String] = []
        if let one = any as? String { raw = [one] }
        // `[Any]` rather than `[String]`: JSONSerialization hands back an
        // NSArray, and one stray number in the list must cost that entry alone,
        // not the whole predicate — the same leniency `parse` gives a malformed
        // item, for the same reason.
        else if let many = any as? [Any] { raw = many.compactMap { $0 as? String } }
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// The workspace in front, read from the same MRU file the page walk uses
// (`pages.mruFile`, written by the WM's own workspace-change hook — haus:
// windows/scripts/workspace-mru.sh). Head line only: the hook keeps it
// most-recent-first, so line 1 IS where you are.
//
// Reading the file rather than asking `aerospace` is the whole point. This runs
// on the ⌘Space path, once per summon, and a subprocess there would put tens of
// milliseconds in front of the first keystroke — the same trade Windows.swift
// makes for the workspace map it caches. A file that doesn't exist, or a config
// that never set `pages.mruFile`, answers nil, and nil filters nothing.
enum WorkspaceMRU {
    static func current(file: String?) -> String? {
        // `~` expanded here and not at parse time: the config is a hand-written
        // file and "~/.local/state/…" is how a person writes a path a shell hook
        // owns. Unexpanded it simply fails to open, which under the fail-open
        // rule below makes the whole feature a silent no-op — the one failure
        // mode a scoped row cannot afford. (`pounce doctor` reports the same
        // thing out loud; see Doctor's items section.)
        guard let file, !file.isEmpty else { return nil }
        let path = (file as NSString).expandingTildeInPath
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        // Hard-capped like AppScoped's read of the same file, for the day the
        // path points at something that isn't a 50-line list.
        let data = (try? handle.read(upToCount: 8192)) ?? nil
        try? handle.close()
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        // `.whitespacesAndNewlines`, not `.whitespaces`: a CRLF-written file
        // would otherwise yield "T/pounce\r", which matches no pattern and
        // hides the row instead of failing open.
        return text.split(separator: "\n").lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

// The whole `items` map. Entries are keyed by an item's STABLE KEY — the same
// string the frecency store already uses (see PounceItem.frecencyKey), so one
// map covers every kind of thing the palette can address:
//
//   "cmd:<id>"                      a command script (its filename without .sh)
//   "app:/Applications/Foo.app"     an application, by path
//   "shortcut:<uuid>"               a Shortcuts-library entry, by its library
//                                   identifier (`shortcuts list --show-identifiers`)
//   "mode:<name>"                   a built-in window: launcher, clipboard,
//                                   emoji, screenshots, camera, filesearch
//
//   "items": {
//     "cmd:emoji":                    { "alias": "emo", "hotkey": "opt+e" },
//     "cmd:brew-services":            { "enabled": false },
//     "cmd:lane-here":                { "workspaces": ["T"] },
//     "cmd:shell-here":               { "bundleIds": ["com.mitchellh.ghostty"] },
//     "app:/Applications/Ghostty.app": { "hotkey": "opt+t" },
//     "shortcut:0ECC8F7A-3A52-467A-84C0-511CCE1CB9B7": { "alias": "shelf" },
//     "mode:clipboard":               { "hotkey": "cmd+shift+v" }
//   }
struct ItemSettings {
    var entries: [String: ItemSetting] = [:]

    var isEmpty: Bool { entries.isEmpty }

    // Lenient like the rest of Settings.load: a malformed entry is skipped, not
    // fatal, so one bad line can't cost you the whole map.
    static func parse(_ any: Any?) -> ItemSettings {
        var settings = ItemSettings()
        guard let raw = any as? [String: Any] else { return settings }
        for (key, value) in raw {
            guard let fields = value as? [String: Any] else { continue }
            var entry = ItemSetting()
            if let e = fields["enabled"] as? Bool { entry.enabled = e }
            if let a = fields["alias"] as? String, !a.isEmpty { entry.alias = a }
            entry.hotkey = HotKeySequence.parse(fields["hotkey"])
            entry.workspaces = ItemSetting.stringList(fields["workspaces"])
            // Lowercased at parse time so the per-summon comparison stays a
            // plain `contains` — bundle ids are case-insensitive, and this read
            // happens once per config load rather than once per row per open.
            entry.bundleIds = ItemSetting.stringList(fields["bundleIds"]).map { $0.lowercased() }
            settings.entries[key] = entry
        }
        return settings
    }

    // MARK: Lookups
    //
    // Read on the launcher's hot path (once per item per open), so they stay
    // dictionary lookups against the already-parsed map — no re-reading of disk.

    // False only when an entry explicitly says so; an unlisted item is enabled.
    // Config alone — the answer doesn't move between summons. Kept beside
    // `isVisible` as the narrow question ("is this item switched off?"), which
    // is what a caller wants when a summon isn't what it's asking about; the
    // hotkey path asks neither, because it reads `bindings`, and a key must not
    // come and go with the workspace.
    func isEnabled(_ itemKey: String) -> Bool { entries[itemKey]?.enabled ?? true }

    // Whether the palette should LIST this item right now: `enabled`, plus the
    // context predicates (`workspaces` / `bundleIds`). An item with no entry, or
    // an entry that names no predicate, is visible everywhere.
    func isVisible(_ itemKey: String, in context: ItemContext) -> Bool {
        guard let entry = entries[itemKey] else { return true }
        return entry.enabled && entry.matches(context)
    }

    // Does anything here ask about context at all? The launcher checks this
    // before building an ItemContext, so a config that scopes nothing — every
    // config until someone writes one of these keys — pays no file read and no
    // NSWorkspace call on the summon path.
    var isScoped: Bool { entries.values.contains { $0.isScoped } }

    // A user-assigned search alias ("emo" → Emoji Picker), or nil.
    func alias(for itemKey: String) -> String? { entries[itemKey]?.alias }

    // Every item carrying a hotkey, as (target, sequence) pairs. The daemon
    // registers these at startup (see DaemonMode.run). Sorted by target so the
    // registration order — and therefore the log and `pounce doctor` — is
    // deterministic rather than dictionary-order roulette.
    var bindings: [(target: String, sequence: HotKeySequence)] {
        entries.compactMap { key, entry in entry.hotkey.map { (target: key, sequence: $0) } }
            .sorted { $0.target < $1.target }
    }
}

// MARK: - What a key runs
//
// The target grammar, in one place. It's the same string that keys the `items`
// map and that `pounce run` takes as its argument, so a settings UI writes one
// value and it works as a row key, a hotkey target, and a CLI argument.
enum ItemTarget: Equatable {
    case command(String)   // "cmd:emoji"        — a command script by id
    case app(String)       // "app:/Applications/Foo.app"
    case mode(String)      // "mode:clipboard"   — a built-in window
    case shortcut(String)  // "shortcut:<uuid>"  — a Shortcuts-library entry
    // "setting:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
    // — a System Settings pane, or one setting inside it. The payload is the
    // pane's bundle id plus an optional `?anchor`, which is also exactly what
    // follows `x-apple.systempreferences:` when it opens (see SettingsPaneStore).
    case setting(String)

    // The built-in windows a "mode:" target may name. Single-sourced here so the
    // daemon's dispatch, the CLI's validation and the error text can't drift.
    static let modes = ["launcher", "clipboard", "emoji", "screenshots", "camera", "filesearch"]

    static func parse(_ target: String) -> ItemTarget? {
        if target.hasPrefix("cmd:"), target.count > 4 { return .command(String(target.dropFirst(4))) }
        if target.hasPrefix("app:"), target.count > 4 { return .app(String(target.dropFirst(4))) }
        if target.hasPrefix("shortcut:"), target.count > 9 {
            return .shortcut(String(target.dropFirst(9)))
        }
        if target.hasPrefix("setting:"), target.count > 8 {
            return .setting(String(target.dropFirst(8)))
        }
        if target.hasPrefix("mode:") {
            let name = String(target.dropFirst(5))
            return modes.contains(name) ? .mode(name) : nil
        }
        return nil
    }

    // Why `target` can't be dispatched, or nil if its SHAPE is fine. Deliberately
    // does not check that a command id exists: scripts can appear after the
    // daemon starts, so that's resolved at fire time (and warned about separately
    // at startup — see DaemonMode.run). This is the check that can be answered
    // immediately, which is what lets `pounce run` exit non-zero on a typo
    // instead of reporting success for a key that does nothing.
    static func problem(with target: String) -> String? {
        if target.isEmpty { return "empty target" }
        if parse(target) != nil { return nil }
        if target.hasPrefix("mode:") {
            return "'\(target)' names no built-in mode (expected one of: "
                + modes.map { "mode:" + $0 }.joined(separator: ", ") + ")"
        }
        return "'\(target)' is not an item key "
            + "(expected cmd:<id>, app:<path>, shortcut:<uuid>, setting:<pane>[?<anchor>] "
            + "or mode:<name>)"
    }
}

// MARK: - The binding tree
//
// Sequences that share a leader share a NODE: ⌥Space→E and ⌥Space→C mean one
// ⌥Space registration owning a two-entry map, not two competing registrations.
// That's the whole reason a tree exists rather than a flat list — and it's what
// lets the daemon grab the second-step keys only while a leader is armed (see
// Leader.swift), so a leader costs no Accessibility grant and no event tap.
//
// Pure data, no Carbon, so tests/run.sh can build and assert on it.
final class HotKeyNode {
    // Child steps, keyed by the step's canonical display form ("e", "cmd+c").
    private(set) var children: [String: HotKeyNode] = [:]
    // The step that reaches this node; nil at the root.
    let step: HotKeySpec?
    // Set on a leaf: the item key to run when this node is reached.
    private(set) var target: String?

    init(step: HotKeySpec? = nil) { self.step = step }

    var isLeaf: Bool { target != nil }
    // Children in a stable order, for registration and for the hint overlay.
    var sortedChildren: [HotKeyNode] {
        children.values.sorted { ($0.step?.display ?? "") < ($1.step?.display ?? "") }
    }

    // Every target reachable from `node`, itself included — what a leader key
    // can ultimately run. Used for the startup log and doctor line, so one
    // ⌥Space entry can say how many sequences hang off it and which of them
    // name a command that doesn't exist.
    static func targets(under node: HotKeyNode) -> [String] {
        var found: [String] = []
        if let target = node.target { found.append(target) }
        for child in node.sortedChildren { found.append(contentsOf: targets(under: child)) }
        return found
    }

    // Build the tree. Returns the root plus any conflicts, which are reported
    // rather than resolved silently: a sequence that's a strict prefix of
    // another can never fire (the shorter would always win first), and two
    // items on the identical sequence means one of them is dead. Both are
    // config mistakes the user needs told about — see DaemonMode.run.
    static func build(_ bindings: [(target: String, sequence: HotKeySequence)])
        -> (root: HotKeyNode, conflicts: [String]) {
        let root = HotKeyNode()
        var conflicts: [String] = []

        for (target, sequence) in bindings {
            var node = root
            var blocked: String?
            for step in sequence.steps {
                // Walking THROUGH a leaf: this sequence extends one that already
                // fires, so it could never be reached.
                if let owner = node.target {
                    blocked = "\(sequence.display) → \(target) can never fire: "
                        + "a shorter sequence to \(owner) already fires first"
                    break
                }
                let key = step.display
                if let existing = node.children[key] {
                    node = existing
                } else {
                    let child = HotKeyNode(step: step)
                    node.children[key] = child
                    node = child
                }
            }
            if let blocked { conflicts.append(blocked); continue }
            if let owner = node.target {
                conflicts.append("\(sequence.display) is bound twice (\(owner) and \(target)); keeping \(owner)")
                continue
            }
            if !node.children.isEmpty {
                conflicts.append("\(sequence.display) → \(target) can never fire: "
                    + "a longer sequence starting with it is already bound")
                continue
            }
            node.target = target
        }
        return (root, conflicts)
    }
}
