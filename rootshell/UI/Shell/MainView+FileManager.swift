//
//  MainView+FileManager.swift
//  rootshell
//
//  Presents the file manager: a resizable column beside the terminal, a HUD
//  over it (floating or covering it), or a sheet on iPhone. The window's model is created on first use
//  and kept while hidden, so reopening restores panes, selection and focus.
//

import SwiftUI

extension MainView {
    var fileManagerShowsSidebar: Bool {
        showFileManager && !isPhone && fileManagerPresentation == .sidebar && fileManagerModel != nil
    }

    /// The floating or full-size HUD.
    var fileManagerShowsOverlay: Bool {
        showFileManager && !isPhone && fileManagerPresentation != .sidebar && fileManagerModel != nil
    }

    /// Full size and the iPhone sheet cover the terminal and own the keyboard. The
    /// sidebar and the floating HUD share it: a click or tap picks the terminal or the panel.
    var fileManagerOwnsKeyboard: Bool {
        showFileManager && (isPhone || fileManagerPresentation == .full)
    }

    /// The window's side rail carries the open panel's touch actions (Duo's inner display).
    var fileManagerActionsInRail: Bool {
        showsDuoSideRail && (fileManagerShowsSidebar || fileManagerShowsOverlay)
    }

    var fileManagerSidebarCurrentWidth: CGFloat {
        fileManagerShowsSidebar ? fileManagerSidebarWidth : 0
    }

    // MARK: - Toggle

    /// First press opens; with the sidebar or floating HUD open but the terminal
    /// typing, a press moves focus into the manager; otherwise it closes.
    func toggleFileManager() {
        if showFileManager {
            if !fileManagerOwnsKeyboard, KeyboardTracker.shared.isHardwareKeyboard, !fileManagerFieldFocused,
               fileManagerModel?.hasKeyboardTarget == true {
                focusedTerminalForFileManager?.resignFirstResponder()
                fileManagerModel?.requestFocus()
            } else {
                closeFileManager()
            }
            return
        }
        openFileManager()
    }

    private var fileManagerFieldFocused: Bool {
        guard let window = focusedTerminalForFileManager?.window else { return false }
        return DraggableHUDHostView.ownsFirstResponder(in: window)
    }

    private var focusedTerminalForFileManager: Ghostty.TerminalView? {
        guard terminals.indices.contains(selectedTabIndex) else { return nil }
        return terminals[selectedTabIndex].focusedTerminal
    }

    func openFileManager() {
        let model = fileManagerModel ?? makeFileManagerModel()
        fileManagerModel = model
        if let terminal = focusedTerminalForFileManager {
            let source = FileEndpoint.PaneSource(terminal: terminal, openInFolderTarget: captureOpenInFolderTarget())
            let directory = terminal.pwd.flatMap { $0.hasPrefix("/") ? $0 : nil }
            model.present(from: source, directory: directory)
        }
        revealFileManager(model)
    }

    /// Opens (or retargets) the manager on `endpoint`, reusing a pane already on that file system.
    func openFileManager(at endpoint: FileEndpoint, presentation: PanelPresentation?) {
        let model = fileManagerModel ?? makeFileManagerModel()
        fileManagerModel = model
        // Asked to browse somewhere: show the list, not whichever editor tab was last up.
        model.showFiles()
        if let existing = [model.left, model.right].first(where: { $0.endpoint.sharesFileSystem(with: endpoint) }) {
            model.activeSide = existing.id
        } else {
            let side: FilePaneModel.Side = endpoint.isLocal ? .left : .right
            model.pane(side).connect(to: endpoint)
            model.activeSide = side
        }

        if let presentation, !isPhone, presentation != fileManagerPresentation {
            if showFileManager {
                switchFileManagerPresentation(presentation)
                return
            }
            fileManagerPresentation = presentation
            SettingsStore.shared.set(Settings.Transfer.fileManagerPresentation, presentation)
        }
        if showFileManager {
            model.requestFocus()
        } else {
            revealFileManager(model)
        }
    }

