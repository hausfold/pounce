import AppKit
import ApplicationServices

// MARK: - Auto-quit on last window close

// Off by default. When on, closing an app's last window quits the app — the
// behaviour Windows has and macOS doesn't, where a windowless app sits in ⌘Tab
// and the Dock until you remember to ⌘Q it.
//
// This rides the window switcher's AX snapshot (WindowTracker) rather than
// observing anything of its own: the tracker already keeps a per-app AXObserver
// on every regular app and already learns, within ~300ms, that a window went
// away. So turning this on adds no observers, no polling and no permission
// beyond the Accessibility grant the tracker needs anyway.
//
// Two decisions worth knowing before you change anything here:
//
//   The quit is POLITE. `terminate()` is the same Quit AppleEvent ⌘Q sends, so an
//   app with unsaved work puts its sheet up and stays. Never forceTerminate() —
//   an auto-quit that can lose work is a bug the user can't undo.
//
//   The re-check is CONSERVATIVE, and deliberately stricter than the snapshot
//   that scheduled it. The snapshot counts switchable windows (standard + dialog
//   subroles); this counts ANY window element at all, and an app that doesn't
//   answer keeps its life. The costs are asymmetric — a missed quit is invisible,
//   a wrong quit closes something you were using — so every ambiguity resolves
//   toward "leave it alone".
final class AutoQuit {
    private var policy: AutoQuitPolicy
    private let delay: TimeInterval
    // Last published window count per pid. The scheduled quit re-reads this on
    // its way to terminate(): the AX re-check runs off-main and can take up to
    // its messaging timeout, and a window opened inside that gap arrives here as
    // a fresh census long before the answer it invalidates comes back.
    private var windows: [pid_t: Int] = [:]

    init(settings: AutoQuitSettings) {
        policy = AutoQuitPolicy(excluded: settings.exclude)
        delay = settings.delay
    }

    // Main thread — WindowTracker publishes its census there.
    func consume(_ census: [AppWindowCensus]) {
        // uniquing rather than uniqueKeysWithValues: a duplicate pid shouldn't be
        // possible, and a trap here would take ⌘Space down with the daemon. Keep
        // the larger count — the reading that doesn't quit anything.
        windows = Dictionary(census.map { ($0.pid, $0.windows) }, uniquingKeysWith: max)
        for app in policy.step(census) { schedule(app) }
    }

    // The grace period is what makes this survive an app that closes one window
    // and opens another (a browser's "close tab-window, open new one", an
    // editor's project switch): the re-check below sees the replacement and the
    // quit never happens. No cancellation machinery is needed for that — the
    // re-check IS the cancellation.
    private func schedule(_ app: AppWindowCensus) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.quitIfStillWindowless(app)
        }
    }

    private func quitIfStillWindowless(_ app: AppWindowCensus) {
        // Re-resolve rather than holding NSRunningApplication across the delay:
        // the app may have exited on its own, and the bundle-id check catches the
        // case where its pid has already been handed to something else.
        guard let running = NSRunningApplication(processIdentifier: app.pid),
              !running.isTerminated,
              running.bundleIdentifier == app.bundleId
        else { return }

        // Off-main: a wedged app can hold the AX reply for the full messaging
        // timeout, and the palette's UI runs on this thread.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard Self.hasNoWindows(pid: app.pid) else { return }
            DispatchQueue.main.async {
                // Last look, on the thread that owns the state: the AX answer
                // above may be up to a messaging timeout old, and a window that
                // appeared meanwhile has already been published here.
                guard let self, self.windows[app.pid] == 0, !running.isTerminated else { return }
                NSLog("pounce auto-quit: \(app.name) has no windows left — quitting")
                running.terminate()
            }
        }
    }

    // True only when the app answered AND said it has nothing open. A failed or
    // timed-out reply returns false, i.e. "don't quit it".
    private static func hasNoWindows(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        // Longer than the snapshot walk's 100ms: this runs once per candidate,
        // off the hot path, and here a timeout costs a missed quit rather than a
        // stale row.
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return false }
        return windows.isEmpty
    }
}
