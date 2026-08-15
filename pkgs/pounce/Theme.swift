import SwiftUI
import AppKit

// MARK: - Theme

// A palette is the full set of colors the UI paints with. `"theme"` in
// config.json selects one: a built-in below, or any JSON palette dropped into
// ~/.config/pounce/themes/ (see `loaded(_:)`) — no rebuild needed.
struct Palette {
    let base, surface0, surface1, surface2: Color
    let text, subtext, subtext0: Color
    let mauve, blue: Color   // accent (selection/highlight) + secondary accent

    // nebelung — the custom desaturated Catppuccin used across the haus desktop,
    // and the default theme. `static let nebelung` and its light counterpart
    // `nebelungLatte` are GENERATED at build time from the nebelung flake's
    // `palettes` output (see pkgs/pounce/default.nix), so they live in
    // Palette+nebelung.generated.swift rather than here. Both are compiled in
    // because the default pair has to work with no files on disk at all — a
    // Homebrew install with an empty ~/.config still follows macOS light/dark.
    static let defaultDarkName = "nebelung"
    static let defaultLightName = "nebelung-latte"

    // mocha — stock Catppuccin Mocha (pounce's original look).
    static let mocha = Palette(
        base:     Color(hex: "1e1e2e"),
        surface0: Color(hex: "313244"),
        surface1: Color(hex: "45475a"),
        surface2: Color(hex: "585b70"),
        text:     Color(hex: "cdd6f4"),
        subtext:  Color(hex: "a6adc8"),
        subtext0: Color(hex: "6c7086"),
        mauve:    Color(hex: "cba6f7"),
        blue:     Color(hex: "89b4fa"))

    // Is this a LIGHT palette? Relative luminance of `base`, the window fill.
    // The chrome that sits under SwiftUI — the vibrancy material, the hairline
    // border, how opaque the fill has to be — can't be read off a Color, so
    // every polarity-dependent decision routes through this one predicate
    // (see `Theme.wash` and `PounceUI.applyChrome`).
    var isLight: Bool {
        guard let c = NSColor(base).usingColorSpace(.sRGB) else { return false }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent > 0.5
    }

    // A user file SHADOWS a built-in of the same name: `~/.config/pounce/themes/
    // nebelung-latte.json` (what the rice installs) wins over the compiled-in
    // one, so a nebelung update reaches a not-yet-rebuilt pounce. Built-ins are
    // the floor, not the ceiling.
    static func named(_ name: String) -> Palette {
        if let file = loaded(name) { return file }
        switch name.lowercased() {
        case "mocha":                return .mocha
        case defaultLightName:       return .nebelungLatte
        default:                     return .nebelung
        }
    }

    // Runtime palettes: any name that isn't a built-in resolves to
    // ~/.config/pounce/themes/<name>.json — a flat catppuccin-style
    // name → "#hex" map, i.e. nebelung's palette/*.hex.json files verbatim, so
    // every nebelung variant (latte, high-contrast, …) or stock Catppuccin
    // flavor drops in without a rebuild. Same cost model as config.json itself:
    // tiny file, re-read per open, so a theme edit shows on the next open.
    // Unknown name or malformed file falls back to the compiled-in default.
    private static func loaded(_ name: String) -> Palette? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pounce/themes/\(name).json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        // Pounce's roles are a subset of the catppuccin names, offset by one on
        // the greys: pounce `subtext`/`subtext0` read catppuccin
        // `subtext0`/`overlay0` — the same mapping pkgs/pounce/default.nix uses
        // to generate the compiled-in nebelung.
        func color(_ key: String) -> Color? {
            map[key].map { Color(hex: $0.hasPrefix("#") ? String($0.dropFirst()) : $0) }
        }
        guard let base = color("base"),
              let surface0 = color("surface0"),
              let surface1 = color("surface1"),
              let surface2 = color("surface2"),
              let text = color("text"),
              let subtext = color("subtext0"),
              let subtext0 = color("overlay0"),
              let mauve = color("mauve"),
              let blue = color("blue")
        else { return nil }
        return Palette(base: base, surface0: surface0, surface1: surface1,
                       surface2: surface2, text: text, subtext: subtext,
                       subtext0: subtext0, mauve: mauve, blue: blue)
    }
}

// Static façade over the active palette so views keep reading `Theme.base` etc.
// `current` is swapped in per request from the loaded Settings (see the socket
// handler), so editing `"theme"` in config.json takes effect on the next open.
enum Theme {
    static var current: Palette = .nebelung

    static var base: Color { current.base }
    static var surface0: Color { current.surface0 }
    static var surface1: Color { current.surface1 }
    static var surface2: Color { current.surface2 }
    static var text: Color { current.text }
    static var subtext: Color { current.subtext }
    static var subtext0: Color { current.subtext0 }
    static var mauve: Color { current.mauve }
    static var blue: Color { current.blue }

    static var isLight: Bool { current.isLight }

    // Is macOS itself in Light Mode? Decides which of `theme`/`themeLight`/
    // `themeDark` applies (Settings.themeName), read on the same per-open path
    // as config.json — so flipping System Settings shows on the next summon,
    // no daemon restart. NSApp's effectiveAppearance is the authority when
    // there's a running app; the AppleInterfaceStyle default (absent = light)
    // covers the CLI paths that build a palette before NSApplication exists.
    static var systemIsLight: Bool {
        if let app = NSApp {
            return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
    }

    // The translucent window fill, painted over the vibrancy material. `alpha`
    // is the dark-palette value; a light palette needs a heavier tint because a
    // pale wash is exactly what the blur behind it dilutes — 0.55 of #f1f1f1
    // over a blurred dark desktop reads muddy grey, not light. Pull the light
    // case 60% of the way to opaque so the palette's own base wins while some
    // of the backdrop still shows through.
    static func wash(_ alpha: Double = 0.55) -> Color {
        current.base.opacity(isLight ? alpha + (1 - alpha) * 0.6 : alpha)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
