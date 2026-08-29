// Renders an annotated config.json: every setting present, at its default, with
// a comment above it, and every setting commented out.
//
// The shape is AeroSpace's: its default config lists every setting at its
// default with a comment above, so you learn the surface by reading your own
// config and you make it minimal by deleting the lines you never touched. No
// doc-site round trip to find out what exists. Pounce had the same problem the
// haus desktop did — the settings were discoverable only in the reference, and
// you had to know a setting existed before you could look it up.
//
// THREE THINGS ABOUT JSON MAKE THIS FIDDLIER THAN THE NIX VERSION, and all three
// are why `Settings.load()` parses with `.json5Allowed`:
//
//   1. JSON has no comments. Without them the annotated file could not be the
//      file pounce reads, and you'd be copying lines between two files.
//   2. Section objects have to be REAL, not commented, or uncommenting a leaf
//      inside them does nothing. So `"clipboard": { }` is written out empty and
//      its children are the commented lines — an empty object overrides nothing,
//      which is exactly the inert default we want.
//   3. Every commented line carries its OWN trailing comma. Uncomment any
//      subset and the commas are already right; the last one before a `}` is
//      then an orphan, which strict JSON rejects and JSON5 forgives. Without
//      that, uncommenting two lines in a section would produce invalid JSON and
//      the whole promise of the file would be a lie on the second edit.
//
// Foundation-only (no AppKit, no Settings): the table that knows pounce's actual
// settings is ConfigSpec.swift, and it hands this a plain description. That split
// is what lets tests/run.sh compile the renderer and prove its output parses,
// both as shipped and once uncommented.

import Foundation

/// What the Settings window draws for one setting.
///
/// A DESCRIPTION, not a widget: this file is Foundation-only (it is compiled by
/// `tests/run.sh`, which links no AppKit), so the SwiftUI that honours each case
/// lives in SettingsControls.swift. The split is the same one that already keeps
/// the renderer testable — ConfigSpec knows pounce's settings, this file knows
/// how to write them down, and the window knows how to draw them.
///
/// Every case reads and writes a JSON LITERAL rather than a typed value, because
/// that is the currency both halves of the file already trade in: ConfigSpec
/// renders defaults as JSON (`ConfigSpec.json`) and ConfigWriter puts JSON back
/// on one line. A control that dealt in `Bool` would need a third mapping
/// between the two, and a place for it to disagree.
enum ConfigControl {
    /// One of a fixed set of strings — `windowMode`, `fnKey`.
    struct Choice {
        let value: String   // the JSON string as written, without its quotes
        let label: String   // what the picker says
        init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }

    case toggle
    /// A whole number, with the range it is clamped or sensible within.
    case number(ClosedRange<Int>, unit: String? = nil)
    /// A real number typed rather than dragged — a timeout, where the useful
    /// range spans three orders of magnitude and a slider resolves none of it.
    case decimal(ClosedRange<Double>, step: Double, unit: String? = nil)
    /// A real number dragged rather than typed — `scale`, whose whole point is
    /// that you try one and look.
    case slider(ClosedRange<Double>, step: Double)
    case choice([Choice])
    /// Free text. `nullable` means an emptied field writes `null` (the theme
    /// keys, where "unset" is a third state that means "follow macOS"), not `""`.
    case text(placeholder: String = "", nullable: Bool = false)
    /// A named key — "space", "tab", "f13". Text, but drawn narrow and with the
    /// spelling to hand, since the grammar is pounce's own (see HotKey.swift).
    case key
    /// Any of "cmd"/"shift"/"opt"/"ctrl", drawn as the four glyphs.
    case modifiers
    /// A list of strings, one per line — bundle ids, mostly.
    case list(placeholder: String = "")
    /// Structured past what a row can honestly draw: `appHotkeys.scopes` is a
    /// list of apps each holding a list of chords each naming a target. The
    /// window shows how many there are and sends you to the file, which is a
    /// smaller lie than a form that can only express half of them. The string
    /// says what one entry looks like.
    case fileOnly(String)

