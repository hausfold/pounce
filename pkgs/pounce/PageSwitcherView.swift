import SwiftUI
import AppKit

// MARK: - Page walk HUD
//
// The ⌃⇥ page walk's list (AppScoped.swift drives it). Sibling of the ⌘⇥ window
// switcher's HUD, one deliberate difference: the rows here are *pages*, not
// windows. Each row is one AeroSpace workspace of the family you're standing in
// — `T`, `T/haus`, `T/pounce` — with the windows that live on it listed under
// it, so the choice is made by recognising the contents of a page rather than
// by remembering its name.
//
// Only the walk's own candidates are ever shown: the live (non-empty) pages of
// `pages.prefix`'s family. Everything else on the Mac is ⌘⇥'s business, and a
// page walk that listed workspaces the chord cannot reach would be lying about
// what the next tap does.

// One row of the HUD: a page and the windows on it, in the window MRU order the
// tracker already gathered them in.
struct PageGroup: Identifiable {
    let name: String              // the AeroSpace workspace name, e.g. "T/haus"
    let windows: [WindowInfo]

    var id: String { name }
}

// The walk's render model, mutated by AppScopedKeys (always on the main thread —
// the event tap's run loop). No text field and no filtering: the walk owns the
// keyboard only while ⌃ is held, and letters under a held ⌃ are control codes
// the terminal underneath still wants.
final class PageSwitcherState: ObservableObject {
    @Published var groups: [PageGroup] = []
    @Published var selection = 0
    // The page the walk started on, drawn with a marker so "where I came from"
    // stays visible once the walk has moved past it.
    @Published var origin: String?

    var onSelect: ((Int) -> Void)?    // row click → select + commit
    var onResize: (() -> Void)?       // content height changed; panel refits
}

enum PageSwitcherLayout {
    static var headerHeight: CGFloat { pt(30) }
    static var windowRowHeight: CGFloat { pt(24) }
    static var groupBottomPadding: CGFloat { pt(6) }
    static var listVPadding: CGFloat { pt(8) }
    // Where a window's TITLE starts: the row's leading inset, its icon, and the
    // gap after it. The lines that have no icon (the overflow counter, the
    // empty-page note) hang off this so they can't drift out of alignment.
    static var textInset: CGFloat { pt(28) + pt(16) + pt(8) }
    // Past this the list scrolls to the selection instead of growing. Sized so
    // a handful of pages with a few windows each all fit; a lane machine with
    // fifteen pages is meant to scroll rather than paint over the screen.
    static var maxListHeight: CGFloat { pt(460) }
    // A page with more windows than this shows a "+N more" line instead. The
    // point of the row is recognising the page, and eight terminal windows all
    // titled the same recognise no better than four.
    static let maxWindowsPerPage = 4
}

// MARK: - View

struct PageSwitcherView: View {
    @ObservedObject var state: PageSwitcherState

    private func rowsShown(_ g: PageGroup) -> Int {
        // An empty page still draws one line. The candidate pages come from
        // AeroSpace's window map while the rows come from the tracker's AX
        // cache, and the two can disagree for a moment (an app that timed out
        // the AX walk looks exactly like an app with nothing open) — a header
        // hanging over nothing would read as the page being empty, which is the
        // one thing it can't be.
        if g.windows.isEmpty { return 1 }
        // The overflow line takes the last slot rather than being extra height.
        return g.windows.count > PageSwitcherLayout.maxWindowsPerPage
            ? PageSwitcherLayout.maxWindowsPerPage
            : g.windows.count
    }

    private func groupHeight(_ g: PageGroup) -> CGFloat {
        PageSwitcherLayout.headerHeight
            + CGFloat(rowsShown(g)) * PageSwitcherLayout.windowRowHeight
            + PageSwitcherLayout.groupBottomPadding
    }

