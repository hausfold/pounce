import Foundation

// MARK: - System Settings panes, and the settings inside them, as launcher rows
//
// WHERE THIS DATA COMES FROM.
//
// System Settings is a shell around ~50 ExtensionKit extensions, one per pane,
// in /System/Library/ExtensionKit/Extensions. Each one that can be deep-linked
// declares it in its Info.plist:
//
//     EXAppExtensionAttributes
//       SettingsExtensionAttributes
//         allowsXAppleSystemPreferencesURLScheme = true
//         searchTermsFileName                    = "PrivacySecurity"
//
// and that named file — Resources/<locale>.lproj/<name>.searchTerms — is the
// index behind System Settings' own search field. It is a plist keyed BY ANCHOR,
// and each anchor carries the setting's title plus Apple's hand-written synonym
// list:
//
//     Privacy_AllFiles → title "Allow applications to access all user files"
//                        index "files, full disk access, complete, full, disk"
//
// The anchor is exactly what `x-apple.systempreferences:<bundle-id>?<anchor>`
// takes, so every row here opens the pane already scrolled to the setting. No
// Accessibility grant, no AX walk of another app's window, no private API — just
// plists and NSWorkspace.open, which is why this feature costs nothing at rest.
//
// TWO THINGS THAT WILL BITE A FUTURE EDITOR:
//
// 1. THE `title` IS APPLE'S SENTENCE, NOT THE UI LABEL. The Full Disk Access
//    pane's entry is titled "Allow applications to access all user files"; the
//    words a person types — "full disk access" — appear only in `index`. So the
//    keywords are not decoration: they are half the searchable surface, and they
//    are matched TERM BY TERM (see PounceItem.searchKeywords / matchScore).
//    Fuzzy-matching the joined blob instead would make a 200-character keyword
//    string a subsequence of nearly any query, and every settings row would
//    match everything.
//
// 2. ANCHORS AND PANE NAMES ARE UNDOCUMENTED AND MOVE BETWEEN RELEASES. Nothing
//    here is hardcoded for that reason: the pane list, the anchors and the
//    titles are all read off disk at daemon start. A macOS update that renames
//    `Privacy_AllFiles` produces a different row, not a broken one — and a pane
//    that stops shipping a .searchTerms file simply contributes its own row and
//    no sub-items. Never inline a table of anchors here to "make it faster".
//
// Localized like everything else: the pane's display name comes from the
// extension's InfoPlist.loctable (the English Info.plist value is often the
// internal build name — "SoftwareUpdateSettingsExtension", "LoginItems"), and
// the .searchTerms file is picked per the user's preferred language with an
// English fallback.
//
// Foundation-only by design (no AppKit/SwiftUI), so tests/run.sh can compile it
// — see tests/systemsettings_tests.swift.

// One addressable thing in System Settings: a pane (anchor nil) or one setting
// inside it.
struct SettingsPaneEntry: Equatable {
    let paneID: String      // the extension's bundle id
    let anchor: String?     // nil → the pane itself
    let title: String       // what the row displays
    let pane: String        // the pane's localized name, shown as the subtitle
    let keywords: [String]  // Apple's synonyms, matched one term at a time
    // The bundle whose Finder icon the row shows: the pane's own extension when
    // it ships one (so Privacy & Security's rows carry the blue hand, Appearance's
    // the half-disc), System Settings.app when it doesn't. Sub-items deliberately
    // inherit their pane's icon — that's what makes a list of settings scannable
    // without reading every subtitle.
    let iconPath: String

    // The frecency key, the `items` override key, and the `pounce run` argument.
    // One grammar, parsed in exactly one place — see ItemTarget.
    var itemKey: String { "setting:" + target }

    // The part after "setting:", which is also the part after the URL scheme.
    var target: String { anchor.map { "\(paneID)?\($0)" } ?? paneID }

    var url: String { SettingsPaneStore.urlScheme + target }
}

final class SettingsPaneStore {
    static let shared = SettingsPaneStore()

    static let extensionsDir = "/System/Library/ExtensionKit/Extensions"

    // Every row opens through this, whether it was clicked in the palette or
    // fired by a hotkey bound to a `setting:` target.
    static let urlScheme = "x-apple.systempreferences:"

    // The fallback row icon, for a pane that ships none of its own. ItemRow
    // resolves an "app:" icon to that bundle's real Finder icon — which works on
    // an .appex just as well as on an .app, and is why these rows can carry the
    // pane's actual artwork instead of one shared SF Symbol.
    static let iconPath = "/System/Applications/System Settings.app"

