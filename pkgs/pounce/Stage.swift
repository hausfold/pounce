import SwiftUI
import AppKit

// MARK: - The Stage

// What an EMPTY query looks like: a strip of top-frecency TILES, the familiar
// list beneath them, and one quiet glance line. Type a single character and the
// whole thing yields to today's ranked list — search itself is untouched, and
// every code path below is gated on `queryIsEmpty` in ContentView.
//
// Three rules it is built to:
//
//   1. A tile is not a new kind of thing. It is the SAME `PounceItem` the list
//      would have drawn — same frecency key, same `items` override, same
//      hotkey, same commit path — just drawn as a tile because it is one of the
//      few you actually reach for. `ContentView.visible` stays one flat array
//      and `selectedIndex` indexes across both zones, which is what keeps ⏎,
//      the action bar and `ItemSettings` working here with no second
//      implementation to keep in step.
//   2. It visualises only what is ALREADY in memory. Frecency (the sorted item
//      list), the clipboard head, the update nudge — nothing here reads the
//      disk or the network on the ⌘Space keystroke. The glance line is built
//      ONCE per summon, in `DaemonState.load`, and handed to the view as a
//      value; a body that formatted a date or asked the clipboard store for its
//      head on every render would be doing that work per keystroke.
//   3. It moves on `Motion.spring` or not at all. The selection highlight glides
//      between a tile and a row exactly as it glides between two rows: the tiles
//      draw the same `SelectionGlide` in the same namespace the list owns, so
//      the highlight interpolates from a 130pt square to a full-width bar
//      instead of cutting.
//
// Compact mode is deliberately NOT staged. `hideEmptyList` means "an empty
// query shows nothing", and a tile strip is emphatically something; the gate is
// `showList` in ContentView, so pressing ↓ to reveal brings the stage with it.

enum StageLayout {
    static var tileHeight: CGFloat { pt(74) }
    static var tileSpacing: CGFloat { pt(10) }
    static var stripHPadding: CGFloat { pt(14) }
    static var stripVPadding: CGFloat { pt(10) }
    // Counted by ContentView.contentHeight, which sizes the window
    // arithmetically — this and the frame below must stay one number.
    static var stripHeight: CGFloat { tileHeight + stripVPadding * 2 }
    static var glanceHeight: CGFloat { pt(30) }
    // The widest a clipboard preview may get before it truncates, so a copied
    // paragraph can't push the date off the other end of the line.
    static var clipWidth: CGFloat { pt(240) }
}

// MARK: - The glance line's contents

// A value, not a view model that goes looking for things. Every field is
// snapshotted in `DaemonState.load` from state the daemon already holds, which
// is what makes rendering it free — see rule 2 above. nil fields simply don't
// draw.
struct StageGlance {
    let date: String        // "Thursday 27 August"
    let time: String        // "14:32"
    let clip: String?       // the clipboard head's one-line preview

    // Two things the glance deliberately does NOT carry:
    //
    //   The pending update. It is already a real row, pinned above the list by
    //   ContentView.filtered, and that row is the one you can press ⏎ on. A
    //   second mention in the same panel is noise — and worse, ⌘⏎ on the row
    //   waves the version off (UpdateNudge.dismiss), so a chip that read
    //   `availableVersion` would resurrect exactly what was just dismissed.
    //
    //   The current Focus. `FocusMode.readState()` parses the DoNotDisturb
    //   assertions DB off disk and needs Full Disk Access — I/O on the ⌘Space
    //   keystroke, which is the one thing this zone may not cost. It belongs
    //   here only once something in the daemon already holds it in memory.

    // Snapshotted at summon time, which is also the only time it could be
    // meaningfully right: the window lives for seconds, so a clock that ticked
    // would be animation for its own sake on the one surface that refuses it.
    static func now(clipboardEnabled: Bool) -> StageGlance {
        let now = Date()
        let clip = clipboardEnabled ? ClipboardStore.shared.head?.preview : nil
        return StageGlance(
            date: dateFormatter.string(from: now),
            time: timeFormatter.string(from: now),
            clip: clip.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 })
    }

    // Built once for the life of the process. A DateFormatter costs about as
    // much to create as it does to use, and this is on the summon path. The
    // date is a localized TEMPLATE, not a literal pattern, so the weekday /
    // day / month order is the user's locale's rather than en-GB's.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

// MARK: - The tile strip

