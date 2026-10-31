//
//  SwipeGesturesSettingsView.swift
//  rootshell
//
//  Lets users customize what the terminal's left and right horizontal swipes do.
//  Bindings are stored in SwipeGestureManager and apply to both iOS direct-touch
//  swipes and Mac Catalyst trackpad horizontal pan swipes.
//

import SwiftUI

struct SwipeGesturesSettingsView: View {
    #if os(visionOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var manager = SwipeGestureManager.shared
    @State private var toolbarManager = KeyboardToolbarManager.shared
    @State private var showingResetConfirmation = false
    @State private var swapTrigger = 0
    #if !targetEnvironment(macCatalyst)
    @Setting(Settings.Gestures.scrollMode) private var scrollModeEnabled
    #endif

    // Built-in pair presets shown in the Quick Setup section. Tapping a row
    // applies both directions in one batch update.
    private struct QuickSetupPair: Identifiable {
        let id: String
        let title: String
        let icon: String
        let left: SwipeGestureBinding
        let right: SwipeGestureBinding
    }

    private static let quickSetupPairs: [QuickSetupPair] = [
        .init(
            id: "none",
            title: String(localized: "None", comment: "Quick setup pair: disable both swipes"),
            icon: "nosign",
            left: .preset(.none),
            right: .preset(.none)
        ),
        .init(
            id: "appTabs",
            title: String(localized: "App Tabs", comment: "Quick setup pair: switch app tabs"),
            icon: "square.on.square",
            left: .preset(.nextTab),
            right: .preset(.previousTab)
        ),
        .init(
            id: "tmuxWindows",
            title: String(localized: "Tmux Windows", comment: "Quick setup pair: switch tmux windows"),
            icon: "rectangle.stack",
            left: .preset(.tmuxNextWindow),
            right: .preset(.tmuxPreviousWindow)
        ),
        .init(
            id: "tmuxSessions",
            title: String(localized: "Tmux Sessions", comment: "Quick setup pair: switch tmux sessions"),
            icon: "macwindow.on.rectangle",
            left: .preset(.tmuxNextSession),
            right: .preset(.tmuxPreviousSession)
        ),
        .init(
            id: "zellijTabs",
            title: String(localized: "Zellij Tabs", comment: "Quick setup pair: switch zellij tabs"),
            icon: "rectangle.split.3x1",
            left: .preset(.zellijNextTab),
            right: .preset(.zellijPreviousTab)
        ),
    ]

