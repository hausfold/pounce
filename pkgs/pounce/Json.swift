import Foundation

// MARK: - The one JSON writer
//
// Every `--json` in this CLI renders through here, and the options below are the
// contract rather than a preference. The family's agent-surface standard (the
// workshop's docs/agent-surface.md, A2) asks for one documented schema per read
// verb, data on stdout and diagnostics on stderr; the cheapest way to hold a
// dozen call sites to that is for all of them to build a dictionary and hand it
// to one function.
//
//   .sortedKeys              deterministic bytes, so two runs diff cleanly and a
//                            test can pin one. Swift dictionaries have no order
//                            of their own, so without this the output would
//                            reshuffle between runs of the same command.
//   .withoutEscapingSlashes  paths are most of what pounce answers with, and
//                            "\/Users\/…" is a path no reader expects to see.
//   .prettyPrinted           an agent parses either shape; the human running the
//                            same command by hand only reads this one.
//
// Every record carries a `schema` number. Adding a key is not a breaking change
// and does not move it; renaming or removing one is, and does.
//
// Foundation-only (no AppKit/SwiftUI), like the rest of the pure half, so
// tests/run.sh compiles it.
enum Json {
    /// The version stamped into every record this binary emits.
    static let schema = 1

    static func text(_ value: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted, .fragmentsAllowed]),
            let rendered = String(data: data, encoding: .utf8)
        else {
            // Unreachable for the records this repo builds — they are
            // String/Int/Double/Bool/Array/Dictionary/NSNull all the way down.
            // But an unhandled throw here would land in a `--json` path, which is
            // precisely where a caller has the least chance of recovering, so it
            // answers with something parseable instead.
            return "{\"error\":\"pounce could not render that as JSON — please report it\",\"schema\":\(schema)}"
        }
        return rendered
    }

    /// A record with `schema` already in it. Call sites pass the payload alone.
    static func record(_ fields: [String: Any]) -> [String: Any] {
        var out = fields
        out["schema"] = schema
        return out
    }

    static func emit(_ fields: [String: Any]) {
        print(text(record(fields)))
    }

    /// A Swift optional as a JSON value: `nil` becomes null rather than a
    /// missing key, so a record's shape doesn't change with its contents.
    static func value(_ optional: String?) -> Any { optional ?? NSNull() }
    static func value(_ optional: Bool?) -> Any { optional ?? NSNull() }
    static func value(_ optional: Int?) -> Any { optional ?? NSNull() }

    /// Re-read a JSON literal as a value. ConfigSpec renders each setting's live
    /// value as a JSON string ("200", "true", "\"space\"") for the annotated
    /// config template; `config print --json` needs those back as real JSON
    /// types, and re-parsing the one rendering both surfaces already agree on
    /// beats a second walk over `Settings` that could disagree with it.
    static func parse(_ literal: String) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(literal.utf8),
                                           options: [.fragmentsAllowed])) ?? NSNull()
    }
}
