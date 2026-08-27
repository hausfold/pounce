import Foundation

// MARK: - Dials

// A dial is a small set of mutually exclusive values a picker step carries
// alongside whatever the user is typing or choosing — "which model", "public
// or private" — declared by the CALLER (`--dial "model=sonnet|opus|haiku"`)
// and cycled in place with ⇥ / ⇧⇥ while the palette is up. It exists because
// the alternative is a second picker step: "which model, this once" is too
// small a question to deserve its own window, but too real to hardcode in the
// script. Foundation-only (no AppKit/SwiftUI) so tests/run.sh can compile it.
struct Dial {
    let name: String
    let options: [String]
    var index: Int = 0

    // Always valid: parse() guarantees at least two options and cycling wraps,
    // but a decoded/mutated index is clamped rather than trusted.
    var value: String { options[max(0, min(index, options.count - 1))] }

    // "model=sonnet|opus|haiku;visibility=public|private" — `;` separates
    // dials, `=` names one, `|` separates its options. Total: a malformed
    // segment (no `=`, empty name, fewer than two distinct options) is dropped
    // rather than failing the invocation — the step still opens, it just
    // offers less. Which is also why option values must not contain `;` `=`
    // `|` or tabs: they are the grammar, not data.
    static func parse(_ spec: String) -> [Dial] {
        spec.split(separator: ";").compactMap { seg in
            let kv = seg.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            let name = kv[0].trimmingCharacters(in: .whitespaces)
            let opts = kv[1].split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !name.isEmpty, Set(opts).count >= 2 else { return nil }
            return Dial(name: name, options: opts)
        }
    }

    // The committed values in declaration order — the field a consumer reads
    // back: "model=opus;visibility=private".
    static func encode(_ dials: [Dial]) -> String {
        dials.map { "\($0.name)=\($0.value)" }.joined(separator: ";")
    }

    // The memory key is the whole declared segment, so a dial remembers per
    // option-SET: add or remove an option and its memory starts fresh instead
    // of pointing at a value that may no longer exist.
    var memoryKey: String { "\(name)=\(options.joined(separator: "|"))" }

    // Pure half of the sticky memory, split from the file I/O for the tests:
    // restore each dial's last-committed value where it still names an option.
    static func applying(memory: [String: String], to dials: [Dial]) -> [Dial] {
        dials.map { d in
            var d = d
            if let v = memory[d.memoryKey], let i = d.options.firstIndex(of: v) { d.index = i }
            return d
        }
    }
}

// The palette re-opens each dial on the value it committed last time — pass
// `--dial "model=sonnet|opus|haiku"` every invocation and it lands on opus for
// as long as opus is what you pick, with no state for the caller to thread
// through. One flat name=options → value file; only a COMMIT writes it, so
// cycling through the options and pressing Esc changes nothing.
enum DialMemory {
    private static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/pounce/dials.json")
    }

    static func recall(_ dials: [Dial]) -> [Dial] {
        guard !dials.isEmpty,
              let raw = try? Data(contentsOf: path),
              let map = try? JSONDecoder().decode([String: String].self, from: raw)
        else { return dials }
        return Dial.applying(memory: map, to: dials)
    }

    static func store(_ dials: [Dial]) {
        guard !dials.isEmpty else { return }
        var map = (try? Data(contentsOf: path))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        for d in dials { map[d.memoryKey] = d.value }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = try? JSONEncoder().encode(map) else { return }
        try? out.write(to: path, options: .atomic)
    }
}
