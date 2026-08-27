// Hosting the Settings window in an app that has never had one.
//
// Pounce is a raw `NSApplication` at `.accessory` policy with no main menu and
// no SwiftUI `App` — the whole process exists to draw one borderless panel on a
// keystroke (Entry.swift). A SwiftUI `Settings` scene, which is how perch and
// trill get theirs, needs an `App`; there isn't one to hang it off. So the
// window is built the way the palette's is: an `NSWindow` with an
// `NSHostingView` inside it (Window.swift), just an ordinary titled one.
//
// THREE THINGS AN ACCESSORY APP HAS TO DO BY HAND, and all three bite:
//
//   1. ORDERING. An `.accessory` app's window can be left behind whatever is
//      already on screen — especially under a tiling window manager like
//      AeroSpace, which places windows itself. Switching to `.regular` while the
//      window is up, activating with `ignoringOtherApps`, and reverting to
//      `.accessory` once it closes is the same dance trill runs
//      (Trill/Platform/UtilityWindowManager.swift); it is also what puts pounce
//      in ⌘Tab and the Dock for exactly as long as its settings are open, which
//      is the correct answer to "where did that window go".
//
//   2. THE EDIT MENU. In AppKit, ⌘X/⌘C/⌘V/⌘A/⌘Z are dispatched by the Edit
//      menu's key equivalents, not by the text field. With no main menu, they
//      silently do nothing — the bug `PounceWindow.performKeyEquivalent` exists
//      to work around for the palette's one search field. A settings window is
//      full of text fields and someone WILL paste a theme name into one, so this
//      installs a real menu bar rather than re-creating the workaround.
//
//   3. ⌘Q. Installing that menu bar means the app finally has a Quit item — and
//      the palette is a transient panel where ⌘Q must keep doing nothing rather
//      than killing the daemon out from under a keystroke. `PounceWindow`
//      swallows it; see the note there.
//
// One window, one store, for the life of the process: reopening shows the file
// as it is now (the store re-reads on every activation), not as it was when the
// window was first built.

import AppKit
import SwiftUI

final class PounceSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = PounceSettingsWindowController()

    /// Called after the window closes. The daemon leaves this nil — it lives on
    /// to answer the next ⌘Space. A `pounce settings` invocation with no daemon
    /// running sets it to terminate, since the window IS that process's whole
    /// job.
    var onClose: (() -> Void)?

    private var window: NSWindow?
    private let store = ConfigStore()
    /// What the policy was before we raised the window, so a process that was
    /// already `.regular` (there is none today, but a future one is cheap to be
    /// right about) isn't demoted to `.accessory` on close.
    private var previousPolicy: NSApplication.ActivationPolicy?

    /// Show the window, building it the first time. Idempotent: a second call
    /// with the window already up just brings it forward, which is what a second
    /// press of the palette row should do.
    func show() {
        PounceMainMenu.install()
        // Whatever the file says NOW. The window may have been open, closed and
        // hand-edited in between.
        store.refresh()

        let window = self.window ?? build()
        if previousPolicy == nil {
            previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func build() -> NSWindow {
        let size = PounceSettingsView.defaultWindowSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = PounceSettingsView.windowTitle
        window.titlebarAppearsTransparent = false
        // Closing a settings window is not closing the app, and the window is
        // rebuilt-on-demand exactly once. Releasing it here would leave `window`
        // pointing at freed memory the second time someone opens it.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PounceSettingsView(store: store))
        window.setContentSize(size)
        // A settings window is small, personal and remembered by macOS itself.
        window.setFrameAutosaveName("PounceSettings")
        self.window = window
        return window
    }

    // MARK: - NSWindowDelegate

    /// Catch up with the file whenever the window comes forward — someone may
    /// have edited config.json in their editor since it was last looked at, and
    /// a settings window showing a value the file no longer has is worse than no
    /// settings window.
    func windowDidBecomeKey(_ notification: Notification) {
        store.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        if let previousPolicy {
            NSApp.setActivationPolicy(previousPolicy)
            self.previousPolicy = nil
        }
        onClose?()
    }
}

// MARK: - The menu bar

/// The main menu pounce has never had, installed the first time a real window
/// wants one.
///
/// Minimal on purpose. There is no document model, no windows to arrange and no
/// preferences item (this IS the preferences), so what's left is the three menus
/// macOS genuinely expects: the app menu, an Edit menu (which is what makes
/// ⌘C/⌘V work at all — see the note at the top of this file), and a Window menu
/// for ⌘W.
///
/// Installed once and left in place. It is only ever VISIBLE while the app is
/// `.regular`, i.e. while the settings window is up; tearing it down again on
/// close would buy nothing and risks doing it mid-tracking.
enum PounceMainMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }

        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Pounce", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // The only feedback channel pounce has — there is no telemetry in
        // anything we ship. The palette carries the same door as a row (the
        // Report Pounce Issue command) and the terminal as `pounce report`;
        // this is the one for whoever came to Settings because something was
        // wrong and found the setting wasn't the problem. All three end at the
        // same prefilled form. See BugReport.swift.
        appMenu.addItem(withTitle: "Report a Bug…", action: #selector(PounceMenuActions.reportBug(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Pounce", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        // ⌘Q terminates the daemon, which is right from a settings window and
        // wrong from the palette — `PounceWindow` refuses it there so a
        // mistyped ⌘Space chord can't take pounce down with it.
        appMenu.addItem(withTitle: "Quit Pounce", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        // The row above targets this explicitly; keep the object alive for as
        // long as the menu is.
        for item in appMenu.items where item.action == #selector(PounceMenuActions.reportBug(_:)) {
            item.target = PounceMenuActions.shared
        }

        NSApp.mainMenu = main
        // Named so macOS puts its own items (Enter Full Screen, the window
        // list) in the right place rather than treating it as a stray menu.
        NSApp.windowsMenu = windowMenu
    }
}