    /// Whether this control can actually read that literal — i.e. whether the
    /// control named in ConfigSpec matches the TYPE of the setting it was put
    /// against. `.toggle` on an Int is the mistake this catches: the switch
    /// would read false, write `true`, and `Settings.load()` would drop it, so
    /// the window would appear to work and change nothing.
    ///
    /// Checked where the row is drawn rather than trusted, so a mismatched pair
    /// degrades to "edit this one in the file" instead of to a control that
    /// lies. Pure, so tests/run.sh can hold the table to it.
    func accepts(_ json: String) -> Bool {
        switch self {
        case .toggle:
            return json == "true" || json == "false"
        case .number:
            return Int(json) != nil
        case .decimal, .slider:
            return Double(json) != nil
        case .choice(let choices):
            // `null` is not offered by a picker — a choice setting always has
            // one of its cases, because `Settings` types them as enums.
            guard let value = ConfigValue.string(json) else { return false }
            return choices.contains { $0.value == value }
        case .text(_, let nullable):
            return ConfigValue.string(json) != nil || (nullable && json == "null")
        case .key:
            return ConfigValue.string(json) != nil
        case .modifiers, .list:
            return ConfigValue.isStringArray(json)
        case .fileOnly:
            return ConfigValue.isArray(json)
        }
    }
}

/// Reading a JSON literal back — the other direction from `ConfigSpec.json`.
///
/// Lives here, beside `ConfigControl`, because the two are one idea: the spec
/// hands the window a value written as JSON and a note about how to draw it,
/// and both halves of that have to agree about what "a string" looks like.
/// Foundation-only, so tests/run.sh holds them to it together.
enum ConfigValue {
    /// A JSON string's contents, or nil for `null` and for anything that isn't
    /// a string.
    static func string(_ json: String) -> String? {
        guard json != "null" else { return nil }
        return object(json) as? String
    }

    /// A JSON array of strings, or empty for anything else. Empty and
    /// not-an-array are deliberately the same answer: a list control showing
    /// nothing is the honest rendering of both.
    static func strings(_ json: String) -> [String] {
        object(json) as? [String] ?? []
    }

    static func isStringArray(_ json: String) -> Bool { object(json) is [String] }

    static func isArray(_ json: String) -> Bool { object(json) is [Any] }

    /// How many entries an array literal holds; 0 for anything else.
    static func count(_ json: String) -> Int { (object(json) as? [Any])?.count ?? 0 }

    /// Parsed with the SAME flags `Settings.load()` uses, plus fragments —
    /// most of these literals are a bare `true` or `200`, which is not a JSON
    /// document on its own.
    private static func object(_ json: String) -> Any? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed, .json5Allowed])
    }
}

/// One setting: the leaf key, the prose above it, its default as JSON, and what
/// the Settings window should draw for it.
struct ConfigField {
    let name: String
    let doc: String
    /// The default, already rendered as a JSON value ("200", "true", "\"space\"",
    /// or a pretty-printed array). ConfigSpec builds these from a live `Settings`
    /// so they can't drift from the struct defaults they document.
    let json: String
    /// The widget. Deliberately NOT optional and with no default value: a
    /// setting added to ConfigSpec without one doesn't compile, which is the
    /// only kind of coverage this table has ever managed to keep. (The prose and
    /// the default were both once "remember to add it too"; the default stopped
    /// drifting the day it started being read off a live `Settings`.)
    let control: ConfigControl
    /// SF Symbol for the row, or nil for a row that reads fine without one.
    let symbol: String?

    /// "maxEntries" → "Max entries". The key IS the label: inventing a second
    /// name for every setting would mean the words you read in the Settings
    /// window and the words you search for in config.json are different words,
    /// which for a window whose whole pitch is "this is that file" would be the
    /// one unforgivable seam.
    var label: String {
        var out = ""
        for (index, character) in name.enumerated() {
            if index > 0 && character.isUppercase && !out.hasSuffix(" ") {
                out.append(" ")
                out.append(Character(character.lowercased()))
            } else {
                out.append(index == 0 ? Character(character.uppercased()) : character)
            }
        }
        // "Bundle IDs" beats "Bundle i ds" — the acronym is the one place the
        // camel-case split guesses wrong, and it is in four of these keys.
        return out.replacingOccurrences(of: " ids", with: " IDs")
    }

    init(name: String, doc: String, json: String, control: ConfigControl, symbol: String? = nil) {
        self.name = name
        self.doc = doc
        self.json = json
        self.control = control
        self.symbol = symbol
    }
}

