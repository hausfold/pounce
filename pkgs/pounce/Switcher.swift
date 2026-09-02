import AppKit
import Carbon
import SwiftUI

// MARK: - Window Switcher (⌘Tab quasimode)

// The MRU window switcher: hold the modifier, tap the trigger key to walk
// windows most-recent-first, release to land. A single tap-and-release toggles
// to the LAST window — the gesture that makes it a real ⌘Tab replacement.
// Typing while holding filters (fuzzy + frecency). ⇧ walks backwards, ⎋
// cancels, ↵ commits without releasing.
//
// ⌘Tab is not a symbolic hotkey macOS lets you rebind — the Dock owns it. The
// only way in is a session CGEventTap that swallows the keyDown before the Dock
// sees it, and keyboard taps are gated behind the Accessibility grant (the same
// one haus's stable-signing dance preserves across rebuilds). No grant → no
// tap → stock ⌘Tab keeps working; the daemon just logs and moves on.
//
// The tap callback runs on the main run loop and must return fast — macOS
// disables taps that stall (~1s). Everything here is O(cached list); the AX
// walking and the `aerospace` subprocess both live in WindowTracker, off this
// path, and this side only ever reads their cached results. During Secure Input
// (password fields) keyboard taps go deaf and events flow to the stock switcher
// — an acceptable, self-healing fallback.
final class WindowSwitcher {
    // Injected rather than owned: auto-quit (AutoQuit.swift) reads the same AX
    // snapshot, and a second tracker would mean a second AXObserver on every
    // running app. DaemonMode holds the one instance and hands it to whoever
    // needs it.
    private let tracker: WindowTracker
    // Separate store from the launcher's frecency.json: two live Frecency
    // instances on one file would clobber each other's writes.
    private let frecency = Frecency(filename: "window-frecency.json")
    private let state = SwitcherState()
    private lazy var panel: QuasimodePanel<SwitcherView> = {
        let panel = QuasimodePanel(rootView: SwitcherView(state: state))
        state.onResize = { [weak panel] in panel?.refitIfVisible() }
        return panel
    }()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let triggerKey: CGKeyCode
    private let requiredFlags: CGEventFlags
    private static let relevantFlags: CGEventFlags =
        [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    // Quasimode session. `sessionWindows` is frozen at activation — a snapshot
    // refresh mid-cycle would shuffle rows under the user's selection.
    private var active = false
    private var sessionWindows: [WindowInfo] = []
    private var hudShown = false
    private var hudTimer: DispatchWorkItem?
    // A quick tap-release toggle shouldn't flash a window; the HUD appears
    // only if the modifier is still held after this delay (or on any explicit
    // cycle/typing, immediately). Tuned to sit above a deliberate back-and-forth
    // round trip — at 0.1s an ordinary bounce between two windows outran it and
    // strobed the panel for a few frames on the way past. Raising it costs
    // nothing when you DO want the list: walking with ⇥ shows it instantly.
    private static let hudDelay: TimeInterval = 0.25

    init?(settings: WindowSwitcherSettings, tracker: WindowTracker) {
        guard let code = HotKeyParser.keyCode(for: settings.key) else {
            NSLog("pounce switcher: unknown key '\(settings.key)'")
            return nil
        }
        self.tracker = tracker
        triggerKey = CGKeyCode(code)
        requiredFlags = Self.eventFlags(for: settings.modifiers)
        // Release-to-commit needs a modifier to release; a bare key would also
        // swallow ordinary typing.
        guard !requiredFlags.isEmpty else {
            NSLog("pounce switcher: refusing to bind without a modifier")
            return nil
        }

        state.onSelect = { [weak self] index in
            guard let self, self.active else { return }
            self.state.selection = index
            self.commit()
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<WindowSwitcher>.fromOpaque(refcon).takeUnretainedValue()
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-arm and bail out of any half-open session — better a cancelled
            // switch than a dead ⌘Tab until the daemon restarts.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelSession()
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            // Never swallow modifier transitions — the rest of the system
            // tracks them too. Releasing the required modifiers commits.
            if active, !event.flags.contains(requiredFlags) { commit() }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let held = event.flags.intersection(Self.relevantFlags)

            if !active {
                // ⇧ on top of the chord starts the walk backwards.
                guard code == triggerKey,
                      held == requiredFlags || held == requiredFlags.union(.maskShift),
                      begin(reverse: held.contains(.maskShift))
                else { return Unmanaged.passUnretained(event) }
                return nil
            }
            handleActiveKey(code: code, event: event)
            return nil   // the quasimode owns the keyboard while it's up

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleActiveKey(code: CGKeyCode, event: CGEvent) {
        if code == triggerKey {
            cycle(event.flags.contains(.maskShift) ? -1 : +1)
            return
        }
        switch Int(code) {
        case kVK_Escape:     cancelSession()
        case kVK_Return:     commit()
        case kVK_DownArrow:  cycle(+1)
        case kVK_UpArrow:    cycle(-1)
        case kVK_Delete:
            if !state.query.isEmpty { state.query.removeLast(); refilter() }
        default:
            if let ch = Self.typedCharacter(event) {
                state.query.append(ch)
                refilter()
                showHUDNow()
            }
        }
    }

    // MARK: Session

    // False when there's nothing to switch between — the trigger passes through
    // to the stock switcher rather than dying on a swallowed key.
    private func begin(reverse: Bool) -> Bool {
        // Pin row 0 to the truly-active window before snapshotting, so a rapid
        // second trigger doesn't race the async focus/refresh from the last one.
        tracker.stampFrontmost()
        let windows = tracker.orderedWindows()
        guard !windows.isEmpty else { return false }

        active = true
        sessionWindows = windows
        state.query = ""
        // Read synchronously and frozen for the session: the grouping and the
        // row badges must agree with the order `windows` already came in, and a
        // map arriving mid-cycle would relabel rows under the selection.
        state.workspaces = tracker.workspaceMap
        state.visible = windows
        state.selection = defaultSelection(windows, reverse: reverse)

        tracker.refreshSoon()   // freshen the snapshot for the NEXT activation

        let show = DispatchWorkItem { [weak self] in self?.showHUD() }
        hudTimer = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudDelay, execute: show)
        return true
    }

    // Where a tap-and-release lands. "The window before this one" is the whole
    // point of MRU — but when two windows are tiled side by side, the one before
    // this one is right there on screen, so landing on it isn't a switch at all;
    // it's the focus nudge windowNav's ⌥hjkl exists for. Under a tiling WM the
    // default therefore looks past the current workspace entirely and takes the
    // most recent window on a DIFFERENT one.
    //
    // Deliberately "different workspace" rather than "not currently visible":
    // same-workspace-but-off-screen is the ambiguous middle (a ⌘H-hidden app, a
    // window on its own native Space) where landing there fires a Space-switch
    // animation instead of a switch. Requiring the candidate's workspace to be
    // *known and different* keeps the default on windows AeroSpace can actually
    // reach with `focus --window-id`.
    //
    // A workspace *family* is the unit, not the workspace name: `T`, `T/haus`
    // and `T/main` are pages of one place (see `family(of:)`), and the page
    // chord is what moves between them. A bare tap looks past all of them.
    //
    // Nothing is removed from the list: the skipped siblings are still rows
    // 1..n, still reachable with ⇧⇥ or by keeping ⇥ held down.
    private func defaultSelection(_ windows: [WindowInfo], reverse: Bool) -> Int {
        guard windows.count > 1 else { return 0 }
        if reverse { return windows.count - 1 }
        // Plain MRU, but still preferring not to un-minimize on a bare tap.
        // Reached when there's no tiling to reason about at all, when one
        // workspace holds everything, and when the map hasn't placed a
        // candidate — walking with ⇥ reaches minimized windows either way, so
        // only an all-minimized list makes one the default.
        func mru() -> Int { windows.dropFirst().firstIndex { !$0.isMinimized } ?? 1 }

        // No AeroSpace, or it hasn't placed the window we're standing on (the
        // map is briefly empty at daemon start) → the unmodified rule.
        guard let here = tracker.workspace(of: windows[0]) else { return mru() }

        let hereFamily = Self.family(of: here)
        let elsewhere = windows.dropFirst().firstIndex {
            guard !$0.isMinimized, let ws = tracker.workspace(of: $0) else { return false }
            return Self.family(of: ws) != hereFamily
        }
        return elsewhere ?? mru()
    }

    // The workspace family a name belongs to: everything before the first `/`.
    //
    // AeroSpace workspace names are flat strings, but a `/` in one is the
    // settled convention for a *page* — a sub-workspace of the base name, the
    // ring the page switcher walks (AppScoped.swift). Pages of one base are one
    // place: you get between them with the page chord, so a bare ⌘⇥ tap that
    // lands on the page you just walked away from is the same non-switch as
    // landing on a tiled sibling, and for the same reason.
    //
    // Deliberately not keyed on `pages.prefix`: that setting says which family
    // the page chord walks, and ⌘⇥'s default must not change shape depending
    // on whether an unrelated chord is configured. A name with no `/` is its
    // own family, which is every workspace on a Mac that has no pages at all —
    // there the comparison is the plain name equality it has always been.
    private static func family(of workspace: String) -> Substring {
        workspace.prefix { $0 != "/" }
    }

    private func cycle(_ delta: Int) {
        guard active, !state.visible.isEmpty else { return }
        state.selection = (state.selection + delta + state.visible.count) % state.visible.count
        showHUDNow()   // explicitly walking means the user wants to see the list
    }

    private func refilter() {
        let q = state.query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            state.visible = sessionWindows
        } else {
            let chars = Array(q.lowercased())
            state.visible = sessionWindows
                .compactMap { w -> (WindowInfo, Double)? in
                    guard let s = Fuzzy.score(chars, w.searchText) else { return nil }
                    let f = frecency.score(for: w.frecencyKey)
                    return (w, s + Frecency.rankWeight(f))   // same shaping as the launcher
                }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 }
        }
        state.selection = 0
    }

