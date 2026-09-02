import SwiftUI

// MARK: - Emoji View

struct EmojiView: View {
    @ObservedObject var state: DaemonState
    @State private var query = ""
    @State private var selectedIndex = 0

    var filtered: [EmojiEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty query: most-used first (frecency), stable dataset order
            // otherwise. Symbols are hidden here until you've actually used one
            // — the browse grid stays the emoji grid it has always been, and a
            // symbol earns its place in it by frecency exactly like an emoji
            // does. Typing surfaces the whole corpus (see the scored branch).
            var browse: [(entry: EmojiEntry, order: Int, frec: Double)] = []
            for (i, e) in state.emojiEntries.enumerated() {
                let frec = state.emojiFrecency(e.c)
                guard e.kind == .emoji || frec > 0 else { continue }
                browse.append((e, i, frec))
            }
            browse.sort { a, b in a.frec != b.frec ? a.frec > b.frec : a.order < b.order }
            return browse.map { $0.entry }
        }
        let q = Array(trimmed.lowercased())
        let scored = state.emojiEntries.compactMap { e -> (EmojiEntry, Double)? in
            guard let s = state.emojiMatch(e, query: q) else { return nil }
            return (e, s)
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    var selected: EmojiEntry? {
        guard selectedIndex < filtered.count else { return nil }
        return filtered[selectedIndex]
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: pt(4)), count: EmojiLayout.columns)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: pt(12)) {
                Image(systemName: "face.smiling")
                    .font(.system(size: pt(16), weight: .medium))
                    .foregroundColor(Theme.subtext)
                CustomTextField(
                    text: $query, selectedIndex: $selectedIndex,
                    itemCount: filtered.count, placeholder: state.placeholderText,
                    fontSize: 18, state: state,
                    onSubmit: { _ in commit() },
                    gridColumns: EmojiLayout.columns
                )
            }
            .padding(.horizontal, pt(20))
            .frame(height: pt(52))

            Divider().background(Theme.surface1.opacity(0.3))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: pt(4)) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, e in
                            // Color emoji carry their own ink; a monochrome
                            // symbol drawn at the same size next to them reads
                            // as thin and unaligned, so it gets its own metrics
                            // and the theme's text color.
                            Text(e.c)
                                .font(uiFont(e.kind == .emoji ? 26 : 22))
                                .foregroundColor(e.kind == .emoji ? .primary : Theme.text)
                                .frame(maxWidth: .infinity)
                                .frame(height: EmojiLayout.cellHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: pt(8))
                                        .fill(i == selectedIndex ? Theme.mauve.opacity(0.30) : Color.clear)
                                )
                                .id(e.c)
                                .onTapGesture { selectedIndex = i; commit() }
                        }
                    }
                    .padding(pt(8))
                }
                .frame(height: EmojiLayout.gridHeight)
                .onChange(of: selectedIndex) {
                    if selectedIndex < filtered.count { proxy.scrollTo(filtered[selectedIndex].c) }
                }
            }

            Divider().background(Theme.surface1.opacity(0.3))

            HStack(spacing: pt(10)) {
                if let e = selected {
                    Text(e.c)
                        .font(uiFont(pt(18)))
                        .foregroundColor(e.kind == .emoji ? .primary : Theme.text)
                    Text(e.name)
                        .foregroundColor(Theme.subtext)
                        .font(uiFont(pt(12)))
                        .lineLimit(1)
                    if e.kind == .symbol {
                        Text(e.codepoints)
                            .foregroundColor(Theme.subtext0)
                            .font(uiFont(pt(11), design: .monospaced))
                    }
                } else {
                    Text("No match").foregroundColor(Theme.subtext0).font(uiFont(pt(12)))
                }
                Spacer()
            }
            .padding(.horizontal, pt(16))
            .frame(height: pt(36))
        }
        .frame(width: EmojiLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.wash())
        .onChange(of: query) { selectedIndex = 0 }
        .onChange(of: state.requestID) { query = ""; selectedIndex = 0 }
    }

    func commit() {
        guard let e = selected else { state.cancel(); return }
        state.commitEmoji(e)
    }
}
