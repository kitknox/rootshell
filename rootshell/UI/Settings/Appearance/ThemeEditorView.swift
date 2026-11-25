//
//  ThemeEditorView.swift
//  rootshell
//
//  Theme editor with color pickers and live terminal preview
//

import SwiftUI

struct ThemeEditorView: View {
    enum EditorMode: Identifiable {
        case new(UUID = UUID())
        case edit(CustomTheme)
        case duplicate(ThemeManager.ThemeInfo)

        var id: String {
            switch self {
            case .new(let uuid): return "new-\(uuid.uuidString)"
            case .edit(let theme): return "edit-\(theme.id)"
            case .duplicate(let info): return "dup-\(info.id)"
            }
        }
    }

    let mode: EditorMode
    let onSave: ((CustomTheme) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var theme: CustomTheme
    @State private var showingNameWarning = false
    @State private var nameWarningMessage = ""
    @State private var nameBlocksSave = false

    private let ansiNormalLabels = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"
    ]

    init(mode: EditorMode, onSave: ((CustomTheme) -> Void)? = nil) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .new:
            _theme = State(initialValue: CustomTheme.defaultTheme())
        case .edit(let existing):
            _theme = State(initialValue: existing)
        case .duplicate(let info):
            _theme = State(initialValue: CustomThemeManager.shared.duplicateBuiltInTheme(info))
        }
    }

    private var canSave: Bool {
        !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !nameBlocksSave
    }

    /// Pin the live terminal preview above the form whenever there is enough
    /// vertical room so edits to cursor, selection, and ANSI colors remain
    /// immediately visible; let it scroll in compact landscape heights.
    private var pinsLivePreview: Bool {
        verticalSizeClass != .compact
    }

    var body: some View {
        NavigationStack {
            PanelSideRailReader { inRail in
                VStack(spacing: 0) {
                    if pinsLivePreview {
                        ThemeEditorLivePreview(theme: theme)
                            .padding(.leading, 16)
                            .padding(.trailing, inRail ? 0 : 16)
                            .padding(.top, 8)
                            .padding(.bottom, 10)
                    }

                    Form {
                        if !pinsLivePreview {
                            Section {
                                ThemeEditorLivePreview(theme: theme)
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                            }
                        }

                        // Theme name
                        Section {
                            TextField("Theme Name", text: $theme.name)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .themedRow()
                        } header: {
                            Text("Name")
                        } footer: {
                            if showingNameWarning {
                                Text(nameWarningMessage)
                                    .foregroundColor(.orange)
                            }
                        }

                        // Core colors
                        Section("Colors") {
                            colorRow("Background", keyPath: \.background)
                            colorRow("Foreground", keyPath: \.foreground)
                        }

                        // Cursor colors
                        Section("Cursor") {
                            colorRow("Cursor Color", keyPath: \.cursorColor)
                            colorRow("Cursor Text", keyPath: \.cursorText)
                        }

                        // Selection colors
                        Section("Selection") {
                            colorRow("Selection Background", keyPath: \.selectionBackground)
                            colorRow("Selection Foreground", keyPath: \.selectionForeground)
                        }

                        // ANSI Normal (0-7)
                        Section("ANSI Normal") {
                            ForEach(0..<8, id: \.self) { index in
                                paletteRow(index: index, label: ansiNormalLabels[index])
                            }
                        }

                        // ANSI Bright (8-15)
                        Section("ANSI Bright") {
                            ForEach(8..<16, id: \.self) { index in
                                paletteRow(index: index, label: "Bright \(ansiNormalLabels[index - 8])")
                            }
                        }

                        // Extended palette indicator
                        if theme.hasExtendedPalette {
                            Section {
                                Label(
                                    String(localized: "This theme includes \(theme.extendedPalette.count) extended palette colors (indices 16-255) that will be preserved."),
                                    systemImage: "paintpalette"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .themedRow()
                            } header: {
                                Text("Extended Palette")
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .themedList()
                }
                .background((sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea())
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                validateName(theme.name)
            }
            .onChange(of: theme.name) { _, newName in
                validateName(newName)
            }
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .new: return String(localized: "New Theme")
        case .edit: return String(localized: "Edit Theme")
        case .duplicate: return String(localized: "Duplicate Theme")
        }
    }

    // MARK: - Color Rows

    private func colorRow(_ label: String, keyPath: WritableKeyPath<CustomTheme, String>) -> some View {
        let hex = resolvedHex(theme[keyPath: keyPath])
        return ColorPicker(selection: colorBinding(for: keyPath), supportsOpacity: false) {
            colorRowLabel(label, hex: hex)
        }
        .themedRow()
    }

    private func paletteRow(index: Int, label: String) -> some View {
        let hex = index < theme.palette.count ? theme.palette[index].uppercased() : ""
        return ColorPicker(selection: paletteBinding(index: index), supportsOpacity: false) {
            colorRowLabel(label, hex: hex)
        }
        .themedRow()
    }

    private func colorRowLabel(_ title: String, hex: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            if !hex.isEmpty {
                Text(hex)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resolvedHex(_ raw: String) -> String {
        // Resolve Ghostty keywords (e.g. "cell-foreground") before hex parsing,
        // because Scanner.scanHexInt64 accepts the leading "ce" as 0x0000CE.
        Color.resolveKeywordColor(raw, foreground: theme.foreground, background: theme.background).uppercased()
    }

    // MARK: - Color Bindings

    private func colorBinding(for keyPath: WritableKeyPath<CustomTheme, String>) -> Binding<Color> {
        Binding(
            get: {
                let resolved = resolvedHex(theme[keyPath: keyPath])
                return Color(hex: resolved) ?? .gray
            },
            set: { newColor in theme[keyPath: keyPath] = newColor.hexString }
        )
    }

    private func paletteBinding(index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard index < theme.palette.count else { return .gray }
                return Color(hex: theme.palette[index]) ?? .gray
            },
            set: { newColor in
                guard index < theme.palette.count else { return }
                theme.palette[index] = newColor.hexString
            }
        )
    }

    // MARK: - Validation & Save

    private func validateName(_ name: String) {
        let validation = CustomThemeManager.shared.validateName(
            name,
            excludingId: theme.id
        )
        switch validation {
        case .valid, .empty:
            showingNameWarning = false
            nameBlocksSave = false
        case .containsPathSeparator:
            showingNameWarning = true
            nameBlocksSave = true
            nameWarningMessage = String(localized: "Theme name cannot contain path separators.")
        case .conflictsWithCustom:
            showingNameWarning = true
            nameBlocksSave = true
            nameWarningMessage = String(localized: "A custom theme with this name already exists.")
        case .shadowsBuiltIn:
            showingNameWarning = true
            nameBlocksSave = false
            nameWarningMessage = String(localized: "This will override the built-in theme with the same name.")
        }
    }

    private func save() {
        let validation = CustomThemeManager.shared.validateName(
            theme.name,
            excludingId: theme.id
        )
        guard validation != .empty, validation != .containsPathSeparator, validation != .conflictsWithCustom else {
            return
        }
        CustomThemeManager.shared.saveTheme(theme)
        onSave?(theme)
        dismiss()
    }
}

/// Live terminal preview tailored for the theme editor: reflects background,
/// foreground, cursor, selection, and all 16 ANSI palette slots as they change.
private struct ThemeEditorLivePreview: View {
    let theme: CustomTheme

    private var backgroundColor: Color {
        Color(hex: theme.background) ?? .black
    }

    private var foregroundColor: Color {
        Color(hex: theme.foreground) ?? .white
    }

    private var cursorColor: Color {
        let resolved = Color.resolveKeywordColor(theme.cursorColor, foreground: theme.foreground, background: theme.background)
        return Color(hex: resolved) ?? foregroundColor
    }

    private var cursorTextColor: Color {
        let resolved = Color.resolveKeywordColor(theme.cursorText, foreground: theme.foreground, background: theme.background)
        return Color(hex: resolved) ?? backgroundColor
    }

    private var selectionBackground: Color {
        let resolved = Color.resolveKeywordColor(theme.selectionBackground, foreground: theme.foreground, background: theme.background)
        return Color(hex: resolved) ?? foregroundColor.opacity(0.25)
    }

    private var selectionForeground: Color {
        let resolved = Color.resolveKeywordColor(theme.selectionForeground, foreground: theme.foreground, background: theme.background)
        return Color(hex: resolved) ?? foregroundColor
    }

    private func paletteColor(_ index: Int) -> Color {
        guard index < theme.palette.count else { return foregroundColor }
        return Color(hex: theme.palette[index]) ?? foregroundColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("user@host").foregroundStyle(paletteColor(4))
                    Text(":").foregroundStyle(foregroundColor)
                    Text("~").foregroundStyle(paletteColor(5))
                    Text("$ git statu").foregroundStyle(foregroundColor)
                    Text("s")
                        .foregroundStyle(cursorTextColor)
                        .background(cursorColor)
                }

                HStack(spacing: 0) {
                    Text("M ").foregroundStyle(paletteColor(1))
                    Text("Theme.swift").foregroundStyle(paletteColor(2))
                    Text("  ")
                    Text("selected")
                        .foregroundStyle(selectionForeground)
                        .padding(.horizontal, 3)
                        .background(selectionBackground, in: RoundedRectangle(cornerRadius: 2))
                }

                HStack(spacing: 0) {
                    Text("ok ").foregroundStyle(paletteColor(6))
                    Text("warn ").foregroundStyle(paletteColor(3))
                    Text("16 ANSI colors").foregroundStyle(foregroundColor.opacity(0.8))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)

            // 16-color ANSI swatch strip (0-7 normal, 8-15 bright)
            HStack(spacing: 2) {
                ForEach(0..<min(16, theme.palette.count), id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(paletteColor(index))
                        .frame(height: 6)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live theme preview"))
    }
}
