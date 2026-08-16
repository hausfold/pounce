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
//               most-recent-first (⇧ walks backwards), release to stay. Unlike
//               ⌘Tab there is no HUD: every step FOCUSES the workspace live, so
//               the feedback is the screen itself — the same feel as the zellij
//               tab walk this replaces on haus's zmx lane machines.
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

    // The walk session. Candidates are frozen at the first tap — the MRU file
    // moves underneath us as the walk itself focuses workspaces (the hook
    // pushes every visit), and re-reading mid-walk would shuffle the ring.
    private var walking = false
    private var walkPages: [String] = []
    private var walkIndex = 0

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
            walking = false
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Modifier transitions are never swallowed. Dropping the walk
            // modifier ends the walk — nothing to commit, the last step already
            // focused where we are; the MRU file's own hook records it.
            if walking, !event.flags.contains(pageFlags) { walking = false; walkPages = [] }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let held = event.flags.intersection(Self.relevantFlags)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

            // The walk key: exact chord, or the chord + ⇧ for backwards.
            if let pageKey, code == pageKey {
                let backFlags = pageFlags.union(.maskShift)
                let chordHeld = (held == pageFlags) || (held == backFlags)
                let inScope = pages.bundleId == nil || pages.bundleId == front
                if chordHeld && inScope {
                    if step(back: held.contains(.maskShift)) { return nil }
                    return Unmanaged.passUnretained(event)   // no pages → falls through
                }
            }

            if !walking, let hit = scoped.first(where: { entry in
                entry.keyCode == code && entry.flags == held && entry.bundleId == front
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
    private func step(back: Bool) -> Bool {
        if !walking {
            let live = Set((tracker?.workspaceMap ?? [:]).values).filter {
                $0 == pages.prefix || $0.hasPrefix(pages.prefix + "/")
            }
            guard !live.isEmpty else { return false }

            var ordered: [String] = []
            var current: String?
            if let file = pages.mruFile,
               let text = try? String(contentsOfFile: file, encoding: .utf8) {
                let lines = text.split(separator: "\n").map(String.init)
                current = lines.first
                ordered = lines.filter { live.contains($0) }
            }
            // Pages the file hasn't seen yet (fresh lane, wiped state) still
            // deserve to be reachable; they queue behind the known ones.
            ordered += live.subtracting(Set(ordered)).sorted()

            walkPages = ordered
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
        } else {
            guard !walkPages.isEmpty else { return true }
            let delta = back ? -1 : 1
            walkIndex = (walkIndex + delta + walkPages.count) % walkPages.count
        }
        if walkPages.indices.contains(walkIndex) {
            Aerospace.focusWorkspace(walkPages[walkIndex])
        }
        return true
    }
}
