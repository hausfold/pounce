import SwiftUI
import AppKit

// MARK: - The confirm sheet

// What `# pounce: confirm = true` buys: the palette asks before it runs the
// script. This is the only one of the three declarations (CommandRisk, in
// CommandRegistry.swift) that changes what pressing Return does — the other two
// are read HERE, as the reason the question is being asked, because a
// confirmation that only says "are you sure?" teaches nothing and gets answered
// yes by reflex.
//
// It replaces the launcher's body rather than floating over it, for a reason
// that is about keys and not about looks: the query field is what routes
// Return and Esc while the list is up (CustomTextField's monitor), and two
// live monitors racing for the same Return is exactly the bug this feature
// would be worst at having. Swapping the subtree dismantles that field —
// SwiftUI calls `dismantleNSView`, which removes its monitor — so while the
// sheet is up there is exactly one thing listening.
//
// Esc answers no and goes BACK to the list, not out of the palette: "not that
// one" is the likelier meaning, the row you did want is still on screen behind
// the sheet, and a second Esc closes the window the way it always has.
struct ConfirmView: View {
    @ObservedObject var state: DaemonState
    let pending: PendingConfirm

    @State private var keyMonitor: Any?
    // When the sheet went up. A Return that lands inside `armingDelay` of that
    // is the second half of the keystroke that RAISED it, not an answer to it —
    // see the monitor.
    @State private var armedAt: Date?

    // Long enough to have read a line, short enough that a deliberate ⏎ never
    // feels dropped. The window it closes is a real one: pressing Return twice
    // in quick succession is how people commit a row they are sure of, and the
    // one shipped command that declares `confirm` replaces your install.
    private static let armingDelay: TimeInterval = 0.35

    private var item: PounceItem { pending.item }

    // The declarations, as sentences. `confirm` itself is not one of them — it
    // is why this sheet exists — so a command that declares nothing else still
    // says something rather than showing an empty box.
    private var notes: [(icon: String, text: String)] {
        var out: [(String, String)] = []
        if item.risk.mutates { out.append(("pencil", "Changes state on this Mac")) }
        if item.risk.network { out.append(("network", "Talks to the internet")) }
        if out.isEmpty { out.append(("hand.raised", "Asked pounce to check with you first")) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: ContentView.headerSpacing) {
                Image(systemName: item.icon ?? "sparkles")
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.mauve)
                    .frame(width: ContentView.searchIconColumn)
                Text("Run \(item.title)?")
                    .font(.system(size: state.metrics.searchFontSize, weight: .medium))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, ContentView.headerHPadding)
            .frame(height: state.metrics.headerHeight)

            Divider().frame(height: ContentView.dividerHeight)
                .background(Theme.surface1.opacity(0.3))

            VStack(alignment: .leading, spacing: 0) {
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: pt(13)))
                        .foregroundColor(Theme.subtext)
                        .lineLimit(1)
                        .frame(height: ConfirmLayout.subtitleHeight, alignment: .leading)
                }
                ForEach(notes, id: \.text) { note in
                    HStack(spacing: pt(8)) {
                        Image(systemName: note.icon)
                            .font(.system(size: pt(11), weight: .semibold))
                            .foregroundColor(Theme.mauve)
                            .frame(width: pt(16))
                        Text(note.text)
                            .font(.system(size: pt(13), weight: .medium))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Spacer()
                    }
                    .frame(height: ConfirmLayout.noteHeight)
                }
                // The honest caption, and the point of the whole feature: this
                // is the command author's own claim about their script, not
                // something pounce checked. `pounce list --json` carries the
                // same claims plus the path to read.
                Text("declared by the command's own header — pounce doesn't verify it")
                    .font(.system(size: pt(11)))
                    .foregroundColor(Theme.subtext0)
                    .lineLimit(1)
                    .frame(height: ConfirmLayout.captionHeight, alignment: .leading)
            }
            .padding(.horizontal, ContentView.headerHPadding)
            .padding(.vertical, ConfirmLayout.bodyVPadding)
            .frame(width: state.targetWidth, alignment: .leading)

            Divider().frame(height: ContentView.dividerHeight)
                .background(Theme.surface1.opacity(0.3))

            // The launcher's own bar, so the two keys read exactly where every
            // other key in this window reads. ↵ first, esc second: pounce puts
            // the plain Return at the leading edge everywhere else.
            ActionBar(actions: [ItemAction(key: "enter", label: "Run"),
                                ItemAction(key: "esc", label: "Cancel")],
                      firedAction: state.firedAction)
                .frame(height: ContentView.actionBarHeight)
        }
        .frame(width: state.targetWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.wash())
        .clipShape(RoundedRectangle(cornerRadius: PanelChrome.cornerRadius))
        .onAppear {
            // The exact height, the same way launcherBody does it: arithmetic,
            // handed to the window before it refits, never measured. Every
            // frame above is pinned to the same constants this adds up.
            state.pendingContentHeight = panelHeight
            state.onResize?()
            armedAt = Date()
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
    }

    private var panelHeight: CGFloat {
        let hasSubtitle = !(item.subtitle ?? "").isEmpty
        let body = ConfirmLayout.bodyVPadding * 2
            + (hasSubtitle ? ConfirmLayout.subtitleHeight : 0)
            + CGFloat(notes.count) * ConfirmLayout.noteHeight
            + ConfirmLayout.captionHeight
        return state.metrics.headerHeight
            + ContentView.dividerHeight + body
            + ContentView.dividerHeight + ContentView.actionBarHeight
    }

    // MARK: Keys

    // No text field in this view, so nothing routes keys for us — the same
    // situation the camera peek and the cheatsheet are in, and the same answer.
    // Returning nil swallows the event so a stray letter can't beep or leak
    // into whatever becomes first responder next; anything holding ⌘/⌥/⌃ is
    // passed through, so ⌘Q and friends still belong to the system.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard state.pendingConfirm != nil, state.isVisible else { return event }
            if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                return event
            }
            switch event.keyCode {
            case 53:        // esc — no, and back to the list
                state.cancelConfirm()
                return nil
            case 36, 76:    // return / keypad enter — yes, if it is an answer
                // Two Returns in quick succession is how a sure-handed user
                // commits a row, and a held Return repeats — either would
                // answer a sheet that has been on screen for one frame, which
                // is a confirmation nobody read. Swallowed rather than passed
                // on, so it cannot fall through to anything else either.
                if event.isARepeat { return nil }
                if let armedAt, Date().timeIntervalSince(armedAt) < Self.armingDelay {
                    return nil
                }
                state.confirmPending()
                return nil
            default:
                return nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// The sheet's fixed pieces, named so the view and `panelHeight` cannot drift —
// the same contract ContentView.contentHeight has with launcherBody.
enum ConfirmLayout {
    static var bodyVPadding: CGFloat { pt(16) }
    static var subtitleHeight: CGFloat { pt(24) }
    static var noteHeight: CGFloat { pt(26) }
    static var captionHeight: CGFloat { pt(22) }
}
