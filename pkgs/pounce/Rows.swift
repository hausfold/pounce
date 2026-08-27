import SwiftUI
import AppKit

// MARK: - GroupHeaderRow

// A non-selectable section header rendered between groups of items.
struct GroupHeaderRow: View {
    static var height: CGFloat { pt(28) }
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: pt(11), weight: .semibold, design: .rounded))
            .foregroundColor(Theme.subtext0)
            .kerning(0.6)
            .padding(.horizontal, pt(22))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: GroupHeaderRow.height, alignment: .bottom)
            .padding(.bottom, pt(4))
    }
}

// MARK: - SelectionGlide

// The selection is ONE body, not a fill each row paints for itself.
//
// Every row that can be selected draws this, and exactly one of them has
// `isSelected` at a time — but they all hand the shape the SAME
// matchedGeometryEffect id in a namespace the LIST owns, so SwiftUI treats the
// highlight leaving row 3 and the one arriving at row 4 as a single view that
// moved and interpolates its frame on the shared spring. That is the whole
// trick. The shape, the fill and the 8pt inset are byte-for-byte what each row
// used to fill for itself, so a still frame is identical to before; only the
// frames BETWEEN two stills are new, which is why this costs no latency —
// SwiftUI was already drawing them.
//
// The size interpolates too, which is the point on the one list that mixes row
// heights: gliding on or off the quick answer's 76pt hero card grows and
// shrinks the highlight instead of cutting.
struct SelectionGlide: View {
    let isSelected: Bool
    // nil = no namespace on offer, so the highlight cuts the way it always did.
    // Matched geometry needs both ends inside one namespace and a Namespace.ID
    // cannot be conjured per row, so a row rendered outside a list that owns one
    // has to degrade rather than fail.
    var namespace: Namespace.ID? = nil
    // The shape, for the callers that aren't a full-width row: the Stage's
    // tiles are square-ish and butt against their neighbours, so they take a
    // rounder corner and no inset, and a grid CARD is already an inset shape
    // with gutters around it, so it passes 0 and the highlight fills the card
    // exactly. Both default to what every row has always drawn, so a still
    // frame of the list is unchanged. They are NOT interpolated between zones —
    // SwiftUI animates the frame of the matched pair, and the shape is whatever
    // the arriving view says it is. Same shape, same fill, same spring either
    // way — the point of one glide is that the thing moving between a row and a
    // card is ONE view, so only its frame differs.
    var cornerRadius: CGFloat? = nil
    var inset: CGFloat? = nil

    static let id = "pounce.selection"

    private var shape: some View {
        RoundedRectangle(cornerRadius: cornerRadius ?? pt(10))
            .fill(Theme.mauve.opacity(0.20))
    }

    var body: some View {
        ZStack {
            if isSelected {
                if let namespace {
                    shape.matchedGeometryEffect(id: Self.id, in: namespace)
                } else {
                    shape
                }
            }
        }
        .padding(.horizontal, inset ?? pt(8))
    }
}

// MARK: - GridCard

// One row of a `--grid` step, drawn as a card rather than a band.
//
// Same PounceItem, same commit path, same selection body — a grid is a shape a
// step asks for, not a second kind of item. What changes is what the shape is
// FOR: a list reads top-to-bottom and is right for names you scan (files,
// commands), while a two-column grid gives each row a rectangle with room for
// an icon and two lines of description, which is what a step offering THINGS —
// projects, machines, images — needs. Height is fixed (GridLayout.cardHeight)
// so the window's arithmetic resize stays arithmetic.
struct GridCard: View {
    static var height: CGFloat { GridLayout.cardHeight }

    let item: PounceItem
    let isSelected: Bool
    var glide: Namespace.ID? = nil
    var selection: Int = 0
    var glides: Bool = true

    var accent: Color { isSelected ? Theme.mauve : Theme.blue }

    // Same prefix grammar as ItemRow: "app:"/"file:" mean a real Finder icon
    // for that path.
    private var iconFilePath: String? {
        guard let icon = item.icon else { return nil }
        if icon.hasPrefix("app:") { return String(icon.dropFirst(4)) }
        if icon.hasPrefix("file:") { return String(icon.dropFirst(5)) }
        return nil
    }