/// Targets for menu items that aren't one of AppKit's own selectors.
///
/// A menu item with a nil target sends up the responder chain to NSApp and then
/// to its delegate; neither answers `reportBug:`, and an unhandled selector
/// leaves the row permanently greyed out with nothing said anywhere. So the row
/// gets an explicit target, and this object is it.
///
/// `static let shared` is what keeps it alive, and it has to: `NSMenuItem.target`
/// is a **weak** reference, so the menu retains nothing and a per-install
/// instance would be gone before the first click.
final class PounceMenuActions: NSObject {
    static let shared = PounceMenuActions()

    @objc func reportBug(_ sender: Any?) {
        // Re-exec `pounce report` rather than calling ReportMode in place, for
        // two reasons that both end badly in-process:
        //
        //   ReportMode exits when it's done, and this process is a live
        //   settings window somebody is still using.
        //
        //   The block it builds includes the doctor report, which is a
        //   round trip to the DAEMON's socket — and when Settings was opened
        //   from the palette, this process IS that daemon. Asking yourself a
        //   question over your own socket and waiting on the main thread for
        //   the answer is a beachball with no visible cause.
        //
        // A separate process asks the daemon from outside, which is the
        // supported direction, and nothing here waits for it.
        // `Bundle.main.executableURL`, not `CommandLine.arguments[0]`: a binary
        // found on PATH sees argv[0] as the bare word `pounce`, which
        // `URL(fileURLWithPath:)` then resolves against the cwd and `run()`
        // throws on. That path is live — `SettingsMode.run` hosts the window in
        // the CLI process whenever no daemon answers, which is exactly the
        // "something is wrong, let me file a bug" cohort.
        let process = Process()
        process.executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["report"]
        // Logged, not swallowed: a door that can fail must not fail mutely.
        // Same shape as CommandSpawner.run.
        do {
            try process.run()
        } catch {
            NSLog("pounce: couldn't open the bug report: \(error)")
        }
    }
}

// MARK: - `pounce settings`

/// The CLI verb, and the reason `mode:settings` exists as a target rather than
/// as a private call: one item key addresses this window from the palette row,
/// from a hotkey binding, from `pounce run`, and from here.
///
/// Handed to the DAEMON when one is listening, for the same reason `pounce run`
/// is — the window has to belong to a process that outlives the command you
/// typed, and a second `pounce settings` should raise the window you already
/// have rather than opening a rival one against the same file. With no daemon
/// it runs here instead: a settings window is worth having on a Mac where
/// pounce isn't running, since "it isn't running" is one of the things you
/// might have come to fix.
enum SettingsMode {
    static func run() -> Never {
        // The same escape hatch `ClientMode.run` honours, and for the same
        // reason AGENTS.md spells out: with a daemon running, every window verb
        // is answered by the DAEMON's build, so a fix can be feel-tested twice
        // against the old code with no sign it never ran. This is the verb
        // people will most want to try from `./result/bin/pounce`.
        let forwarded = ProcessInfo.processInfo.environment["POUNCE_NO_DAEMON"] == nil
        if forwarded, let reply = Daemon.request("RUN\tmode:settings\n"), !reply.hasPrefix("err") {
            exit(0)
        }
        runDirect()
    }

    private static func runDirect() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        PounceSettingsWindowController.shared.onClose = { NSApp.terminate(nil) }
        DispatchQueue.main.async { PounceSettingsWindowController.shared.show() }
        app.run()
        exit(0)
    }
}
