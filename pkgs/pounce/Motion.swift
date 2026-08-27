import SwiftUI
import AppKit

// MARK: - Motion

// ONE spring for everything in the palette that moves — the selection glide,
// the dial roll, the action-bar keycap's press blink. The design direction
// states it as a rule rather than a preference ("snappy is a physics constant,
// not a vibe"), which only holds if there is a single place to read it from:
// a second `.spring(response:…)` literal anywhere in the sources is the drift
// this enum exists to prevent.
//
// Deliberately NOT a config setting. The three motions below animate frames
// SwiftUI was already drawing — they cost no keystroke and there is nothing to
// tune — and the one dial a user genuinely has for this is the system's own,
// read below.
enum Motion {
    // The constant PR #111 established, now named once.
    static let response: Double = 0.25
    static let dampingFraction: Double = 0.85

    // nil under System Settings › Accessibility › Display › Reduce motion,
    // which turns every animation here back into exactly today's snap. A nil
    // Animation is not "skip the change": both `withAnimation(nil)` and
    // `.animation(nil, value:)` mean "apply it without one", so the palette
    // stays correct, just instant.
    static var spring: Animation? {
        reduceMotion ? nil : .spring(response: response, dampingFraction: dampingFraction)
    }

    // Cached, and refreshed from the notification — NOT read per use.
    //
    // `Motion.spring` is evaluated in every row's body, so a plain read of
    // NSWorkspace's property would run once per row per render, on the
    // keystroke path. It measures at ~5ns when its CFPreferences cache is warm,
    // but that cache is invalidated process-wide by anything that touches
    // preferences, and the read after that round-trips to cfprefsd — which is
    // I/O, on the one code path this repo refuses to put I/O on. Cached, it is
    // an ivar load and the question stops being interesting.
    //
    // Still LIVE, which is the reason for the observer rather than a one-shot
    // snapshot: the daemon outlives any number of trips to System Settings, and
    // a value frozen at launch would be wrong for the rest of the session.
    static var reduceMotion: Bool { ReduceMotionWatcher.shared.value }

    // How long a pressed keycap holds its lit state before springing back —
    // long enough to be a blink you can see, short enough to finish inside the
    // 0.4s linger that precedes the window's fade (PounceUI.startLinger).
    static let pressHold: TimeInterval = 0.09
}

private final class ReduceMotionWatcher {
    static let shared = ReduceMotionWatcher()
    private(set) var value: Bool

    // Built on first use (a Swift static is lazy and thread-safe), so a pounce
    // invocation that never draws a window never registers anything. Both the
    // initial read and every refresh happen on the main queue, which is also
    // the only place `value` is read from — SwiftUI bodies.
    private init() {
        value = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.value = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
    }
}
