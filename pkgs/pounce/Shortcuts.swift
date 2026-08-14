import Foundation

// MARK: - The Shortcuts library as launcher rows
//
// WHY THIS EXISTS, AND WHY IT ISN'T "App Intents".
//
// macOS 26's Spotlight runs an app's **App Intents** directly — type "Add to
// Perch Shelf", press ⏎, the intent fires with no Shortcuts app in sight. The
// obvious ask is for pounce to do the same. It can't, and the reason is worth
// writing down so nobody re-litigates it:
//
//   * DISCOVERY is trivial. Every intent-exposing app ships
//     `Contents/Resources/Metadata.appintents/extract.actionsdata` — plain JSON
//     with the title, description and even the SF Symbol for each action.
//   * INVOCATION has no public API. Spotlight reaches the intent through
//     AppIntentsIndex/AppIntentsServices, both private and both entitled. The
//     `shortcuts` CLI is no help: `shortcuts list` returns only the user's saved
//     library and deliberately omits every App Shortcut. So a row parsed out of
//     actionsdata would be a row with nothing behind it.
//
// The supported bridge is the Shortcuts library itself. Wrap an App Intent in a
// one-action shortcut (ten seconds in Shortcuts.app) and it becomes a normal
// library entry — which this file then surfaces as a first-class launcher row,
// searchable and runnable in one keystroke, exactly like an app. That's the
// whole feature: pounce indexes what it can actually run.
//
// Cost model matches AppScanner: `shortcuts list` is ~16ms, which is 16ms too
// many on the ⌘Space path, so the parsed library lives in an in-memory snapshot
// that a background task refreshes. The first call before warm() lands pays one
// synchronous run so the list is never mysteriously empty; every call after is
// served from the snapshot.
//
// Foundation-only by design (no AppKit/SwiftUI), so tests/run.sh can compile it
// — see tests/shortcuts_tests.swift, which asserts on the parser.

struct ShortcutEntry: Equatable {
    let name: String
    let id: String        // the library UUID, from `shortcuts list --show-identifiers`
}

final class ShortcutsStore {
    static let shared = ShortcutsStore()

    // Ships with macOS since Monterey. Absent only on a stripped system, where
    // rebuild() simply yields nothing and the launcher is unchanged.
    static let cli = "/usr/bin/shortcuts"

    // The row icon is Shortcuts.app's own, so a shortcut row is recognisable at
    // a glance without every entry sharing one anonymous SF Symbol. ItemRow
    // resolves an "app:" icon to that bundle's real Finder icon (see Rows.swift).
    static let iconPath = "/System/Applications/Shortcuts.app"

    // Shortcuts sort BELOW everything at an empty query and have to climb back
    // by actual use — the same soft demotion AppScanner applies to never-opened
    // Apple utilities, and for the same reason: a library of 60 shortcuts would
    // otherwise squat the seven empty-query slots on the day this feature ships,
    // purely on alphabetical luck among zero-frecency items. Typed search is
    // unaffected — matchScore only reads `baseBoost > 0`, so a negative boost is
    // neutral there, and "add to perch" lands on the shortcut exactly as it
    // would have. Sized to the frecency scale (see Frecency), so using one lifts
    // it back out of the basement.
    static let emptyQueryPenalty = 5.0

    private var cache: [ShortcutEntry]? = nil     // nil until the first list
    private var refreshTimer: Timer?
    private let lock = NSLock()

    // Mirrors `shortcuts.enabled`, pushed in by whoever last read the config
    // (the daemon at startup, then DaemonState.load on every summon) rather than
    // read from here — Settings lives in Config.swift, which pulls in AppKit,
    // and this file stays Foundation-only so tests/run.sh can compile it.
    // Only the background refresh consults it; see rebuild().
    private var enabled = true

    func setEnabled(_ on: Bool) {
        lock.lock(); enabled = on; lock.unlock()
    }