    private func revealFileManager(_ model: FileManagerModel) {
        // Floating tools yield first, as they do for Open in Folder.
        showThemePickerOverlay = false
        showClipboardManager = false
        showQuickSettingsOverlay = false
        showOpenInFolderOverlay = false
        showIPLookup = false
        #if !CHINA_BUILD
        yieldSlotToFileManager(fileManagerPresentation)
        #endif
        yieldAgentInboxSlot(to: fileManagerPresentation)
        yieldGitDiffSlot(to: fileManagerPresentation)

        if isPhone {
            resignFirstResponderForSheetPresentation()
        } else if fileManagerPresentation != .full {
            // Shared keyboard: the panel takes it now, as the gate does for full size.
            if KeyboardTracker.shared.isHardwareKeyboard { focusedTerminalForFileManager?.resignFirstResponder() }
            if fileManagerPresentation == .sidebar { scheduleTerminalRelayout() }
        }
        showFileManager = true
        if fileManagerOwnsKeyboard { setOverlayOwnsKeyboardForAllTerminals(true) }
        model.requestFocus()
    }

    func closeFileManager() {
        guard showFileManager else { return }
        let wasSidebar = fileManagerShowsSidebar
        let ownedKeyboard = fileManagerOwnsKeyboard
        showFileManager = false
        fileManagerModel?.save()
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
        if !ownedKeyboard {
            _ = focusedTerminalForFileManager?.becomeFirstResponder()
            if wasSidebar { scheduleTerminalRelayout() }
        } else {
            restoreFirstResponderAfterSheetDismissal()
        }
    }

