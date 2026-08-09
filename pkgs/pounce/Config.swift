import SwiftUI

// MARK: - Socket Path

enum SocketConfig {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/pounce").path
    static let path = dir + "/pounce.sock"

    // True iff a live daemon owns the socket. A stale socket FILE left by a
    // crashed daemon fails connect() (ECONNREFUSED), so connecting — not the
    // file's existence — is the truth test. Used by the daemon's single-instance
    // guard and the Finder-launch path (LoginItem.swift), both of which need
    // "is pounce already running?" answered without a subprocess.
    static func daemonAlive() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { cstr in
                _ = memcpy(ptr, cstr, min(strlen(cstr) + 1, MemoryLayout.size(ofValue: ptr.pointee)))
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr, { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, addrLen) }
        }) == 0
    }
}

// MARK: - Settings & Layout

// MARK: UI scale

// Every size in pounce's UI is a point value written for scale 1.0 and read back
// through `pt(_:)`. `"scale"` in config.json multiplies them, so the whole window
// — text, rows, icons, and the panels behind the palette — grows as one piece
// rather than one hand-tuned number at a time. This is the seam the nebelhaus
// rice's `ui.scale` reaches when a rice asks for a Mac you can read.
//
// Deliberately NOT a `.scaleEffect` on the hosting view: that rasterises and then
// transforms, and soft text is the one thing a legibility setting must not ship.
// Sizes resolve before layout, so the window is crisp at any scale.
//
// A global, mirroring `Theme.current`, rather than a value threaded through the
// views: both are installed from the same `Settings` on the same path
// (`Settings.apply`), so they cannot disagree, and the leaf views (rows, keycaps,
// the emoji grid) stay free of a metrics parameter they would only pass along.
enum UIScale {
    // Clamped to `range` on load. 1.0 is today's look, unchanged.
    static var factor: CGFloat = 1
    // Below 0.8 the search field's own line height stops shrinking with it and
    // the header lies about its size; above 2.0 the launcher is taller than the
    // room under its top inset even after the row cap kicks in.
    static let range: ClosedRange<CGFloat> = 0.8...2.0
}

// Scale a point value. Rounded, because half-point row heights accumulate into a
// window whose arithmetic height (`ContentView.contentHeight`) disagrees with what
// AppKit lays out — and the exact-height fast path in `PounceUI.resizeToFit`, the
// fix for Tahoe's stale `fittingSize`, depends on those two matching.
func pt(_ base: CGFloat) -> CGFloat { (base * UIScale.factor).rounded() }

// Hold a window width inside the screen. Scale and display mode COMPOUND — a
// large-print Mac turns both up (`haus.ui.scale` and
// `haus.displays.*.uiScale = "larger-text"`), and 820pt at 1.4× is wider than
// the 1147pt-wide desktop that the second one leaves — so the panels have to be
// told where the screen ends. A panel narrower than intended is a compromise; one
// wider than the screen is unusable.
//
// Main thread only (NSScreen is not thread-safe), which is why the launcher clamps
// in `DaemonState.targetWidth` — read while drawing — rather than inside
// `LayoutMetrics.scaled(by:)`, which Entry resolves off-main.
func clampToScreen(_ width: CGFloat) -> CGFloat {
    guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return width }
    return min(width, vf.width - 48)
}

// Scale a window width and clamp it. `pt` + `clampToScreen` in one call.
func ptWidth(_ base: CGFloat) -> CGFloat { clampToScreen(pt(base)) }

// Chrome shared by every pounce window: the rounded panel. The radius is written
// in three places that MUST agree — SwiftUI's clipShape, the vibrancy layer's
// cornerRadius, and the mask image that shapes the window shadow (Window.swift) —
// so it lives here rather than as the same literal three times.
enum PanelChrome {
    static var cornerRadius: CGFloat { pt(16) }
}

