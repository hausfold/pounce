import Foundation

// FontFamily.swift: what `"fontFamily"` in config.json resolves to before a
// `Font` exists.
//
// The `Font` half can't be pinned here (it needs SwiftUI, and this suite is a
// plain Foundation compile), but the half with a trap in it can: which names
// mean "macOS's own", which is the difference between a desktop's default
// rendering identically to no key at all and rendering subtly unlike it.
func runFontFamilyTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    check(FontFamily.resolve(nil) == nil, "no key means the system font")
    check(FontFamily.resolve("") == nil, "an empty string means the system font")
    check(FontFamily.resolve("   \n") == nil, "a blank string means the system font")

    // The case a desktop generating this file actually hits: it writes the
    // family it was configured with, and the usual default IS macOS's own.
    check(FontFamily.resolve(".AppleSystemUIFont") == nil,
          "macOS's own family, named, must give back the system font rather than a frozen copy of it")
    check(FontFamily.resolve(".applesystemuifont") == nil, "and case must not decide it")
    check(FontFamily.resolve("System") == nil, "nor must the spelling a person would type")
    check(FontFamily.resolve("-apple-system") == nil, "nor the CSS one")

    check(FontFamily.resolve("Atkinson Hyperlegible") == "Atkinson Hyperlegible",
          "a real family is passed through verbatim")
    check(FontFamily.resolve("iA Writer Quattro S") == "iA Writer Quattro S",
          "case is the font's business — CoreText matches it, pounce must not tidy it")
    check(FontFamily.resolve("  Inter \n") == "Inter",
          "a hand-edited file is where a stray space comes from, and \" Inter\" is nobody's family")

    if failures == 0 { print("ok — all font-family resolution tests passed") }
    return failures
}
