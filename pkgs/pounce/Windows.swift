import AppKit
import ApplicationServices

// MARK: - Private AX bridge

// The one private call this feature leans on: map an AXUIElement window to its
// CGWindowID. There is no public equivalent, and the ID is what lets us (a) key
// the MRU table on something stable-per-window and (b) hand the exact window to
// `aerospace focus --window-id`. Ubiquitous in this app category (AltTab, yabai,
// AeroSpace itself); if it ever vanishes the switcher degrades to nothing worse
// than a failed lookup (id 0 → window skipped).
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - WindowInfo

// One switchable window, snapshotted from the AX tree. The axElement stays
// valid for the window's lifetime, so raising/unminimizing later needs no
// re-walk.
struct WindowInfo: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let bundleId: String?
    let appPath: String?      // bundle path, for the row icon
    let title: String         // window title; falls back to the app name
    let isMinimized: Bool
    let axElement: AXUIElement

    // Frecency is deliberately app-level: window titles are too volatile to
    // accumulate history against (editors/browsers retitle constantly), so
    // "which app's windows do I reach for" is the signal that survives.
    // Within an app, MRU order breaks the tie.
    var frecencyKey: String { "win:\(bundleId ?? appName)" }
    var searchText: String { "\(appName) \(title)".lowercased() }
}

// MARK: - WindowTracker

// The daemon-resident half of the window switcher: keeps a cached AX snapshot
// of every standard window plus a last-focused timestamp per CGWindowID, so a
// ⌘Tab press only has to SORT (never enumerate — a hung app's AX replies can
// stall for seconds, and the event-tap callback must return instantly).
//
// MRU stamps come from focus events (NSWorkspace app activation + a per-app
// AXObserver for within-app window switches). The snapshot refreshes lazily —
// coalesced, off the main thread, with a 100ms per-app messaging timeout — on
// any signal that the window population changed.
//
// All mutable state is confined to the main thread: observers and workspace
// notifications land there, and refresh() only hops to a background queue for
// the AX walk, publishing its result back on main.
final class WindowTracker {
    private(set) var cached: [WindowInfo] = []
    // window-id → AeroSpace workspace, refreshed on the same background pass as
    // the AX snapshot. Cached rather than fetched per-show because the switcher
    // needs it *synchronously* at activation — it decides both the row grouping
    // and which row starts selected, and neither may shuffle mid-session.
    private(set) var workspaceMap: [CGWindowID: String] = [:]
    private var stamps: [CGWindowID: Double] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var refreshScheduled = false
    // Throttle state for the workspace map — see refresh().
    private var workspaceFetchIDs = Set<CGWindowID>()
    private var workspaceFetchedAt: TimeInterval = 0
    private var workspaceFetchInFlight = false
    private static let workspaceMaxAge: TimeInterval = 5

    init() {
        seedFromZOrder()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
        installWorkspaceObservers()
        refreshSoon()
    }

    // The switcher's list: most-recently-focused first, then gathered so windows
    // sharing an AeroSpace workspace sit together. Windows never focused since
    // the daemon started sink to the bottom (stable by title so the tail doesn't
    // shuffle between opens).
    func orderedWindows() -> [WindowInfo] {
        let sorted = cached.sorted { a, b in
            let sa = stamps[a.id] ?? 0, sb = stamps[b.id] ?? 0
            if sa != sb { return sa > sb }
            return a.title < b.title
        }
        // Collapse to one row per CGWindowID (keep the highest-stamped, i.e.
        // first after the sort). Two AX elements can briefly map to the same id
        // while an app is mid-transition — and the HUD keys rows on `.id(w.id)`,
        // so a duplicate would collide SwiftUI's identity and smear the
        // selection highlight onto the wrong row.
        var seen = Set<CGWindowID>()
        return groupByWorkspace(sorted.filter { seen.insert($0.id).inserted })
    }