struct StageStrip: View {
    let items: [PounceItem]
    let selectedIndex: Int
    // The LIST's glide namespace, handed down so the highlight can travel
    // between a tile and a row as one body. See SelectionGlide.
    var glide: Namespace.ID? = nil
    var glides: Bool = true
    let onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: StageLayout.tileSpacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                StageTile(item: item, isSelected: i == selectedIndex,
                          glide: glide, selection: selectedIndex, glides: glides)
                    .onTapGesture { onPick(i) }
            }
        }
        .padding(.horizontal, StageLayout.stripHPadding)
        .padding(.vertical, StageLayout.stripVPadding)
        .frame(height: StageLayout.stripHeight)
    }
}

// One tile: the item's own icon over its own name. Tiles share the row's width
// equally (`maxWidth: .infinity`) rather than computing a column width, so the
// strip fits whatever `stage.tiles` says without arithmetic that could disagree
// with the window's.
struct StageTile: View {
    let item: PounceItem
    let isSelected: Bool
    var glide: Namespace.ID? = nil
    var selection: Int = 0
    var glides: Bool = true

    // Same two prefixes ItemRow honours: an app or a file draws its real Finder
    // icon, anything else draws an SF Symbol.
    private var iconFilePath: String? {
        guard let icon = item.icon else { return nil }
        if icon.hasPrefix("app:") { return String(icon.dropFirst(4)) }
        if icon.hasPrefix("file:") { return String(icon.dropFirst(5)) }
        return nil
    }

    var body: some View {
        VStack(spacing: pt(8)) {
            Group {
                if let path = iconFilePath {
                    Image(nsImage: AppIconCache.shared.icon(for: path))
                        .resizable().aspectRatio(contentMode: .fit)
                } else if let iconName = item.icon {
                    Image(systemName: iconName)
                        .font(.system(size: pt(22), weight: .medium))
                        .foregroundColor(isSelected ? Theme.mauve : Theme.subtext)
                }
            }
            .frame(width: pt(32), height: pt(32))

            Text(item.title)
                .font(.system(size: pt(11), weight: .medium, design: .rounded))
                .foregroundColor(isSelected ? Theme.text : Theme.subtext)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, pt(5))
        }
        .frame(maxWidth: .infinity)
        .frame(height: StageLayout.tileHeight)
        // Zero inset and a squarer corner: the same highlight body the rows
        // draw, shaped for a tile. Because it is the same matchedGeometryEffect
        // id in the same namespace, ↓ off the strip glides the highlight from
        // here down into the list rather than cutting.
        .background(SelectionGlide(isSelected: isSelected, namespace: glide,
                                   cornerRadius: pt(12), inset: 0))
        .contentShape(Rectangle())
        // Keyed on the SELECTION, for the reason ItemRow documents at length:
        // the highlight leaving one view and arriving at another are two halves
        // of one move and have to animate in the same transaction.
        .animation(glides ? Motion.spring : nil, value: selection)
    }
}

// MARK: - The glance line

// Deliberately not selectable and deliberately not clickable. It is the one
// zone that answers a question you didn't type — what time is it, what did I
// just copy, is there an update — and the moment it becomes a control it is
// competing with the list for the same ⏎.
struct GlanceLine: View {
    let glance: StageGlance

    var body: some View {
        HStack(spacing: pt(8)) {
            Text(glance.time)
                .font(.system(size: pt(11), weight: .semibold, design: .rounded))
                .foregroundColor(Theme.subtext)
            Text(glance.date)
                .font(.system(size: pt(11), design: .rounded))
                .foregroundColor(Theme.subtext0)
                .lineLimit(1)

            Spacer(minLength: pt(10))

            if let clip = glance.clip {
                chip("doc.on.clipboard", clip, tint: Theme.subtext0,
                     maxWidth: StageLayout.clipWidth)
            }
        }
        .padding(.horizontal, pt(18))
        .frame(height: StageLayout.glanceHeight)
    }

    private func chip(_ symbol: String, _ text: String, tint: Color,
                      maxWidth: CGFloat?) -> some View {
        HStack(spacing: pt(5)) {
            Image(systemName: symbol)
                .font(.system(size: pt(10), weight: .medium))
                .foregroundColor(tint)
            Text(text)
                .font(.system(size: pt(11), design: .rounded))
                .foregroundColor(Theme.subtext0)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .fixedSize(horizontal: maxWidth == nil, vertical: false)
    }
}
