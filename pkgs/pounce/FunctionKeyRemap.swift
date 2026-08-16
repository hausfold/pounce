import Foundation

// MARK: - Fn/Globe as a real key, via the HID layer
//
// The event-tap binding in FunctionKey.swift cannot be made reliable, and the
// reason is structural rather than a bug we could chase: HIToolbox is linked
// into EVERY process and carries its own Globe handler, which reads the key
// below the CGEvent stream a tap can see. Captured live, with pounce's tap
// installed and healthy (zero tapDisabled events in 7k lines of log):
//
//     05:18:27.713  pounce    [HIToolbox:CharacterPalette] TSMLaunchCharacterPalette called
//     05:18:33.890  ghostty   [HIToolbox:CharacterPalette] TSMLaunchCharacterPalette called
//     05:18:40.187  Obsidian  [HIToolbox:CharacterPalette] TSMLaunchCharacterPalette called
//
// — four native pickers, ZERO corresponding "fn down/up" lines from the tap.
// The press never reached the session event stream at all, so there was nothing
// to suppress and nothing to fire on; one of those four was launched by HIToolbox
// inside pounce's own process. Turning off System Settings → Keyboard → "Press 🌐
// key to" does not help either: that value is read from login-session state, so a
// `defaults write` is honored by nothing already running, and even a freshly
// launched app went on opening the picker.
//
// So the only place left to intervene is BELOW all of that: remap the key at the
// HID layer, where it stops being Fn before HIToolbox (or anyone else) can see
// it. IOKit's UserKeyMapping turns Fn into an ordinary F-key, which pounce then
// binds with the same Carbon call as any other hotkey — no event tap, no
// Accessibility grant, and nothing to race, because there is no Fn key left in
// the system to race over.
//
// The cost is real and is why this is opt-in (`"fnKey": "remap"`): Fn stops being
// Fn for everything else too — no Fn+arrows (Home/End/PageUp/PageDown), no
// Fn+Delete, no Fn+F1…F12. That is the whole trade, and it belongs to the user.
//
// The mapping is applied to the live IOHID services only; it is NOT persistent,
// so a reboot clears it even if pounce dies badly. On a clean exit the daemon
// restores exactly the list it found (see `restorePayload`), which is what keeps
// this composable with the other tools that write UserKeyMapping — Karabiner, a
// Caps→F18 leader from a dotfiles rebuild — instead of clobbering them.
enum FunctionKeyRemap {
    // AppleVendor Top Case page (0xFF), usage 0x03: the Fn/Globe key itself.
    static let fnUsage: Int64 = 0xFF00000003
    // Keyboard page (0x07), usage 0x6E: F19. Chosen because no Mac keyboard has
    // one physically, so nothing else can be typing it.
    static let targetUsage: Int64 = 0x70000006E
    static let targetKeyName = "f19"

    static let srcField = "HIDKeyboardModifierMappingSrc"
    static let dstField = "HIDKeyboardModifierMappingDst"

    // MARK: Pure list algebra (unit-tested; see tests/functionkeyremap_tests.swift)

    // One mapping entry, order-independent so a parsed dictionary compares equal
    // however hidutil chose to print it.
    struct Entry: Equatable {
        var src: Int64
        var dst: Int64
    }

    // hidutil prints an old-style plist: ({Dst=30064771181;Src=30064771129;},…).
    // Parsed with a regex rather than PropertyListSerialization because the
    // openStep reader hands back every scalar as a String and silently accepts
    // shapes we'd have to re-validate anyway.
    static func parse(_ output: String) -> [Entry] {
        let groups = matches(in: output, pattern: "\\{[^{}]*\\}")
        return groups.compactMap { group in
            guard let src = field(srcField, in: group), let dst = field(dstField, in: group) else {
                return nil
            }
            return Entry(src: src, dst: dst)
        }
    }

    // Our entry, with any previous mapping OF THE SAME SOURCE dropped: applying
    // twice must be idempotent, and a stale Fn mapping (ours from a crashed run,
    // or someone else's) must lose rather than sit ahead of us in the list.
    static func adding(to existing: [Entry]) -> [Entry] {
        existing.filter { $0.src != fnUsage } + [Entry(src: fnUsage, dst: targetUsage)]
    }

    // Everything except the Fn mapping — used to restore on exit. Note this drops
    // a foreign Fn mapping too, but by the time we're here we already replaced it.
    static func removing(from existing: [Entry]) -> [Entry] {
        existing.filter { $0.src != fnUsage }
    }

    // The argument hidutil wants. Keys are printed in a fixed order so a payload
    // is byte-comparable in tests.
    static func payload(_ entries: [Entry]) -> String {
        let items = entries.map { #"{"\#(srcField)":\#($0.src),"\#(dstField)":\#($0.dst)}"# }
        return #"{"UserKeyMapping":[\#(items.joined(separator: ","))]}"#
    }

    static func isMapped(_ entries: [Entry]) -> Bool {
        entries.contains(Entry(src: fnUsage, dst: targetUsage))
    }

    // MARK: Live IOHID state

    // The list hidutil reports right now, or [] if it has never been set.
    static func current() -> [Entry] {
        parse(hidutil(["property", "--get", "UserKeyMapping"]) ?? "")
    }

    static var isActive: Bool { isMapped(current()) }

    // What `remove()` will write: the list as it stood BEFORE we touched it.
    // Captured at apply time so teardown needs no reads — it runs from a signal
    // handler, where spawning a pipe-reading child would be the unsafe part.
    private static var restorePayload: String?

    @discardableResult
    static func apply() -> Bool {
        let existing = current()
        guard !isMapped(existing) else {
            restorePayload = restorePayload ?? payload(removing(from: existing))
            return true
        }
        restorePayload = payload(removing(from: existing))
        guard hidutil(["property", "--set", payload(adding(to: existing))]) != nil else {
            NSLog("pounce daemon: hidutil could not set the Fn remap; Fn left to macOS")
            return false
        }
        let ok = isActive
        if !ok { NSLog("pounce daemon: Fn remap did not take — this keyboard may not expose Fn to IOHID") }
        return ok
    }

    // Best effort, and deliberately fire-and-forget: called from the SIGTERM
    // handler, so it must not allocate a Foundation Process or read a pipe.
    // posix_spawn + waitpid of a pre-rendered argv is the whole of it.
    static func removeSync() {
        guard let payload = restorePayload else { return }
        let argv: [String] = ["/usr/bin/hidutil", "property", "--set", payload]
        var cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargv.append(nil)
        defer { for p in cargv where p != nil { free(p) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, argv[0], nil, nil, &cargv, environ) == 0 else { return }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    // MARK: Plumbing

    private static func hidutil(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func field(_ name: String, in group: String) -> Int64? {
        matches(in: group, pattern: "\(name)\\s*[=:]\\s*(\\d+)", captureGroup: 1)
            .first.flatMap(Int64.init)
    }

    private static func matches(in text: String, pattern: String, captureGroup: Int = 0) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: captureGroup), in: text).map { String(text[$0]) }
        }
    }
}
