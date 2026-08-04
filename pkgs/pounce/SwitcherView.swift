import SwiftUI
import AppKit

// MARK: - Switcher State

// The quasimode's render model, mutated by WindowSwitcher (always on the main
// thread — the event tap's run loop). No text field: the panel never becomes
// key, all input arrives through the event tap.
final class SwitcherState: ObservableObject {
    @Published var visible: [WindowInfo] = []
    @Published var selection = 0
    @Published var query = ""
    @Published var workspaces: [CGWindowID: String] = [:]

    var onSelect: ((Int) -> Void)?    // row click → select + commit
    var onResize: (() -> Void)?       // content height changed; panel refits
}

// MARK: - Layout

enum SwitcherLayout {
    static let width: CGFloat = 640
    static let rowHeight: CGFloat = 44
    static let headerHeight: CGFloat = 26
    static let queryHeight: CGFloat = 40
    static let maxVisibleRows = 9
}

// MARK: - Panel

// A non-activating floating panel: it must never steal key focus (the app the
// user is leaving keeps it until the commit lands), which is also why it needs
// no responder chain — the event tap feeds it. Chrome matches the palette
// window (same blur, mask, radius) so the switcher reads as pounce.
final class SwitcherPanel {
    private let panel: NSPanel
    private let hosting: NSHostingView<SwitcherView>
    private let state: SwitcherState

    init(state: SwitcherState) {
        self.state = state
        hosting = NSHostingView(rootView: SwitcherView(state: state))

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: SwitcherLayout.width, height: pt(200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .statusBar   // above the palette's .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let blur = NSVisualEffectView()
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        PounceUI.applyChrome(blur)   // material/appearance/border follow the palette
        blur.maskImage = PounceUI.roundedMask(radius: pt(16))
        hosting.autoresizingMask = [.width, .height]
        blur.addSubview(hosting)
        panel.contentView = blur

        state.onResize = { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.refit()
        }
    }

    func show() {
        // Same as the palette window: the panel is built once, the palette is
        // re-read per show, so the chrome has to follow it here too.
        if let blur = panel.contentView as? NSVisualEffectView { PounceUI.applyChrome(blur) }
        refit()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    // Size to the SwiftUI content and park it slightly above screen center (the
    // stock switcher's neighborhood). Snap, never tween — same reasoning as
    // PounceUI.resizeToFit.
    private func refit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.height > 1,
              let vf = (NSScreen.main ?? panel.screen)?.visibleFrame else { return }
        let frame = NSRect(
            x: vf.midX - SwitcherLayout.width / 2,
            y: vf.midY - size.height / 2 + vf.height * 0.06,
            width: SwitcherLayout.width,
            height: size.height
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true)
        hosting.frame = panel.contentView?.bounds ?? .zero
        CATransaction.commit()
    }
}

// MARK: - View

struct SwitcherView: View {
    @ObservedObject var state: SwitcherState

    // Row index → the workspace header that precedes it. The list arrives from
    // WindowTracker already gathered by workspace, so a header is simply the
    // first row whose workspace differs from the one above.
    //
    // Empty while filtering: those results are ranked by score, not gathered, so
    // headers would slice the ranking into meaningless bands. The per-row badge
    // takes over there. Also empty when everything is on one workspace — a
    // single header states the obvious and costs a row of screen.
    // Windows AeroSpace doesn't place get their own run under an unnamed
    // header rather than inheriting the header above them, which would read as
    // a lie about which workspace they're on.
    var groupHeaders: [Int: String] {
        guard state.query.isEmpty else { return [:] }
        var out: [Int: String] = [:]
        var previous: String?
        for (i, w) in state.visible.enumerated() {
            let ws = state.workspaces[w.id] ?? ""
            if i == 0 || ws != previous { out[i] = ws }
            previous = ws
        }
        return out.count > 1 ? out : [:]
    }

    func listHeight(headers: Int) -> CGFloat {
        let content = CGFloat(max(state.visible.count, 1)) * SwitcherLayout.rowHeight
                    + CGFloat(headers) * SwitcherLayout.headerHeight
        // Headers buy their own height rather than eating into the nine rows
        // they annotate — and the row part stays an exact multiple of
        // rowHeight, so the cap never slices a row in half at the bottom edge.
        let cap = CGFloat(SwitcherLayout.maxVisibleRows) * SwitcherLayout.rowHeight
                + CGFloat(min(headers, 2)) * SwitcherLayout.headerHeight
        return min(content, cap)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The filter line appears only once the user types — the resting
            // switcher is just the window list.
            if !state.query.isEmpty {
                HStack(spacing: pt(10)) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: pt(13), weight: .medium))
                        .foregroundColor(Theme.subtext)
                    Text(state.query)
                        .font(.system(size: pt(15), weight: .regular, design: .rounded))
                        .foregroundColor(Theme.text)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, pt(20))
                .frame(height: SwitcherLayout.queryHeight)

