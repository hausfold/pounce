import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var state: DaemonState
    @State private var selectedIndex = 0
    @State private var revealed = false   // compact mode: list shown after ↓ / typing
    // The namespace the selection highlight glides through. It belongs to the
    // LIST, not to a row: matchedGeometryEffect only ties two views together
    // inside one namespace, and the two views here are the highlight leaving
    // the old row and the one arriving at the new. See SelectionGlide.
    @Namespace private var glide
    // Whether the NEXT selection move is one the user made (↑ ↓, a click) or one
    // the list made under them. Only the first glides: a keystroke resets the
    // selection to row 0 from wherever it was, and matched geometry given a
    // source that scrolled out of the viewport — or that the LazyVStack culled —
    // animates in from outside the panel. Disarmed in the query hook below,
    // re-armed the moment the selection settles, so an arrow press right after
    // typing glides normally.
    @State private var glideArmed = true

    var rowHeight: CGFloat { state.metrics.rowHeight }

    // How many rows the window will show. The preset's count is a preference; the
    // screen has the last word, because `scale` multiplies the row height while the
    // desktop stays the same size — eight 46pt rows fit anywhere, eight 92pt ones
    // do not. Without this the panel simply grows off the bottom of the screen at a
    // large scale, which is the failure a legibility setting can least afford.
    // Floored at 3 so it degrades to a short list rather than to nothing.
    var maxVisibleItems: Int {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        let chrome = state.metrics.headerHeight + Self.actionBarHeight
            + Self.dividerHeight * 2 + Self.listVPadding * 2 + stageHeight
        let room = screen * (1 - state.metrics.topInsetFraction) - chrome
        let fits = Int(floor(room / max(rowHeight, 1)))
        return max(3, min(state.metrics.maxVisibleItems, fits))
    }

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
        // The scoring pass lives behind a per-query memo in DaemonState: this
        // property is re-read a dozen-plus times per render (every slice and
        // height below derives from it), and re-scoring every item on each
        // read was the typing lag.
        let base = queryIsEmpty ? state.emptyQueryRows : state.rankedMatches(for: trimmed)
        var rows = grouped(base)
        // A pending update rides the launcher's first row until it's taken —
        // pinned AFTER grouped() for the same reason the quick answer is:
        // bucketing would otherwise drop it back among the commands. Empty
        // query only; once you type, it competes on merit like any other row.
        // Deduped, because frecency may already have ranked it into the prefix.
        if queryIsEmpty, let notice = state.updateNoticeItem() {
            rows.removeAll { $0.frecencyKey == notice.frecencyKey }
            // AFTER the Stage's tiles, so it lands as the first row of the
            // LIST rather than as tile 0. A tile is an icon over a truncated
            // one-line title with no subtitle — "Update Pounce — 2026.07.30
            // available" reads as "Update Pou…" and the per-install hint
            // ("Return to run brew upgrade") is not drawn at all, which is
            // precisely the invisibility the pin exists to fix. See
            // UpdateCheck.swift. With no Stage this is `at: 0`, exactly as
            // before.
            rows.insert(notice, at: min(stageTileTarget, rows.count))
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

    // MARK: - The Stage (empty query only — see Stage.swift)

    // How many of `visible`'s LEADING rows are drawn as tiles instead of list
    // rows. Zero everywhere the Stage isn't on: a typed query, a utility menu,
    // compact mode, `stage.enabled: false` — so every expression below reduces
    // to exactly today's launcher by arithmetic rather than by a second branch.
    //
    // Crucially the strip is a SLICE of the one array, not a second list:
    // `selectedIndex` indexes across both zones, so ⏎, the action bar, frecency,
    // the `items` overrides and the pinned update row all keep working with no
    // second implementation to keep in step.
    // The count the config asked for, before the list's length caps it. Kept
    // independent of `filtered` on purpose: `filtered` reads THIS to place the
    // pinned update notice at the head of the list rather than in the strip,
    // and a cycle between the two would not compile.
    //
    // `state.query.isEmpty`, not `queryIsEmpty`: the trimmed predicate calls a
    // lone space an empty query, and the strip takes ← / → away from the field
    // editor (see CustomTextField) — so with a space typed the caret would be
    // unable to move through text that is really there.
    var stageTileTarget: Int {
        guard state.query.isEmpty, showList, state.stageTiles > 0 else { return 0 }
        return state.stageTiles
    }

    var tileCount: Int { min(stageTileTarget, visible.count) }

    var tileItems: [PounceItem] { Array(visible.prefix(tileCount)) }
    var listItems: [PounceItem] { Array(visible.dropFirst(tileCount)) }

    // The info cards' contents, or nil for no cards. Snapshotted per summon in
    // DaemonState.load; gated on the empty query here, so the first character
    // typed takes the whole zone away. Drawn along the BOTTOM of the panel, just
    // above the action bar — see InfoCards.
    var glance: StageGlance? { stageTileTarget > 0 ? state.stageGlance : nil }

    // What the two Stage zones add to the panel. Counted by `contentHeight`
    // (which sizes the window arithmetically) and by `maxVisibleItems` (which
    // decides how many rows still fit on the screen underneath them). The
    // cards' height counts here even though they DRAW at the bottom — the
    // arithmetic only cares about the total.
    var stageHeight: CGFloat {
        (glance != nil ? StageLayout.cardsHeight : 0)
            + (tileCount > 0 ? StageLayout.stripHeight : 0)
    }

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
        // The list is what's LEFT after the strip took its prefix; the index
        // carried in each row is still the one into `visible`, which is what
        // keeps a click and the keyboard talking about the same row.
        for (i, item) in listItems.enumerated() {
            if hasGroups, item.group != (lastGroup ?? nil) {
                if let g = item.group { rows.append(.header(g)) }
                lastGroup = .some(item.group)
            }
            rows.append(.item(item, i + tileCount))
        }
        return rows
    }

    // True when the pinned quick answer leads the list (its hero card is
    // taller than a standard row).
    var hasAnswer: Bool { visible.first?.kind == .answer }

    var listHeight: CGFloat {
        let cap = min(listItems.count, maxVisibleItems)
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

    // MARK: - …or the same rows as a grid (--grid)

    // How many card rows the items need, and how many of them the window shows.
    // The cap is the grid's answer to `maxVisibleItems` and is computed the same
    // way — the preset's count is a preference, the screen has the last word —
    // because a card is taller than a row and `scale` multiplies it.
    var gridRowCount: Int {
        Int(ceil(Double(visible.count) / Double(GridLayout.columns)))
    }

    var maxVisibleGridRows: Int {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        let chrome = state.metrics.headerHeight + Self.actionBarHeight
            + Self.dividerHeight * 2 + Self.listVPadding * 2
        let room = screen * (1 - state.metrics.topInsetFraction) - chrome
        let fits = Int(floor(room / max(GridLayout.cardHeight + GridLayout.spacing, 1)))
        return max(2, min(GridLayout.maxVisibleRows, fits))
    }

    // Card rows plus the gutters BETWEEN them (n - 1, not n) — the padding
    // around the whole grid is listVPadding, counted by contentHeight exactly
    // as it is for the list.
    var gridHeight: CGFloat {
        let rows = min(gridRowCount, maxVisibleGridRows)
        return CGFloat(rows) * GridLayout.cardHeight
            + CGFloat(max(rows - 1, 0)) * GridLayout.spacing
    }

    // The results area's exact height, whichever shape it is in. contentHeight
    // and the scroll viewport both read this one property, so the arithmetic
    // resize cannot drift from what is drawn.
    var resultsHeight: CGFloat { state.grid ? gridHeight : listHeight }

    // A hairline stays a hairline: it is a 1px rule, not a size, so it is the one
    // constant here that does not scale.
    static let dividerHeight: CGFloat = 1
    static var actionBarHeight: CGFloat { pt(44) }
    // The list's breathing room, above and below. Named because `contentHeight`
    // and the ScrollView frame both have to count it and used to say `12` twice.
    static var listVPadding: CGFloat { pt(6) }

    // MARK: - The header grows with the query

    // A long query used to run off the right edge with nowhere to go: the field
    // scrolled horizontally and you typed into a moving window. It wraps now, and
    // the header — and so the window — grows a line at a time until the box would
    // reach half way down the screen, after which it scrolls.
    var maxQueryLines: Int {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        let room = screen * (0.5 - state.metrics.topInsetFraction)
        return max(3, Int(floor(room / queryLineHeight)))
    }
    // Fixed so the wrap width below is arithmetic instead of a guess about how
    // wide a given SF Symbol renders. Comfortably fits the 18pt (standard) and
    // 16pt (compact) search icons.
    static var searchIconColumn: CGFloat { pt(26) }
    static var headerHPadding: CGFloat { pt(20) }
    static var headerSpacing: CGFloat { pt(12) }
    static let queryAnchor = "query"

    // The width the field actually wraps at — launcherBody's HStack in numbers:
    // the window, less the padding either side, less the icon column and the gap
    // after it. Kept in lockstep with the frames below.
    var queryWidth: CGFloat {
        state.targetWidth - Self.headerHPadding * 2 - Self.searchIconColumn - Self.headerSpacing
    }

    var queryFont: NSFont {
        NSFont.systemFont(ofSize: state.metrics.searchFontSize, weight: .regular)
    }

    var queryLineHeight: CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: queryFont))
    }

    // Uncapped raw number of lines required by the query text.
    var queryLineCountRaw: Int {
        guard !state.query.isEmpty else { return 1 }
        let bounds = (state.query as NSString).boundingRect(
            with: CGSize(width: queryWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: queryFont])
        return max(Int(ceil(bounds.height / queryLineHeight)), 1)
    }

    // Number of lines actually visible in the header (capped at half-screen room).
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
    // A free-text step (`--actions`) has no rows and so no selected item, which is
    // exactly why it needs the bar: ⌘↵/⌥↵/⇧↵ on typed text are otherwise invisible
    // — nothing on screen says the step can do more than one thing.
    // Dials count too: a --dial step with no --actions still needs the bar on
    // screen, or the one interaction it offers is invisible.
    var showFreeTextBar: Bool {
        visible.isEmpty && (!state.freeTextActions.isEmpty || !state.dials.isEmpty)
    }

    var contentHeight: CGFloat {
        var h = headerHeight
        if !visible.isEmpty {
            // The Stage's zones sit between that divider and the results, and
            // are zero-height when it's off — see stageHeight. `resultsHeight`
            // is the list's or the grid's, whichever shape this step asked for.
            h += Self.dividerHeight + stageHeight + resultsHeight + Self.listVPadding * 2
            if selectedItem != nil { h += Self.dividerHeight + Self.actionBarHeight }
        } else if showFreeTextBar {
            h += Self.dividerHeight + Self.actionBarHeight
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
            glideArmed = true
        }
    }

    // The results as a list — the shape every step had before `--grid`.
    var listScroll: some View {
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
                                    AnswerRow(item: item, isSelected: i == selectedIndex,
                                              glide: glide, selection: selectedIndex,
                                              glides: glideArmed)
                                } else {
                                    ItemRow(item: item, isSelected: i == selectedIndex,
                                            glide: glide, selection: selectedIndex,
                                            glides: glideArmed,
                                            hint: state.hotkeyHints[item.frecencyKey],
                                            badge: state.badges[item.frecencyKey])
                                }
                            }
                            .frame(height: item.kind == .answer ? AnswerRow.height : rowHeight)
                            .id(item.id)
                            .onTapGesture { selectedIndex = i; select(action: "enter") }
                        }
                    }
                }
                .padding(.vertical, Self.listVPadding)
                // A keystroke's re-rank deliberately does NOT animate: rows are
                // simply IN the new order the instant scoring returns. A list
                // that reorders several times a second has no reorder worth
                // watching — springing each one read as churn, and every
                // in-flight transaction taxed the very keystroke being handled.
                // The launcher's motion belongs to moves the USER makes (the
                // selection glide, the dial roll, the press blink), never to
                // moves the list makes under them.
            }
            .frame(height: listHeight + Self.listVPadding * 2)
            .onChange(of: selectedIndex) {
                // A selection on the strip has no row in this ScrollView
                // to scroll to — it is above it, always on screen.
                if selectedIndex >= tileCount, selectedIndex < visible.count {
                    proxy.scrollTo(visible[selectedIndex].id)
                }
            }
        }
    }

    // …and the same results as cards, two to a row (`--grid`).
    //
    // Deliberately NOT over `renderRows`: a grid step draws no group headers.
    // A header is a full-width band with a column of rows under it, and a card
    // grid has no full width to give one — so the grid walks `visible`
    // directly, which also makes its index the SELECTION index. That is what
    // lets CustomTextField's 2-D navigation stay pure arithmetic: ←→ is ±1 and
    // ↑↓ is ±GridLayout.columns, with nothing to skip over. (A grid step whose
    // lines carry a group field still gets the grouped ORDER out of
    // `filtered`; it just has nowhere to write the names.)
    var gridScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: GridLayout.spacing),
                                   count: GridLayout.columns),
                    spacing: GridLayout.spacing
                ) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                        GridCard(item: item, isSelected: i == selectedIndex,
                                 glide: glide, selection: selectedIndex,
                                 glides: glideArmed)
                            .frame(height: GridLayout.cardHeight)
                            .id(item.id)
                            .onTapGesture { selectedIndex = i; select(action: "enter") }
                    }
                }
                .padding(.horizontal, GridLayout.hPadding)
                .padding(.vertical, Self.listVPadding)
                // Same rule as the list: a typed re-rank snaps, it never
                // springs. See listScroll.
            }
            .frame(height: gridHeight + Self.listVPadding * 2)
            .onChange(of: selectedIndex) {
                if selectedIndex < visible.count { proxy.scrollTo(visible[selectedIndex].id) }
            }
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
                            // The 2-D navigation the emoji picker already uses,
                            // pointed at this step's cards: ↑↓ move by a card
                            // ROW, ←→ by one card. 1 everywhere else, which is
                            // the plain ↑↓ list walk it has always been. Never
                            // both at once: `--grid --launcher` drops the grid
                            // (State.configure), and only the launcher stages.
                            gridColumns: state.grid ? GridLayout.columns : 1,
                            stageTiles: tileCount,
                            wraps: true,
                            calculatedHeight: queryFieldHeight,
                            preferredWidth: queryWidth
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: queryFieldHeight, alignment: .topLeading)
                        .id(Self.queryAnchor)
                    }
                    .frame(height: queryViewportHeight)
                    .onChange(of: state.query) {
                        proxy.scrollTo(Self.queryAnchor, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal, Self.headerHPadding)
            .frame(height: headerHeight)

            if !visible.isEmpty {
                Divider().frame(height: Self.dividerHeight).background(Theme.surface1.opacity(0.3))

                // The Stage. Both zones are plain views with fixed heights that
                // `contentHeight` counts — no GeometryReader, no measurement, so
                // the window still sizes itself in one arithmetic step. The
                // tiles flow under the header; the info cards draw at the bottom
                // (below the list), and `stageHeight` counts both wherever they
                // sit.
                if tileCount > 0 {
                    StageStrip(items: tileItems, selectedIndex: selectedIndex,
                               glide: glide, glides: glideArmed,
                               onPick: { i in selectedIndex = i; select(action: "enter") })
                }

                // One step, two shapes. Both draw the SAME `visible` items at
                // the same indices and commit through the same select(), so
                // `--grid` changes what the step looks like and nothing about
                // what it does or prints.
                if state.grid { gridScroll } else { listScroll }

                // The Stage's info cards, along the bottom — time/date and the
                // clipboard head, the questions you didn't type.
                if let glance { InfoCards(glance: glance) }

                if let item = selectedItem {
                    Divider().frame(height: Self.dividerHeight).background(Theme.surface1.opacity(0.3))
                    ActionBar(actions: item.actions, dials: state.dials,
                              activeDial: state.activeDial,
                              onDialTap: { state.tapDial($0) },
                              firedAction: state.firedAction)
                        .frame(height: Self.actionBarHeight)
                }
            } else if showFreeTextBar {
                // Same widget, same height, same place as a row's action bar —
                // this one just describes what the modifiers do to the text you
                // typed rather than to a selection.
                Divider().frame(height: Self.dividerHeight).background(Theme.surface1.opacity(0.3))
                ActionBar(actions: state.freeTextActions, dials: state.dials,
                          activeDial: state.activeDial,
                          onDialTap: { state.tapDial($0) },
                          firedAction: state.firedAction)
                    .frame(height: Self.actionBarHeight)
            }
        }
        .frame(width: state.targetWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.wash())
        .clipShape(RoundedRectangle(cornerRadius: PanelChrome.cornerRadius))
        // requestResize on every keystroke, not just when the result count moves:
        // the header itself changes height now, and typing past the end of a line
        // with the same (or no) results showing is exactly the case a
        // visible.count hook cannot see.
        // Disarm the glide for exactly the update this keystroke causes: the
        // selection is about to jump to row 0 from a row the new results may not
        // even contain. `.animation(_:value:)` reads its animation at the moment
        // the value changes, so writing the flag here — in the same handler that
        // moves the index — is what makes the move land unanimated.
        .onChange(of: state.query) {
            glideArmed = false
            selectedIndex = 0
            revealed = false
            requestResize()
        }
        // …and re-arm as soon as the selection has settled, which is the update
        // right after the one above. Nothing visible changes on this pass; it
        // just means the next ↑/↓ glides.
        .onChange(of: selectedIndex) { glideArmed = true }
        .onChange(of: visible.count) { requestResize() }
        .onChange(of: renderRows.count) { requestResize() }
        // The answer card can appear/vanish while the row COUNT stays equal
        // (its slot swaps with a match) — that still changes the height.
        .onChange(of: hasAnswer) { requestResize() }
        .onChange(of: state.requestID) {
            selectedIndex = 0
            revealed = false
            requestResize()
        }
        // Seed the window with its arithmetic height before AppKit's first
        // fitting-size pass installs the multiline field. Fires per REQUEST —
        // the subtree above carries `.id(state.requestID)`.
        .onAppear { requestResize() }
    }

    func select(action: String) {
        if visible.isEmpty {
            // Carry the modifier through. A free-text step is the ONE place the
            // palette has no row to hang actions on, so dropping the action here
            // (as this did) capped every typed-text step at exactly one thing it
            // could do with what you wrote.
            if !state.query.isEmpty { state.commitText(state.query, action: action) }
            // An EMPTY box still commits a modified Return, as long as the step
            // declared that modifier in `--actions`. Not every modified action is
            // about the text: "show me my drafts" and "let me grab a screenshot
            // first" are things you reach for BEFORE you have typed anything, and
            // requiring a character first made the action bar advertise two chords
            // that silently dismissed the palette instead. Plain ↵ on an empty box
            // is still a dismissal — there is nothing to submit.
            else if action != "enter",
                    state.freeTextActions.contains(where: { $0.key == action }) {
                state.commitText("", action: action)
            }
            else { state.cancel() }
            return
        }
        // A stale index is NOT a dismissal. `visible` is derived from the query
        // and is therefore always current, while `selectedIndex` is @State reset
        // by .onChange(of: state.query) on the next view update — so a keystroke
        // that narrows the list, followed a few milliseconds later by a Return,
        // can arrive with the index still pointing past the end of the shorter
        // list. Cancelling there closed the palette outright with nothing
        // committed: type to filter a row far down a menu, commit immediately,
        // and one time in five the window simply vanished (the repo step of
        // haus's Spawn Agent is where it showed). Commit the first row instead —
        // it is what the pending reset was about to select, and it is the row
        // that draws highlighted a frame later.
        let index = selectedIndex < visible.count ? selectedIndex : 0
        state.commit(visible[index], action: action)
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
            HStack(spacing: pt(12)) {
                Image(systemName: state.loadingIcon)
                    .font(.system(size: state.metrics.searchIconSize, weight: .medium))
                    .foregroundColor(Theme.subtext)
                Text(state.loadingTitle)
                    .font(.system(size: state.metrics.searchFontSize, weight: .regular))
                    .foregroundColor(Theme.subtext0)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, pt(20))
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
            .padding(.vertical, ContentView.listVPadding)
        }
        .frame(width: state.targetWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.wash())
        .clipShape(RoundedRectangle(cornerRadius: PanelChrome.cornerRadius))
    }
}

// A single placeholder row with a staggered, gentle pulse.
struct SkeletonRow: View {
    let delay: Double
    @State private var pulse = false

    // Where the pulse rests. Brighter when it will never move, so a static
    // skeleton doesn't read as a row that failed to load.
    private var resting: Double { Motion.reduceMotion ? 0.6 : 0.3 }

    var body: some View {
        HStack(spacing: pt(14)) {
            RoundedRectangle(cornerRadius: pt(6))
                .fill(Theme.surface1)
                .frame(width: pt(24), height: pt(24))
            RoundedRectangle(cornerRadius: pt(5))
                .fill(Theme.surface1)
                .frame(width: pt(150), height: pt(11))
            Spacer()
        }
        .padding(.horizontal, pt(18))
        .opacity(pulse ? 0.9 : resting)
        .onAppear {
            // The one animation in pounce that ISN'T the shared spring, because
            // it isn't a move — it's a "still working" signal, and a spring has
            // no forever. It still answers to Reduce motion, and has to: an
            // indefinitely repeating pulse is the exact thing that setting
            // exists to stop. There it sits at a steady mid opacity instead,
            // which still reads as placeholder rather than content.
            guard !Motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true).delay(delay)) {
                pulse = true
            }
        }
    }
}
