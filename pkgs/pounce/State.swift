import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Where a summon came from
//
// The AppKit half of ItemSettings' context predicates (the rest is
// Foundation-only so tests/run.sh can compile it). Called at most once per
// launcher build, and only when the config scopes something.
extension ItemContext {
    static func current(settings: Settings) -> ItemContext {
        // The palette hasn't activated yet at this point — every path calls
        // DaemonState.load before PounceUI.present() steals focus, and this
        // depends on that order — so the frontmost app is still the one you
        // pressed the key over. Belt and braces anyway: if it
        // IS us (a re-entrant summon, a linger), say we don't know rather than
        // scoping every row against Pounce itself.
        let front = NSWorkspace.shared.frontmostApplication
        let ours = front?.processIdentifier == NSRunningApplication.current.processIdentifier
        return ItemContext(
            workspace: WorkspaceMRU.current(file: settings.pages.mruFile),
            bundleId: ours ? nil : front?.bundleIdentifier)
    }
}

// MARK: - Commit

// hideNow: close immediately. linger: brief fade (terminal action). loading:
// keep the window up showing a spinner until the next request swaps in (a
// two-step command re-invoking pounce) — never a gap between steps.
enum Disposition { case hideNow, linger, loading }

struct Commit {
    let clientString: String?               // sent back to the connected client (nil → "")
    let disposition: Disposition
    let appLaunch: (path: String, reveal: Bool)?
    // When true, after hiding the window the daemon reactivates the previously
    // focused app and synthesizes ⌘V (clipboard auto-paste). Defaults false so
    // the existing memberwise-init call sites need no change.
    var pasteAfter: Bool = false
    // A Find Files hit to act on: open it in its default app (reveal false) or
    // reveal it in Finder (reveal true). Distinct from appLaunch, which uses the
    // app-specific openApplication path; files open via NSWorkspace.open.
    var fileOpen: (path: String, reveal: Bool)? = nil
    // A Shortcuts-library entry to run, by identifier. A daemon-side side
    // effect rather than a clientString verb for the same reason appLaunch is
    // one: the launcher is presented by three different paths (the in-process
    // hotkey, a socket client running pounce-palette, and the no-daemon
    // fallback), and only the first of those could interpret a new verb. Acting
    // here makes ⏎ run the shortcut on all three.
    var shortcutRun: String? = nil
    // A System Settings deep link to open (`x-apple.systempreferences:…`).
    // Daemon-side for the same reason shortcutRun is: only the in-process hotkey
    // path could interpret a new clientString verb, and this has to work from
    // the socket client and the no-daemon fallback too.
    var settingOpen: String? = nil
}

// MARK: - State

enum DisplayMode { case list, clipboard, emoji, screenshots, camera, cheatsheet, fileSearch }

final class DaemonState: ObservableObject {
    @Published var items: [PounceItem] = []
    @Published var itemsSorted: [PounceItem] = []   // empty-query order
    @Published var placeholderText: String = "Search..."
    @Published var globalIcon: String? = nil
    @Published var isVisible: Bool = false
    @Published var requestID = UUID()
    @Published var metrics: LayoutMetrics = .standard
    @Published var displayMode: DisplayMode = .list
    @Published var clipEntries: [ClipEntry] = []
    @Published var emojiEntries: [EmojiEntry] = []
    @Published var screenshotEntries: [ScreenshotEntry] = []
    @Published var cheatsheetGroups: [CheatsheetGroup] = []
    // Find Files: live results and whether a search is in flight (spinner/hint).
    @Published var fileResults: [FileHit] = []
    @Published var fileSearching = false
    @Published var fileSearchEnabled = true   // false → mode shows a "disabled" note
    var cheatsheetPath = ""            // set with cheatsheetGroups; read-only for the view
    @Published var isLoading = false   // skeleton shown between a two-step command's steps
    @Published var loadingTitle = ""   // selected command's name, shown in the static header
    @Published var loadingIcon = "magnifyingglass"
    // The launcher's search text. Held here (not as ContentView @State) so reset()
    // can clear it synchronously before step 2 renders — no one-frame flash of the
    // previous query.
    @Published var query = ""