    // MARK: Parsing
    //
    // `--show-identifiers` renders one shortcut per line as `Name (UUID)`. A
    // shortcut name may itself contain parentheses ("Save to Photos (use with
    // cobalt)" is a real one), so the identifier is taken as the LAST
    // parenthesised group and only accepted when it actually looks like a UUID.
    // A line that fails that check is dropped rather than guessed at: running
    // the wrong shortcut is worse than not listing one, and the alternative —
    // falling back to `shortcuts run <name>` — is ambiguous the moment two
    // shortcuts share a name, which the library does not prevent.
    static func parse(_ output: String) -> [ShortcutEntry] {
        output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return nil }
            let id = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
            guard isUUID(id) else { return nil }
            let name = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return ShortcutEntry(name: name, id: id)
        }
    }

    // 8-4-4-4-12 hex, the shape `shortcuts` emits. Hand-rolled rather than
    // UUID(uuidString:) so the check is exact about grouping — UUID's parser
    // accepts spellings the CLI never produces, and this is a disambiguator
    // between "identifier" and "part of the name", not a validator.
    static func isUUID(_ s: String) -> Bool {
        let groups = s.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return groups.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }

    // MARK: Reading the library

    // How long a cold call is willing to wait for `shortcuts list`. Warm it's
    // ~16ms; cold at login, the Shortcuts XPC service has to spin up first and
    // there is no ceiling on that. This runs on the main thread (DaemonState.load
    // does), so an unbounded wait would be a palette that doesn't paint — the
    // one thing pounce is never allowed to be. Past the budget the call gives up
    // and returns nothing; the rebuild it started still finishes and populates
    // the snapshot, so the next summon (or the 60s timer) has the library.
    private static let coldWaitBudget: TimeInterval = 0.25

    // The launcher's rows. Served from the snapshot; only a cold cache (before
    // warm() has landed, or in a no-daemon `pounce --launcher`) pays for a list,
    // and even then only up to coldWaitBudget.
    func items() -> [PounceItem] {
        lock.lock(); var snapshot = cache; lock.unlock()
        if snapshot == nil {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                self.rebuild(force: true)   // reaching here IS the setting being on
                done.signal()
            }
            if done.wait(timeout: .now() + Self.coldWaitBudget) == .timedOut {
                NSLog("pounce: `shortcuts list` exceeded \(Self.coldWaitBudget)s — "
                    + "showing the launcher without shortcuts this time")
                return []
            }
            lock.lock(); snapshot = cache; lock.unlock()
        }
        return (snapshot ?? []).map {
            PounceItem.shortcut(name: $0.name, id: $0.id)
        }
    }

    func warm() {
        DispatchQueue.global(qos: .utility).async { self.rebuild() }
        DispatchQueue.main.async {
            guard self.refreshTimer == nil else { return }
            // Shortcuts are authored by hand, not installed in bursts, so a
            // minute's staleness is invisible — the same interval AppScanner's
            // filesystem walk uses.
            self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                DispatchQueue.global(qos: .utility).async { self.rebuild() }
            }
        }
    }

    private func rebuild(force: Bool = false) {
        // warm() and its timer are unconditional so that re-enabling the feature
        // needs no daemon restart — but a user who turned it OFF should not go on
        // paying a subprocess a minute for the daemon's whole life. Bailing here
        // rather than skipping the timer keeps that property: the cache is left
        // untouched (nil, not empty), so the first items() call after the setting
        // flips back on repopulates it. (items() itself is only reached when the
        // setting is on, and forces a rebuild through the cold path regardless.)
        lock.lock(); let on = enabled; lock.unlock()
        guard on || force else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.cli) else {
            lock.lock(); cache = []; lock.unlock()
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.cli)
        process.arguments = ["list", "--show-identifiers"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("pounce daemon: `shortcuts list` failed to start: \(error)")
            lock.lock(); cache = []; lock.unlock()
            return
        }
        // Read before waiting: a library big enough to fill the pipe buffer
        // would deadlock a wait-then-read.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let entries = Self.parse(String(data: data, encoding: .utf8) ?? "")
        lock.lock(); cache = entries; lock.unlock()
    }

    // MARK: Running one

    // Fire and forget. `shortcuts run` blocks for as long as the shortcut takes
    // — which for anything with a UI prompt is "until the user is done" — so the
    // daemon never waits on it, exactly like a spawned command script.
    static func run(id: String) {
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            NSLog("pounce daemon: cannot run shortcut \(id) — \(cli) is missing")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["run", id]
        process.standardOutput = FileHandle.nullDevice
        // Discarded rather than captured: a shortcut can run for minutes, and a
        // pipe nobody drains would eventually block it. The exit status below is
        // the cheap half of the signal — enough to tell "it ran and failed" from
        // "pounce never spawned it", which is the distinction a bug report needs.
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { p in     // reap asynchronously
            guard p.terminationStatus != 0 else { return }
            // Most likely a shortcut deleted since the last 60s refresh, so the
            // row outlived the thing behind it.
            NSLog("pounce daemon: shortcut \(id) exited \(p.terminationStatus) "
                + "(deleted since the last refresh? try `shortcuts run \(id)` in a terminal)")
        }
        do {
            try process.run()
        } catch {
            NSLog("pounce daemon: failed to run shortcut \(id): \(error)")
        }
    }
}