/// A `{ }` in the config, or the top level when `name` is nil.
struct ConfigSection {
    let name: String?
    /// Which Settings-window pane this section's card belongs on. A plain string
    /// here rather than an enum for the same reason `control` is a description:
    /// the panes' titles, glyphs and tints are SwiftUI, and this file links no
    /// AppKit. `ConfigPane` in SettingsView.swift owns the id → chrome map and
    /// the sidebar order; a pane id it doesn't recognise still shows up, on the
    /// fallback pane, because a setting that silently isn't drawn is the exact
    /// failure that window exists to fix.
    ///
    /// Required, again so the compiler is the one keeping coverage.
    let pane: String
    let doc: String?
    let fields: [ConfigField]
    /// A raw, already-commented block appended inside the section — for the one
    /// setting (`items`) whose shape is a user-defined map rather than a fixed
    /// list of keys, so there's nothing to enumerate and an example is the only
    /// honest documentation.
    let raw: String?

    init(name: String?, pane: String, doc: String? = nil,
         fields: [ConfigField] = [], raw: String? = nil) {
        self.name = name
        self.pane = pane
        self.doc = doc
        self.fields = fields
        self.raw = raw
    }
}

enum ConfigTemplate {
    static let docsURL = "https://hausfold.co/docs/pounce/config/"

    /// Wrap prose to `width` columns. Docs are authored as single paragraphs, so
    /// this is the only thing standing between a 300-character sentence and a
    /// config file you have to scroll sideways to read.
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    /// Prose gets `//` + TWO spaces; a setting line gets one. That single column
    /// is load-bearing: everything in this file is commented, so `// "` has to
    /// mean "a line you can uncomment" and nothing else — and prose can start
    /// with a quote all on its own (`"gruvbox-dark" + "themeLight": "gruvbox"`
    /// is a real sentence in the theme docs, and it has a `": ` in it too).
    /// Without the offset, a script — or a reader skimming for the settable
    /// line — can't tell that sentence from a setting.
    private static func comment(_ text: String, indent: String, width: Int) -> String {
        wrap(text, width: width).map { "\(indent)//  \($0)" }.joined(separator: "\n")
    }

    /// Re-indent a multi-line JSON value so a pretty-printed array lines up under
    /// the key it belongs to instead of hugging column zero.
    private static func reindent(_ json: String, to indent: String) -> String {
        let lines = json.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return json }
        return ([String(lines[0])] + lines.dropFirst().map { "\(indent)// \($0)" })
            .joined(separator: "\n")
    }

    static func render(_ sections: [ConfigSection], version: String) -> String {
        var out: [String] = [
            "// pounce — every setting, at its default.",
            "//",
            "// Generated by `pounce config init` from pounce \(version). Everything below is",
            "// commented out, so this file changes nothing as shipped. Uncomment a line to",
            "// change that setting, and delete every line you never touched — what's left is",
            "// a config that says only what you meant.",
            "//",
            "// The lines you can uncomment are the ones that read `// \"name\": value,` — one",
            "// space after the slashes. Prose is indented one column further, so nothing you",
            "// can't act on ever looks like something you can.",
            "//",
            "// Comments and trailing commas are both fine here (pounce parses this as JSON5),",
            "// which is what lets you uncomment any subset of lines without fixing up commas",
            "// by hand. Unknown keys are ignored, so a newer pounce never chokes on this file",
            "// and an older one never chokes on a newer one.",
            "//",
            "// Re-read on every summon, so an edit shows on the next ⌘Space — except",
            "// `hotkey` and `windows`, which the daemon reads once at start.",
            "//",
            "// Full reference: \(docsURL)",
            "{",
        ]

        for (index, section) in sections.enumerated() {
            let nested = section.name != nil
            let indent = nested ? "    " : "  "

            if index > 0 { out.append("") }
            if let name = section.name {
                if let doc = section.doc {
                    out.append(comment(doc, indent: "  ", width: 74))
                }
                out.append("  \"\(name)\": {")
            } else if let doc = section.doc {
                // No `"name": {` line to separate a top-level blurb from the
                // first setting's prose, so put one blank line there by hand.
                out.append(comment(doc, indent: "  ", width: 74))
                out.append("")
            }

            for (fieldIndex, field) in section.fields.enumerated() {
                if fieldIndex > 0 { out.append("") }
                out.append(comment(field.doc, indent: indent, width: 76 - indent.count))
                let value = reindent(field.json, to: indent)
                out.append("\(indent)// \"\(field.name)\": \(value),")
            }

            if let raw = section.raw {
                if !section.fields.isEmpty { out.append("") }
                out.append(raw.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "" : "\(indent)\($0)" }
                    .joined(separator: "\n"))
            }

            // A real, empty object: it overrides nothing, and it's what makes an
            // uncommented child inside it take effect.
            if nested { out.append("  },") }
        }

        out.append("}")
        return out.joined(separator: "\n") + "\n"
    }
}
