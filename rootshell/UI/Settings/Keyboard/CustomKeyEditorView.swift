//
//  CustomKeyEditorView.swift
//  rootshell
//
//  Editor for creating and modifying custom toolbar keys.
//  Supports multi-step sequences of key combos and text.
//

import SwiftUI

struct CustomKeyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let existingKey: CustomKey?
    let onSave: (CustomKey) -> Void
    let onDelete: (() -> Void)?

    enum ActionType: String, CaseIterable {
        case text = "Text"
        case keyCombo = "Key Combo"
        case sequence = "Sequence"

        var displayName: String {
            switch self {
            case .text: return String(localized: "Text", comment: "Custom key action type: text input")
            case .keyCombo: return String(localized: "Key Combo", comment: "Custom key action type: key combination")
            case .sequence: return String(localized: "Sequence", comment: "Custom key action type: multi-step sequence")
            }
        }
    }

    enum ActiveSheet: Identifiable {
        case addKeyCombo
        case editKeyCombo(index: Int, combo: SequenceStep.KeyCombo)
        case addText
        case editText(index: Int, text: String)
        case iconPicker

        var id: String {
            switch self {
            case .addKeyCombo: return "addKeyCombo"
            case .editKeyCombo(let index, _): return "editKeyCombo-\(index)"
            case .addText: return "addText"
            case .editText(let index, _): return "editText-\(index)"
            case .iconPicker: return "iconPicker"
            }
        }
    }

    @State private var label: String
    @State private var iconName: String?
    @State private var colorHex: String?
    @State private var actionType: ActionType
    @State private var quickText: String
    @State private var quickTextReturn: Bool
    @State private var singleCombo: SequenceStep.KeyCombo?
    @State private var sequence: [SequenceStep]
    @State private var activeSheet: ActiveSheet?
    @State private var showingDeleteConfirmation = false

    init(existingKey: CustomKey? = nil, onSave: @escaping (CustomKey) -> Void, onDelete: (() -> Void)? = nil) {
        self.existingKey = existingKey
        self.onSave = onSave
        self.onDelete = onDelete
        _label = State(initialValue: existingKey?.label ?? "")
        _iconName = State(initialValue: existingKey?.iconName)
        _colorHex = State(initialValue: existingKey?.colorHex)
        _sequence = State(initialValue: existingKey?.sequence ?? [])

        // Detect action type from existing key's sequence
        if let existing = existingKey {
            let steps = existing.sequence
            let textSteps = steps.filter { if case .text = $0 { return true }; return false }
            let comboSteps = steps.filter { if case .keyCombo = $0 { return true }; return false }

            // Check for single key combo (not a bare Return)
            if textSteps.isEmpty && comboSteps.count == 1 {
                if case .keyCombo(let c) = comboSteps[0],
                   !(c.modifiers.isEmpty && c.key == .special(.returnKey)) {
                    _actionType = State(initialValue: .keyCombo)
                    _singleCombo = State(initialValue: c)
                    _quickText = State(initialValue: "")
                    _quickTextReturn = State(initialValue: true)
                    return
                }
            }

            // Check for simple text + optional Return
            let isReturnOnly = comboSteps.count <= 1 && comboSteps.allSatisfy {
                if case .keyCombo(let c) = $0 { return c.modifiers.isEmpty && c.key == .special(.returnKey) }
                return false
            }
            if textSteps.count == 1 && isReturnOnly {
                if case .text(let t) = textSteps[0] {
                    _actionType = State(initialValue: .text)
                    _singleCombo = State(initialValue: nil)
                    _quickText = State(initialValue: t)
                    _quickTextReturn = State(initialValue: !comboSteps.isEmpty)
                    return
                }
            }

            // Everything else is a sequence
            _actionType = State(initialValue: steps.isEmpty ? .text : .sequence)
            _singleCombo = State(initialValue: nil)
            _quickText = State(initialValue: "")
            _quickTextReturn = State(initialValue: true)
        } else {
            _actionType = State(initialValue: .text)
            _singleCombo = State(initialValue: nil)
            _quickText = State(initialValue: "")
            _quickTextReturn = State(initialValue: true)
        }
    }

    private var canSave: Bool {
        let hasLabel = !label.trimmingCharacters(in: .whitespaces).isEmpty
        switch actionType {
        case .text:
            return hasLabel && !quickText.isEmpty
        case .keyCombo:
            return hasLabel && singleCombo != nil
        case .sequence:
            return hasLabel && !sequence.isEmpty
        }
    }

    /// Build the effective sequence from the current action type
    private var effectiveSequence: [SequenceStep] {
        switch actionType {
        case .text:
            guard !quickText.isEmpty else { return [] }
            var steps: [SequenceStep] = [.text(quickText)]
            if quickTextReturn {
                steps.append(.keyCombo(SequenceStep.KeyCombo(
                    modifiers: [],
                    key: .special(.returnKey)
                )))
            }
            return steps
        case .keyCombo:
            guard let combo = singleCombo else { return [] }
            return [.keyCombo(combo)]
        case .sequence:
            return sequence
        }
    }

    var body: some View {
        Form {
            buttonLabelSection
            actionTypeSection

            switch actionType {
            case .text:
                textSection
            case .keyCombo:
                keyComboSection
            case .sequence:
                sequenceSection
                addStepSection
            }

            iconSection
            colorSection
            previewSection

            if onDelete != nil {
                deleteSection
            }
        }
        .themedList()
        .navigationTitle(existingKey != nil ? "Edit Custom Key" : "New Custom Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .disabled(!canSave)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addKeyCombo:
                KeyComboPickerSheet(confirmLabel: "Add") { combo in
                    if actionType == .keyCombo {
                        singleCombo = combo
                    } else {
                        sequence.append(.keyCombo(combo))
                    }
                }
                .themedSubSheet(sheetThemeColors)
            case .editKeyCombo(let index, let combo):
                KeyComboPickerSheet(initialCombo: combo, confirmLabel: "Done") { newCombo in
                    guard index < sequence.count else { return }
                    sequence[index] = .keyCombo(newCombo)
                }
                .themedSubSheet(sheetThemeColors)
            case .addText:
                TextStepSheet(confirmLabel: "Add") { text in
                    sequence.append(.text(text))
                }
                .themedSubSheet(sheetThemeColors)
            case .editText(let index, let text):
                TextStepSheet(initialText: text, confirmLabel: "Done") { newText in
                    guard index < sequence.count else { return }
                    sequence[index] = .text(newText)
                }
                .themedSubSheet(sheetThemeColors)
            case .iconPicker:
                SFSymbolPickerSheet(selectedIcon: $iconName)
                    .themedSubSheet(sheetThemeColors)
            }
        }
        .confirmationDialog("Delete Custom Key?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
        }
        .onChange(of: actionType) { oldValue, newValue in
            migrateData(from: oldValue, to: newValue)
        }
    }

    // MARK: - Sections

    private var buttonLabelSection: some View {
        Section {
            TextField("Label", text: $label)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .themedRow()
        } header: {
            Text("Button Label")
        } footer: {
            Text("First 2 characters shown on the toolbar button when there's no icon.")
        }
    }

    private var actionTypeSection: some View {
        Section {
            Picker("Action Type", selection: $actionType) {
                ForEach(ActionType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()
        }
    }

    private var textSection: some View {
        Section {
            TextField("Text to send", text: $quickText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .themedRow()

            Toggle("Press Return after text", isOn: $quickTextReturn)
                .themedRow()
        } header: {
            Text("Text to Send")
        } footer: {
            Text("Sent as terminal input when you tap the button.")
        }
    }

    private var keyComboSection: some View {
        Section {
            if let combo = singleCombo {
                HStack {
                    Text(combo.displayText)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Change") {
                        activeSheet = .addKeyCombo
                    }
                    .font(.subheadline)
                }
                .themedRow()
            } else {
                Button {
                    activeSheet = .addKeyCombo
                } label: {
                    Label("Choose Key Combo", systemImage: "command")
                }
                .themedRow()
            }
        } header: {
            Text("Key Combination")
        } footer: {
            Text("A single key combo sent when you tap the button.")
        }
    }

    private var iconSection: some View {
        Section {
            Button {
                activeSheet = .iconPicker
            } label: {
                HStack {
                    Text("Icon")
                        .foregroundStyle(.primary)
                    Spacer()
                    if let iconName {
                        Image(systemName: iconName)
                            .foregroundStyle(.secondary)
                        Text(iconName)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        Text("None")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .themedRow()

            if iconName != nil {
                Button("Remove Icon", role: .destructive) {
                    iconName = nil
                }
                .themedRow()
            }
        } header: {
            Text("Icon (Optional)")
        } footer: {
            Text("Pick an SF Symbol, or leave blank for text label.")
        }
    }

    private var colorSection: some View {
        Section {
            Toggle("Own Color", isOn: Binding(
                get: { colorHex != nil },
                // Starts from the color custom keys take by key type.
                set: { colorHex = $0 ? SettingsStore.shared.value(Settings.KeyboardToolbar.glyphColorCustomKeys) : nil }
            ))
            .themedRow()

            if let colorHex {
                ColorPicker("Color", selection: Binding(
                    get: { Color(hex: colorHex) ?? .accentColor },
                    set: { self.colorHex = UIColor($0).hexString }
                ), supportsOpacity: false)
                .themedRow()
            }
        } header: {
            Text("Color (Optional)")
        } footer: {
            Text("Colors this key's icon or label on every toolbar, in place of the toolbar's key colors.")
        }
    }

    private var sequenceSection: some View {
        Section {
            if sequence.isEmpty {
                Text("No steps yet. Add a key combo or text below.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .themedRow()
            } else {
                ForEach(Array(sequence.enumerated()), id: \.offset) { index, step in
                    HStack {
                        Text("\(index + 1).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)

                        Button {
                            switch step {
                            case .keyCombo(let combo):
                                activeSheet = .editKeyCombo(index: index, combo: combo)
                            case .text(let text):
                                activeSheet = .editText(index: index, text: text)
                            }
                        } label: {
                            HStack {
                                stepView(step)
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            sequence.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .themedRow()
                }
                .onMove { from, to in
                    sequence.move(fromOffsets: from, toOffset: to)
                }
            }
        } header: {
            Text("Sequence")
        }
    }

    private var quickAddKeys: [(label: String, glyph: String, key: SequenceStep.SpecialKey)] {
        [
            ("Return", "\u{23CE}", .returnKey),
            ("Tab", "\u{21E5}", .tab),
            ("Escape", "\u{238B}", .escape),
            ("Space", "\u{2423}", .space),
        ]
    }

    private var addStepSection: some View {
        Section {
            HStack(spacing: 10) {
                ForEach(quickAddKeys, id: \.key) { item in
                    Button {
                        sequence.append(.keyCombo(SequenceStep.KeyCombo(
                            modifiers: [],
                            key: .special(item.key)
                        )))
                    } label: {
                        VStack(spacing: 2) {
                            Text(item.glyph)
                                .font(.system(.body, design: .monospaced))
                            Text(item.label)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .themedRow()

            Button {
                activeSheet = .addKeyCombo
            } label: {
                Label("Key Combo\u{2026}", systemImage: "command")
            }
            .themedRow()

            Button {
                activeSheet = .addText
            } label: {
                Label("Text\u{2026}", systemImage: "text.cursor")
            }
            .themedRow()
        } header: {
            Text("Add Step")
        }
    }

    private var previewSection: some View {
        Section {
            let steps = effectiveSequence
            if steps.isEmpty {
                Text("Empty sequence")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .themedRow()
            } else {
                Text(steps.map(\.displayText).joined(separator: " \u{2192} "))
                    .font(.system(.body, design: .monospaced))
                    .themedRow()
            }
        } header: {
            Text("Preview")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Label("Delete Custom Key", systemImage: "trash")
                    Spacer()
                }
            }
            .themedRow()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func stepView(_ step: SequenceStep) -> some View {
        switch step {
        case .keyCombo(let combo):
            HStack(spacing: 2) {
                ForEach(Array(SequenceStep.KeyModifier.allCases.filter { combo.modifiers.contains($0) }), id: \.self) { mod in
                    Text(mod.displayGlyph)
                        .font(.system(.body, design: .monospaced))
                }
                Text(combo.key.displayText)
                    .font(.system(.body, design: .monospaced))
            }
        case .text(let string):
            HStack(spacing: 4) {
                Text("Text:")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("\"\(string)\"")
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }
        }
    }

    private func migrateData(from oldValue: ActionType, to newValue: ActionType) {
        switch (oldValue, newValue) {
        case (.text, .sequence):
            // Seed sequence from quick text
            if !quickText.isEmpty {
                sequence = effectiveSequenceForText()
                quickText = ""
            }
        case (.keyCombo, .sequence):
            // Seed sequence from single combo
            if let combo = singleCombo {
                sequence = [.keyCombo(combo)]
                singleCombo = nil
            }
        default:
            break
        }
    }

    /// Build sequence from text fields (used during migration)
    private func effectiveSequenceForText() -> [SequenceStep] {
        guard !quickText.isEmpty else { return [] }
        var steps: [SequenceStep] = [.text(quickText)]
        if quickTextReturn {
            steps.append(.keyCombo(SequenceStep.KeyCombo(
                modifiers: [],
                key: .special(.returnKey)
            )))
        }
        return steps
    }

    private func save() {
        let key = CustomKey(
            id: existingKey?.id ?? UUID(),
            label: label.trimmingCharacters(in: .whitespaces),
            iconName: iconName,
            sequence: effectiveSequence,
            colorHex: colorHex
        )
        onSave(key)
        dismiss()
    }
}


// MARK: - SF Symbol Picker Sheet

private struct SFSymbolPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Binding var selectedIcon: String?
    @State private var searchText = ""

    private static let allSymbols: [String] = [
        "terminal.fill", "command", "network", "server.rack",
        "key.fill", "lock.fill", "bolt.fill", "gearshape",
        "arrow.triangle.branch", "doc.text", "folder", "cloud",
        "hammer", "wrench", "ant", "ladybug",
        "play.fill", "pause.fill", "stop.fill",
        "chevron.left.forwardslash.chevron.right",
        "arrow.right", "arrow.left", "arrow.up", "arrow.down",
        "star.fill", "heart.fill", "flag.fill", "bookmark.fill",
        "cube", "cylinder", "shippingbox",
    ]

    private var filteredSymbols: [String] {
        if searchText.isEmpty { return Self.allSymbols }
        return Self.allSymbols.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            symbolList
                .searchable(text: $searchText, prompt: "Search symbols")
                .navigationTitle("Choose Icon")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    private var symbolList: some View {
        List {
            ForEach(filteredSymbols, id: \.self) { symbol in
                symbolRow(symbol)
                    .themedRow()
            }
        }
        .themedList()
    }

    private func symbolRow(_ symbol: String) -> some View {
        Button {
            selectedIcon = symbol
            dismiss()
        } label: {
            HStack {
                Image(systemName: symbol)
                    .frame(width: 30)
                Text(symbol)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedIcon == symbol {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
