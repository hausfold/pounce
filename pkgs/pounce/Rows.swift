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

    var body: some View {
        HStack(spacing: 0) {
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

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if wrapsText, let h = calculatedHeight {
            size.height = h
        }
        return size
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
        tf.wrapsText = wraps
        tf.calculatedHeight = calculatedHeight
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
        // us. Enter cannot insert a newline even in this multi-line mode —
        // insertNewline is intercepted below and submits.
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
        }
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        if let ptf = tf as? PounceTextField {
            ptf.wrapsText = wraps
            ptf.calculatedHeight = calculatedHeight
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
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CustomTextField
        var itemCount: Int

        init(_ parent: CustomTextField) {
            self.parent = parent
            self.itemCount = parent.itemCount
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
            case #selector(NSResponder.insertNewline(_:)):
                let flags = NSEvent.modifierFlags
                if flags.contains(.shift) {
                    textView.insertNewline(nil)
                    return true
                } else if flags.contains(.command) { parent.onSubmit("cmd") }
                else if flags.contains(.option) { parent.onSubmit("opt") }
                else if flags.contains(.control) { parent.onSubmit("ctrl") }
                else { parent.onSubmit("enter") }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.state.cancel()
                return true
            default:
                return false
            }
        }
    }
}
