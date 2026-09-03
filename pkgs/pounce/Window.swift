import SwiftUI
import AppKit

// MARK: - Field editor

// The palette's own field editor, whose only job is to refuse the contextual
// menu macOS asks for when nobody clicked.
//
// ⌃⏎ is one of Pounce's action chords (haus's Spawn Agent uses it for
// "Background"), and it is ALSO the system-wide context-menu hotkey whenever
// keyboard navigation is on — AppleKeyboardUIMode = 2, which haus sets by
// default, so that is the ordinary state of the machine. The chord therefore ran
// its action AND dropped AppKit's stock text menu (Cut / Copy / Paste / Writing
// Tools / AutoFill) over the palette a frame later.
//
// Not cosmetic: an NSMenu tracks in a modal run loop on the main thread, so the
// palette behind it stops answering and is left on screen after its command has
// finished and exited — a stuck window with no process behind it.
//
// ── why it is stopped here and not at the key event ──────────────────────────
// Two earlier attempts ate the chord itself, and neither worked: swallowing its
// keyDown in the field's local monitor, then also its keyUp. Measured both
// times, the menu still arrived ~40 ms after the key came up with no mouse
// button down anywhere. It does not travel the app's event stream as a key
// event at all — NSResponder.h is explicit that the hotkey is delivered as
// `contextMenuKeyDown:`, and that an Accessibility ShowMenu action or a user's
// own Cocoa Text key binding can produce the menu with no key event first.
//
// Both of those doors are macOS 15 API (`NSResponder.h`, `API_AVAILABLE(macos(15.0))`),
// hence the `@available` on each override: build.sh pins the deployment target
// at macOS 14, so without the annotation the overrides only compile when the
// builder's own OS happens to be 15+. The third door,
// `accessibilityPerformShowMenu`, is 10.10 and needs none. Note this is a
// COMPILE-time floor as well as a runtime one — an SDK older than 15 does not
// declare the methods at all, so building pounce needs Xcode 16+ CLT no matter
// what it is then targeted at.
//
// So all three of AppKit's documented doors are answered below. Note what is
// NOT here: a `menu(for:)` override that tries to tell a click from a keypress.
// That cannot work, and the header says why — the default
// `showContextMenuForSelection:` displays its menu by calling `menuForEvent:`
// with a SYNTHESIZED right-mouse-down centered on the selection, so by the time
// the request reaches `menu(for:)` it is indistinguishable from a real
// right-click. Refusing there would have taken the real right-click's menu with
// it, which is the one this class means to keep.
final class PounceFieldEditor: NSTextView {
    // The hotkey itself. This is the override NSResponder.h names for exactly
    // this situation: "if your application already provides a different
    // behavior for control-Return (the default context menu hotkey
    // definition), and you want to preserve that behavior, you should override
    // this method to handle that specific key combination, and then return
    // without calling super."
    //
    // Scoped to ⌃Return for the reason the same paragraph gives: the user may
    // have moved the hotkey to some other combination, and that one is not
    // ours to swallow — it goes to super, which walks the responder chain and
    // ends in the ordinary menu.
    @available(macOS 15.0, *)
    override func contextMenuKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, flags.contains(.control) { return }
        super.contextMenuKeyDown(event)
    }

    // The routes that arrive with no `contextMenuKeyDown:` before them, which
    // the header lists as an Accessibility ShowMenu action and a user-defined
    // Cocoa Text key binding. A launcher panel that lives for one keystroke has
    // no contextual menu worth presenting without a pointer, so both are
    // declined rather than passed up the chain.
    @available(macOS 15.0, *)
    override func showContextMenuForSelection(_ sender: Any?) {}

    // AXShowMenu is documented to arrive as `showContextMenuForSelection:`
    // above, so this should be redundant — but it is the door measured to close
    // the bug on macOS 26.6 before either override above existed, and a second
    // answer to a request that must always be "no" costs nothing.
    override func accessibilityPerformShowMenu() -> Bool { false }
}

// MARK: - Window

class PounceWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // One field editor per window is AppKit's own arrangement; this just makes
    // it ours. `createFlag` is deliberately ignored — AppKit also probes with
    // false ("is there one already?"), and answering that probe by building one
    // is cheaper than tracking the distinction for a window that has exactly one
    // text field and always edits it.
    private lazy var pounceEditor: PounceFieldEditor = {
        let editor = PounceFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is NSTextField { return pounceEditor }
        return super.fieldEditor(createFlag, for: object)
    }

    // Pounce is a menu-less accessory app (.accessory policy, no main menu), and
    // in AppKit the standard editing chords — ⌘X/⌘C/⌘V/⌘A/⌘Z — are dispatched by
    // the Edit menu's key equivalents, not by the field editor itself. With no
    // Edit menu those chords never reach the search field's field editor, so
    // pasting (and copy/cut/select-all/undo) silently do nothing — the "can't
    // paste a file URI into the input" bug. Plain typing and the arrow/return
    // keys work because they travel the normal responder chain. Re-create just the
    // dispatch the missing menu would do: map the chord to its editing selector
    // and send it to the first responder (to: nil walks the responder chain, so
    // the field editor picks it up).
    //
    // The WINDOW-management chords are the opposite job, and arrived with the
    // same fix. Pounce grew a main menu the day it grew a Settings window
    // (SettingsWindow.swift), and a menu brings ⌘Q/⌘W/⌘M/⌘H with it — all four
    // right from a settings window, all four wrong from a panel that lives for
    // one keystroke and has always ignored them. ⌘Q would take the daemon down
    // on a fumbled ⌘Space; the other three would beep, minimise or hide a panel
    // that is about to dismiss itself anyway. Refused HERE rather than left out
    // of the menu, so the menu stays the one macOS expects and the palette stays
    // the panel it has always been.
    static let refusedCommandKeys: Set<String> = ["q", "w", "m", "h"]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command: NSEvent.ModifierFlags = .command
        if mods == command,
           let key = event.charactersIgnoringModifiers,
           Self.refusedCommandKeys.contains(key) { return true }
        if mods == command || mods == [command, .shift] {
            let selector: Selector?
            switch event.charactersIgnoringModifiers {
            case "x": selector = #selector(NSText.cut(_:))
            case "c": selector = #selector(NSText.copy(_:))
            case "v": selector = #selector(NSText.paste(_:))
            case "a": selector = #selector(NSResponder.selectAll(_:))
            // ⌘Z undo, ⇧⌘Z redo — selectors live on the field editor's undo
            // support, not a shared protocol, so resolve them by name.
            case "z": selector = NSSelectorFromString(mods.contains(.shift) ? "redo:" : "undo:")
            default:  selector = nil
            }
            if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - PounceUI (window controller shared by daemon + direct mode)

final class PounceUI {
    // A resizable rounded-rect mask: a solid rounded square with cap insets so it
    // stretches to any window size without distorting the corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let image = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // Point the window chrome at the ACTIVE palette's polarity. `.hudWindow`
    // and an unset `appearance` both follow the SYSTEM appearance, so a light
    // theme (nebelung-latte, catppuccin latte) on a dark Mac blurred a dark
    // backdrop through its pale fill and came out muddy grey with unreadable
    // secondary text. Pinning the effect view's appearance decouples the two:
    // the palette decides, not System Settings. Called on every present() —
    // `"theme"` is re-read per open, so the window outlives any one palette.
    static func applyChrome(_ blur: NSVisualEffectView) {
        let light = Theme.isLight
        blur.appearance = NSAppearance(named: light ? .vibrantLight : .vibrantDark)
        blur.material = light ? .popover : .hudWindow
        // A whisper, not a line. The border exists so the panel reads as one
        // object against a same-colored backdrop; 0.08 read as a drawn outline
        // and made the panel feel framed rather than floating.
        blur.layer?.borderColor = (light ? NSColor.black : NSColor.white)
            .withAlphaComponent(light ? 0.06 : 0.035).cgColor
    }

    let window: PounceWindow
    let hosting: NSHostingView<ContentView>
    let state: DaemonState

    private var lingerItem: DispatchWorkItem?
    private var spinnerItem: DispatchWorkItem?
    // A fade that has already STARTED is the one teardown cancelLinger cannot
    // take back: its work item has fired, and NSAnimationContext runs the
    // completion handler whatever happens next. A next step's present() landing
    // inside those 120 ms therefore had its brand-new window ordered out by the
    // PREVIOUS step's completion handler — and because that orderOut is the only
    // silent hide in the whole daemon (every other one logs a "dismiss via"),
    // the failure had no window, no error and no trace: the client stayed
    // blocked until the NEXT request released it with an empty answer. That is
    // exactly what "pick the repo and the prompt box doesn't come up, do it
    // again and it does" was. So stamp each fade, and let present() disown one
    // mid-flight AND stop the animation driving it.
    private var fadeToken = 0
    private var fading = false
    private var resizePending = false   // coalesces a keystroke's onResize burst into one deferred refit
    var resultSink: ((String) -> Void)?

    // The app that was frontmost when the window first appeared — captured before
    // we steal focus, preserved across submenu swaps, and reactivated on an
    // auto-paste commit. Cleared when the window fully hides.
    private var capturedApp: NSRunningApplication?

    init(state: DaemonState) {
        self.state = state
        self.hosting = NSHostingView(rootView: ContentView(state: state))

        window = PounceWindow(
            contentRect: NSRect(x: 0, y: 0, width: LayoutMetrics.standard.width, height: 400),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = PanelChrome.cornerRadius
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        PounceUI.applyChrome(blur)   // material/appearance/border follow the palette
        // layer.cornerRadius alone doesn't clip the vibrancy material or shape the
        // window shadow — a resizable rounded maskImage does both, killing the
        // square corner that pokes out behind the rounded panel.
        blur.maskImage = PounceUI.roundedMask(radius: PanelChrome.cornerRadius)
        // Pin the content to the TOP edge (fixed height, flexible bottom margin)
        // so an animated window resize reveals/covers from the bottom instead of
        // letting NSHostingView re-center the content and slide it vertically.
        hosting.autoresizingMask = [.width, .minYMargin]
        blur.addSubview(hosting)
        window.contentView = blur

        state.onCommit = { [weak self] commit in self?.handleCommit(commit) }
        state.onResize = { [weak self] in
            guard let self = self else { return }
            // Fast path — the launcher hands us its EXACT height
            // (state.pendingContentHeight, computed from row metrics) right before
            // this call, so we resize synchronously in the SAME runloop turn as the
            // content change. Window and content then composite together in one
            // clean snap. We deliberately do NOT measure hosting.fittingSize here:
            // on macOS 26 (Tahoe) it reads stale within the turn, and measuring
            // then correcting on the next tick is the shrink-then-grow "flash
            // closed/open" seen while typing to filter.
            if self.state.pendingContentHeight != nil {
                self.resizeToFit()
                return
            }
            // Slow path — no exact height (a command/cheatsheet mode swap): measure
            // on the next tick, after SwiftUI reconciles the new mode. Coalesce a
            // burst of onChange calls into that single pass.
            guard !self.resizePending else { return }
            self.resizePending = true
            DispatchQueue.main.async {
                self.resizePending = false
                self.hosting.layoutSubtreeIfNeeded()
                self.resizeToFit()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.state.isVisible else { return }
            // DIAGNOSTIC (fn+Esc/native-picker race)
            NSLog("pounce DIAG: dismiss via click-out at \(Date())")
            self.state.cancel()
        }

        // DIAGNOSTIC (fn+Esc/native-picker race): log every app activation so a
        // native Character Viewer / emoji picker appearing right after a
        // dismiss shows up here with a timestamp to correlate against.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            NSLog("pounce DIAG: app activated -> \(app.bundleIdentifier ?? "?") (\(app.localizedName ?? "?")) at \(Date())")
        }
    }

    // MARK: Presentation

    // Build the SwiftUI view tree and run its first layout + draw at startup,
    // while the window is hidden, so the very first ⌘Space doesn't pay
    // NSHostingView's one-time initial render on the keystroke. An ordered-out
    // window otherwise defers that render until the panel is first shown —
    // landing the whole cost (SwiftUI graph build, CoreText font realization,
    // the vibrancy layer) on the hot path. Reading fittingSize forces SwiftUI to
    // build its graph and lay out; displayIfNeeded forces the first draw into the
    // backing store. Cheap and idempotent; safe to call once at daemon start.
    func warmRender() {
        let target = NSSize(width: state.targetWidth, height: 400)
        window.setContentSize(target)
        hosting.frame = window.contentView?.bounds ?? .zero
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.fittingSize
        hosting.displayIfNeeded()
    }

    func present() {
        cancelLinger()
        let interrupted = abortFade()
        state.isLoading = false   // new content replaces any in-flight spinner
        let fresh = !window.isVisible
        // DIAGNOSTIC (two-step present race). This and `faded out` below are
        // what make a window that vanished with no dismissal legible at all:
        // that line is the daemon's ONE silent hide, and `interruptedFade=true`
        // here is this fix catching one. NOT on the launcher, which logs its
        // own timing line and is the ~12 ms warm path the in-process hotkey
        // exists for — a step arriving over the socket has already paid a
        // process spawn, so one NSLog is free there and nowhere else.
        if !state.isLauncher {
            NSLog("pounce DIAG: step present fresh=\(fresh) interruptedFade=\(interrupted) appActive=\(NSApp.isActive)")
        }
        // The palette is re-read per open; the window isn't rebuilt. Re-point
        // the chrome at whatever `Theme.current` just became.
        if let blur = window.contentView as? NSVisualEffectView { PounceUI.applyChrome(blur) }

        // Record who had focus before we steal it, so an auto-paste commit can
        // hand focus back and ⌘V into the right app. Skip our own process so a
        // stale activation can't capture pounce itself. Keyed on "we have nobody"
        // rather than on `fresh`: a `.linger` commit hands focus back and nils
        // this, so a step presenting into that still-visible window would
        // otherwise have nowhere to paste — while a chained step, which never
        // let go, keeps the app it captured on the way in.
        if capturedApp == nil {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != NSRunningApplication.current.processIdentifier {
                capturedApp = front
            }
        }

        if fresh {
            // First appear: size + position instantly (nothing to animate from).
            // Force layout first so fittingSize reflects the content the caller
            // JUST reset/loaded, not whatever taller view (e.g. clipboard
            // history) was rendered last time the window was up. Without this the
            // window opens at the stale height for one frame before the deferred
            // resizeToFit snaps it down — the flash you see going from a big
            // window (clipboard) back to the empty launcher bar.
            hosting.layoutSubtreeIfNeeded()
            let height = state.pendingContentHeight ?? hosting.fittingSize.height
            state.pendingContentHeight = nil
            let target = NSSize(width: state.targetWidth, height: height)
            window.setContentSize(target)
            positionFresh(size: target)
            hosting.frame = window.contentView?.bounds ?? .zero
        }
        // Non-fresh (window already up, e.g. swapping step 2 into the live window):
        // leave the current size; the deferred resizeToFit snaps it to the new mode.

        // Hold the incoming content dark until the deferred pass has sized it and
        // SwiftUI has painted it, then reveal it fully-formed in one step. present()
        // runs synchronously right after state.reset()/load(), but SwiftUI hasn't
        // reconciled the displayMode swap yet, so any size read now can still report
        // the PREVIOUS view. Showing content before the async correction lands is
        // what flashed — either the stale oversized W×H (fresh open) or the new grid
        // mid-resize/mid-reconcile (step swap). FRESH gates the whole WINDOW (it has
        // to reposition too); a non-fresh step swap gates just the CONTENT so the
        // panel chrome stays put underneath.
        window.alphaValue = fresh ? 0 : 1
        if !fresh { hosting.alphaValue = 0 }
        state.isVisible = true

        window.makeKeyAndOrderFront(nil)
        // Re-activate on a submenu step swap too, not only on a fresh open. A
        // two-step command presents its next step into the already-visible window
        // (fresh == false) via a nested `pounce` invocation, but the app can lose
        // frontmost between steps (the prior step's client process exits and macOS
        // hands activation back to whatever was behind us) — leaving the window
        // ordered-front yet not key, so keystrokes go to the app behind. Guarding
        // on !NSApp.isActive restores focus on a swap without churning activation
        // when we're already frontmost (e.g. a per-keystroke content refresh).
        if fresh || !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let tf = state.textField { window.makeFirstResponder(tf) }

        // One runloop tick later SwiftUI has reconciled the new mode: size to it and
        // unveil crisply, in a single step (no frame tween → no shear; no crossfade
        // → no low-contrast header lagging the grid). resizeToFit reveals the
        // content; a fresh open also lifts the window veil once it's positioned.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.resizeToFit()
            // Unconditional, not `if fresh`. A fresh open needs it because the
            // window was held dark until it was positioned — but a present that
            // INTERRUPTED a fade is by construction non-fresh (the fade never
            // ordered the window out), and if that interrupt failed to take,
            // this is the only line left that can put the alpha back. Costs a
            // redundant assignment on the swap path; the alternative costs a
            // window that is ordered in, laid out, key and invisible.
            self.window.alphaValue = 1
        }
    }

    // Match the window height to the SwiftUI content, anchoring the top edge so
    // the list grows/shrinks downward as the query filters it. Always a crisp,
    // instant snap — both typing-driven filtering AND mode swaps (launcher →
    // emoji/clipboard). We never tween the frame: an animated setFrame runs an
    // implicit animation on the content layer that scales/shears the just-rendered
    // grid mid-flight — the "sheared panel" jank — and morphing geometry between
    // two unrelated layouts is the wrong metaphor anyway. A step swap instead hides
    // its content in present() and this reveals it, so the change is one clean cut.
    func resizeToFit() {
        guard window.isVisible else { return }
        // Prefer the view's EXACT computed height (the launcher stashes it in
        // state.pendingContentHeight); only fall back to measuring the hosting
        // view when no exact height is on offer (command/cheatsheet views). The
        // exact path needs no layout pass and — crucially — no fittingSize read,
        // which is what lets the launcher resize correctly in the same turn on
        // Tahoe. Consume it so a later measure-path call doesn't reuse a stale one.
        let h: CGFloat
        if let exact = state.pendingContentHeight {
            state.pendingContentHeight = nil
            h = exact
        } else {
            hosting.layoutSubtreeIfNeeded()
            h = hosting.fittingSize.height
        }
        let w = state.targetWidth
        if h > 1, abs(h - window.frame.height) > 0.5 || abs(w - window.frame.width) > 0.5 {
            let oldTop = window.frame.maxY
            var f = window.frame
            f.size.height = h
            f.size.width = w
            f.origin.y = oldTop - h          // anchor the top edge; grow/shrink downward
            if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
                f.origin.x = vf.midX - w / 2  // keep centered if the width changed
            }
            // Commit the frame + hosting bounds atomically with implicit animation
            // off, so nothing (blur material, content layer) tweens/flickers through
            // the resize.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(f, display: true)
            hosting.frame = window.contentView?.bounds ?? .zero
            CATransaction.commit()
        }
        // Content is now sized and laid out — unveil it in one step (a no-op unless
        // a step swap hid it in present()). Instant, never a fade: a crossfade would
        // expose the low-contrast search header lagging the emoji grid for a frame.
        if hosting.alphaValue != 1 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosting.alphaValue = 1
            CATransaction.commit()
        }
    }

    private func positionFresh(size: NSSize) {
        guard let vf = (NSScreen.main ?? window.screen)?.visibleFrame else { window.center(); return }
        let x = vf.midX - size.width / 2
        let topInset = vf.height * state.metrics.topInsetFraction
        let y = vf.maxY - topInset - size.height
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Commit handling

    private func handleCommit(_ commit: Commit) {
        // Whether WE still own focus at the moment of dismissal. Esc/↵ arrive
        // while the window is key; a click into another app arrives via
        // didResignKey AFTER that app took focus — there, handing focus back
        // would undo the user's click.
        let wasKey = window.isKeyWindow

        // Every way out of the camera peek (↵, Esc, click-away) commits through
        // here — release the camera the moment the window goes, not at the next
        // request's reset().
        if state.displayMode == .camera { CameraController.shared.stop() }

        if let app = commit.appLaunch {
            let url = URL(fileURLWithPath: app.path)
            if app.reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
        }

        // Find Files: open the hit in its default app, or reveal it in Finder.
        // NSWorkspace.open (not openApplication) is the document path; reveal
        // reuses the same file-viewer call app-reveal uses.
        if let f = commit.fileOpen {
            let url = URL(fileURLWithPath: f.path)
            if f.reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url)
            }
        }

        // A Shortcuts-library entry: spawned, never waited on (see
        // ShortcutsStore.run). Deliberately NOT added to the refocus exclusions
        // below — unlike an app launch, running a shortcut usually takes no
        // focus, so the app you summoned pounce from should get it back.
        if let id = commit.shortcutRun { ShortcutsStore.run(id: id) }

        // A System Settings pane or one setting inside it. The anchor after `?`
        // is what scrolls it to (say) Full Disk Access rather than the top of
        // Privacy & Security — see SystemSettings.swift.
        if let link = commit.settingOpen {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                NSLog("pounce daemon: '\(link)' is not a URL; settings row ignored")
            }
        }

        resultSink?(commit.clientString ?? "")

        switch commit.disposition {
        case .hideNow:
            state.isVisible = false
            hideNow()
            if commit.pasteAfter {
                restoreFocusAndPaste()
            } else if commit.appLaunch == nil && commit.fileOpen == nil
                        && commit.settingOpen == nil {
                refocusCaptured(wasKey: wasKey)
            } else {
                capturedApp = nil   // the launched app / file / Finder / System Settings takes focus
            }
        case .linger:
            state.isVisible = false
            // Hand focus back right away, before the fade: if the committed
            // command goes on to open/activate something, that later
            // activation simply wins.
            refocusCaptured(wasKey: wasKey)
            startLinger()
        case .loading:
            // Keep the window up (and key, so click-away still cancels) until the
            // two-step command's step 2 calls present() and swaps the content in.
            startLoading()
        }
    }

    // MARK: Hide / linger / loading

    func hideNow() {
        cancelLinger()
        _ = abortFade()
        window.orderOut(nil)
    }

    // Raycast-style focus restore: on dismissal (Esc, ↵ on a copy-style
    // action) hand focus back to the app pounce stole it from. wasKey=false
    // means the user dismissed by clicking into another app — that app owns
    // focus now, leave it alone.
    private func refocusCaptured(wasKey: Bool) {
        defer { capturedApp = nil }
        guard wasKey, let app = capturedApp, !app.isTerminated else { return }
        // DIAGNOSTIC (fn+Esc/native-picker race)
        NSLog("pounce DIAG: refocusCaptured activating \(app.bundleIdentifier ?? "?") at \(Date())")
        app.activate(options: [.activateIgnoringOtherApps])
    }

    // Hand focus back to the app that was frontmost before pounce appeared, then
    // synthesize ⌘V once it's active. The small delay lets the activation settle
    // so the keystroke lands in the target app rather than the just-hidden window.
    private func restoreFocusAndPaste() {
        guard let app = capturedApp else { capturedApp = nil; return }
        capturedApp = nil
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Paste.sendCommandV()
        }
    }

    private func startLinger() {
        cancelLinger()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        lingerItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // Show the skeleton after a short grace period (so fast sub-commands swap
    // with no flash), and fall back to fading out if step 2 never arrives. We do
    // NOT resize here — the skeleton fills the window at its current (step 1)
    // height, so there's no arbitrary intermediary height; the single animated
    // resize happens only when step 2's real content lands.
    private func startLoading() {
        cancelLinger()
        let show = DispatchWorkItem { [weak self] in self?.state.isLoading = true }
        spinnerItem = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: show)

        let fallback = DispatchWorkItem { [weak self] in
            self?.state.isLoading = false
            self?.fadeOut()
        }
        lingerItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: fallback)
    }

    private func cancelLinger() {
        lingerItem?.cancel()
        lingerItem = nil
        spinnerItem?.cancel()
        spinnerItem = nil
    }

    private func fadeOut() {
        fadeToken &+= 1
        let token = fadeToken
        fading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A fade present() has since disowned owns nothing: the window it was
            // told to put away is showing the NEXT step's content.
            guard let self = self, self.fadeToken == token else { return }
            self.fading = false
            NSLog("pounce DIAG: faded out")
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.capturedApp = nil
        })
    }

    // Stop a fade mid-flight and disown its completion handler; answers whether
    // there was one, for the diagnostic.
    //
    // Three ways of saying "alpha is 1", because each covers a hole the others
    // leave and the failure they guard against is the very bug this fixes — a
    // window ordered in, laid out, key and fully TRANSPARENT, which reads from
    // the outside exactly like the vanished one. A plain `window.alphaValue = 1`
    // is not enough on its own: NSWindow's animator drives that property on its
    // own timer and takes it straight back down on the next tick. Whether a
    // ZERO-DURATION animator call actually stops an in-flight window animation
    // is undocumented (duration 0 is also the one value AppKit may short-circuit
    // to a direct set — i.e. possibly the path that doesn't take), so it is not
    // trusted alone either. The deferred re-assert is what closes it: by then
    // the interrupted fade's own 0.12 s has elapsed, so whatever the first two
    // did, this one sticks — unless a NEW fade has legitimately begun since,
    // which the token and `fading` both rule out.
    @discardableResult
    private func abortFade() -> Bool {
        guard fading else { return false }
        fading = false
        fadeToken &+= 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            window.animator().alphaValue = 1
        }
        window.alphaValue = 1
        let token = fadeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.fadeToken == token, !self.fading,
                  self.window.isVisible, self.window.alphaValue < 1 else { return }
            NSLog("pounce DIAG: re-asserted alpha after an interrupted fade")
            self.window.alphaValue = 1
        }
        return true
    }
}
