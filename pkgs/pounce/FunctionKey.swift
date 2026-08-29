import AppKit
import Carbon

// MARK: - Fn / Globe key binding

// Fn is a modifier, not an ordinary key, so Carbon's RegisterEventHotKey cannot
// bind it. A configured `"hotkey": "fn"` therefore takes the same session
// event-tap path as the window switcher (and the same Accessibility grant).
//
// Fire on RELEASE, not press: that is the only point where we know Fn was
// tapped alone. If another keyboard event arrives while it is held, this tap
// leaves that event untouched and suppresses only Fn's own flag transitions —
// the hardware-produced Fn combination still reaches the frontmost app, while
// a lone tap fires pounce's binding.
//
// That suppression only covers the ordinary flagsChanged CGEvent this tap
// watches. macOS's own Globe action reads Fn through a private per-app HUD
// controller (TUINSCursorUIController / TextInputUI.framework) that no tap
// sees, so while "Press 🌐 key to" is anything but Do Nothing the SAME tap
// can also open the native Character Viewer — a plain ~100ms tap does it,
// not just a held press: log capture shows CharacterPalette's "First
// activateServer" landing 15ms after a DIAG "fn up -> FIRE" line from this
// tap. And once it fires, the Character Palette latches onto the frontmost
// app, so it re-shows on every later app switch, which is why the symptom
// gets misread as ⌘Tab spawning the picker. No CGEventTap placement
// suppresses that path; `pounce doctor` flags the system setting instead
// (see hausfold.co/docs/pounce/config, "The Fn/Globe key").
final class FunctionKeyHotKey {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gesture = FunctionKeyGesture()
    private let onFire: () -> Void

    static func matches(_ name: String) -> Bool {
        ["fn", "function", "globe"].contains(name.lowercased())
    }

    init?(onFire: @escaping () -> Void) {
        self.onFire = onFire

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<FunctionKeyHotKey>.fromOpaque(refcon).takeUnretainedValue()
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // DIAGNOSTIC (fn+Esc/native-picker race, see AGENTS/task notes): if
            // this ever logs, the tap was off for some stretch of real time —
            // any fn transition (ours or a stray one) in that gap went straight
            // to macOS's own Globe handling, unsuppressed.
            NSLog("pounce DIAG: fn tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "userInput")), re-enabling at \(Date())")
            gesture.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == kVK_Function else {
                gesture.noteOtherKeyboardEvent()
                return Unmanaged.passUnretained(event)
            }

            let nowDown = event.flags.contains(.maskSecondaryFn)
            let shouldFire = gesture.functionFlagsChanged(isDown: nowDown)
            // DIAGNOSTIC: every fn transition this tap sees, and whether it
            // decided to fire pounce's menu.
            NSLog("pounce DIAG: fn \(nowDown ? "down" : "up") at \(Date())\(shouldFire ? " -> FIRE" : "")")
            // Presenting a mode can do layout and disk reads. Leave the tap
            // callback first so macOS never disables it for taking too long.
            if shouldFire { DispatchQueue.main.async { self.onFire() } }
            // Own Fn's transitions while configured. That stops anything
            // downstream of this tap from seeing Fn at all, but NOT macOS's own
            // Globe action, which never looks at this event stream (see the
            // header). Other events in an Fn chord pass.
            return nil

        case .keyDown, .keyUp:
            gesture.noteOtherKeyboardEvent()
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
