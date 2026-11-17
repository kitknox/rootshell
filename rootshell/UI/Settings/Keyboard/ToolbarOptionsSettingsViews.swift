//
//  ToolbarOptionsSettingsViews.swift
//  rootshell
//
//  The two option screens under Toolbar Keys: how a toolbar looks, and how its
//  rows are arranged. Each keeps a preview on screen while its options change.
//

import SwiftUI

// MARK: - Appearance

/// Style, keycaps and size. These apply to every toolbar, not only the one
/// whose screen opened this.
struct ToolbarAppearanceSettingsView: View {
    let context: ToolbarContext

    @State private var manager = KeyboardToolbarManager.shared
    @State private var previewMetrics = ToolbarLayoutPreviewMetrics()
    @Setting(Settings.Keyboard.touchEnabled) private var terminalKeyboard
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingBar

    private var surfaces: [ToolbarPreviewSurface] {
        ToolbarPreviewSurface.available(for: context, terminalKeyboard: terminalKeyboard, floatingBar: floatingBar)
    }
    /// Style and keycaps only show above the system keyboard.
    private var showsSystemKeyboardOptions: Bool { surfaces.contains(.systemKeyboard) }

    var body: some View {
        List {
            Section {
                ToolbarLayoutPreview(toolbar: context, surface: showsSystemKeyboardOptions ? .systemKeyboard : nil,
                                     metrics: $previewMetrics)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .themedRow()
            } header: {
                Text("Preview")
            }

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
            Section {
                if DuoHingeEvents.hasHinge {
                    ToolbarSizePicker("Inner Display", key: Settings.KeyboardToolbar.sizeDuoInner)
                    ToolbarSizePicker("Front Display", key: Settings.KeyboardToolbar.sizeDuoFront)
                } else {
                    ToolbarSizePicker("Toolbar Size", key: KeyboardToolbarSize.currentKey)
                }
            } header: {
                Text("Size")
            } footer: {
                Text("Automatic keeps the system keyboard's toolbar at its usual size and sizes the terminal keyboard's toolbar with the keyboard. A chosen size holds whether the keyboard is docked or detached.")
            }
            #endif
        }
        .themedList()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One display's toolbar size.
private struct ToolbarSizePicker: View {
    private let title: LocalizedStringKey
    private let key: SettingKey<KeyboardToolbarSize>
    @Setting private var size: KeyboardToolbarSize

    init(_ title: LocalizedStringKey, key: SettingKey<KeyboardToolbarSize>) {
        self.title = title
        self.key = key
        _size = Setting(key)
    }

    var body: some View {
        Picker(title, selection: $size) {
            ForEach(KeyboardToolbarSize.allCases, id: \.self) { size in
                Text(size.displayName).tag(size)
            }
        }
        .themedRow()
        .settingContextMenu(key)
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
            keySizeSection
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
        } header: {
            Text("Main Row")
        } footer: {
            Text(sectionsFooter)
        }
    }

    private var keySizeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Minimum Key Width")
                    Spacer()
                    Text(layout.minimumKeyWidth > 0
                         ? String(localized: "\(Int(layout.minimumKeyWidth)) pt")
                         : String(localized: "Automatic"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // The low end of the slider is Automatic.
                Slider(value: Binding(
                    get: { max(layout.minimumKeyWidth, ToolbarLayoutConfig.minimumKeyWidthRange.lowerBound) },
                    set: { manager.setMinimumKeyWidth($0, in: editedContext) }
                ), in: ToolbarLayoutConfig.minimumKeyWidthRange, step: 4)
                .accessibilityLabel("Minimum Key Width")
            }
            .themedRow()

            Toggle("Same Key Size in Drawer", isOn: Binding(
                get: { layout.drawerMatchesMainRow },
                set: { manager.setDrawerMatchesMainRow($0, in: editedContext) }
            ))
            .themedRow()
        } header: {
            Text("Key Size")
        } footer: {
            Text("Main row keys fill the row and narrow as you add more. A minimum width keeps them from narrowing past it, so the row scrolls or moves keys to the drawer sooner. With the same key size, drawer keys line up under the main row's; the terminal keyboard's toolbar always does this.")
        }
    }

    private var sectionsFooter: String {
        layout.mainRowScrolls
            ? String(localized: "A pinned section stands apart at its end of the main row and stays put. When the row is full, the keys between scroll sideways, and the ••• key stays at the right end. Add keys to a pinned section in the key list.")
            : String(localized: "A pinned section stands apart at its end of the main row and keeps its keys there when the row is full; the keys between move to the drawer first. Add keys to a pinned section in the key list.")
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
        guard drawerRowCount > 1 else {
            return String(localized: "When enabled, the drawer starts open each time the keyboard appears.")
        }
        switch manager.drawerToggleMode {
        case .stack:
            return String(localized: "Each press of the ••• button reveals one more drawer row; when all are open, the next press closes them. \"Open Drawer by Default\" opens the first row when the keyboard appears.")
        case .cycle:
            return String(localized: "Each press of the ••• button swaps the drawer row's contents to the next set of keys, then closes. \"Open Drawer by Default\" opens the first row when the keyboard appears.")
        }
    }
}
