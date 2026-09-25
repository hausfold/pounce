import Foundation

// MARK: - The `pounce://` door
//
// One shape, and the grammar is `pounce run`'s:
//
//   pounce://run?item=<item key>[&arg=<value>…]
//
// It exists so that a thing which can only produce a LINK — a row in an
// Obsidian base, a note, a spreadsheet cell, a web page, a Shortcut, a Markdown
// to-do — can reach a palette command without a plugin of its own to shell out
// for it. Before this, every such caller needed a host app willing to run a
// subprocess on its behalf; now the only thing it needs is the ability to open
// a URL, which everything has.
//
// This file is the GRAMMAR and the POLICY, and nothing else: no AppKit, no
// registry, no window, so tests/urlscheme_tests.swift can hold every refusal to
// the letter. URLHandler.swift is the half that receives the Apple Event, draws
// the sheet and dispatches.
//
// ## Why the parse refuses so much
//
// A link has no exit code. Every other way into pounce answers the caller —
// `pounce run` exits 1 on a bad key, the picker exits 2 on an unknown flag —
// and a URL answers nobody: whatever opened it has already moved on. So a
// mistake can only be reported on the user's screen, and the way to keep that
// rare is to accept exactly one spelling and name what was wrong with anything
// else. A silently-ignored query key here is a caller who thinks they passed an
// argument and a user who never learns they didn't.
//
// ## Why arguments are positional and not environment
//
// `arg` is repeatable and arrives at the script as `$1 $2 …`. The alternative
// considered — hand the whole query string to the script as environment — was
// rejected on one point: a URL that sets a spawned process's environment sets
// `PATH` and `DYLD_INSERT_LIBRARIES` unless something stops it, and "something
// stops it" is a list of privileged names that must never be wrong or short.
// argv has no privileged positions. Nothing is passed through a shell either
// (CommandSpawner builds an argv), so quoting is not a thing a caller has to
// get right.
enum URLScheme {
    /// The scheme registered in Info.plist's `CFBundleURLTypes`.
    static let scheme = "pounce"
    /// The only action today. A second one would be a new host, not a new key.
    static let action = "run"
    /// The one `mode:` that turns hardware on rather than drawing a list — see
    /// `confirmationRequired`. Spelled here, next to the policy that reads it,
    /// rather than as a literal inside the switch.
    static let capturingMode = "camera"

    /// At most this many `arg`s, each at most this long. Not a security
    /// boundary — the spawn is an argv either way — but a link is written by
    /// somebody else, and a sheet that asks the user to vouch for 400 arguments
    /// is not a question anybody can answer.
    ///
    /// The count is exactly what the confirm sheet draws, one row each
    /// (Confirm.swift), and that is the point of the number: a cap higher than
    /// the sheet's would produce a link whose payload is summarised as "6
    /// arguments" and agreed to unseen, which is the reflex-yes this whole path
    /// is written against. The length is a line of a panel; past it the row
    /// truncates in the MIDDLE, so a long path still shows both ends, and the
    /// whole link is in the log either way.
    static let maxArguments = 4
    static let maxArgumentLength = 2048

    struct Request: Equatable {
        /// The item key, exactly as `pounce run` and `config.json`'s `items`
        /// map take it — `cmd:emoji`, `mode:clipboard`, `app:/…`.
        let target: String
        /// Positional arguments for a `cmd:` target, in the order the URL wrote
        /// them. Empty for every other kind (and refused for them at parse).
        let arguments: [String]
    }

    enum Outcome: Equatable {
        case run(Request)
        /// Why not — a whole sentence, because it is going on screen in a
        /// banner and into the log, and those are the only two places a link's
        /// mistake can ever be read.
        case refuse(String)
    }

    static func parse(_ raw: String) -> Outcome {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refuse("an empty link") }
        guard let parts = URLComponents(string: trimmed) else {
            return .refuse("'\(trimmed)' is not a URL pounce can read")
        }
        guard parts.scheme?.lowercased() == scheme else {
            return .refuse("'\(trimmed)' is not a \(scheme):// link")
        }
        // The authority form only: `pounce://run?…`. `pounce:run?…` parses as a
        // path with no host and is a different URL, so it is named rather than
        // quietly accepted — one spelling is what keeps a link written once in
        // somebody's notes working everywhere else it gets pasted.
        guard let host = parts.host, !host.isEmpty else {
            return .refuse("a \(scheme):// link needs the \(scheme)://\(action)?… form, with the slashes")
        }
        guard host.lowercased() == action else {
            return .refuse("'\(host)' is not a \(scheme):// action (the only one is '\(action)')")
        }
        // `pounce://run` and `pounce://run/` are the same thing; anything deeper
        // is a caller expecting a path grammar that does not exist.
        let path = parts.path
        guard path.isEmpty || path == "/" else {
            return .refuse("'\(path)' is not part of any \(scheme):// link (expected \(scheme)://\(action)?item=…)")
        }
        // The rest of a URL's shape has no meaning here, so it is refused rather
        // than ignored — `pounce://someone@run?…` and a trailing `#fragment`
        // both read as carrying something, and a link that carries something
        // pounce silently drops is the failure this whole parse is written
        // against.
        guard parts.user == nil, parts.password == nil, parts.port == nil,
              parts.fragment == nil else {
            return .refuse("a \(scheme):// link is \(scheme)://\(action)?item=… and nothing else — no user, port or #fragment")
        }

