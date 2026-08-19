import Foundation

// SettingsPaneStore — the parser over macOS's own settings search index, and the
// per-pane cap that keeps one pane from being the whole result list.
// See SystemSettings.swift.

func runSystemSettingsTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }

    // MARK: keywords

    // Apple's index strings are comma-separated, inconsistently spaced, and
    // repeat themselves. They're matched, never shown, so they normalize hard.
    check(SettingsPaneStore.keywords("files, full disk access,complete,  Full , disk")
            == ["files", "full disk access", "complete", "full", "disk"],
          "keywords split, trim, lowercase and dedupe")
    check(SettingsPaneStore.keywords(nil).isEmpty, "no index → no keywords")
    check(SettingsPaneStore.keywords(" , ,").isEmpty, "an index of separators yields nothing")
    check(!SettingsPaneStore.keywords("sound, Volume", title: "Volume").contains("volume"),
          "a keyword that just repeats the title is dropped — the title already scores")
    // Apple spells the Wi-Fi pane with a non-breaking hyphen; nobody types one.
    check(SettingsPaneStore.alternateName(for: "Wi\u{2011}Fi") == "Wi-Fi",
          "a title's non-breaking hyphen gets an ASCII twin, matched at full weight")
    check(SettingsPaneStore.alternateName(for: "Menu Bar", derived: "Control Center")
            == "Control Center",
          "a renamed pane keeps answering to the name in its bundle id")
    check(SettingsPaneStore.alternateName(for: "Bluetooth", derived: "Bluetooth") == nil,
          "…and a pane whose name matches its id has no second name")
    check(SettingsPaneStore.keywords(nil, title: "Menu Bar", extra: ["Control Center", "Menu Bar"])
            == ["control center"],
          "extra names (the bundle id's, the Info.plist's) join the keywords, deduped")

    // MARK: pane names macOS doesn't localize

    check(SettingsPaneStore.isInternalName("PowerPreferences"), "a build target's name is not a pane name")
    check(SettingsPaneStore.isInternalName("HeadphoneSettingsExtension"), "nor is this one")
    check(!SettingsPaneStore.isInternalName("Touch ID & Password"), "a real name has a space")
    check(!SettingsPaneStore.isInternalName("Bluetooth"), "…or doesn't end in a target-name word")
    check(SettingsPaneStore.nameFromBundleID("com.apple.Battery-Settings.extension") == "Battery",
          "the bundle id is the last-resort pane name")
    check(SettingsPaneStore.nameFromBundleID("com.apple.HeadphoneSettings") == "Headphone",
          "…camel-cased ids split into words")
    check(SettingsPaneStore.nameFromBundleID("com.apple.ControlCenter-Settings.extension")
            == "Control Center",
          "…which is also how \"control center\" still finds the pane macOS renamed to Menu Bar")

    // MARK: searchTerms parsing

    // The shape of a real .searchTerms file: keyed BY ANCHOR, each anchor
    // holding one or more titled entries.
    let plist: [String: Any] = [
        "Privacy_AllFiles": [
            "localizableStrings": [
                ["title": "Allow applications to access all user files",
                 "index": "files, full disk access, complete"],
            ],
        ],
        "FileVault": [
            "localizableStrings": [
                ["title": "FileVault", "index": "disk, encrypt, filevault"],
            ],
        ],
        // One anchor backing several settings — the shape Appearance's `Main`
        // has. Each needs its own item key.
        "Shared": [
            "localizableStrings": [
                ["title": "Accent color", "index": "color"],
                ["title": "Highlight color", "index": "color"],
            ],
        ],
        // A pane whose sub-item just restates the pane name — dropped, since the
        // always-visible pane row already goes there.
        "Main": [
            "localizableStrings": [
                ["title": "Privacy & Security", "index": "security"],
                ["title": "", "index": "ignored"],          // no title → no row
                ["index": "also ignored"],                  // ditto
            ],
        ],
        "Malformed": ["localizableStrings": "not an array"],
    ]
    let entries = SettingsPaneStore.parseSearchTerms(
        plist, paneID: "com.apple.settings.PrivacySecurity.extension", pane: "Privacy & Security",
        icon: "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex")

    check(entries.count == 4, "titled entries only, and never the pane's own name again")
    check(entries.map(\.title).prefix(2) == ["FileVault", "Allow applications to access all user files"],
          "anchors are walked in a stable (sorted) order")

    // MARK: one anchor, several settings

    let shared = entries.filter { $0.anchor == "Shared" }
    check(shared.count == 2, "both settings under a shared anchor become rows")
    check(Set(shared.map(\.itemKey)).count == 2, "…with DISTINCT item keys, or an alias would hit both")
    check(shared.contains { $0.itemKey.hasSuffix("?Shared#accent-color") },
          "the uniquifier is the title, not the array index Apple reorders")
    check(shared.allSatisfy { $0.url.hasSuffix("?Shared") },
          "but the URL keeps the bare anchor — macOS has never heard of the uniquifier")
    check(SettingsPaneStore.url(forTarget: "com.apple.x?Shared#accent-color")
            == "x-apple.systempreferences:com.apple.x?Shared",
          "…and `pounce run` strips it through the same one place")

    guard let fda = entries.first(where: { $0.anchor == "Privacy_AllFiles" }) else {
        check(false, "the Full Disk Access anchor survives parsing"); return failures
    }
    check(fda.pane == "Privacy & Security", "the pane name rides along as the subtitle")
    check(fda.iconPath.hasSuffix("SecurityPrivacyExtension.appex"),
          "a sub-item wears its pane's icon, not a shared gear")
    check(fda.keywords.contains("full disk access"),
          "the words a person actually types live in the keywords, not the title")

    // MARK: the key / URL grammar
    //
    // One string is the frecency key, the `items` override key, the `pounce run`
    // argument and the tail of the URL — see ItemTarget.
    check(fda.itemKey == "setting:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
          "a sub-item's item key carries the anchor")
    check(fda.url == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
          "…and the URL is the scheme plus that same tail")
    check(ItemTarget.parse(fda.itemKey) == .setting(fda.target), "which ItemTarget parses back")

    let pane = SettingsPaneEntry(paneID: "com.apple.Appearance-Settings.extension", anchor: nil,
                                 discriminator: nil, title: "Appearance", pane: "Appearance",
                                 keywords: [], iconPath: SettingsPaneStore.iconPath, alias: nil)
    check(pane.itemKey == "setting:com.apple.Appearance-Settings.extension",
          "a pane's item key has no anchor")
    check(pane.url == "x-apple.systempreferences:com.apple.Appearance-Settings.extension",
          "…and opens the pane's top")

    // MARK: locale fallback

    let candidates = SettingsPaneStore.localeCandidates(["fr-CA"])
    check(candidates.prefix(3).elementsEqual(["fr_CA", "fr", "en"]),
          "region first, then language, then English")
    check(SettingsPaneStore.localeCandidates(["en"]).first == "en",
          "no duplicate en for an English Mac")

    // MARK: the per-pane cap

    func sub(_ pane: String, _ anchor: String) -> PounceItem {
        PounceItem.setting(SettingsPaneEntry(paneID: pane, anchor: anchor, discriminator: nil,
                                             title: anchor, pane: pane, keywords: [],
                                             iconPath: SettingsPaneStore.iconPath, alias: nil),
                           subItemMinQuery: 3)
    }
    func paneRow(_ pane: String) -> PounceItem {
        PounceItem.setting(SettingsPaneEntry(paneID: pane, anchor: nil, discriminator: nil,
                                             title: pane, pane: pane, keywords: [],
                                             iconPath: SettingsPaneStore.iconPath, alias: nil),
                           subItemMinQuery: 3)
    }
    let app = PounceItem.app(name: "Safari", path: "/Applications/Safari.app", boost: 0)
    let list = [app, paneRow("ax"), sub("ax", "a"), sub("ax", "b"), sub("ax", "c"),
                sub("net", "x"), sub("ax", "d"), sub("net", "y")]

    let capped = SettingsPaneStore.capPerPane(list, limit: 2)
    check(capped.count == 6, "two sub-items per pane survive; four rows drop to none")
    check(capped.contains { $0.frecencyKey == "app:/Applications/Safari.app" },
          "a non-settings row is never capped")
    check(capped.contains { $0.frecencyKey == "setting:ax" },
          "nor is the pane row itself — the cap is about what's INSIDE a pane")
    check(capped.filter { $0.frecencyKey.hasPrefix("setting:ax?") }.count == 2,
          "the pane over its limit keeps exactly `limit` sub-items")
    check(capped.map(\.frecencyKey).contains("setting:ax?a")
            && capped.map(\.frecencyKey).contains("setting:ax?b"),
          "and keeps the FIRST ones, i.e. the highest-scoring — the list arrives sorted")
    check(SettingsPaneStore.capPerPane(list, limit: 0).count == list.count,
          "limit 0 is no cap, which is how config.json spells `maxPerPane: 0`")
    check(SettingsPaneStore.capPerPane(list, limit: Int.max).count == list.count,
          "…and Int.max is the no-cap every non-launcher mode passes")

    // MARK: the query gate

    check(sub("ax", "a").minQueryLength == 3,
          "a setting inside a pane waits for a specific enough query")
    check(paneRow("ax").minQueryLength == 0, "a pane is always eligible")
    check(paneRow("ax").baseBoost < 0, "…but starts below everything at an empty query")
    check(sub("ax", "a").subtitle == "ax", "a sub-item names its pane")
    check(paneRow("ax").subtitle == "System Settings", "a pane names the app")

    if failures == 0 { print("ok — all System Settings pane tests passed") }
    return failures
}
