import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Update nudge (hourly release check)
//
// Closes the loop the self-update command can't: `update-pounce.sh` can APPLY
// an update on the installs that own their own bytes, but nothing ever told the
// user one existed — a drag-install sat on its download-day version forever.
// The daemon checks GitHub's latest-release tag hourly and, when it's newer
// than the running build, nudges on two surfaces, both quiet:
//
//   palette   the Update Pounce row is renamed ("Update Pounce — 2026.07.30
//             available") AND pinned to the first row on an empty query
//             (State.updateNoticeItem). The rename alone was close to
//             invisible: an empty query lists the top `maxEmpty` rows by
//             frecency, and nobody runs the updater often enough to rank
//             there — you'd have to already suspect an update to search for
//             it. Pinned, the next ⌘Space shows it without interrupting
//             anything, and it disappears the moment you're current. ⌘⏎ on
//             that row skips the version: the pin is the one thing here that
//             takes over a row you didn't ask for, so it owes you a way out —
//             and for the Nix cohorts ⏎ can't clear it by installing. Skipping
//             is per-version, so the next release pins again.
//   banner    a macOS notification on first discovery, then at most once a
//             day while the update stays pending (see `renotify`) — enough to
//             not be forgotten, rare enough not to be a nag.
//
// It never applies anything by itself. Auto-updating is wrong for two of the
// three cohorts below — a Nix/rice install lives in an immutable store and
// would be reverted by the next rebuild, and a brew install expects brew to
// own versions — so the keystroke stays the user's.
//
// Follows the CurrencyRates cache contract: keystrokes only ever read the
// in-memory `availableVersion`; the network happens on a background queue off
// the summon path. Gated by `updates.check` in config.json (default on) and
// off for "dev" builds. With currency, this is the second of pounce's two
// outbound calls — both gated, neither carries more than an IP and a
// user-agent. Hourly is ~24 unauthenticated API calls a day against GitHub's
// 60/hour/IP limit, and a cached answer inside the hour costs nothing.

// How THIS install takes an update — which decides the ONE thing the nudge
// must get right: the command it tells the user to run. Mirrors the cohort
// detection in update-pounce.sh (keep the two in step); the script is what
// actually runs when the pinned row is committed, so a mismatch here would
// promise an install the script then refuses.
enum InstallKind {
    case homebrew    // <brew prefix>/…/Pounce.app — the script runs `brew upgrade`
    case direct      // dragged to /Applications — the script swaps the app in place
    case rice        // the nebelhaus rice's re-signed copy — `haus update`
    case nix         // a bare store path (own flake, `nix run`) — flake update
    case unknown

    // Whether update-pounce.sh will actually install for this cohort. The Nix
    // cohorts get a notification pointing at their flake instead.
    var canSelfUpdate: Bool { self == .homebrew || self == .direct }

    // The subtitle under the pinned row: what to DO, in this install's own
    // vocabulary. "bench ship / rebuild" is developer-speak — a rice user's
    // command is `haus update` (docs: reference/haus.md).
    var actionHint: String {
        switch self {
        case .homebrew: return "Return to run brew upgrade"
        case .direct:   return "Return to install it"
        case .rice:     return "Run haus update in a terminal to pick it up"
        case .nix:      return "Update your flake input to pick it up"
        case .unknown:  return "Return to update"
        }
    }

    // The same instruction, as a notification sentence.
    var bannerHint: String {
        switch self {
        case .homebrew, .direct, .unknown:
            return "Open the palette and run Update Pounce to install."
        case .rice: return "Run haus update to pick it up."
        case .nix:  return "Update your pounce flake input to pick it up."
        }
    }

    // Pure so the suite can exercise every cohort without a bundle. Symlinks
    // are resolved first, exactly as the script's `readlink -f` does: the rice
    // publishes /Applications/Pounce.app as a symlink into its re-signed copy,
    // so the unresolved path would read as a plain drag-install.
    static func detect(bundlePath: String, home: String) -> InstallKind {
        if bundlePath.hasPrefix("/nix/store/") { return .nix }
        if bundlePath.hasPrefix(home + "/.local/state/pounce") { return .rice }
        if bundlePath.hasPrefix("/opt/homebrew/") || bundlePath.hasPrefix("/usr/local/") {
            return .homebrew
        }
        if bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/") {
            return .direct
        }
        return .unknown
    }
}

