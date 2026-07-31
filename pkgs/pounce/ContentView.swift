import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var state: DaemonState
    @State private var selectedIndex = 0
    @State private var revealed = false   // compact mode: list shown after ↓ / typing

    var rowHeight: CGFloat { state.metrics.rowHeight }
    var maxVisibleItems: Int { state.metrics.maxVisibleItems }

    var queryIsEmpty: Bool {
        state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // True when any item carries a group → render with section headers.
    var hasGroups: Bool { state.items.contains { $0.group != nil } }

    // Distinct groups in first-seen (input) order; this is the section order.
    var groupOrder: [String] {
        var seen = Set<String>(); var order: [String] = []
        for it in state.items {
            if let g = it.group, !seen.contains(g) { seen.insert(g); order.append(g) }
        }
        return order
    }

    // Re-bucket a priority-ordered list into section order, preserving each
    // item's incoming order within its section. (Swift's sort isn't stable, so
    // we bucket explicitly rather than sort by group index.)
    func grouped(_ items: [PounceItem]) -> [PounceItem] {
        guard hasGroups else { return items }
        var buckets: [String: [PounceItem]] = [:]
        for it in items { buckets[it.group ?? "", default: []].append(it) }
        return groupOrder.flatMap { buckets[$0] ?? [] }
    }

    var filtered: [PounceItem] {
        let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [PounceItem]
        if queryIsEmpty {
            base = Array(state.itemsSorted.prefix(state.maxEmpty))
        } else {
            let q = Array(trimmed.lowercased())
            let scored = state.items.compactMap { item -> (PounceItem, Double)? in
                guard let s = state.matchScore(item, query: q) else { return nil }
                return (item, s)
            }
            base = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        }
        var rows = grouped(base)
        // A pending update rides the launcher's first row until it's taken —
        // pinned AFTER grouped() for the same reason the quick answer is:
        // bucketing would otherwise drop it back among the commands. Empty
        // query only; once you type, it competes on merit like any other row.
        // Deduped, because frecency may already have ranked it into the prefix.
        if queryIsEmpty, let notice = state.updateNoticeItem() {
            rows.removeAll { $0.frecencyKey == notice.frecencyKey }
            rows.insert(notice, at: 0)
        }
        // Expression-shaped query? Pin its quick answer (inline calculator,
        // conversions, …) above the matches; ⏎ on it copies.
        if let answer = state.quickAnswerItem(for: trimmed) { return [answer] + rows }
        return rows
    }

    // In compact mode the launcher hides its list on an empty query until the
    // user types or presses ↓. This is a launcher-only affordance — utility /
    // second-step menus (ports, brew, force-quit…) always show their list.
    var showList: Bool {
        if !queryIsEmpty { return true }
        if state.isLauncher && state.metrics.hideEmptyList { return revealed }
        return true
    }

    var visible: [PounceItem] { showList ? filtered : [] }

    var selectedItem: PounceItem? {
        guard selectedIndex < visible.count else { return nil }
        return visible[selectedIndex]
    }

    // Render model: section headers interleaved with the selectable items.
    // `index` is the position in `visible` (headers are not selectable, so
    // keyboard nav over `visible` skips them for free).
    enum RenderRow: Identifiable {
        case header(String)
        case item(PounceItem, Int)
        var id: String {
            switch self {
            case .header(let g): return "header:\(g)"
            case .item(let it, _): return "item:\(it.id)"
            }
        }
    }

    var renderRows: [RenderRow] {
        var rows: [RenderRow] = []
        var lastGroup: String?? = .none
        for (i, item) in visible.enumerated() {
            if hasGroups, item.group != (lastGroup ?? nil) {
                if let g = item.group { rows.append(.header(g)) }
                lastGroup = .some(item.group)
            }
            rows.append(.item(item, i))
        }
        return rows
    }

    // True when the pinned quick answer leads the list (its hero card is
    // taller than a standard row).
    var hasAnswer: Bool { visible.first?.kind == .answer }

    var listHeight: CGFloat {
        let cap = min(visible.count, maxVisibleItems)
        let answerExtra = hasAnswer && cap > 0 ? AnswerRow.height - rowHeight : 0
        guard hasGroups else { return CGFloat(cap) * rowHeight + answerExtra }
        // Fit `cap` items plus whatever headers precede them in the window.
        var items = 0, headers = 0
        for row in renderRows {
            if items >= cap { break }
            switch row {
            case .header: headers += 1
            case .item: items += 1
            }
        }
        return CGFloat(cap) * rowHeight + CGFloat(headers) * GroupHeaderRow.height + answerExtra
    }

    static let dividerHeight: CGFloat = 1
    static let actionBarHeight: CGFloat = 44

    // MARK: - The header grows with the query

    // A long query used to run off the right edge with nowhere to go: the field
    // scrolled horizontally and you typed into a moving window. It wraps now, and
    // the header — and so the window — grows a line at a time until the box would
    // reach half way down the screen, after which it scrolls.
    //
    // The window's TOP sits at topInsetFraction of the visible frame, so the room
    // available before the bottom edge hits the half-way mark is what's left of
    // that half. Derived per screen rather than a fixed line count: the same six
    // lines is a third of a laptop display and a sliver of a 5K one.
    var maxQueryLines: Int {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let room = screen * (0.5 - state.metrics.topInsetFraction)
        return max(3, Int(floor(room / queryLineHeight)))
    }
    // Fixed so the wrap width below is arithmetic instead of a guess about how
    // wide a given SF Symbol renders. Comfortably fits the 18pt (standard) and
    // 16pt (compact) search icons.
    static let searchIconColumn: CGFloat = 26
    static let headerHPadding: CGFloat = 20
    static let headerSpacing: CGFloat = 12
    static let queryAnchor = "query"

    // The width the field actually wraps at — launcherBody's HStack in numbers:
    // the window, less the padding either side, less the icon column and the gap
    // after it. Kept in lockstep with the frames below.
    var queryWidth: CGFloat {
        state.metrics.width - Self.headerHPadding * 2 - Self.searchIconColumn - Self.headerSpacing
    }

    var queryFont: NSFont {
        NSFont.systemFont(ofSize: state.metrics.searchFontSize, weight: .regular)
    }

    var queryLineHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: queryFont))
    }

    // COMPUTED, never measured: resizeToFit reads contentHeight in the same
    // runloop turn as the keystroke that changed it, and on Tahoe a hosting
    // view's fittingSize is still the previous turn's answer by then — that is
    // the flash this whole exact-height path exists to avoid.
    //
    // Uncapped, because this is the height the FIELD gets. Handing an NSTextField
    // less room than its text needs and asking its field editor to scroll the
    // difference is what produced the broken box: the editor scrolled to the
    // caret, drew the tail of the text at the top of the frame with a half-clipped
    // line above it, and left the rest of the frame empty. Give the field every
    // line it needs and it never scrolls; the SwiftUI ScrollView around it does
    // the clipping, at displayedQueryLines.
    var queryLineCountRaw: Int {
        guard !state.query.isEmpty else { return 1 }
        let bounds = (state.query as NSString).boundingRect(
            with: CGSize(width: queryWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: queryFont])
        return max(Int(ceil(bounds.height / queryLineHeight)), 1)
    }

    // What the window actually shows. Equal to the raw count until the box hits
    // the half-way cap, so below the cap there is no scroll view to scroll.
    var displayedQueryLines: Int { min(queryLineCountRaw, maxQueryLines) }

    var queryFieldHeight: CGFloat { CGFloat(queryLineCountRaw) * queryLineHeight }
    var queryViewportHeight: CGFloat { CGFloat(displayedQueryLines) * queryLineHeight }

    // One line is the metrics' own header height; every extra shown line adds
    // exactly its own height, so the breathing room above and below the text is
    // the same whether the query is one line or fills the cap.
    var headerHeight: CGFloat {
        state.metrics.headerHeight + CGFloat(displayedQueryLines - 1) * queryLineHeight
    }

    // The launcher panel's EXACT height, mirroring launcherBody's layout 1:1 so
    // the window can size to it without measuring the hosting view (see
    // PounceUI.resizeToFit — measuring is stale in the same runloop turn on
    // Tahoe, which is what made filtering flash). Header, then — when the list
    // shows — a divider + the scroll area (listHeight + its 12pt vertical
    // padding), then — when a row is selected — a divider + the action bar. The
    // divider and action-bar frames below are pinned to these same constants;
    // keep the two in lockstep.
    var contentHeight: CGFloat {
        var h = headerHeight
        if !visible.isEmpty {
            h += Self.dividerHeight + listHeight + 12
            if selectedItem != nil { h += Self.dividerHeight + Self.actionBarHeight }
        }
        return h
    }

    // Stash the exact height for the window, then ask it to refit. Called from the
    // launcher's onChange hooks so every filter/reveal resizes in one clean snap.
    func requestResize() {
        state.pendingContentHeight = contentHeight
        state.onResize?()
    }

    var body: some View {
        Group {
            if state.isLoading {
                SkeletonView(state: state)
            } else if state.displayMode == .clipboard {
                ClipboardView(state: state)
            } else if state.displayMode == .emoji {
                EmojiView(state: state)
            } else if state.displayMode == .screenshots {
                ScreenshotsView(state: state)
            } else if state.displayMode == .camera {
                CameraView(state: state)
            } else if state.displayMode == .cheatsheet {
                CheatsheetView(state: state)
            } else if state.displayMode == .fileSearch {
                FileSearchView(state: state)
            } else {
                launcherBody
            }
        }
        // New identity per request resets the child views' @State (clipboard /
        // emoji / screenshots queries).
        .id(state.requestID)
        // query itself is cleared synchronously in reset() (no flash). These are
        // local @State, so reset them per request here.
        .onReceive(state.$requestID) { _ in
            selectedIndex = 0
            revealed = false
        }
    }

    var launcherBody: some View {
        VStack(spacing: 0) {
            // Search header. Top-aligned, because a wrapped query grows DOWN: the
            // icon and the first line have to stay put while lines two and three
            // appear beneath them, or the whole header slides as you type. The
            // outer .frame then centres that block inside headerHeight, which is
            // what keeps the padding above and below identical at every line count.
            HStack(alignment: .top, spacing: Self.headerSpacing) {
                Image(systemName: state.globalIcon ?? "magnifyingglass")
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.subtext)
                    .frame(width: Self.searchIconColumn, height: queryLineHeight)
                // The field always gets every line its text needs; the scroll view
                // is what stops at the cap. Below the cap the two heights are
                // equal, so there is nothing to scroll and nothing behaves
                // differently from a one-line query.
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        CustomTextField(
                            text: $state.query,
                            selectedIndex: $selectedIndex,
                            itemCount: visible.count,
                            placeholder: state.placeholderText,
                            fontSize: state.metrics.searchFontSize,
                            state: state,
                            onSubmit: { action in select(action: action) },
                            onRevealDown: { revealed = true },
                            wraps: true
                        )
                        .frame(height: queryFieldHeight)
                        .id(Self.queryAnchor)
                    }
                    .frame(height: queryViewportHeight)
                    // Typing appends at the end, so past the cap the end is the
                    // only part worth looking at. Without this you would be typing
                    // into text you cannot see — the same complaint as the
                    // sideways scrolling this replaced.
                    .onChange(of: state.query) {
                        proxy.scrollTo(Self.queryAnchor, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal, Self.headerHPadding)
            .frame(height: headerHeight)

            if !visible.isEmpty {
                Divider().frame(height: Self.dividerHeight).background(Theme.surface1.opacity(0.3))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(renderRows) { row in
                                switch row {
                                case .header(let title):
                                    GroupHeaderRow(title: title)
                                        .frame(height: GroupHeaderRow.height)
                                        .id(row.id)
                                case .item(let item, let i):
                                    Group {
                                        if item.kind == .answer {
                                            AnswerRow(item: item, isSelected: i == selectedIndex)
                                        } else {
                                            ItemRow(item: item, isSelected: i == selectedIndex)
                                        }
                                    }
                                    .frame(height: item.kind == .answer ? AnswerRow.height : rowHeight)
                                    .id(item.id)
                                    .onTapGesture { selectedIndex = i; select(action: "enter") }
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(height: listHeight + 12)
                    .onChange(of: selectedIndex) {
                        if selectedIndex < visible.count { proxy.scrollTo(visible[selectedIndex].id) }
                    }
                }

                if let item = selectedItem {
                    Divider().frame(height: Self.dividerHeight).background(Theme.surface1.opacity(0.3))
                    ActionBar(actions: item.actions)
                        .frame(height: Self.actionBarHeight)
                }
            }
        }
        .frame(width: state.metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.wash())
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // requestResize on every keystroke, not just when the result count moves:
        // the header itself changes height now, and typing past the end of a line
        // with the same (or no) results showing is exactly the case a
        // visible.count hook cannot see.
        .onChange(of: state.query) { selectedIndex = 0; revealed = false; requestResize() }
        .onChange(of: visible.count) { requestResize() }
        .onChange(of: renderRows.count) { requestResize() }
        // The answer card can appear/vanish while the row COUNT stays equal
        // (its slot swaps with a match) — that still changes the height.
        .onChange(of: hasAnswer) { requestResize() }
        .onChange(of: state.requestID) { selectedIndex = 0; revealed = false; requestResize() }
    }

    func select(action: String) {
        if visible.isEmpty {
            if !state.query.isEmpty { state.commitText(state.query) } else { state.cancel() }
            return
        }
        guard selectedIndex < visible.count else { state.cancel(); return }
        state.commit(visible[selectedIndex], action: action)
    }
}