    // Pane rows sort BELOW everything at an empty query and climb back by use —
    // the same soft demotion AppScanner applies to never-opened Apple utilities
    // and ShortcutsStore to the library. Fifty panes would otherwise squat the
    // seven empty-query slots on the day this ships, purely on alphabetical luck
    // among zero-frecency items. Typed search is unaffected (matchScore only
    // reads `baseBoost > 0`). Sub-items don't need it: they're gated out of the
    // empty query entirely by minQueryLength.
    static let emptyQueryPenalty = 5.0

    // How long a cold call is willing to wait for the scan. Warm it's served
    // from memory; cold it's ~240 bundles' Info.plists plus a .searchTerms parse
    // for the 50 that are settings panes — measured at 57ms on an M-series Mac.
    // This runs on the main thread (DaemonState.load does), so the wait is
    // bounded for the same reason ShortcutsStore's is: a palette that doesn't
    // paint is the one thing pounce is never allowed to be. Past the budget the
    // call gives up and returns nothing; the scan it started still finishes and
    // populates the snapshot, so the next summon has the panes.
    private static let coldWaitBudget: TimeInterval = 0.25

    private var cache: [SettingsPaneEntry]? = nil    // nil until the first scan
    private let lock = NSLock()

    // Mirrors `systemSettings.enabled`, pushed in by whoever last read the
    // config rather than read from here — Settings lives in Config.swift, which
    // pulls in AppKit, and this file stays Foundation-only.
    private var enabled = true

    func setEnabled(_ on: Bool) { lock.lock(); enabled = on; lock.unlock() }

