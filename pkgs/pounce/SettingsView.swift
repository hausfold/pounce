// The Settings window: a sidebar of panes on the left, one scrolling column of
// cards on the right — the same shape perch and trill use, because three apps in
// one family with three different settings windows is three things to learn.
//
// THE PANES ARE GENERATED, not written out. Every card, row, label and sentence
// on them comes from `ConfigSpec.sections()` — the same table `pounce config
// init` renders as an annotated config.json. A setting cannot therefore exist in
// the file and be missing from this window, or be described one way in one and
// another way in the other; there is one description of pounce's settings and
// two renderers for it. What this file adds is the *arrangement*: which pane a
// section lands on (`ConfigSection.pane`), and the four hand-built cards on the
// Config File pane that aren't settings at all.
//
// It is a WINDOW, not a palette mode. The palette is one borderless panel that
// swaps its contents (DisplayMode); this is an ordinary titled, resizable,
// closable mac window with its own controller — see SettingsWindow.swift, which
// also explains why an accessory-policy app has to change policy to show one.
//
// Naming: `ConfigPane` and not `SettingsPane`, because `SettingsPaneStore` in
// this module already means macOS's OWN settings panes, the ones the launcher
// lists as rows. Two different things called the same thing in one module is a
// bug waiting for a hurry.

import AppKit
import SwiftUI

// MARK: - The sidebar

/// The sidebar's contents, in the order they appear. The raw value is the id
/// `ConfigSection.pane` names.
enum ConfigPane: String, CaseIterable, Identifiable {
    case general
    case appearance
    case launcher
    case clipboard
    case keys
    case windows
    case file

    var id: String { rawValue }

    /// Where a section whose `pane` nobody recognises ends up. A section is
    /// never dropped: an unassigned setting that silently doesn't appear is the
    /// exact failure this window exists to fix.
    static let fallback = ConfigPane.general

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .launcher: return "Launcher"
        case .clipboard: return "Clipboard"
        case .keys: return "Keys"
        case .windows: return "Windows"
        case .file: return "Config File"
        }
    }

    /// The line under the pane's title: what this pane is for, in one breath.
    var summary: String {
        switch self {
        case .general:
            return "Whether pounce tells you a new version exists."
        case .appearance:
            return "How big the palette is drawn, how tightly it reads, and what colour it is."
        case .launcher:
            return "What ⌘Space offers besides your apps — files, shortcuts, macOS settings, and the answers it works out inline."
        case .clipboard:
            return "What the clipboard panel remembers, and what it refuses to."
        case .keys:
            return "The key that summons the palette, and the ones that go straight to a single item."
        case .windows:
            return "The gestures that move you between windows and workspaces, and the one that quits an app when its last window goes."
        case .file:
            return "Every switch in this window is one line in one file — the same file you can edit by hand."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintpalette.fill"
        case .launcher: return "magnifyingglass"
        case .clipboard: return "doc.on.clipboard.fill"
        case .keys: return "keyboard.fill"
        case .windows: return "macwindow"
        case .file: return "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .appearance: return .pink
        case .launcher: return .blue
        case .clipboard: return .teal
        case .keys: return .indigo
        case .windows: return .orange
        case .file: return .purple
        }
    }

    /// Panes whose settings the daemon reads ONCE at start rather than on every
    /// summon. Saying so on the pane is the difference between "this switch
    /// doesn't work" and "this switch works after a restart" — and the prose on
    /// the individual settings says it too, but a note at the top is what you
    /// read before you click, not after.
    var restartNote: String? {
        switch self {
        case .keys:
            return "The palette hotkey, the app-scoped chords and the Fn key are read once, when pounce starts. Changes here land after a restart. Everything on the other panes is re-read on every ⌘Space."
        case .windows:
            return "These four are read once, when pounce starts — changes here land after a restart. They also all want the Accessibility grant; without it they stay quiet rather than half-working."
        default:
            return nil
        }
    }

    /// The sections from the spec that belong on this pane, in the spec's own
    /// order (which mirrors `Settings.load()`, which mirrors config.json).
    func sections(from spec: [ConfigSection]) -> [ConfigSection] {
        let known = Set(ConfigPane.allCases.map(\.rawValue))
        return spec.filter {
            $0.pane == rawValue || (self == ConfigPane.fallback && !known.contains($0.pane))
        }
    }
}

