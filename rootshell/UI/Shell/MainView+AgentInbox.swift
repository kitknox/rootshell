//
//  MainView+AgentInbox.swift
//  rootshell
//
//  Presents the agent inbox like the file manager and HTTP capture: a
//  resizable column beside the terminal, a HUD over it (floating or covering
//  it), or a sheet on iPhone. The three panels share the trailing slot.
//

import SwiftUI
import UIKit

extension MainView {
    var agentInboxShowsSidebar: Bool {
        showAgentInbox && !isPhone && agentInboxPresentation == .sidebar
    }

    /// The floating or full-size HUD.
    var agentInboxShowsOverlay: Bool {
        showAgentInbox && !isPhone && agentInboxPresentation != .sidebar
    }

    /// The HUD and the iPhone sheet own the keyboard; the sidebar shares the window with the terminal.
    var agentInboxOwnsKeyboard: Bool {
        showAgentInbox && (isPhone || agentInboxPresentation.ownsKeyboard)
    }

    var agentInboxSidebarCurrentWidth: CGFloat {
        agentInboxShowsSidebar ? agentInboxSidebarWidth : 0
    }

    // MARK: - Toggle

    func toggleAgentInbox() {
        if showAgentInbox {
            closeAgentInbox()
        } else {
            openAgentInbox()
        }
    }

    func openAgentInbox() {
        guard !showAgentInbox else { return }
        showThemePickerOverlay = false
        showClipboardManager = false
        showQuickSettingsOverlay = false
        showOpenInFolderOverlay = false
        showIPLookup = false
        // The floating tab sidebar / Exposé can still be up when the island's
        // URL arrives (it is an overlay, not a sheet). Every other overlay here
        // dismisses it before taking the screen — the inbox did not, so an
        // island tap with the switcher up put the inbox *behind* it and looked
        // like "the inbox sent me into tab expose".
        if showingTabSwitcher && !tabSidebarIsDocked {
            showingTabSwitcher = false
        }
        yieldPanelSlotToAgentInbox(agentInboxPresentation)

        if isPhone {
            resignFirstResponderForSheetPresentation()
        } else if agentInboxPresentation == .sidebar {
            scheduleTerminalRelayout()
        }
        showAgentInbox = true
        if agentInboxOwnsKeyboard { setOverlayOwnsKeyboardForAllTerminals(true) }
    }

    func closeAgentInbox() {
        guard showAgentInbox else { return }
        let wasSidebar = agentInboxShowsSidebar
        showAgentInbox = false
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
        if wasSidebar {
            if terminals.indices.contains(selectedTabIndex) {
                _ = terminals[selectedTabIndex].focusedTerminal?.becomeFirstResponder()
            }
            scheduleTerminalRelayout()
        } else {
            restoreFirstResponderAfterSheetDismissal()
        }
    }

    func switchAgentInboxPresentation(_ presentation: PanelPresentation) {
        guard presentation != agentInboxPresentation else { return }
        yieldPanelSlotToAgentInbox(presentation)
        agentInboxPresentation = presentation
        SettingsStore.shared.set(Settings.AgentInbox.presentation, presentation)
        setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented || agentInboxOwnsKeyboard)
        scheduleTerminalRelayout()
    }

    /// The inbox is about to show as `presentation`: hide a file manager or
    /// HTTP capture panel holding that spot.
    private func yieldPanelSlotToAgentInbox(_ presentation: PanelPresentation) {
        guard !isPhone else { return }
        if showFileManager, fileManagerPresentation.sharesSlot(with: presentation) {
            closeFileManager()
        }
        #if !CHINA_BUILD
        if showHTTPCapture, httpCapturePresentation.sharesSlot(with: presentation) {
            closeHTTPCapture()
        }
        #endif
    }

    /// Another panel is about to show as `presentation`: hide the inbox if it holds that spot.
    func yieldAgentInboxSlot(to presentation: PanelPresentation) {
        guard !isPhone, showAgentInbox, agentInboxPresentation.sharesSlot(with: presentation) else { return }
        closeAgentInbox()
    }

    /// The island asked for the inbox. Only the active window answers, and a
    /// sheet in the way is closed first.
    func consumePendingAgentInboxOpen() {
        guard AgentInboxRouter.shared.pendingOpen, isActiveSceneForAgentInbox else { return }
        AgentInboxRouter.shared.pendingOpen = false
        guard !showAgentInbox else { return }
        if isSheetPresentedBesidesFloatingTabSidebar {
            showSettings = false
            showConnectionSidebar = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                openAgentInbox()
            }
        } else {
            openAgentInbox()
        }
    }

    private var isActiveSceneForAgentInbox: Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard scenes.count > 1 else { return true }
        return scenes.first { $0.session.persistentIdentifier == windowSceneSessionID }?
            .activationState == .foregroundActive
    }

    // MARK: - Views

    @ViewBuilder
    func agentInboxSidebarColumn(width: CGFloat, totalWidth: CGFloat) -> some View {
        if agentInboxShowsSidebar {
            AgentInboxSidebarView(
                width: $agentInboxSidebarWidth,
                isDragging: $agentInboxSidebarIsDragging,
                totalWidth: totalWidth,
                theme: resolvedSheetTheme(),
                onClose: { closeAgentInbox() },
                onSwitchPresentation: { switchAgentInboxPresentation($0) }
            )
            .frame(width: width)
            .transition(.move(edge: .trailing))
        }
    }

    /// `fullSize` picks the full-size panel's layer or the floating one.
    @ViewBuilder
    func agentInboxOverlays(fullSize: Bool) -> some View {
        if agentInboxShowsOverlay, (agentInboxPresentation == .full) == fullSize {
            AgentInboxHUD(
                fills: fullSize,
                theme: resolvedSheetTheme(),
                onClose: { closeAgentInbox() },
                onSwitchPresentation: { switchAgentInboxPresentation($0) },
                integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabHeader ? integratedTabJoin : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A fresh host per presentation; the HUD host sets up dragging and resizing once.
            .id(agentInboxPresentation)
        }
    }

    func agentInboxPhoneSheetModifier(sheetTheme: ResolvedSheetTheme) -> AgentInboxPhoneSheetModifier {
        AgentInboxPhoneSheetModifier(
            isPresented: Binding(
                get: { showAgentInbox && isPhone },
                set: { if !$0 { closeAgentInbox() } }
            ),
            sheetTheme: sheetTheme,
            onClose: { closeAgentInbox() }
        )
    }
}
