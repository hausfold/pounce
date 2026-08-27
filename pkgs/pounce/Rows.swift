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

// MARK: - ItemRow

struct ItemRow: View {
    let item: PounceItem
    let isSelected: Bool

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
        .background(
            RoundedRectangle(cornerRadius: pt(10))
                .fill(isSelected ? Theme.mauve.opacity(0.20) : Color.clear)
                .padding(.horizontal, pt(8))
        )
        .contentShape(Rectangle())
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
        .background(
            RoundedRectangle(cornerRadius: pt(10))
                .fill(isSelected ? Theme.mauve.opacity(0.20) : Color.clear)
                .padding(.horizontal, pt(8))
        )
        .contentShape(Rectangle())
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
                    KeyCap(action.displayKey)
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

struct KeyCap: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Text(symbol)
            .font(.system(size: pt(12), weight: .medium, design: .rounded))
            .foregroundColor(Theme.subtext)
            .frame(minWidth: pt(22), minHeight: pt(22))
            .padding(.horizontal, pt(4))
            .background(
                RoundedRectangle(cornerRadius: pt(6))
                    .fill(Theme.surface1.opacity(0.5))
            )
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

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            let cols = max(1, parent.gridColumns)
            switch sel {
            case #selector(NSResponder.moveDown(_:)):
                if itemCount > 0 {
                    if parent.selectedIndex + cols < itemCount { parent.selectedIndex += cols }
                    return true
                } else if parent.state.isLauncher && parent.state.metrics.hideEmptyList {
                    parent.onRevealDown()        // compact mode: ↓ reveals the list
                    return true
                }
                return false
            case #selector(NSResponder.moveUp(_:)):
                if itemCount > 0 {
                    if parent.selectedIndex - cols >= 0 { parent.selectedIndex -= cols }
                    return true
                }
                return false
            case #selector(NSResponder.moveRight(_:)) where cols > 1:
                if parent.selectedIndex < itemCount - 1 { parent.selectedIndex += 1 }
                return true
            case #selector(NSResponder.moveLeft(_:)) where cols > 1:
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