    private var listHeight: CGFloat {
        let content = state.groups.reduce(0) { $0 + groupHeight($1) }
        return min(max(content, PageSwitcherLayout.headerHeight),
                   PageSwitcherLayout.maxListHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.groups.isEmpty {
                Text("No pages")
                    .font(uiFont(pt(14), design: .rounded))
                    .foregroundColor(Theme.subtext0)
                    .frame(height: PageSwitcherLayout.headerHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PageSwitcherLayout.listVPadding)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Identity is the row POSITION, not the page name —
                            // same reasoning as SwitcherView: the highlight is a
                            // function of the slot, and keying on the name lets
                            // SwiftUI carry a rendered row (highlight included)
                            // to the page's new slot when the ring reorders
                            // between walks.
                            ForEach(state.groups.indices, id: \.self) { i in
                                PageGroupCard(group: state.groups[i],
                                              isSelected: i == state.selection,
                                              isOrigin: state.groups[i].name == state.origin,
                                              shown: rowsShown(state.groups[i]))
                                    .frame(height: groupHeight(state.groups[i]))
                                    .id(i)
                                    .onTapGesture { state.onSelect?(i) }
                            }
                        }
                        .padding(.vertical, PageSwitcherLayout.listVPadding)
                    }
                    .frame(height: listHeight + 2 * PageSwitcherLayout.listVPadding)
                    .onChange(of: state.selection) {
                        if state.groups.indices.contains(state.selection) {
                            proxy.scrollTo(state.selection)
                        }
                    }
                }
            }
        }
        .frame(width: SwitcherLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.wash())
        .clipShape(RoundedRectangle(cornerRadius: PanelChrome.cornerRadius))
        .onChange(of: state.groups.count) { state.onResize?() }
    }
}

// MARK: - Group card

struct PageGroupCard: View {
    let group: PageGroup
    let isSelected: Bool
    let isOrigin: Bool
    let shown: Int

    private var overflow: Int { group.windows.count - shown }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: pt(8)) {
                Text(group.name)
                    .font(uiFont(pt(11), weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? Theme.mauve : Theme.blue)
                    .padding(.horizontal, pt(7))
                    .padding(.vertical, pt(2))
                    .background(RoundedRectangle(cornerRadius: pt(5))
                        .fill((isSelected ? Theme.mauve : Theme.blue).opacity(0.15)))
                if isOrigin {
                    // Where the walk started. Once you have stepped away, this
                    // is the only thing on screen that still says so.
                    Circle()
                        .fill(Theme.subtext0)
                        .frame(width: pt(5), height: pt(5))
                }
                if !group.windows.isEmpty {
                    Text(group.windows.count == 1 ? "1 window" : "\(group.windows.count) windows")
                        .font(uiFont(pt(10), design: .rounded))
                        .foregroundColor(Theme.subtext0)
                }
                Rectangle()
                    .fill(Theme.surface1.opacity(0.35))
                    .frame(height: 1)
            }
            .padding(.horizontal, pt(16))
            .frame(height: PageSwitcherLayout.headerHeight)

            if group.windows.isEmpty {
                Text("windows not listed yet")
                    .font(uiFont(pt(11), design: .rounded))
                    .foregroundColor(Theme.subtext0)
                    .padding(.leading, PageSwitcherLayout.textInset)
                    .frame(height: PageSwitcherLayout.windowRowHeight, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(group.windows.prefix(shown).indices, id: \.self) { i in
                let w = group.windows[i]
                // The last visible slot becomes the counter when the page holds
                // more windows than the card draws.
                if overflow > 0 && i == shown - 1 {
                    Text("+\(overflow + 1) more")
                        .font(uiFont(pt(11), design: .rounded))
                        .foregroundColor(Theme.subtext0)
                        .padding(.leading, PageSwitcherLayout.textInset)
                        .frame(height: PageSwitcherLayout.windowRowHeight,
                               alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    PageWindowRow(window: w)
                        .frame(height: PageSwitcherLayout.windowRowHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: pt(10))
                .fill(isSelected ? Theme.mauve.opacity(0.20) : Color.clear)
                .padding(.horizontal, pt(8))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Window line

// Deliberately lighter than SwitcherRow: here a window is evidence about the
// page, not the thing being chosen, so it gets one line and a small icon.
struct PageWindowRow: View {
    let window: WindowInfo

    var body: some View {
        HStack(spacing: pt(8)) {
            Group {
                if let path = window.appPath {
                    Image(nsImage: AppIconCache.shared.icon(for: path))
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: pt(11), weight: .medium))
                        .foregroundColor(Theme.subtext)
                }
            }
            .frame(width: pt(16), height: pt(16))

            Text(window.title)
                .font(uiFont(pt(12), design: .rounded))
                .foregroundColor(Theme.text)
                .lineLimit(1)

            if window.title != window.appName {
                Text(window.appName)
                    .font(uiFont(pt(11), design: .rounded))
                    .foregroundColor(Theme.subtext0)
                    .lineLimit(1)
            }

            Spacer(minLength: pt(8))

            if window.isMinimized {
                Image(systemName: "arrow.down.right.square")
                    .font(.system(size: pt(10)))
                    .foregroundColor(Theme.subtext0)
            }
        }
        .padding(.leading, pt(28))
        .padding(.trailing, pt(20))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
