//
//  MainView+Presentation.swift
//  rootshell
//
//  Scene/sheet modifier pipeline and sheet-presentation predicates for MainView.
//  Extracted from MainView.swift for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

extension MainView {

    // MARK: - Sheet Presentation Predicates

    private var pendingClosePaneExists: Bool {
        // Avoid observing every tab's split tree during ordinary rendering.
        // Topology changes matter here only while a confirmation is pending.
        guard pendingClosePaneID != nil else { return false }
        return PaneCloseConfirmationPolicy.targetExists(
            pendingID: pendingClosePaneID,
            livePaneIDs: terminals.flatMap { $0.splitTree.map(\.uuid) }
        )
    }

    private var pendingTabCloseExists: Bool {
        guard let id = pendingTabClose?.tabID else { return false }
        return terminals.contains { $0.id == id }
    }

    /// Which multiplexer the pending "Ask Each Time" tab belongs to, and
    /// whether it offers Hide Tab. (id=tmux-tab-close-action)
    private var pendingMuxCloseKind: MultiplexerCloseTabDialogModifier.Kind {
        guard let id = pendingMuxCloseTabID,
              let tab = terminals.first(where: { $0.id == id }) else { return .tmux(canHide: true) }
        if tab.isHerdrWindow { return .herdr }
        // Hiding an already-hidden tab is a no-op, and performTmuxClose(.hideTab)
        // would fall back to kill-window, turning a non-destructive choice destructive.
        return .tmux(canHide: !tab.isHiddenTmuxWindow)
    }

    private var voiceAgentPresentationDetents: Set<PresentationDetent> {
        UIDevice.current.userInterfaceIdiom == .phone ? [.large] : [.medium, .large]
    }

    /// Returns true if any sheet or overlay is currently presented
    /// Used to prevent focus restoration from showing keyboard over sheets
    var isAnySheetPresented: Bool {
        // The docked sidebar does NOT cover the terminal or own the
        // keyboard (the user types in the terminal beside it), so it must
        // not count as a presented sheet — otherwise the overlay-owns-
        // keyboard gate would refuse the terminal first responder.
        floatingEdgeSidebarPresented(.leading) || floatingEdgeSidebarPresented(.trailing) || isSheetPresentedBesidesFloatingTabSidebar
    }

    /// `isAnySheetPresented` without the floating tab sidebar, for things
    /// that work alongside it (its own rows' hover previews).
    var isSheetPresentedBesidesFloatingTabSidebar: Bool {
        edgeSidebarModalPresented || fileManagerOwnsKeyboard || httpCaptureHoldsKeyboard
    }

    /// Sheets that block an edge swipe. The file manager drawer is not one:
    /// on iPhone a swipe from the other edge closes it and opens that edge.
    var edgeSidebarModalPresented: Bool {
        let baseFlags = showSettings ||
            showToolbarSettings ||
            (showConnectionSidebar && !edgeSidebarUsesDrawer(.connections)) ||
            showPasswordPromptSheet ||
            showKeyboardInteractivePrompt ||
            showKeyResolutionSheet ||
            showYubiKeyPINPrompt ||
            (showThemePickerOverlay && !edgeSidebarUsesDrawer(.themePicker)) ||
            (showQuickSettingsOverlay && !edgeSidebarUsesDrawer(.quickSettings)) ||
            showKeyboardChooser ||
            (showOpenInFolderOverlay && !edgeSidebarUsesDrawer(.openInFolder)) ||
            (httpCaptureHoldsKeyboard && !isPhone) ||
            (fileManagerOwnsKeyboard && !fileManagerUsesEdgeSidebar) ||
            agentInboxOwnsKeyboard ||
            // The iPhone presentation is a sheet that owns the keyboard. On
            // regular width the clipboard manager is a passthrough glass HUD (like
            // the Find HUD, which is intentionally absent here) and must NOT count
            // — the terminal would surrender first responder with nothing to take
            // it, i.e. steal focus. The exception is keyboard mode, where the
            // HUD's search field is guaranteed to take focus (the toggle cycle
            // refuses keyboard mode while the disabled/locked pane is showing).
            (showClipboardManager && !edgeSidebarUsesDrawer(.clipboardManager) &&
                (UIDevice.current.userInterfaceIdiom == .phone || clipboardManagerKeyboardMode)) ||
            connectionInfoToShow != nil ||
            tmuxDashboardRequest != nil ||
            herdrDashboardRequest != nil ||
            pendingNewTabRequest != nil ||
            unavailableNewTabRequest != nil ||
            trzszTransferOriginRequest != nil ||
            trzszTransferIncomingOffer != nil
        #if !CHINA_BUILD
        return baseFlags || (showAIAgentOverlay && !edgeSidebarUsesDrawer(.aiAgent))
        #else
        return baseFlags
        #endif
    }