// Layout dimensions for a given window mode. The window resizes to `width` and
// the list/header shrink with the other fields, so "compact" reads as a tighter
// launcher. The constants below are the scale-1.0 base; `Settings.metrics` hands
// out `scaled(by:)` copies.
struct LayoutMetrics {
    let width: CGFloat
    let rowHeight: CGFloat
    let maxVisibleItems: Int
    let headerHeight: CGFloat
    let searchIconSize: CGFloat
    let searchFontSize: CGFloat
    let topInsetFraction: CGFloat   // distance from top of screen, as a fraction of height
    // When true, an empty query shows no list until the user types or presses ↓
    // (the compact behaviour). When false, the empty query shows the top-N.
    let hideEmptyList: Bool

    static let standard = LayoutMetrics(
        width: 720, rowHeight: 46, maxVisibleItems: 8, headerHeight: 60,
        searchIconSize: 18, searchFontSize: 20, topInsetFraction: 0.16,
        hideEmptyList: false)

    static let compact = LayoutMetrics(
        width: 600, rowHeight: 42, maxVisibleItems: 6, headerHeight: 52,
        searchIconSize: 16, searchFontSize: 18, topInsetFraction: 0.20,
        hideEmptyList: true)

    // Takes the factor as an argument rather than reading `UIScale.factor`,
    // because `Settings.metrics` is resolved off the main thread (Entry's request
    // handler computes it before hopping to the main queue to draw) while the
    // global is installed on the main thread. The row COUNT is untouched: how many
    // results fit is a question about the screen, answered where the screen is
    // known (`ContentView.maxVisibleItems`).
    func scaled(by factor: CGFloat) -> LayoutMetrics {
        func s(_ v: CGFloat) -> CGFloat { (v * factor).rounded() }
        return LayoutMetrics(
            width: s(width), rowHeight: s(rowHeight), maxVisibleItems: maxVisibleItems,
            headerHeight: s(headerHeight), searchIconSize: s(searchIconSize),
            searchFontSize: s(searchFontSize), topInsetFraction: topInsetFraction,
            hideEmptyList: hideEmptyList)
    }
}

// The panels below carry FIXED geometry — fixed in the sense of "not varying with
// the launcher's windowMode", not "not varying at all": each dimension is a
// scale-1.0 base read through `pt(_:)`, so they grow with `"scale"` like the
// launcher does. They are `static var` for exactly that reason; a `static let`
// would freeze the first read's scale for the life of the process.

// Geometry for the clipboard history's two-pane window.
enum ClipboardLayout {
    static var width: CGFloat { ptWidth(820) }
    static var height: CGFloat { pt(480) }
    static var listWidth: CGFloat { pt(300) }
    static var rowHeight: CGFloat { pt(56) }
}

// Geometry for the emoji grid window. `columns` is a count, not a size: the grid
// keeps its 9 columns and the cells (and so the window) get wider.
enum EmojiLayout {
    static var width: CGFloat { ptWidth(520) }
    static let columns = 9
    static var cellHeight: CGFloat { pt(50) }
    static var gridHeight: CGFloat { pt(320) }
}

// Geometry for the recent-screenshots two-pane window. Mirrors the clipboard
// history layout (list on the left, large preview on the right).
enum ScreenshotLayout {
    static var width: CGFloat { ptWidth(820) }
    static var height: CGFloat { pt(480) }
    static var listWidth: CGFloat { pt(300) }
    static var rowHeight: CGFloat { pt(64) }
}

// Geometry for the camera peek window: a 16:9 live preview with the action bar
// underneath. The preview height is derived from the width so the aspect ratio
// survives scaling and rounding rather than drifting from two rounded constants.
enum CameraLayout {
    static var width: CGFloat { ptWidth(820) }
    static var previewHeight: CGFloat { (width * 461 / 820).rounded() }
    static var barHeight: CGFloat { pt(44) }
    static var height: CGFloat { previewHeight + barHeight }
}