    var body: some View {
        List {
            if !manager.separateAreasEnabled {
                quickSetupSection
                directionsSection
            }
            #if targetEnvironment(macCatalyst)
            if manager.separateAreasEnabled {
                directionsSection
            }
            #endif
            Section {
                Toggle("Separate Top and Bottom Swipes", isOn: $manager.separateAreasEnabled)
                    .themedRow()
            } footer: {
                Text("Assign different actions to swipes starting in the top and bottom halves of the terminal. Turning this off restores the shared swipe actions. Trackpad swipes always use the shared actions.")
            }
            if manager.separateAreasEnabled {
                Section("Top Half") {
                    directionRow(.left, area: .top)
                    directionRow(.right, area: .top)
                }
                Section("Bottom Half") {
                    directionRow(.left, area: .bottom)
                    directionRow(.right, area: .bottom)
                }
            }
            captureModeNoteSection
            if manager.isCustomized {
                resetSection
            }
        }
        .themedList()
        .navigationTitle("Swipe Gestures")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if os(visionOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            #endif
            SettingsScreenPinMenu(groups: [.gestures])
        }
        .confirmationDialog("Reset to Defaults?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                manager.resetToDefaults()
            }
        } message: {
            Text("Restore left swipe to Next Tab and right swipe to Previous Tab for all areas, and turn off separate top and bottom swipes.")
        }
    }

    // MARK: - Sections

    private var quickSetupSection: some View {
        Section {
            #if !targetEnvironment(macCatalyst)
            if shouldShowScrollModeWarning {
                scrollModeWarningRow
            }
            #endif
            ForEach(Self.quickSetupPairs) { pair in
                quickSetupRow(pair)
            }
        } header: {
            Text("Quick Setup")
        } footer: {
            if !matchedAnyPair {
                Text("Custom configuration — use Customize Directions below.")
            }
        }
    }

    private func quickSetupRow(_ pair: QuickSetupPair) -> some View {
        Button {
            manager.setBindings(left: pair.left, right: pair.right)
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: pair.icon)
                Text(pair.title)
                    .foregroundStyle(.primary)
                Spacer()
                if matchesPair(pair) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .themedRow()
    }

    private func matchesPair(_ pair: QuickSetupPair) -> Bool {
        manager.leftBinding == pair.left && manager.rightBinding == pair.right
    }

    private var matchedAnyPair: Bool {
        Self.quickSetupPairs.contains { matchesPair($0) }
    }

    #if !targetEnvironment(macCatalyst)
    private var shouldShowScrollModeWarning: Bool {
        !scrollModeEnabled
            && manager.activeTouchBindings.contains { !$0.isDisabled }
    }

    private var scrollModeWarningRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Scroll Mode is off")
                        .foregroundStyle(.primary)
                    SettingPinTag(Settings.Gestures.scrollMode.erased)
                }
                Text("Single-finger horizontal swipes need Scroll Mode to fire.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $scrollModeEnabled)
                .labelsHidden()
        }
        .themedRow()
        .settingContextMenu(Settings.Gestures.scrollMode)
    }
    #endif

    private var directionsSection: some View {
        Section {
            directionRow(.left)
            directionRow(.right)
        } header: {
            HStack {
                Text("Customize Directions")
                Spacer()
                Button {
                    swapTrigger &+= 1
                    manager.swapBindings()
                } label: {
                    Label(
                        String(localized: "Swap", comment: "Button to swap left and right swipe bindings"),
                        systemImage: "arrow.left.arrow.right"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .disabled(manager.leftBinding == manager.rightBinding)
                .accessibilityLabel(Text("Swap left and right swipe bindings"))
                .sensoryFeedback(.success, trigger: swapTrigger)
            }
        }
    }

    private func directionRow(_ direction: SwipeDirection, area: TerminalSwipeArea? = nil) -> some View {
        NavigationLink {
            SwipeBindingPickerView(
                direction: direction,
                current: manager.binding(for: direction, area: area),
                onSelect: { binding in
                    manager.setBinding(binding, for: direction, area: area)
                }
            )
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: direction == .left ? "arrow.left" : "arrow.right")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(direction == .left ? "Left Swipe" : "Right Swipe")
                            .foregroundStyle(.primary)
                        SettingPinTag(Settings.Gestures.swipeBindings.erased)
                    }
                    Text(manager.binding(for: direction, area: area).displaySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .themedRow()
        .settingContextMenu(Settings.Gestures.swipeBindings)
    }

    private var captureModeNoteSection: some View {
        Section {
            EmptyView()
        } footer: {
            #if targetEnvironment(macCatalyst)
            Text("Two-finger trackpad horizontal swipes trigger these bindings. Tmux and Zellij presets work even when the multiplexer has mouse capture enabled.")
            #else
            Text("Swipes work even in mouse-capture mode — pair the Tmux/Zellij presets with mouse-on multiplexers to switch windows or tabs inside a single terminal.")
            #endif
        }
    }

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showingResetConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    Spacer()
                }
            }
            .themedRow()
        }
    }
}

// MARK: - Binding Picker

