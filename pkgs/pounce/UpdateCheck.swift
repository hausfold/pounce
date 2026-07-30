import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Update nudge (daily release check)
//
// Closes the loop the self-update command can't: `update-pounce.sh` can APPLY
// an update on any install, but nothing ever told the user one existed — a
// drag-install stayed on its download-day version forever. The daemon checks
// GitHub's latest-release tag once a day and, when it's newer than the running
// build, nudges twice, both quiet:
//
//   palette   the Update Pounce row is renamed while an update is pending
//             ("Update Pounce — 2026.07.30 available"), so the next summon
//             shows it exactly where the fix is applied (Entry.swift decorates
//             via `decorate`).
//   banner    ONE macOS notification per new version (persisted in the state
//             file), through the same osascript path the command scripts use.
//
// It never applies anything by itself — updating stays the user's keystroke.
//
// Follows the CurrencyRates cache contract: keystrokes only ever read the
// in-memory `availableVersion`; the network happens on a background queue off
// the summon path. Gated by `updates.check` in config.json (default on), and
// self-disabling on Nix-managed installs (their updates ride the flake, so a
// nudge would only be noise) and on "dev" builds. With currency, this is the
// second of pounce's two outbound calls — both gated, neither carries more
// than an IP and a user-agent.

final class UpdateNudge {
    static let shared = UpdateNudge()

    // Newer-than-running version ("2026.07.30", no leading v), or nil. Main
    // thread only, like the registry it decorates.
    private(set) var availableVersion: String?
    private var fetching = false

    static let endpoint = URL(string: "https://api.github.com/repos/nebelhaus/pounce/releases/latest")!
    static let maxAge: TimeInterval = 24 * 3600
    // {"checkedAt": epoch, "latest": "2026.07.30", "notified": "2026.07.30"} —
    // `latest` answers offline restarts inside maxAge, `notified` is what makes
    // the banner once-per-version.
    static var statePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce/update-nudge.json")
    }

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

    // Nix-managed installs — the store itself, or the rice's re-signed stable
    // copy in ~/.local/state/pounce — update via the flake ripple; the person
    // holding the flake IS the release process, so a nudge tells them nothing.
    static func isNixManaged() -> Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let riceCopy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/pounce").path
        return path.hasPrefix("/nix/store/") || path.hasPrefix(riceCopy)
    }

    // The palette-side nudge: a pending update renames the update command's row
    // in place. Matching on the script's id keeps this working for a user copy
    // shadowing the built-in.
    func decorate(_ entry: CommandRegistry.Entry) -> CommandRegistry.Entry? {
        guard entry.id == "update-pounce", let v = availableVersion else { return nil }
        return CommandRegistry.Entry(
            id: entry.id,
            name: "\(entry.name) — \(v) available",
            description: "New release ready — run to install",
            icon: entry.icon,
            submenu: entry.submenu,
            scriptPath: entry.scriptPath)
    }

    // Non-blocking daily check; safe to call repeatedly (daemon start + a 6h
    // timer, same cadence style as CurrencyRates). Main thread only.
    func warm() {
        guard pounceVersion != "dev", !fetching else { return }
        let state = Self.readState()
        if let state, Date().timeIntervalSince1970 - state.checkedAt < Self.maxAge {
            // Fresh enough: surface the cached answer, skip the network.
            if let latest = state.latest, Self.isNewer(latest, than: pounceVersion) {
                availableVersion = latest
            }
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
                guard let latest else {
                    // Network/API miss: stamp nothing, so the next warm() retries.
                    return
                }
                let notified = Self.readState()?.notified
                if Self.isNewer(latest, than: pounceVersion) {
                    self.availableVersion = latest
                    if notified != latest {
                        Self.postBanner(version: latest)
                    }
                    Self.writeState(latest: latest, notified: latest)
                } else {
                    self.availableVersion = nil
                    Self.writeState(latest: latest, notified: notified)
                }
            }
        }.resume()
    }

    // MARK: - Internals

    private struct State {
        let checkedAt: TimeInterval
        let latest: String?
        let notified: String?
    }

    private static func readState() -> State? {
        guard let data = try? Data(contentsOf: statePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checkedAt = obj["checkedAt"] as? TimeInterval
        else { return nil }
        return State(checkedAt: checkedAt,
                     latest: obj["latest"] as? String,
                     notified: obj["notified"] as? String)
    }

    private static func writeState(latest: String?, notified: String?) {
        var obj: [String: Any] = ["checkedAt": Date().timeIntervalSince1970]
        if let latest { obj["latest"] = latest }
        if let notified { obj["notified"] = notified }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: statePath, options: .atomic)
    }

    // The same notification surface the command scripts use. The version is
    // regex-vetted above, so interpolation is safe.
    private static func postBanner(version: String) {
        let script = "display notification \"Open the palette and run Update Pounce to install.\" " +
                     "with title \"Pounce \(version) is out\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