// MARK: - The window's root view

struct PounceSettingsView: View {
    @ObservedObject var store: ConfigStore

    /// Which pane the window comes back to. Persisted, like every mac settings
    /// window: reopening lands where you left off, not on the first tab.
    @AppStorage("settingsSelectedPane") private var selectedPaneID = ConfigPane.general.rawValue

    static let windowTitle = "Pounce Settings"
    /// What the window opens at the first time, before anyone has resized it.
    static let defaultWindowSize = NSSize(width: 820, height: 620)

    var body: some View {
        NavigationSplitView {
            List(ConfigPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                        .padding(.leading, 2)
                } icon: {
                    SettingsPaneChip(symbol: pane.symbol, tint: pane.tint)
                }
                .padding(.vertical, 3)
            }
            .removingSidebarToggle()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsSidebarFooter(version: pounceVersion)
            }
            // Outermost, and fixed: this is the width that has to hold
            // "Config File" without an ellipsis, and a settings sidebar has no
            // reason to be draggable.
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ConfigPaneView(pane: ConfigPane(rawValue: selectedPaneID) ?? .general, store: store)
                .frame(minWidth: 520, idealWidth: 600)
        }
        .frame(
            minWidth: 720, maxWidth: .infinity,
            minHeight: 420, maxHeight: .infinity
        )
        .navigationTitle(Self.windowTitle)
        .pounceType()
    }

    /// `List` selects by element ID, and a pane's ID is its raw value — so the
    /// stored default *is* the selection. A nil set (clicking the sidebar's
    /// empty space) is dropped: there is always a pane on screen.
    private var selection: Binding<String?> {
        Binding(
            get: { selectedPaneID },
            set: { newValue in
                guard let newValue else { return }
                selectedPaneID = newValue
            }
        )
    }
}