    // Stable group-by: a workspace takes its rank from its most recent window,
    // and every other window of that workspace follows it. So the list reads
    // current-workspace-first, then the workspace you were on before that, and
    // so on — workspace MRU, with window MRU inside each group. Without
    // AeroSpace every window maps to nil, which is one group, which is the
    // plain MRU list this replaced.
    private func groupByWorkspace(_ windows: [WindowInfo]) -> [WindowInfo] {
        var order: [String] = []          // workspace names by first appearance
        var groups: [String: [WindowInfo]] = [:]
        for w in windows {
            let key = workspaceMap[w.id] ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(w)
        }
        return order.flatMap { groups[$0] ?? [] }
    }

    // The windows tiled beside `anchor` right now: same AeroSpace workspace, and
    // actually drawn on screen. Switching to one of those isn't a switch — you're
    // looking at it already, and nudging focus between visible tiles is what
    // windowNav's ⌥hjkl is for. Used only to pick which row starts selected;
    // nothing is ever filtered out of the list.
    //
    // nil means "no tiling to reason about" — no AeroSpace, or it doesn't place
    // the anchor — and the switcher then keeps the plain "row 1 is the last
    // window" rule. That gate matters: without a tiling WM, a window merely
    // sitting on screen *behind* the current one is an ordinary switch target,
    // not a tile, and skipping it would walk the default onto something worse.
    //
    // Both halves are load-bearing. Same-workspace alone would skip a minimized
    // or otherwise hidden sibling that IS a real target; on-screen alone would
    // skip the other monitor's window (AeroSpace binds each workspace to one
    // monitor, so a different display is already a different workspace).
    func windowsTiledBeside(_ anchor: WindowInfo) -> Set<CGWindowID>? {
        guard Aerospace.binPath != nil, let home = workspaceMap[anchor.id] else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        var onScreen = Set<CGWindowID>()
        for info in list {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            onScreen.insert(CGWindowID(num))
        }
        var beside = Set<CGWindowID>()
        for w in cached where w.id != anchor.id
            && workspaceMap[w.id] == home && onScreen.contains(w.id) {
            beside.insert(w.id)
        }
        return beside
    }

