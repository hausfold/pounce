import AppKit
import Carbon

// MARK: - App-scoped keys (scoped hotkeys + the workspace-page walk)

// Two features, one session event tap, because they are the same trick: a chord
// that belongs to an APP rather than to the machine. A Carbon hotkey
// (HotKey.swift) can only swallow a chord globally — ⌘P everywhere, or ⌘P
// nowhere — so scoping needs the same consuming CGEventTap the ⌘Tab switcher
// runs (Switcher.swift), deciding per keystroke: frontmost app matches → act
// and swallow; anything else → pass the event through untouched and the chord
// keeps meaning whatever it always meant there (⌘P prints, ⌃⇥ walks browser
// tabs).
//
//   appHotkeys  one-shot chords firing an ItemTarget through the same runTarget
//               closure a Carbon binding fires — one dispatch grammar.
//   pages       a quasimode like the window switcher's: hold the modifier, tap
//               the key to walk the non-empty `prefix`/* AeroSpace workspaces
//               most-recent-first (⇧ walks backwards), release to land. Its
//               HUD (PageSwitcherView.swift) is the ⌘Tab list one level up —
//               a row per PAGE, with the windows on it underneath, so a page is
//               chosen by recognising what is on it rather than by remembering
//               its name.
//
//               The walk used to focus each workspace as it stepped, with no
//               HUD: the screen itself was the feedback. With a list to read,
//               travelling is worse than useless — it strobes every page you
//               pass through, and each visit is one the WM's own hook pushes
//               onto the MRU file, so a three-step walk left the corridor
//               ranked above where you came from (the classic alt-tab
//               degeneration) and needed the file repaired on release. Landing
//               only on the release makes both problems not exist.
//
// Recency for the walk comes from an MRU file the WM's own workspace-change
// hook maintains (most recent first, one name per line). pounce deliberately
// only reads it: the hook hears about every change — chords, mouse, `aerospace
// workspace` from a script — where anything pounce tracked itself would only
// see the changes pounce caused. Emptiness comes from the WindowTracker's
// cached workspace map, never from a subprocess: the tap callback must return
// in well under a second or macOS disables the tap.
//
// Same constraints as Switcher.swift throughout: the callback runs on the main
// run loop, taps go deaf during Secure Input (events then flow to the apps
// unmodified — a self-healing fallback), and installation needs Accessibility,
// so DaemonMode arms and disarms this from the same grant watcher.
final class AppScopedKeys {
    private struct ScopedKey {
        let bundleId: String
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let target: String
    }

    // nil when only scoped hotkeys are configured — the walk is the only reader,
    // and a tracker nobody reads is an AXObserver per app for nothing.
    private let tracker: WindowTracker?
    private let runTarget: (String) -> Void
    private let pages: PageSwitcherSettings

    private var scoped: [ScopedKey] = []
    private var pageKey: CGKeyCode?
    private var pageFlags: CGEventFlags = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // The walk session. Candidates are frozen at the first tap: re-reading the
    // MRU file mid-walk would shuffle the ring under the selection, and the
    // window snapshot behind the rows must agree with the order they came in.
    private var walking = false
    private var walkPages: [String] = []
    private var walkIndex = 0
    // The page the walk began on — the MRU file's head, when that page is one
    // of the candidates. Marked in the HUD, and the release skips focusing it
    // (landing where you already are is a subprocess for nothing).
    private var walkOrigin: String?

    // The HUD. Built lazily: a machine with only scoped hotkeys configured
    // never walks, and an NSPanel it never shows is an NSPanel it shouldn't
    // build.
    private let state = PageSwitcherState()
    private lazy var panel: QuasimodePanel<PageSwitcherView> = {
        let panel = QuasimodePanel(rootView: PageSwitcherView(state: state))
        state.onResize = { [weak panel] in panel?.refitIfVisible() }
        state.onSelect = { [weak self] index in
            guard let self, self.walking, self.walkPages.indices.contains(index) else { return }
            self.walkIndex = index
            self.state.selection = index
            self.endWalk()
        }
        return panel
    }()
    private var hudShown = false
    private var hudTimer: DispatchWorkItem?
    // Same reasoning (and same value) as the window switcher's: a tap-and-
    // release toggle between two pages shouldn't flash a list on the way past,
    // but any explicit second step shows it immediately.
    private static let hudDelay: TimeInterval = 0.25