    // MARK: - View Modifiers

    // Stored once so body evaluations don't tear down and resubscribe (see NotificationHandlersModifier).
    #if os(visionOS)
    private static let toggleKeyboardToolbarPublisher = NotificationCenter.default.publisher(for: .toggleKeyboardToolbar)
    #endif
    private static let trzszTransferOfferPublisher = NotificationCenter.default.publisher(for: .trzszTransferOfferReceived)
    private static let trzszTransferLeafShouldRemovePublisher = NotificationCenter.default.publisher(for: .trzszTransferLeafShouldRemove)

    @ViewBuilder
    func applySceneModifiers<V: View>(_ view: V) -> some View {
#if targetEnvironment(macCatalyst)
        // hideWindowTitleBar also forces the top safe area ignored: with the
        // titlebar merely hidden (not removed) the OS may still report a top
        // inset, which would push content down and expose the window backdrop.
        view
            .modifier(TitlebarTabsModifier(isEnabled: usesTitlebarTabs || hideWindowTitleBar, fullScreenEnabled: false))
            .background(windowId == "visor" ? nil : CurrentWindowTitleAccessor(tabsModel: tabsModel))
#elseif !os(visionOS)
        view
            .modifier(TitlebarTabsModifier(isEnabled: usesTitlebarTabs, fullScreenEnabled: fullScreenModeEnabled))
            .background(windowId == "visor" ? nil : CurrentWindowTitleAccessor(tabsModel: tabsModel))
#else
        view
            .modifier(TitlebarTabsModifier(isEnabled: usesTitlebarTabs, fullScreenEnabled: false))
            .ornament(
                visibility: showKeyboardToolbar ? .visible : .hidden,
                attachmentAnchor: .scene(.bottom),
                contentAlignment: .center
            ) {
                KeyboardToolbarOrnament(
                    focusedTerminal: terminals.indices.contains(selectedTabIndex)
                        ? terminals[selectedTabIndex].focusedTerminal : nil,
                    isVisible: $showKeyboardToolbar
                )
            }
            .onReceive(Self.toggleKeyboardToolbarPublisher) { _ in
                showKeyboardToolbar.toggle()
            }
#endif
    }

    // Note: `allTabTitles` / `allTabRoamProtocols` moved into `TabBar`
    // (Views/TabBar.swift) so per-tab title and roam-protocol mutations
    // do not invalidate `MainView.body`.

    private func applyHerdrDashboard<V: View>(_ view: V) -> some View {
        view.sheet(item: $herdrDashboardRequest) { request in
            HerdrWorkspaceSheet(request: request)
        }
    }