    var body: some View {
        ZStack {
            // The card at rest. It stays under the highlight rather than
            // swapping with it, so a selected card reads as the same card lit —
            // and so the glide has an unchanging backdrop to travel over.
            RoundedRectangle(cornerRadius: pt(10))
                .fill(Theme.surface0.opacity(0.5))

            SelectionGlide(isSelected: isSelected, namespace: glide, inset: 0)

            HStack(spacing: pt(12)) {
                Group {
                    if let path = iconFilePath {
                        Image(nsImage: AppIconCache.shared.icon(for: path))
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: pt(24), height: pt(24))
                    } else if let iconName = item.icon {
                        ZStack {
                            RoundedRectangle(cornerRadius: pt(8))
                                .fill(accent.opacity(0.18))
                            Image(systemName: iconName)
                                .font(.system(size: pt(16), weight: .semibold))
                                .foregroundColor(accent)
                        }
                    }
                }
                .frame(width: pt(34), height: pt(34))

                VStack(alignment: .leading, spacing: pt(3)) {
                    Text(item.title)
                        .foregroundColor(Theme.text)
                        .font(.system(size: pt(15), weight: .medium, design: .rounded))
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        // Two lines, unlike a list row's one: a card is half the
                        // window wide and the description is the reason to use
                        // a card at all.
                        Text(subtitle)
                            .foregroundColor(Theme.subtext0)
                            .font(.system(size: pt(12), design: .rounded))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, pt(12))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Keyed on the SELECTION for the same reason ItemRow is: the highlight
        // leaving one card and arriving at another are two halves of one move
        // and have to animate in one transaction. `glides` withholds the
        // animation when the LIST moved under the selection rather than the
        // user moving it. See ContentView.glideArmed.
        .animation(glides ? Motion.spring : nil, value: selection)
    }
}

// MARK: - ItemRow

struct ItemRow: View {
    let item: PounceItem
    let isSelected: Bool
    // The list's shared glide namespace, and the index the whole list is
    // currently on. Both default to "no glide" so a row drawn outside a list
    // that owns a namespace (Find Files' own list passes one; anything else)
    // keeps exactly today's behaviour.
    var glide: Namespace.ID? = nil
    var selection: Int = 0
    // False while the selection is moving because the LIST changed under it
    // rather than because the user navigated — see ContentView.glideArmed. The
    // move still happens, it just cuts.
    var glides: Bool = true

    // Both "app:<path>" (launcher) and "file:<path>" (Find Files) render the
    // real Finder icon for that path via NSWorkspace; the prefix just marks it.
    private var iconFilePath: String? {
        guard let icon = item.icon else { return nil }
        if icon.hasPrefix("app:") { return String(icon.dropFirst(4)) }
        if icon.hasPrefix("file:") { return String(icon.dropFirst(5)) }
        return nil
    }

