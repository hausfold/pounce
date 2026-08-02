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
// check at runtime instead: `ConfigSpec.render` strips and parses its own output
// before `pounce config init` writes anything.
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
        ConfigSection(name: nil, doc: "Top level.", fields: [
            ConfigField(name: "windowMode", doc: "How tightly it reads: \"default\", or \"compact\".", json: "\"default\""),
            ConfigField(name: "scale", doc: "Multiplies every size.", json: "1"),
            ConfigField(name: "theme", doc: "Unset follows macOS light and dark.", json: "null"),
        ]),
        ConfigSection(name: "clipboard", doc: "Clipboard history.", fields: [
            ConfigField(name: "enabled", doc: "Record copies at all.", json: "true"),
            ConfigField(name: "maxEntries", doc: "How many to remember.", json: "200"),
            ConfigField(name: "blacklistBundleIds",
                        doc: "A long list, so it renders across lines.",
                        json: "[\n  \"a\",\n  \"b\",\n  \"c\",\n  \"d\"\n]"),
        ]),
        ConfigSection(name: "items", doc: "Per-item overrides.", raw: """
        // "cmd:emoji": {
        //   "alias": "emo",
        // },
        """),
    ]

    let text = ConfigTemplate.render(fixture, version: "test")

    func parse(_ s: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(JSONC.strip(s).utf8)) as? [String: Any]
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

    // The last line before a `}` is the orphan-comma case JSONC.strip forgives.
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

    if failures == 0 { print("ok — all config-template tests passed") }
    return failures
}
