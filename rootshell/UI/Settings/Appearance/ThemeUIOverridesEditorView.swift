//
//  ThemeUIOverridesEditorView.swift
//  rootshell
//
//  Per-theme editor for overriding the algorithmically derived UI chrome
//  colors (sheets, list rows, accent, tab bar). Each picker starts at the
//  derived default; tapping a per-row reset removes just that override, and
//  "Reset All to Defaults" clears every override for this theme.
//

import SwiftUI

struct ThemeUIOverridesEditorView: View {
    let theme: ThemeManager.ThemeInfo

    @Environment(\.dismiss) private var dismiss
    private var manager = ThemeUIOverridesManager.shared

    init(theme: ThemeManager.ThemeInfo) {
        self.theme = theme
    }

    private var derived: DerivedThemeUIColors? {
        ThemeUIColorDerivation.derive(from: theme.colors, effective: false)
    }

    var body: some View {
        NavigationStack {
            Form {
                introSection

                if let derived {
                    Section("Sheets & Lists") {
                        overrideRow(.sheetBackground, derived: derived)
                        overrideRow(.sheetRowBackground, derived: derived)
                        overrideRow(.sheetAccent, derived: derived)
                    }

                    Section("Tab Bar") {
                        overrideRow(.tabBarBackground, derived: derived)
                        overrideRow(.selectedTabBackground, derived: derived)
                        overrideRow(.unselectedTabBackground, derived: derived)
                        overrideRow(.tabText, derived: derived)
                        overrideRow(.tabSecondaryText, derived: derived)
                    }

                    if manager.hasOverrides(for: theme.name) {
                        Section {
                            Button(role: .destructive) {
                                manager.clear(for: theme.name)
                            } label: {
                                Label("Reset All to Defaults", systemImage: "arrow.uturn.backward")
                            }
                            .themedRow()
                        }
                    }
                } else {
                    Section {
                        Label(
                            "Couldn't read this theme's colors. Overrides aren't available.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                        .themedRow()
                    }
                }
            }
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .themedList()
            .navigationTitle(theme.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var introSection: some View {
        Section {
            Text("Override the derived chrome colors for this theme. These pickers start at the values the app would compute automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .themedRow()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func overrideRow(_ field: ThemeUIOverrideField, derived: DerivedThemeUIColors) -> some View {
        let overrideHex = manager.overrides(for: theme.name)[field]
        let hasOverride = overrideHex != nil
        let displayHex = (overrideHex ?? derived.color(for: field)?.hexString ?? "").uppercased()
        HStack(spacing: 8) {
            ColorPicker(
                selection: binding(for: field, derived: derived),
                supportsOpacity: false
            ) {
                HStack(spacing: 8) {
                    Text(field.displayName)
                    Spacer(minLength: 8)
                    if !displayHex.isEmpty {
                        Text(displayHex)
                            .font(.caption.monospaced())
                            .foregroundStyle(hasOverride ? Color.accentColor : Color.secondary)
                    }
                }
            }
            if hasOverride {
                Button {
                    manager.clearField(field, for: theme.name)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                        .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset \(field.displayName) to default")
            }
        }
        .themedRow()
    }

    // MARK: - Bindings

    private func binding(for field: ThemeUIOverrideField, derived: DerivedThemeUIColors) -> Binding<Color> {
        Binding(
            get: {
                if let hex = manager.overrides(for: theme.name)[field], let color = Color(hex: hex) {
                    return color
                }
                return derived.color(for: field) ?? .gray
            },
            set: { newColor in
                manager.setField(field, hex: newColor.hexString, for: theme.name)
            }
        )
    }
}
