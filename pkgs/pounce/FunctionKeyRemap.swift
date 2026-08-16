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
// so a reboot clears it even if pounce dies badly. UserKeyMapping is one SHARED
// list — a Karabiner rule, a Caps→F18 leader from a dotfiles rebuild — and
// `--set` writes all of it at once, so every path here reads the live list first
// and refuses to write when it couldn't read one. That single rule is what keeps
// this from eating a key the user never asked us to touch.
enum FunctionKeyRemap {
    // AppleVendor Top Case page (0xFF), usage 0x03: the Fn/Globe key itself.
    static let fnUsage: Int64 = 0xFF00000003
    // Keyboard page (0x07), usage 0x6E: F19. Chosen because no laptop or compact
    // Magic Keyboard has it — the full-size Magic Keyboard with a numeric keypad
    // DOES, where it's the last key of the F-row, so on that keyboard pressing
    // F19 fires this binding too. That's the least-bad option: every key below
    // F13 is one people actually bind.
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

    // Everything except the Fn mapping — the shape of a restore. Any Fn mapping
    // we displaced is put back by the caller (`displacedFn`), so this drops it
    // rather than trying to guess which Fn entry was whose.
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

    // The list hidutil reports right now — or nil when we couldn't read it, which
    // is emphatically NOT the same as "there are no mappings". Conflating the two
    // is how a `--set` built from an empty list silently deletes every OTHER
    // tool's entry, so every writer here refuses to act on nil.
    static func current() -> [Entry]? {
        interpret(hidutil(["property", "--get", "UserKeyMapping"]))
    }

    // Split from current() so the distinction that matters — "no mappings" vs
    // "couldn't read the mappings" — is unit-testable without an IOHID service.
    static func interpret(_ output: String?) -> [Entry]? {
        guard let output else { return nil }
        // What hidutil prints when nothing has ever been set. Whitespace-stripped
        // because the multi-line form is the same list.
        let dense = output.filter { !$0.isWhitespace }
        if dense.isEmpty || dense == "()" || dense == "(null)" { return [] }
        let entries = parse(output)
        return entries.isEmpty ? nil : entries
    }

    static var isActive: Bool { current().map(isMapped) ?? false }

    // An Fn mapping that was already there when we arrived — someone's persistent
    // hidutil script, a Karabiner rule. We had to displace it to take the key;
    // restore() puts it back, which is the difference between borrowing the key
    // and quietly eating a mapping the user set up themselves.
    private static var displacedFn: Entry?
    private static var installed = false

    @discardableResult
    static func apply() -> Bool {
        guard let existing = current() else {
            NSLog("pounce daemon: could not read UserKeyMapping; Fn remap not attempted (Fn left to macOS)")
            return false
        }
        guard !isMapped(existing) else {
            installed = true
            return true
        }
        displacedFn = existing.first { $0.src == fnUsage }
        guard hidutil(["property", "--set", payload(adding(to: existing))]) != nil else {
            NSLog("pounce daemon: hidutil could not set the Fn remap; Fn left to macOS")
            return false
        }
        installed = isActive
        if !installed {
            NSLog("pounce daemon: Fn remap did not take — this keyboard may not expose Fn to IOHID")
        }
        return installed
    }

    // Give Fn back. Re-reads the live list rather than replaying a snapshot taken
    // at startup: anything added while the daemon ran (a rice rebuild reapplying
    // its own UserKeyMapping, someone plugging in Karabiner) has to survive us
    // leaving, and a stale snapshot would delete exactly those.
    static func restore() {
        guard installed, let live = current(), isMapped(live) else { return }
        let restored = removing(from: live) + (displacedFn.map { [$0] } ?? [])
        _ = hidutil(["property", "--set", payload(restored)])
        installed = false
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
