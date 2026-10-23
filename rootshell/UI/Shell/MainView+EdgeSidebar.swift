//
//  MainView+EdgeSidebar.swift
//  rootshell
//
//  Opens the tab switcher and the file manager from the edge each one is
//  assigned to. Pages on the same edge share one panel and its tab bar.
//

import SwiftUI
import os

extension MainView {
    var edgeSidebarAssignment: EdgeSidebarAssignment {
        EdgeSidebarAssignment.decode(edgeSidebarPageSides)
    }

    func selectedEdgePage(on side: EdgeSidebarSide) -> EdgeSidebarPage? {
        let pages = edgeSidebarAssignment.pages(on: side)
        if let raw = edgeSidebarSelectedPage[side.rawValue],
           let page = EdgeSidebarPage(rawValue: raw),
           pages.contains(page) {
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
            return showFileManager && fileManagerUsesEdgeSidebar
        }
    }

    func edgeSidebarSideIsOpen(_ side: EdgeSidebarSide) -> Bool {
        edgeSidebarAssignment.pages(on: side).contains(where: edgeSidebarPageIsOpen)
    }

    /// Floating drawer for this edge. A pinned tab sidebar is a column instead.
    /// On iPad the file manager's own column is not a drawer.
    func floatingEdgeSidebarPresented(_ side: EdgeSidebarSide) -> Bool {
        guard edgeSidebarSideIsOpen(side) else { return false }
        if tabSidebarIsDocked && edgeSidebarAssignment.side(of: .tabSwitcher) == side { return false }
        if isPhone { return true }
        return edgeSidebarAssignment.side(of: .tabSwitcher) == side
    }

    func edgeOpensDocked(_ side: EdgeSidebarSide) -> Bool {
        if edgeSidebarAssignment.side(of: .tabSwitcher) == side && tabSidebarUsesDockedPresentation {
            return true
        }
        if !isPhone,
           edgeSidebarAssignment.side(of: .fileManager) == side,
           !edgeSidebarAssignment.sharesOneSide,
           fileManagerPresentation == .sidebar {
            return true
        }
        return false
    }

    /// A floating drawer on this edge tracks the finger. A docked column and
    /// a file manager HUD open without tracking.
    func edgeTracksFinger(_ side: EdgeSidebarSide) -> Bool {
        if edgeOpensDocked(side) { return false }
        if isPhone { return !edgeSidebarAssignment.pages(on: side).isEmpty }
        return edgeSidebarAssignment.side(of: .tabSwitcher) == side
    }

    func canOpenEdgeSidebar(_ side: EdgeSidebarSide) -> Bool {
        guard !edgeSidebarAssignment.pages(on: side).isEmpty else { return false }
        guard !edgeSidebarSideIsOpen(side) else { return false }
        // The other edge is already a floating drawer. A second drawer would cover it.
        if floatingEdgeSidebarPresented(side.opposite) { return false }
        if fileManagerOwnsKeyboard && !fileManagerUsesEdgeSidebar { return false }
        return !edgeSidebarModalPresented
    }

    func defersEdgeSidebarGesture(_ side: EdgeSidebarSide) -> Bool {
        #if os(visionOS)
        return false
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        guard !edgeSidebarAssignment.pages(on: side).isEmpty else { return false }
        if floatingEdgeSidebarPresented(side) { return true }
        return canOpenEdgeSidebar(side)
        #endif
    }