    var isLauncher = false
    var maxEmpty = Int.max
    // The Stage (Stage.swift), snapshotted per summon rather than read in a view
    // body — that is what keeps the zone free on the keystroke path. `stageTiles`
    // is how many of the empty-query rows are drawn as TILES; 0 is what the off
    // switch, a non-launcher step and a config without the key all reduce to, so
    // "is there a stage?" is one integer and never a chain of predicates.
    @Published var stageTiles = 0
    // The glance line's contents, built once in load(). nil → no line.
    @Published var stageGlance: StageGlance?
    // Trailing-row key hints ("⌘⇧V"), one lookup per row in the view. Built
    // once per load from the items map — the glyphs come off a hotkey the
    // daemon already parsed and registered; the view never walks the map.
    @Published var hotkeyHints: [String: String] = [:]
    // Live state badges ("On"/"Off"), filled synchronously from BadgeStore's
    // cache where fresh and async as runs land. See Badges.swift.
    @Published var badges: [String: String] = [:]
    // How many settings a single System Settings pane may contribute to one
    // result list (ContentView.filtered). Read off config on every summon like
    // everything else; Int.max outside the launcher, where there are no
    // settings rows to cap.
    var settingsMaxPerPane = Int.max
    // --chain: which free-text commits the caller answers by running another
    // `pounce`, so those commits hold the window in the loading state instead of
    // fading out and re-opening. Keyed by action ("enter", "cmd", "opt", "ctrl")
    // because one step can chain on one modifier and not another: ⌥↵ "show my
    // drafts" is a second picker and should hold the window, while ⌘↵ "let me
    // drag out a screenshot" needs the palette off the screen first. Empty →
    // nothing chains. Row picks are unaffected (see buildCommit).
    var chainActions: Set<String> = []
    // --actions: the label spec for a free-text step's action bar. That bar is
    // otherwise drawn only for a selected ROW, which leaves a step that asks for
    // typed text with nowhere to say what ⌘↵ / ⌥↵ / ⇧↵ do.
    var freeTextActions: [ItemAction] = []
    // --draft <key>: file the query under this key on any dismissal that isn't a
    // commit, so a stray click into another app can't take a typed paragraph with
    // it. nil → this invocation keeps nothing. See Drafts.swift.
    var draftKey: String? = nil
    // --dial: the step's in-place option cyclers ("model=sonnet|opus|haiku"),
    // drawn as chips at the leading edge of the action bar and stepped with
    // ⇥ / ⇧⇥ (⌃⇥ moves between dials). Committed values ride the client string
    // as an extra middle field — see takeDialField(). Empty → no dials, and
    // the published two-field output shape is untouched.
    @Published var dials: [Dial] = []
    @Published var activeDial = 0
    // --grid: draw this step's rows as cards two to a row instead of as a list
    // (ContentView.gridScroll). A SHAPE the caller asked for and nothing else —
    // the items, the commit path and the printed result are the list step's,
    // byte for byte, so a caller switches a step between the two by adding or
    // removing one flag. Launcher-only in the sense that it applies to
    // `displayMode == .list`; the built-in windows own their own layouts.
    @Published var grid = false
    // The action key that just committed, for the action bar's press blink
    // (see KeyCap). Set at the commit, read for the fraction of a second the
    // window lingers before its fade — it is feedback, never part of the
    // client string, and reset() clears it with everything else.
    @Published var firedAction: String? = nil

    // The clipboard and emoji views are fixed-size windows; everything else
    // follows the launcher's windowMode width.
    var targetWidth: CGFloat {
        switch displayMode {
        case .clipboard: return ClipboardLayout.width
        case .emoji: return EmojiLayout.width
        case .screenshots: return ScreenshotLayout.width
        case .camera: return CameraLayout.width
        case .cheatsheet: return CheatsheetLayout.width
        case .fileSearch: return FileSearchLayout.width
        case .list: return metrics.width
        }
    }

    let frecency = Frecency()
    // What each query has been answered with before — the pairing memory that
    // makes the palette teachable rather than merely adaptive (QueryMemory.swift).
    let queryMemory = QueryMemory()
    // Which items hold the Stage's tile slots, and in which order (StageSlots.swift).
    let stageSlots = StageSlotStore()
    // Lazily created the first time Find Files mode opens (no cost otherwise);
    // holds the live NSMetadataQuery. reset() stops it so it never runs on after
    // the palette closes.
    private var fileSearcher: FileSearchController?
    private var frecencyScores: [UUID: Double] = [:]
    // Mirrors `ranking.learnFromQueries`, captured per summon rather than read
    // at commit time: config lives on disk, and the commit path already has
    // enough to do without a second read of it. False for every non-launcher
    // step — a utility menu's lines are its caller's payload, not a vocabulary
    // the user is building, and the same word means something different in each.
    private var learnFromQueries = false

    // Quick answer (inline calculator & friends) for the current launcher
    // query. Memoized per query string because ContentView.filtered — where
    // this is read — re-evaluates on every render, not just on keystrokes.
    private var answerQuery = ""
    private var answerItem: PounceItem?
    private var noticeVersion: String?
    private var noticeItem: PounceItem?
    // The scored match list, memoized per query string — see rankedMatches().
    private var rankedQuery: String?
    private var rankedRows: [PounceItem] = []

    var onCommit: ((Commit) -> Void)?
    var onResize: (() -> Void)?       // content height changed; window should refit
    // When the view knows its exact target height (the launcher computes it from
    // row metrics — see ContentView.contentHeight), it stashes it here right
    // before calling onResize so the window can resize to it synchronously, in
    // the same turn, without measuring hosting.fittingSize (stale same-turn on
    // Tahoe). nil → the window measures (command/cheatsheet views). resizeToFit
    // consumes and clears it.
    var pendingContentHeight: CGFloat?
    weak var textField: NSTextField?

