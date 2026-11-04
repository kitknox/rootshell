//
//  FontSettingsView.swift
//  rootshell
//
//  Font selection and import settings.
//

import SwiftUI
import UniformTypeIdentifiers

struct FontSettingsView: View {
    @ObservedObject private var fontManager = FontManager.shared
    @State private var showingFileImporter = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var showingFontPicker = false
    @State private var notMonospaceFamily: String?
    @State private var showingNotMonospace = false
    @State private var sampleFonts = SampleFontCache()

    var body: some View {
        List {
            // MARK: - Bundled Fonts
            Section("Bundled Fonts") {
                // Ghostty Default option
                Button(action: {
                    fontManager.currentFontFamily = nil
                }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ghostty Default")
                                .foregroundColor(.primary)
                            Text("The quick brown fox 0123456789")
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if fontManager.currentFontFamily == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()

                if !fontManager.isCatalogLoaded && fontManager.availableFamilies.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading fonts…")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                // Bundled fonts
                ForEach(fontManager.availableFamilies) { family in
                    Button(action: {
                        fontManager.currentFontFamily = family.configName
                    }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(family.displayName)
                                    .foregroundColor(.primary)
                                // Inline sample text preview
                                if let sampleFont = sampleFonts.font(for: family, revision: fontManager.catalogRevision) {
                                    Text("The quick brown fox 0123456789")
                                        .font(Font(fontManager.applyEnabledFeatures(to: sampleFont, for: family.configName)))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("The quick brown fox 0123456789")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if fontManager.currentFontFamily == family.configName {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            }

            // MARK: - System Fonts
            if !fontManager.systemFontFamilies.isEmpty {
                Section {
                    ForEach(fontManager.systemFontFamilies) { family in
                        Button(action: {
                            fontManager.currentFontFamily = family.configName
                        }) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(family.displayName)
                                        .foregroundColor(.primary)
                                    if let sampleFont = sampleFonts.font(for: family, revision: fontManager.catalogRevision) {
                                        Text("The quick brown fox 0123456789")
                                            .font(Font(fontManager.applyEnabledFeatures(to: sampleFont, for: family.configName)))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text("The quick brown fox 0123456789")
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                if fontManager.currentFontFamily == family.configName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .themedRow()
                    }

                    #if !targetEnvironment(macCatalyst)
                    Button {
                        showingFontPicker = true
                    } label: {
                        Label("Choose Installed Font...", systemImage: "textformat")
                    }
                    .themedRow()
                    #endif
                } header: {
                    Text("System Fonts")
                } footer: {
                    #if targetEnvironment(macCatalyst)
                    Text("Monospace fonts installed on your device via apps like Font Case.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #else
                    Text("Monospace fonts installed on your device. A font from an app like Font Case appears here once you choose it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #endif
                }
            }

            // MARK: - Custom Fonts
            Section {
                ForEach(fontManager.customFontFamilies) { family in
                    Button(action: {
                        fontManager.currentFontFamily = family.configName
                    }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(family.displayName)
                                    .foregroundColor(.primary)
                                if let sampleFont = fontManager.sampleFontForCustomFamily(family) {
                                    Text("The quick brown fox 0123456789")
                                        .font(Font(fontManager.applyEnabledFeatures(to: sampleFont, for: family.configName)))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("The quick brown fox 0123456789")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                let styleCount = family.fontFiles.count
                                Text("\(styleCount) style\(styleCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if fontManager.currentFontFamily == family.configName {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let family = fontManager.customFontFamilies[index]
                        fontManager.deleteCustomFontFamily(id: family.id)
                    }
                }

                Button {
                    showingFileImporter = true
                } label: {
                    Label("Import Font...", systemImage: "plus.circle")
                }
                .themedRow()
            } header: {
                Text("Custom Fonts")
            } footer: {
                if fontManager.customFontFamilies.isEmpty {
                    #if targetEnvironment(macCatalyst)
                    Text("Import your own TTF or OTF font files. Select multiple files at once to import all weights of a font family. If your font came as a ZIP file, extract it first using Finder.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #else
                    Text("Import your own TTF or OTF font files. Select multiple files at once to import all weights of a font family. If your font came as a ZIP file, extract it first using the Files app.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    #endif
                }
            }

            Section("Font Size") {
                HStack {
                    Text("\(Int(fontManager.currentFontSize))")
                        .frame(width: 40)
                        .monospacedDigit()
                        .settingRow(Settings.Font.size)
                    Slider(value: $fontManager.currentFontSize, in: 4...24, step: 1)
                }
                .themedRow()
            }

            cellSpacingSection

            Section {
                SettingToggle(Settings.Font.ligatures, isOn: $fontManager.ligaturesEnabled, title: "Enable Ligatures")
                    .padding(.vertical, 4)
                    .themedRow()

                NavigationLink {
                    FontFeatureSettingsView()
                } label: {
                    HStack {
                        Text("Stylistic Sets")
                        SettingPinTag(Settings.Font.featurePrefs.erased)
                        Spacer()
                        let count = fontManager.enabledFeatureTags(for: fontManager.currentFontFamily).count
                        if count > 0 {
                            Text("\(count) enabled")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Font.featurePrefs)
            } header: {
                Text("Font Features")
            } footer: {
                Text("Ligatures combine multiple characters into single glyphs (e.g., != becomes ≠). Stylistic sets control alternate letterforms like slashed zero and alternate characters.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Footer with font count
            Section {
                let bundledCount = fontManager.availableFamilies.count
                let systemCount = fontManager.systemFontFamilies.count
                let customCount = fontManager.customFontFamilies.count
                let parts = [
                    "\(bundledCount) bundled",
                    systemCount > 0 ? "\(systemCount) system" : nil,
                    customCount > 0 ? "\(customCount) custom" : nil
                ].compactMap { $0 }
                Text("\(parts.joined(separator: " + ")) font families")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.font]) }
        .task {
            await fontManager.ensureFontsLoaded()
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.font, UTType(filenameExtension: "ttf")!, UTType(filenameExtension: "otf")!],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                do {
                    let imported = try fontManager.importFonts(from: urls)
                    // Auto-select the first imported family
                    if let first = imported.first {
                        fontManager.currentFontFamily = first.configName
                    }
                } catch {
                    importError = error.localizedDescription
                    showingImportError = true
                }
            case .failure(let error):
                importError = error.localizedDescription
                showingImportError = true
            }
        }
        .sheet(isPresented: $showingFontPicker) {
            InstalledFontPicker { descriptor in
                showingFontPicker = false
                guard let descriptor else { return }
                Task {
                    if case .notMonospace(let family) = await fontManager.selectInstalledFont(descriptor) {
                        notMonospaceFamily = family
                        showingNotMonospace = true
                    }
                }
            }
        }
        .alert("Not a Monospace Font", isPresented: $showingNotMonospace) {
            Button("OK") {}
        } message: {
            Text("\(notMonospaceFamily ?? "") has characters of different widths, so it can't be used in the terminal.")
        }
        .alert("Import Failed", isPresented: $showingImportError) {
            Button("OK") {}
        } message: {
            Text(importError ?? String(localized: "An unknown error occurred", comment: "Generic error fallback message"))
        }
    }

    // MARK: - Cell Spacing

    @ViewBuilder
    private var cellSpacingSection: some View {
        let family = fontManager.currentFontFamily
        let displayName = fontManager.currentFontFamilyDisplayName
        let current = fontManager.cellAdjustments(for: family)

        let widthBinding = Binding<Double>(
            get: { Double(fontManager.cellAdjustments(for: family).widthPercent) },
            set: { fontManager.setCellWidth(Int($0.rounded()), for: family) }
        )
        let heightBinding = Binding<Double>(
            get: { Double(fontManager.cellAdjustments(for: family).heightPercent) },
            set: { fontManager.setCellHeight(Int($0.rounded()), for: family) }
        )

        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Width")
                        .settingRow(Settings.Font.cellAdjustmentPrefs)
                    Spacer()
                    Text(current.widthPercent, format: .percent)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(value: widthBinding, in: -25...25, step: 1)
            }
            .padding(.vertical, 4)
            .themedRow()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Height")
                        .settingRow(Settings.Font.cellAdjustmentPrefs)
                    Spacer()
                    Text(current.heightPercent, format: .percent)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                Slider(value: heightBinding, in: -25...25, step: 1)
            }
            .padding(.vertical, 4)
            .themedRow()

            if !current.isZero {
                Button("Reset to \(0.formatted(.percent))") {
                    fontManager.setCellAdjustments(.zero, for: family)
                }
                .themedRow()
            }
        } header: {
            Text("Cell Spacing — \(displayName)")
        } footer: {
            Text("Adjusts the cell box around each glyph for the selected font. Negative values tighten spacing; positive values loosen it. Settings are saved per font.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// The system font picker, which lists fonts other apps installed before this
/// app has access. Unfiltered: some monospace fonts (GNU Unifont) lack the trait.
private struct InstalledFontPicker: UIViewControllerRepresentable {
    /// Called with the picked font, or nil on cancel.
    let onFinish: (UIFontDescriptor?) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let picker = UIFontPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        var onFinish: (UIFontDescriptor?) -> Void

        init(onFinish: @escaping (UIFontDescriptor?) -> Void) {
            self.onFinish = onFinish
        }

        func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
            onFinish(picker.selectedFontDescriptor)
        }

        func fontPickerViewControllerDidCancel(_ picker: UIFontPickerViewController) {
            onFinish(nil)
        }
    }
}

/// Preview fonts built on first display and released with the settings screen.
/// A reference type so filling it during body evaluation doesn't invalidate the view.
private final class SampleFontCache {
    private var fonts: [String: UIFont?] = [:]
    private var revision = 0

    func font(for family: FontManager.FontFamilyInfo, revision catalogRevision: Int) -> UIFont? {
        if revision != catalogRevision {
            fonts.removeAll()
            revision = catalogRevision
        }
        if let cached = fonts[family.id] { return cached }
        let font = family.makeSampleFont()
        fonts[family.id] = font
        return font
    }
}

// MARK: - Cursor Settings

