// Unit tests for ConfigTemplate.swift — the renderer behind `pounce config init`.
//
// The property that matters, and the reason this file exists: the generated
// config must be valid JSON **as shipped** (everything commented) AND **after
// you uncomment any subset of it**. The second half is the whole promise of the
// file, and it's the half that breaks silently — an uncommented pair with no
// comma after it makes `Settings.load()` fall back to defaults without a word,
// so the user's edit appears to be ignored rather than to have failed.
//
// ConfigSpec's real table isn't reachable from here (it reads `Settings`, which
// pulls in AppKit and can't join this Foundation-only suite). It gets the same
// check at runtime instead: `ConfigSpec.render` parses its own output before
// `pounce config init` writes anything.
//
// Named with a _tests suffix (see tests/run.sh) so it can't collide with
// ConfigTemplate.swift on a case-insensitive filesystem.

import Foundation

func runConfigTemplateTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    let fixture: [ConfigSection] = [
        ConfigSection(name: nil, pane: "appearance", doc: "Top level.", fields: [
            ConfigField(name: "windowMode", doc: "How tightly it reads: \"default\", or \"compact\".", json: "\"default\"",
                        control: .choice([.init("default", "Default"), .init("compact", "Compact")])),
            ConfigField(name: "scale", doc: "Multiplies every size.", json: "1",
                        control: .slider(0.8...2.0, step: 0.05)),
            ConfigField(name: "theme", doc: "Unset follows macOS light and dark.", json: "null",
                        control: .text(nullable: true)),
        ]),
        ConfigSection(name: "clipboard", pane: "clipboard", doc: "Clipboard history.", fields: [
            ConfigField(name: "enabled", doc: "Record copies at all.", json: "true", control: .toggle),
            ConfigField(name: "maxEntries", doc: "How many to remember.", json: "200",
                        control: .number(1...5000)),
            ConfigField(name: "blacklistBundleIds",
                        doc: "A long list, so it renders across lines.",
                        json: "[\n  \"a\",\n  \"b\",\n  \"c\",\n  \"d\"\n]",
                        control: .list()),
        ]),
        ConfigSection(name: "items", pane: "keys", doc: "Per-item overrides.", raw: """
        // "cmd:emoji": {
        //   "alias": "emo",
        // },
        """),
    ]

    let text = ConfigTemplate.render(fixture, version: "test")

    func parse(_ s: String) -> [String: Any]? {
        // `.json5Allowed`, exactly as Settings.load() reads a real config.
        try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.json5Allowed])
            as? [String: Any]
    }

    // MARK: as shipped

    guard let shipped = parse(text) else {
        FileHandle.standardError.write(Data("FAIL: the rendered template isn't valid JSON\n".utf8))
        return failures + 1
    }
    check(shipped["windowMode"] == nil, "a commented top-level setting is absent as shipped")
    check((shipped["clipboard"] as? [String: Any])?.isEmpty == true,
          "a section is a real, empty object — present so an uncommented child can land in it")
    check(shipped["items"] != nil, "the raw-example section is still a real object")

    // MARK: `// "` means "a line you can uncomment", and only that

    // Prose can legitimately start with a quoted word — this fixture's
    // windowMode doc does, and the real theme docs contain
    // `"gruvbox-dark" + "themeLight": "gruvbox"`, quote and colon and all. The
    // renderer indents prose one column further for exactly this reason; if that
    // ever regresses, a reader skimming for the settable line (and the uncomment
    // helper below) starts hitting sentences.
    let proseLikeSettings = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("// \"") }
    check(proseLikeSettings.allSatisfy { line in
        ["windowMode", "scale", "theme", "enabled", "maxEntries", "blacklistBundleIds", "cmd:emoji"]
            .contains { line.hasPrefix("// \"\($0)\":") }
    }, "every `// \"` line is a setting, never a sentence that happens to start with a quote")

    // MARK: uncommenting

    func uncomment(_ source: String, _ names: [String]) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for name in names where trimmed.hasPrefix("// \"\(name)\":") {
                if let range = line.range(of: "// ") {
                    return line.replacingCharacters(in: range, with: "")
                }
            }
            return String(line)
        }.joined(separator: "\n")
    }

    let one = parse(uncomment(text, ["maxEntries"]))
    check((one?["clipboard"] as? [String: Any])?["maxEntries"] as? Int == 200,
          "uncommenting a single line lands the documented default")

    // The case a comma-less template gets wrong: two siblings, no hand-editing.
    let two = parse(uncomment(text, ["enabled", "maxEntries"]))
    let clip = two?["clipboard"] as? [String: Any]
    check(clip?["enabled"] as? Bool == true && clip?["maxEntries"] as? Int == 200,
          "uncommenting TWO siblings needs no comma fixups — the commas are already there")

    // The last line before a `}` is the orphan-comma case JSON5 forgives.
    let last = parse(uncomment(text, ["theme"]))
    check(last != nil && last?.keys.contains("theme") == true,
          "uncommenting the last setting in a section leaves a trailing comma that's forgiven")

    check(parse(uncomment(text, ["windowMode", "scale", "theme", "enabled", "maxEntries"])) != nil,
          "uncommenting across sections stays valid")

    // MARK: wrapping

    let long = String(repeating: "word ", count: 60)
    check(ConfigTemplate.wrap(long, width: 40).allSatisfy { $0.count <= 40 },
          "prose wraps within the requested width")
    check(ConfigTemplate.wrap("", width: 40) == [""], "empty prose renders one empty line, not none")
    check(ConfigTemplate.wrap("supercalifragilistic", width: 5) == ["supercalifragilistic"],
          "a word longer than the width is emitted whole rather than dropped")

    // MARK: the Settings window's half of the description

    // A key is its own label — the words in the window and the words in the
    // file have to be the same words.
    func label(_ key: String) -> String {
        ConfigField(name: key, doc: "", json: "null", control: .toggle).label
    }
    check(label("maxEntries") == "Max entries", "camelCase becomes a sentence")
    check(label("theme") == "Theme", "a one-word key is just capitalised")
    check(label("subItemMinQuery") == "Sub item min query", "several humps still read as one phrase")
    check(label("blacklistBundleIds") == "Blacklist bundle IDs", "the one acronym is spelled as one")
    check(label("fnKey") == "Fn key", "a two-letter first word survives")

    // A control that can't read its own setting's type is the mistake worth
    // catching: it would draw a working-looking switch that changes nothing.
    check(ConfigControl.toggle.accepts("true"), "a switch reads a bool")
    check(!ConfigControl.toggle.accepts("200"), "a switch does NOT read a number")
    check(ConfigControl.number(1...10).accepts("200"), "a stepper reads a number")
    check(!ConfigControl.number(1...10).accepts("true"), "a stepper does not read a bool")
    check(ConfigControl.slider(0.8...2.0, step: 0.05).accepts("1"), "a slider reads an int as a double")
    check(ConfigControl.decimal(0...10, step: 1).accepts("2.5"), "a decimal field reads a double")
    check(ConfigControl.text(nullable: true).accepts("null"),
          "an unset-able string reads null — that IS its third state")
    check(!ConfigControl.text().accepts("null"),
          "a string that can't be unset does not read null")
    check(ConfigControl.text().accepts("\"nebelung\""), "a string field reads a string")
    let modes = ConfigControl.choice([.init("tap", "Event tap"), .init("remap", "HID remap")])
    check(modes.accepts("\"remap\""), "a picker reads one of its own cases")
    check(!modes.accepts("\"nonsense\""), "a picker refuses a value it doesn't offer")
    check(ConfigControl.modifiers.accepts("[\"cmd\"]"), "the modifier chips read a string array")
    check(!ConfigControl.modifiers.accepts("\"cmd\""), "…and not a bare string")
    check(ConfigControl.fileOnly("").accepts("[]"), "a file-only setting reads any array")
    check(!ConfigControl.list().accepts("[{}]"),
          "a list of strings refuses a list of objects — that's the file-only case")

    // Reading a literal back, the inverse of ConfigSpec.json.
    check(ConfigValue.string("\"gruvbox\"") == "gruvbox", "a string literal unwraps")
    check(ConfigValue.string("null") == nil, "null is not a string")
    check(ConfigValue.string("200") == nil, "a number is not a string")
    check(ConfigValue.strings("[\n  \"a\",\n  \"b\"\n]") == ["a", "b"],
          "a pretty-printed array reads back in order")
    check(ConfigValue.strings("true").isEmpty, "a non-array reads as no entries, not a crash")
    check(ConfigValue.count("[1, 2, 3]") == 3, "an array literal is counted")
    check(ConfigValue.count("null") == 0, "nothing counts as none")

    if failures == 0 { print("ok — all config-template tests passed") }
    return failures
}