private struct SwipeBindingPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let direction: SwipeDirection
    let current: SwipeGestureBinding
    let onSelect: (SwipeGestureBinding) -> Void

    @State private var toolbarManager = KeyboardToolbarManager.shared

    private var directionTitle: String {
        direction == .left
            ? String(localized: "Left Swipe", comment: "Swipe gesture binding picker title for left swipe")
            : String(localized: "Right Swipe", comment: "Swipe gesture binding picker title for right swipe")
    }

    var body: some View {
        List {
            appPresetsSection
            tmuxPresetsSection
            zellijPresetsSection
            if !toolbarManager.customKeys.isEmpty {
                customKeysSection
            }
            customSequenceSection
        }
        .themedList()
        .navigationTitle(directionTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appPresetsSection: some View {
        Section {
            ForEach([SwipeGesturePreset.none, .nextTab, .previousTab]) { preset in
                presetRow(preset)
            }
        } header: {
            Text("App")
        }
    }

    private var tmuxPresetsSection: some View {
        Section {
            ForEach([
                SwipeGesturePreset.tmuxNextWindow,
                .tmuxPreviousWindow,
                .tmuxNextSession,
                .tmuxPreviousSession,
            ]) { preset in
                presetRow(preset)
            }
        } header: {
            Text("Tmux")
        }
    }

    private var zellijPresetsSection: some View {
        Section {
            ForEach([SwipeGesturePreset.zellijNextTab, .zellijPreviousTab]) { preset in
                presetRow(preset)
            }
        } header: {
            Text("Zellij")
        }
    }

    private func presetRow(_ preset: SwipeGesturePreset) -> some View {
        Button {
            onSelect(.preset(preset))
            dismiss()
        } label: {
            HStack {
                Image(systemName: iconName(for: preset))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(preset.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if case .preset(let p) = current, p == preset {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .themedRow()
    }

    private var customKeysSection: some View {
        Section {
            ForEach(toolbarManager.customKeys) { key in
                Button {
                    onSelect(.customKeyRef(key.id))
                    dismiss()
                } label: {
                    HStack {
                        if let iconName = key.iconName {
                            Image(systemName: iconName)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                        } else {
                            Image(systemName: "keyboard")
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.label)
                                .foregroundStyle(.primary)
                            Text(key.sequenceSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if case .customKeyRef(let id) = current, id == key.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .themedRow()
            }
        } header: {
            Text("Toolbar Custom Keys")
        } footer: {
            Text("Reuse a custom key you've already built for the keyboard toolbar.")
        }
    }

    private var customSequenceSection: some View {
        Section {
            NavigationLink {
                SwipeCustomSequenceEditor(
                    initialSteps: {
                        if case .sequence(let steps) = current { return steps }
                        return []
                    }(),
                    onSave: { steps in
                        // Editor pops itself after Save; the picker auto-updates
                        // and the user can tap back to leave.
                        onSelect(.sequence(steps))
                    }
                )
            } label: {
                HStack {
                    Image(systemName: "text.cursor")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    if case .sequence(let steps) = current, !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Custom Sequence")
                                .foregroundStyle(.primary)
                            Text(steps.map(\.displayText).joined(separator: " \u{2192} "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Custom Sequence\u{2026}")
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    if case .sequence = current {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
            }
            .themedRow()
        } header: {
            Text("Custom")
        } footer: {
            Text("Build a one-off sequence of key combos and text just for this swipe.")
        }
    }

    private func iconName(for preset: SwipeGesturePreset) -> String {
        switch preset {
        case .none: return "nosign"
        case .nextTab: return "arrow.right.square"
        case .previousTab: return "arrow.left.square"
        case .tmuxNextWindow, .zellijNextTab: return "rectangle.stack.badge.plus"
        case .tmuxPreviousWindow, .zellijPreviousTab: return "rectangle.stack.badge.minus"
        case .tmuxNextSession: return "macwindow.badge.plus"
        case .tmuxPreviousSession: return "macwindow"
        }
    }
}

// MARK: - Custom Sequence Editor

private struct SwipeCustomSequenceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    let onSave: ([SequenceStep]) -> Void

    @State private var sequence: [SequenceStep]
    @State private var activeSheet: ActiveSheet?

    enum ActiveSheet: Identifiable {
        case addKeyCombo
        case editKeyCombo(index: Int, combo: SequenceStep.KeyCombo)
        case addText
        case editText(index: Int, text: String)

        var id: String {
            switch self {
            case .addKeyCombo: return "addKeyCombo"
            case .editKeyCombo(let index, _): return "editKeyCombo-\(index)"
            case .addText: return "addText"
            case .editText(let index, _): return "editText-\(index)"
            }
        }
    }

    init(initialSteps: [SequenceStep], onSave: @escaping ([SequenceStep]) -> Void) {
        self.onSave = onSave
        _sequence = State(initialValue: initialSteps)
    }

    var body: some View {
        Form {
            sequenceSection
            addStepSection
            previewSection
        }
        .themedList()
        .navigationTitle("Custom Sequence")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(sequence)
                    dismiss()
                }
                .disabled(sequence.isEmpty)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .addKeyCombo:
                KeyComboPickerSheet(confirmLabel: "Add") { combo in
                    sequence.append(.keyCombo(combo))
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
            }
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
            if sequence.isEmpty {
                Text("Empty sequence")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .themedRow()
            } else {
                Text(sequence.map(\.displayText).joined(separator: " \u{2192} "))
                    .font(.system(.body, design: .monospaced))
                    .themedRow()
            }
        } header: {
            Text("Preview")
        }
    }

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
}
