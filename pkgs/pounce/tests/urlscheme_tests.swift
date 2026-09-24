// Unit tests for the `pounce://` grammar and its confirm policy
// (URLScheme.swift).
//
// This is the surface with the least forgiving failure mode in the repo: a link
// lives in somebody else's note, base or page, its caller gets no exit code,
// and the only thing a mistake can produce is a banner on a screen nobody may
// be looking at. So every refusal is pinned here by its SHAPE — a link that is
// accepted when it should be refused is an item running unasked, and one that
// is refused when it should be accepted is a ⚡ column that quietly stopped
// working.
//
// Named with a _tests suffix (see tests/run.sh) so it can't collide with
// URLScheme.swift on a case-insensitive filesystem.

import Foundation

func runURLSchemeTests() -> Int {
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            failures += 1
        }
    }
    func refusal(_ raw: String) -> String? {
        if case .refuse(let why) = URLScheme.parse(raw) { return why }
        return nil
    }
    func request(_ raw: String) -> URLScheme.Request? {
        if case .run(let r) = URLScheme.parse(raw) { return r }
        return nil
    }

    // MARK: The shape that works

    check(request("pounce://run?item=cmd:todos")
            == URLScheme.Request(target: "cmd:todos", arguments: []),
          "the documented link runs the item it names")
    check(request("pounce://run/?item=mode:clipboard")
            == URLScheme.Request(target: "mode:clipboard", arguments: []),
          "a trailing slash is the same link")
    check(request("POUNCE://RUN?item=cmd:todos")?.target == "cmd:todos",
          "scheme and action are case-insensitive, the way a URL's authority is")

    // The value is percent-decoded once, by URLComponents, and reaches the
    // script as one argv entry — so a path with a space needs no quoting from
    // the caller and gets none from us.
    check(request("pounce://run?item=cmd:spawn&arg=%2FUsers%2Fme%2Fa%20note.md")?.arguments
            == ["/Users/me/a note.md"],
          "an argument is percent-decoded and stays one argument")
    check(request("pounce://run?item=cmd:spawn&arg=one&arg=two")?.arguments == ["one", "two"],
          "arg is repeatable and keeps the order the link wrote")
    check(request("pounce://run?item=cmd:spawn&arg=")?.arguments == [""],
          "an explicit empty argument is a real argument")
    check(request("pounce://run?item=cmd%3Atodos")?.target == "cmd:todos",
          "an encoded item key decodes to the same key")

    // MARK: The shapes that don't

    check(refusal("") != nil, "an empty link is refused")
    check(refusal("obsidian://tracker?spawn=x") != nil, "another app's scheme is not ours")
    check(refusal("pounce:run?item=cmd:todos") != nil,
          "the no-authority spelling is named, not silently accepted")
    check(refusal("pounce://focus?item=cmd:todos") != nil,
          "an action that isn't `run` is refused rather than guessed at")
    check(refusal("pounce://run/deeper?item=cmd:todos") != nil,
          "there is no path grammar to fall into")
    check(refusal("pounce://run") != nil, "a link naming no item is refused")
    check(refusal("pounce://run?item=cmd:todos#frag") != nil,
          "a fragment is carrying something, so it is named rather than dropped")
    check(refusal("pounce://someone@run?item=cmd:todos") != nil,
          "a userinfo is not part of the shape")
    check(refusal("pounce://run?item=") != nil, "an empty item is refused")
    check(refusal("pounce://run?item=cmd:a&item=cmd:b") != nil,
          "two items is ambiguous, and ambiguity runs nothing")
    check(refusal("pounce://run?item=cmd:todos&args=one") != nil,
          "an unknown key is refused — a silently-dropped one is a caller who thinks it passed something")
    check(refusal("pounce://run?item=cmd:todos&arg") != nil,
          "an arg with no value is a caller who meant to pass one")
    check(refusal("pounce://run?item=nonsense") != nil,
          "a target that is not an item key is refused before anything is dispatched")
    check(refusal("pounce://run?item=mode:nope") != nil,
          "a mode that doesn't exist is refused (ItemTarget.problem says which)")

    // Arguments belong to a command alone: every other kind is told what to do
    // by something that is not argv, so passing one is a mistake to name.
    check(refusal("pounce://run?item=mode:clipboard&arg=x") != nil,
          "a built-in window takes no arguments")
    check(refusal("pounce://run?item=app:/Applications/Ghostty.app&arg=x") != nil,
          "an app takes no arguments")
    check(refusal("pounce://run?item=shortcut:ABC&arg=x") != nil,
          "a Shortcut takes no arguments")

    // The caps are about a sheet a human has to be able to read, not about
    // safety — the spawn is an argv either way.
    let many = (0..<(URLScheme.maxArguments + 1)).map { "arg=\($0)" }.joined(separator: "&")
    check(refusal("pounce://run?item=cmd:spawn&\(many)") != nil,
          "more arguments than the sheet can show is refused")
    let atCount = (0..<URLScheme.maxArguments).map { "arg=\($0)" }.joined(separator: "&")
    check(request("pounce://run?item=cmd:spawn&\(atCount)")?.arguments.count == URLScheme.maxArguments,
          "the count the sheet can draw is allowed in full — every argument is a row on it")
    let long = String(repeating: "x", count: URLScheme.maxArgumentLength + 1)
    check(refusal("pounce://run?item=cmd:spawn&arg=\(long)") != nil,
          "an argument longer than the cap is refused")
    let atCap = String(repeating: "x", count: URLScheme.maxArgumentLength)
    check(request("pounce://run?item=cmd:spawn&arg=\(atCap)")?.arguments.count == 1,
          "the cap itself is allowed — the refusal is for what is past it")

    // MARK: Who has to answer first

    // Opening is not running. A link that puts a pounce window or a System
    // Settings pane in front of you does what any link does; one that runs a
    // command, a Shortcut or an app does something no page could otherwise do.
    for target in ["mode:clipboard", "mode:launcher", "setting:com.apple.Displays-Settings.extension"] {
        check(!URLScheme.confirmationRequired(target: target, alwaysConfirm: true,
                                              declaresConfirm: true),
              "\(target) only opens something, so a link never has to ask")
    }
    for target in ["cmd:todos", "app:/Applications/Ghostty.app", "shortcut:ABC"] {
        check(URLScheme.confirmationRequired(target: target, alwaysConfirm: true,
                                             declaresConfirm: false),
              "\(target) runs something, so the default asks even with nothing declared")
        check(!URLScheme.confirmationRequired(target: target, alwaysConfirm: false,
                                              declaresConfirm: false),
              "\(target) with urlScheme.confirm off is trusted exactly as much as a hotkey")
    }
    // The camera is the one `mode:` that is not only a window — it starts a
    // capture session, light and all — so it is asked about like anything else
    // that acts, and like them it follows the dial rather than overriding it.
    check(URLScheme.confirmationRequired(target: "mode:camera", alwaysConfirm: true,
                                         declaresConfirm: false),
          "a link to the camera asks, because a camera is a device and not a view")
    check(!URLScheme.confirmationRequired(target: "mode:camera", alwaysConfirm: false,
                                          declaresConfirm: false),
          "…and with the dial off it is trusted exactly as much as a hotkey, like every other mode")

    // `confirm: false` hands the decision back to the command's own header,
    // which is `pounce run`'s contract — not "never ask".
    check(URLScheme.confirmationRequired(target: "cmd:update-pounce", alwaysConfirm: false,
                                         declaresConfirm: true),
          "a command declaring confirm keeps its sheet even with the dial off")

    // The hand-over from a launch that caught a link to the daemon that
    // answers it (URLScheme.Forward). The link and its sender are somebody
    // else's text on a protocol made of tabs and newlines, so both must come
    // back exactly, and nothing about them may end the line early.
    func roundTrip(_ raw: String, _ sender: String?) -> (raw: String, sender: String?)? {
        URLScheme.Forward.parse(URLScheme.Forward.payload(raw: raw, sender: sender))
    }
    let plain = roundTrip("pounce://run?item=cmd:todos", "Obsidian")
    check(plain?.raw == "pounce://run?item=cmd:todos" && plain?.sender == "Obsidian",
          "a forwarded link keeps its URL and the app that opened it")
    check(roundTrip("pounce://run?item=cmd:todos", nil).map { $0.sender == nil } == true,
          "an unknown sender stays unknown rather than becoming an empty name")
    let hostile = roundTrip("pounce://run?item=cmd:x&arg=a\tb\nc\\n", "Evil\tApp\nRUN\tcmd:rm")
    check(hostile?.raw == "pounce://run?item=cmd:x&arg=a\tb\nc\\n",
          "tabs, newlines and backslashes in a forwarded link survive the socket")
    check(hostile?.sender == "Evil\tApp\nRUN\tcmd:rm",
          "a sender's name cannot smuggle a second line onto the socket")
    check(!URLScheme.Forward.payload(raw: "a\nb", sender: "c\nd").dropLast().contains("\n"),
          "a forward payload is exactly one line")
    check(URLScheme.Forward.parse("URL\t\t\n") == nil, "a URL line with no link is not a link")
    check(URLScheme.Forward.parse("RUN\tcmd:todos\n") == nil, "another verb is not a forwarded link")

    if failures == 0 { print("ok — all pounce:// link tests passed") }
    return failures
}
