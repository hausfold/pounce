import AppKit

// MARK: - Mouse chords (modifier + click → an action on the window you clicked)

// The pointer half of window management. A tiling WM binds keys and acts on the
// FOCUSED window; a mouse chord acts on the window under the POINTER, which is
// the whole point — you can zoom a window on the other monitor without going
// there first.
//
// Why this lives in pounce and not in the WM: AeroSpace has no mouse bindings at
// all, and Ghostty's keybind triggers are keys or Unicode codepoints — neither
// can fire on a click (measured on Ghostty 1.3.1: `+list-actions` has
// `toggle_fullscreen`, but nothing to trigger it from the mouse). A consuming
// CGEventTap is the only mechanism on macOS that can, and pounce already runs
// two of them (Switcher.swift, AppScoped.swift) behind the Accessibility grant
// they need — so the marginal cost here is one more tap, not one more daemon
// with its own TCC story.
//
// Same constraints as those two: the callback runs on the main run loop and
// must return in well under a second or macOS disables the tap; taps go deaf
// during Secure Input (events then flow through unmodified — a self-healing
// fallback); installation needs Accessibility, so DaemonMode arms and disarms
// this from the same grant watcher.
//
// The window under the pointer is resolved from the WindowServer's own list
// (`CGWindowListCopyWindowInfo`) rather than by AX-hit-testing the app, because
// the AX route is a synchronous round trip into whatever app you clicked — and
// the one app that would stall it is the busy one you clicked BECAUSE it was
// busy. The window list is a single WindowServer call with no app in the loop,
// and its `kCGWindowNumber` is the same CGWindowID `aerospace --window-id`
// takes (verified against `aerospace list-windows --all --format
// '%{window-id}'`; both are the id `_AXUIElementGetWindow` returns).
final class MouseChords {
    private struct Chord {
        let button: MouseChordsSettings.Button
        let flags: CGEventFlags
        let action: MouseChordsSettings.Action
    }

    private var chords: [Chord] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Set when a down was swallowed, so the matching drag/up can be swallowed
    // too. Keyed on the button rather than on the modifiers: releasing ⌥ before
    // the mouse button is ordinary, and an up that reached the app without its
    // down is exactly the unpaired event that leaves a text view stuck in a
    // selection drag.
    private var swallowing: MouseChordsSettings.Button?

    init?(settings: MouseChordsSettings) {
        guard settings.enabled else { return nil }

        chords = settings.chords.compactMap { entry in
            let flags = WindowSwitcher.eventFlags(for: entry.modifiers)
            guard !flags.isEmpty else {
                // A bare click chord would swallow every click on the machine —
                // including the ones you'd need to fix the config. Same refusal
                // AppScoped.swift makes for a modifier-less key.
                NSLog("pounce mouseChords: refusing '\(entry.button.rawValue)' without a modifier")
                return nil
            }
            return Chord(button: entry.button, flags: flags, action: entry.action)
        }
        guard !chords.isEmpty else { return nil }

        // Only the buttons actually bound are watched. An unconfigured button
        // never enters the callback at all, which is the cheapest possible
        // answer for the clicks this feature has no opinion about.
        var mask: CGEventMask = 0
        for button in Set(chords.map(\.button)) {
            for type in button.eventTypes { mask |= (1 << type.rawValue) }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseChords>.fromOpaque(refcon).takeUnretainedValue()
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
            swallowing = nil
            return Unmanaged.passUnretained(event)

        case .leftMouseUp, .rightMouseUp:
            let button: MouseChordsSettings.Button = (type == .leftMouseUp) ? .left : .right
            if swallowing == button { swallowing = nil; return nil }
            return Unmanaged.passUnretained(event)

        case .leftMouseDragged, .rightMouseDragged:
            let button: MouseChordsSettings.Button = (type == .leftMouseDragged) ? .left : .right
            return swallowing == button ? nil : Unmanaged.passUnretained(event)

        case .leftMouseDown, .rightMouseDown:
            let button: MouseChordsSettings.Button = (type == .leftMouseDown) ? .left : .right
            let held = event.flags.intersection(Self.relevantFlags)
            // Exact match, so ⌥⇧-click keeps whatever it meant — the same
            // discipline the key chords use.
            guard let hit = chords.first(where: { $0.button == button && $0.flags == held })
            else { return Unmanaged.passUnretained(event) }

            // Nothing under the pointer but the desktop: pass it through rather
            // than eating it, so ⌥-right-click on the wallpaper still gets
            // Finder's menu.
            guard let windowID = Self.window(at: event.location) else {
                return Unmanaged.passUnretained(event)
            }

            // Off the tap path: two subprocess spawns have no business in a
            // callback that macOS times out.
            let action = hit.action
            DispatchQueue.main.async { Self.perform(action, on: windowID) }
            swallowing = button
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: Hit test

    // The frontmost ordinary window containing `point`, or nil for the desktop.
    //
    // Layer 0 is the filter that matters: it is where ordinary app windows live,
    // so menu-bar extras, the Dock, SketchyBar and any notch shelf — all drawn
    // above it — are transparent to the chord rather than being "clicked". The
    // list comes back front-to-back, so the first containment wins with no
    // depth comparison of our own.
    //
    // Both coordinate systems here are CG global (origin at the top-left of the
    // main display): `CGEvent.location` and `kCGWindowBounds` agree natively, so
    // there is no NSScreen flip to get wrong.
    private static func window(at point: CGPoint) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary
            else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &rect),
                  rect.contains(point) else { continue }
            return CGWindowID(number)
        }
        return nil
    }

    // MARK: Actions

    private static func perform(_ action: MouseChordsSettings.Action, on windowID: CGWindowID) {
        switch action {
        case .fullscreen:
            // Focus first, then zoom. Both name the window explicitly, so
            // neither depends on the other having landed — the order is for the
            // eye, not for correctness. Focusing is not optional though: a
            // window zoomed to fill a workspace you aren't in is a screenful of
            // something you can't type into.
            Aerospace.focus(windowID: windowID) { _ in
                Aerospace.fullscreen(windowID: windowID)
            }
        }
    }
}
