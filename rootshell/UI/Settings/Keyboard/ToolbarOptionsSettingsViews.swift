//
//  ToolbarOptionsSettingsViews.swift
//  rootshell
//
//  The two option screens under Toolbar Keys: how a toolbar looks, and how its
//  rows are arranged. Each keeps a preview on screen while its options change.
//

import SwiftUI

// MARK: - Appearance

/// Style, keycaps, key colors and key size. These apply to every toolbar, not
/// only the one whose screen opened this; key size is set per display.
struct ToolbarAppearanceSettingsView: View {
    let context: ToolbarContext

    @State private var manager = KeyboardToolbarManager.shared
    @State private var previewMetrics = ToolbarLayoutPreviewMetrics()
    @State private var chosenSurface: ToolbarPreviewSurface?
    @Setting(Settings.Keyboard.touchEnabled) private var terminalKeyboard
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingBar

    private var surfaces: [ToolbarPreviewSurface] {
        ToolbarPreviewSurface.available(for: context, terminalKeyboard: terminalKeyboard, floatingBar: floatingBar)
    }
    /// Style and keycaps only show above the system keyboard.
    private var showsSystemKeyboardOptions: Bool { surfaces.contains(.systemKeyboard) }
    /// Opens on the system keyboard, where style and keycaps show; key colors show on every surface.
    private var previewSurface: ToolbarPreviewSurface {
        chosenSurface.flatMap { surfaces.contains($0) ? $0 : nil }
            ?? (showsSystemKeyboardOptions ? .systemKeyboard : surfaces[0])
    }

    var body: some View {
        List {
            Section {
                ToolbarPreviewSurfacePicker(surfaces: surfaces, selection: Binding(
                    get: { previewSurface },
                    set: { chosenSurface = $0 }
                ))
                ToolbarLayoutPreview(toolbar: context, surface: previewSurface, metrics: $previewMetrics)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .themedRow()
            } header: {
                Text("Preview")
            }

            ToolbarKeyColorsSection(manager: manager)

            if showsSystemKeyboardOptions {
                Section {
                    Picker("Style", selection: Binding(
                        get: { manager.toolbarStyle },
                        set: { manager.toolbarStyle = $0 }
                    )) {
                        ForEach(KeyboardToolbarStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .themedRow()
                    .settingContextMenu(Settings.KeyboardToolbar.style)

                    SettingToggle(
                        Settings.KeyboardToolbar.keycaps,
                        isOn: Binding(
                            get: { manager.showsKeycaps },
                            set: { manager.showsKeycaps = $0 }
                        ),
                        title: "Keycaps"
                    )
                    .themedRow()
                } header: {
                    Text("System Keyboard Toolbar")
                } footer: {
                    Text("Glass draws each section as a glass capsule in the system keyboard's color. Keycaps draws each key as a cap like the keyboard's own. The terminal keyboard and the remote screen toolbar have their own look.")
                }
            }

            #if !os(visionOS)
            if DuoHingeEvents.hasHinge {
                ToolbarKeySizeSection(title: "Key Size on the Inner Display",
                                      size: Settings.KeyboardToolbar.sizeDuoInner,
                                      width: Settings.KeyboardToolbar.minKeyWidthDuoInner)
                ToolbarKeySizeSection(title: "Key Size on the Front Display", showsFooter: true,
                                      size: Settings.KeyboardToolbar.sizeDuoFront,
                                      width: Settings.KeyboardToolbar.minKeyWidthDuoFront)
            } else {
                ToolbarKeySizeSection(title: "Key Size", showsFooter: true,
                                      size: KeyboardToolbarSize.currentKey,
                                      width: KeyboardToolbarSize.currentMinimumKeyWidthKey)
            }
            #endif
        }
        .themedList()
        .navigationTitle("Appearance and Size")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// How every toolbar colors its keys' symbols and labels.
private struct ToolbarKeyColorsSection: View {
    let manager: KeyboardToolbarManager

    var body: some View {
        Section {
            Picker("Key Colors", selection: Binding(
                get: { manager.glyphColoring },
                set: { manager.glyphColoring = $0 }
            )) {
                ForEach(KeyboardToolbarGlyphColoring.allCases, id: \.self) { coloring in
                    Text(coloring.displayName).tag(coloring)
                }
            }
            .themedRow()
            .settingContextMenu(Settings.KeyboardToolbar.glyphColoring)

            switch manager.glyphColoring {
            case .standard:
                EmptyView()
            case .single:
                ToolbarKeyColorRow(manager: manager, title: String(localized: "Color"),
                                   key: Settings.KeyboardToolbar.glyphColor)
            case .byKind:
                ForEach(ToolbarGlyphKind.allCases, id: \.self) { kind in
                    ToolbarKeyColorRow(manager: manager, title: kind.displayName, key: kind.colorKey)
                }
                let kindKeys = ToolbarGlyphKind.allCases.map(\.colorKey)
                if kindKeys.contains(where: manager.isGlyphColorChanged) {
                    Button("Reset Key Type Colors") {
                        manager.resetGlyphColors(kindKeys)
                    }
                    .themedRow()
                }
            }

            if manager.hasOwnGlyphColors {
                Button("Remove Individual Key Colors", role: .destructive) {
                    manager.clearOwnGlyphColors()
                }
                .themedRow()
            }
        } header: {
            Text("Key Colors")
        } footer: {
            Text("Colors the symbols and labels on toolbar keys above the system keyboard, in the terminal keyboard's toolbar row, and in the Screen Sharing and KVM toolbar. To give one key its own color, touch and hold it in the Toolbar Keys list and choose Key Color; its color wins over these. On the terminal keyboard, a selected modifier keeps its style's colors.")
        }
    }
}

private struct ToolbarKeyColorRow: View {
    let manager: KeyboardToolbarManager
    let title: String
    let key: SettingKey<String>
    @Setting private var hex: String

    init(manager: KeyboardToolbarManager, title: String, key: SettingKey<String>) {
        self.manager = manager
        self.title = title
        self.key = key
        _hex = Setting(key)
    }

    var body: some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { Color(hex: hex) ?? .accentColor },
                set: { manager.setGlyphColor(UIColor($0), for: key) }
            ), supportsOpacity: false)
            if manager.isGlyphColorChanged(key) {
                // Borderless, so only the button takes the tap, not the whole row.
                Button {
                    manager.resetGlyphColors([key])
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset \(title) to Default")
            }
        }
        .themedRow()
        .settingContextMenu(key)
    }
}

/// One display's key size: how tall the keys are, and how narrow they may get.
private struct ToolbarKeySizeSection: View {
    private let title: LocalizedStringKey
    private let showsFooter: Bool
    private let sizeKey: SettingKey<KeyboardToolbarSize>
    private let widthKey: SettingKey<Double>
    @Setting private var size: KeyboardToolbarSize
    @Setting private var minimumWidth: Double

