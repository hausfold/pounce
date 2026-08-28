import Foundation

// FullscreenGate.swift — the decision half of AeroSpace's fullscreen toggle,
// split out of Windows.swift so tests/run.sh can pin it (Foundation-only; the
// AppKit side — the listing spawn and the zoom itself — stays in Aerospace).
//
// `fullscreen` is a MODE, and arming it on a solo window is a silent trap: the
// window already fills its workspace, so nothing visible happens, but
// `window-is-fullscreen` flips and the NEXT window to open there is hidden
// behind this one. The gate fires the toggle only when the window is already
// fullscreen (the OFF take, always allowed — a window whose siblings all closed
// must still have a way out) or shares its workspace with another window.
enum FullscreenGate {
    enum Decision {
        case zoom // the toggle may fire — OFF take, or a sibling shares the workspace
        case hold // solo and not fullscreen — arming the mode here is the trap
    }

    // The listing is what `aerospace list-windows --all --format
    // '%{window-id}\t%{workspace}\t%{window-is-fullscreen}'` prints: one window
    // per line, three tab-separated fields.
    //
    // nil means the target is absent from a well-formed listing — the window
    // closed between the click and the spawn, or is unmanaged (a floating
    // window). The caller degrades nil to the ungated toggle: for an unmanaged
    // window it was a no-op anyway, and refusing to fire would strand the chord
    // on the same hiccup the listing's own failure degrades for.
    static func decide(target: UInt32, listing: String) -> Decision? {
        // Collect first, decide second: `list-windows` emits per workspace in
        // tree order, so the target's line is frequently not first and a single
        // pass would miss every sibling listed before it.
        var rows: [(id: UInt32, workspace: String, fullscreen: Bool)] = []
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let id = UInt32(parts[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            rows.append((
                id,
                String(parts[1]).trimmingCharacters(in: .whitespaces),
                parts[2].trimmingCharacters(in: .whitespaces) == "true"
            ))
        }
        guard let target = rows.first(where: { $0.id == target }) else { return nil }
        if target.fullscreen || rows.contains(where: { $0.id != target.id && $0.workspace == target.workspace }) {
            return .zoom
        }
        return .hold
    }
}