    func openEdgeSidebar(_ side: EdgeSidebarSide) {
        guard let page = preferredEdgeSidebarPage(on: side) else { return }
        Ghostty.logger.info("Edge sidebar swipe side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    func toggleEdgeSidebarSide(_ side: EdgeSidebarSide) {
        if edgeSidebarSideIsOpen(side) {
            Ghostty.logger.info("Edge sidebar button close side=\(side.rawValue, privacy: .public)")
            closeEdgeSidebar(side)
            return
        }
        guard let page = preferredEdgeSidebarPage(on: side) else { return }
        Ghostty.logger.info("Edge sidebar button open side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    func preferredEdgeSidebarPage(on side: EdgeSidebarSide) -> EdgeSidebarPage? {
        let pages = edgeSidebarAssignment.pages(on: side)
        let preferred = selectedEdgePage(on: side)
        return pages.first { $0 == preferred && edgePageOpensInSidebar($0) }
            ?? pages.first(where: edgePageOpensInSidebar)
            ?? preferred
            ?? pages.first
    }

    var edgeSidebarHeaderButtonWidth: CGFloat {
        var count = 0
        if !edgeSidebarAssignment.pages(on: .leading).isEmpty { count += 1 }
        if !edgeSidebarAssignment.pages(on: .trailing).isEmpty { count += 1 }
        return CGFloat(count) * TabMetrics.tabBarHeight
    }

    func toggleEdgeSidebarPage(_ page: EdgeSidebarPage) {
        let side = edgeSidebarAssignment.side(of: page)
        if edgeSidebarSideIsOpen(side), selectedEdgePage(on: side) == page {
            Ghostty.logger.info("Edge sidebar close side=\(side.rawValue, privacy: .public) page=\(page.rawValue, privacy: .public)")
            closeEdgeSidebar(side)
            return
        }
        Ghostty.logger.info("Edge sidebar open page=\(page.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    /// Puts the file manager on its edge. On iPhone the other edge closes.
    /// A shared edge keeps the tab switcher panel as the host.
    func adoptFileManagerEdge() {
        guard fileManagerUsesEdgeSidebar else { return }
        let side = edgeSidebarAssignment.side(of: .fileManager)
        if isPhone { closeEdgeSidebar(side.opposite) }
        edgeSidebarSelectedPage[side.rawValue] = EdgeSidebarPage.fileManager.rawValue
        if edgeSidebarAssignment.sharesOneSide {
            keepSharedEdgeSidebarHost(selecting: .fileManager)
        }
    }

    func openEdgeSidebarPage(_ page: EdgeSidebarPage) {
        let side = edgeSidebarAssignment.side(of: page)
        if isPhone { closeEdgeSidebar(side.opposite) }
        edgeSidebarSelectedPage[side.rawValue] = page.rawValue
        switch page {
        case .tabSwitcher:
            if edgeSidebarAssignment.sharesOneSide && fileManagerUsesEdgeSidebar {
                keepSharedEdgeSidebarHost(selecting: page)
            }
            if showSettings { showSettings = false }
            if !showingTabSwitcher { showingTabSwitcher = true }
        case .fileManager:
            if !fileManagerUsesEdgeSidebar {
                if !showFileManager { openFileManager() }
                return
            }
            if edgeSidebarAssignment.sharesOneSide {
                keepSharedEdgeSidebarHost(selecting: page)
            }
            if !showFileManager {
                openFileManager()
            } else {
                fileManagerModel?.requestFocus()
            }
        }
    }

    func closeEdgeSidebar(_ side: EdgeSidebarSide) {
        if edgeSidebarAssignment.side(of: .tabSwitcher) == side {
            showingTabSwitcher = false
        }
        if edgeSidebarAssignment.side(of: .fileManager) == side, showFileManager, fileManagerUsesEdgeSidebar {
            closeFileManager()
        }
    }

    func selectEdgeSidebarPage(_ page: EdgeSidebarPage) {
        let side = edgeSidebarAssignment.side(of: page)
        guard selectedEdgePage(on: side) != page || !edgeSidebarPageIsOpen(page) else { return }
        Ghostty.logger.info("Edge sidebar select page=\(page.rawValue, privacy: .public) side=\(side.rawValue, privacy: .public)")
        openEdgeSidebarPage(page)
    }

    /// Width of docked columns on the leading edge. Overlays that center on the terminal use this.
    func leadingChromeWidth(windowWidth: CGFloat) -> CGFloat {
        var width: CGFloat = 0
        if edgeSidebarAssignment.side(of: .tabSwitcher) == .leading {
            width += dockedTabSidebarWidth(windowWidth: windowWidth)
        }
        if edgeSidebarAssignment.side(of: .fileManager) == .leading {
            width += fileManagerSidebarCurrentWidth
        }
        return width
    }

    func trailingChromeWidth(windowWidth: CGFloat) -> CGFloat {
        var width = aiAgentSidebarCurrentWidth() + httpCaptureDockedWidth
        if edgeSidebarAssignment.side(of: .tabSwitcher) == .trailing {
            width += dockedTabSidebarWidth(windowWidth: windowWidth)
        }
        if edgeSidebarAssignment.side(of: .fileManager) == .trailing {
            width += fileManagerSidebarCurrentWidth
        }
        return width
    }

    func leadingWidth(in columns: TerminalRowColumns) -> CGFloat {
        var width: CGFloat = 0
        if edgeSidebarAssignment.side(of: .tabSwitcher) == .leading { width += columns.docked }
        if edgeSidebarAssignment.side(of: .fileManager) == .leading { width += columns.fileManager }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let selected {
                EdgeSidebarTabBar(pages: pages, selection: selected, onSelect: selectEdgeSidebarPage)
            }
        }
        .padding(.bottom, dockedBottomClearance)
        .environmentObject(ghosttyApp)
    }

    @ViewBuilder
    private func edgeSidebarPage(
        _ page: EdgeSidebarPage,
        sheetTheme: ResolvedSheetTheme,
        isDocked: Bool,
        side: EdgeSidebarSide
    ) -> some View {
        switch page {
        case .tabSwitcher:
            verticalTabSidebarContent(
                sheetTheme: sheetTheme,
                isDocked: isDocked,
                dockedBottomClearance: 0
            )
        case .fileManager:
            if hidesFileManagerPage(on: side, isDocked: isDocked) {
                EmptyView()
            } else if let model = fileManagerModel {
                FileManagerView(
                    manager: model,
                    style: .sidebar,
                    canFocus: showFileManager,
                    onClose: { closeEdgeSidebar(side) },
                    onSwitchPresentation: isPhone ? nil : { switchFileManagerPresentation($0) }
                )
                .fileManagerTheme(sheetTheme)
            }
        }
    }

    /// The file manager already has a column, or this overlay would copy the
    /// docked host. The floating drawer is the only overlay that shows it.
    private func hidesFileManagerPage(on side: EdgeSidebarSide, isDocked: Bool) -> Bool {
        if isDocked { return false }
        if fileManagerShowsSidebar && edgeSidebarAssignment.side(of: .fileManager) == side {
            return true
        }
        return tabSidebarIsDocked && edgeSidebarAssignment.side(of: .tabSwitcher) == side
    }

    private func edgePageOpensInSidebar(_ page: EdgeSidebarPage) -> Bool {
        switch page {
        case .tabSwitcher: true
        case .fileManager: fileManagerUsesEdgeSidebar
        }
    }

    func edgeSidebarModifier(side: EdgeSidebarSide, sheetTheme: ResolvedSheetTheme) -> some ViewModifier {
        TabSidebarModifier(
            edge: side == .leading ? .leading : .trailing,
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

    /// A shared edge uses the tab switcher's panel as the host for both pages.
    private func keepSharedEdgeSidebarHost(selecting page: EdgeSidebarPage) {
        edgeSidebarSelectedPage[edgeSidebarAssignment.side(of: page).rawValue] = page.rawValue
        if showSettings { showSettings = false }
        if !showingTabSwitcher { showingTabSwitcher = true }
    }
}