final class UpdateNudge {
    static let shared = UpdateNudge()

    // Newer-than-running version ("2026.07.30", no leading v), or nil. Main
    // thread only, like the registry it decorates.
    private(set) var availableVersion: String?
    // The version the user waved off with ⌘⏎, persisted. Per-version on
    // purpose: skipping 2026.07.30 says nothing about 2026.08.01.
    private(set) var dismissedVersion: String?
    private var fetching = false

    // Whether the palette should PIN the nudge to its first row. Pure so the
    // suite can pin the one rule that matters: a dismissal must expire when a
    // newer release lands, or "skip" silently becomes "never tell me again".
    static func shouldPin(available: String?, dismissed: String?) -> Bool {
        guard let available else { return false }
        return available != dismissed
    }

    // The pending update worth interrupting the first row for.
    var pendingVersion: String? {
        Self.shouldPin(available: availableVersion, dismissed: dismissedVersion)
            ? availableVersion : nil
    }

    // ⌘⏎ on the nudge: stop pinning and stop notifying for THIS version. The
    // row keeps its rename, so searching "update" still tells you one is
    // waiting — dismissal hides the interruption, not the fact.
    func dismiss() {
        guard let v = availableVersion else { return }
        dismissedVersion = v
        let prev = Self.readState()
        Self.writeState(checkedAt: prev?.checkedAt ?? Date().timeIntervalSince1970,
                        latest: prev?.latest ?? v, notified: prev?.notified,
                        notifiedAt: prev?.notifiedAt, dismissed: v)
    }

    static let endpoint = URL(string: "https://api.github.com/repos/hausfold/pounce/releases/latest")!
    // Hourly: the nudge should show up the day it's cut, not up to a day late.
    static let maxAge: TimeInterval = 3600
    // …but the BANNER is the invasive surface, so it repeats at most daily
    // while the same version stays pending. The pinned palette row carries the
    // reminder in between, and costs the user nothing.
    static let renotify: TimeInterval = 24 * 3600