// Geometry for the Find Files window: a launcher-width results list with a fixed
// visible height, so async Spotlight results stream in without the window resizing
// under the user's cursor.
enum FileSearchLayout {
    static var width: CGFloat { ptWidth(720) }
    static var rowHeight: CGFloat { pt(46) }
    static let visibleRows = 8
    static var headerHeight: CGFloat { pt(60) }
    static var listHeight: CGFloat { rowHeight * CGFloat(visibleRows) }
}

// Width for the cheatsheet overlay; height follows the content, capped near the
// screen edge (see CheatsheetView.maxBodyHeight).
enum CheatsheetLayout {
    static var width: CGFloat { ptWidth(1000) }
    static var headerHeight: CGFloat { pt(64) }
}

// User settings, read from ~/.config/pounce/config.json. Parsed leniently via
// JSONSerialization so unknown/extra keys (added by future versions) never break
// an older binary, and any missing/malformed value falls back to a default.
struct ClipboardSettings {
    var enabled: Bool = true
    var maxEntries: Int = 200
    // Copies whose frontmost app matches one of these bundle ids are never
    // recorded (belt-and-suspenders on top of the org.nspasteboard.ConcealedType
    // filter, which already drops password-manager copies).
    var blacklistBundleIds: [String] = ["com.apple.Passwords"]
    // Auto-paste a selected entry into the previously-focused app (synthesize ⌘V)
    // instead of only setting the clipboard. Requires the daemon to hold an
    // Accessibility grant; falls back to clipboard-only when untrusted. Default
    // off so a fresh install never silently needs a TCC permission.
    var autoPaste: Bool = false
}

// Quick-answer engine toggles. Currency is the only engine that touches the
// network (daily ECB reference rates from api.frankfurter.app — pounce's sole
// outbound call, see Currency.swift); set false to keep pounce fully offline.
// The other engines are pure and always on.
struct QuickAnswerSettings {
    var currency: Bool = true
}

// The daily release check (UpdateCheck.swift). `check: false` makes pounce
// fully silent on the network once quickAnswers.currency is off too.
struct UpdateSettings {
    var check: Bool = true
}

// Find Files tuning. A safe, read-only feature (local Spotlight index only, no
// network), so it's on by default. `homeOnly` scopes the search to the user's
// home directory — the sane default for "find my file"; set false to search the
// whole indexed computer. `maxResults` caps how many hits the list shows.
struct FileSearchSettings {
    var enabled: Bool = true
    var homeOnly: Bool = true
    var maxResults: Int = 60
}

// App-launcher tuning. `demoteBundleIds` lists apps that should sink below
// everything at an empty query and rely on frecency (actual use) to climb back —
// the fix for junk like Feedback Assistant squatting the top slot. Defaults to a
// curated set of never-launched Apple utilities (see AppScanner); set to [] to
// disable, or list your own bundle ids (unknown ids are harmless no-ops).
// `hideBundleIds` goes further — those apps are dropped from the list entirely,
// on top of the built-in helper filter (AppScanner.isHelper already hides
// background agents and droplet bridges). Use it for anything else you never
// want to see in the palette at all.
struct AppLauncherSettings {
    var demoteBundleIds: Set<String> = AppScanner.defaultDemotedBundleIds
    var hideBundleIds: [String] = []
}

// The daemon's in-process global hotkey (see HotKeyManager). `key` is a named
// key ("space", "return", "a"…); `modifiers` combine "cmd"/"shift"/"opt"/"ctrl".
// Defaults to ⌘Space. Set `enabled: false` to leave the hotkey to an external
// binder (skhd, AeroSpace, a launch agent spawning pounce-palette).
struct HotKeyConfig {
    var enabled: Bool = true
    var key: String = "space"
    var modifiers: [String] = ["cmd"]
}

