import Foundation

// What `"fontFamily"` in config.json actually resolves to — the pure half of
// `AppFont`, kept Foundation-only so `tests/run.sh` can pin it.
//
// There is one trap in here and it is the whole reason this is a function
// rather than an `if !isEmpty`. A desktop generating the config writes the
// family it was told to use, and the usual default IS macOS's own —
// `Font.custom(".AppleSystemUIFont", …)` works, and freezes the weight and
// optical size SwiftUI picks per size, so "I left it at the default" would
// render subtly unlike leaving the key out. Naming the system font has to give
// you the system font.
enum FontFamily {
    /// nil means "SwiftUI's own `.system(…)`": absent, empty, blank, or one of
    /// the names macOS's UI family answers to.
    static func resolve(_ configured: String?) -> String? {
        guard let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !systemNames.contains(trimmed.lowercased())
        else { return nil }
        return trimmed
    }

    static let systemNames: Set<String> = [
        ".applesystemuifont", "applesystemuifont", ".sf ns",
        "system", "system font", "-apple-system",
    ]
}
