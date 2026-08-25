// The widgets that honour `ConfigControl` — one row per setting, generated from
// ConfigSpec rather than written out by hand.
//
// Kept apart from SettingsChrome.swift, which is a verbatim copy of trill's and
// has to stay diffable against it. Everything here is pounce's own.
//
// ── every control commits on PURPOSE, never on every keystroke ───────────────
// A control bound straight to the store would write config.json once per
// character typed and once per pixel of slider drag — a hundred atomic file
// replacements to change one number, each one re-read and re-parsed. So the
// typed and dragged controls hold a local copy while they are being used and
// hand it over on ⏎, on losing focus, or on the end of a drag. The local copy
// re-syncs from the file whenever the file changes underneath it AND the
// control isn't the thing being edited — which is what lets you edit
// config.json in your editor with this window open.
//
// Toggles, steppers and pickers have no intermediate state to protect, so they
// write immediately.

import AppKit
import SwiftUI

// MARK: - One setting, whatever its shape

/// A row for one `ConfigField`: the trailing-control layout for anything that
/// fits on one line, and a full-width layout for the two that don't (a list of
/// bundle ids, and the structured settings that only the file can express).
struct ConfigFieldRow: View {
    @ObservedObject var store: ConfigStore
    let section: String?
    let field: ConfigField

    var body: some View {
        // A control that can't read the value it was pointed at is a control
        // that would silently change nothing (see `ConfigControl.accepts`), so
        // say so and send the user to the file instead. Only reachable if a
        // ConfigSpec entry pairs a widget with the wrong type of setting — a
        // bug, but one that must not present as a working switch.
        if !field.control.accepts(store.value(section, field)) {
            ConfigFileOnlyRow(
                store: store, section: section, field: field,
                example: store.value(section, field),
                lead: "Pounce can't draw a control for this value, so it's edited in config.json:")
        } else {
            switch field.control {
            case .list(let placeholder):
                ConfigListRow(store: store, section: section, field: field, placeholder: placeholder)
            case .fileOnly(let example):
                ConfigFileOnlyRow(store: store, section: section, field: field, example: example)
            default:
                SettingsRow(symbol: field.symbol, title: field.label, subtitle: field.doc) {
                    HStack(spacing: 8) {
                        ConfigControlView(store: store, section: section, field: field)
                        ResetToDefaultButton(store: store, section: section, field: field)
                    }
                }
            }
        }
    }
}

/// The trailing control itself.
struct ConfigControlView: View {
    @ObservedObject var store: ConfigStore
    let section: String?
    let field: ConfigField

    private var json: String { store.value(section, field) }
    private func write(_ new: String) { store.set(section, field, to: new) }

    var body: some View {
        switch field.control {
        case .toggle:
            Toggle(field.label, isOn: Binding(
                get: { json == "true" },
                set: { write($0 ? "true" : "false") }))
                .labelsHidden()
                .toggleStyle(.switch)

        case .number(let range, let unit):
            HStack(spacing: 6) {
                CommittingTextField(
                    placeholder: "", value: json, width: 64, alignment: .trailing
                ) { text in
                    guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
                    write(ConfigSpec.json(min(max(n, range.lowerBound), range.upperBound)))
                }
                Stepper(field.label, value: Binding(
                    get: { Int(json) ?? range.lowerBound },
                    set: { write(ConfigSpec.json(min(max($0, range.lowerBound), range.upperBound))) }
                ), in: range)
                    .labelsHidden()
                if let unit { UnitLabel(unit) }
            }

        case .decimal(let range, let step, let unit):
            HStack(spacing: 6) {
                CommittingTextField(
                    placeholder: "", value: json, width: 64, alignment: .trailing
                ) { text in
                    guard let d = Double(text.trimmingCharacters(in: .whitespaces)) else { return }
                    write(ConfigSpec.json(min(max(d, range.lowerBound), range.upperBound)))
                }
                Stepper(field.label, value: Binding(
                    get: { Double(json) ?? range.lowerBound },
                    set: { write(ConfigSpec.json(min(max($0, range.lowerBound), range.upperBound))) }
                ), in: range, step: step)
                    .labelsHidden()
                if let unit { UnitLabel(unit) }
            }

        case .slider(let range, let step):
            CommittingSlider(
                range: range, step: step,
                value: Double(json) ?? 1
            ) { write(ConfigSpec.json($0)) }

        case .choice(let choices):
            Picker(field.label, selection: Binding(
                get: { ConfigValue.string(json) ?? choices.first?.value ?? "" },
                set: { write(ConfigSpec.json($0)) }
            )) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

        case .text(let placeholder, let nullable):
            CommittingTextField(
                placeholder: placeholder, value: ConfigValue.string(json) ?? "", width: 190
            ) { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty && nullable { write("null") } else { write(ConfigSpec.json(trimmed)) }
            }

        case .key:
            CommittingTextField(
                placeholder: "space", value: ConfigValue.string(json) ?? "", width: 84, monospaced: true
            ) { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
                guard !trimmed.isEmpty else { return }
                write(ConfigSpec.json(trimmed))
            }

        case .modifiers:
            ModifierPicker(selected: ConfigValue.strings(json)) { write(ConfigSpec.json($0)) }

        case .list, .fileOnly:
            // Handled by their own row shapes; never reached from here.
            EmptyView()
        }
    }
}

