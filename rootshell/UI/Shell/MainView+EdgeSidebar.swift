//
//  MainView+EdgeSidebar.swift
//  rootshell
//
//  Opens each tool from its assigned edge. One tool per edge is visible;
//  the bottom selector switches between the tools assigned to that edge.
//

import SwiftUI
import os

extension MainView {
    var edgeSidebarAssignment: EdgeSidebarAssignment {
        EdgeSidebarAssignment.decode(edgeSidebarPageSides)
    }

    func selectedEdgePage(on side: EdgeSidebarSide) -> EdgeSidebarPage? {
        let pages = edgeSidebarAssignment.pages(on: side)
        if let page = edgeSidebarSelectedPage[side], pages.contains(page) {
            return page
        }
        return pages.first
    }

    /// The file manager is inside an edge sidebar, not the overlay or the full-size panel.
    var fileManagerUsesEdgeSidebar: Bool {
        #if os(visionOS)
        return false
        #else
        return isPhone || fileManagerPresentation == .sidebar
        #endif
    }

    func edgeSidebarPageIsOpen(_ page: EdgeSidebarPage) -> Bool {
        switch page {
        case .tabSwitcher:
            return showingTabSwitcher
        case .fileManager:
            return showFileManager
        case .httpCapture:
            #if !CHINA_BUILD
            return showHTTPCapture
            #else
            return false
            #endif
        case .aiAgent:
            #if !CHINA_BUILD
            guard terminals.indices.contains(selectedTabIndex) else { return false }
            return isPhone ? showAIAgentOverlay : shouldShowAISidebar(currentTabId: terminals[selectedTabIndex].id)
            #else
            return false
            #endif
        case .clipboardManager: return showClipboardManager
        case .connections: return showConnectionSidebar
        case .themePicker: return showThemePickerOverlay
        case .quickSettings: return showQuickSettingsOverlay
        case .openInFolder: return showOpenInFolderOverlay
        case .ipLookup: return showIPLookup
        case .dictation: return showDictationHUD
        }
    }

    func edgeSidebarUsesDrawer(_ page: EdgeSidebarPage) -> Bool {
        #if os(visionOS)
        return false
        #else
        switch page {
        case .tabSwitcher: return !tabSidebarUsesDockedPresentation
        case .fileManager, .httpCapture, .aiAgent: return isPhone
        default: return true
        }
        #endif
    }

    func edgeSidebarSideIsOpen(_ side: EdgeSidebarSide) -> Bool {
        edgeSidebarAssignment.pages(on: side).contains(where: edgeSidebarPageIsOpen)
    }

    /// Floating drawer for this edge. A pinned tab sidebar is a column instead.
    /// On iPad the file manager's own column is not a drawer.
    func floatingEdgeSidebarPresented(_ side: EdgeSidebarSide) -> Bool {
        guard let page = selectedEdgePage(on: side), edgeSidebarPageIsOpen(page) else { return false }
        return edgeSidebarUsesDrawer(page)
    }

    /// A floating drawer on this edge tracks the finger. A docked column and
    /// a file manager HUD open without tracking.
    func edgeTracksFinger(_ side: EdgeSidebarSide) -> Bool {
        guard let page = selectedEdgePage(on: side) else { return false }
        return page != .dictation && edgeSidebarUsesDrawer(page)
    }

    func canOpenEdgeSidebar(_ side: EdgeSidebarSide) -> Bool {
        guard !edgeSidebarAssignment.pages(on: side).isEmpty else { return false }
        guard !edgeSidebarSideIsOpen(side) else { return false }
        guard !floatingEdgeSidebarPresented(side.opposite) else { return false }
        return !edgeSidebarModalPresented
    }

    func defersEdgeSidebarGesture(_ side: EdgeSidebarSide) -> Bool {
        #if os(visionOS)
        return false
        #else
        guard UIDevice.current.userInterfaceIdiom == .phone || UIDevice.current.userInterfaceIdiom == .pad else { return false }
        guard !edgeSidebarAssignment.pages(on: side).isEmpty else { return false }
        if floatingEdgeSidebarPresented(side) { return true }
        return canOpenEdgeSidebar(side)
        #endif
    }

