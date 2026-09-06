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

    /// Whether the pending "Ask Each Time" tab is already hidden — used to omit
    /// the Hide Tab dialog button (hiding it is a no-op). (id=tmux-tab-close-action)
    private var pendingTmuxCloseTabIsHidden: Bool {
        guard let id = pendingTmuxCloseTabID,
              let tab = terminals.first(where: { $0.id == id }) else { return false }
        return tab.isHiddenTmuxWindow
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
        (showingTabSwitcher && !tabSidebarIsDocked) || isSheetPresentedBesidesFloatingTabSidebar
    }

    /// `isAnySheetPresented` without the floating tab sidebar, for things
    /// that work alongside it (its own rows' hover previews).
    var isSheetPresentedBesidesFloatingTabSidebar: Bool {
        let baseFlags = showSettings ||
            showToolbarSettings ||
            showConnectionSidebar ||
            showPasswordPromptSheet ||
            showKeyboardInteractivePrompt ||
            showKeyResolutionSheet ||
            showYubiKeyPINPrompt ||
            showThemePickerOverlay ||
            // The iPhone presentation is a sheet that owns the keyboard. On
            // regular width the clipboard manager is a passthrough glass HUD (like
            // the Find HUD, which is intentionally absent here) and must NOT count
            // — the terminal would surrender first responder with nothing to take
            // it, i.e. steal focus. The exception is keyboard mode, where the
            // HUD's search field is guaranteed to take focus (the toggle cycle
            // refuses keyboard mode while the disabled/locked pane is showing).
            (showClipboardManager &&
                (UIDevice.current.userInterfaceIdiom == .phone || clipboardManagerKeyboardMode)) ||
            connectionInfoToShow != nil ||
            tmuxDashboardRequest != nil ||
            pendingNewTabRequest != nil ||
            unavailableNewTabRequest != nil ||
            trzszTransferOriginRequest != nil ||
            trzszTransferIncomingOffer != nil
        #if !CHINA_BUILD
        return baseFlags || showAIAgentOverlay
        #else
        return baseFlags
        #endif
    }

    // MARK: - View Modifiers

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
            .onReceive(NotificationCenter.default.publisher(for: .toggleKeyboardToolbar)) { _ in
                showKeyboardToolbar.toggle()
            }
#endif
    }

    // Note: `allTabTitles` / `allTabRoamProtocols` moved into `TabBar`
    // (Views/TabBar.swift) so per-tab title and roam-protocol mutations
    // do not invalidate `MainView.body`.

    @ViewBuilder
    func applySheetModifiers<V: View>(_ view: V, sheetTheme: ResolvedSheetTheme) -> some View {
        view
            .modifier(SettingsSheetModifier(
                showSettings: $showSettings,
                settingsDestination: settingsDestination,
                onDismiss: { settingsDestination = nil },
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme
            ))
            .modifier(TabSidebarModifier(
                // The floating overlay is mounted only in floating mode; the
                // instant the user pins, `tabSidebarIsDocked` flips true and the
                // overlay animates out (the docked column takes over). Dismissing
                // the overlay (backdrop/✕) clears `showingTabSwitcher`.
                showSidebar: Binding(
                    get: { showingTabSwitcher && !tabSidebarIsDocked },
                    set: { newValue in if !newValue { showingTabSwitcher = false } }
                ),
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme,
                // The floating sidebar is re-hosted in a window-level
                // UIHostingController (SidePanelOverlay), which does not inherit
                // MainView's environment. Without this injection, the tmux
                // session dashboard sheet presented from the sidebar crashes in
                // TmuxPreviewContainer's @EnvironmentObject read.
                sidebarContent: { verticalTabSidebarContent(sheetTheme: sheetTheme, isDocked: false).environmentObject(ghosttyApp) }
            ))
            .sheet(isPresented: $showToolbarSettings) {
                NavigationStack {
                    KeyboardToolbarSettingsView()
                }
                .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            // Clipboard manager: compact-width presentation (iPhone). Regular
            // width mounts the draggable glass HUD in terminalOverlays() instead.
            .sheet(isPresented: Binding(
                get: { showClipboardManager && UIDevice.current.userInterfaceIdiom == .phone },
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
            .sheet(item: $connectionInfoToShow) { info in
                ConnectionInfoSheet(info: info)
                    .themedSheet(themeColors: sheetTheme.themeColors, accentColor: sheetTheme.accentColor, colorScheme: sheetTheme.colorScheme)
            }
            // "Ask Each Time" tmux tab-close action sheet. (id=tmux-tab-close-action)
            .confirmationDialog(
                "Close tmux Tab",
                isPresented: Binding(
                    get: { pendingTmuxCloseTabID != nil },
                    set: { if !$0 { pendingTmuxCloseTabID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Close tmux Window") { runPendingTmuxClose(.closeWindow) }
                    .keyboardShortcut(.defaultAction)
                Button("Detach Session") { runPendingTmuxClose(.detachSession) }
                Button("Detach Session & Close Gateway") { runPendingTmuxClose(.detachSessionAndCloseGateway) }
                // Omit Hide Tab for an already-hidden tab: hiding is a no-op there,
                // and performTmuxClose(.hideTab) would fall back to kill-window —
                // turning an explicitly non-destructive choice destructive.
                // (id=tmux-tab-close-action)
                if !pendingTmuxCloseTabIsHidden {
                    Button("Hide Tab") { runPendingTmuxClose(.hideTab) }
                }
                Button("Cancel", role: .cancel) { pendingTmuxCloseTabID = nil }
                    .keyboardShortcut(.cancelAction)
            } message: {
                Text("Choose what to do with this tmux control-mode tab.")
            }
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
            .onReceive(NotificationCenter.default.publisher(for: .trzszTransferOfferReceived)) { note in
                if let offer = note.object as? TrzszTransferReceiver.Offer {
                    trzszTransferIncomingOffer = offer
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .trzszTransferLeafShouldRemove)) { note in
                guard let info = note.userInfo,
                      let tabId = info["tabId"] as? UUID,
                      let leafId = info["leafId"] as? UUID else { return }
                handleTrzszTransferLeafRemoval(tabId: tabId, leafId: leafId)
            }
            .modifier(ConnectionSidebarModifier(
                showSidebar: $showConnectionSidebar,
                contentID: AnyHashable(connectionSidebarInitialTab),
                preventDismissal: terminals.isEmpty,
                themeColors: sheetTheme.themeColors,
                accentColor: sheetTheme.accentColor,
                colorScheme: sheetTheme.colorScheme,
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
            #if !CHINA_BUILD
            .modifier(AIAgentSheetModifier(
                showOverlay: $showAIAgentOverlay,
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
