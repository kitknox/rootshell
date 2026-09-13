//
//  KeyboardShortcutsSettingsView.swift
//  rootshell
//
//  Settings view for browsing and customizing keyboard shortcuts
//

import SwiftUI
import UniformTypeIdentifiers

struct KeyboardShortcutsSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject private var keybindManager = KeybindManager.shared
    @State private var selectedCategory: KeybindCategory = .tabs
    @State private var editingAction: KeybindAction?
    /// Outcome captured from the editor sheet but not yet applied. Stored
    /// while the sheet is still dismissing; applied in the sheet's onDismiss
    /// so KeybindManager's @Published cascade runs after the sheet has fully
    /// torn down rather than racing with it. Covers all three editor paths —
    /// capture, restore-default, unbind — so every mutation is deferred
    /// uniformly.
    @State private var pendingOutcome: (action: KeybindAction, outcome: KeybindEditorOutcome)?
    @State private var showConfigFilePicker = false
    @State private var showConfigEditor = false
    @State private var showResetConfirmation = false
    @State private var isReloadingConfig = false
    @State private var lastConfigReloadDate: Date?
    @State private var configFileErrorMessage: String?

    var body: some View {
        List {
            // External config section
            Section {
                externalConfigSection
            } header: {
                Text("Config File")
            } footer: {
                Text("Optionally load keybinds from an external ghostty config file. The imported file lives at \(keybindManager.externalConfigShellPath), can be edited in place, and your in-app customizations still take priority.")
            }

            // Category picker
            Section {
                Picker("Category", selection: $selectedCategory) {
                    ForEach(KeybindCategory.allCases.sorted { $0.displayOrder < $1.displayOrder }, id: \.self) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .themedRow()
            }

            // Keybindings for selected category
            Section(selectedCategory.displayName) {
                let categoryActions = KeybindAction.customizableActions
                    .filter { $0.category == selectedCategory }
                    .sorted { $0.displayName < $1.displayName }

                ForEach(categoryActions) { action in
                    let binding = keybindManager.keybind(for: action)
                    let isUnbound = keybindManager.isActionUnbound(action)
                    KeybindRow(action: action, binding: binding, isUnbound: isUnbound) {
                        editingAction = action
                    }
                    .themedRow()
                }
            }

            // Reset section
            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset All to Defaults")
                    }
                }
                .disabled(keybindManager.userOverrides.isEmpty)
                .themedRow()
            } footer: {
                if !keybindManager.userOverrides.isEmpty {
                    Text("You have \(keybindManager.userOverrides.count) custom shortcut(s)")
                }
            }
        }
        .themedList()
        .navigationTitle("Keyboard Shortcuts")
        .toolbar { SettingsScreenPinMenu(groups: [.keybinds]) }
        .sheet(
            item: $editingAction,
            onDismiss: applyPendingOutcome
        ) { action in
            KeybindEditorView(
                action: action,
                onOutcome: { editedAction, outcome in
                    pendingOutcome = (editedAction, outcome)
                },
                onSwitchAction: { conflict in
                    // Stay in the same sheet; just keep the list behind it in sync.
                    selectedCategory = conflict.category
                }
            )
            .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showConfigEditor) {
            KeybindConfigEditorView(keybindManager: keybindManager)
                .themedSubSheet(sheetThemeColors)
        }
        .fileImporter(
            isPresented: $showConfigFilePicker,
            allowedContentTypes: [.plainText, UTType(filenameExtension: "conf") ?? .text],
            onCompletion: handleConfigFileSelection
        )
        .alert("Config File Error", isPresented: Binding(
            get: { configFileErrorMessage != nil },
            set: { if !$0 { configFileErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { configFileErrorMessage = nil }
        } message: {
            Text(configFileErrorMessage ?? "")
        }
        .alert("Reset All Shortcuts?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                keybindManager.resetAllOverrides()
            }
        } message: {
            Text("This will remove all your custom keyboard shortcuts and restore the defaults.")
        }
    }

    // MARK: - External Config Section

    @ViewBuilder
    private var externalConfigSection: some View {
        if let path = keybindManager.externalConfigPath {
            VStack(alignment: .leading, spacing: 4) {
                Text(keybindManager.externalConfigOriginalFileName ?? path.lastPathComponent)
                    .font(.body)
                Text(keybindManager.externalConfigShellPath)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let symlinkDestination = keybindManager.externalConfigSymlinkDestination {
                    Text("Symlink target: \(symlinkDestination)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            HStack {
                Image(systemName: keybindManager.externalConfigBindings.isEmpty ? "doc.text" : "checkmark.circle.fill")
                    .foregroundColor(keybindManager.externalConfigBindings.isEmpty ? .secondary : .green)
                Text("\(keybindManager.externalConfigBindings.count) keybinds loaded")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .themedRow()

            if let lastConfigReloadDate {
                HStack {
                    Text("Last Reloaded")
                    Spacer()
                    Text(lastConfigReloadDate, style: .relative)
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
                .themedRow()
            }

            Button {
                showConfigEditor = true
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("Edit Imported Config")
                }
            }
            .themedRow()

            Button {
                Task {
                    await reloadExternalConfigWithFeedback()
                }
            } label: {
                HStack {
                    if isReloadingConfig {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reloading Imported Config...")
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text("Reload Imported Config")
                    }
                }
            }
            .disabled(isReloadingConfig)
            .themedRow()

            Button(role: .destructive) {
                keybindManager.externalConfigPath = nil
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Remove Imported Config")
                }
            }
            .themedRow()

            Text("Shell edits are picked up with the Reload button here or by running reloadconfig in a local shell.")
                .font(.caption)
                .foregroundColor(.secondary)
                .themedRow()
        } else {
            Button {
                showConfigFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "doc.badge.plus")
                    Text("Select Ghostty Config File...")
                }
            }
            .themedRow()
        }
    }

    // MARK: - Deferred Editor-Outcome Application

    private func applyPendingOutcome() {
        guard let pending = pendingOutcome else { return }
        pendingOutcome = nil
        switch pending.outcome {
        case .captured(let sequence):
            keybindManager.setOverride(sequence: sequence, action: pending.action)
        case .restoreDefault:
            keybindManager.removeOverride(for: pending.action)
        case .unbind:
            keybindManager.unbindAction(pending.action)
        }
    }

    // MARK: - File Picker Handler

    private func handleConfigFileSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            keybindManager.importExternalConfig(from: url)

        case .failure(let error):
            configFileErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reloadExternalConfigWithFeedback() async {
        guard !isReloadingConfig else { return }

        isReloadingConfig = true
        await Task.yield()
        keybindManager.reloadExternalConfig()
        lastConfigReloadDate = Date()

        // Keep the loading state visible briefly so taps feel acknowledged.
        try? await Task.sleep(for: .milliseconds(350))
        isReloadingConfig = false
    }
}

