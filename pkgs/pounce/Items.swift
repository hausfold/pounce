import Foundation

// MARK: - Data Types

enum ItemKind {
    case plain     // generic item from stdin (utility menus): client interprets it
    case command   // launcher command: selecting returns its id to the client
    case app       // launcher app: the daemon launches it natively
    case answer    // inline quick answer (calculator etc.): ⏎ copies it
    case shortcut  // Shortcuts-library entry: the daemon runs it via the CLI
    case setting   // a System Settings pane or one setting in it: opened by URL
}

struct ItemAction {
    let key: String      // "enter", "cmd", "opt", "ctrl" — plus "shift", hint-only
    let label: String

    var displayKey: String {
        switch key {
        case "enter": return "↵"
        case "cmd": return "⌘↵"
        case "opt": return "⌥↵"
        case "ctrl": return "⌃↵"
        // Shift+Return inserts a newline in the wrapping query field, so it never
        // commits and is never a real action — but a free-text step that WANTS a
        // paragraph has to advertise that somewhere, and the action bar is the one
        // place a user already looks to learn what the modifiers do.
        case "shift": return "⇧↵"
        default: return key
        }
    }

    // "Select|cmd:Reveal|opt:Copy" — the grammar a plain stdin row uses in its
    // fourth field, and the one `--actions` takes to label a free-text step. The
    // first segment is the unmodified Return; the rest are `key:label`.
    static func parseSpec(_ spec: String) -> [ItemAction] {
        var actions: [ItemAction] = []
        for (index, part) in spec.split(separator: "|").map(String.init).enumerated() {
            if index == 0 {
                actions.append(ItemAction(key: "enter", label: part))
            } else if part.contains(":") {
                let kv = part.split(separator: ":", maxSplits: 1).map(String.init)
                if kv.count == 2 { actions.append(ItemAction(key: kv[0], label: kv[1])) }
            }
        }
        return actions
    }
}

struct PounceItem: Identifiable {
    let id = UUID()
    let raw: String
    let title: String
    // An extra name to fuzzy-match against, beyond the displayed `title` — for
    // apps whose Finder name (shown as `title`) differs from their Info.plist
    // bundle name, so "Ableton Live 11 Suite" stays findable by typing "live"
    // and "Visual Studio Code" by typing "code". nil for everything else.
    let searchAlias: String?
    let subtitle: String?
    let icon: String?
    let actions: [ItemAction]
    let kind: ItemKind
    let payload: String       // cmd id (command) / bundle path (app) / raw (plain)
    let frecencyKey: String   // stable key for usage history
    let baseBoost: Double     // recency boost for freshly-installed apps
    let group: String?        // optional section header; nil → flat (ungrouped) list
    let submenu: Bool         // command re-invokes pounce (two-step) → loading state
    // What a command's header declared about itself (CommandRisk in
    // CommandRegistry.swift). `.none` for every other kind: an app, a shortcut
    // and a settings pane are macOS's to describe, not a script author's — and
    // for those three the palette is not the thing that decides what runs.
    // `confirm` is read at the commit (DaemonState.commit); the other two are
    // read by the sheet it opens.
    var risk: CommandRisk = .none
    // A user-assigned alias from config.json's `items` map ("emo" → Emoji
    // Picker). Distinct from `searchAlias`, which is the app's own bundle name:
    // this one is chosen by the user, so it matches at a bonus (see
    // DaemonState.matchScore) — typing your own shorthand should win outright.
    // Stamped in DaemonState.load after the items are built, hence `var`.
    var userAlias: String? = nil

    // Extra search terms matched ONE AT A TIME, unlike `searchAlias`. Apple's
    // synonym lists for a settings row are comma-separated blobs of a couple of
    // hundred characters ("files, full disk access, complete, full, disk"), and
    // fuzzy-matching the joined string would make it a subsequence of almost any
    // query. Empty for everything that isn't a settings row.
    var searchKeywords: [String] = []

