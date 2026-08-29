import SwiftUI
import AppKit

// MARK: - The Stage

// What an EMPTY query looks like: a strip of TILES, the familiar list beneath
// them, and a row of info cards that draw only when they have something to say. Type a single character and the whole thing
// yields to today's ranked list — search itself is untouched, and every code
// path below is gated on `queryIsEmpty` in ContentView.
//
// The strip and the list are ranked by DIFFERENT numbers, which is the point of
// having two zones at all. The list is live: it ranks on the full frecency score
// so this afternoon's burst floats to the top. The strip is muscle memory: it
// ranks on habit alone and then holds its positions across summons, so ⌘3 is the
// same thing this week that it was last week. `StageSlots.swift` owns that rule;
// `DaemonState.hoistSlots` is what puts the result at the head of the array.
//
// Three rules it is built to:
//
//   1. A tile is not a new kind of thing. It is the SAME `PounceItem` the list
//      would have drawn — same frecency key, same `items` override, same
//      hotkey, same commit path — just drawn as a tile because it is one of the
//      few you actually reach for. `ContentView.visible` stays one flat array
//      and `selectedIndex` indexes across both zones, which is what keeps ⏎,
//      the action bar and `ItemSettings` working here with no second
//      implementation to keep in step. The strip's own ranking is expressed as
//      the ORDER of that one array, never as a second list.
//   2. It visualises only what is ALREADY in memory. Frecency (the sorted item
//      list), the clipboard head, the update nudge — nothing here reads the
//      disk or the network on the ⌘Space keystroke. The slot order is the one
//      thing that is persisted, and it is read once at daemon start and written
//      off the main thread only when it changes (StageSlotStore). The info cards' contents
//      are built ONCE per summon, in `DaemonState.load`, and handed to the view
//      as a value; a body that formatted a date or asked the clipboard store
//      for its head on every render would be doing that work per keystroke.
//   3. It moves on `Motion.spring` or not at all. The selection highlight glides
//      between a tile and a row exactly as it glides between two rows: the tiles
//      draw the same `SelectionGlide` in the same namespace the list owns, so
//      the highlight interpolates from a 130pt square to a full-width bar
//      instead of cutting.
//
// Compact mode is deliberately NOT staged at all. `hideEmptyList` means "an
// empty query shows nothing", and a tile strip is emphatically something — the
// two are answers to the same question and the narrower one wins. The gate is
// in `DaemonState.load`, which leaves `stageTiles` at 0 and `stageGlance` nil
// there, so ↓ reveals the plain list exactly as it always has.

enum StageLayout {
    static var tileHeight: CGFloat { pt(80) }
    static var tileSpacing: CGFloat { pt(8) }
    static var stripHPadding: CGFloat { pt(10) }
    static var stripVPadding: CGFloat { pt(8) }
    // Counted by ContentView.contentHeight, which sizes the window
    // arithmetically — this and the frame below must stay one number.
    static var stripHeight: CGFloat { tileHeight + stripVPadding * 2 }
    // The bottom info-card row (what the glance line grew into — see below).
    static var cardsHeight: CGFloat { pt(52) }
    static var cardSpacing: CGFloat { pt(8) }
    // A tile is as wide as its title needs, capped — past the cap the title
    // truncates instead of the tile eating the strip. There is no measuring and
    // no shared column width: the strip is a horizontal ScrollView, so tiles of
    // different widths just flow, and an overflow SCROLLS rather than squeezing.
    static var tileMaxWidth: CGFloat { pt(150) }
    static var tileMinWidth: CGFloat { pt(76) }
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
    let next: Next?         // what usually follows what you just did

    // The predicted follow-up, flattened to what the card draws. A title and an
    // icon, not the item — the view has no business committing anything, and
    // ⇥ goes through `DaemonState.predictedItem` and the ordinary commit path
    // exactly as ⏎ on a row does.
    struct Next {
        let title: String
        let icon: String?
    }

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
    static func now(clipboardEnabled: Bool, next: Next? = nil) -> StageGlance {
        let now = Date()
        let clip = clipboardEnabled ? ClipboardStore.shared.head?.preview : nil
        return StageGlance(
            date: dateFormatter.string(from: now),
            time: timeFormatter.string(from: now),
            clip: clip.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 },
            next: next)
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
        // Horizontal overflow, not a shared column width. Tiles are sized by
        // their own title (StageTile), so nothing here measures anything and no
        // two tiles have to agree; a strip longer than the window scrolls, and
        // the reader keeps the selected tile in view. The height stays the one
        // arithmetic constant — width is the only dimension that flows.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: StageLayout.tileSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        StageTile(item: item, index: i, isSelected: i == selectedIndex,
                                  glide: glide, selection: selectedIndex, glides: glides)
                            .id(item.id)
                            .onTapGesture { onPick(i) }
                    }
                }
                .padding(.horizontal, StageLayout.stripHPadding)
            }
            .frame(height: StageLayout.stripHeight)
            .onChange(of: selectedIndex) {
                guard selectedIndex < items.count else { return }
                proxy.scrollTo(items[selectedIndex].id, anchor: .center)
            }
        }
    }
}