private struct KeybindConfigEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject var keybindManager: KeybindManager
    @State private var text = ""
    @State private var didLoadContents = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(keybindManager.externalConfigShellPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(8)
                    .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding()
            .background((sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea())
            .navigationTitle("Edit Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!didLoadContents)
                }
            }
            .task {
                do {
                    text = try keybindManager.externalConfigContents()
                    didLoadContents = true
                } catch {
                    didLoadContents = false
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Config File Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try keybindManager.saveExternalConfigContents(text)
            keybindManager.reloadExternalConfig()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Keybind Row

struct KeybindRow: View {
    let action: KeybindAction
    let binding: Keybind?
    let isUnbound: Bool
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.displayName)
                        .foregroundColor(.primary)

                    if let binding {
                        if binding.isUserOverride {
                            Text("Custom")
                                .font(.caption2)
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                        } else if binding.source == .externalConfig {
                            Text("Config File")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.1))
                                .cornerRadius(4)
                        }
                    } else if isUnbound {
                        Text("Unbound")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(4)
                    } else {
                        Text("Displaced")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                    }
                }

                Spacer()

                if let binding {
                    Text(binding.sequence.symbolDescription)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("No Shortcut")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .italic()
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    NavigationView {
        KeyboardShortcutsSettingsView()
    }
}
