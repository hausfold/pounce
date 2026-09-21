import AppKit

// MARK: - Receiving a `pounce://` link

// The daemon's half of the door. URLScheme.swift owns the grammar and the
// policy (and is pure, so the tests can hold both); this file is what Launch
// Services actually reaches, and what puts the question or the refusal on
// screen.
//
// ## Why an Apple Event and not an app delegate
//
// `application(_:open:)` needs an `NSApplicationDelegate`, and the daemon has
// none — it is `NSApplication.shared` with an accessory activation policy and
// nothing else, which is exactly why ⌘Space costs what it costs. Installing the
// `kAEGetURL` handler directly is the same mechanism a delegate would have
// installed for us, one object smaller.
//
// ## Why the running daemon gets the event at all
//
// haus and Homebrew run the bundle's executable directly rather than opening
// the bundle through Launch Services, which reads like it should leave LS
// ignorant of the running copy. It doesn't: a process whose main bundle is
// Pounce.app and which brings up NSApplication is a registered running
// application (`lsappinfo` lists it, bundle id and all), and DaemonMode.run
// calls `LSRegisterURL` on top of that for the Background Items name. So a
// `pounce://` link is delivered to the daemon that is already up, not to a
// second copy — which matters, because a second copy would exit on the
// single-instance guard with the link unanswered in its queue.
enum URLHandler {
    /// `--source` for every banner this file raises, and so the string a
    /// `~/.config/trill/rules.json` rule matches on.
    static let bannerSource = "pounce.url"

    // MARK: Install