    func switchFileManagerPresentation(_ presentation: PanelPresentation) {
        guard presentation != fileManagerPresentation else { return }
        // Every way into full size (menu, rail, zoom button) records where to return.
        if presentation == .full { fileManagerModel?.presentationBeforeZoom = fileManagerPresentation }
        #if !CHINA_BUILD
        yieldSlotToFileManager(presentation)
        #endif
        yieldAgentInboxSlot(to: presentation)
        yieldGitDiffSlot(to: presentation)
        fileManagerPresentation = presentation
        SettingsStore.shared.set(Settings.Transfer.fileManagerPresentation, presentation)
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented || fileManagerOwnsKeyboard)
        scheduleTerminalRelayout()
        fileManagerModel?.requestFocus()
    }

    func scheduleTerminalRelayout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .terminalLayoutInvalidation, object: nil)
        }
    }

    private func makeFileManagerModel() -> FileManagerModel {
        let model = FileManagerModel()
        model.openInTerminal = { endpoint, directory in
            openTerminal(at: directory, on: endpoint)
        }
        #if !targetEnvironment(macCatalyst)
        model.openInEmbeddedEditor = { filePath, editor in
            openEmbeddedEditor(filePath: filePath, editor: editor)
        }
        #endif
        return model
    }

    #if !targetEnvironment(macCatalyst)
    private func openEmbeddedEditor(filePath: String, editor: FileManagerEmbeddedEditor) -> Bool {
        guard ghosttyApp.app != nil else { return false }
        createFileEditorTab(filePath: filePath, editor: editor.command)
        if !fileManagerShowsSidebar {
            closeFileManager()
        }
        return true
    }
    #endif

    /// "Open in Terminal": a new tab (or the user's last Open in Folder placement)
    /// in `directory` on the pane's connection.
    private func openTerminal(at directory: String, on endpoint: FileEndpoint) -> Bool {
        let opened: Bool
        switch endpoint {
        case .local:
            openConnectionTab(.local(workingDirectory: directory), sourceProfileID: nil)
            opened = true
        case .pane(let source):
            if let target = source.openInFolderTarget {
                opened = openInFolder(target, directory: directory, placement: OpenInFolderRecentsStore.placement)
            } else if let profileID = source.fallbackProfileID {
                opened = openProfile(profileID, at: directory)
            } else {
                opened = false
            }
        case .profile(let id):
            opened = openProfile(id, at: directory)
        case .storage:
            opened = false
        case .sudo(let base):
            return openTerminal(at: directory, on: base)
        }
        if opened { closeFileManager() }
        return opened
    }

    private func openProfile(_ id: UUID, at directory: String) -> Bool {
        guard var profile = ConnectionProfileManager.shared.profile(for: id) else { return false }
        profile.sshConfig.initialDirectory = directory
        connectToProfile(profile, splitOption: .newTab)
        return true
    }

    // MARK: - Views

    /// The docked column, placed beside the AI sidebar when both are open.
    @ViewBuilder
    func fileManagerSidebarColumn(width: CGFloat, totalWidth: CGFloat, bottomClearance: CGFloat = 0) -> some View {
        if fileManagerShowsSidebar, let model = fileManagerModel {
            FileManagerSidebarView(
                manager: model,
                width: $fileManagerSidebarWidth,
                isDragging: $fileManagerSidebarIsDragging,
                totalWidth: totalWidth,
                canFocus: showFileManager,
                theme: resolvedSheetTheme(),
                actionsInRail: fileManagerActionsInRail,
                bottomClearance: bottomClearance,
                onClose: { closeFileManager() },
                onSwitchPresentation: { switchFileManagerPresentation($0) }
            )
            .frame(width: width)
            .transition(.move(edge: .trailing))
        }
    }

    /// The HUD and, while the manager is hidden, the transfer progress pill.
    /// `fullSize` picks the full-size panel's layer or the floating one.
    @ViewBuilder
    func fileManagerOverlays(fullSize: Bool) -> some View {
        if fileManagerShowsOverlay, (fileManagerPresentation == .full) == fullSize, let model = fileManagerModel {
            FileManagerHUD(
                manager: model,
                fills: fullSize,
                canFocus: showFileManager,
                theme: resolvedSheetTheme(),
                onClose: { closeFileManager() },
                onSwitchPresentation: { switchFileManagerPresentation($0) },
                integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabs ? integratedTabJoin : nil,
                actionsInRail: fileManagerActionsInRail
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A fresh host per presentation; the HUD host sets up dragging and resizing once.
            .id(fileManagerPresentation)
        }
        if !fullSize, !showFileManager {
            TransferPill(manager: fileManagerModel, onOpen: { openFileManager() })
                .padding(.bottom, 16 + pillKeyboardLift(above: focusedTerminalForFileManager))
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .animation(
                    .snappy,
                    value: FileTransferCenter.shared.hasActiveJobs
                        || RemoteFileEditCenter.shared.hasActiveUploads
                        || RemoteFileEditCenter.shared.hasAttentionItems
                )
        }
    }

    /// iPhone presentation, kept out of the long sheet chain in applySheetModifiers.
    func fileManagerPhoneSheetModifier(sheetTheme: ResolvedSheetTheme) -> FileManagerPhoneSheetModifier {
        FileManagerPhoneSheetModifier(
            isPresented: Binding(
                get: { showFileManager && isPhone },
                set: { if !$0 { closeFileManager() } }
            ),
            model: fileManagerModel,
            sheetTheme: sheetTheme,
            onClose: { closeFileManager() }
        )
    }
}

struct FileManagerPhoneSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let model: FileManagerModel?
    let sheetTheme: ResolvedSheetTheme
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let model {
                PanelSheetNavigation {
                    PanelSideRailReader { inRail in
                        FileManagerView(
                            manager: model,
                            style: .sheet,
                            canFocus: isPresented,
                            onClose: onClose,
                            onSwitchPresentation: nil,
                            actionsInRail: inRail
                        )
                        .modifier(FileManagerSheetRail(active: inRail, manager: model, onClose: onClose))
                    }
                }
                .presentationDetents([.large])
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
        }
    }
}