    var body: some View {
        HStack(spacing: pt(14)) {
            Group {
                if let path = iconFilePath {
                    Image(nsImage: AppIconCache.shared.icon(for: path))
                        .resizable().aspectRatio(contentMode: .fit)
                } else if let iconName = item.icon {
                    Image(systemName: iconName)
                        .font(.system(size: pt(17), weight: .medium))
                        .foregroundColor(isSelected ? Theme.mauve : Theme.subtext)
                }
            }
            .frame(width: pt(26), height: pt(26))

            Text(item.title)
                .foregroundColor(Theme.text)
                .font(.system(size: pt(16), weight: .medium, design: .rounded))
                .lineLimit(1)

            Spacer(minLength: pt(8))

            if let subtitle = item.subtitle {
                Text(subtitle)
                    .foregroundColor(Theme.subtext0)
                    .font(.system(size: pt(13), design: .rounded))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, pt(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(SelectionGlide(isSelected: isSelected, namespace: glide))
        .contentShape(Rectangle())
        // Keyed on the SELECTION, not on this row's own `isSelected`: the
        // highlight's departure from one row and its arrival at another are two
        // halves of one move, and they have to animate in the same transaction
        // or matchedGeometryEffect has nothing to interpolate between. It also
        // brings the icon's accent tint along, so the row lights up with the
        // highlight rather than a frame ahead of it.
        //
        // `glides` is what keeps that honest when the list itself moved: a
        // keystroke resets the selection to row 0 from wherever it was, and the
        // row it is leaving may be scrolled out of the viewport or gone from the
        // results altogether — a matched-geometry pair whose source frame is
        // off-screen (or stale, in a LazyVStack that culled it) swoops in from
        // outside the panel. The move is real either way; only the animation is
        // withheld. See ContentView.glideArmed.
        .animation(glides ? Motion.spring : nil, value: selection)
    }
}

// MARK: - AnswerRow

// The quick answer's pinned hero card (inline calculator & friends): a
// tinted icon badge, the result big and front-and-center, the
// interpretation underneath. Taller than a standard row — ContentView's
// listHeight accounts for the difference via AnswerRow.height.
struct AnswerRow: View {
    static var height: CGFloat { pt(76) }
    let item: PounceItem
    let isSelected: Bool
    var glide: Namespace.ID? = nil
    var selection: Int = 0
    var glides: Bool = true

    var accent: Color { isSelected ? Theme.mauve : Theme.blue }

    var body: some View {
        HStack(spacing: pt(14)) {
            ZStack {
                RoundedRectangle(cornerRadius: pt(9))
                    .fill(accent.opacity(0.18))
                Image(systemName: item.icon ?? "equal.square")
                    .font(.system(size: pt(18), weight: .semibold))
                    .foregroundColor(accent)
            }
            .frame(width: pt(40), height: pt(40))

            VStack(alignment: .leading, spacing: pt(3)) {
                Text(item.title)
                    .foregroundColor(Theme.text)
                    .font(.system(size: pt(25), weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)   // long results shrink, never clip
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .foregroundColor(Theme.subtext0)
                        .font(.system(size: pt(12), design: .rounded))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: pt(8))
        }
        .padding(.horizontal, pt(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(SelectionGlide(isSelected: isSelected, namespace: glide))
        .contentShape(Rectangle())
        // Keyed on the SELECTION, not on this row's own `isSelected`: the
        // highlight's departure from one row and its arrival at another are two
        // halves of one move, and they have to animate in the same transaction
        // or matchedGeometryEffect has nothing to interpolate between. It also
        // brings the icon's accent tint along, so the row lights up with the
        // highlight rather than a frame ahead of it.
        //
        // `glides` is what keeps that honest when the list itself moved: a
        // keystroke resets the selection to row 0 from wherever it was, and the
        // row it is leaving may be scrolled out of the viewport or gone from the
        // results altogether — a matched-geometry pair whose source frame is
        // off-screen (or stale, in a LazyVStack that culled it) swoops in from
        // outside the panel. The move is real either way; only the animation is
        // withheld. See ContentView.glideArmed.
        .animation(glides ? Motion.spring : nil, value: selection)
    }
}

// MARK: - App Icon Cache

final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

// MARK: - ActionBar

struct ActionBar: View {
    let actions: [ItemAction]
    // The step's dials (--dial), drawn as chips at the LEADING edge — the
    // actions keep their trailing home, so a step with no dials renders
    // exactly as before. `activeDial` is the one ⇥ steps; `onDialTap` lets a
    // click focus-and-cycle a chip.
    var dials: [Dial] = []
    var activeDial: Int = 0
    var onDialTap: ((Int) -> Void)? = nil
    // The action key that just committed ("enter" / "cmd" / …), so THIS bar can
    // blink the one keycap that fired while the window goes. It answers the
    // question a dismissal otherwise leaves open on a step with three verbs:
    // which one did I just hit? nil (and every other cap) draws at rest.
    var firedAction: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            if !dials.isEmpty {
                HStack(spacing: pt(8)) {
                    ForEach(Array(dials.enumerated()), id: \.offset) { i, dial in
                        DialChip(dial: dial, isActive: i == min(activeDial, dials.count - 1))
                            .onTapGesture { onDialTap?(i) }
                    }
                    KeyCap("⇥")
                }
            }
            Spacer()
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.surface1.opacity(0.6))
                        .frame(width: 1, height: pt(16))
                        .padding(.horizontal, pt(14))
                }
                HStack(spacing: pt(7)) {
                    Text(action.label)
                        .font(.system(size: pt(12), weight: .medium, design: .rounded))
                        .foregroundColor(Theme.subtext)
                    KeyCap(action.displayKey, isPressed: firedAction == action.key)
                }
            }
        }
        .padding(.horizontal, pt(18))
    }
}

// One dial as a chip: the name in caps beside the current value, the active
// dial tinted with the accent. The value change animates as a small vertical
// roll — the chip reads as a dial, not a label swap — driven by the withAnimation
// wrapped around DaemonState.cycleDial's mutation.
struct DialChip: View {
    let dial: Dial
    let isActive: Bool

