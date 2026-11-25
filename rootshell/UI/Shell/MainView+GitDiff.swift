//
//  MainView+GitDiff.swift
//  rootshell
//
//  Presents the git diff panel like the other trailing panels: a resizable
//  column beside the terminal, a HUD over it (floating or covering it), or a
//  sheet on iPhone. The overlay and the iPhone presentation also collapse to
//  a summary pill. Only the full-size panel and the sheet take the keyboard;
//  the floating HUD and the pill leave it with the terminal.
//

import SwiftUI
import UIKit

extension MainView {
    /// The pill stands in for the floating HUD, and for the sheet on iPhone.
    private var gitDiffCollapses: Bool {
        isPhone || gitDiffPresentation == .overlay
    }

    var gitDiffShowsPill: Bool {
        showGitDiff && gitDiffStore != nil && gitDiffCollapses && gitDiffCollapsed
    }

    var gitDiffShowsSidebar: Bool {
        showGitDiff && gitDiffStore != nil && !isPhone && gitDiffPresentation == .sidebar
    }

    /// The floating or full-size HUD.
    var gitDiffShowsOverlay: Bool {
        showGitDiff && gitDiffStore != nil && !isPhone && gitDiffPresentation != .sidebar && !gitDiffShowsPill
    }

    private var gitDiffShowsSheet: Bool {
        showGitDiff && isPhone && !gitDiffCollapsed
    }

    /// Only a presentation that covers the terminal takes the keyboard.
    var gitDiffOwnsKeyboard: Bool {
        gitDiffShowsSheet || (gitDiffShowsOverlay && gitDiffPresentation == .full)
    }

    /// The window's side rail carries the expanded panel's actions (Duo's inner display).
    /// An open file manager has the rail first.
    var gitDiffActionsInRail: Bool {
        showsDuoSideRail && !fileManagerActionsInRail && (gitDiffShowsSidebar || gitDiffShowsOverlay)
    }

    var gitDiffSidebarCurrentWidth: CGFloat {
        gitDiffShowsSidebar ? gitDiffSidebarWidth : 0
    }