// One tile: the item's own icon over its own name, sized to the name. No
// `maxWidth: .infinity` — that shared-width strip is what made five tiles eat
// the window's width each. A tile is as wide as its title (capped at
// StageLayout.tileMaxWidth, min StageLayout.tileMinWidth) so short names read
// tight and long ones scroll the strip instead of truncating every neighbour.
struct StageTile: View {
    let item: PounceItem
    // Position in the strip, drawn as its ⌘-digit — see below.
    var index: Int = 0
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
                        .font(.system(size: pt(26), weight: .medium))
                        .foregroundColor(isSelected ? Theme.mauve : Theme.subtext)
                }
            }
            .frame(width: pt(38), height: pt(38))

            Text(item.title)
                .font(.system(size: pt(13), weight: .medium, design: .rounded))
                .foregroundColor(isSelected ? Theme.text : Theme.subtext)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, pt(2))
        }
        .padding(.horizontal, pt(12))
        // The tile's own number, because ⌘1…⌘9 fires it (CustomTextField's key
        // monitor). Drawn quietly in the corner rather than as a keycap: it is
        // the answer to a question you only ask once, and the strip's job is to
        // be scanned. Only ever for the first nine — a tenth tile has no chord
        // to advertise, and a bare "10" would read as part of the name.
        .overlay(alignment: .topTrailing) {
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: pt(9), weight: .semibold, design: .rounded))
                    .foregroundColor(isSelected ? Theme.subtext : Theme.surface2)
                    .padding(.top, pt(5))
                    .padding(.trailing, pt(6))
            }
        }
        .frame(minWidth: StageLayout.tileMinWidth, maxWidth: StageLayout.tileMaxWidth)
        .frame(height: StageLayout.tileHeight)
        // A resting card under the highlight, exactly the GridCard pattern: a
        // selected tile reads as the same tile lit, and the glide has an
        // unchanging backdrop to travel over. Without it the unselected tiles
        // float as bare icon-over-label and the strip reads unfinished — the
        // card is what makes a tile a TILE.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: pt(12)).fill(Theme.surface0.opacity(0.5))
                // Zero inset and a squarer corner: the same highlight body the
                // rows draw, shaped for a tile. Because it is the same
                // matchedGeometryEffect id in the same namespace, ↓ off the
                // strip glides the highlight from here down into the list
                // rather than cutting.
                SelectionGlide(isSelected: isSelected, namespace: glide,
                               cornerRadius: pt(12), inset: 0)
            })
        .contentShape(Rectangle())
        // Keyed on the SELECTION, for the reason ItemRow documents at length:
        // the highlight leaving one view and arriving at another are two halves
        // of one move and have to animate in the same transaction.
        .animation(glides ? Motion.spring : nil, value: selection)
    }
}

// MARK: - The bottom info cards

// The glance line's data, drawn the way the sketch wanted it: CARDS along the
// bottom, one per fact, instead of a quiet line the eye has to hunt for at the
// top. Same value, same snapshotting rules — still built ONCE per summon in
// DaemonState.load, never per render.
//
// **A card draws when it has something to say.** That is the rule the row is
// built to now, and the clock is what taught it: `TODAY 14:32` drew on every
// single summon, saying a thing macOS already draws in the menu bar all day.
// A panel element that is always there and never new stops being read at all —
// and takes the cards that ARE new down with it, because the eye learns to skip
// the strip rather than the card.
//
// So the row is news-first:
//
//   NEXT       what usually follows what you just did (NextAction.swift). Rare
//              by construction — it appears only when the pairing is strong —
//              and the one card that is actionable.
//   CLIPBOARD  the clipboard head. Genuinely invisible otherwise: the only way
//              to find out what you are about to paste is to paste it.
//   TODAY      the panel's RESTING FACE, drawn only when neither of the others
//              has anything to say. Not because the time is news, but because
//              an empty strip where a row of cards belongs reads as broken, and
//              the clock is the cheapest honest thing to put there — it is
//              already snapshotted, and it is never wrong.
//
// The NEXT card is a suggestion, not a control. It takes ⇥ — never ⏎, which
// belongs to the selection — and it is deliberately NOT clickable: ⇥ is a
// deliberate act, a click that lands on a card nobody selected is not.
struct InfoCards: View {
    let glance: StageGlance

    var body: some View {
        HStack(spacing: StageLayout.cardSpacing) {
            if let next = glance.next {
                InfoCard(label: "NEXT", icon: next.icon ?? "arrow.turn.down.right",
                         value: next.title, key: "⇥", flexible: glance.clip == nil)
            }
            if let clip = glance.clip {
                InfoCard(label: "CLIPBOARD", icon: "doc.on.clipboard", value: clip)
            }
            if glance.next == nil && glance.clip == nil {
                InfoCard(label: "TODAY", icon: "clock",
                         value: "\(glance.time) · \(glance.date)")
            }
        }
        .padding(.horizontal, pt(12))
        .frame(height: StageLayout.cardsHeight)
    }
}

// One card: a small caps label over the value. The clipboard card flexes to
// take the remaining width (it's the one worth reading); the date card sizes
// to its own text unless it's alone.
struct InfoCard: View {
    let label: String
    let icon: String
    let value: String
    // A keycap on the trailing edge, for the one card you can act on. nil — every
    // other card — draws exactly what it always did.
    var key: String? = nil
    var flexible: Bool = true

    var body: some View {
        HStack(spacing: pt(8)) {
            Image(systemName: icon)
                .font(.system(size: pt(12), weight: .medium))
                .foregroundColor(Theme.subtext0)
            VStack(alignment: .leading, spacing: pt(1)) {
                Text(label)
                    .font(.system(size: pt(9), weight: .semibold, design: .rounded))
                    .kerning(0.8)
                    .foregroundColor(Theme.subtext0)
                Text(value)
                    .font(.system(size: pt(12), weight: .medium, design: .rounded))
                    .foregroundColor(Theme.subtext)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The same KeyCap the action bar draws, so the affordance reads as
            // the same kind of promise the bar's ⏎ and ⌘⏎ make.
            if let key {
                Spacer(minLength: pt(8))
                KeyCap(key)
            }
        }
        .padding(.horizontal, pt(12))
        .padding(.vertical, pt(7))
        .frame(maxWidth: flexible ? .infinity : nil, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: pt(10)).fill(Theme.surface0.opacity(0.45)))
    }
}