    var body: some View {
        HStack(spacing: pt(6)) {
            Text(dial.name.uppercased())
                .font(.system(size: pt(10), weight: .semibold, design: .rounded))
                .kerning(0.5)
                .foregroundColor(Theme.subtext0)
            Text(dial.value)
                .font(.system(size: pt(12), weight: .semibold, design: .rounded))
                .foregroundColor(isActive ? Theme.mauve : Theme.text)
                .id(dial.value)   // new identity per value → the roll transition below
                .transition(.asymmetric(insertion: .push(from: .bottom),
                                        removal: .push(from: .top)))
        }
        .padding(.horizontal, pt(9))
        .frame(height: pt(24))
        .background(
            RoundedRectangle(cornerRadius: pt(7))
                .fill(isActive ? Theme.mauve.opacity(0.14) : Theme.surface1.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: pt(7))
                .strokeBorder(isActive ? Theme.mauve.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: pt(7)))
        .contentShape(Rectangle())
    }
}

// Press feedback lives here: a cap whose chord just fired lights, holds for a
// blink, then springs back to rest on the shared spring — a keypress you can
// SEE land, on the one surface that was already telling you what the chord
// does. It plays out during the 0.4s the window lingers before its fade
// (PounceUI.startLinger), so the confirmation and the dismissal are one
// gesture. A `.hideNow` commit (an app launch) takes the window instantly and
// simply never shows it — nothing to confirm there; the app arriving IS the
// confirmation.
struct KeyCap: View {
    let symbol: String
    var isPressed: Bool = false
    @State private var lit = false

    init(_ symbol: String, isPressed: Bool = false) {
        self.symbol = symbol
        self.isPressed = isPressed
    }

    var body: some View {
        Text(symbol)
            .font(.system(size: pt(12), weight: .medium, design: .rounded))
            .foregroundColor(lit ? Theme.mauve : Theme.subtext)
            .frame(minWidth: pt(22), minHeight: pt(22))
            .padding(.horizontal, pt(4))
            .background(
                RoundedRectangle(cornerRadius: pt(6))
                    .fill(lit ? Theme.mauve.opacity(0.42) : Theme.surface1.opacity(0.5))
            )
            .scaleEffect(lit ? 0.93 : 1)
            .onChange(of: isPressed) { blink() }
    }

    // Lit SNAPS on — a key going down has no ease-in — and is released after a
    // hold, from a later runloop turn: both halves in one turn would coalesce
    // into a single update and the lit frame would never be drawn at all.
    //
    // The snap is enforced, not assumed. This runs from onChange, so it
    // inherits whatever transaction published `firedAction`; nothing wraps a
    // commit in withAnimation today, but that is a fact about the callers, not
    // a property of this view, and the day one does the blink would fade in
    // instead of landing.
    private func blink() {
        guard isPressed, !Motion.reduceMotion else { return }
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { lit = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.pressHold) {
            withAnimation(Motion.spring) { lit = false }
        }
    }
}

// MARK: - CustomTextField

final class PounceTextField: NSTextField {
    var wrapsText: Bool = false
    var calculatedHeight: CGFloat?
    var onSubmit: ((String) -> Void)?

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if wrapsText, let h = calculatedHeight {
            size.height = h
        }
        return size
    }