// The MRU window switcher (see Switcher.swift): hold `modifiers`, tap `key` to
// walk windows most-recent-first, release to land. Default off — taking over
// ⌘Tab is a bold move that additionally needs the Accessibility grant (the
// event tap won't install without it), so it's strictly opt-in here; opinionated
// setups (the nebelhaus rice) turn it on in the config they ship. Read once at
// daemon start: toggling requires a daemon restart, unlike the palette settings.
struct WindowSwitcherSettings {
    var enabled: Bool = false
    var key: String = "tab"
    var modifiers: [String] = ["cmd"]
}

struct Settings {
    enum WindowMode: String { case standard = "default", compact }

    var windowMode: WindowMode = .standard
    // Multiplies every size in the UI (see `UIScale`). `windowMode` picks the
    // launcher's proportions — how tight it reads; `scale` picks how big the whole
    // thing is drawn, panels included. They compose: a compact launcher at 1.4 is
    // still the compact layout, just legible from further away.
    var scale: CGFloat = 1
    var clipboard = ClipboardSettings()
    var appLauncher = AppLauncherSettings()
    var hotkey = HotKeyConfig()
    var windows = WindowSwitcherSettings()
    var quickAnswers = QuickAnswerSettings()
    // Daily latest-release check that nudges (palette row + one notification)
    // but never applies — see UpdateCheck.swift. Default on; independently
    // self-disabled on Nix-managed installs, whose updates ride the flake.
    var updates = UpdateSettings()
    var fileSearch = FileSearchSettings()
    // Per-item overrides (enable / alias / hotkey), keyed by stable item key.
    // See ItemSettings.swift. Empty by default: an untouched config behaves
    // exactly as it did before this key existed.
    var items = ItemSettings()
    // Color palette: a built-in name, or a ~/.config/pounce/themes/<name>.json
    // (see Palette.named).
    //
    // `theme` is the fallback for BOTH appearances; `themeLight`/`themeDark`
    // override it when macOS is in that appearance. Three consequences, all
    // intended:
    //
    //   nothing set          nebelung / nebelung-latte — the default pair, so a
    //                        zero-config pounce follows macOS light/dark.
    //   only `theme`         that palette, always. Setting one theme PINS it —
    //                        "theme": "gruvbox-dark" must not go latte at noon.
    //   a pair               "theme": "gruvbox" + "themeDark": "gruvbox-dark",
    //                        or "theme": "nebelung" + "themeLight": "…-latte".
    //
    // nil rather than a default string is what makes "only theme pins" work:
    // the resolver can't otherwise tell a chosen "nebelung" from an unset one.
    var theme: String?
    var themeLight: String?
    var themeDark: String?

    var metrics: LayoutMetrics {
        switch windowMode {
        case .standard: return LayoutMetrics.standard.scaled(by: scale)
        case .compact: return LayoutMetrics.compact.scaled(by: scale)
        }
    }

    // Install the parts of the settings that the views read from globals rather
    // than from `DaemonState`: the palette and the UI scale. Both are re-read per
    // open, so a config edit shows on the next summon without restarting the
    // daemon — and doing them together is what keeps `UIScale.factor` from ever
    // lagging a `state.metrics` that was resolved from the same `Settings`.
    // Main thread: `UIScale.factor` is read during layout.
    func apply() {
        Theme.current = palette
        UIScale.factor = scale
    }

    // Resolved per open (like the rest of Settings), so toggling macOS
    // appearance shows on the next summon without restarting the daemon.
    var themeName: String {
        Theme.systemIsLight
            ? (themeLight ?? theme ?? Palette.defaultLightName)
            : (themeDark ?? theme ?? Palette.defaultDarkName)
    }

    var palette: Palette { Palette.named(themeName) }