                Divider().background(Theme.surface1.opacity(0.3))
            }

            if state.visible.isEmpty {
                Text("No matching windows")
                    .font(.system(size: pt(14), design: .rounded))
                    .foregroundColor(Theme.subtext0)
                    .frame(height: SwitcherLayout.rowHeight)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, pt(6))
            } else {
                let headers = groupHeaders
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // Identity is the row POSITION, not the window. The
                            // selection highlight is a function of position
                            // (`i == selection`); keying rows on `w.id` instead
                            // made SwiftUI carry a row's rendered view — highlight
                            // and all — to the window's new slot whenever the list
                            // reordered between opens (the just-focused window
                            // jumps to the top on a rapid second ⌘Tab), stranding
                            // the highlight on the wrong row. Position identity
                            // re-evaluates `isSelected` per slot every time.
                            ForEach(state.visible.indices, id: \.self) { i in
                                if let ws = headers[i] {
                                    SwitcherGroupHeader(name: ws)
                                        .frame(height: SwitcherLayout.headerHeight)
                                }
                                let w = state.visible[i]
                                SwitcherRow(window: w,
                                            // The header already names it; a
                                            // badge on every row under it would
                                            // just repeat itself.
                                            workspace: headers.isEmpty ? state.workspaces[w.id] : nil,
                                            isSelected: i == state.selection)
                                    .frame(height: SwitcherLayout.rowHeight)
                                    .onTapGesture { state.onSelect?(i) }
                            }
                        }
                        .padding(.vertical, pt(6))
                    }
                    .frame(height: listHeight(headers: headers.count) + 12)
                    .onChange(of: state.selection) {
                        if state.visible.indices.contains(state.selection) {
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
        .onChange(of: state.visible.count) { state.onResize?() }
        .onChange(of: state.query.isEmpty) { state.onResize?() }
    }
}

// MARK: - Group header

// The workspace a run of rows belongs to. Reading the list as workspaces rather
// than as one undifferentiated pile is the point: it makes "where was I before
// this" a visible boundary instead of something you infer from badges.
struct SwitcherGroupHeader: View {
    let name: String            // empty = windows AeroSpace doesn't place

    private var isPlaced: Bool { !name.isEmpty }
    private var tint: Color { isPlaced ? Theme.blue : Theme.subtext0 }

    var body: some View {
        HStack(spacing: pt(8)) {
            Text(isPlaced ? name : "—")
                .font(.system(size: pt(10), weight: .bold, design: .rounded))
                .foregroundColor(tint)
                .frame(minWidth: pt(18))
                .padding(.horizontal, pt(6))
                .padding(.vertical, pt(2))
                .background(RoundedRectangle(cornerRadius: pt(5)).fill(tint.opacity(0.15)))
            Rectangle()
                .fill(Theme.surface1.opacity(0.35))
                .frame(height: 1)
        }
        .padding(.horizontal, pt(22))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

struct SwitcherRow: View {
    let window: WindowInfo
    let workspace: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: pt(12)) {
            Group {
                if let path = window.appPath {
                    Image(nsImage: AppIconCache.shared.icon(for: path))
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: pt(16), weight: .medium))
                        .foregroundColor(isSelected ? Theme.mauve : Theme.subtext)
                }
            }
            .frame(width: pt(26), height: pt(26))

            VStack(alignment: .leading, spacing: 1) {
                Text(window.title)
                    .foregroundColor(Theme.text)
                    .font(.system(size: pt(15), weight: .medium, design: .rounded))
                    .lineLimit(1)
                if window.title != window.appName {
                    Text(window.appName)
                        .foregroundColor(Theme.subtext0)
                        .font(.system(size: pt(11), design: .rounded))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: pt(8))

            if window.isMinimized {
                Image(systemName: "arrow.down.right.square")
                    .font(.system(size: pt(12)))
                    .foregroundColor(Theme.subtext0)
            }

            // The AeroSpace workspace this window lives on — the cross-workspace
            // reach is what the badge is advertising.
            if let ws = workspace {
                Text(ws)
                    .font(.system(size: pt(11), weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.blue)
                    .frame(minWidth: pt(20), minHeight: pt(20))
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: pt(5)).fill(Theme.blue.opacity(0.15)))
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
