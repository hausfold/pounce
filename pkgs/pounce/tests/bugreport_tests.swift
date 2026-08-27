// The bug-report door (BugReport.swift): the URL the palette row, the settings
// menu and `pounce report` all end at, and the block that rides in it.
//
// Everything here fails SILENTLY in production if it's wrong — a form still
// opens, an issue can still be filed, and nobody finds out for a year that the
// form wasn't the one we designed or that half the paths in it were rewritten
// into nonsense. That is the whole reason these exist.

import Foundation

func runBugReportTests() -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }
    func expectEqual(_ a: String, _ b: String, _ message: String) {
        expect(a == b, "\(message)\n  got:  \(a)\n  want: \(b)")
    }

    // MARK: The template is the point
    //
    // `?body=` opens GitHub's BLANK editor and walks past bug.yml — its fields,
    // its "wrong repo? file it anyway" preamble, its labels. This row shipped
    // that version for a year before the door landed.

    let plain = BugReport.destination(diagnostics: "pounce dev")
    expect(plain.url.absoluteString.contains("template=bug.yml"),
           "the URL must name the template, or it opens a blank issue")
    expect(plain.overflow == nil, "a short block rides in the query")

    func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }
    expectEqual(queryValue(plain.url, "diagnostics") ?? "", "pounce dev",
                "the block comes back out of the query unchanged")

    // MARK: Encoding
    //
    // `URLComponents.queryItems` encodes with CharacterSet.urlQueryAllowed,
    // which CONTAINS `+` — it leaves it literal and the far end decodes it as a
    // SPACE. `pounce doctor` prints `cmd+space` on nearly every line, so this
    // is the repo where that bug would really have shown up.

    let plussed = BugReport.destination(diagnostics: "hotkey cmd+space registered").url.absoluteString
    expect(plussed.contains("cmd%2Bspace"), "a `+` must be encoded: \(plussed)")
    expect(!plussed.contains("cmd+space"), "a literal `+` arrives as a space: \(plussed)")

    let ampersanded = BugReport.destination(diagnostics: "a&template=nope").url
    expectEqual(queryValue(ampersanded, "template") ?? "", "bug.yml",
                "a `&` in the block must not start a second parameter")
    expectEqual(queryValue(ampersanded, "diagnostics") ?? "", "a&template=nope",
                "…and the block keeps its ampersand")

    let unicode = "✔ daemon running\n▶ Healthy."
    expectEqual(queryValue(BugReport.destination(diagnostics: unicode).url, "diagnostics") ?? "",
                unicode, "doctor's glyphs and newlines survive the round trip")

    // MARK: The length guard
    //
    // A live path here, unlike perch and trill: doctor grows a line per binding
    // and per scoped command, so a busy palette really can overrun the URL.

    let huge = String(repeating: "x", count: BugReport.maximumURLLength + 1)
    let overflowed = BugReport.destination(diagnostics: huge)
    expect(overflowed.overflow == huge, "an over-long block is handed back to the caller")
    expect(overflowed.url.absoluteString.count <= BugReport.maximumURLLength,
           "…and the URL that opens instead is short")
    expect(overflowed.url.absoluteString.contains("template=bug.yml"),
           "…and still lands on the form, not a blank issue")
    expect(queryValue(overflowed.url, "diagnostics") == nil,
           "…with no half-written diagnostics field")

    // MARK: Redacting the home directory
    //
    // doctor names real paths and every one of them starts with the reporter's
    // name. In a terminal that's their own screen. Prefilled into a public
    // issue it's a username we put there.

    expectEqual(
        BugReport.redactingHome("  ✔ read /Users/ada/.config/pounce/commands", home: "/Users/ada"),
        "  ✔ read ~/.config/pounce/commands",
        "the home directory is written back as ~")
    expectEqual(
        BugReport.redactingHome("/Users/ada/x and /Users/ada/y", home: "/Users/ada/"),
        "~/x and ~/y",
        "a trailing slash on home doesn't leave a double slash behind")
    expectEqual(
        BugReport.redactingHome("/Users/ada/x", home: "/"),
        "/Users/ada/x",
        "a `/` home would rewrite every path in the report — refuse it")
    expectEqual(
        BugReport.redactingHome("/Users/ada/x", home: ""),
        "/Users/ada/x",
        "…same for an empty one")

    // MARK: The block

    let block = BugReport.diagnostics(
        version: "2026.08.09-2",
        operatingSystem: "26.0.1 (25A354)",
        model: "Mac16,10",
        install: "Homebrew",
        doctor: "pounce doctor\n\n  ✔ daemon running — version 2026.08.09-2\n  ✔ read /Users/ada/.config",
        home: "/Users/ada")
    expectEqual(block, """
        pounce 2026.08.09-2
        macOS 26.0.1 (25A354)
        Mac16,10
        installed: Homebrew

        pounce doctor

          ✔ daemon running — version 2026.08.09-2
          ✔ read ~/.config
        """, "the header sits above the doctor report, with home redacted")

    // MARK: The install cohort, in the reporter's words
    //
    // "rice" is our vocabulary and this line is read by someone who has never
    // heard it — the same rule the Task form's title follows (workshop
    // docs/bug-reports.md: internal vocabulary is free in a comment and
    // expensive in a form).

    expectEqual(BugReport.describe(.rice), "the haus desktop", "no internal vocabulary in the block")
    for kind in [InstallKind.homebrew, .direct, .rice, .nix, .unknown] {
        expect(!BugReport.describe(kind).isEmpty, "every cohort has a wording")
        expect(BugReport.describe(kind) != "rice", "no cohort reports as `rice`")
    }

    if failures == 0 { print("ok — all bug-report door tests passed") }
    return failures
}
