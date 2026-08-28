import Foundation

// MARK: - Badges (rows that show live state)

// The `items` map's per-item "state" key: a read-only shell command whose first
// stdout line becomes the row's trailing badge — "On"/"Off" for Toggle Focus is
// the canonical one. Anything that can print one word works: a volume percentage,
// a queue length, a battery.
//
// The one rule this store exists to hold: NONE of this runs on the ⌘Space
// keystroke. The summon path is DaemonState.load, which calls refresh() and
// gets (a) synchronous cache-fresh values copied into state.badges and (b) one
// async run per stale key that publishes when it lands — a summon never waits
// for a shell to start. Rows simply appear without a badge and gain one a
// moment later, which reads as live data rather than a missing row.
//
// Commands must be read-only: they run repeatedly (per summon, until cached)
// and with the daemon's grants. `pounce focus status` is the shape — status,
// never toggle. Output is capped at the first line and truncated later by the
// row's own lineLimit; a process that ignores SIGTERM simply yields no badge.
//
// The cache is process-wide and static: the daemon lives for the whole login,
// so a TTL of 30s is what keeps re-opening the palette free while still
// tracking a state you can flip faster than that from the row itself.
//
// Deliberately daemon-agnostic: this file compiles in the Foundation-only test
// module too, so it speaks in commands and callbacks — no DaemonState here.
enum BadgeStore {
    static let ttl: TimeInterval = 30
    static let timeout: Double = 1.5

    private static var cache: [String: (value: String, at: Date)] = [:]
    private static var inFlight: Set<String> = []

    // A cache-fresh badge for this command, or nil. Read on the summon path:
    // a hit is a dictionary lookup, no I/O, so the badge is on the row before
    // the first frame.
    static func cached(for command: String) -> String? {
        guard let cached = cache[command], Date().timeIntervalSince(cached.at) < ttl else { return nil }
        return cached.value
    }

    // Kick one run. `deliver` fires ON THE MAIN QUEUE, either with the first
    // stdout line or never (empty output, non-zero-worthy failure, timeout).
    // Repeat calls for a command already running coalesce into the run in
    // flight.
    static func fetch(_ command: String, deliver: @escaping (String) -> Void) {
        guard !inFlight.contains(command) else { return }
        inFlight.insert(command)
        run(command) { value in
            DispatchQueue.main.async {
                inFlight.remove(command)
                guard let value else { return }
                cache[command] = (value, Date())
                deliver(value)
            }
        }
    }

    // One run. Wall-clock-capped: a hung command costs 1.5s on ONE background
    // thread and then no badge, never a spinner.
    private static func run(_ command: String, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do { try process.run() } catch { completion(nil); return }

            var finished = false
            let kill = DispatchWorkItem {
                guard !finished else { return }
                finished = true
                process.terminate()
                completion(nil)
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: kill)

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !finished else { return }
            finished = true
            kill.cancel()

            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text?.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init))
        }
    }
}