    func reset() {
        // A new request replaces whatever mode is up; make sure a live camera
        // session from a previous peek doesn't keep the hardware (and its
        // indicator light) on behind the next view.
        if displayMode == .camera { CameraController.shared.stop() }
        // Stop any live file-search query so it doesn't keep hitting the metadata
        // index after the palette is dismissed.
        fileSearcher?.stop()
        fileResults = []
        fileSearching = false
        items = []
        itemsSorted = []
        frecencyScores = [:]
        learnFromQueries = false
        placeholderText = "Search..."
        globalIcon = nil
        isLauncher = false
        maxEmpty = Int.max
        stageTiles = 0
        stageGlance = nil
        hotkeyHints = [:]
        badges = [:]
        settingsMaxPerPane = Int.max
        chainActions = []
        freeTextActions = []
        draftKey = nil
        dials = []
        activeDial = 0
        grid = false
        firedAction = nil
        requestID = UUID()
        displayMode = .list
        clipEntries = []
        emojiEntries = []
        screenshotEntries = []
        cheatsheetGroups = []
        isLoading = false
        query = ""
        answerQuery = ""
        answerItem = nil
        pendingContentHeight = nil
        noticeVersion = nil
        noticeItem = nil
        rankedQuery = nil
        rankedRows = []
    }

    // The quick answer pinned above the launcher's results, if the query is
    // expression-shaped (see QuickAnswerHub). Launcher-only: utility menus
    // pipe arbitrary lines where "2*3" may be a legitimate item filter.
    func quickAnswerItem(for query: String) -> PounceItem? {
        guard isLauncher, displayMode == .list else { return nil }
        if query != answerQuery {
            answerQuery = query
            answerItem = QuickAnswerHub.answer(for: query).map(PounceItem.answer)
        }
        return answerItem
    }

    // A pending update, pinned as the launcher's first row on an empty query
    // (ContentView.filtered). This hoists the EXISTING Update Pounce row rather
    // than minting a new item, so ⏎ runs the same script through the same path
    // and the row already carries UpdateNudge.decorate's rename + per-install
    // hint. Without the pin the rename is close to invisible: an empty query
    // shows the top `maxEmpty` rows by frecency, and the updater never ranks.
    // Cached like the quick answer, and for the same reason: `filtered`
    // recomputes on every render, and PounceItem mints a fresh UUID per
    // instance — rebuilding here would hand SwiftUI a new identity each pass
    // and thrash the row. Cleared in reset(), so each summon rebuilds it once
    // against that summon's registry.
    func updateNoticeItem() -> PounceItem? {
        guard isLauncher, displayMode == .list,
              let version = UpdateNudge.shared.pendingVersion
        else { return nil }
        if noticeVersion != version {
            noticeVersion = version
            let source = items.first { $0.frecencyKey == "cmd:update-pounce" }
            noticeItem = source.map { row in
                // Same payload/kind, so ⏎ still runs the script through the
                // usual path — only the advertised actions change. ⌘⏎ is the
                // way out for anyone who can't clear it with a keystroke (the
                // Nix cohorts update through the store, not from here).
                let kind = UpdateNudge.shared.installKind
                return PounceItem(
                    raw: row.raw, title: row.title, searchAlias: row.searchAlias,
                    subtitle: row.subtitle, icon: row.icon,
                    actions: [ItemAction(key: "enter",
                                         label: kind.canSelfUpdate ? "Install now" : "Show how"),
                              ItemAction(key: "cmd", label: "Skip this version")],
                    kind: row.kind, payload: row.payload, frecencyKey: row.frecencyKey,
                    baseBoost: row.baseBoost, group: row.group, submenu: row.submenu)
            }
            noticeItem?.userAlias = source?.userAlias
        }
        return noticeItem
    }

    // Load the clipboard history view from the daemon's own store.
    func loadClipboard(placeholder: String?) {
        displayMode = .clipboard
        clipEntries = ClipboardStore.shared.entries()
        placeholderText = placeholder ?? "Clipboard history…"
    }