    init?(settings: AppHotkeysSettings, pages: PageSwitcherSettings,
          tracker: WindowTracker?, runTarget: @escaping (String) -> Void) {
        self.tracker = tracker
        self.runTarget = runTarget
        self.pages = pages

        if settings.enabled {
            scoped = settings.scopes.flatMap { scope in
                scope.keys.compactMap { entry in
                    guard let code = HotKeyParser.keyCode(for: entry.key) else {
                        NSLog("pounce appHotkeys: unknown key '\(entry.key)' for \(scope.bundleId); skipped")
                        return nil
                    }
                    let flags = WindowSwitcher.eventFlags(for: entry.modifiers)
                    guard !flags.isEmpty else {
                        // A bare scoped key would also swallow ordinary typing
                        // in the scoped app — same refusal as the switcher's.
                        NSLog("pounce appHotkeys: refusing '\(entry.key)' for \(scope.bundleId) without a modifier")
                        return nil
                    }
                    return ScopedKey(bundleId: scope.bundleId, keyCode: CGKeyCode(code),
                                     flags: flags, target: entry.target)
                }
            }
        }
        if pages.enabled {
            if let code = HotKeyParser.keyCode(for: pages.key) {
                let flags = WindowSwitcher.eventFlags(for: pages.modifiers)
                if flags.isEmpty {
                    NSLog("pounce pages: refusing to walk without a modifier")
                } else if flags.contains(.maskShift) {
                    // ⇧ is the walk's own reverse gear — a chord that includes
                    // it would make backwards the only direction.
                    NSLog("pounce pages: refusing shift in pages.modifiers — shift reverses the walk")
                } else {
                    pageKey = CGKeyCode(code)
                    pageFlags = flags
                }
            } else {
                NSLog("pounce pages: unknown key '\(pages.key)'")
            }
        }
        guard !scoped.isEmpty || pageKey != nil else { return nil }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<AppScopedKeys>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }

    // MARK: Event tap