    /// The pane the panel follows: the focused terminal of the visible tab.
    private var gitDiffTerminal: Ghostty.TerminalView? {
        terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].focusedTerminal : nil
    }

    // MARK: - Toggle

    func toggleGitDiff() {
        if showGitDiff {
            closeGitDiff()
        } else {
            openGitDiff()
        }
    }

    func openGitDiff() {
        guard !showGitDiff else { return }
        if gitDiffStore == nil { gitDiffStore = GitDiffStore() }
        if !(gitDiffCollapses && gitDiffCollapsed) {
            prepareForExpandedGitDiff(gitDiffPresentation)
        }
        showGitDiff = true
        if gitDiffOwnsKeyboard { setOverlayOwnsKeyboardForAllTerminals(true) }
    }

    func closeGitDiff() {
        guard showGitDiff else { return }
        let wasSidebar = gitDiffShowsSidebar
        let ownedKeyboard = gitDiffOwnsKeyboard
        showGitDiff = false
        gitDiffStore?.setActive(false, wantsPatch: false)
        if wasSidebar {
            scheduleTerminalRelayout()
        } else if ownedKeyboard {
            setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
            restoreFirstResponderAfterSheetDismissal()
        }
    }

    /// Shrinks the overlay to its pill, or opens it back up.
    func setGitDiffCollapsed(_ collapsed: Bool) {
        guard collapsed != gitDiffCollapsed else { return }
        let ownedKeyboard = gitDiffOwnsKeyboard
        if !collapsed { prepareForExpandedGitDiff(gitDiffPresentation) }
        gitDiffCollapsed = collapsed
        SettingsStore.shared.set(Settings.GitDiff.collapsed, collapsed)
        if gitDiffOwnsKeyboard {
            setOverlayOwnsKeyboardForAllTerminals(true)
        } else if ownedKeyboard {
            setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
            restoreFirstResponderAfterSheetDismissal()
        }
    }

    func switchGitDiffPresentation(_ presentation: PanelPresentation) {
        guard presentation != gitDiffPresentation else { return }
        let ownedKeyboard = gitDiffOwnsKeyboard
        yieldPanelSlotToGitDiff(presentation)
        gitDiffPresentation = presentation
        SettingsStore.shared.set(Settings.GitDiff.presentation, presentation)
        if gitDiffOwnsKeyboard {
            setOverlayOwnsKeyboardForAllTerminals(true)
        } else if ownedKeyboard {
            setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
            restoreFirstResponderAfterSheetDismissal()
        }
        scheduleTerminalRelayout()
    }

    /// The panel is about to show expanded: clear what would sit under or over it.
    private func prepareForExpandedGitDiff(_ presentation: PanelPresentation) {
        if showingTabSwitcher && !tabSidebarIsDocked {
            showingTabSwitcher = false
        }
        yieldPanelSlotToGitDiff(presentation)
        if isPhone {
            resignFirstResponderForSheetPresentation()
        } else if presentation == .sidebar {
            scheduleTerminalRelayout()
        }
    }

    /// Hides a panel holding the spot the diff is about to take.
    private func yieldPanelSlotToGitDiff(_ presentation: PanelPresentation) {
        guard !isPhone else { return }
        if showFileManager, fileManagerPresentation.sharesSlot(with: presentation) {
            closeFileManager()
        }
        if showAgentInbox, agentInboxPresentation.sharesSlot(with: presentation) {
            closeAgentInbox()
        }
        #if !CHINA_BUILD
        if showHTTPCapture, httpCapturePresentation.sharesSlot(with: presentation) {
            closeHTTPCapture()
        }
        #endif
    }

    /// Another panel is about to show as `presentation`: make room. The diff
    /// is a companion, so a floating one shrinks to its pill instead of closing.
    func yieldGitDiffSlot(to presentation: PanelPresentation) {
        guard !isPhone, showGitDiff, !gitDiffShowsPill,
              gitDiffPresentation.sharesSlot(with: presentation) else { return }
        if gitDiffPresentation == .overlay {
            setGitDiffCollapsed(true)
        } else {
            closeGitDiff()
        }
    }

    // MARK: - Views

    @ViewBuilder
    func gitDiffSidebarColumn(width: CGFloat, totalWidth: CGFloat, bottomClearance: CGFloat = 0) -> some View {
        if gitDiffShowsSidebar, let store = gitDiffStore {
            GitDiffSidebarView(
                store: store,
                width: $gitDiffSidebarWidth,
                isDragging: $gitDiffSidebarIsDragging,
                totalWidth: totalWidth,
                theme: resolvedSheetTheme(),
                actionsInRail: gitDiffActionsInRail,
                bottomClearance: bottomClearance,
                onClose: { closeGitDiff() },
                onSwitchPresentation: { switchGitDiffPresentation($0) }
            )
            .modifier(GitDiffFollowModifier(store: store, terminal: gitDiffTerminal, wantsPatch: true))
            .frame(width: width)
            .transition(.move(edge: .trailing))
        }
    }

    /// `fullSize` picks the full-size panel's layer or the floating one,
    /// which also holds the pill.
    @ViewBuilder
    func gitDiffOverlays(fullSize: Bool) -> some View {
        if let store = gitDiffStore {
            if gitDiffShowsOverlay, (gitDiffPresentation == .full) == fullSize {
                GitDiffHUD(
                    store: store,
                    fills: fullSize,
                    theme: resolvedSheetTheme(),
                    onClose: { closeGitDiff() },
                    onCollapse: { setGitDiffCollapsed(true) },
                    onSwitchPresentation: { switchGitDiffPresentation($0) },
                    integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabs ? integratedTabJoin : nil,
                    actionsInRail: gitDiffActionsInRail
                )
                .modifier(GitDiffFollowModifier(store: store, terminal: gitDiffTerminal, wantsPatch: true))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A fresh host per presentation; the HUD host sets up dragging and resizing once.
                .id(gitDiffPresentation)
            } else if gitDiffShowsPill, !fullSize {
                GitDiffPillHUD(
                    store: store,
                    theme: resolvedSheetTheme(),
                    onExpand: { setGitDiffCollapsed(false) },
                    onClose: { closeGitDiff() }
                )
                .modifier(GitDiffFollowModifier(store: store, terminal: gitDiffTerminal, wantsPatch: false))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    func gitDiffPhoneSheetModifier(sheetTheme: ResolvedSheetTheme) -> GitDiffPhoneSheetModifier {
        GitDiffPhoneSheetModifier(
            isPresented: Binding(
                get: { gitDiffShowsSheet },
                // Swiping the sheet away leaves the summary pill, not nothing.
                set: { if !$0, gitDiffShowsSheet { setGitDiffCollapsed(true) } }
            ),
            store: gitDiffStore,
            terminal: gitDiffTerminal,
            sheetTheme: sheetTheme,
            onClose: { closeGitDiff() },
            onCollapse: { setGitDiffCollapsed(true) }
        )
    }
}
