// Renders an annotated config.json: every setting present, at its default, with
// a comment above it, and every setting commented out.
//
// The shape is AeroSpace's: its default config lists every setting at its
// default with a comment above, so you learn the surface by reading your own
// config and you make it minimal by deleting the lines you never touched. No
// doc-site round trip to find out what exists. Pounce had the same problem the
// nebelhaus rice did — the settings were discoverable only in the reference, and
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

/// One setting: the leaf key, the prose above it, and its default as JSON.
struct ConfigField {
    let name: String
    let doc: String
    /// The default, already rendered as a JSON value ("200", "true", "\"space\"",
    /// or a pretty-printed array). ConfigSpec builds these from a live `Settings`
    /// so they can't drift from the struct defaults they document.
    let json: String
}

/// A `{ }` in the config, or the top level when `name` is nil.
struct ConfigSection {
    let name: String?
    let doc: String?
    let fields: [ConfigField]
    /// A raw, already-commented block appended inside the section — for the one
    /// setting (`items`) whose shape is a user-defined map rather than a fixed
    /// list of keys, so there's nothing to enumerate and an example is the only
    /// honest documentation.
    let raw: String?

    init(name: String?, doc: String? = nil, fields: [ConfigField] = [], raw: String? = nil) {
        self.name = name
        self.doc = doc
        self.fields = fields
        self.raw = raw
    }
}

enum ConfigTemplate {
    static let docsURL = "https://hausfold.co/docs/haus/reference/pounce/"

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