    private static let relevantFlags: CGEventFlags =
        [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelWalk()
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Modifier transitions are never swallowed. Dropping the walk
            // modifier ends the walk.
            if walking, !event.flags.contains(pageFlags) { endWalk() }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let held = event.flags.intersection(Self.relevantFlags)
            // Frontmost is a LaunchServices lookup — resolved lazily, only once
            // a keycode+flags candidate matches, so ordinary machine-wide
            // typing never pays for it.
            var frontCache: String??
            func front() -> String? {
                if let cached = frontCache { return cached }
                let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                frontCache = .some(now)
                return now
            }

            // The walk key: exact chord, or the chord + ⇧ for backwards. The
            // scope check gates the FIRST step only — once a walk is up it owns
            // the chord until the release, whatever happens to be frontmost.
            // (It cannot change any more now that stepping doesn't focus, but a
            // walk handing its own key back mid-gesture would wedge it, so the
            // guard stays.)
            if let pageKey, code == pageKey {
                let backFlags = pageFlags.union(.maskShift)
                let chordHeld = (held == pageFlags) || (held == backFlags)
                let inScope = walking || pages.bundleId == nil || pages.bundleId == front()
                if chordHeld && inScope {
                    if step(back: held.contains(.maskShift)) { return nil }
                    return Unmanaged.passUnretained(event)   // no pages → falls through
                }
            }

            // While the list is up the quasimode owns these two, the same
            // pair the window switcher's does: ⎋ abandons the walk (nothing is
            // focused, the MRU file is untouched), ↵ lands on the selection
            // without waiting for the modifier to come up.
            if walking {
                switch Int(code) {
                case kVK_Escape: cancelWalk(); return nil
                case kVK_Return: endWalk();    return nil
                default: break
                }
            }

            // One-shot chords must not machine-gun on key autorepeat — holding
            // ⌘P should spawn one shell, not fifteen a second. (The walk key
            // above deliberately keeps repeats: holding ⌃⇥ keeps walking, the
            // same feel as ⌘Tab.)
            if !walking,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
               let hit = scoped.first(where: { entry in
                   entry.keyCode == code && entry.flags == held && entry.bundleId == front()
               }) {
                // Off the tap path: runTarget may refresh the command registry
                // (stats a directory) before spawning, and the callback must
                // return now.
                let target = hit.target
                let fire = runTarget
                DispatchQueue.main.async { fire(target) }
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: The walk

    // One step of the walk; the first step also builds the session. False when
    // there is nothing to walk (no live pages) — the caller then passes the
    // chord through, so on a machine with no lanes ⌃⇥ keeps its old meaning all
    // the way down (Ghostty forwards it to zellij's tab history).
    //
    // Stepping only ever moves the SELECTION. The focus happens once, on the
    // release (endWalk) — see the note at the top of the file.
    private func step(back: Bool) -> Bool {
        if !walking {
            let map = tracker?.workspaceMap ?? [:]
            let live = Set(map.values).filter {
                $0 == pages.prefix || $0.hasPrefix(pages.prefix + "/")
            }
            guard !live.isEmpty else { return false }

            var ordered: [String] = []
            var current: String?
            if let file = pages.mruFile, let handle = FileHandle(forReadingAtPath: file) {
                // Head only, hard-capped: this read is on the tap path, and a
                // tap that stalls ~1s is killed by macOS. The hook keeps the
                // file to ~50 short lines; the cap is for the day the path
                // points somewhere it shouldn't.
                let data = (try? handle.read(upToCount: 8192)) ?? nil
                try? handle.close()
                if let data, let text = String(data: data, encoding: .utf8) {
                    let lines = text.split(separator: "\n").map(String.init)
                    current = lines.first
                    // Dedup keeping the FIRST (most recent) occurrence — a
                    // hook that appends rather than rewrites must not make the
                    // ring visit a page twice per cycle.
                    var seen = Set<String>()
                    ordered = lines.filter { live.contains($0) && seen.insert($0).inserted }
                }
            }
            // Pages the file hasn't seen yet (fresh lane, wiped state) still
            // deserve to be reachable; they queue behind the known ones.
            ordered += live.subtracting(Set(ordered)).sorted()

            walkPages = ordered
            walkOrigin = current.flatMap { ordered.contains($0) ? $0 : nil }
            // The most recent page is usually the one we're standing on (the
            // hook pushed it when we landed here); start one past it. When the
            // walk begins somewhere else — a float on a numbered workspace —
            // the most recent page IS the right first stop.
            let onIt = ordered.first == current
            // Forward starts one past the page we're standing on (the hook
            // pushed it when we landed, so it heads the list); backwards wraps
            // straight to the least recent. When the walk begins somewhere that
            // isn't a page — a float on a numbered workspace — the most recent
            // page IS the right first stop.
            walkIndex = back ? ordered.count - 1 : (onIt && ordered.count > 1 ? 1 : 0)
            walking = true

            // Read synchronously and frozen for the session, for the same
            // reason the ⌘⇥ switcher freezes its snapshot: rows arriving
            // mid-walk would re-describe pages under the selection. Both reads
            // are against WindowTracker's cache — no subprocess on this path.
            state.groups = Self.groups(ordered, windows: tracker?.orderedWindows() ?? [], map: map)
            state.origin = walkOrigin
            state.selection = walkIndex

            let show = DispatchWorkItem { [weak self] in self?.showHUD() }
            hudTimer = show
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudDelay, execute: show)
        } else {
            guard !walkPages.isEmpty else { return true }
            let delta = back ? -1 : 1
            walkIndex = (walkIndex + delta + walkPages.count) % walkPages.count
            state.selection = walkIndex
            showHUDNow()   // explicitly walking means the user wants to see the list
        }
        return true
    }

    // The HUD's rows: one per candidate page, in ring order, each carrying the
    // windows AeroSpace has placed on it. Window order comes from the tracker
    // (window MRU), so the top line of a page is the window you last used there.
    private static func groups(_ pages: [String], windows: [WindowInfo],
                               map: [CGWindowID: String]) -> [PageGroup] {
        var byPage: [String: [WindowInfo]] = [:]
        for w in windows {
            guard let ws = map[w.id], pages.contains(ws) else { continue }
            byPage[ws, default: []].append(w)
        }
        return pages.map { PageGroup(name: $0, windows: byPage[$0] ?? []) }
    }

    // MARK: The HUD

    private func showHUDNow() {
        hudTimer?.cancel()
        hudTimer = nil
        showHUD()
    }

    private func showHUD() {
        guard walking, !hudShown else { return }
        hudShown = true
        Settings.load().apply()   // config + scale edits apply on next show
        panel.show()
    }

    private func hideHUD() {
        hudTimer?.cancel()
        hudTimer = nil
        guard hudShown else { return }
        hudShown = false
        panel.hide()
    }

    // ⎋, or the tap being pulled out from under us: leave focus exactly where
    // the walk started. Nothing to undo — the walk never moved it.
    private func cancelWalk() {
        guard walking else { return }
        walking = false
        walkPages = []
        walkOrigin = nil
        hideHUD()
    }

    // Release (or ↵). The one focus of the whole gesture.
    private func endWalk() {
        let landed = walkPages.indices.contains(walkIndex) ? walkPages[walkIndex] : nil
        let origin = walkOrigin
        walking = false
        walkPages = []
        walkOrigin = nil
        hideHUD()
        guard let landed, landed != origin else { return }
        Aerospace.focusWorkspace(landed)   // async under the hood; safe from the tap
    }
}