    private func showHUDNow() {
        hudTimer?.cancel()
        hudTimer = nil
        showHUD()
    }

    private func showHUD() {
        guard active, !hudShown else { return }
        hudShown = true
        Settings.load().apply()   // config + scale edits apply on next show
        panel.show()
        // No workspace fetch here any more: the map is cached on the tracker and
        // was read at activation, so the headers are correct on the first frame
        // instead of popping in a subprocess later.
    }

    private func commit() {
        guard active else { return }
        let target = state.visible.indices.contains(state.selection)
            ? state.visible[state.selection] : nil
        endSession()
        if let target {
            frecency.record(target.frecencyKey)
            tracker.focus(target)
        }
    }

    private func cancelSession() {
        guard active else { return }
        endSession()
    }

    private func endSession() {
        active = false
        hudShown = false
        hudTimer?.cancel()
        hudTimer = nil
        sessionWindows = []
        panel.hide()
    }

    // MARK: Parsing

    // CG-flavored sibling of HotKeyParser.modifierMask (that one speaks Carbon;
    // the tap compares CGEventFlags).
    static func eventFlags(for names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command", "super", "meta": flags.insert(.maskCommand)
            case "shift":                           flags.insert(.maskShift)
            case "opt", "option", "alt":            flags.insert(.maskAlternate)
            case "ctrl", "control":                 flags.insert(.maskControl)
            default: break
            }
        }
        return flags
    }

    // The character a keyDown would type, for the filter query. Control keys
    // (and anything unprintable) return nil and fall through untyped.
    private static func typedCharacter(_ event: CGEvent) -> Character? {
        var length = 0
        var buf = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length,
                                       unicodeString: &buf)
        guard length > 0 else { return nil }
        let s = String(utf16CodeUnits: buf, count: length)
        guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let ch = s.first else { return nil }
        return ch
    }
}
