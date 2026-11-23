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

    /// Toolbars this device shows, so the ones settings may edit. A Mac's only
    /// toolbar is a remote screen's bar.
    static var editableCases: [ToolbarContext] {
        #if targetEnvironment(macCatalyst)
        allCases.filter(\.usesGlassBar)
        #else
        allCases
        #endif
    }
}

/// Ends the toolbar's undo history with the screen that made it, so an undo
/// somewhere else in the window cannot reach back into it.
private final class ToolbarHistoryScope {
    weak var undoManager: UndoManager?

    deinit {
        guard let undoManager else { return }
        Task { @MainActor in KeyboardToolbarManager.shared.forgetHistory(in: undoManager) }
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
    @State private var isSelecting = false
    @State private var selection: Set<KeySlot> = []
    @State private var collapsed: Set<KeyboardToolbarManager.ToolbarSection> = []
    /// The key the preview flashes, and the one the list scrolls to.
    @State private var previewPulse: ToolbarKeyPulse?
    @State private var listReveal: ToolbarKeyPulse?
    @State private var pulseToken = 0
    @State private var editorRefreshToken = 0
    @State private var historyScope = ToolbarHistoryScope()
    @State private var listHeight: CGFloat = 0
    @State private var addKeyTarget: AddKeyTarget?
    @State private var editingCustomKey: CustomKey?
    @State private var showingNewCustomKey = false
    @State private var showingSave = false
    @State private var saveName = ""
    /// An edit waiting on whether it may change the Terminal toolbar too.
    @State private var pendingSharedEdit: PendingSharedEdit?
    /// Toolbars the user chose to edit together with the Terminal toolbar.
    @State private var sharedEditsAllowed: Set<ToolbarContext> = []
    @Environment(\.undoManager) private var undoManager
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Setting(Settings.Keyboard.touchEnabled) private var terminalKeyboard
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingBar

    /// `surface` is where the toolbar was showing when its settings key was pressed.
    init(context: ToolbarContext = .terminal, surface: ToolbarPreviewSurface? = nil) {
        _context = State(initialValue: ToolbarContext.editableCases.contains(context)
            ? context : ToolbarContext.editableCases[0])
        _chosenSurface = State(initialValue: surface)
    }

    private var layout: ToolbarLayoutConfig { manager.layout(for: context) }
    private var hasOwnLayout: Bool { manager.hasOwnLayout(context) }
    /// The layout edits land in: this toolbar's own, or the terminal's while it is shared.
    private var editedContext: ToolbarContext { hasOwnLayout ? context : .terminal }

    private var surfaces: [ToolbarPreviewSurface] {
        ToolbarPreviewSurface.available(for: context, terminalKeyboard: terminalKeyboard, floatingBar: floatingBar)
    }
    /// The preview stays put only where it leaves most of the height to the
    /// list: not on a phone on its side, and not once its drawer rows stack up
    /// on a short display.
    private var pinsPreview: Bool {
        guard verticalSizeClass != .compact else { return false }
        let rows = 2 + (layout.drawerRows.lastIndex { !$0.isEmpty } ?? -1)
        return listHeight == 0 || CGFloat(rows) * 46 + 20 <= listHeight * 0.3
    }

    private struct AddKeyTarget: Identifiable {
        let section: KeyboardToolbarManager.ToolbarSection
        var id: KeyboardToolbarManager.ToolbarSection { section }
    }

    private struct PendingSharedEdit {
        let run: (ToolbarContext) -> Void
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
            relatedSection
        }
        .themedList()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
            if pinsPreview { pinnedPreview }
        }
        // No text input on this screen, so keyboard avoidance is pure downside:
        // when the sheet is presented from the keyboard toolbar the keyboard is
        // still animating away, and on iPad the List latches its bottom inset
        // as a permanent stretch of blank scrollable space after the last section.
        .ignoresSafeArea(.keyboard)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if os(visionOS)
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
            #endif
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    setSelecting(!isSelecting)
                }
                moreMenu
            }
            if isSelecting {
                ToolbarItemGroup(placement: .bottomBar) { selectionBar }
            }
        }
        .navigationDestination(item: $editingCustomKey) { key in
            CustomKeyEditorView(existingKey: key, context: context,
                                onSave: { manager.updateCustomKey($0) },
                                onDelete: { manager.deleteCustomKey(id: key.id) })
        }
        .navigationDestination(isPresented: $showingNewCustomKey) {
            CustomKeyEditorView(context: context, onSave: { key in
                edit(String(localized: "Add Custom Key"), keys: [.custom(key.id)]) {
                    manager.createCustomKey(key, in: $0)
                }
            })
        }
        .sheet(item: $addKeyTarget) { target in
            ToolbarAddKeySheet(context: context, section: target.section, add: { slot in
                edit(String(localized: "Add Key"), keys: [slot]) {
                    manager.placeKeys([slot], in: target.section, in: $0)
                }
            }, create: { key in
                edit(String(localized: "Add Key"), keys: [.custom(key.id)]) {
                    manager.createCustomKey(key, in: $0)
                    manager.placeKeys([.custom(key.id)], in: target.section, in: $0)
                }
            })
            .themedSubSheet(sheetThemeColors)
        }
        .alert("Change the Terminal Toolbar Too?", isPresented: Binding(
            get: { pendingSharedEdit != nil },
            set: { if !$0 { pendingSharedEdit = nil } }
        ), presenting: pendingSharedEdit) { pending in
            Button("Change Both") {
                sharedEditsAllowed.insert(context)
                pending.run(.terminal)
            }
            Button("Customize \(context.displayName) Only") {
                manager.undoably(String(localized: "Customize Toolbar"), with: undoManager) {
                    manager.splitLayout(for: context)
                }
                pending.run(context)
            }
            Button("Cancel", role: .cancel) {
                // The list may already show the change that was called off.
                editorRefreshToken += 1
            }
        } message: { _ in
            Text("\(context.displayName) uses the Terminal toolbar, so this changes both. Customizing gives \(context.displayName) a copy of its own and leaves the Terminal toolbar as it is.")
        }
        .alert("Save Layout", isPresented: $showingSave) {
            TextField("Name", text: $saveName)
            Button("Save") { manager.saveLayout(of: context, named: saveName) }
            Button("Cancel", role: .cancel) {}
        }
        // The history outlives a visit to a subpage and ends with this screen.
        .onAppear { historyScope.undoManager = undoManager }
        .onChange(of: undoManager) { historyScope.undoManager = undoManager }
        .confirmationDialog(resetTitle, isPresented: $showingResetConfirmation) {
            Button(role: .destructive) {
                manager.undoably(String(localized: "Reset Toolbar"), with: undoManager) { manager.resetLayout(for: context) }
                sharedEditsAllowed.remove(context)
            } label: {
                context == .terminal ? Text("Reset") : Text("Use Terminal Toolbar")
            }
        } message: {
            Text(resetMessage)
        }
        .confirmationDialog("Reset All Toolbars?", isPresented: $showingResetAllConfirmation) {
            Button("Reset", role: .destructive) {
                manager.undoably(String(localized: "Reset All Toolbars"), with: undoManager) {
                    manager.resetToDefaults()
                }
                sharedEditsAllowed.removeAll()
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
                    setSelecting(false)
                }
            )) {
                ForEach(ToolbarContext.editableCases, id: \.self) { context in
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
            if !pinsPreview {
                preview
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .themedRow()
            }
        } header: {
            if !pinsPreview { Text("Preview") }
        } footer: {
            Text(previewFooter + " " + String(localized: "Tap a key to find it in the list. Touch and hold a key to drag it to a new place."))
        }
    }

    private var preview: some View {
        ToolbarLayoutPreview(toolbar: context, surface: previewSurface, showsDrawers: true,
                             metrics: $previewMetrics, pulse: previewPulse,
                             actions: ToolbarPreviewActions(selectKey: { slot in
                                 listReveal = nextPulse(slot)
                             }, moveKey: movePreviewKey))
    }

    /// The preview held above the list, so it shows what each edit does.
    private var pinnedPreview: some View {
        VStack(spacing: 0) {
            preview
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
        }
        .background(sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground))
    }

    private func nextPulse(_ slot: KeySlot) -> ToolbarKeyPulse {
        pulseToken += 1
        return ToolbarKeyPulse(slot: slot, token: pulseToken)
    }

    // MARK: - Edits

    /// Runs an action on the layout edits should change. While this toolbar
    /// still shows the Terminal's, it asks first which of the two to change.
    @discardableResult
    private func onEditableLayout(_ action: @escaping (ToolbarContext) -> Void) -> Bool {
        guard hasOwnLayout || sharedEditsAllowed.contains(context) else {
            pendingSharedEdit = PendingSharedEdit(run: action)
            return false
        }
        action(editedContext)
        return true
    }

    /// One undoable change to the layout. The preview flashes the first of `keys`.
    @discardableResult
    private func edit(_ name: String, keys: [KeySlot] = [], _ change: @escaping (ToolbarContext) -> Void) -> Bool {
        onEditableLayout { target in
            manager.undoably(name, with: undoManager) { change(target) }
            if let key = keys.first { previewPulse = nextPulse(key) }
        }
    }

    /// A drag in the preview dropped a key at a place the preview worked out.
    private func movePreviewKey(_ slot: KeySlot, to section: KeyboardToolbarManager.ToolbarSection,
                                before anchor: KeySlot?) {
        edit(String(localized: "Move Key"), keys: [slot]) { target in
            manager.placeKeys([slot], in: section, before: anchor, in: target)
        }
    }

    // MARK: - Selecting

    /// While selecting, the title counts the keys picked.
    private var navigationTitle: String {
        guard isSelecting else { return String(localized: "Toolbar Keys") }
        let count = selectedKeys.count
        return count == 0 ? String(localized: "Select Keys") : String(localized: "\(count) Selected")
    }

    /// The selected keys still on the toolbar, in the order the layout places them.
    private var selectedKeys: [KeySlot] {
        layout.placedSlots.filter(selection.contains)
    }

    private func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        selection = []
    }

    @ViewBuilder
    private var selectionBar: some View {
        let keys = selectedKeys
        let drawerRows = layout.drawerRows.count
        Menu("Move To") {
            ForEach(manager.sections(in: editedContext), id: \.self) { section in
                Button {
                    // The selection lasts until the edit runs, which may wait on a question.
                    edit(String(localized: "Move Keys"), keys: keys) {
                        manager.placeKeys(keys, in: section, in: $0)
                        setSelecting(false)
                    }
                } label: {
                    Label(section.title(drawerRows: drawerRows), systemImage: section.symbolName)
                }
            }
        }
        .disabled(keys.isEmpty)
        Spacer()
        // A built-in key is hidden; a custom key only leaves this toolbar.
        Button(keys.contains { $0.customID != nil } ? "Remove" : "Hide", role: .destructive) {
            edit(String(localized: "Remove Keys")) {
                manager.removeKeys(keys, in: $0)
                setSelecting(false)
            }
        }
        .disabled(keys.isEmpty)
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        // Read here so the Undo and Redo rows are redrawn when the history changes.
        let _ = manager.historyRevision
        return Menu {
            // The navigation bar can scroll away on a small display; this menu stays.
            Button {
                setSelecting(!isSelecting)
            } label: {
                if isSelecting {
                    Label("Done Selecting", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Select Keys", systemImage: "checkmark.circle")
                }
            }

            Divider()
            Button {
                undoManager?.undo()
            } label: {
                Label(undoManager?.undoMenuItemTitle ?? String(localized: "Undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(undoManager?.canUndo != true)
            Button {
                undoManager?.redo()
            } label: {
                Label(undoManager?.redoMenuItemTitle ?? String(localized: "Redo"), systemImage: "arrow.uturn.forward")
            }
            .disabled(undoManager?.canRedo != true)

            Divider()
            Button {
                saveName = manager.suggestedSaveName(for: context)
                showingSave = true
            } label: {
                Label("Save Layout…", systemImage: "tray.and.arrow.down")
            }

            Divider()
            if hasOwnLayout {
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    if context == .terminal {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    } else {
                        Label("Use Terminal Toolbar", systemImage: "arrow.uturn.backward")
                    }
                }
                .disabled(!manager.isCustomized(context))
            }
            Button(role: .destructive) {
                showingResetAllConfirmation = true
            } label: {
                Label("Reset All Toolbars", systemImage: "trash")
            }
            .disabled(!manager.isCustomized)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
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
                manager.undoably(String(localized: "Customize Toolbar"), with: undoManager) {
                    manager.splitLayout(for: context)
                }
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
            overflowing: previewMetrics.overflowing,
            marksHostBarKeys: context.usesGlassBar,
            isSelecting: isSelecting,
            selection: $selection,
            collapsed: $collapsed,
            reveal: listReveal,
            refreshToken: editorRefreshToken,
            actions: ToolbarLayoutEditorActions(
                edit: { name, keys, change in edit(name, keys: keys, change) },
                record: { name, change in manager.undoably(name, with: undoManager, change) },
                addKey: { section in onEditableLayout { _ in addKeyTarget = AddKeyTarget(section: section) } },
                editCustomKey: { editingCustomKey = manager.customKey(for: $0) }),
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

            // A new key joins this toolbar's first drawer row, so a shared layout asks first.
            Button {
                onEditableLayout { _ in showingNewCustomKey = true }
            } label: {
                Label("New Custom Key", systemImage: "plus.circle")
            }
            .themedRow()
        } header: {
            Text("Custom Keys")
        } footer: {
            Text("Create buttons that send key sequences. Custom keys are shared by every toolbar; each toolbar places them from a row's + button.")
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

    // MARK: - Reset

    private var resetTitle: String {
        context == .terminal
            ? String(localized: "Reset to Defaults?")
            : String(localized: "Use the Terminal Toolbar?")
    }

    private var resetMessage: String {
        context == .terminal
            ? String(localized: "This will restore the default key layout. Custom keys stay available from each row's + button.")
            : String(localized: "This removes this toolbar's own layout. It will show the Terminal toolbar again.")
    }
}
