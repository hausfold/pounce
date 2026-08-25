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

        NSApp.mainMenu = main
        // Named so macOS puts its own items (Enter Full Screen, the window
        // list) in the right place rather than treating it as a stray menu.
        NSApp.windowsMenu = windowMenu
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
        if let reply = Daemon.request("RUN\tmode:settings\n"), !reply.hasPrefix("err") {
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