/// The unit after a number field — "copies", "seconds". Grey and small, so the
/// row reads as one phrase rather than a form field with a caption.
private struct UnitLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// Hand one setting back to its default — which, in this file's grammar, means
/// commenting its line out again. Present only while the setting is NOT at its
/// default, so the card stays quiet for the settings you never touched, and it
/// doubles as the only marker of which ones you did.
struct ResetToDefaultButton: View {
    @ObservedObject var store: ConfigStore
    let section: String?
    let field: ConfigField

    var body: some View {
        Button {
            store.set(section, field, to: field.json)
        } label: {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .help("Back to the default (\(field.json)) — the line comes out of config.json")
        .opacity(store.isDefault(section, field) ? 0 : 1)
        // Reserved rather than inserted: appearing and disappearing would shove
        // every control on the card sideways the first time you change one.
        .disabled(store.isDefault(section, field))
        .frame(width: 16)
    }
}

// MARK: - The two full-width shapes

/// A list of strings, one per line — bundle ids, mostly. Full width because
/// four bundle ids do not fit in a trailing control, and because pasting a
/// column of them out of another window is how this setting actually gets
/// filled in.
struct ConfigListRow: View {
    @ObservedObject var store: ConfigStore
    let section: String?
    let field: ConfigField
    let placeholder: String

    private var json: String { store.value(section, field) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                if let symbol = field.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                    Text(field.doc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                ResetToDefaultButton(store: store, section: section, field: field)
            }
            CommittingLineEditor(
                placeholder: placeholder,
                value: ConfigValue.strings(json).joined(separator: "\n")
            ) { text in
                let lines = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                store.set(section, field, to: ConfigSpec.json(lines))
            }
            .padding(.leading, 29)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A setting whose shape a row can't honestly draw. Says how many there are and
/// what one looks like, and opens the file — which is a smaller lie than a form
/// that can express half of them.
struct ConfigFileOnlyRow: View {
    @ObservedObject var store: ConfigStore
    let section: String?
    let field: ConfigField
    let example: String
    /// The sentence above the example. Defaults to the ordinary "this one lives
    /// in the file" reading; the mismatch path overrides it to say why.
    var lead = "Each one looks like this, and is edited in config.json:"

    private var count: Int { ConfigValue.count(store.value(section, field)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 11) {
                if let symbol = field.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                    Text(field.doc)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(count == 0 ? "None" : "\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(lead)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(example)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Open config.json") { store.openInEditor() }
                    .disabled(!store.fileExists)
            }
            .padding(.leading, 29)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - Modifier chips

/// ⌘ ⌥ ⇧ ⌃ as four little toggles. A modifier set is short, closed and
/// symbol-shaped, so four chips beat a text field you can typo into.
struct ModifierPicker: View {
    let selected: [String]
    let commit: ([String]) -> Void

    /// The order a chord is written in, so toggling back to exactly the default
    /// produces the default's own spelling and the line leaves the file again.
    static let order = ["cmd", "ctrl", "opt", "shift"]
    static let glyphs = ["cmd": "⌘", "ctrl": "⌃", "opt": "⌥", "shift": "⇧"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.order, id: \.self) { name in
                let on = selected.contains(name)
                Button {
                    var next = Set(selected)
                    if on { next.remove(name) } else { next.insert(name) }
                    commit(Self.order.filter { next.contains($0) })
                } label: {
                    Text(Self.glyphs[name] ?? name)
                        .font(.system(size: 13))
                        .frame(width: 26, height: 22)
                        .background(
                            on ? Color.accentColor : Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help(name)
            }
        }
    }
}

// MARK: - Commit-on-purpose primitives

/// A text field whose edits reach the file on ⏎ or on losing focus, never
/// per-keystroke. `value` is the authoritative one from disk; it only overwrites
/// what is being typed when this field isn't the one being typed in.
struct CommittingTextField: View {
    let placeholder: String
    let value: String
    var width: CGFloat? = nil
    var alignment: TextAlignment = .leading
    var monospaced: Bool = false
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(alignment)
            .font(monospaced ? .system(size: 12, design: .monospaced) : nil)
            .frame(width: width)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: focused) { _, now in if !now { commit(text) } }
            .onSubmit { commit(text) }
    }
}

/// The same bargain for a multi-line list. No `onSubmit` — Return is a new
/// entry here — so it commits when focus leaves.
struct CommittingLineEditor: View {
    let placeholder: String
    let value: String
    let commit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 84)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
                .focused($focused)
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, new in if !focused { text = new } }
        .onChange(of: focused) { _, now in if !now { commit(text) } }
    }
}

/// A slider that writes once, when you let go — not sixty times on the way
/// there.
struct CommittingSlider: View {
    let range: ClosedRange<Double>
    let step: Double
    let value: Double
    let commit: (Double) -> Void

    @State private var live: Double = 1
    @State private var dragging = false

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $live, in: range, step: step) { editing in
                dragging = editing
                if !editing { commit(live) }
            }
            .frame(width: 150)
            Text(String(format: "%.2f×", live))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
        .onAppear { live = value }
        .onChange(of: value) { _, new in if !dragging { live = new } }
    }
}
