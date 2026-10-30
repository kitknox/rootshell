//
//  KeyboardToolbarSettingsView.swift
//  rootshell
//
//  Settings view for keyboard toolbar customization.
//  Supports reordering, hiding, and restoring keys, plus custom key management.
//

import SwiftUI

struct KeyboardToolbarSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    #if os(visionOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var manager = KeyboardToolbarManager.shared
    @State private var editorContentHeight: CGFloat = 360
    @State private var showingResetConfirmation = false

    /// The embedded editor self-sizes to its full content so its rows flow as
    /// part of the surrounding list (the outer List does the scrolling, not the
    /// collection view). This is the reported content height from the editor.
    private var editorFrameHeight: CGFloat {
        max(editorContentHeight, 120)
    }

    var body: some View {
        List {
            Section {
                KeyboardToolbarPreview(config: manager.config, customKeys: manager.customKeys)
                    .frame(height: UIDevice.current.userInterfaceIdiom == .phone ? 44 : 55)
                    .padding(.vertical, 12)
                    .themedRow()
            } header: {
                Text("Preview")
            }
            toolbarOptionsSection
            toolbarLayoutSection
            customKeysSection
            drawerBehaviorSection
            hiddenKeysSection
            relatedSection
            resetSection
        }
        .themedList()
        // No text input on this screen, so keyboard avoidance is pure downside:
        // when the sheet is presented from the keyboard toolbar the keyboard is
        // still animating away, and on iPad the List latches its bottom inset
        // as a permanent stretch of blank scrollable space after the last section.
        .ignoresSafeArea(.keyboard)
        .navigationTitle("Toolbar Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if os(visionOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
            #endif
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .confirmationDialog("Reset to Defaults?", isPresented: $showingResetConfirmation) {
            Button("Reset", role: .destructive) {
                manager.resetToDefaults()
            }
        } message: {
            Text("This will restore the default key layout and remove all custom keys from the toolbar.")
        }
    }

    private var toolbarOptionsSection: some View {
        Section {
            Picker("Appearance", selection: Binding(
                get: { manager.config.appearance },
                set: { manager.setAppearance($0) }
            )) {
                ForEach(ToolbarAppearance.allCases, id: \.self) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()

            Picker("Scroll Keys", selection: Binding(
                get: { manager.config.scrollScope },
                set: { manager.setScrollScope($0) }
            )) {
                ForEach(ToolbarScrollScope.allCases, id: \.self) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()

            Picker("Scroll Behavior", selection: Binding(
                get: { manager.config.scrollBehavior },
                set: { manager.setScrollBehavior($0) }
            )) {
                ForEach(ToolbarScrollBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()
        } header: {
            Text("Toolbar Layout")
        } footer: {
            Text("Pin keys in the left and right sections. Primary keys scroll between them, or scroll with all keys. Page mode snaps to the number of keys that fit.")
        }
    }

    // MARK: - Toolbar Layout Editor (Pinned, Primary, and Drawer Rows)

    // The editor hosts its own grouped sections with native headers and footers,
    // so it is not wrapped in a SwiftUI Section. An empty Section would add a
    // second top gap before its first header. As a bare, clear-background,
    // full-width row, only the editor's grouped chrome shows.
    private var toolbarLayoutSection: some View {
        ToolbarLayoutEditor(
            manager: manager,
            themeColors: sheetThemeColors,
            contentHeight: $editorContentHeight
        )
        .frame(height: editorFrameHeight)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    // MARK: - Custom Keys Section

    private var customKeysSection: some View {
        Section {
            ForEach(manager.customKeys) { key in
                NavigationLink {
                    CustomKeyEditorView(
                        existingKey: key,
                        onSave: { updatedKey in
                            manager.updateCustomKey(updatedKey)
                        },
                        onDelete: {
                            manager.deleteCustomKey(id: key.id)
                        }
                    )
                } label: {
                    HStack {
                        if let iconName = key.iconName {
                            Image(systemName: iconName)
                                .foregroundStyle(.tint)
                                .frame(width: 24)
                        }
                        Text(key.label)
                        Spacer()
                        Text(key.sequenceSummary)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                .themedRow()
            }

            NavigationLink {
                CustomKeyEditorView(
                    onSave: { newKey in
                        manager.createCustomKey(newKey)
                    }
                )
            } label: {
                Label("New Custom Key", systemImage: "plus.circle")
            }
            .themedRow()
        } header: {
            Text("Custom Keys")
        } footer: {
            Text("Create buttons that send key sequences.")
        }
    }

    // MARK: - Drawer Behavior Section

    private var drawerBehaviorSection: some View {
        Section {
            Stepper(value: Binding(
                get: { manager.drawerRowCount },
                set: { manager.setDrawerRowCount($0) }
            ), in: 1...KeyboardToolbarManager.maxDrawerRows) {
                HStack {
                    Text("Drawer Rows")
                    Spacer()
                    Text("\(manager.drawerRowCount)")
                        .foregroundStyle(.secondary)
                }
            }
            .themedRow()

            if manager.drawerRowCount > 1 {
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
        } footer: {
            Text(drawerBehaviorFooter)
        }
    }

    private var drawerBehaviorFooter: String {
        guard manager.drawerRowCount > 1 else {
            return String(localized: "When enabled, the drawer starts open each time the keyboard appears.")
        }
        switch manager.drawerToggleMode {
        case .stack:
            return String(localized: "Each press of the ••• button reveals one more drawer row; when all are open, the next press closes them. \"Open Drawer by Default\" opens the first row when the keyboard appears.")
        case .cycle:
            return String(localized: "Each press of the ••• button swaps the drawer row's contents to the next set of keys, then closes. \"Open Drawer by Default\" opens the first row when the keyboard appears.")
        }
    }

    // MARK: - Hidden Keys Section

    private var hiddenKeysSection: some View {
        Section {
            if manager.config.hiddenKeys.isEmpty && manager.unplacedCustomKeys.isEmpty {
                Text("No hidden keys.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .themedRow()
            } else {
                ForEach(Array(manager.config.hiddenKeys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { keyID in
                    Button {
                        manager.unhideKey(keyID)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                            keyBadge(for: keyID)
                            Text(keyID.displayName)
                                .foregroundStyle(.primary)
                        }
                    }
                    .themedRow()
                }
                ForEach(manager.unplacedCustomKeys) { key in
                    Button {
                        manager.addCustomKeyToLayout(id: key.id, section: .drawer(0))
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                            if let iconName = key.iconName {
                                Image(systemName: iconName)
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                    .frame(width: 28, height: 28)
                                    .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Text(String(key.label.prefix(2)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tint)
                                    .frame(width: 28, height: 28)
                                    .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text(key.label)
                                .foregroundStyle(.primary)
                        }
                    }
                    .themedRow()
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            manager.deleteCustomKey(id: key.id)
                        }
                    }
                }
            }
        } header: {
            Text("Hidden Keys")
        } footer: {
            if !manager.config.hiddenKeys.isEmpty || !manager.unplacedCustomKeys.isEmpty {
                Text("Tap to restore a hidden key to the drawer. Swipe left on a custom key to delete it.")
            }
        }
    }

    // MARK: - Related Section

    private var relatedSection: some View {
        Section {
            NavigationLink {
                SwipeGesturesSettingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.draw")
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text("Swipe Gestures")
                    SettingPinTag(Settings.Gestures.swipeBindings.erased)
                    Spacer()
                    if SwipeGestureManager.shared.isCustomized {
                        Text("Customized")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .themedRow()
            .settingContextMenu(Settings.Gestures.swipeBindings)
        } header: {
            Text("Related")
        } footer: {
            Text("Configure left/right swipes to send custom sequences or switch tabs.")
        }
    }

    // MARK: - Reset Section

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
            .disabled(!manager.isCustomized)
            .themedRow()
        }
    }

    // MARK: - Badge Views

    @ViewBuilder
    private func keyBadge(for keyID: KeyID) -> some View {
        if let iconName = keyID.iconName {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text(keyID.keyValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

}

private struct KeyboardToolbarPreview: UIViewRepresentable {
    let config: ToolbarLayoutConfig
    let customKeys: [CustomKey]

    func makeUIView(context: Context) -> KeyboardToolbarView {
        let toolbar = KeyboardToolbarView(sizes: KeyboardSizes.current(traitCollection: UITraitCollection.current))
        toolbar.isEmbeddedPreview = true
        toolbar.setDismissButtonShowsRestore(true)
        return toolbar
    }

    func updateUIView(_ toolbar: KeyboardToolbarView, context: Context) {
        toolbar.updateSizes(KeyboardSizes.current(traitCollection: toolbar.traitCollection))
    }
}