// MARK: - Loading (skeleton) View

// Shown between a two-step command's steps. The search header stays put — now
// carrying the command's name + icon with a cleared field, matching the step-2
// header that's about to arrive — while the results area shows pulsing skeleton
// rows. Reads as "results loading", not a window reload.
struct SkeletonView: View {
    @ObservedObject var state: DaemonState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: state.loadingIcon)
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.subtext)
                Text(state.loadingTitle)
                    .font(.system(size: state.metrics.searchFontSize, weight: .regular))
                    .foregroundColor(Theme.subtext0)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: state.metrics.headerHeight)

            Divider().background(Theme.surface1.opacity(0.3))

            // Fill the window at its CURRENT height (it isn't resized when loading
            // begins) with exactly enough skeleton rows — no arbitrary intermediary
            // height. The single animated resize happens when step 2's data lands.
            GeometryReader { geo in
                let n = max(1, Int(geo.size.height / state.metrics.rowHeight))
                VStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { i in
                        SkeletonRow(delay: Double(i) * 0.1)
                            .frame(height: state.metrics.rowHeight)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: state.targetWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.wash())
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// A single placeholder row with a staggered, gentle pulse.
struct SkeletonRow: View {
    let delay: Double
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.surface1)
                .frame(width: 24, height: 24)
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surface1)
                .frame(width: 150, height: 11)
            Spacer()
        }
        .padding(.horizontal, 18)
        .opacity(pulse ? 0.9 : 0.3)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(delay)) {
                pulse = true
            }
        }
    }
}