    func commitClip(_ entry: ClipEntry) {
        ClipboardStore.shared.restore(entry)
        // Auto-paste when enabled AND we hold the Accessibility grant; otherwise
        // fall back to clipboard-only (restore already ran) and nudge once.
        var paste = false
        if Settings.load().clipboard.autoPaste {
            if AXIsProcessTrusted() {
                paste = true
            } else {
                AccessibilityHint.promptOnce()
            }
        }
        onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil, pasteAfter: paste))
    }

    // Load the recent-screenshots grid from the configured screencapture folder.
    func loadScreenshots(placeholder: String?) {
        displayMode = .screenshots
        screenshotEntries = ScreenshotStore.recent()
        placeholderText = placeholder ?? "Recent screenshots…"
    }

    // Copy the selected screenshot to the clipboard as both an image (paste into
    // Slack/Notion) and a file reference (⌘V in Finder pastes the file).
    func commitScreenshot(_ entry: ScreenshotEntry) {
        Pasteboard.copyFile(URL(fileURLWithPath: entry.path))
        onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil))
    }

    // Show the live camera peek; the capture session starts immediately so the
    // first frames are already flowing by the time the window fades in.
    func loadCamera(placeholder: String?) {
        displayMode = .camera
        placeholderText = placeholder ?? "Camera"
        CameraController.shared.start()
    }

    // Load the cheatsheet overlay from JSON. The path is kept so the view can
    // say where it looked when the file is missing or malformed.
    func loadCheatsheet(path: String, placeholder: String?) {
        displayMode = .cheatsheet
        placeholderText = placeholder ?? "Cheatsheet"
        cheatsheetPath = path
        cheatsheetGroups = CheatsheetStore.load(path: path)
    }

    // Load the emoji grid from the bundled dataset.
    func loadEmoji(placeholder: String?) {
        displayMode = .emoji
        emojiEntries = EmojiStore.shared.all
        placeholderText = placeholder ?? "Search emoji…"
    }

    // MARK: Find Files

    // Enter Find Files mode. The searcher is created on first use (wired to
    // publish results here) and configured from live settings each time.
    func loadFileSearch(placeholder: String?) {
        displayMode = .fileSearch
        let cfg = Settings.load().fileSearch
        fileSearchEnabled = cfg.enabled
        fileResults = []
        fileSearching = false
        placeholderText = placeholder ?? "Search files & folders…"
        guard cfg.enabled else { return }

        let searcher = fileSearcher ?? FileSearchController(
            frecency: { [weak self] key in self?.frecency.score(for: key) ?? 0 })
        searcher.maxResults = cfg.maxResults
        searcher.homeOnly = cfg.homeOnly
        searcher.onUpdate = { [weak self] hits, searching in
            // The query runs on main, but guard the hop so a stray notification
            // can never touch @Published off-main.
            if Thread.isMainThread {
                self?.fileResults = hits; self?.fileSearching = searching
            } else {
                DispatchQueue.main.async { self?.fileResults = hits; self?.fileSearching = searching }
            }
        }
        fileSearcher = searcher
    }

    // A keystroke in Find Files mode: drive the live query (debounced inside).
    func fileQueryChanged(_ query: String) {
        fileSearcher?.search(query)
    }

    // Act on a selected file. Open (⏎) and reveal (⌘⏎) route through the daemon's
    // NSWorkspace; copy-path (⌥⏎) is handled here (clipboard + client echo). Every
    // path records frecency so files you open float up next time. All read-only —
    // nothing here moves or deletes a file.
    func commitFile(_ hit: FileHit, action: String) {
        frecency.record("file:\(hit.path)")
        switch action {
        case "cmd":
            onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil,
                             fileOpen: (hit.path, true)))
        case "opt":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(hit.path, forType: .string)
            onCommit?(Commit(clientString: hit.path, disposition: .hideNow, appLaunch: nil))
        default:
            onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil,
                             fileOpen: (hit.path, false)))
        }
    }

    func emojiFrecency(_ c: String) -> Double { frecency.score(for: "emoji:\(c)") }

    // Relevance of an emoji for a typed query (name + keywords), nil → no match.
    func emojiMatch(_ e: EmojiEntry, query: [Character]) -> Double? {
        guard let s = Fuzzy.score(query, e.search) else { return nil }
        let frec = emojiFrecency(e.c)
        return s + (frec / (frec + 5)) * 1.5
    }

    // Copy the emoji to the clipboard, record frecency, and echo it to the client.
    // Same auto-paste contract as commitClip: with clipboard.autoPaste on and the
    // Accessibility grant held, the emoji lands straight at the cursor of the
    // previously-focused app instead of stopping at the clipboard.
    func commitEmoji(_ e: EmojiEntry) {
        frecency.record("emoji:\(e.c)")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(e.c, forType: .string)
        var paste = false
        if Settings.load().clipboard.autoPaste {
            if AXIsProcessTrusted() {
                paste = true
            } else {
                AccessibilityHint.promptOnce()
            }
        }
        onCommit?(Commit(clientString: e.c, disposition: .hideNow, appLaunch: nil, pasteAfter: paste))
    }

    func load(lines: [String], placeholder: String?, icon: String?, launcher: Bool, maxEmpty: Int?,
              chainActions: Set<String> = [], freeTextActions: [ItemAction] = [],
              draftKey: String? = nil, seedQuery: String = "", dials: [Dial] = [],
              grid: Bool = false) {
        globalIcon = icon
        isLauncher = launcher
        // The launcher itself is never a grid: its rows are names you scan and
        // its list carries group headers, the quick answer's hero card and the
        // update nudge — none of which have a card shape. `--grid --launcher`
        // is therefore the flag being ignored, not an error.
        self.grid = grid && !launcher
        self.chainActions = chainActions
        self.freeTextActions = freeTextActions
        self.draftKey = draftKey
        // Each dial opens on the value it committed last time (see DialMemory).
        self.dials = DialMemory.recall(dials)
        self.activeDial = 0
        // reset() cleared this a moment ago; --query is the caller putting text
        // BACK (a draft handed over for editing), so it has to land after.
        self.query = seedQuery
        self.maxEmpty = maxEmpty ?? (launcher ? 7 : Int.max)

        var built: [PounceItem] = []
        // The Stage's slot order, resolved below once `built` is final and
        // applied after the sort — see hoistSlots.
        var slotKeys: [String] = []
        if launcher {
            let settings = Settings.load()
            learnFromQueries = settings.ranking.learnFromQueries
            built.append(contentsOf: lines.filter { !$0.isEmpty }.map { PounceItem.parseCommand($0) })
            built.append(contentsOf: AppScanner.shared.apps(
                demotedBundleIds: settings.appLauncher.demoteBundleIds,
                hiddenBundleIds: Set(settings.appLauncher.hideBundleIds)))
            // The Shortcuts library, which is also how an app's App Intent
            // becomes runnable from here — see Shortcuts.swift for why the
            // intents themselves can't be. The store is told the setting on
            // every summon (config is re-read here) so its background refresh
            // stops the moment you switch it off, and resumes when you don't.
            ShortcutsStore.shared.setEnabled(settings.shortcuts.enabled)
            if settings.shortcuts.enabled {
                built.append(contentsOf: ShortcutsStore.shared.items())
            }
            // System Settings: every pane, plus the ~700 individual settings
            // inside them, read out of the panes' own search index (see
            // SystemSettings.swift). The sub-items carry a minQueryLength so
            // they stay out of the way until you've typed enough to mean one.
            SettingsPaneStore.shared.setEnabled(settings.systemSettings.enabled)
            settingsMaxPerPane = settings.systemSettings.maxPerPane
            if settings.systemSettings.enabled {
                built.append(contentsOf: SettingsPaneStore.shared.items(
                    subItemMinQuery: settings.systemSettings.subItemMinQuery))
            }
            // Apply the per-item overrides from config.json's `items` map. Both
            // passes key off frecencyKey ("cmd:<id>" / "app:<path>"), which is
            // exactly how the map is addressed — see ItemSetting. Done here, on
            // the assembled list, so commands and apps obey the same rules and a
            // future settings UI has one place to reason about.
            if !settings.items.isEmpty {
                // Where this summon came from, for the rows that asked to be
                // scoped to it (`workspaces` / `bundleIds` — see ItemSetting).
                // Built only when some entry actually asks, so an unscoped
                // config pays nothing for the feature on the ⌘Space path.
                let context = settings.items.isScoped
                    ? ItemContext.current(settings: settings) : .unknown
                built.removeAll { !settings.items.isVisible($0.frecencyKey, in: context) }
                for i in built.indices {
                    built[i].userAlias = settings.items.alias(for: built[i].frecencyKey)
                }
            }
            // The Stage. Snapshotted HERE — once, on the summon — and never in
            // a view body: formatting a date or asking the clipboard store for
            // its head on every render would put that work on the keystroke
            // path, which is the one thing this zone may not cost.
            //
            // Compact mode is deliberately excluded. `hideEmptyList` means "an
            // empty query shows nothing", and a strip of tiles is emphatically
            // something — the two are answers to the same question and the
            // narrower one wins.
            if settings.stage.enabled && !settings.metrics.hideEmptyList {
                stageGlance = StageGlance.now(clipboardEnabled: settings.clipboard.enabled)
                // Which items get tiles, and where each one sits. The strip is
                // ranked by HABIT ALONE — `longScore`, a 30-day average with
                // today's burst deliberately excluded — and then holds its
                // positions, because a tile you can hit without looking is
                // worth more than a tile that is optimally ranked. The list
                // beneath keeps the live ranking. See StageSlots.swift for the
                // promotion rule; the reordering that makes the strip a SLICE
                // of the one array happens after the sort below.
                if settings.ranking.stickyTiles {
                    let candidates = built
                        .filter { $0.minQueryLength == 0 }
                        .map { (key: $0.frecencyKey, score: frecency.longScore(for: $0.frecencyKey)) }
                        .filter { $0.score > 0 }
                        .sorted { $0.score > $1.score }
                    // Fewer slots than asked for is the honest answer on a
                    // pounce that has not been used yet: nothing has earned one.
                    slotKeys = stageSlots.resolve(candidates: candidates, slots: settings.stage.tiles)
                    stageTiles = slotKeys.count
                } else {
                    stageTiles = settings.stage.tiles
                }
                // The list beneath keeps its full length: a tile is a row
                // PROMOTED out of the ranked prefix, not one taken away from it,
                // so turning the Stage on never costs you list.
                if self.maxEmpty != Int.max { self.maxEmpty += stageTiles }
            }
            // Row hints and state badges. Both are dictionary lookups in the
            // view — the glyph formatting happens HERE, once per summon, off a
            // sequence the daemon already parsed. A badge fresh in BadgeStore's
            // cache lands synchronously (a lookup, no I/O); a stale one is
            // fetched in the background and published when it arrives, so the
            // summon path never waits for a shell (see Badges.swift).
            var hints: [String: String] = [:]
            for (target, sequence) in settings.items.bindings { hints[target] = sequence.glyphs }
            for (target, hint) in settings.items.hints where hint != nil {
                hints[target] = hint!
            }
            hotkeyHints = hints
            let byKey = Dictionary(uniqueKeysWithValues:
                settings.items.stateCommands.map { ($0.target, $0.command) })
            for item in built {
                guard let command = byKey[item.frecencyKey] else { continue }
                if let cached = BadgeStore.cached(for: command) {
                    badges[item.frecencyKey] = cached
                } else {
                    BadgeStore.fetch(command) { [weak self] value in
                        self?.badges[item.frecencyKey] = value
                    }
                }
            }
            placeholderText = placeholder ?? "Search apps & actions..."
        } else {
            built = lines.map { PounceItem.parsePlain($0, globalIcon: icon) }
            placeholderText = placeholder ?? (lines.isEmpty ? "Input..." : "Search...")
        }
        items = built
        rankedQuery = nil   // new items → any memoized ranking is stale
        frecencyScores = Dictionary(uniqueKeysWithValues: built.map { ($0.id, frecency.score(for: $0.frecencyKey)) })

        // Tie-break: the launcher's own items have no meaningful input order
        // (filesystem-order roulette among the many zero-score apps), so sort
        // them by title. A piped list is the opposite — the script already
        // ranked it (a search engine's relevance order, a curated menu), and
        // alphabetizing that throws the ranking away. Keep the caller's order.
        let rank = Dictionary(uniqueKeysWithValues: built.enumerated().map { ($0.element.id, $0.offset) })
        itemsSorted = built.sorted { a, b in
            let sa = (frecencyScores[a.id] ?? 0) + a.baseBoost
            let sb = (frecencyScores[b.id] ?? 0) + b.baseBoost
            if sa != sb { return sa > sb }
            if launcher { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
            return (rank[a.id] ?? 0) < (rank[b.id] ?? 0)
        }
        if !slotKeys.isEmpty { itemsSorted = Self.hoistSlots(slotKeys, in: itemsSorted) }
    }

    // Put the Stage's slots at the head of the empty-query order, in SLOT order.
    // That is the whole mechanism behind the strip/list split: ContentView reads
    // `visible.prefix(tileCount)` as the strip and `dropFirst(tileCount)` as the
    // list, so hoisting here gives the strip its own stable ranking AND stops
    // the list from repeating it — with no second array, and no second meaning
    // for `selectedIndex`. See Stage.swift, rule 1.
    private static func hoistSlots(_ keys: [String], in sorted: [PounceItem]) -> [PounceItem] {
        var byKey: [String: PounceItem] = [:]
        for item in sorted where byKey[item.frecencyKey] == nil { byKey[item.frecencyKey] = item }
        let tiles = keys.compactMap { byKey[$0] }
        guard !tiles.isEmpty else { return sorted }
        let tileIDs = Set(tiles.map { $0.id })
        return tiles + sorted.filter { !tileIDs.contains($0.id) }
    }

    private func frecency(for item: PounceItem) -> Double { frecencyScores[item.id] ?? 0 }

    // The empty-query list. Rows that ask for a minimum query length (the
    // individual macOS settings — see SettingsPaneStore) are not eligible here
    // by definition: this IS the no-query case.
    var emptyQueryRows: [PounceItem] {
        Array(itemsSorted.lazy.filter { $0.minQueryLength == 0 }.prefix(maxEmpty))
    }

    // The scored, sorted, per-pane-capped matches for a typed query, memoized
    // on the query string. ContentView.filtered is a computed property, and
    // SwiftUI reads it well over a dozen times per render pass — every derived
    // property there (the tile slice, the list slice, the heights, the three
    // onChange watchers, contentHeight via requestResize) bottoms out in it.
    // The scoring pass fuzzy-matches every item on title, aliases, subtitle
    // AND each settings keyword (~3300 of those alone), so uncached it
    // multiplied the one genuinely expensive pass per keystroke by ~15 — which
    // was the typing lag. Memoized, a keystroke pays for exactly one pass.
    // Invalidated by reset() and load(); same pattern as the quick answer and
    // the update notice above.
    func rankedMatches(for trimmed: String) -> [PounceItem] {
        if rankedQuery == trimmed { return rankedRows }
        let q = Array(trimmed.lowercased())
        // What THIS query has been answered with before. Looked up once, here,
        // and read as a dictionary lookup per item inside the scoring pass —
        // the pass already fuzzy-matches every title, alias, subtitle and
        // settings keyword on every keystroke, and a second string pass over
        // the same items is exactly the budget it does not have.
        let taught = learnFromQueries ? queryMemory.boosts(for: trimmed) : [:]
        let scored = items.compactMap { item -> (PounceItem, Double)? in
            guard let s = matchScore(item, query: q, taught: taught[item.frecencyKey] ?? 0)
            else { return nil }
            return (item, s)
        }
        // One System Settings pane can hold hundreds of settings (Accessibility
        // alone ships 342), so a short query would otherwise return one pane's
        // worth of rows and nothing else. Applied after sorting, so what
        // survives is that pane's best matches — and it touches nothing but
        // settings sub-items.
        rankedRows = SettingsPaneStore.capPerPane(scored.sorted { $0.1 > $1.1 }.map { $0.0 },
                                                  limit: settingsMaxPerPane)
        rankedQuery = trimmed
        return rankedRows
    }

    // Combined relevance for a typed query. nil → no match.
    // `taught` is what QueryMemory has learned about this exact query and this
    // item (0 when it has learned nothing). It is passed in rather than looked
    // up here for the reason rankedMatches gives.
    func matchScore(_ item: PounceItem, query: [Character], taught: Double = 0) -> Double? {
        // Gated rows (a setting inside a System Settings pane) join the list
        // only once the query is specific enough to be asking for one. The
        // panes themselves are ungated and always searchable.
        guard query.count >= item.minQueryLength else { return nil }
        let title = Fuzzy.score(query, item.title.lowercased())
        // An app's bundle name (e.g. "Live" for Ableton) scores at full weight —
        // it's a legitimate name for the app, just not the one we display.
        let alias = item.searchAlias.flatMap { Fuzzy.score(query, $0.lowercased()) }
        // A user-assigned alias beats both: the user picked this shorthand for
        // this item, so typing it should land here rather than on whatever app
        // happens to fuzzy-match the same letters more tightly.
        let user = item.userAlias.flatMap { Fuzzy.score(query, $0.lowercased()).map { $0 + 4.0 } }
        let sub = item.subtitle.flatMap { Fuzzy.score(query, $0.lowercased()) }
        // Apple's synonyms for a settings row, scored one TERM at a time — the
        // words a person types ("full disk access") are usually only in here,
        // never in the title. Discounted, because these are synonyms and not
        // names: at full weight an exact hit on one of the ~3300 settings
        // keywords ties an exact hit on an app's own name, and there are a lot
        // more keywords than apps (typing "safari" started returning a settings
        // row that lists Safari among its synonyms, ahead of Safari). A settings
        // row's real alternate NAMES go through `searchAlias`, which is
        // undiscounted. Scoring the joined blob instead would make a
        // 200-character string a subsequence of any query — see
        // SystemSettings.swift.
        let keyword = item.searchKeywords.isEmpty ? nil
            : item.searchKeywords.compactMap { Fuzzy.score(query, $0) }.max().map { $0 * 0.9 }
        let candidates = [title, alias, user, keyword, sub.map { $0 * 0.5 }].compactMap { $0 }
        guard let best = candidates.max() else {
            // Nothing you typed appears in this row at ALL — and yet you have
            // repeatedly answered this exact query with it. That is the only
            // way "mail" can come to mean Superhuman, so a pairing this well
            // established brings the row in on its own, scored on what it has
            // earned. The threshold is two confident picks (QueryMemory.
            // rescueBoost), never one: a row conjured out of nowhere on the
            // strength of a single accident is worse than no learning.
            return taught >= QueryMemory.rescueBoost ? taught : nil
        }
        // Habit, shaped to the scale a Fuzzy score lives on — see
        // Frecency.rankWeight for why this is a logarithm and not the
        // saturating ratio it replaced.
        let frec = Frecency.rankWeight(frecency(for: item))
        let boost = item.baseBoost > 0 ? 0.8 : 0
        return best + frec + boost + taught
    }

    func commit(_ item: PounceItem, action: String) {
        // A quick answer copies to the clipboard — no frecency (it's derived
        // from the query, its rank is fixed) and no client round-trip.
        if item.kind == .answer { commitAnswer(item); return }
        // ⌘⏎ on the update nudge waves it off until the NEXT release, instead
        // of running the updater. The pin is the only thing that takes over a
        // row you didn't ask for, so it owes you a way out — especially for
        // the Nix cohorts, where ⏎ can't clear it by installing.
        if action == "cmd", item.frecencyKey == "cmd:update-pounce",
           UpdateNudge.shared.availableVersion != nil {
            UpdateNudge.shared.dismiss()
            noticeVersion = nil
            noticeItem = nil
            cancel()
            return
        }
        frecency.record(item.frecencyKey)
        // Teach the query that led here. Recorded at the commit, against the
        // row actually taken, which is the only moment either half is known.
        if learnFromQueries {
            let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty { queryMemory.record(query: typed, key: item.frecencyKey) }
        }
        // Light the keycap this commit actually used — which is not always the
        // one you pressed: buildCommit falls back to the plain Return when the
        // row declares nothing for the modifier you held, and the bar has to
        // agree with what happened rather than with what you reached for.
        firedAction = item.action(for: action) != nil ? action : "enter"
        // For a two-step command, seed the loading header with its name + icon so
        // it matches the step-2 header (which arrives with the same -p / -i).
        if item.kind == .command && item.submenu {
            loadingTitle = item.title
            loadingIcon = item.icon ?? "magnifyingglass"
        }
        onCommit?(buildCommit(item, action: action))
    }

    // Copy the answer's plain text. Same auto-paste contract as commitClip /
    // commitEmoji: with clipboard.autoPaste on and the Accessibility grant
    // held, the answer lands straight at the cursor of the previous app.
    private func commitAnswer(_ item: PounceItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.payload, forType: .string)
        var paste = false
        if Settings.load().clipboard.autoPaste {
            if AXIsProcessTrusted() {
                paste = true
            } else {
                AccessibilityHint.promptOnce()
            }
        }
        onCommit?(Commit(clientString: item.payload, disposition: .hideNow,
                         appLaunch: nil, pasteAfter: paste))
    }

    // Return with nothing matching: hand the raw text back, prefixed with which
    // Return it was — the same "<action>\t<payload>" shape a row commit uses, so
    // a caller reads ⌘↵/⌥↵/⌃↵ on typed text exactly the way it already reads them
    // on a row. (It used to hardcode "enter", which made every modifier
    // indistinguishable from a plain Return and left a free-text step with no way
    // to offer a second verb at all.)
    //
    // When the caller has declared this action as chaining (--chain), its next
    // act is another pounce step, which can take a moment — hold the window with
    // the loading skeleton, seeded from this step's own prompt, so there's no
    // fade-out/fade-in gap. An action that ISN'T chained lingers out normally,
    // which is what a caller wants when its next act needs the screen (⌘↵ →
    // `screencapture -i`).
    func commitText(_ text: String, action: String = "enter") {
        firedAction = action
        let chains = chainActions.contains(action)
        if chains {
            loadingTitle = placeholderText
            loadingIcon = globalIcon ?? "magnifyingglass"
        }
        let body = takeDialField().map { "\($0)\t\(text)" } ?? text
        onCommit?(Commit(clientString: "\(action)\t\(body)",
                         disposition: chains ? .loading : .linger, appLaunch: nil))
    }

    // File the current query as a draft, if this invocation asked for one
    // (--draft <key>). Called on every non-commit exit from the query box — Esc,
    // click-away — because that text exists nowhere else and the palette is a
    // surface you can dismiss by accident. See Drafts.swift.
    func stashDraft() {
        guard let key = draftKey else { return }
        Drafts.save(key: key, text: query)
    }

    func cancel() {
        stashDraft()
        onCommit?(Commit(clientString: "", disposition: .hideNow, appLaunch: nil))
    }

    // MARK: Dials

    // ⇥ / ⇧⇥ (and a click on the chip): step the active dial through its
    // options, wrapping both ways. Animated as a state change so the chip's
    // value rolls rather than swaps.
    func cycleDial(_ delta: Int) {
        guard !dials.isEmpty else { return }
        let i = min(activeDial, dials.count - 1)
        var d = dials[i]
        let n = d.options.count
        d.index = ((d.index + delta) % n + n) % n
        withAnimation(Motion.spring) { dials[i] = d }
    }

    // ⌃⇥: move the ⇥ focus to the next dial. Only meaningful on the rare
    // several-dial step; with one dial it's a no-op rather than an error.
    func nextDial() {
        guard dials.count > 1 else { return }
        activeDial = (activeDial + 1) % dials.count
    }

    // A click on a chip focuses that dial and steps it once.
    func tapDial(_ index: Int) {
        guard dials.indices.contains(index) else { return }
        activeDial = index
        cycleDial(1)
    }

    // The committed dial values, injected as an extra SECOND tab field —
    // "<action>\t<name=value;…>\t<payload>" — but ONLY when this invocation
    // declared dials, so a caller that never passed --dial keeps the exact
    // two-field shape published in ai/SKILL.md. Committing is also the moment
    // the values become the memory (DialMemory): Esc and click-away change
    // nothing, which is why this lives here and not in cycleDial.
    private func takeDialField() -> String? {
        guard !dials.isEmpty else { return nil }
        DialMemory.store(dials)
        return Dial.encode(dials)
    }

    private func buildCommit(_ item: PounceItem, action: String) -> Commit {
        switch item.kind {
        case .app:
            return Commit(clientString: "", disposition: .hideNow,
                          appLaunch: (item.payload, action == "cmd"))
        case .command:
            // Two-step commands re-invoke pounce → keep the window up (loading)
            // so step 2 swaps in without a gap. Terminal commands briefly linger.
            return Commit(clientString: "run\t\(item.payload)",
                          disposition: item.submenu ? .loading : .linger, appLaunch: nil)
        case .shortcut:
            // Run natively (see Commit.shortcutRun) and hand the client nothing,
            // exactly like an app launch: `shortcuts run` is spawned and never
            // waited on, so there's nothing to linger for and nothing for a
            // pipe-consuming script to act on.
            return Commit(clientString: "", disposition: .hideNow, appLaunch: nil,
                          shortcutRun: item.payload)
        case .setting:
            // Opened natively (see Commit.settingOpen) and nothing handed to the
            // client: System Settings takes focus, so there's nothing to linger
            // for, exactly like an app launch.
            return Commit(clientString: "", disposition: .hideNow, appLaunch: nil,
                          settingOpen: item.payload)
        case .plain:
            let a = item.action(for: action) != nil ? action : "enter"
            // Same opt-in middle field as commitText: a --dial caller reads its
            // dials back whether the user picked a row or typed free text.
            let body = takeDialField().map { "\($0)\t\(item.raw)" } ?? item.raw
            return Commit(clientString: "\(a)\t\(body)", disposition: .linger, appLaunch: nil)
        case .answer:
            // Unreachable — commit() routes .answer to commitAnswer first.
            return Commit(clientString: item.payload, disposition: .hideNow, appLaunch: nil)
        }
    }
}
