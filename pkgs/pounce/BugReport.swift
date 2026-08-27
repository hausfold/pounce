import Foundation

// MARK: - pounce report
//
// The in-product door to pounce's bug form: the palette's *Report a Bug* row,
// the settings window's app menu, and `pounce report`, which are one shape by
// three routes.
//
// There is no telemetry in anything we ship and there never will be, so the
// issue form is not one feedback channel among several — it is the only one
// (workshop docs/bug-reports.md). And the form's third field asks the reporter
// to run `pounce doctor` and paste the output, which is two steps in which a
// report gets lost and a third in which it arrives truncated because a terminal
// scrolled. pounce can just answer it.
//
// Foundation only, no AppKit: tests/run.sh compiles the pure sources with a
// plain `xcrun swiftc`, so everything decidable without a window lives here and
// the one call that needs NSWorkspace lives in Entry.swift's ReportMode.
enum BugReport {
    static let repository = "hausfold/pounce"
    static let formURL = "https://github.com/\(repository)/issues/new"

    /// Above this, drop the prefill — the block goes to stdout instead and the
    /// form opens empty. GitHub serves a URL of roughly 8 KB and refuses past
    /// it; the margin covers the rest of the query.
    ///
    /// Unlike perch's and trill's, this one is a LIVE path, not a guard rail:
    /// `pounce doctor` grows a line per binding and per scoped command, so a
    /// palette with thirty bindings can genuinely overrun it.
    static let maximumURLLength = 6000

    // MARK: The block

    /// Pure, so the shape is pinned by a test rather than by reading it.
    static func diagnostics(
        version: String,
        operatingSystem: String,
        model: String,
        install: String,
        doctor: String,
        home: String
    ) -> String {
        let header = """
            pounce \(version)
            macOS \(operatingSystem)
            \(model)
            installed: \(install)
            """
        return "\(header)\n\n\(redactingHome(doctor, home: home))"
    }

    /// The home directory, written back as `~`.
    ///
    /// `pounce doctor` names real paths — `pages.mruFile`, a command dir, a
    /// hotkey tool's config — and every one of them starts with the reporter's
    /// name. In a terminal that is fine: they typed the command and they are
    /// reading their own screen. In a field the app filled in for them, on its
    /// way to a public issue, it is a username we put there. `~` says the same
    /// thing to whoever reads the report.
    ///
    /// Longest-first is not needed (one needle), but the guard is: an empty or
    /// `/` home would rewrite every path in the report to nonsense.
    static func redactingHome(_ text: String, home: String) -> String {
        guard home.count > 1, home != "/" else { return text }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return text.replacingOccurrences(of: trimmed, with: "~")
    }

    /// What `installed:` says. Deliberately the reporter-facing word for each
    /// cohort rather than the enum case — "rice" is our vocabulary and this
    /// line is read by someone who has never heard it.
    static func describe(_ kind: InstallKind) -> String {
        switch kind {
        case .homebrew: return "Homebrew"
        case .direct:   return "dragged to /Applications"
        case .rice:     return "the haus desktop"
        case .nix:      return "Nix store"
        case .unknown:  return "somewhere else"
        }
    }

    /// `26.0.1 (25A354)` — the pair Apple's own bug reports ask for, because a
    /// build number tells apart two OSes that answer the same to a user.
    static var currentOperatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        guard let build = sysctl("kern.osversion") else { return short }
        return "\(short) (\(build))"
    }

    /// `Mac16,10`. The marketing name reads better and needs a round trip to
    /// Apple to get, so this is the identifier — which is what a maintainer
    /// looks up anyway.
    static var currentModel: String { sysctl("hw.model") ?? "unknown Mac" }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl reports the length *including* the NUL, which would otherwise
        // ride along as a U+0000 on the end of the identifier.
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    // MARK: The URL

    /// Where the door goes, and whether the block was too long to ride in it.
    struct Destination: Equatable {
        var url: URL
        /// Non-nil when the block didn't fit: the caller says so rather than
        /// opening a form with a field it silently declined to fill.
        var overflow: String?
    }

    /// Pure, so the encoding and the length guard are testable without opening
    /// anything.
    ///
    /// Two things here are easy to get wrong and neither one fails loudly:
    ///
    /// `?template=bug.yml`, not `?title=&body=`. A `body=` prefill opens
    /// GitHub's **blank** editor and walks straight past the designed form — its
    /// fields, its "wrong repo? file it anyway" preamble, the labels it
    /// applies. The reporter just never sees any of it. (The palette's
    /// report-issue command did exactly that from before the forms existed
    /// until this landed.)
    ///
    /// Strict percent-encoding, not `URLComponents.queryItems`, which encodes
    /// with `CharacterSet.urlQueryAllowed` — a set that CONTAINS `+`, so it
    /// leaves it literal and the receiving server reads it back as a space.
    /// `pounce doctor` prints `cmd+space` on almost every line it draws, so
    /// this is the repo where that bug would actually have shown up.
    static func destination(diagnostics: String) -> Destination {
        let short = "\(formURL)?template=bug.yml"
        let full = "\(short)&diagnostics=\(percentEncoded(diagnostics))"

        if full.count <= maximumURLLength, let url = URL(string: full) {
            return Destination(url: url, overflow: nil)
        }
        // Unreachable via `URL(string:)` failing — the short form is a literal —
        // but a door that can silently do nothing is worse than one that opens
        // the repo's Issues tab.
        guard let url = URL(string: short) else {
            return Destination(url: URL(string: "https://github.com/\(repository)/issues")!, overflow: diagnostics)
        }
        return Destination(url: url, overflow: diagnostics)
    }

    /// RFC 3986 unreserved passes; everything else is percent-encoded, UTF-8
    /// byte by byte. See `destination(diagnostics:)` for why this isn't
    /// `addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`.
    static func percentEncoded(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,  // A-Z a-z 0-9
                 0x2D, 0x2E, 0x5F, 0x7E:                 // - . _ ~
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}