/// `.toolbar(removing:)` is macOS 15 and pounce's floor is 14 (see build.sh), so
/// the collapse control simply stays on the older OS rather than the window not
/// compiling. Nothing else about the sidebar depends on it.
private extension View {
    @ViewBuilder
    func removingSidebarToggle() -> some View {
        if #available(macOS 15.0, *) {
            // Nothing to toggle: a settings window with a collapsible sidebar
            // is a settings window you can hide the navigation of.
            self.toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

/// The sidebar's foot: which pounce this is, in the place every mac app puts it.
private struct SettingsSidebarFooter: View {
    let version: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 9) {
                // Not `applicationIconImage`: Pounce.app ships no icon (it has
                // never needed one — a `.accessory` app is in no Dock and no
                // Finder window), and AppKit answers that with the generic
                // blank-app placeholder, which in a settings sidebar reads as a
                // missing resource rather than as pounce. The paw is the mark
                // the desktop already uses for it.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pounce")
                        .font(uiFont(12, weight: .semibold))
                    Text(version)
                        .font(uiFont(11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

// MARK: - One pane

struct ConfigPaneView: View {
    let pane: ConfigPane
    @ObservedObject var store: ConfigStore

    var body: some View {
        SettingsPaneLayout(title: pane.title, subtitle: pane.summary) {
            // Whether a click can reach the file at all, said once at the top —
            // before the controls, because on a Nix-managed Mac every control
            // below is read-only and finding that out by clicking one is the
            // wrong order to learn it in.
            ConfigWriteStatus(store: store)

            if let note = pane.restartNote {
                SettingsNote(symbol: "clock.arrow.circlepath", text: note)
            }

            // A pane with one card doesn't get an intro above it: the pane's
            // own summary is already that sentence, two lines up, and reading
            // the same thing twice in a row is what makes a settings window
            // feel padded.
            let sections = pane.sections(from: store.spec)
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                ConfigSectionView(section: section, store: store, showIntro: sections.count > 1)
            }

            if pane == .file {
                ConfigFileCards(store: store)
            }
        }
    }
}

/// One `{ }` of config.json as one card, plus the section's own prose under it.
private struct ConfigSectionView: View {
    let section: ConfigSection
    @ObservedObject var store: ConfigStore
    /// False on a pane with one card, where the pane's summary already said it.
    var showIntro = true

    var body: some View {
        if section.fields.isEmpty {
            // A section with no enumerable keys — `items`, which is a map of
            // the user's own item keys. There is no form for "any key you like";
            // the example that documents it in the file documents it here too.
            ConfigRawSectionView(section: section, store: store)
        } else {
            // The section's prose goes ABOVE its card, not below it as trill's
            // `SettingsFootnote` does. Trill has one card per pane; a pounce
            // pane has up to six, and every one of them has a row called
            // "Enabled" — which is exactly right, since the row IS the key in
            // the file, but it means the sentence saying WHICH feature this
            // card is has to be read before the rows, not after them.
            if showIntro, let doc = section.doc {
                SettingsCardIntro(doc)
            }
            SettingsCard {
                ForEach(Array(section.fields.enumerated()), id: \.offset) { index, field in
                    if index > 0 { SettingsDivider() }
                    ConfigFieldRow(store: store, section: section.name, field: field)
                }
            }
            // Read-only rather than hidden on a Nix-managed Mac: what the
            // settings ARE is still worth reading when they aren't yours to
            // change, and the note above says where they are declared. Faded
            // with it, because macOS draws a disabled switch that is ON in
            // almost the same blue as a live one, and a card you cannot use
            // should not look like one you can.
            .disabled(store.isManagedExternally)
            .opacity(store.isManagedExternally ? 0.65 : 1)
        }
    }
}

/// The line above a card that says what the card is. The mirror of the chrome's
/// `SettingsFootnote` — same voice, other side — snugged up to the card it
/// introduces so the two read as one block.
private struct SettingsCardIntro: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(uiFont(.subheadline))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, -8)
    }
}

private struct ConfigRawSectionView: View {
    let section: ConfigSection
    @ObservedObject var store: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let doc = section.doc {
                SettingsNote(symbol: "slider.horizontal.3", text: doc)
            }
            if let raw = section.raw {
                Text(raw.replacingOccurrences(of: "// ", with: "")
                    .replacingOccurrences(of: "//", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(uiFont(11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Button("Open config.json") { store.openInEditor() }
                .disabled(!store.fileExists)
        }
    }
}

/// The one thing a file-backed settings window owes the user: whether the click
/// actually reached the file. Silent on the happy path.
private struct ConfigWriteStatus: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        if store.isManagedExternally {
            SettingsNote(
                symbol: "lock.fill",
                tint: .secondary,
                text: """
                These controls are read-only on this Mac: config.json is a symlink into the \
                Nix store, written from your host file's `haus.launcher.*` options. A change \
                here would be reverted by the next `haus rebuild` without saying so. Change \
                it where it's declared, then rebuild.
                """
            )
        } else if let error = store.writeError {
            SettingsNote(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
        }
    }
}

// MARK: - The Config File pane's own cards

/// Not settings: where the file is, how to get at it, and what this window does
/// to it. The one pane that isn't generated, because none of it is a key in
/// config.json.
private struct ConfigFileCards: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        SettingsCard {
            SettingsRow(
                symbol: "folder",
                title: "config.json",
                subtitle: store.path.path
            ) {
                Button("Reveal") { store.revealInFinder() }
                    .disabled(!store.fileExists)
            }
            SettingsDivider()
            if store.fileExists {
                SettingsRow(
                    symbol: "square.and.pencil",
                    title: "Edit it by hand",
                    subtitle: "Comments and trailing commas are fine — pounce parses this as JSON5, which is what lets the file you read be the file it reads. Edits show on the next ⌘Space."
                ) {
                    Button("Open") { store.openInEditor() }
                }
            } else {
                SettingsRow(
                    symbol: "doc.badge.plus",
                    title: "There is no config.json yet",
                    subtitle: "Pounce is running on its defaults. Writing one puts every setting in it at its default with a sentence above it, all commented out — the same file `pounce config init` writes. Changing anything in this window creates it too."
                ) {
                    Button("Create") { store.createAnnotatedConfig() }
                        .disabled(store.isManagedExternally)
                }
            }
        }

        SettingsFootnote(
            """
            There is no second copy of these settings. A switch in this window rewrites \
            exactly one line of that file and leaves your comments, your ordering and any \
            key pounce has never heard of untouched. Setting something back to its default \
            comments its line out again, so the file keeps only the decisions you actually \
            made.
            """
        )

        SettingsNote(
            symbol: "terminal",
            text: """
            `pounce config print` writes the same annotated config to stdout without \
            touching anything — pipe it, or diff it against yours. `pounce doctor` says \
            whether the hotkey is really firing.
            """
        )
    }
}