    // Force the currently-frontmost app's focused window to the top of the MRU
    // order, synchronously. The async focus path (AeroSpace subprocess +
    // NSWorkspace/AX activation notifications) may not have re-stamped the last
    // switch's target yet, so a rapid second ⌘Tab would otherwise sort against a
    // half-settled snapshot and leave the just-activated window somewhere below
    // row 0 — making it the auto-selected row 1 and looking "stuck" as you tab.
    // The live frontmost app is the synchronous source of truth for row 0.
    func stampFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        touchFocusedWindow(pid: app.processIdentifier)
    }

    // Focus a window: unminimize via AX when needed, otherwise prefer
    // `aerospace focus --window-id` (it knows how to surface a window parked on
    // another AeroSpace workspace); plain AX raise + app activation everywhere
    // else, and as the fallback when the CLI call fails.
    func focus(_ w: WindowInfo) {
        stamps[w.id] = Date().timeIntervalSince1970
        if w.isMinimized {
            AXUIElementSetAttributeValue(w.axElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            raise(w)
            return
        }
        if Aerospace.binPath != nil {
            Aerospace.focus(windowID: w.id) { [weak self] ok in
                if !ok { self?.raise(w) }
            }
        } else {
            raise(w)
        }
    }

    private func raise(_ w: WindowInfo) {
        AXUIElementPerformAction(w.axElement, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: MRU stamping

    @discardableResult
    private func touch(windowElement: AXUIElement) -> Bool {
        var id: CGWindowID = 0
        _AXUIElementGetWindow(windowElement, &id)
        guard id != 0 else { return false }
        stamps[id] = Date().timeIntervalSince1970
        return true
    }

    private func touchFocusedWindow(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return }
        touch(windowElement: v as! AXUIElement)
    }

    // Before any focus event has fired, approximate MRU with the WindowServer's
    // front-to-back z-order (no Screen Recording needed — we only read IDs, not
    // names). Descending stamps preserve that order under the same sort.
    private func seedFromZOrder() {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return }
        let now = Date().timeIntervalSince1970
        for (i, info) in list.enumerated() {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            stamps[CGWindowID(num)] = now - Double(i) * 0.001
        }
    }

    // MARK: Observation

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.touchFocusedWindow(pid: app.processIdentifier)
            self?.refreshSoon()   // cheap way to prune windows closed since last look
        }
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            self?.observe(app)
            self?.refreshSoon()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let observer = self?.observers.removeValue(forKey: app.processIdentifier) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                      AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            self?.refreshSoon()
        }
    }

    // Per-app AXObserver: NSWorkspace only reports app-level activation, so
    // within-app window switches (⌘`, clicking a second window) would be
    // invisible to the MRU without this. Window created/destroyed just marks
    // the snapshot stale.
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier,
              observers[pid] == nil else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handleAX(notification: notification as String, element: element)
        }, &observer) == .success, let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, axApp, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func handleAX(notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            // The callback element should be the newly-focused window; some apps
            // hand back something unmappable, so fall back to asking the app.
            if !touch(windowElement: element) {
                var pid: pid_t = 0
                if AXUIElementGetPid(element, &pid) == .success { touchFocusedWindow(pid: pid) }
            }
            refreshSoon()   // a focus shift often means a window just closed
        case kAXWindowCreatedNotification:
            touch(windowElement: element)   // brand-new windows join near the top
            refreshSoon()
        case kAXUIElementDestroyedNotification:
            refreshSoon()
        default:
            break
        }
    }

    // MARK: Snapshot refresh

    // Coalesced (many AX notifications arrive in bursts) and asynchronous: the
    // AX walk does one IPC round-trip per app, and an unresponsive app would
    // otherwise stall whoever asked. Nothing waits on this — the switcher reads
    // whatever snapshot is current.
    func refreshSoon() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let apps: [(pid: pid_t, name: String, bundleId: String?, path: String?)] =
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && !$0.isTerminated
                          && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .map { ($0.processIdentifier, $0.localizedName ?? "App",
                        $0.bundleIdentifier, $0.bundleURL?.path) }

        // refresh() fires on every app activation and AX window notification, so
        // the workspace map does NOT ride every pass — that would be an
        // `aerospace` subprocess per click. Re-ask only when the window
        // population changed (new/closed window ⇒ the map can't be complete) or
        // when the answer has simply aged out, which is what catches a window
        // thrown to another workspace without any id changing.
        let ids = Set(cached.map(\.id))
        let now = ProcessInfo.processInfo.systemUptime
        let wantSpaces = !workspaceFetchInFlight
            && (ids != workspaceFetchIDs || now - workspaceFetchedAt >= Self.workspaceMaxAge)
        if wantSpaces { workspaceFetchInFlight = true }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = Self.enumerate(apps: apps)
            // Blocking, hence out here rather than on the main thread: the
            // switcher reads the cached map synchronously and can't spawn
            // anything from inside the event tap.
            let spaces = wantSpaces ? Aerospace.workspacesSync() : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.cached = snapshot
                guard wantSpaces else { return }
                self.workspaceFetchInFlight = false
                // A failed pass keeps the previous map rather than dropping
                // every window into one unnamed group, and doesn't stamp the
                // clock — so the next refresh retries instead of waiting it out.
                if let spaces {
                    self.workspaceMap = spaces
                    self.workspaceFetchIDs = Set(snapshot.map(\.id))
                    self.workspaceFetchedAt = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }

    private static func enumerate(apps: [(pid: pid_t, name: String, bundleId: String?, path: String?)]) -> [WindowInfo] {
        var out: [WindowInfo] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            // Cap how long a busy/hung app may stall the walk (default is 6s!).
            AXUIElementSetMessagingTimeout(axApp, 0.1)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for el in windows {
                var id: CGWindowID = 0
                _AXUIElementGetWindow(el, &id)
                guard id != 0 else { continue }
                // Standard windows + dialogs; palettes/popovers/status bubbles
                // (AXSystemDialog, AXUnknown, floating panels) aren't targets a
                // window switcher should offer. A missing subrole passes — some
                // apps never set one on perfectly ordinary windows.
                if let sub = stringAttr(el, kAXSubroleAttribute),
                   sub != kAXStandardWindowSubrole, sub != kAXDialogSubrole { continue }
                let title = stringAttr(el, kAXTitleAttribute) ?? ""
                out.append(WindowInfo(
                    id: id, pid: app.pid, appName: app.name, bundleId: app.bundleId,
                    appPath: app.path,
                    title: title.isEmpty ? app.name : title,
                    isMinimized: boolAttr(el, kAXMinimizedAttribute),
                    axElement: el))
            }
        }
        return out
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttr(_ el: AXUIElement, _ attr: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

// MARK: - AeroSpace CLI

// Optional integration with the AeroSpace tiling WM. Its workspaces aren't
// native Spaces (windows are parked off-viewport), so focusing across them
// through the CLI is the only move that also switches the workspace. Absent
// AeroSpace, everything degrades to plain AX focus and no badges.
enum Aerospace {
    static let binPath: String? = {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/aerospace",
                          "/usr/local/bin/aerospace",
                          "/run/current-system/sw/bin/aerospace",
                          "/etc/profiles/per-user/\(NSUserName())/bin/aerospace"]
        if let env = ProcessInfo.processInfo.environment["POUNCE_AEROSPACE"] {
            candidates.insert(env, at: 0)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }()

    static func focus(windowID: CGWindowID, completion: @escaping (Bool) -> Void) {
        run(["focus", "--window-id", String(windowID)]) { status, _ in
            completion(status == 0)
        }
    }

    // window-id → workspace name, for the switcher's grouping. Blocking, so it
    // may ONLY be called off the main thread — WindowTracker.refresh()'s
    // background pass is the single caller. nil means "no answer this pass"
    // (AeroSpace absent, erroring, or wedged): the caller keeps the map it had
    // rather than dropping every window into one unnamed group.
    static func workspacesSync() -> [CGWindowID: String]? {
        guard let (status, output) =
                runSync(["list-windows", "--all", "--format", "%{window-id}\t%{workspace}"]),
              status == 0 else { return nil }
        var map: [CGWindowID: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2, let id = UInt32(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            map[CGWindowID(id)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return map
    }

    // Blocking sibling of run(), for callers already on a background queue.
    // nil on any failure. The watchdog is what keeps a wedged AeroSpace from
    // pinning a worker thread for every refresh that follows it.
    private static func runSync(_ args: [String]) -> (Int32, String)? {
        guard let bin = binPath else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        // Exit is observed through terminationHandler rather than
        // waitUntilExit(): the timeout has to be able to fire while we're
        // waiting, and polling isRunning to decide whether to terminate races
        // the reap (the pid can be reused between the check and the signal).
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }

        // Drained on its own thread so a child that inherited the pipe's write
        // end can't wedge this one past the timeout, and so the read can't
        // deadlock against a process still filling a full pipe buffer.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if exited.wait(timeout: .now() + 1.0) == .timedOut {
            proc.terminate()
            _ = exited.wait(timeout: .now() + 0.5)
        }
        guard drained.wait(timeout: .now() + 0.5) == .success else { return nil }
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // Fire-and-callback subprocess, never blocking the caller; completion runs
    // on the main queue.
    private static func run(_ args: [String], completion: @escaping (Int32, String) -> Void) {
        guard let bin = binPath else { completion(1, ""); return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { p in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async { completion(p.terminationStatus, out) }
        }
        do { try proc.run() } catch { completion(1, "") }
    }
}
