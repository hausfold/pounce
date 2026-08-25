// What the Settings window reads and writes: config.json itself, one line at a
// time.
//
// There is NO second copy of the settings. The window does not hold a model it
// syncs to disk on close, and it does not keep a `@AppStorage` shadow of
// anything — every control reads its value out of the file (through
// `Settings.load()`, so it shows what pounce will actually USE) and every click
// writes one line back with ConfigWriter. Close the window mid-edit and nothing
// is lost, because nothing was pending; edit the file in your editor with the
// window open and the window catches up the next time it comes forward.
//
// THE CURRENCY IS A JSON LITERAL, not a typed value. `ConfigSpec.sections()`
// already renders every default as JSON, so handing it a live `Settings`
// instead of a fresh one yields every CURRENT value in the same notation — the
// whole read side, for forty settings, in one call. The write side is the
// reverse: a control renders its new value with `ConfigSpec.json` and hands the
// string to `ConfigWriter.apply`. Nothing in between has to know that
// `maxEntries` is an Int.
//
// TWO CONSEQUENCES WORTH KNOWING:
//
//   1. A value equal to its default is written by COMMENTING THE LINE OUT (see
//      ConfigWriter). So a config only ever accumulates the decisions you
//      actually made, exactly as if you had edited it by hand, and switching
//      something on and off again leaves the file where it started.
//
//   2. Every write is followed by a re-read through `Settings.load()`, which
//      clamps (`scale`, `subItemMinQuery`) and falls back on anything it can't
//      parse. So a value the parser would refuse visibly snaps back to what
//      pounce is really going to do, instead of the window claiming a setting
//      that isn't in effect.

import Foundation
import SwiftUI

// Main-thread only, like `DaemonState` and for the same reason: it is read
// during SwiftUI layout. Not annotated `@MainActor`, because nothing else in
// pounce is and one file adopting it would put an isolation boundary through
// the middle of a single-module app.
final class ConfigStore: ObservableObject {
    /// The spec at its DEFAULTS — prose, control, symbol, and the default JSON
    /// each field falls back to. Fixed for the life of the window.
    let spec: [ConfigSection] = ConfigSpec.sections()

    /// Current value per field, as a JSON literal, keyed by `fieldKey`.
    @Published private(set) var values: [String: String] = [:]

    /// True when config.json is a symlink into the Nix store — home-manager
    /// wrote it from `haus.launcher.*`. Every control is read-only then, and
    /// `set` refuses BEFORE it touches anything: a write here either fails on a
    /// read-only store or, worse, succeeds against a file the next `haus
    /// rebuild` silently replaces. Re-read on every refresh, because a rebuild
    /// can happen while this window is open.
    @Published private(set) var isManagedExternally = false

    /// True when the file isn't there yet. Not an error — the first write
    /// creates it, annotated, exactly as `pounce config init` would.
    @Published private(set) var fileExists = false

    /// What the last write said when it didn't work. Silent on the happy path.
    @Published private(set) var writeError: String?

    let path = Settings.configPath

    init() { refresh() }

    /// "clipboard.maxEntries", or ".fnKey" for a top-level key. Only ever used
    /// as a dictionary key, so the leading dot is fine and the ambiguity a bare
    /// name would carry ("enabled" is in nine sections) is not.
    static func fieldKey(_ section: String?, _ name: String) -> String {
        "\(section ?? "").\(name)"
    }

    /// The default for a field, as JSON.
    func defaultJSON(_ section: String?, _ field: ConfigField) -> String { field.json }

    /// What the file says now — or the default, for a field the file never
    /// mentions.
    func value(_ section: String?, _ field: ConfigField) -> String {
        values[Self.fieldKey(section, field.name)] ?? field.json
    }

    /// True when this field is at its default, i.e. the file does not speak
    /// about it (or speaks about it and agrees).
    func isDefault(_ section: String?, _ field: ConfigField) -> Bool {
        value(section, field) == field.json
    }

    // MARK: - Reading