    // {"checkedAt": epoch, "latest": "…", "notified": "…", "notifiedAt": epoch}
    // — `latest` answers offline restarts inside maxAge; `notified`/`notifiedAt`
    // are what keep the banner to once a day per version across daemon restarts.
    static var statePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce/update-nudge.json")
    }

    lazy var installKind: InstallKind = InstallKind.detect(
        bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
        home: FileManager.default.homeDirectoryForCurrentUser.path)

    // CalVer ordering. The zero-padded date part compares lexicographically
    // ("2026.07.29" < "2026.07.30"); the same-day `-N` suffix must compare
    // NUMERICALLY — a pure string compare would put "-10" before "-2", which
    // is exactly the silent-never-nudge bug the tests pin.
    static func isNewer(_ candidate: String, than running: String) -> Bool {
        guard !running.isEmpty, running != "dev" else { return false }
        let c = split(candidate), r = split(running)
        return c.date == r.date ? c.repeatN > r.repeatN : c.date > r.date
    }

    private static func split(_ version: String) -> (date: String, repeatN: Int) {
        guard let dash = version.firstIndex(of: "-") else { return (version, 0) }
        return (String(version[..<dash]),
                Int(version[version.index(after: dash)...]) ?? 0)
    }

    // The palette-side nudge: a pending update renames the update command's row
    // in place and swaps its description for this install's actual command.
    // Matching on the script's id keeps this working for a user copy shadowing
    // the built-in.
    func decorate(_ entry: CommandRegistry.Entry) -> CommandRegistry.Entry? {
        guard entry.id == "update-pounce", let v = availableVersion else { return nil }
        return CommandRegistry.Entry(
            id: entry.id,
            name: "\(entry.name) — \(v) available",
            description: installKind.actionHint,
            icon: entry.icon,
            submenu: entry.submenu,
            scriptPath: entry.scriptPath)
    }

    // Non-blocking hourly check; safe to call repeatedly (daemon start + the
    // timer in DaemonMode.run). Main thread only.
    func warm() {
        guard pounceVersion != "dev", !fetching else { return }
        let cached = Self.readState()
        if let cached, Date().timeIntervalSince1970 - cached.checkedAt < Self.maxAge {
            // Fresh enough: surface the cached answer, skip the network. Keeps
            // the ORIGINAL checkedAt — restamping it here would push the next
            // fetch out by an hour on every daemon start and, for someone who
            // restarts often, mean the check never actually runs.
            apply(latest: cached.latest, previous: cached, checkedAt: cached.checkedAt)
            return
        }
        fetching = true
        var req = URLRequest(url: Self.endpoint)
        req.setValue("pounce-update-check", forHTTPHeaderField: "user-agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var latest: String?
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = obj["tag_name"] as? String {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                // The tag round-trips into a shell one-liner (the banner) and
                // the UI — accept nothing beyond CalVer-shaped characters.
                if version.range(of: "^[0-9][0-9.\\-]*$", options: .regularExpression) != nil {
                    latest = version
                }
            }
            DispatchQueue.main.async {
                self.fetching = false
                // Network/API miss: stamp nothing, so the next warm() retries
                // instead of sitting out the hour on a failure.
                guard let latest else { return }
                self.apply(latest: latest, previous: Self.readState(),
                           checkedAt: Date().timeIntervalSince1970)
            }
        }.resume()
    }

    // MARK: - Internals

    // Reconcile one answer (cached or freshly fetched) into the in-memory
    // nudge, the banner, and the state file. Main thread only.
    private func apply(latest: String?, previous: State?, checkedAt: TimeInterval) {
        guard let latest else { return }
        let now = Date().timeIntervalSince1970
        // Rehydrate the dismissal before deciding anything: a daemon restart
        // must not resurrect a nudge the user already waved off.
        dismissedVersion = previous?.dismissed
        guard Self.isNewer(latest, than: pounceVersion) else {
            // Up to date (or ahead — a rice user can run a build newer than the
            // last tagged release). Clear any stale nudge and remember the
            // answer so the next hour is a no-op.
            availableVersion = nil
            Self.writeState(checkedAt: checkedAt, latest: latest,
                            notified: previous?.notified, notifiedAt: previous?.notifiedAt,
                            dismissed: previous?.dismissed)
            return
        }
        availableVersion = latest
        // A dismissal silences the banner too — waving the row away and then
        // being notified about the same version tomorrow is the nag this whole
        // design is trying not to be.
        let firstSighting = previous?.notified != latest
        let staleReminder = (previous?.notifiedAt).map { now - $0 >= Self.renotify } ?? true
        let due = Self.shouldPin(available: latest, dismissed: dismissedVersion)
            && (firstSighting || staleReminder)
        if due { Self.postBanner(version: latest, kind: installKind) }
        Self.writeState(checkedAt: checkedAt, latest: latest, notified: latest,
                        notifiedAt: due ? now : previous?.notifiedAt,
                        dismissed: previous?.dismissed)
    }

    private struct State {
        let checkedAt: TimeInterval
        let latest: String?
        let notified: String?
        let notifiedAt: TimeInterval?
        let dismissed: String?
    }

    private static func readState() -> State? {
        guard let data = try? Data(contentsOf: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkedAt = obj["checkedAt"] as? TimeInterval
        else { return nil }
        return State(checkedAt: checkedAt,
                     latest: obj["latest"] as? String,
                     notified: obj["notified"] as? String,
                     notifiedAt: obj["notifiedAt"] as? TimeInterval,
                     dismissed: obj["dismissed"] as? String)
    }

    private static func writeState(checkedAt: TimeInterval, latest: String?,
                                   notified: String?, notifiedAt: TimeInterval?,
                                   dismissed: String?) {
        var obj: [String: Any] = ["checkedAt": checkedAt]
        if let latest { obj["latest"] = latest }
        if let notified { obj["notified"] = notified }
        if let notifiedAt { obj["notifiedAt"] = notifiedAt }
        if let dismissed { obj["dismissed"] = dismissed }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: statePath, options: .atomic)
    }

    // The same notification surface the command scripts use. The version is
    // regex-vetted above and the hint is a compile-time constant, so the
    // interpolation is safe.
    private static func postBanner(version: String, kind: InstallKind) {
        let script = "display notification \"\(kind.bannerHint)\" " +
                     "with title \"Pounce \(version) is out\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