    // MARK: Parsing
    //
    // A .searchTerms file, as a dict keyed by anchor:
    //
    //   { "Privacy_AllFiles": { "localizableStrings": [ { title, index } ] } }
    //
    // Anchors are returned sorted so a scan is reproducible; the palette re-sorts
    // by score anyway, but a stable order keeps tests and logs readable.
    static func parseSearchTerms(_ plist: [String: Any], paneID: String, pane: String,
                                 icon: String = iconPath) -> [SettingsPaneEntry] {
        var entries: [SettingsPaneEntry] = []
        for anchor in plist.keys.sorted() {
            guard let group = plist[anchor] as? [String: Any],
                  let strings = group["localizableStrings"] as? [[String: Any]] else { continue }
            for entry in strings {
                guard let title = (entry["title"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
                else { continue }
                // A sub-item that merely restates its pane ("Appearance" inside
                // Appearance) is the pane row twice over. Drop it: the pane row
                // is the one that's always visible and always openable.
                if title.compare(pane, options: .caseInsensitive) == .orderedSame { continue }
                entries.append(SettingsPaneEntry(
                    paneID: paneID, anchor: anchor, title: title, pane: pane,
                    keywords: keywords(entry["index"] as? String), iconPath: icon))
            }
        }
        return entries
    }

    // "files, full disk access, complete" → ["files", "full disk access", …].
    // Deduped and lowercased because they're only ever fuzzy-matched, never
    // shown; a term equal to the title would just score the same thing twice.
    static func keywords(_ index: String?) -> [String] {
        guard let index else { return [] }
        var seen = Set<String>()
        return index.split(separator: ",").compactMap { part in
            let term = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !term.isEmpty, seen.insert(term).inserted else { return nil }
            return term
        }
    }

    // The .lproj names to try, best first, for the user's language. "en-CA"
    // yields en_CA → en → Base → English, so a locale nobody localized still
    // lands on real English strings rather than nothing.
    static func localeCandidates(_ preferred: [String] = Locale.preferredLanguages) -> [String] {
        var out: [String] = []
        for tag in preferred.prefix(3) {
            let underscored = tag.replacingOccurrences(of: "-", with: "_")
            out.append(underscored)
            if let language = underscored.split(separator: "_").first { out.append(String(language)) }
        }
        out.append(contentsOf: ["en", "Base", "English"])
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: Scanning

    // The launcher's rows. `subItemMinQuery` is how many characters the user has
    // to type before the settings INSIDE a pane join the list — panes themselves
    // are always present. See DaemonState.matchScore for where that's enforced.
    func items(subItemMinQuery: Int) -> [PounceItem] {
        lock.lock(); var snapshot = cache; lock.unlock()
        if snapshot == nil {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                self.rebuild(force: true)   // reaching here IS the setting being on
                done.signal()
            }
            if done.wait(timeout: .now() + Self.coldWaitBudget) == .timedOut {
                NSLog("pounce: the System Settings scan exceeded \(Self.coldWaitBudget)s — "
                    + "showing the launcher without settings this time")
                return []
            }
            lock.lock(); snapshot = cache; lock.unlock()
        }
        return (snapshot ?? []).map { PounceItem.setting($0, subItemMinQuery: subItemMinQuery) }
    }

    // Scanned once, at daemon start. Unlike apps or shortcuts, the pane list can
    // only change with a macOS update — which restarts the daemon anyway — so
    // there is no refresh timer here on purpose.
    func warm() {
        DispatchQueue.global(qos: .utility).async { self.rebuild() }
    }

    private func rebuild(force: Bool = false) {
        lock.lock(); let on = enabled; lock.unlock()
        guard on || force else { return }
        let entries = Self.scan()
        lock.lock(); cache = entries; lock.unlock()
    }

    // Walk every extension bundle and keep the ones that say they can be opened
    // by URL. ~240 directories, most of which aren't settings panes at all and
    // are rejected on their Info.plist alone; the 50 that are yield ~700 settings
    // between them.
    static func scan(dir: String = extensionsDir) -> [SettingsPaneEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        let locales = localeCandidates()
        var entries: [SettingsPaneEntry] = []

        for name in names.sorted() where name.hasSuffix(".appex") {
            let bundle = (dir as NSString).appendingPathComponent(name)
            let resources = (bundle as NSString).appendingPathComponent("Contents/Resources")
            guard let info = plist(at: (bundle as NSString).appendingPathComponent("Contents/Info.plist")),
                  let paneID = info["CFBundleIdentifier"] as? String,
                  let attributes = (info["EXAppExtensionAttributes"] as? [String: Any])?[
                      "SettingsExtensionAttributes"] as? [String: Any],
                  attributes["allowsXAppleSystemPreferencesURLScheme"] as? Bool == true
            else { continue }

            let pane = displayName(info: info, resources: resources, locales: locales)
                ?? paneID
            let icon = hasIcon(info: info, resources: resources) ? bundle : iconPath
            entries.append(SettingsPaneEntry(paneID: paneID, anchor: nil, title: pane,
                                             pane: pane, keywords: [], iconPath: icon))

            guard let file = attributes["searchTermsFileName"] as? String,
                  let terms = firstPlist(named: file + ".searchTerms",
                                         in: resources, locales: locales)
            else { continue }
            entries.append(contentsOf: parseSearchTerms(terms, paneID: paneID, pane: pane,
                                                        icon: icon))
        }
        return entries
    }

    // Does this bundle have artwork of its own? NSWorkspace hands back a generic
    // document icon rather than failing when it doesn't, so the question has to
    // be answered here — one pane in fifty (Time Machine, today) ships none.
    static func hasIcon(info: [String: Any], resources: String) -> Bool {
        if info["CFBundleIcons"] != nil || info["CFBundleIconFile"] != nil { return true }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? []
        return contents.contains { $0.hasSuffix(".icns") }
    }

    // The pane's name as System Settings shows it. InfoPlist.loctable first:
    // the Info.plist value is frequently the internal target name
    // ("SoftwareUpdateSettingsExtension" for Software Update), while the loctable
    // is what the sidebar actually renders.
    static func displayName(info: [String: Any], resources: String, locales: [String]) -> String? {
        if let table = plist(at: (resources as NSString).appendingPathComponent("InfoPlist.loctable")) {
            for locale in locales {
                if let strings = table[locale] as? [String: Any],
                   let name = strings["CFBundleDisplayName"] as? String, !name.isEmpty {
                    return name
                }
            }
        }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = info[key] as? String, !name.isEmpty { return name }
        }
        return nil
    }

    private static func firstPlist(named file: String, in resources: String,
                                   locales: [String]) -> [String: Any]? {
        for locale in locales {
            let path = (resources as NSString)
                .appendingPathComponent("\(locale).lproj/\(file)")
            if let found = plist(at: path) { return found }
        }
        return nil
    }

    // Reads XML and binary plists alike (both shapes ship in these bundles).
    private static func plist(at path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)
        else { return nil }
        return object as? [String: Any]
    }

    // MARK: Keeping one pane from taking the whole list

    // Accessibility alone ships 342 settings — half of everything here — so a
    // three-letter query can otherwise return one pane's worth of rows and
    // nothing else. Cap how many SUB-ITEMS any single pane contributes to a
    // result list, keeping the highest-scoring ones (the list arrives sorted).
    // Pane rows and every non-settings row pass through untouched, which is what
    // makes this safe to run over the whole launcher list.
    static func capPerPane(_ items: [PounceItem], limit: Int) -> [PounceItem] {
        guard limit > 0 else { return items }
        var perPane: [String: Int] = [:]
        return items.filter { item in
            guard case .setting(let target)? = ItemTarget.parse(item.frecencyKey),
                  let split = target.firstIndex(of: "?") else { return true }
            let pane = String(target[target.startIndex..<split])
            let seen = (perPane[pane] ?? 0) + 1
            perPane[pane] = seen
            return seen <= limit
        }
    }
}