        var target: String?
        var arguments: [String] = []
        for item in parts.queryItems ?? [] {
            switch item.name {
            case "item":
                guard target == nil else { return .refuse("the link names 'item' twice") }
                guard let value = item.value, !value.isEmpty else {
                    return .refuse("the link's 'item' is empty")
                }
                target = value
            case "arg":
                // A bare `&arg` (no `=`) is a caller who meant to pass
                // something. An explicit `&arg=` is an empty argument, which is
                // a real thing to want, and stays one.
                guard let value = item.value else {
                    return .refuse("the link has an 'arg' with no value")
                }
                guard value.count <= maxArgumentLength else {
                    return .refuse("one of the link's arguments is longer than \(maxArgumentLength) characters")
                }
                arguments.append(value)
                guard arguments.count <= maxArguments else {
                    return .refuse("the link passes more than \(maxArguments) arguments")
                }
            default:
                return .refuse("'\(item.name)' is not part of a \(scheme):// link (it takes 'item' and 'arg')")
            }
        }

        guard let target else {
            return .refuse("the link names no item (expected \(scheme)://\(action)?item=cmd:<id>)")
        }
        if let problem = ItemTarget.problem(with: target) { return .refuse(problem) }
        // Arguments are a command's alone. An app, a Shortcut, a built-in
        // window and a settings pane all have their own way of being told what
        // to do and none of it is argv, so a link that passes one to them is
        // not doing what its author believes — and dropping it quietly is how
        // that belief survives.
        if !arguments.isEmpty, ItemTarget.parse(target)?.isCommand != true {
            return .refuse("only a cmd: item takes arguments, and '\(target)' is not one")
        }
        return .run(Request(target: target, arguments: arguments))
    }

    // MARK: - Does this need answering first?

    /// Whether a link naming `target` must be confirmed on screen before it
    /// acts.
    ///
    /// The line is between OPENING and RUNNING, and it is the only line pounce
    /// can draw honestly. A link that opens a pounce window or a System
    /// Settings pane does what every other link on this Mac does — it puts
    /// something in front of you, and you are already looking. A link that runs
    /// a command, a Shortcut or an application is doing something a web page,
    /// an email or a shared note cannot otherwise do, and pounce cannot tell
    /// which of those sent it: `kAEGetURL` names the app that opened the link,
    /// never the page that wrote it.
    ///
    /// `mode:camera` is the one window that is not only a window: it starts an
    /// `AVCaptureSession` (Camera.swift), so a link to it turns a camera and
    /// its indicator light on. That is a device, not a view, and it is asked
    /// about like anything else that acts. Its siblings stay on the open side —
    /// clipboard history, screenshots and file search all put the user's own
    /// things on the user's own screen, which is nuisance at worst.
    ///
    /// `alwaysConfirm` is `urlScheme.confirm`, on by default. Turned off, a
    /// link is trusted exactly as much as the keyboard is — the command's own
    /// `confirm` header still gets its sheet, and nothing else does, which is
    /// `pounce run`'s contract to the letter.
    static func confirmationRequired(target: String,
                                     alwaysConfirm: Bool,
                                     declaresConfirm: Bool) -> Bool {
        switch ItemTarget.parse(target) {
        case .some(.mode(let name)) where name != capturingMode:
            return false
        case .some(.setting):
            return false
        default:
            // .command, .app, .shortcut — and a target that parses as nothing,
            // which the dispatcher will refuse anyway but must never be the
            // shape that skips the question.
            return alwaysConfirm || declaresConfirm
        }
    }

    // MARK: - Handing a link to the daemon

    /// The socket line a link travels on when it reached the wrong process:
    /// Launch Services started Pounce.app for it with no daemon up, and by the
    /// time one answered, the link was sitting in a copy that is about to exit
    /// (AppLaunchMode, LoginItem.swift). `URL\t<link>\t<sender>`, both fields
    /// escaped the way `CONFIG`'s seed query is (Drafts.encode), because a link
    /// is somebody else's text and this protocol is built out of tabs and
    /// newlines. The sender travels too: it is the only thing the confirm
    /// sheet can say about where a link came from, and forwarding must not turn
    /// "Obsidian" into "Pounce".
    enum Forward {
        static let verb = "URL"

        static func payload(raw: String, sender: String?) -> String {
            "\(verb)\t\(Drafts.encode(raw))\t\(Drafts.encode(sender ?? ""))\n"
        }

        /// The link and its sender, or nil for a payload that is not this verb.
        /// An empty sender is nil, as it would have been had the daemon taken
        /// the Apple Event itself.
        static func parse(_ payload: String) -> (raw: String, sender: String?)? {
            guard payload.hasPrefix(verb + "\t") else { return nil }
            let line = payload.dropFirst(verb.count + 1)
                .trimmingCharacters(in: .newlines)
            let fields = line.split(separator: "\t", maxSplits: 1,
                                    omittingEmptySubsequences: false).map(String.init)
            let raw = Drafts.decode(fields[0])
            guard !raw.isEmpty else { return nil }
            let sender = fields.count > 1 ? Drafts.decode(fields[1]) : ""
            return (raw, sender.isEmpty ? nil : sender)
        }
    }
}