    func openEdgeSidebar(_ side: EdgeSidebarSide) {
        guard let page = selectedEdgePage(on: side) else { return }
        Ghostty.logger.info("Edge sidebar swipe side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    func toggleEdgeSidebarSide(_ side: EdgeSidebarSide) {
        if edgeSidebarSideIsOpen(side) {
            Ghostty.logger.info("Edge sidebar button close side=\(side.rawValue, privacy: .public)")
            closeEdgeSidebar(side)
            return
        }
        guard let page = selectedEdgePage(on: side) else { return }
        Ghostty.logger.info("Edge sidebar button open side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    var edgeSidebarHeaderButtonWidth: CGFloat {
        var count = 0
        if !edgeSidebarAssignment.pages(on: .leading).isEmpty { count += 1 }
        if !edgeSidebarAssignment.pages(on: .trailing).isEmpty { count += 1 }
        return CGFloat(count) * TabMetrics.tabBarHeight
    }

    func toggleEdgeSidebarPage(_ page: EdgeSidebarPage) {
        let side = edgeSidebarAssignment.side(of: page)
        if edgeSidebarPageIsOpen(page) {
            Ghostty.logger.info("Edge sidebar close side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
            closeEdgeSidebar(side)
            return
        }
        Ghostty.logger.info("Edge sidebar open page=\(page.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    func adoptEdgeSidebarPage(_ page: EdgeSidebarPage) {
        let side = edgeSidebarAssignment.side(of: page)
        if isPhone || floatingEdgeSidebarPresented(side.opposite) {
            closeEdgeSidebar(side.opposite)
        }
        for other in edgeSidebarAssignment.pages(on: side) where other != page {
            closeEdgeSidebarPage(other)
        }
        edgeSidebarSelectedPage[side] = page
        if edgeSidebarUsesDrawer(page) { resignFirstResponderForSheetPresentation() }
        Ghostty.logger.info("Edge sidebar adopt window=\(windowId, privacy: .public) side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
    }

    func openEdgeSidebarPage(_ page: EdgeSidebarPage) {
        guard EdgeSidebarPage.availableCases.contains(page) else { return }
        switch page {
        case .tabSwitcher:
            adoptEdgeSidebarPage(page)
            if showSettings { showSettings = false }
            if !showingTabSwitcher { showingTabSwitcher = true }
        case .fileManager:
            if !showFileManager {
                openFileManager()
            } else {
                adoptEdgeSidebarPage(page)
                fileManagerModel?.requestFocus()
            }
        case .httpCapture:
            #if !CHINA_BUILD
            if !showHTTPCapture { openHTTPCapture() }
            #else
            break
            #endif
        case .aiAgent:
            #if !CHINA_BUILD
            if !edgeSidebarPageIsOpen(page) { toggleAIAgent() }
            #endif
        case .clipboardManager:
            if !showClipboardManager { toggleClipboardManager() }
        case .connections:
            if !showConnectionSidebar { addNewTab() }
        case .themePicker:
            if !showThemePickerOverlay { toggleThemePicker() }
        case .quickSettings:
            if !showQuickSettingsOverlay { toggleQuickSettings() }
        case .openInFolder:
            if !showOpenInFolderOverlay { toggleOpenInFolder() }
        case .ipLookup:
            if !showIPLookup { toggleIPLookup() }
        case .dictation:
            #if canImport(FluidAudio) && !CHINA_BUILD
            if !showDictationHUD, DictationSupport.isEnabled { toggleDictationHUD(from: nil) }
            #endif
        }
    }

    func closeEdgeSidebar(_ side: EdgeSidebarSide) {
        for page in edgeSidebarAssignment.pages(on: side) {
            closeEdgeSidebarPage(page)
        }
    }

    private func closeEdgeSidebarPage(_ page: EdgeSidebarPage) {
        switch page {
        case .tabSwitcher:
            showingTabSwitcher = false
        case .fileManager:
            closeFileManager()
        case .httpCapture:
            #if !CHINA_BUILD
            closeHTTPCapture()
            #else
            break
            #endif
        case .aiAgent:
            #if !CHINA_BUILD
            guard edgeSidebarPageIsOpen(.aiAgent) else { return }
            showAIAgentOverlay = false
            if terminals.indices.contains(selectedTabIndex) {
                let id = terminals[selectedTabIndex].id
                aiAgentSidebarVisibleTabs.remove(id)
                aiAgentSessions[id]?.cancel()
            }
            #endif
        case .clipboardManager: showClipboardManager = false
        case .connections: showConnectionSidebar = false
        case .themePicker: showThemePickerOverlay = false
        case .quickSettings: showQuickSettingsOverlay = false
        case .openInFolder: showOpenInFolderOverlay = false
        case .ipLookup: showIPLookup = false
        case .dictation: showDictationHUD = false
        }
    }

    private func edgeSidebarPageBinding(_ page: EdgeSidebarPage) -> Binding<Bool> {
        Binding(get: { edgeSidebarPageIsOpen(page) }, set: { if !$0 { closeEdgeSidebarPage(page) } })
    }

    func selectEdgeSidebarPage(_ page: EdgeSidebarPage) {
        let side = edgeSidebarAssignment.side(of: page)
        guard selectedEdgePage(on: side) != page || !edgeSidebarPageIsOpen(page) else { return }
        Ghostty.logger.info("Edge sidebar select page=\(page.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    /// Width of docked columns on the leading edge. Overlays that center on the terminal use this.
    func leadingChromeWidth(windowWidth: CGFloat) -> CGFloat {
        leadingWidth(in: terminalRowColumns(width: windowWidth))
    }

    func trailingChromeWidth(windowWidth: CGFloat) -> CGFloat {
        let columns = terminalRowColumns(width: windowWidth)
        return columns.aiSidebar + columns.docked + columns.fileManager + columns.httpCapture + columns.agentInbox - leadingWidth(in: columns)
    }

    func leadingWidth(in columns: TerminalRowColumns) -> CGFloat {
        var width: CGFloat = 0
        if edgeSidebarAssignment.side(of: .tabSwitcher) == .leading { width += columns.docked }
        if edgeSidebarAssignment.side(of: .fileManager) == .leading { width += columns.fileManager }
        if edgeSidebarAssignment.side(of: .httpCapture) == .leading { width += columns.httpCapture }
        if edgeSidebarAssignment.side(of: .aiAgent) == .leading { width += columns.aiSidebar }
        return width
    }

    @ViewBuilder
    func edgeSidebarBody(
        side: EdgeSidebarSide,
        sheetTheme: ResolvedSheetTheme,
        isDocked: Bool,
        dockedBottomClearance: CGFloat
    ) -> some View {
        let pages = edgeSidebarAssignment.pages(on: side)
        let selected = selectedEdgePage(on: side) ?? pages.first
        VStack(spacing: 0) {
            Group {
                if let selected {
                    edgeSidebarPage(selected, sheetTheme: sheetTheme, isDocked: isDocked, side: side)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let selected {
                EdgeSidebarTabBar(pages: pages, selection: selected, onSelect: selectEdgeSidebarPage)
            }
        }
        .padding(.bottom, dockedBottomClearance)
        .environmentObject(ghosttyApp)
        .fileManagerTheme(sheetTheme)
    }

    private func edgeSidebarPage(
        _ page: EdgeSidebarPage,
        sheetTheme: ResolvedSheetTheme,
        isDocked: Bool,
        side: EdgeSidebarSide
    ) -> AnyView {
        switch page {
        case .tabSwitcher:
            return AnyView(verticalTabSidebarContent(
                sheetTheme: sheetTheme,
                isDocked: isDocked,
                dockedBottomClearance: 0
            ))
        case .fileManager:
            if isPhone, let model = fileManagerModel {
                return AnyView(FileManagerView(
                    manager: model,
                    style: .sidebar,
                    canFocus: showFileManager,
                    onClose: { closeEdgeSidebar(side) },
                    onSwitchPresentation: isPhone ? nil : { switchFileManagerPresentation($0) }
                )
                .fileManagerTheme(sheetTheme))
            }
            return AnyView(EmptyView())
        case .httpCapture:
            #if !CHINA_BUILD
            if isPhone, let model = httpCaptureModel {
                return AnyView(HTTPCaptureView(
                    model: model,
                    style: .sidebar,
                    onClose: { closeEdgeSidebar(side) },
                    onSwitchPresentation: nil
                )
                .fileManagerTheme(sheetTheme))
            }
            #endif
            return AnyView(EmptyView())
        case .aiAgent:
            #if !CHINA_BUILD
            if isPhone, let session = currentAIAgentSession(), terminals.indices.contains(selectedTabIndex) {
                return AnyView(AIAgentOverlayView(
                    isPresented: edgeSidebarPageBinding(page), session: session,
                    tabID: terminals[selectedTabIndex].id
                ))
            }
            #endif
            return AnyView(EmptyView())
        case .clipboardManager:
            return AnyView(ClipboardManagerOverlay(
                style: .sidebar, isPresented: edgeSidebarPageBinding(page),
                keyboardMode: $clipboardManagerKeyboardMode, pasteHandler: pasteFromClipboardManager
            ))
        case .connections:
            return AnyView(connectionSheetContent)
        case .themePicker:
            return AnyView(ThemePickerOverlay(
                isPresented: edgeSidebarPageBinding(page), windowId: windowId,
                currentTabId: tabsModel.selectedTabID, onThemeSelected: handleThemePickerSelection,
                fillsSidebar: true
            ))
        case .quickSettings:
            return AnyView(QuickSettingsHUD(isPresented: edgeSidebarPageBinding(page), inSidebar: true))
        case .openInFolder:
            if let model = openInFolderModel {
                return AnyView(GeometryReader { geometry in
                    OpenInFolderOverlay(
                        model: model, isPresented: edgeSidebarPageBinding(page), shortcut: openInFolderShortcut,
                        onOpen: { openInFolder(model.target, directory: $0, placement: $1) },
                        width: geometry.size.width, height: geometry.size.height
                    )
                })
            }
            return AnyView(EmptyView())
        case .ipLookup:
            if let model = ipLookupModel {
                return AnyView(GeometryReader { geometry in
                    IPLookupOverlay(model: model, isPresented: edgeSidebarPageBinding(page), width: geometry.size.width)
                })
            }
            return AnyView(EmptyView())
        case .dictation:
            #if canImport(FluidAudio) && !CHINA_BUILD
            return AnyView(GeometryReader { geometry in
                DictationPanel(isPresented: edgeSidebarPageBinding(page), target: { dictationTarget }, width: geometry.size.width)
            })
            #else
            return AnyView(EmptyView())
            #endif
        }
    }

    func edgeSidebarModifier(side: EdgeSidebarSide, sheetTheme: ResolvedSheetTheme) -> some ViewModifier {
        TabSidebarModifier(
            edge: side == .leading ? .leading : .trailing,
            preventDismissal: selectedEdgePage(on: side) == .connections && terminals.isEmpty,
            showSidebar: Binding(
                get: { floatingEdgeSidebarPresented(side) },
                set: { newValue in if !newValue { closeEdgeSidebar(side) } }
            ),
            themeColors: sheetTheme.themeColors,
            accentColor: sheetTheme.accentColor,
            colorScheme: sheetTheme.colorScheme,
            sidebarContent: {
                edgeSidebarBody(
                    side: side,
                    sheetTheme: sheetTheme,
                    isDocked: false,
                    dockedBottomClearance: 0
                )
            }
        )
    }

}