    @ViewBuilder
    func applySheetModifiers<V: View>(_ view: V, sheetTheme: ResolvedSheetTheme) -> some View {
        let dashboardHost = applyHerdrDashboard(view)
        dashboardHost
            .modifier(SettingsSheetModifier(
                showSettings: $showSettings,
                settingsDestination: settingsDestination,
                onDismiss: {
                    settingsDestination = nil
                    flushPendingHTTPCaptureOpen()
                },
                openHTTPCapture: settingsOpenHTTPCapture,
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme
            ))
            #if os(visionOS)
            .modifier(TabSidebarModifier(
                showSidebar: Binding(
                    get: { showingTabSwitcher && !tabSidebarIsDocked },
                    set: { newValue in if !newValue { dismissTabSidebar() } }
                ),
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme,
                sidebarContent: { verticalTabSidebarContent(sheetTheme: sheetTheme, isDocked: false).environmentObject(ghosttyApp) }
            ))
            #else
            .modifier(edgeSidebarModifier(side: .leading, sheetTheme: sheetTheme))
            .modifier(edgeSidebarModifier(side: .trailing, sheetTheme: sheetTheme))
            #endif
            .sheet(isPresented: $showToolbarSettings) {
                NavigationStack {
                    KeyboardToolbarSettingsView()
                }
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            // Clipboard manager: compact-width presentation (iPhone). Regular
            // width mounts the draggable glass HUD in floatingHUDOverlays() instead.
            .sheet(isPresented: Binding(
                get: { showClipboardManager && !edgeSidebarUsesDrawer(.clipboardManager) && UIDevice.current.userInterfaceIdiom == .phone },
                set: { if !$0 { showClipboardManager = false } }
            )) {
                ClipboardManagerOverlay(
                    style: .sheet,
                    isPresented: $showClipboardManager,
                    keyboardMode: .constant(false),
                    pasteHandler: { text in pasteFromClipboardManager(text) }
                )
                .presentationDetents([.medium, .large])
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            // File manager: iPhone presentation. Larger screens use the sidebar or HUD.
            .modifier(fileManagerPhoneSheetModifier(sheetTheme: sheetTheme))
            .modifier(agentInboxPhoneSheetModifier(sheetTheme: sheetTheme))
            .sheet(item: $connectionInfoToShow) { info in
                ConnectionInfoSheet(info: info)
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            // Keep the dialog's view builder outside this large modifier chain.
            .modifier(CloseConfirmationDialogModifier(
                title: "Close Pane?",
                confirmTitle: "Close Pane",
                message: "Closing this pane will end its current session.",
                targetExists: pendingClosePaneExists,
                dismiss: { pendingClosePaneID = nil },
                confirm: { confirmPendingPaneClose() }
            ))
            .modifier(CloseConfirmationDialogModifier(
                title: "Close Tab?",
                confirmTitle: "Close Tab",
                message: "Closing this tab will end its session.",
                targetExists: pendingTabCloseExists,
                dismiss: { pendingTabClose = nil },
                confirm: { confirmPendingTabClose() }
            ))
            // Kept as a modifier: inlining another dialog here pushes this
            // chain past the type-checker's budget. (id=tmux-tab-close-action)
            .modifier(MultiplexerCloseTabDialogModifier(
                pendingTabID: $pendingMuxCloseTabID,
                kind: pendingMuxCloseKind,
                run: { action in runPendingMuxClose(action) }
            ))
            .confirmationDialog(
                "New Tab",
                isPresented: Binding(
                    get: { pendingNewTabRequest != nil },
                    set: { if !$0 { pendingNewTabRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingNewTabRequest
            ) { request in
                Button("Local Shell") {
                    pendingNewTabRequest = nil
                    createLocalShellTab(for: request)
                }
                .keyboardShortcut(.defaultAction)
                if let title = request.duplicateTitle {
                    Button(title) {
                        pendingNewTabRequest = nil
                        runNewTabDuplicate(request)
                    }
                }
                Button("Open Connections") {
                    pendingNewTabRequest = nil
                    addNewTab()
                }
                Button("Cancel", role: .cancel) { pendingNewTabRequest = nil }
                    .keyboardShortcut(.cancelAction)
            } message: { _ in
                Text("Choose what to open in a new tab.")
            }
            .alert(
                "Session Unavailable",
                isPresented: Binding(
                    get: { unavailableNewTabRequest != nil },
                    set: { if !$0 { unavailableNewTabRequest = nil } }
                ),
                presenting: unavailableNewTabRequest
            ) { request in
                Button("Local Shell") {
                    unavailableNewTabRequest = nil
                    createLocalShellTab(for: request)
                }
                Button("Open Connections") {
                    unavailableNewTabRequest = nil
                    addNewTab()
                }
                Button("Cancel", role: .cancel) { unavailableNewTabRequest = nil }
            } message: { _ in
                Text("The original tmux session is no longer available. Open a local shell or choose another connection.")
            }
            .sheet(item: $tmuxDashboardRequest) { request in
                TmuxSessionDashboardView(controller: request.controller)
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            .sheet(item: $trzszTransferOriginRequest) { request in
                TrzszTransferOriginSheet(
                    originator: request.originator,
                    displayName: request.displayName,
                    onDismiss: { trzszTransferOriginRequest = nil }
                )
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            .sheet(item: $trzszTransferIncomingOffer) { offer in
                TrzszTransferReceiveSheet(
                    offer: offer,
                    onAcceptedTab: { ticketID, displayName, host in
                        createTrzszTransferReceivedTab(
                            ticketID: ticketID,
                            displayName: displayName,
                            host: host
                        )
                    },
                    onDismiss: { trzszTransferIncomingOffer = nil }
                )
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            .onReceive(Self.trzszTransferOfferPublisher) { note in
                if let offer = note.object as? TrzszTransferReceiver.Offer {
                    trzszTransferIncomingOffer = offer
                }
            }
            .onReceive(Self.trzszTransferLeafShouldRemovePublisher) { note in
                guard let info = note.userInfo,
                      let tabId = info["tabId"] as? UUID,
                      let leafId = info["leafId"] as? UUID else { return }
                handleTrzszTransferLeafRemoval(tabId: tabId, leafId: leafId)
            }
            // The island's deep link can land before this window exists.
            .onChange(of: AgentInboxRouter.shared.pendingOpen, initial: true) { _, pending in
                if pending { consumePendingAgentInboxOpen() }
            }
            .modifier(ConnectionSidebarModifier(
                showSidebar: Binding(get: { showConnectionSidebar && !edgeSidebarUsesDrawer(.connections) }, set: { showConnectionSidebar = $0 }),
                contentID: AnyHashable(connectionSidebarInitialTab),
                preventDismissal: terminals.isEmpty,
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme,
                // onDismiss runs inside SwiftUI's presentation-state write; resigning
                // first responder there re-enters SheetBridge and traps.
                onSheetDismiss: { DispatchQueue.main.async { flushPendingFileManagerOpen() } },
                phoneContent: { connectionSheetContentForPhone },
                // Same SidePanelOverlay re-hosting as the tab sidebar above:
                // inject so @EnvironmentObject reads under this overlay can
                // never hit the missing-object trap. (The phone path is an
                // in-hierarchy sheet and inherits naturally.)
                sidebarContent: { connectionSheetContent.environmentObject(ghosttyApp) }
            ))
            .sheet(isPresented: $showPasswordPromptSheet) {
                if let profile = passwordPromptProfile {
                    PasswordPromptSheet(
                        host: profile.sshConfig.host,
                        port: profile.sshConfig.port,
                        username: profile.sshConfig.username,
                        onSubmit: { password, shouldSave in
                            handlePasswordSubmit(profile: profile, password: password, shouldSave: shouldSave)
                        },
                        onCancel: {
                            showPasswordPromptSheet = false
                            passwordPromptProfile = nil
                        }
                    )
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                }
            }
            .sheet(isPresented: $showKeyboardInteractivePrompt) {
                if let entry = keyboardInteractiveQueue.first {
                    KeyboardInteractivePromptView(
                        challenge: entry.challenge,
                        sessionLabel: entry.sessionLabel,
                        onSubmit: { responses in
                            respondToKeyboardInteractive(responses)
                        },
                        onCancel: {
                            respondToKeyboardInteractive(nil)
                        },
                        authBannerStates: entry.authBannerStates
                    )
                    // Force an explicit Submit/Cancel: a swipe-dismiss must still
                    // resume the continuation, so treat interactive dismissal as
                    // cancel via the same handler.
                    .interactiveDismissDisabled()
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                    .id(entry.id)
                }
            }
            .sheet(isPresented: $showAskpassPrompt) {
                if let request = askpassQueue.first {
                    RemoteAskpassPromptView(
                        request: request,
                        onSubmit: { value in respondToAskpass(id: request.id, value: value) },
                        onCancel: { respondToAskpass(id: request.id, value: nil) }
                    )
                    // Explicit Send/Cancel so the remote helper always gets an answer.
                    .interactiveDismissDisabled()
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                    .id(request.id)
                }
            }
            #if !CHINA_BUILD
            .modifier(AIAgentSheetModifier(
                showOverlay: Binding(get: { showAIAgentOverlay && !edgeSidebarUsesDrawer(.aiAgent) }, set: { showAIAgentOverlay = $0 }),
                session: currentAIAgentSession(),
                tabID: terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : UUID()
            ))
            .overlay(alignment: .topTrailing) {
                if let voiceSession = currentVoiceAgentSession(), voiceSession.state.isActive {
                    VoiceAgentPillView(
                        session: voiceSession,
                        onTap: {
                            resignFirstResponderForSheetPresentation()
                            showVoiceAgentExpanded = true
                        },
                        onClose: {
                            voiceSession.stop()
                            if terminals.indices.contains(selectedTabIndex) {
                                voiceAgentSessions.removeValue(forKey: terminals[selectedTabIndex].id)
                            }
                        }
                    )
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $showVoiceAgentExpanded) {
                if let voiceSession = currentVoiceAgentSession() {
                    VoiceAgentExpandedView(
                        session: voiceSession,
                        onCollapse: { showVoiceAgentExpanded = false },
                        onEnd: {
                            voiceSession.stop()
                            showVoiceAgentExpanded = false
                            if terminals.indices.contains(selectedTabIndex) {
                                voiceAgentSessions.removeValue(forKey: terminals[selectedTabIndex].id)
                            }
                        }
                    )
                    .presentationDetents(voiceAgentPresentationDetents)
                    .presentationDragIndicator(.visible)
                }
            }
            .onChange(of: currentVoiceAgentSession()?.pendingApproval?.id) { _, newValue in
                guard newValue != nil else { return }
                resignFirstResponderForSheetPresentation()
                showVoiceAgentExpanded = true
            }
            #endif
            .sheet(isPresented: $showKeyResolutionSheet) {
                if let config = keyResolutionConfig {
                    KeyResolutionSheet(
                        unresolvedKeys: keyResolutionUnresolvedKeys,
                        config: config,
                        profileID: keyResolutionProfileID,
                        connectionIdentity: keyResolutionConnectionIdentity,
                        onResolved: { resolvedConfig in
                            showKeyResolutionSheet = false
                            connectWithConfig(resolvedConfig, connectionProtocol: keyResolutionProtocol, splitOption: keyResolutionSplitOption, trzszTransportMode: keyResolutionTransportMode, trzszMTU: keyResolutionTrzszMTU, trzszPortMin: keyResolutionTrzszPortMin, trzszPortMax: keyResolutionTrzszPortMax, trzszServerPath: keyResolutionTrzszServerPath, sourceProfileID: keyResolutionProfileID)
                        },
                        onCancel: {
                            showKeyResolutionSheet = false
                        }
                    )
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                }
            }
            .sheet(isPresented: $showYubiKeyPINPrompt) {
                if let request = yubiKeyConnectionManager.pendingPINRequest {
                    YubiKeyPINPromptView(request: request) { pin in
                        yubiKeyConnectionManager.completePINRequest(with: pin)
                        showYubiKeyPINPrompt = false
                    } onCancel: {
                        yubiKeyConnectionManager.completePINRequest(with: nil)
                        showYubiKeyPINPrompt = false
                    }
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
                }
            }
            .onChange(of: yubiKeyConnectionManager.pendingPINRequest) { _, newValue in
                showYubiKeyPINPrompt = newValue != nil
            }
    }

    @ViewBuilder
    func applyOverlayChangeHandlers<V: View>(_ view: V) -> some View {
        view
            #if !CHINA_BUILD
            .onChange(of: showAIAgentOverlay) { _, newValue in
                handleAIAgentOverlayChange(newValue)
            }
            .onChange(of: aiAgentSidebarVisibleTabs) { oldValue, newValue in
                handleAIAgentSidebarVisibilityChange(oldValue: oldValue, newValue: newValue)
            }
            #endif
            .onChange(of: showSettings) { _, presented in
                if presented { showQuickSettingsOverlay = false; showOpenInFolderOverlay = false; showIPLookup = false }
            }
            .onChange(of: showClipboardManager) { _, presented in
                if presented { showQuickSettingsOverlay = false; showOpenInFolderOverlay = false; showIPLookup = false }
            }
            .onChange(of: showConnectionSidebar) { _, presented in
                if presented { showQuickSettingsOverlay = false; showOpenInFolderOverlay = false; showIPLookup = false }
            }
            .onChange(of: showIPLookup) { _, presented in
                guard !presented else { return }
                ipLookupModel?.end()
                ipLookupModel = nil
                // Passthrough HUD: hand the keyboard back if its field took it.
                restoreFirstResponderAfterHUDDismissal()
            }
            #if canImport(FluidAudio) && !CHINA_BUILD
            .onChange(of: showDictationHUD) { _, presented in
                guard !presented else { return }
                DictationController.shared.stop(ownedBy: DictationController.hudOwner)
                restoreFirstResponderAfterHUDDismissal()
            }
            #endif
            .onChange(of: showQuickSettingsOverlay) { _, presented in
                setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
                if !presented { restoreFirstResponderAfterSheetDismissal() }
            }
            .onChange(of: showOpenInFolderOverlay) { _, presented in
                setOverlayOwnsKeyboardForAllTerminals(isAnySheetPresented)
                if !presented {
                    openInFolderModel?.end()
                    openInFolderModel = nil
                    openInFolderShortcut = nil
                    restoreFirstResponderAfterSheetDismissal()
                }
            }
            .onChange(of: showThemePickerOverlay) { _, newValue in
                handleThemePickerOverlayChange(newValue)
            }
            .onChange(of: showingTabSwitcher) { _, newValue in
                NotificationCenter.default.post(
                    name: .tabSwitcherVisibilityChanged,
                    object: nil,
                    userInfo: ["visible": newValue]
                )
            }
    }

}

/// "Ask Each Time" close of a tmux or herdr control-mode tab: close on the
/// host, detach, detach and close the gateway, or (tmux) hide.
/// (id=tmux-tab-close-action)
private struct MultiplexerCloseTabDialogModifier: ViewModifier {
    enum Kind: Equatable {
        case tmux(canHide: Bool)
        case herdr
    }

    @Binding var pendingTabID: UUID?
    let kind: Kind
    let run: (MultiplexerTabCloseAction) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            kind == .herdr ? "Close herdr Tab" : "Close tmux Tab",
            isPresented: Binding(
                get: { pendingTabID != nil },
                set: { if !$0 { pendingTabID = nil } }
            ),
            titleVisibility: .visible
        ) {
            switch kind {
            case .tmux(let canHide):
                Button("Close tmux Window") { run(.closeWindow) }
                    .keyboardShortcut(.defaultAction)
                Button("Detach Session") { run(.detachSession) }
                Button("Detach Session & Close Gateway") { run(.detachSessionAndCloseGateway) }
                if canHide {
                    Button("Hide Tab") { run(.hideTab) }
                }
            case .herdr:
                Button("Close herdr Tab") { run(.closeWindow) }
                    .keyboardShortcut(.defaultAction)
                Button("Detach from herdr") { run(.detachSession) }
                Button("Detach & Close Gateway") { run(.detachSessionAndCloseGateway) }
            }
            Button("Cancel", role: .cancel) { pendingTabID = nil }
                .keyboardShortcut(.cancelAction)
        } message: {
            switch kind {
            case .tmux:
                Text("Choose what to do with this tmux control-mode tab.")
            case .herdr:
                Text("Closing removes the tab from the herdr session on the host. Detaching leaves the session running and returns the gateway tab to its shell.")
            }
        }
    }
}

/// Optional confirmation for a user-requested pane or tab close.
private struct CloseConfirmationDialogModifier: ViewModifier {
    let title: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
    let message: LocalizedStringKey
    let targetExists: Bool
    let dismiss: () -> Void
    let confirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: Binding(
                get: { targetExists },
                set: { if !$0 { dismiss() } }
            ),
            titleVisibility: .visible
        ) {
            Button(confirmTitle, role: .destructive, action: confirm)
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel, action: dismiss)
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(message)
        }
        .onChange(of: targetExists) { _, exists in
            // Server reconciliation and tab removal bypass closeSplit.
            // Observe the live tree so those paths dismiss the dialog too.
            if !exists { dismiss() }
        }
    }
}
