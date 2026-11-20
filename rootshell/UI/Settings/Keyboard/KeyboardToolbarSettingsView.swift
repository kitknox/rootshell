//
//  KeyboardToolbarSettingsView.swift
//  rootshell
//
//  Settings for the keyboard toolbars: one screen, with a picker for which
//  toolbar it shows and edits.
//

import SwiftUI

extension ToolbarContext {
    var toolbarTitle: String {
        switch self {
        case .terminal: return String(localized: "Terminal Toolbar")
        case .screenSharing: return String(localized: "Screen Sharing Toolbar")
        case .kvm: return String(localized: "KVM Toolbar")
        }
    }
}

struct KeyboardToolbarSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    #if os(visionOS)
    @Environment(\.dismiss) private var dismiss
    #endif
    @State private var manager = KeyboardToolbarManager.shared
    /// The toolbar on screen. Opens on the one the settings key was pressed in.
    @State private var context: ToolbarContext
    /// The surface the preview draws; nil is the one this toolbar appears on first.
    @State private var chosenSurface: ToolbarPreviewSurface?
    @State private var editorContentHeight: CGFloat = 360
    @State private var previewMetrics = ToolbarLayoutPreviewMetrics()
    @State private var showingResetConfirmation = false
    @State private var showingResetAllConfirmation = false
    @Setting(Settings.Keyboard.touchEnabled) private var terminalKeyboard
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingBar

    /// `surface` is where the toolbar was showing when its settings key was pressed.
    init(context: ToolbarContext = .terminal, surface: ToolbarPreviewSurface? = nil) {
        _context = State(initialValue: context)
        _chosenSurface = State(initialValue: surface)
    }

    private var layout: ToolbarLayoutConfig { manager.layout(for: context) }
    private var hasOwnLayout: Bool { manager.hasOwnLayout(context) }
    /// The layout edits land in: this toolbar's own, or the terminal's while it is shared.
    private var editedContext: ToolbarContext { hasOwnLayout ? context : .terminal }

    private var surfaces: [ToolbarPreviewSurface] {
        ToolbarPreviewSurface.available(for: context, terminalKeyboard: terminalKeyboard, floatingBar: floatingBar)
    }
    /// A choice this toolbar does not offer falls back to its first surface.
    private var previewSurface: ToolbarPreviewSurface {
        chosenSurface.flatMap { surfaces.contains($0) ? $0 : nil } ?? surfaces[0]
    }

    /// The embedded editor self-sizes to its full content so its rows flow as
    /// part of the surrounding list (the outer List does the scrolling, not the
    /// collection view). This is the reported content height from the editor.
    private var editorFrameHeight: CGFloat {
        max(editorContentHeight, 120)
    }

    var body: some View {
        List {
            toolbarPickerSection
            previewSection
            optionsSection
            if !hasOwnLayout {
                sharedLayoutSection
            }
            toolbarLayoutSection
            customKeysSection
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
        .confirmationDialog(resetTitle, isPresented: $showingResetConfirmation) {
            Button(role: .destructive) {
                manager.resetLayout(for: context)
            } label: {
                context == .terminal ? Text("Reset") : Text("Use Terminal Toolbar")
            }
        } message: {
            Text(resetMessage)
        }
        .confirmationDialog("Reset All Toolbars?", isPresented: $showingResetAllConfirmation) {
            Button("Reset", role: .destructive) {
                manager.resetToDefaults()
            }
        } message: {
            Text("This will restore the default Terminal toolbar, remove the Screen Sharing and KVM toolbars' own layouts, and delete all custom keys. Saved layouts are kept.")
        }
    }

    // MARK: - Toolbar Picker

    private var toolbarPickerSection: some View {
        Section {
            Picker("Toolbar", selection: Binding(
                get: { context },
                set: {
                    context = $0
                    // Each toolbar opens on the surface it appears on first.
                    chosenSurface = nil
                }
            )) {
                ForEach(ToolbarContext.allCases, id: \.self) { context in
                    Text(context.displayName).tag(context)
                }
            }
            .pickerStyle(.segmented)
            .themedRow()
        } footer: {
            Text("Screen Sharing and KVM use the Terminal toolbar until you customize them.")
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        Section {
            ToolbarPreviewSurfacePicker(surfaces: surfaces, selection: Binding(
                get: { previewSurface },
                set: { chosenSurface = $0 }
            ))
            ToolbarLayoutPreview(toolbar: context, surface: previewSurface, showsDrawers: true,
                                 metrics: $previewMetrics)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                .themedRow()
        } header: {
            Text("Preview")
        } footer: {
            Text(previewFooter)
        }
    }

    private var previewFooter: String {
        switch previewSurface {
        case .systemKeyboard:
            return String(localized: "The toolbar above the system keyboard, at this window's width.")
        case .terminalKeyboard where context.usesGlassBar:
            return String(localized: "The terminal keyboard's own toolbar row, which carries these keys while the remote screen's toolbar is docked and the keyboard is up.")
        case .terminalKeyboard:
            return String(localized: "The terminal keyboard's own toolbar row, in your keyboard style, at this window's width.")
        case .glassBar(floating: true):
            return String(localized: "The remote screen's floating toolbar. Its own buttons take the right end.")
        case .glassBar(floating: false):
            return String(localized: "The remote screen's toolbar docked along the bottom, at this window's width. Its own buttons take the right end.")
        }
    }

    // MARK: - Options

    // How the toolbar looks and how its rows are arranged each live a level
    // down, so this screen stays the preview and the keys. Each row says what is set.
    private var optionsSection: some View {
        Section {
            NavigationLink {
                ToolbarAppearanceSettingsView(context: context)
            } label: {
                optionRow("Appearance and Size", systemImage: "paintbrush", value: appearanceSummary)
            }
            .themedRow()

            NavigationLink {
                ToolbarArrangementSettingsView(context: context)
            } label: {
                optionRow("Layout", systemImage: "rectangle.split.3x1", value: arrangementSummary)
            }
            .themedRow()

            NavigationLink {
                ToolbarSavedLayoutsView(context: context)
            } label: {
                optionRow("Copy and Save", systemImage: "tray.full", value: savedSummary)
            }
            .themedRow()
        }
    }

    private var savedSummary: String {
        manager.savedLayouts.isEmpty ? "" : String(localized: "\(manager.savedLayouts.count) Saved")
    }

    private func optionRow(_ title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        HStack(spacing: 12) {
            // A fixed box: a tall symbol would otherwise make its row a fraction taller.
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 20)
            Text(title)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .lineLimit(1)
            }
        }
    }

    private var appearanceSummary: String {
        var parts: [String] = []
        if surfaces.contains(.systemKeyboard) {
            let style = manager.toolbarStyle.resolved
            parts.append(style.displayName)
            if manager.showsKeycaps && style != .glassBar { parts.append(String(localized: "Keycaps")) }
        }
        if manager.glyphColoring != .standard { parts.append(manager.glyphColoring.displayName) }
        let size = KeyboardToolbarSize.current
        if size != .automatic { parts.append(size.displayName) }
        return parts.joined(separator: ", ")
    }

    private var arrangementSummary: String {
        var parts: [String] = []
        switch (layout.pinnedLeading != nil, layout.pinnedTrailing != nil) {
        case (true, true): parts.append(String(localized: "Pinned Both Ends"))
        case (true, false): parts.append(String(localized: "Pinned Left"))
        case (false, true): parts.append(String(localized: "Pinned Right"))
        case (false, false): break
        }
        if layout.mainRowScrolls { parts.append(String(localized: "Scrolls")) }
        if layout.drawerRows.count > 1 { parts.append(String(localized: "\(layout.drawerRows.count) Drawer Rows")) }
        return parts.isEmpty ? String(localized: "Default") : parts.joined(separator: ", ")
    }

    // MARK: - Shared Layout

    private var sharedLayoutSection: some View {
        Section {
            Button {
                manager.splitLayout(for: context)
            } label: {
                Label("Customize This Toolbar", systemImage: "plus.square.on.square")
            }
            .themedRow()
        } header: {
            Text("Shared with Terminal")
        } footer: {
            Text("\(context.displayName) uses the Terminal toolbar, so changes below change both. Customizing gives \(context.displayName) a copy of its own and leaves the Terminal toolbar as it is.")
        }
    }

    // MARK: - Toolbar Layout Editor

    // The editor hosts its own inset-grouped sections (Main Row, Drawer, and any
    // pinned groups) with native headers/footers, so it is NOT wrapped in a
    // SwiftUI Section — an empty Section would add a second top gap above the
    // first header on top of the editor's own first-section spacing. As a bare,
    // clear-background, full-width row, only the editor's grouped chrome shows.
    private var toolbarLayoutSection: some View {
        ToolbarLayoutEditor(
            manager: manager,
            toolbar: editedContext,
            themeColors: sheetThemeColors,
            capacity: previewMetrics.capacity,
            marksHostBarKeys: context.usesGlassBar,
            contentHeight: $editorContentHeight
        )
        // The editor is bound to one layout; another toolbar needs a new editor.
        .id(editedContext)
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
                        context: context,
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
                    context: context,
                    onSave: { newKey in
                        manager.createCustomKey(newKey, in: editedContext)
                    }
                )
            } label: {
                Label("New Custom Key", systemImage: "plus.circle")
            }
            .themedRow()
        } header: {
            Text("Custom Keys")
        } footer: {
            Text("Create buttons that send key sequences. Custom keys are shared by every toolbar; each toolbar chooses where to place them.")
        }
    }

    // MARK: - Hidden Keys Section

    private var hiddenKeysSection: some View {
        let hiddenKeys = layout.hiddenKeys.sorted { $0.rawValue < $1.rawValue }
        let unplacedKeys = manager.unplacedCustomKeys(in: editedContext)
        return Section {
            if hiddenKeys.isEmpty && unplacedKeys.isEmpty {
                Text("No hidden keys.")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                    .themedRow()
            } else {
                ForEach(hiddenKeys, id: \.self) { keyID in
                    Button {
                        manager.unhideKey(keyID, in: editedContext)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                            keyBadge(symbol: keyID.iconName, text: keyID.keyValue)
                            Text(keyID.displayName)
                                .foregroundStyle(.primary)
                        }
                    }
                    .themedRow()
                }
                ForEach(unplacedKeys) { key in
                    Button {
                        manager.addCustomKeyToLayout(id: key.id, section: .drawer(0), in: editedContext)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.green)
                            keyBadge(symbol: key.iconName, text: String(key.label.prefix(2)))
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
            if !hiddenKeys.isEmpty || !unplacedKeys.isEmpty {
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
            if hasOwnLayout {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if context == .terminal {
                            Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        } else {
                            Label("Use Terminal Toolbar", systemImage: "arrow.uturn.backward")
                        }
                        Spacer()
                    }
                }
                .disabled(!manager.isCustomized(context))
                .themedRow()
            }

            Button(role: .destructive) {
                showingResetAllConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Label("Reset All Toolbars", systemImage: "trash")
                    Spacer()
                }
            }
            .disabled(!manager.isCustomized)
            .themedRow()
        }
    }

    private var resetTitle: String {
        context == .terminal
            ? String(localized: "Reset to Defaults?")
            : String(localized: "Use the Terminal Toolbar?")
    }

    private var resetMessage: String {
        context == .terminal
            ? String(localized: "This will restore the default key layout. Custom keys stay available under Hidden Keys.")
            : String(localized: "This removes this toolbar's own layout. It will show the Terminal toolbar again.")
    }

    // MARK: - Badge Views

    private func keyBadge(symbol: String?, text: String) -> some View {
        Group {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
            } else {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .foregroundStyle(.tint)
        .frame(width: 28, height: 28)
        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