    // Command-key chords are offered to the window as key equivalents before
    // the field editor gets a chance to interpret them. That is normally how a
    // menu item such as ⌘Return would work, but Pounce deliberately has no
    // menu. Catch the chord at the control so it reaches the same submit path
    // as the text system's ordinary Return action.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return / keypad Enter
        if isReturn, flags.contains(.command), !flags.contains(.shift) {
            onSubmit?("cmd")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct CustomTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedIndex: Int
    let itemCount: Int
    let placeholder: String
    let fontSize: CGFloat
    let state: DaemonState
    let onSubmit: (String) -> Void
    var onRevealDown: () -> Void = {}
    // >1 turns on 2D grid navigation (emoji): ↑↓ move by a row, ←→ by one cell.
    var gridColumns: Int = 1
    // How many of the host's LEADING items are drawn as the Stage's tile strip
    // rather than as list rows (ContentView.tileCount). 0 — every caller but the
    // staged launcher — leaves the arrow keys exactly as they were.
    var stageTiles: Int = 0
    // Opt-in, and only the launcher opts in: wrapping is only safe where the host
    // grows its header to match (LauncherView.queryLineCount). The clipboard,
    // emoji, screenshot, file-search and cheatsheet headers are fixed-height
    // filters — a field that wrapped in one of those would just clip its own
    // second line.
    var wraps: Bool = false
    var calculatedHeight: CGFloat? = nil
    var preferredWidth: CGFloat? = nil

    func makeNSView(context: Context) -> NSTextField {
        let tf = PounceTextField()
        context.coordinator.textField = tf
        tf.wrapsText = wraps
        tf.calculatedHeight = calculatedHeight
        tf.onSubmit = onSubmit
        tf.delegate = context.coordinator
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        tf.textColor = NSColor(Theme.text)
        tf.backgroundColor = .clear
        tf.focusRingType = .none
        tf.isBordered = false
        tf.drawsBackground = false
        tf.placeholderString = placeholder
        tf.cell?.sendsActionOnEndEditing = false
        // Wrap instead of scrolling sideways. The host computes how many lines
        // this produces (LauncherView.queryLineCount) and grows the header and
        // the window to match, up to a cap; past the cap the field editor keeps
        // the caret visible by scrolling, which is the only part AppKit does for
        // us. Plain Return still submits (insertNewline is intercepted below);
        // Shift+Return is what inserts a line break in this multi-line mode.
        if wraps {
            tf.cell?.usesSingleLineMode = false
            tf.cell?.wraps = true
            tf.cell?.isScrollable = false
            tf.lineBreakMode = .byWordWrapping
            tf.maximumNumberOfLines = 0
            if let pw = preferredWidth, pw > 0 {
                tf.preferredMaxLayoutWidth = pw
            }
        }

        DispatchQueue.main.async {
            state.textField = tf
            tf.window?.makeFirstResponder(tf)
            // A pre-seeded box (--query, e.g. a draft handed back for editing)
            // puts the caret at the END. Becoming first responder selects all,
            // which is right for a filter you're about to replace and exactly
            // wrong for a paragraph you asked to keep — the first keystroke
            // would delete it.
            if !tf.stringValue.isEmpty,
               let editor = tf.currentEditor() {
                editor.selectedRange = NSRange(location: tf.stringValue.count, length: 0)
            }
        }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if let ptf = tf as? PounceTextField {
            ptf.wrapsText = wraps
            ptf.calculatedHeight = calculatedHeight
            ptf.onSubmit = onSubmit
        }
        if tf.stringValue != text { tf.stringValue = text }
        tf.placeholderString = placeholder
        if tf.font?.pointSize != fontSize {
            tf.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        }
        if wraps {
            if let pw = preferredWidth, pw > 0 {
                tf.preferredMaxLayoutWidth = pw
            } else if tf.bounds.width > 0 {
                tf.preferredMaxLayoutWidth = tf.bounds.width
            }
        }
        context.coordinator.itemCount = itemCount
        context.coordinator.parent = self
        context.coordinator.textField = tf
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleNSView(_ tf: NSTextField, coordinator: Coordinator) {
        coordinator.stopMonitoringKeys()
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CustomTextField
        var itemCount: Int
        weak var textField: NSTextField?
        private var keyMonitor: Any?

        init(_ parent: CustomTextField) {
            self.parent = parent
            self.itemCount = parent.itemCount
            super.init()
            // `doCommandBy` reports the selector after AppKit has interpreted
            // the event, but NSEvent.modifierFlags is global keyboard state —
            // by then ⌥ may already read as up. Read the key event itself so a
            // modified Return cannot degrade into a plain Return and submit the
            // prompt by accident.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleModifiedReturn(event) ?? event
            }
        }

        deinit { stopMonitoringKeys() }

        func stopMonitoringKeys() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        private func handleModifiedReturn(_ event: NSEvent) -> NSEvent? {
            guard let textField,
                  event.window === textField.window,
                  textField.currentEditor() != nil else { return event }

            // ⌃⇥ moves the ⇥ focus to the next dial (several-dial steps). In
            // the monitor rather than doCommandBy because AppKit answers
            // control-tab with a window focus-cycling gesture, never a text
            // selector the field editor would report.
            if event.keyCode == 48,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
               !parent.state.dials.isEmpty {
                parent.state.nextDial()
                return nil
            }

            guard event.keyCode == 36 || event.keyCode == 76 else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Match the existing Shift+Return contract: a shift held with any
            // other modifier still writes a line break, never an action. It has
            // to happen here, not in doCommandBy, for the same reason as the
            // action keys: the global modifier state can clear before AppKit
            // asks the field editor to interpret this event.
            if flags.contains(.shift), let editor = textField.currentEditor() as? NSTextView {
                editor.insertText("\n", replacementRange: editor.selectedRange())
                return nil
            }

            let action: String?
            if flags.contains(.command) { action = "cmd" }
            else if flags.contains(.option) { action = "opt" }
            else if flags.contains(.control) { action = "ctrl" }
            else { action = nil }
            guard let action else { return event }

            parent.onSubmit(action)
            return nil
        }

        func controlTextDidChange(_ n: Notification) {
            guard let tf = n.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        // Is there text left for the caret to move over in that direction? A
        // non-empty SELECTION counts: collapsing it is caret work too.
        private func caretHasRoom(_ tv: NSTextView, forward: Bool) -> Bool {
            let r = tv.selectedRange()
            if r.length > 0 { return true }
            return forward ? r.location < (tv.string as NSString).length : r.location > 0
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            let cols = max(1, parent.gridColumns)
            // The Stage's strip, as an index range. The selection is ONE index
            // across both zones (see ContentView.tileCount), so the only thing
            // the keys need to know is where the strip ends: below it ↑↓ walk
            // rows as they always have, and inside it ← → walk tiles instead.
            //
            // ↑ off the first list row is left to the ordinary -1, which lands
            // on the LAST tile — the strip runs left to right in the same rank
            // order the list continues, so the rightmost tile is genuinely the
            // item above list row 0. ↓ can't be the mirror of that: +1 inside
            // the strip would walk sideways, so it jumps to the list.
            let tiles = max(0, parent.stageTiles)
            let onStrip = tiles > 0 && parent.selectedIndex < tiles
            switch sel {
            case #selector(NSResponder.moveDown(_:)):
                if onStrip {
                    // Nothing below a strip that is the whole list.
                    if tiles < itemCount { parent.selectedIndex = tiles }
                    return true
                }
                if itemCount > 0 {
                    if parent.selectedIndex + cols < itemCount { parent.selectedIndex += cols }
                    return true
                } else if parent.state.isLauncher && parent.state.metrics.hideEmptyList {
                    parent.onRevealDown()        // compact mode: ↓ reveals the list
                    return true
                }
                return false
            case #selector(NSResponder.moveUp(_:)):
                if onStrip { return true }       // the strip is the top row
                if itemCount > 0 {
                    if parent.selectedIndex - cols >= 0 { parent.selectedIndex -= cols }
                    return true
                }
                return false
            // ← → walk the strip. Safe to take the keys from the field editor
            // here and nowhere else: a strip only exists while the box is
            // LITERALLY empty (ContentView.stageTileTarget gates on
            // `state.query.isEmpty`, not on the whitespace-trimmed predicate
            // the rest of the launcher uses), so there is no text for the caret
            // to move through — not even a lone space. Off the strip they stay
            // AppKit's, which is what keeps ⌥← / ⇧→ editing a typed query.
            case #selector(NSResponder.moveRight(_:)) where onStrip:
                if parent.selectedIndex < tiles - 1 { parent.selectedIndex += 1 }
                return true
            case #selector(NSResponder.moveLeft(_:)) where onStrip:
                if parent.selectedIndex > 0 { parent.selectedIndex -= 1 }
                return true
            // ←→ walk the grid — but in a field that can hold a PARAGRAPH they
            // belong to the caret first, and only reach the selection at the
            // text's edge. Escalation, the same shape Esc already uses below:
            // the emoji picker's box is a single-line filter (`wraps == false`)
            // and keeps today's behaviour, while the launcher's wrapping box —
            // the one a `--grid` step draws into, which also carries --query's
            // handed-back draft and ⇧↵ newlines — would otherwise leave a
            // pre-filled paragraph with no arrow key that moves through it.
            case #selector(NSResponder.moveRight(_:)) where cols > 1:
                if parent.wraps, caretHasRoom(textView, forward: true) { return false }
                if parent.selectedIndex < itemCount - 1 { parent.selectedIndex += 1 }
                return true
            case #selector(NSResponder.moveLeft(_:)) where cols > 1:
                if parent.wraps, caretHasRoom(textView, forward: false) { return false }
                if parent.selectedIndex > 0 { parent.selectedIndex -= 1 }
                return true
            // Option+Return maps to insertNewlineIgnoringFieldEditor:, rather
            // than insertNewline:. Both are submission gestures in Pounce; the
            // special selector only means "don't end the field editor" to a
            // normal multiline AppKit control.
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                let flags = NSEvent.modifierFlags
                if flags.contains(.shift) {
                    // NOT textView.insertNewline(nil): an NSTextField is always
                    // edited through a FIELD EDITOR (isFieldEditor == true), and a
                    // field editor answers that selector by ending editing rather
                    // than inserting anything — so it silently did nothing, which
                    // is how Shift+Return looked implemented but wasn't. insertText
                    // goes through the ordinary text-storage path and does insert.
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                }
                // DIAGNOSTIC (fn+Esc/native-picker race)
                NSLog("pounce DIAG: dismiss via enter at \(Date())")
                if flags.contains(.command) { parent.onSubmit("cmd") }
                else if flags.contains(.option) { parent.onSubmit("opt") }
                else if flags.contains(.control) { parent.onSubmit("ctrl") }
                else { parent.onSubmit("enter") }
                return true
            // ⇥ / ⇧⇥ step the active dial. Only when this step declared dials —
            // everywhere else Tab keeps its default (a no-op in the palette's
            // single-field windows), so the emoji grid and friends are untouched.
            case #selector(NSResponder.insertTab(_:)) where !parent.state.dials.isEmpty:
                parent.state.cycleDial(1)
                return true
            case #selector(NSResponder.insertBacktab(_:)) where !parent.state.dials.isEmpty:
                parent.state.cycleDial(-1)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc-to-clear, then Esc-to-dismiss — the standard palette idiom,
                // and here also a guard on the one field that can hold something
                // you'd mind losing. Scoped to `wraps`, which is exactly the
                // free-text query box: the filter-style modes (clipboard, emoji,
                // screenshots, file search, cheatsheet) are single-line and keep
                // their one-press Esc. The draft is filed BEFORE the text goes, so
                // the clear is recoverable too, not just the dismissal.
                if parent.wraps && !parent.state.query.isEmpty {
                    parent.state.stashDraft()
                    parent.state.query = ""
                    textView.string = ""
                    return true
                }
                // DIAGNOSTIC (fn+Esc/native-picker race)
                NSLog("pounce DIAG: dismiss via esc at \(Date())")
                parent.state.cancel()
                return true
            default:
                return false
            }
        }
    }
}