    /// Start listening. Called from DaemonMode.run before `app.run()`; the
    /// receiver is held for the daemon's lifetime, because NSAppleEventManager
    /// does not retain its handler target.
    static func install() {
        NSAppleEventManager.shared().setEventHandler(
            receiver,
            andSelector: #selector(Receiver.handle(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        NSLog("pounce daemon: \(URLScheme.scheme):// links are live")
    }

    private static let receiver = Receiver()

    private final class Receiver: NSObject {
        @objc func handle(_ event: NSAppleEventDescriptor,
                          withReplyEvent _: NSAppleEventDescriptor) {
            let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue ?? ""
            URLHandler.open(raw, sender: URLHandler.senderName(of: event))
        }
    }

    // MARK: The link

    /// Act on one link. On the main thread: Apple Events are delivered there,
    /// and everything below it — the registry, the window, the state — is main
    /// thread only.
    static func open(_ raw: String, sender: String?) {
        // Logged before anything is decided, including the refusals below. A
        // link is the one way into pounce whose caller cannot be asked what it
        // sent, so the log is the only record that it arrived at all.
        NSLog("pounce daemon: \(URLScheme.scheme):// link from \(sender ?? "an unknown app"): \(raw)")

        let settings = Settings.load()
        guard settings.urlScheme.enabled else {
            refuse("links are switched off — set \"urlScheme\": {\"enabled\": true} to allow them")
            return
        }

        let request: URLScheme.Request
        switch URLScheme.parse(raw) {
        case .refuse(let why): refuse(why); return
        case .run(let parsed): request = parsed
        }

        guard let run = DaemonMode.runTargetHook else {
            refuse("pounce is still starting — try the link again in a moment")
            return
        }
        // A link never takes the screen off something the user is already
        // looking at. Every OTHER trigger here is the user — a hotkey that
        // lands mid-picker is them changing their mind, and releasing the
        // waiting client with a dismissal is the right answer to that. A link
        // is not them: it can arrive from a background app at any moment, and
        // letting one end somebody's half-typed picker (with the published
        // "dismissed" shape, exit 1, on a caller that never heard of this
        // feature) is a remote trigger reaching into an unrelated script.
        if DaemonMode.paletteBusyHook?() == true {
            refuse("pounce already has something on screen — dismiss it and open the link again")
            return
        }

        // A command id is resolved HERE rather than left to the dispatcher,
        // which only logs an unknown one. `pounce run` can afford that: it
        // exits 1 and the caller sees it. A link's caller sees nothing, so the
        // typo has to reach the user or it reaches nobody.
        var entry: CommandRegistry.Entry?
        if case .some(.command(let id)) = ItemTarget.parse(request.target) {
            let registry = DaemonMode.commandRegistry ?? CommandRegistry()
            registry.refresh()
            guard registry.scriptPath(for: id) != nil else {
                refuse("no command named '\(id)' is installed on this Mac")
                return
            }
            entry = registry.entries.first { $0.id == id }
        }

        let fire = { run(request.target, request.arguments) }
        // A command that resolves but has no ENTRY is one a `whenFile` vetoed:
        // still runnable by key, deliberately absent from the list
        // (CommandRegistry.refresh). Its header has not been read here, so
        // `confirm` is unknown rather than false — and unknown asks. Answering
        // no on a command whose own header may well say `confirm = true` is the
        // one wrong way to be wrong about this.
        let declares = entry?.risk.confirm ?? (request.target.hasPrefix("cmd:"))
        guard URLScheme.confirmationRequired(target: request.target,
                                             alwaysConfirm: settings.urlScheme.confirm,
                                             declaresConfirm: declares)
        else {
            fire()
            return
        }

        let link = PendingConfirm.Link(sender: sender, arguments: request.arguments, run: fire)
        let pending = PendingConfirm(item: item(for: request.target, entry: entry),
                                     action: "enter", origin: .link(link))
        // A question already standing wins. Two links in a row would otherwise
        // swap the sheet under the user between reading it and answering it,
        // which is worse than either link failing: the answer would be given to
        // a question they never read.
        guard let present = DaemonMode.presentConfirmHook else {
            refuse("pounce is still starting — try the link again in a moment")
            return
        }
        guard present(pending) else {
            refuse("a question is already waiting on screen")
            return
        }
    }

    /// What the sheet draws. A command that is in the registry brings its own
    /// name, icon and declarations — `parseCommand` over the same registry line
    /// the launcher parses, so the row reads identically to the one ⌘Space
    /// would have shown. Everything else (an app, a Shortcut, a command the
    /// `whenFile` veto keeps out of `entries`) has no row to borrow, so the key
    /// itself is the honest title.
    private static func item(for target: String, entry: CommandRegistry.Entry?) -> PounceItem {
        if let entry { return PounceItem.parseCommand(entry.registryLine) }
        if case .some(.app(let path)) = ItemTarget.parse(target) {
            // The same name the launcher would draw — `deletingPathExtension`,
            // as AppScanner does it. A sheet asking about "Ghostty.app" when
            // every other row in pounce says "Ghostty" is the one row that
            // doesn't read like the app it names.
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return PounceItem.app(name: name, path: path, boost: 0)
        }
        return PounceItem.parsePlain(target, globalIcon: "link")
    }

    // MARK: Saying no

    /// A refusal, on screen and in the log. The banner is not optional
    /// politeness: a link that does nothing and says nothing is
    /// indistinguishable from pounce being broken, and the caller — a note, a
    /// page, a spreadsheet row — has already moved on and cannot be told.
    ///
    /// The body carries text somebody else wrote (an item key, a query name),
    /// which is why Banner's fallback passes its strings as `argv` rather than
    /// interpolating them into AppleScript.
    private static func refuse(_ why: String) {
        NSLog("pounce daemon: refused a \(URLScheme.scheme):// link — \(why)")
        // One banner per `refusalQuiet`, however many links arrive. The log
        // keeps every one; the screen does not, because whatever is firing them
        // is not a person clicking — a page can open links in a loop, and each
        // banner is a child process this daemon waits on for up to five seconds
        // (Banner.swift). The first refusal is the one that says something
        // anyway: they arrive in a burst and they arrive for the same reason.
        let now = Date()
        if let last = lastRefusal, now.timeIntervalSince(last) < refusalQuiet { return }
        lastRefusal = now
        Banner.post(title: "Pounce ignored a link", body: why,
                    source: bannerSource, symbol: "link.badge.plus")
    }

    /// Main thread only, like everything else on this path (the Apple Event is
    /// delivered there), so it needs no locking.
    private static var lastRefusal: Date?
    private static let refusalQuiet: TimeInterval = 10

    // MARK: Who sent it

    /// The app that opened the URL, when macOS says — never whoever WROTE it.
    /// A link in a note is opened by the notes app, a link on a page by the
    /// browser, and neither of them is the author. That is the whole reason the
    /// sheet's caption says pounce can't see who wrote it, and the reason this
    /// is a label rather than a gate: an allowlist of senders would read as a
    /// guarantee it cannot make.
    ///
    /// nil is ordinary, not an error — `open pounce://…` from a shell is sent
    /// by a process that has already exited by the time we look.
    private static func senderName(of event: NSAppleEventDescriptor) -> String? {
        guard let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))
        else { return nil }
        let pid = descriptor.int32Value
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard let name = app.localizedName, !name.isEmpty else { return nil }
        return name
    }
}