    static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pounce/config.json")
    }

    // Cheap enough (tiny file) to re-read per invocation, so edits take effect
    // on the next open without restarting the daemon.
    //
    // `.json5Allowed` is what lets `pounce config init` write a config with every
    // setting documented above it and commented out: JSON5 permits `//` and
    // `/* */` comments AND trailing commas, so the file you READ is the file
    // pounce reads, rather than a reference document you copy lines out of.
    //
    // The trailing commas matter as much as the comments here. Every commented
    // line in the generated config carries its own comma, so uncommenting any
    // SUBSET of lines needs no punctuation fixups — the last one before a `}` is
    // then an orphan, which strict JSON rejects.
    //
    // Foundation's own flag rather than a hand-rolled stripper (which this had,
    // briefly): the lexing is genuinely fiddly — `"https://example.com"` must not
    // lose its tail to a "comment" — and Apple has already written it, for every
    // macOS this app supports (12+; pounce needs 14).
    //
    // JSON5 is a superset, so it accepts a few things we never generate
    // (unquoted keys, single quotes, hex). For a config file read leniently on
    // purpose, more forgiving is the right direction, and a plain-JSON config
    // written before any of this parses exactly as it always did.
    static func load() -> Settings {
        var s = Settings()
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
                as? [String: Any]
        else { return s }
        if let wm = obj["windowMode"] as? String, let mode = WindowMode(rawValue: wm) {
            s.windowMode = mode
        }
        // Clamped rather than rejected: a config asking for 3.0 wants the biggest
        // palette pounce can draw, and handing it back 1.0 — the smallest — is the
        // opposite of what it asked for.
        if let sc = obj["scale"] as? Double {
            s.scale = min(max(CGFloat(sc), UIScale.range.lowerBound), UIScale.range.upperBound)
        }
        if let t = obj["theme"] as? String { s.theme = t }
        if let t = obj["themeLight"] as? String { s.themeLight = t }
        if let t = obj["themeDark"] as? String { s.themeDark = t }
        if let cb = obj["clipboard"] as? [String: Any] {
            if let e = cb["enabled"] as? Bool { s.clipboard.enabled = e }
            if let m = cb["maxEntries"] as? Int { s.clipboard.maxEntries = m }
            if let bl = cb["blacklistBundleIds"] as? [String] { s.clipboard.blacklistBundleIds = bl }
            if let ap = cb["autoPaste"] as? Bool { s.clipboard.autoPaste = ap }
        }
        if let qa = obj["quickAnswers"] as? [String: Any] {
            if let c = qa["currency"] as? Bool { s.quickAnswers.currency = c }
        }
        if let up = obj["updates"] as? [String: Any] {
            if let c = up["check"] as? Bool { s.updates.check = c }
        }
        if let fs = obj["fileSearch"] as? [String: Any] {
            if let e = fs["enabled"] as? Bool { s.fileSearch.enabled = e }
            if let h = fs["homeOnly"] as? Bool { s.fileSearch.homeOnly = h }
            if let m = fs["maxResults"] as? Int { s.fileSearch.maxResults = m }
        }
        if let ap = obj["apps"] as? [String: Any] {
            if let d = ap["demoteBundleIds"] as? [String] { s.appLauncher.demoteBundleIds = Set(d) }
            if let h = ap["hideBundleIds"] as? [String] { s.appLauncher.hideBundleIds = h }
        }
        if let hk = obj["hotkey"] as? [String: Any] {
            if let e = hk["enabled"] as? Bool { s.hotkey.enabled = e }
            if let k = hk["key"] as? String, !k.isEmpty { s.hotkey.key = k }
            if let m = hk["modifiers"] as? [String] { s.hotkey.modifiers = m }
        }
        if let w = obj["windows"] as? [String: Any] {
            if let e = w["enabled"] as? Bool { s.windows.enabled = e }
            if let k = w["key"] as? String, !k.isEmpty { s.windows.key = k }
            if let m = w["modifiers"] as? [String], !m.isEmpty { s.windows.modifiers = m }
        }
        s.items = ItemSettings.parse(obj["items"])
        return s
    }
}
