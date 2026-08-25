// Unit tests for ConfigWriter.swift — the settings window's write path.
//
// The property that matters: writing one setting changes ONE setting. The file
// the user edits by hand is the file the GUI writes, so every comment, every
// blank line, every key pounce has never heard of and every other setting must
// come out the far side byte-for-byte identical — and the result must still
// parse, as JSON5, to the value that was asked for.
//
// The fixture is a real ConfigTemplate render rather than a hand-written stub:
// the shipped file is the one shape this has to survive, including its
// commented-out settings and its multi-line arrays.
//
// Named with a _tests suffix (see tests/run.sh) so it can't collide with
// ConfigWriter.swift on a case-insensitive filesystem.

import Foundation

func runConfigWriterTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    let sections: [ConfigSection] = [
        ConfigSection(name: nil, doc: "Top level.", fields: [
            ConfigField(name: "windowMode", doc: "\"default\", or \"compact\".", json: "\"default\""),
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
        ConfigSection(name: "fileSearch", doc: "Find Files.", fields: [
            ConfigField(name: "enabled", doc: "Offer file search at all.", json: "true"),
        ]),
    ]
    let template = ConfigTemplate.render(sections, version: "test")

    /// Parse the way `Settings.load()` does — JSON5, so comments and trailing
    /// commas are both fine.
    func parse(_ text: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(
            with: Data(text.utf8), options: [.json5Allowed]) as? [String: Any]
    }

    /// Every line except the ones that changed, so "it changed one setting" is
    /// checked rather than asserted.
    func changedLines(_ before: String, _ after: String) -> [String] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        guard old.count == new.count else { return ["<line count moved: \(old.count) → \(new.count)>"] }
        return zip(old, new).filter { $0 != $1 }.map { $1 }
    }

    // MARK: A top-level scalar

    let scaled = ConfigWriter.apply(template, section: nil, key: "scale", json: "1.4")
    check(parse(scaled)?["scale"] as? Double == 1.4, "scale reads back as 1.4")
    check(changedLines(template, scaled) == ["  \"scale\": 1.4,"],
          "exactly one line changed, and it is the uncommented scale line")
    check(scaled.contains("//  Multiplies every size."), "the prose above the setting survives")

    // MARK: A nested key whose name is not unique

    let clip = ConfigWriter.apply(template, section: "clipboard", key: "enabled", json: "false")
    let clipboard = parse(clip)?["clipboard"] as? [String: Any]
    check(clipboard?["enabled"] as? Bool == false, "clipboard.enabled is now false")
    check((parse(clip)?["fileSearch"] as? [String: Any])?["enabled"] == nil,
          "fileSearch.enabled — the same leaf name one section down — is untouched")
    check(changedLines(template, clip) == ["    \"enabled\": false,"],
          "one line, at the section's own indent")

    // MARK: A multi-line array

    let listed = ConfigWriter.apply(
        template, section: "clipboard", key: "blacklistBundleIds", json: "[\"com.example.vault\"]")
    let listedClipboard = parse(listed)?["clipboard"] as? [String: Any]
    check(listedClipboard?["blacklistBundleIds"] as? [String] == ["com.example.vault"],
          "the array reads back as the new one")
    check(!listed.contains("\"d\""),
          "every line of the old pretty-printed array is gone, not just its first")
    check(listed.components(separatedBy: "\n").count == template.components(separatedBy: "\n").count - 5,
          "the six-line value collapsed to one line and nothing else moved")

    // MARK: Back to the default

    let reverted = ConfigWriter.apply(scaled, section: nil, key: "scale", json: nil, default: "1")
    check(parse(reverted)?["scale"] == nil, "the key is gone from the parsed config")
    check(reverted == template, "and the file is byte-for-byte the template again")

    // MARK: A key the file doesn't carry

    let minimal = """
    // My config.
    {
      "clipboard": {
        "maxEntries": 50,
      },
    }
    """
    let added = ConfigWriter.apply(minimal, section: "clipboard", key: "autoPaste", json: "true")
    let addedClipboard = parse(added)?["clipboard"] as? [String: Any]
    check(addedClipboard?["autoPaste"] as? Bool == true, "the new key parses")
    check(addedClipboard?["maxEntries"] as? Int == 50, "the key that was already there is still there")
    check(added.contains("// My config."), "a comment pounce didn't write survives")

    // MARK: A section the file doesn't carry

    let sectioned = ConfigWriter.apply(minimal, section: "hotkey", key: "key", json: "\"space\"")
    check((parse(sectioned)?["hotkey"] as? [String: Any])?["key"] as? String == "space",
          "a section that wasn't in the file is created around the key")
    check((parse(sectioned)?["clipboard"] as? [String: Any])?["maxEntries"] as? Int == 50,
          "…without disturbing the section that was")

    // MARK: A top-level key is not a nested one

    let nestedOnly = """
    {
      "clipboard": {
        "scale": 9,
      },
    }
    """
    let topLevel = ConfigWriter.apply(nestedOnly, section: nil, key: "scale", json: "1.2")
    check(parse(topLevel)?["scale"] as? Double == 1.2, "the top-level scale is set")
    check((parse(topLevel)?["clipboard"] as? [String: Any])?["scale"] as? Int == 9,
          "the same key inside a section is left alone")

    // MARK: Every write still parses

    var accumulated = template
    for (section, key, value) in [
        (nil, "windowMode", "\"compact\""), (nil, "theme", "\"gruvbox\""),
        ("clipboard", "maxEntries", "500"), ("fileSearch", "enabled", "false"),
    ] as [(String?, String, String)] {
        accumulated = ConfigWriter.apply(accumulated, section: section, key: key, json: value)
        check(parse(accumulated) != nil, "still parses after writing \(section ?? "")…\(key)")
    }
    check(parse(accumulated)?["windowMode"] as? String == "compact", "windowMode survived the run")
    check((parse(accumulated)?["clipboard"] as? [String: Any])?["maxEntries"] as? Int == 500,
          "maxEntries survived the run")

    if failures == 0 { print("ok — all config-writer tests passed") }
    return failures
}