    /// Re-read the file. Cheap (one small file, one JSON5 parse), so it runs on
    /// every window activation as well as after every write — which is what
    /// makes editing config.json in your editor with this window open work
    /// rather than fight.
    func refresh() {
        isManagedExternally = ConfigMode.isNixManaged(path)
        fileExists = FileManager.default.fileExists(atPath: path.path)

        // The read trick: the same table, fed the LIVE settings instead of
        // fresh ones, renders every current value in the same JSON the defaults
        // are written in. Post-clamp and post-fallback, because that is what
        // `load()` returns and therefore what pounce will act on.
        var current: [String: String] = [:]
        for section in ConfigSpec.sections(defaults: Settings.load()) {
            for field in section.fields {
                current[Self.fieldKey(section.name, field.name)] = field.json
            }
        }
        values = current
    }

    // MARK: - Writing

    /// Put one setting in the file, or hand it back to its default.
    ///
    /// `json` is the new value as a JSON literal. Passing the field's own
    /// default is not a no-op: it comments the line out, which is this file's
    /// grammar for "unset" (see ConfigWriter), so the config keeps only the
    /// decisions that were actually made.
    func set(_ section: String?, _ field: ConfigField, to json: String) {
        guard !isManagedExternally else {
            // Refused before anything in memory moves, so the control snaps
            // back rather than showing a value the file doesn't have.
            writeError = nil
            return
        }

        guard let base = fileText() else {
            writeError = "Couldn't render a config to write into — this is a bug, please report it."
            return
        }

        let outcome = ConfigWriter.apply(
            base, section: section, key: field.name,
            json: json == field.json ? nil : json, default: field.json)

        // The writer refuses rather than guesses when the file's shape leaves
        // it no line to edit — a section folded onto one line, most of all,
        // where the old behaviour appended a duplicate key and quietly shadowed
        // everything already in it. Say what it said and change nothing; the
        // control snaps back to the file on the next read.
        if let reason = outcome.refused {
            writeError = reason
            refresh()
            return
        }
        let updated = outcome.text

        // Through the SAME parser `Settings.load()` uses. A config that doesn't
        // parse doesn't half-work — `load()` falls back to defaults wholesale,
        // so one bad write would look like every setting resetting itself. If
        // it ever happens it is a bug in here, not in the user's file, and it
        // must not reach the disk.
        guard (try? JSONSerialization.jsonObject(
            with: Data(updated.utf8), options: [.json5Allowed])) != nil
        else {
            writeError = "That change would have made config.json unreadable, so it wasn't saved. Please report this."
            // Re-read like every other early return: without it the control
            // keeps showing the value that was NOT saved, right beside the
            // banner saying it wasn't.
            refresh()
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try updated.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            writeError = "Couldn't write \(path.path): \(error.localizedDescription)"
            return
        }

        writeError = nil
        refresh()
    }

    /// The file to edit into. A config that isn't there yet becomes the same
    /// annotated one `pounce config init` writes — every setting present, at its
    /// default, commented out — so the first switch you flip lands in a file
    /// that explains the other thirty-nine, rather than in a bare `{ }`.
    private func fileText() -> String? {
        // An EMPTY file counts as no file. `ConfigWriter` has nothing to edit in
        // it and nowhere to insert, so it would hand back the empty string and
        // the parse check would then reject pounce's own no-op — an error
        // message for a file the user could reasonably have just `touch`ed.
        if let text = try? String(contentsOf: path, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return try? ConfigSpec.render(version: pounceVersion)
    }

    // MARK: - The file itself

    /// Write the annotated config without changing a setting — the window's
    /// `pounce config init`, offered when there is no file yet.
    func createAnnotatedConfig() {
        guard !isManagedExternally, !fileExists else { return }
        guard let text = try? ConfigSpec.render(version: pounceVersion) else {
            writeError = "Couldn't render the config template — this is a bug, please report it."
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: path, atomically: true, encoding: .utf8)
            writeError = nil
        } catch {
            writeError = "Couldn't write \(path.path): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Open config.json in whatever the user edits JSON with. Nothing to open
    /// if it isn't there, so the caller offers `createAnnotatedConfig` instead.
    func openInEditor() {
        guard fileExists else { return }
        NSWorkspace.shared.open(path)
    }

    /// Select it in Finder — the answer to "where IS it", which for a file in a
    /// dot-directory is not a question the path alone settles.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }
}
