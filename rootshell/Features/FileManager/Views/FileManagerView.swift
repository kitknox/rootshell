//
//  FileManagerView.swift
//  rootshell
//
//  The file manager's content, shared by the sidebar, the HUD overlay and
//  the iPhone sheet. Layout follows the space it gets: two panes side by
//  side when wide, one pane with a switcher when narrow.
//

import SwiftUI
import QuickLook

struct FileManagerView: View {
    enum Style {
        case sidebar
        case overlay
        case full
        case sheet

        var presentation: PanelPresentation? {
            switch self {
            case .sidebar: .sidebar
            case .overlay: .overlay
            case .full: .full
            case .sheet: nil
            }
        }
    }

    @Bindable var manager: FileManagerModel
    let style: Style
    /// False while hidden, so no field reclaims the keyboard.
    let canFocus: Bool
    let onClose: () -> Void
    /// Switches between presentations; nil where only one presentation exists.
    let onSwitchPresentation: ((PanelPresentation) -> Void)?
    /// A side rail carries the touch actions: the window's rail, or the sheet's own.
    var actionsInRail = false

    @State private var highlightsShortcutsTip = false
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    private static let dualPaneMinWidth: CGFloat = 640
    private static let detailedColumnsMinPaneWidth: CGFloat = 520

    var body: some View {
        GeometryReader { geometry in
            let dual = geometry.size.width >= Self.dualPaneMinWidth
            let paneWidth = dual ? geometry.size.width / 2 : geometry.size.width
            let chrome = self.chrome
            VStack(spacing: 0) {
                if chrome == .pointer {
                    header
                    Divider()
                } else if !(dual && chrome == .rail) {
                    // The rail holds every header action; one pane still needs its switcher.
                    touchHeader(dual: dual, chrome: chrome)
                    Divider()
                }
                if dual {
                    HStack(spacing: 0) {
                        paneView(.left, width: paneWidth, chrome: chrome, dual: true)
                        Divider()
                        paneView(.right, width: paneWidth, chrome: chrome, dual: true)
                    }
                } else {
                    if chrome == .pointer {
                        paneSwitcher
                        Divider()
                    }
                    paneView(manager.activeSide, width: paneWidth, chrome: chrome, dual: false)
                }
                ActiveEditsBarView(manager: manager)
                TransferQueueView(manager: manager)
                if chrome == .touch && !dual {
                    Divider()
                    FileManagerTouchBar(manager: manager)
                } else if chrome == .pointer || KeyboardTracker.shared.isHardwareKeyboard {
                    hintBar
                }
            }
        }
        // The sidebar paints its own themed fill; the iPhone sheet needs one here.
        .background(style == .sheet ? sheetThemeColors?.background.ignoresSafeArea() : nil)
        .sheet(item: sheetBinding) { sheet in sheetContent(sheet).themedSubSheet(sheetThemeColors) }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button(String(localized: "Delete", comment: "File manager: confirm delete"), role: .destructive) {
                if case .confirmDelete(let entries) = manager.sheet { manager.delete(entries) }
                manager.sheet = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) { manager.sheet = nil }
        } message: {
            Text("This can't be undone.")
        }
        .background {
            // Separate hosts so an auth prompt or conflict can appear over a user sheet.
            Color.clear
                .sheet(item: promptBinding) { request in
                    FileManagerPromptSheet(request: request, prompts: manager.prompts)
                        .themedSubSheet(sheetThemeColors)
                }
            Color.clear
                .sheet(item: conflictBinding) { question in
                    TransferConflictSheet(question: question)
                        .themedSubSheet(sheetThemeColors)
                }
            Color.clear
                .sheet(item: externalExportBinding) { request in
                    ExternalEditExportPicker(
                        stagedURL: request.stagedURL,
                        onPicked: { url in manager.completeExternalExport(request, destinationURL: url) },
                        onCancel: { manager.cancelExternalExport(request) }
                    )
                }
            Color.clear
                .sheet(item: activityShareBinding) { request in
                    ExternalFileActivitySheet(urls: request.urls)
                }
            #if targetEnvironment(macCatalyst)
            Color.clear
                .sheet(item: externalAppPickerBinding) { request in
                    ExternalAppPickerSheet(
                        onPicked: { appURL in
                            manager.externalAppPickerRequest = nil
                            switch request {
                            case .openFile(let entry, let endpoint):
                                manager.editExternally(entry, on: endpoint, appURL: appURL)
                            case .setDefault:
                                ExternalEditorBridge.setPreferredEditorApp(appURL)
                            }
                        },
                        onCancel: { manager.externalAppPickerRequest = nil }
                    )
                }
            #endif
        }
        .hostKeyPromptAlerts(manager.prompts.hostKey)
        .quickLookPreview(previewBinding)
        .alert(String(localized: "File Manager", comment: "File manager error alert title"), isPresented: errorBinding) {
            Button(String(localized: "OK", comment: "OK button")) { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? "")
        }
        .onAppear(perform: appeared)
        .onChange(of: chrome == .pointer, initial: true) { _, pointer in
            // The keyboard layout has no Done; a held Select mode would eat every click.
            guard pointer else { return }
            manager.left.isSelecting = false
            manager.right.isSelecting = false
        }
        .onChange(of: manager.sheet == nil) { _, dismissed in
            // Hand the keyboard back to the list after any sheet closes.
            if dismissed { manager.requestFocus() }
        }
    }

    private var hasPresentedSheet: Bool {
        #if targetEnvironment(macCatalyst)
        if manager.externalAppPickerRequest != nil { return true }
        #endif
        return manager.sheet != nil
            || manager.externalExportRequest != nil
            || manager.activityShareRequest != nil
    }

    private var chrome: FileManagerChrome {
        if actionsInRail { return .rail }
        return FileManagerInput.usesPointerSemantics ? .pointer : .touch
    }

    private func paneView(_ side: FilePaneModel.Side, width: CGFloat, chrome: FileManagerChrome, dual: Bool) -> some View {
        FilePaneView(
            pane: manager.pane(side),
            manager: manager,
            isActive: manager.activeSide == side,
            canFocus: canFocus && !hasPresentedSheet,
            columns: width >= Self.detailedColumnsMinPaneWidth ? .detailed : .compact,
            otherPaneName: manager.pane(side.other).endpoint.displayName,
            chrome: chrome,
            // One touch pane names its location in the switcher above it.
            showsEndpoint: dual || chrome == .pointer,
            // Side by side, each pane carries its own bar so it is clear which one it moves.
            showsTouchBar: dual && chrome == .touch,
            onClose: onClose
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { manager.activeSide = side })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape").foregroundStyle(Color.accentColor)
            Text("Files").font(.headline)
            Spacer()
            if let onSwitchPresentation, let current = style.presentation {
                PanelPresentationMenu(current: current, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            FileManagerMoreMenu(manager: manager)
                .equatable()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .help(String(localized: "Close (esc)", comment: "File manager close button tooltip"))
            .accessibilityLabel(String(localized: "Close File Manager", comment: "File manager close button"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Touch: one pane's switcher doubles as the title row. Buttons get 44pt hit areas.
    private func touchHeader(dual: Bool, chrome: FileManagerChrome) -> some View {
        HStack(spacing: 2) {
            if dual {
                Image(systemName: "folder.badge.gearshape").foregroundStyle(Color.accentColor)
                Text("Files").font(.headline)
                Spacer(minLength: 4)
            } else {
                touchPaneSwitcher
            }
            if chrome == .touch {
                if let onSwitchPresentation, let current = style.presentation {
                    PanelPresentationMenu(current: current, onSwitch: onSwitchPresentation, touchSized: true)
                        .equatable()
                }
                FileManagerMoreMenu(manager: manager, touchSized: true)
                    .equatable()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                        .panelTouchTarget()
                }
                .accessibilityLabel(String(localized: "Close File Manager", comment: "File manager close button"))
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, dual ? 14 : 10)
        .padding(.trailing, chrome == .touch ? 4 : 10)
        .padding(.vertical, chrome == .touch ? 0 : 2)
    }

    /// Tapping the other pane switches to it; tapping the current one picks its location.
    private var touchPaneSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(FilePaneModel.Side.allCases, id: \.self) { side in
                let pane = manager.pane(side)
                let isActive = manager.activeSide == side
                Button {
                    if isActive {
                        manager.sheet = .connect(side)
                    } else {
                        manager.activeSide = side
                        manager.requestFocus()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(verbatim: side == .left ? "A" : "B").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(pane.endpoint.displayName).lineLimit(1)
                        if pane.isBusy { ProgressView().controlSize(.mini) }
                        if isActive {
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pane.endpoint.displayName)
                .accessibilityHint(isActive
                    ? String(localized: "Chooses this pane's location", comment: "File manager pane switcher hint")
                    : String(localized: "Shows this pane", comment: "File manager pane switcher hint"))
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Panes", comment: "File manager pane switcher"))
    }

    // MARK: - Single-pane switcher

    private var paneSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(FilePaneModel.Side.allCases, id: \.self) { side in
                let pane = manager.pane(side)
                Button {
                    manager.activeSide = side
                    manager.requestFocus()
                } label: {
                    HStack(spacing: 4) {
                        Text(side == .left ? "A" : "B").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(pane.endpoint.displayName).lineLimit(1)
                        if pane.isBusy { ProgressView().controlSize(.mini) }
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(manager.activeSide == side ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Panes", comment: "File manager pane switcher"))
    }

    // MARK: - Hint bar

    @ViewBuilder
    private var hintBar: some View {
        if KeyboardTracker.shared.isHardwareKeyboard {
            let hints = FileManagerShortcut.hints(
                hasSelection: !manager.activePane.selection.isEmpty,
                queueFocused: manager.queueFocused
            )
            let all = FileManagerShortcut.shortcut(for: .showShortcuts)
            ViewThatFits(in: .horizontal) {
                hintRow(hints, all: all, count: hints.count)
                hintRow(hints, all: all, count: 3)
                hintRow(hints, all: all, count: 1)
                hintRow(hints, all: all, count: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.primary.opacity(0.03))
        } else {
            Text(String(localized: "Long-press for actions · Select to pick several", comment: "File manager touch hint"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        }
    }

    private func hintRow(_ hints: [FileManagerShortcut], all: FileManagerShortcut, count: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(hints.prefix(count).enumerated()), id: \.offset) { _, hint in
                KeyHintBadge(key: hint.glyph, label: hint.title, compact: true)
            }
            Spacer(minLength: 0)
            Button { manager.sheet = .shortcuts } label: {
                KeyHintBadge(key: all.glyph, label: all.title, compact: true)
                    .padding(.horizontal, 4)
                    .background(highlightsShortcutsTip ? Color.accentColor.opacity(0.25) : .clear, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Sheets

    private var sheetBinding: Binding<FileManagerModel.Sheet?> {
        Binding(
            get: {
                if case .confirmDelete = manager.sheet { return nil }
                return manager.sheet
            },
            set: { manager.sheet = $0 }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { if case .confirmDelete = manager.sheet { true } else { false } },
            set: { if !$0 { manager.sheet = nil } }
        )
    }

    private var deleteTitle: String {
        guard case .confirmDelete(let entries) = manager.sheet else { return "" }
        return entries.count == 1
            ? String(localized: "Delete “\(entries[0].name)”?", comment: "File manager delete confirmation; argument is a file name")
            : String(localized: "Delete \(entries.count) items?", comment: "File manager delete confirmation; argument is an item count")
    }

    private var promptBinding: Binding<FileManagerPrompts.Request?> {
        Binding(get: { manager.prompts.current }, set: { if $0 == nil { manager.prompts.respond(.cancelled) } })
    }

    private var conflictBinding: Binding<FileTransferCenter.ConflictQuestion?> {
        Binding(get: { FileTransferCenter.shared.pendingConflict }, set: { if $0 == nil { FileTransferCenter.shared.cancelConflict() } })
    }

    private var externalExportBinding: Binding<FileManagerModel.ExternalExportRequest?> {
        Binding(
            get: { manager.externalExportRequest },
            set: { newValue in
                if newValue == nil, let existing = manager.externalExportRequest {
                    manager.cancelExternalExport(existing)
                }
            }
        )
    }

    private var activityShareBinding: Binding<FileManagerModel.ActivityShareRequest?> {
        Binding(get: { manager.activityShareRequest }, set: { manager.activityShareRequest = $0 })
    }

    #if targetEnvironment(macCatalyst)
    private var externalAppPickerBinding: Binding<FileManagerModel.ExternalAppPickerRequest?> {
        Binding(get: { manager.externalAppPickerRequest }, set: { manager.externalAppPickerRequest = $0 })
    }
    #endif

    private var previewBinding: Binding<URL?> {
        Binding(get: { manager.previewRequest?.url }, set: { if $0 == nil { manager.previewRequest = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { manager.errorMessage != nil }, set: { if !$0 { manager.errorMessage = nil } })
    }

    @ViewBuilder
    private func sheetContent(_ sheet: FileManagerModel.Sheet) -> some View {
        let dismiss = { manager.sheet = nil }
        switch sheet {
        case .connect(let side):
            EndpointPickerSheet(manager: manager, side: side, onDismiss: dismiss)
        case .goToPath:
            FileNameEntrySheet(
                title: FileManagerShortcut.shortcut(for: .goToPath).title,
                actionTitle: String(localized: "Go", comment: "File manager: go to folder"),
                initialText: manager.activePane.path,
                placeholder: String(localized: "Path, ~ for home", comment: "File manager go-to placeholder"),
                onSubmit: { path in
                    dismiss()
                    Task { await manager.activePane.goTo(path) }
                },
                onCancel: dismiss
            )
        case .rename(let entry):
            FileNameEntrySheet(
                title: FileManagerShortcut.shortcut(for: .rename).title,
                actionTitle: String(localized: "Rename", comment: "File manager rename button"),
                initialText: entry.name,
                placeholder: String(localized: "Name", comment: "File manager name placeholder"),
                onSubmit: { name in
                    dismiss()
                    Task { await manager.rename(entry, to: name) }
                },
                onCancel: dismiss
            )
        case .newFolder:
            FileNameEntrySheet(
                title: manager.createsBucket
                    ? String(localized: "New Bucket", comment: "File manager: create a storage bucket")
                    : FileManagerShortcut.shortcut(for: .newFolder).title,
                actionTitle: String(localized: "Create", comment: "File manager create folder button"),
                initialText: "",
                placeholder: manager.createsBucket
                    ? String(localized: "Bucket name", comment: "File manager new bucket placeholder")
                    : String(localized: "Folder name", comment: "File manager new folder placeholder"),
                onSubmit: { name in
                    dismiss()
                    Task { await manager.createFolder(named: name) }
                },
                onCancel: dismiss
            )
        case .info(let entry):
            if manager.activePane.endpoint.storageProvider != nil, !entry.isDirectory {
                StorageObjectInfoSheet(entry: entry, pane: manager.activePane, onDismiss: dismiss)
            } else {
                FileInfoSheet(
                    entry: entry,
                    endpointName: manager.activePane.endpoint.displayName,
                    onApplyPermissions: { mode in manager.setPermissions(mode, for: [entry]) },
                    onDismiss: dismiss
                )
            }
        case .edit(let request):
            RemoteFileEditorView(
                request: request,
                onOpenExternal: { appURL in
                    manager.editExternally(request.entry, on: request.endpoint, appURL: appURL)
                },
                onOpenEmbedded: manager.openInEmbeddedEditor != nil ? { editor in
                    manager.editInEmbeddedEditor(request.entry, on: request.endpoint, editor: editor)
                } : nil,
                onQuickLook: {
                    manager.preview(request.entry, on: request.endpoint)
                },
                onDismiss: dismiss
            )
        case .shareLink(let entry):
            StorageShareLinkSheet(entry: entry, pane: manager.activePane, onDismiss: dismiss)
        case .incompleteUploads(let entry):
            StorageIncompleteUploadsSheet(bucket: entry.name, pane: manager.activePane, onDismiss: dismiss)
        case .shortcuts:
            FileManagerShortcutsSheet(onDismiss: dismiss)
        case .confirmDelete:
            EmptyView()
        }
    }

    // MARK: - Lifecycle

    private func appeared() {
        manager.activatePendingRestores()
        guard KeyboardTracker.shared.isHardwareKeyboard else { return }
        manager.requestFocus()
        if !SettingsStore.shared.get(Settings.Transfer.fileManagerShortcutsTipShown) {
            SettingsStore.shared.set(Settings.Transfer.fileManagerShortcutsTipShown, true)
            withAnimation(.easeInOut(duration: 0.3)) { highlightsShortcutsTip = true }
            Task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeInOut(duration: 0.6)) { highlightsShortcutsTip = false }
            }
        }
    }
}

/// Equatable owner for the overflow menu, same contract as the presentation
/// menu. The items read live pane/transfer state in their own child scope.
struct FileManagerMoreMenu: View, Equatable {
    let manager: FileManagerModel
    var touchSized = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.manager === rhs.manager && lhs.touchSized == rhs.touchSized
    }

    var body: some View {
        Menu {
            FileManagerMoreMenuItems(manager: manager)
        } label: {
            // Titled, so the rail's overflow can name it.
            Label(String(localized: "More", comment: "File manager overflow menu"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .panelTouchTarget(touchSized)
        }
        .accessibilityLabel(String(localized: "More", comment: "File manager overflow menu"))
    }
}

/// The ⋯ menu, also a pane's background context menu (`side` set: acts on that pane).
struct FileManagerMoreMenuItems: View {
    let manager: FileManagerModel
    var side: FilePaneModel.Side? = nil

    var body: some View {
        let pane = side.map { manager.pane($0) } ?? manager.activePane
        Button { activate(); manager.perform(.paste) } label: {
            Label(FileManagerShortcut.shortcut(for: .paste).title, systemImage: "doc.on.clipboard")
        }
        .disabled(pane.path.isEmpty)
        Button { activate(); manager.sheet = .newFolder } label: {
            Label(FileManagerShortcut.shortcut(for: .newFolder).title, systemImage: "folder.badge.plus")
        }
        .disabled(pane.path.isEmpty)
        Button { activate(); manager.sheet = .goToPath } label: {
            Label(FileManagerShortcut.shortcut(for: .goToPath).title, systemImage: "arrow.right.circle")
        }
        if manager.openInTerminal != nil, !pane.path.isEmpty, pane.endpoint.supportsTerminal {
            Button { activate(); manager.perform(.openInTerminal) } label: {
                Label(FileManagerShortcut.shortcut(for: .openInTerminal).title, systemImage: "terminal")
            }
        }
        Divider()
        Toggle(isOn: Binding(get: { pane.showHidden }, set: { _ in manager.perform(.toggleHidden) })) {
            Label(FileManagerShortcut.shortcut(for: .toggleHidden).title, systemImage: "eye")
        }
        Picker(selection: Binding(get: { pane.sortOrder }, set: { pane.sortOrder = $0 })) {
            Text("Name").tag(RFSortOrder.nameAsc)
            Text("Size").tag(RFSortOrder.sizeDesc)
            Text("Date Modified").tag(RFSortOrder.modifiedDesc)
            Text("Kind").tag(RFSortOrder.typeAsc)
        } label: {
            Label(String(localized: "Sort By", comment: "File manager sort menu"), systemImage: "arrow.up.arrow.down")
        }
        Menu {
            Picker(selection: Binding(
                get: {
                    let stored = SettingsStore.shared.value(Settings.Transfer.fileManagerEditorPreference)
                    #if targetEnvironment(macCatalyst)
                    return stored.resolved(isMacCatalyst: true)
                    #else
                    return stored.resolved(isMacCatalyst: false)
                    #endif
                },
                set: { SettingsStore.shared.set(Settings.Transfer.fileManagerEditorPreference, $0) }
            )) {
                ForEach(FileManagerEditorPreference.platformCases, id: \.self) { pref in
                    Text(pref.title).tag(pref)
                }
            } label: {
                Text("Open Text Files In", comment: "File manager editor preference menu")
            }
            #if targetEnvironment(macCatalyst)
            Divider()
            let currentApp = ExternalEditorBridge.preferredEditorApp
            Button {
                manager.externalAppPickerRequest = .setDefault
            } label: {
                if let currentApp {
                    Label(String(localized: "External Editor: \(currentApp.name)…", comment: "File manager choose external editor"), systemImage: "app.badge")
                } else {
                    Label(String(localized: "Choose External Editor…", comment: "File manager choose external editor"), systemImage: "app.badge")
                }
            }
            if currentApp != nil {
                Button(String(localized: "Use System Default Editor", comment: "File manager reset external editor")) {
                    ExternalEditorBridge.setPreferredEditorApp(nil)
                }
            }
            #endif
        } label: {
            Label(String(localized: "Editor", comment: "File manager editor settings submenu"), systemImage: "square.and.pencil")
        }
        Divider()
        if pane.endpoint.canUseSudo {
            Button { activate(); manager.setSudo(true, on: pane) } label: {
                Label(String(localized: "Browse as Root (sudo)", comment: "File manager: reopen the pane's server through sudo"), systemImage: "lock.shield")
            }
        } else if pane.endpoint.isSudo {
            Button { activate(); manager.setSudo(false, on: pane) } label: {
                Label(String(localized: "Exit sudo", comment: "File manager: go back to browsing as the login user"), systemImage: "lock.open")
            }
        }
        if !pane.endpoint.isLocal {
            Button {
                // The login connection; its sudo connection closes with it.
                FileConnectionPool.shared.disconnect(pane.endpoint.withoutSudo)
                pane.connect(to: .local)
            } label: {
                Label(String(localized: "Disconnect", comment: "File manager: close the pane's connection"), systemImage: "bolt.horizontal.circle")
            }
        }
        if FileTransferCenter.shared.jobs.contains(where: { $0.state.isFinished }) {
            Button { FileTransferCenter.shared.clearFinished() } label: {
                Label(String(localized: "Clear Finished Transfers", comment: "File manager menu"), systemImage: "checklist")
            }
        }
        Button { manager.sheet = .shortcuts } label: {
            Label(FileManagerShortcut.shortcut(for: .showShortcuts).title, systemImage: "keyboard")
        }
    }

    private func activate() {
        if let side { manager.activeSide = side }
    }
}
