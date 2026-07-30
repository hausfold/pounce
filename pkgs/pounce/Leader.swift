import AppKit
import Carbon

// MARK: - Leader sequences (⌥Space then E)

// A two-step binding needs to hear a bare, unmodified keypress — normally the
// job of a CGEventTap, which macOS gates behind Accessibility. Pounce's palette
// hotkey deliberately needs no TCC grant at all (that's why it's Carbon and not
// a tap, see HotKey.swift), and a leader sequence must not quietly cost one.
//
// So it doesn't use a tap. RegisterEventHotKey accepts a MODIFIER-LESS
// registration, and several at once — so when a leader fires we register that
// node's second-step keys as ordinary global hotkeys, and unregister them the
// moment one fires, the sequence is abandoned, or the timeout expires. The bare
// keys are ours for ~2 seconds and nobody else's ever.
//
// Consequences that follow from that, and are the reason for every guard below:
//   * while armed, those keys are swallowed system-wide — so the window is
//     short, Escape always cancels, and any registration failure disarms the
//     whole step rather than leaving a half-armed state;
//   * the transient registrations live in their OWN HotKeyManager (with its own
//     Carbon signature), so disarming can never touch the permanent bindings.
final class LeaderRunner {
    // How long a leader stays armed before giving the keys back. Long enough to
    // think, short enough that a misfire costs one keystroke, not a sentence.
    static let timeout: TimeInterval = 2.0
    // A leader shows its available next keys only if you HESITATE — press
    // through quickly and no window ever appears (which-key style). Below this,
    // the sequence is muscle memory and an overlay would just flash.
    static let hintDelay: TimeInterval = 0.45

    private let transient = HotKeyManager(signature: 0x504F_5553)   // 'POUS'
    private var timeout: Timer?
    private var hint: Timer?
    private var armedNode: HotKeyNode?

    private let onRun: (String) -> Void
    private let onHint: (HotKeyNode) -> Void
    private let onDismissHint: () -> Void

    // `onRun` receives an item key ("cmd:emoji"); `onHint`/`onDismissHint` drive
    // the which-key overlay. All three are called on the main thread — Carbon
    // delivers hotkey events there and the timers are scheduled on it.
    init(onRun: @escaping (String) -> Void,
         onHint: @escaping (HotKeyNode) -> Void,
         onDismissHint: @escaping () -> Void) {
        self.onRun = onRun
        self.onHint = onHint
        self.onDismissHint = onDismissHint
    }

    var isArmed: Bool { armedNode != nil }

    // Grab `node`'s child steps. Called when a leader (or an intermediate step
    // of a longer sequence) fires.
    func arm(_ node: HotKeyNode) {
        disarm()
        guard !node.children.isEmpty else { return }

        var registered = 0
        for child in node.sortedChildren {
            guard let step = child.step,
                  let keyCode = HotKeyParser.keyCode(for: step.key) else {
                NSLog("pounce daemon: leader step '\(child.step?.display ?? "?")' uses an unknown key; that branch is unreachable")
                continue
            }
            let modifiers = HotKeyParser.modifierMask(for: step.modifiers)
            if transient.register(keyCode: keyCode, modifiers: modifiers,
                                  onFire: { [weak self] in self?.advance(to: child) }) {
                registered += 1
            } else {
                NSLog("pounce daemon: leader could not grab '\(step.display)' (another app holds it); that branch won't fire this time")
            }
        }

        // Nothing armed → don't hold the keyboard hostage waiting for a key that
        // can never arrive.
        guard registered > 0 else { disarm(); return }

        // Escape always backs out. Registered last and only if the sequence
        // doesn't bind it itself, so a user who really wants Escape as a step
        // keeps it.
        if node.children["escape"] == nil {
            transient.register(keyCode: UInt32(kVK_Escape), modifiers: 0,
                               onFire: { [weak self] in self?.disarm() })
        }

        armedNode = node
        timeout = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            self?.disarm()
        }
        hint = Timer.scheduledTimer(withTimeInterval: Self.hintDelay, repeats: false) { [weak self] _ in
            guard let self, let armed = self.armedNode else { return }
            self.onHint(armed)
        }
    }

    // Dry-run the grab: register this node's child steps, count what took, and
    // release them immediately. Called once per leader at startup so the novel
    // risk in this design — a bare second-step key that some other app holds
    // permanently, which would silently kill that one branch — is visible in the
    // log and in `pounce doctor` instead of only when you press the key.
    //
    // Holds the keys for microseconds and installs no timers, so it can't affect
    // what the user is typing.
    func probe(_ node: HotKeyNode) -> (grabbed: Int, failed: [String]) {
        var grabbed = 0
        var failed: [String] = []
        for child in node.sortedChildren {
            guard let step = child.step,
                  let keyCode = HotKeyParser.keyCode(for: step.key) else {
                failed.append(child.step?.display ?? "?")
                continue
            }
            if transient.register(keyCode: keyCode,
                                  modifiers: HotKeyParser.modifierMask(for: step.modifiers),
                                  onFire: {}) {
                grabbed += 1
            } else {
                failed.append(step.display)
            }
        }
        transient.unregisterAll()
        return (grabbed, failed)
    }

    // A child step fired: either run its target or descend one level.
    private func advance(to node: HotKeyNode) {
        disarm()
        if let target = node.target {
            onRun(target)
        } else {
            arm(node)
        }
    }

    // Hand the keys back. Safe to call when nothing is armed.
    func disarm() {
        let wasArmed = armedNode != nil
        timeout?.invalidate(); timeout = nil
        hint?.invalidate(); hint = nil
        transient.unregisterAll()
        armedNode = nil
        if wasArmed { onDismissHint() }
    }
}

// MARK: - The which-key overlay

// Renders an armed node's next keys through the existing cheatsheet window —
// same model, same view, built in memory instead of read from JSON.
enum LeaderHint {
    // "cmd:emoji" → "Emoji", "mode:clipboard" → "Clipboard", so the overlay
    // reads as actions rather than as config keys. `resolve` supplies a
    // command's real name from the registry when there is one.
    static func groups(for node: HotKeyNode,
                       resolve: (String) -> String?) -> [CheatsheetGroup] {
        var items: [CheatsheetItem] = []
        for child in node.sortedChildren {
            guard let step = child.step else { continue }
            let action: String
            if let target = child.target {
                action = resolve(target) ?? label(for: target)
            } else {
                // An interior node — pressing this opens another level.
                action = "\u{2026} \(child.sortedChildren.count) more"
            }
            items.append(CheatsheetItem(key: step.display, action: action))
        }
        return [CheatsheetGroup(title: "Pounce", items: items, page: nil)]
    }

    // Fallback label when nothing better is known: strip the target's kind
    // prefix and tidy it up ("app:/Applications/Ghostty.app" → "Ghostty").
    static func label(for target: String) -> String {
        if target.hasPrefix("app:") {
            return (target.dropFirst(4) as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
        }
        if target.hasPrefix("mode:") { return String(target.dropFirst(5)).capitalized }
        if target.hasPrefix("cmd:") { return String(target.dropFirst(4)) }
        return target
    }
}