    // Rows that stay out of the list until the query is at least this long. 0 —
    // everything except the settings INSIDE a pane — means "always eligible".
    // Enforced in DaemonState.matchScore and in the empty-query list, so the
    // 700-odd individual macOS settings can't drown the apps you actually
    // launch. See SettingsPaneStore.
    var minQueryLength: Int = 0

    // Generic stdin line: title \t subtitle \t icon \t actions \t group
    // The trailing `group` field is optional; when any line carries one the list
    // renders with section headers (see ContentView), otherwise it stays flat.
    static func parsePlain(_ line: String, globalIcon: String?) -> PounceItem {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0] : line
        let subtitle = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let icon = (parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil) ?? globalIcon

        var actions: [ItemAction] = []
        if parts.count > 3 && !parts[3].isEmpty {
            actions = ItemAction.parseSpec(parts[3])
        }
        if actions.isEmpty { actions.append(ItemAction(key: "enter", label: "Select")) }

        let group = parts.count > 4 && !parts[4].isEmpty ? parts[4] : nil

        return PounceItem(raw: line, title: title, searchAlias: nil, subtitle: subtitle, icon: icon,
                          actions: actions, kind: .plain, payload: line,
                          frecencyKey: title, baseBoost: 0, group: group, submenu: false)
    }

    // Launcher command registry line (CommandRegistry.Entry.registryLine):
    //   name \t description \t icon \t id \t submenu \t mutates \t confirm \t network
    // Every flag is 1|0, and every one of them is read only if the line HAS it:
    // the three declarations were appended to a four-field line that predates
    // them, so a registry built by an older pounce-palette (or by anything else
    // feeding `--launcher`) still parses — as a command that declares nothing,
    // which is exactly what it is saying.
    static func parseCommand(_ line: String) -> PounceItem {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let title = parts.count > 0 ? parts[0] : line
        let subtitle = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let icon = parts.count > 2 && !parts[2].isEmpty ? parts[2] : "sparkles"
        let id = parts.count > 3 ? parts[3] : title
        func flag(_ i: Int) -> Bool { parts.count > i && parts[i] == "1" }
        let submenu = flag(4)
        return PounceItem(raw: line, title: title, searchAlias: nil, subtitle: subtitle, icon: icon,
                          actions: [ItemAction(key: "enter", label: "Run")],
                          kind: .command, payload: id,
                          frecencyKey: "cmd:\(id)", baseBoost: 0, group: nil, submenu: submenu,
                          risk: CommandRisk(mutates: flag(5), confirm: flag(6), network: flag(7)))
    }

    // A quick answer (inline calculator & friends) pinned as the first row.
    // Query-derived, so it lives outside state.items/frecency: ContentView
    // prepends it per keystroke and commit() copies `payload` instead of
    // round-tripping to a client.
    static func answer(_ a: QuickAnswer) -> PounceItem {
        return PounceItem(raw: a.copyText, title: a.display, searchAlias: nil, subtitle: a.detail,
                          icon: a.icon,
                          actions: [ItemAction(key: "enter", label: "Copy Answer")],
                          kind: .answer, payload: a.copyText,
                          frecencyKey: "answer", baseBoost: 0, group: nil, submenu: false)
    }

    static func app(name: String, path: String, boost: Double, alias: String? = nil) -> PounceItem {
        return PounceItem(raw: path, title: name, searchAlias: alias, subtitle: "Application",
                          icon: "app:\(path)",
                          actions: [ItemAction(key: "enter", label: "Open"),
                                    ItemAction(key: "cmd", label: "Reveal in Finder")],
                          kind: .app, payload: path,
                          frecencyKey: "app:\(path)", baseBoost: boost, group: nil, submenu: false)
    }

    // One entry from the Shortcuts library (see Shortcuts.swift). Keyed by the
    // library UUID rather than the name, so renaming a shortcut in Shortcuts.app
    // keeps its frecency and any `items` override pointed at it.
    static func shortcut(name: String, id: String) -> PounceItem {
        return PounceItem(raw: id, title: name, searchAlias: nil, subtitle: "Shortcut",
                          icon: "app:\(ShortcutsStore.iconPath)",
                          actions: [ItemAction(key: "enter", label: "Run")],
                          kind: .shortcut, payload: id,
                          frecencyKey: "shortcut:\(id)",
                          baseBoost: -ShortcutsStore.emptyQueryPenalty, group: nil, submenu: false)
    }

    // A System Settings pane, or one setting inside it (see SystemSettings.swift).
    // The pane's row is always eligible; a sub-item waits for `subItemMinQuery`
    // characters. Its title is Apple's own sentence for the setting — the words
    // people actually type ("full disk access") live in the keywords, which is
    // why both are searched.
    static func setting(_ entry: SettingsPaneEntry, subItemMinQuery: Int) -> PounceItem {
        let isPane = entry.anchor == nil
        return PounceItem(raw: entry.url, title: entry.title, searchAlias: entry.alias,
                          subtitle: isPane ? "System Settings" : entry.pane,
                          icon: "app:\(entry.iconPath)",
                          actions: [ItemAction(key: "enter", label: "Open")],
                          kind: .setting, payload: entry.url,
                          frecencyKey: entry.itemKey,
                          baseBoost: isPane ? -SettingsPaneStore.emptyQueryPenalty : 0,
                          group: nil, submenu: false,
                          searchKeywords: entry.keywords,
                          minQueryLength: isPane ? 0 : subItemMinQuery)
    }

    // A file/folder hit for the Find Files mode. Display-only: FileSearchView
    // routes selection to DaemonState.commitFile (open / reveal / copy), so this
    // never flows through the generic commit(). The "file:" icon renders the
    // file's real Finder icon (see ItemRow); `parent` is the abbreviated dir.
    static func file(name: String, path: String, parent: String) -> PounceItem {
        return PounceItem(raw: path, title: name, searchAlias: nil, subtitle: parent,
                          icon: "file:\(path)",
                          actions: [ItemAction(key: "enter", label: "Open"),
                                    ItemAction(key: "cmd", label: "Reveal in Finder"),
                                    ItemAction(key: "opt", label: "Copy Path")],
                          kind: .plain, payload: path,
                          frecencyKey: "file:\(path)", baseBoost: 0, group: nil, submenu: false)
    }

    func action(for key: String) -> ItemAction? { actions.first { $0.key == key } }
}

// MARK: - Fuzzy Matching

enum Fuzzy {
    // Subsequence match with quality scoring. Returns nil if `query` is not a
    // subsequence of `target`. Higher = tighter / earlier / word-boundary match.
    static func score(_ query: [Character], _ target: String) -> Double? {
        let t = Array(target)
        guard !query.isEmpty else { return 0 }
        var qi = 0
        var score = 0.0
        var prevMatch = -2
        var firstIdx = -1

        for (ti, ch) in t.enumerated() {
            guard qi < query.count, ch == query[qi] else { continue }
            if firstIdx < 0 { firstIdx = ti }
            var s = 1.0
            if ti == prevMatch + 1 { s += 2.5 }                    // consecutive run
            if ti == 0 { s += 2.0 }                                // very start
            else {
                let p = t[ti - 1]
                if p == " " || p == "-" || p == "_" || p == "." { s += 1.5 } // word boundary
            }
            score += s
            prevMatch = ti
            qi += 1
        }
        guard qi == query.count else { return nil }

        // Reward tight targets and front-loaded matches.
        let coverage = Double(query.count) / Double(max(t.count, 1))
        let frontBonus = firstIdx == 0 ? 1.5 : 0
        return score + coverage * 2.0 + frontBonus
    }
}