    init(title: LocalizedStringKey, showsFooter: Bool = false,
         size: SettingKey<KeyboardToolbarSize>, width: SettingKey<Double>) {
        self.title = title
        self.showsFooter = showsFooter
        sizeKey = size
        widthKey = width
        _size = Setting(size)
        _minimumWidth = Setting(width)
    }

    var body: some View {
        Section {
            Picker("Height", selection: $size) {
                ForEach(KeyboardToolbarSize.allCases, id: \.self) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .themedRow()
            .settingContextMenu(sizeKey)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum Width")
                    Spacer()
                    Text(minimumWidth > 0 ? String(localized: "\(Int(minimumWidth)) pt") : String(localized: "Automatic"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // The low end of the slider is Automatic.
                Slider(value: Binding(
                    get: { max(minimumWidth, KeyboardToolbarSize.minimumKeyWidthRange.lowerBound) },
                    set: { KeyboardToolbarManager.shared.setMinimumKeyWidth($0, for: widthKey) }
                ), in: KeyboardToolbarSize.minimumKeyWidthRange, step: 4)
                .accessibilityLabel("Minimum Width")
            }
            .themedRow()
            .settingContextMenu(widthKey)
        } header: {
            Text(title)
        } footer: {
            if showsFooter {
                Text("Height also scales the keys' symbols. Automatic keeps the system keyboard's toolbar at its usual height and sizes the terminal keyboard's toolbar with the keyboard. Keys share the main row's width and narrow as you add more; a minimum width keeps them from narrowing past it, so the row scrolls or moves keys to the drawer sooner.")
            }
        }
    }
}

// MARK: - Layout

/// The pinned sections, scrolling, and the drawer rows of one toolbar.
struct ToolbarArrangementSettingsView: View {
    let context: ToolbarContext

    @State private var manager = KeyboardToolbarManager.shared
    @State private var previewMetrics = ToolbarLayoutPreviewMetrics()

    private var layout: ToolbarLayoutConfig { manager.layout(for: context) }
    /// The layout edits land in: this toolbar's own, or the terminal's while it is shared.
    private var editedContext: ToolbarContext { manager.hasOwnLayout(context) ? context : .terminal }
    private var drawerRowCount: Int { manager.drawerRowCount(in: editedContext) }

    var body: some View {
        List {
            Section {
                ToolbarLayoutPreview(toolbar: context, showsDrawers: true, metrics: $previewMetrics)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .themedRow()
            } header: {
                Text("Preview")
            }
            sectionsSection
            drawerSection
        }
        .themedList()
        .navigationTitle("Layout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sectionsSection: some View {
        Section {
            Toggle("Pinned Left Keys", isOn: pinnedGroupBinding(.leading))
                .themedRow()
            Toggle("Pinned Right Keys", isOn: pinnedGroupBinding(.trailing))
                .themedRow()
            Toggle("Scroll Main Row", isOn: Binding(
                get: { layout.mainRowScrolls },
                set: { manager.setMainRowScrolls($0, in: editedContext) }
            ))
            .themedRow()
            if layout.mainRowScrolls {
                Toggle("Swipe Across Scrolling Modifiers", isOn: Binding(
                    get: { layout.scrollingModifierSwipes },
                    set: { manager.setScrollingModifierSwipes($0, in: editedContext) }
                ))
                .themedRow()
            }
        } header: {
            Text("Main Row")
        } footer: {
            Text(sectionsFooter)
        }
    }

    private var sectionsFooter: String {
        guard layout.mainRowScrolls else { return fixedRowFooter }
        let scrolling = String(localized: "A pinned section stands apart at its end of the main row and stays put. When the row is full, the keys between scroll sideways, and the ••• key stays at the right end. Add keys to a pinned section in the key list.")
        let swipes = layout.scrollingModifierSwipes
            ? String(localized: "A drag from a scrolling modifier onto the modifier beside it selects both and does not scroll, so start a scroll on another key or drag away from the group.")
            : String(localized: "Any drag on the scrolling keys scrolls, so swiping across modifiers to select several works only in a pinned section.")
        return scrolling + " " + swipes
    }

    private var fixedRowFooter: String {
        String(localized: "A pinned section stands apart at its end of the main row and keeps its keys there when the row is full; the keys between move to the drawer first. Add keys to a pinned section in the key list.")
    }

    private func pinnedGroupBinding(_ group: KeyboardToolbarManager.PinnedGroup) -> Binding<Bool> {
        Binding(
            get: { manager.isPinnedGroupOn(group, in: editedContext) },
            set: { manager.setPinnedGroup(group, on: $0, in: editedContext) }
        )
    }

    private var drawerSection: some View {
        Section {
            Stepper(value: Binding(
                get: { drawerRowCount },
                set: { manager.setDrawerRowCount($0, in: editedContext) }
            ), in: 1...KeyboardToolbarManager.maxDrawerRows) {
                HStack {
                    Text("Drawer Rows")
                    Spacer()
                    Text("\(drawerRowCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()

            Toggle("Same Key Width as Main Row", isOn: Binding(
                get: { layout.drawerMatchesMainRow },
                set: { manager.setDrawerMatchesMainRow($0, in: editedContext) }
            ))
            .themedRow()

            if drawerRowCount > 1 {
                Picker("More Button Behavior", selection: Binding(
                    get: { manager.drawerToggleMode },
                    set: { manager.drawerToggleMode = $0 }
                )) {
                    ForEach(DrawerToggleMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .themedRow()
                .settingContextMenu(Settings.KeyboardToolbar.drawerToggleMode)
            }

            SettingToggle(
                Settings.KeyboardToolbar.drawerOpenByDefault,
                isOn: Binding(
                    get: { manager.drawerOpenByDefault },
                    set: { manager.drawerOpenByDefault = $0 }
                ),
                title: "Open Drawer by Default"
            )
            .themedRow()
        } header: {
            Text("Drawer")
        } footer: {
            Text(drawerFooter)
        }
    }

    private var drawerFooter: String {
        let keyWidth = String(localized: "With the same key width, drawer keys line up under the main row's; the terminal keyboard's toolbar always does this.")
        guard drawerRowCount > 1 else {
            return keyWidth + " " + String(localized: "When enabled, the drawer starts open each time the keyboard appears.")
        }
        switch manager.drawerToggleMode {
        case .stack:
            return keyWidth + " " + String(localized: "Each press of the ••• button reveals one more drawer row; when all are open, the next press closes them. \"Open Drawer by Default\" opens the first row when the keyboard appears.")
        case .cycle:
            return keyWidth + " " + String(localized: "Each press of the ••• button swaps the drawer row's contents to the next set of keys, then closes. \"Open Drawer by Default\" opens the first row when the keyboard appears.")
        }
    }
}
