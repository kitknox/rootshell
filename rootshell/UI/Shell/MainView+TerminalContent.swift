//
//  MainView+TerminalContent.swift
//  rootshell
//
//  Terminal content area views for MainView.
//  Extracted to help compiler type-checking and build parallelization.
//

import SwiftUI

nonisolated private struct TerminalToolbarViewport: Equatable {
    let frame: CGRect
    let paneID: UUID?
}
import GhosttyKit
import os
import UIKit

// MARK: - Terminal Content Views

extension MainView {

    /// A terminal effect is composited once across the whole content area, so
    /// it cannot safely cover a rendered split tree that includes a VNC pane.
    /// A zoomed node is the only node on screen and is therefore evaluated on
    /// its own; an unzoomed mixed tree disables the effect for the whole tab.
    func tabAllowsTerminalEffects(_ tab: TerminalTab) -> Bool {
        guard let renderedNode = tab.splitTree.zoomed ?? tab.splitTree.root else {
            return false
        }

        func containsOnlyTerminals(_ node: SplitTree<SplitPaneView>.Node) -> Bool {
            switch node {
            case .leaf(let pane):
                return pane.asTerminal != nil
            case .split(let split):
                return containsOnlyTerminals(split.left)
                    && containsOnlyTerminals(split.right)
            }
        }

        return containsOnlyTerminals(renderedNode)
    }

    /// Whether the single window-wide effect layer may be shown for every tab
    /// currently contributing pixels. During a tab swipe both tabs are live;
    /// during Expose the current and neighboring-preview scopes are live. If
    /// any of those app tabs contains visible VNC content, suppress the shared
    /// layer so it never contaminates remote desktop pixels.
    var visibleContentAllowsTerminalEffects: Bool {
        let visibleTabs: [TerminalTab]

        if tabExpose.isActive {
            var ids = Set(tabExpose.tabIDs)
            ids.formUnion(tabExpose.previewTabIDs)
            if let heroTabID = tabExpose.heroTabID {
                ids.insert(heroTabID)
            }
            // Multiplexer page IDs are not app-tab IDs; ignore them while
            // retaining the app hero and any app scope sliding beside it.
            visibleTabs = ids.compactMap { tabsModel.tab(withID: $0) }
        } else if let swipe = appTabSwipeState {
            visibleTabs = [swipe.sourceTabID, swipe.targetTabID]
                .compactMap { tabsModel.tab(withID: $0) }
        } else if let displayedTabID = tabsModel.displayedTabID,
                  let displayedTab = tabsModel.tab(withID: displayedTabID) {
            visibleTabs = [displayedTab]
        } else {
            visibleTabs = []
        }

        return !visibleTabs.isEmpty && visibleTabs.allSatisfy(tabAllowsTerminalEffects)
    }

    /// Returns the reconnection overlay if needed for the current focused terminal.
    /// - Note: The `restorationVersion` check forces SwiftUI to re-evaluate when restoration state changes
    ///   (TerminalView is a class, so @State doesn't observe its @Published properties)
    @ViewBuilder
    var reconnectionOverlay: some View {
        // Note: restorationVersion check forces SwiftUI re-evaluation when state changes
        let _ = restorationVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           focusedTerminal.showsReconnectionOverlay {
            ReconnectionOverlayView(
                state: focusedTerminal.restorationState,
                connectionConfig: focusedTerminal.connectionConfig,
                onReconnect: {
                    if focusedTerminal.isLiveDisconnectionOverlay {
                        focusedTerminal.isLiveDisconnectionOverlay = false
                        focusedTerminal.restorationState = .none
                        focusedTerminal.manualReconnect()
                    } else {
                        TerminalRestorationReconnector.retryReconnection(for: focusedTerminal)
                    }
                },
                onEnterPassword: { password in
                    TerminalRestorationReconnector.handlePasswordEntry(for: focusedTerminal, password: password)
                },
                onClose: {
                    NotificationCenter.default.post(
                        name: .closeSplit,
                        object: focusedTerminal,
                        userInfo: ["windowId": windowId]
                    )
                }
            )
        }
    }

    /// Returns the YubiKey "insert / touch your key" overlay when a PIV signing
    /// operation is waiting on the user. App-global: there is one physical key
    /// and YubiKeySigner serialises all signing, so it renders over the focused
    /// terminal regardless of which connection path triggered the sign. FIDO2
    /// never reaches here — iOS shows its own system sheet for that.
    @ViewBuilder
    var hardwareKeyOverlay: some View {
        // Persistent container so both insertion and removal animate: the
        // transition only runs when the conditional lives inside a surviving
        // view carrying an animation scoped to the driving value. The empty
        // ZStack has no hit-testable content, so it never blocks the terminal.
        let activity = hardwareKeyCoordinator.activity
        ZStack {
            if terminals.indices.contains(selectedTabIndex),
               terminals[selectedTabIndex].focusedTerminal != nil,
               let activity {
                HardwareKeyPromptView(
                    activity: activity,
                    onCancel: {
                        // Abort whichever phase we're in. Phase-aware so we don't
                        // race the SDK by cancelling a pending connect AND tearing
                        // down a connection at once (which surfaces "connection in
                        // use"). The in-flight signWithPIV then throws and auth
                        // fails cleanly.
                        YubiKeyConnectionManager.shared.cancelCurrentOperation()
                        hardwareKeyCoordinator.finishActivity()
                    }
                )
            }
        }
        .animation(
            UIAccessibility.isReduceMotionEnabled
                ? .easeInOut(duration: 0.2)
                : .spring(response: 0.38, dampingFraction: 0.8),
            value: activity
        )
        .sensoryFeedback(trigger: activity?.phase) { _, newPhase in
            // No .failed case: the coordinator never publishes failures (the
            // session surfaces its own error), so only the touch prompt cues.
            switch newPhase {
            case .touchRequired: return .warning
            default: return nil
            }
        }
    }

    /// Returns the search overlay if the focused terminal has search active.
    @ViewBuilder
    func searchOverlay(searchStateVersion: Int) -> some View {
        // Read searchStateVersion to trigger re-render when search state changes
        let _ = searchStateVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           let searchState = focusedTerminal.searchState {
            // Hosted in a UIKit container so a native pan can drag it smoothly;
            // a SwiftUI DragGesture fights the bar's TextField/buttons for touches.
            // Dismissal honors the customizable start_search binding by answering the
            // app's Find menu action (findInTerminal) while the bar is focused; Escape
            // dismisses via a host UIKeyCommand.
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                forwardsFindToggle: true,
                onDismiss: { focusedTerminal.closeSearch() }
            ) {
                TerminalSearchOverlay(
                    searchState: searchState,
                    onSearch: { focusedTerminal.performSearch($0) },
                    onNavigate: { focusedTerminal.navigateSearch(direction: $0) },
                    onClose: { focusedTerminal.closeSearch() }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Returns the theme picker overlay.
    @ViewBuilder
    func themePickerOverlayView(isPresented: Binding<Bool>) -> some View {
        if showThemePickerOverlay && edgeSidebarUsesExternalPresentation(.themePicker) {
            // Hosted so glass + keyboard dismissal work on macOS (a plain SwiftUI
            // overlay let .onKeyPress steal the X-button click and got preempted by
            // the app's Cmd-Shift-T menu shortcut). Draggable by its chrome; the pan
            // yields to the theme list's scroll view. Dismissal via host UIKeyCommands.
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                // Answer the app's toggle_theme_picker menu action while the picker is
                // focused — that shortcut already honors KeybindManager remaps, and the
                // terminal (its usual target) isn't reachable from the focused picker.
                forwardsThemePickerToggle: true,
                onDismiss: { isPresented.wrappedValue = false }
            ) {
                ThemePickerOverlay(
                    isPresented: isPresented,
                    windowId: windowId,
                    currentTabId: terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : nil,
                    onThemeSelected: handleThemePickerSelection
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Returns the clipboard manager overlay (regular width: draggable glass HUD).
    /// On iPhone the manager is presented as a sheet instead (MainViewPresentation).
    @ViewBuilder
    func clipboardManagerOverlayView(isPresented: Binding<Bool>, keyboardMode: Binding<Bool>) -> some View {
        if showClipboardManager && edgeSidebarUsesExternalPresentation(.clipboardManager) && UIDevice.current.userInterfaceIdiom != .phone {
            DraggableHUDContainer(
                dismissShortcuts: [.escape],
                // Answer the app's toggle_clipboard_manager menu action while the
                // panel is focused — the shortcut honors KeybindManager remaps, and
                // the terminal (its usual target) isn't reachable from the panel.
                // Routed through the 3-press cycle, not a plain dismiss: the field
                // can hold focus before keyboard mode is on (manual tap), where
                // the toggle means "enter keyboard mode", not close.
                forwardsClipboardManagerToggle: true,
                onForwardedToggle: { advanceClipboardManagerCycle() },
                onDismiss: { isPresented.wrappedValue = false }
            ) {
                ClipboardManagerOverlay(
                    style: .hud,
                    isPresented: isPresented,
                    keyboardMode: keyboardMode,
                    pasteHandler: { text in pasteFromClipboardManager(text) }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The regular-width toggle_clipboard_manager cycle: press 1 opens the
    /// passthrough HUD (terminal keeps the keyboard), press 2 enters keyboard
    /// mode (the HUD's search field takes focus), press 3 closes. Reached from
    /// the .toggleClipboardManager observer (terminal focused) and from the
    /// HUD host's forwarded menu action (HUD field focused).
    func advanceClipboardManagerCycle() {
        // Keyboard mode needs the search field on screen. While the HUD shows
        // the disabled/locked pane there is nothing to focus, and raising the
        // overlay-owns-keyboard gate then would strand first responder — fall
        // through to close instead.
        let manager = ClipboardHistoryManager.shared
        let canFocusSearch = manager.isEnabled
            && !(manager.requireBiometric && !manager.isUnlocked)
        if !showClipboardManager {
            showClipboardManager = true
        } else if !clipboardManagerKeyboardMode && canFocusSearch {
            clipboardManagerKeyboardMode = true
        } else {
            showClipboardManager = false
        }
    }

    /// Pastes clipboard-manager content into the focused terminal, resolved at
    /// invocation time (same pattern as the search overlay).
    func pasteFromClipboardManager(_ text: String) {
        guard terminals.indices.contains(selectedTabIndex),
              let focusedTerminal = terminals[selectedTabIndex].focusedTerminal else { return }
        focusedTerminal.pasteText(text)
        focusedTerminal.becomeFirstResponder()
    }

    /// Returns the compose overlay if the focused terminal has compose active.
    @ViewBuilder
    func composeOverlay(composeStateVersion: Int) -> some View {
        let _ = composeStateVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           focusedTerminal.showComposeOverlay {
            TerminalComposeOverlay(
                initialText: focusedTerminal.composeText,
                onSend: { text in
                    focusedTerminal.sendComposedText(text)
                    // Explicitly clear persisted text so future opens start empty.
                    // Don't rely on onChange firing before onClose removes the overlay.
                    focusedTerminal.composeText = ""
                },
                onClose: {
                    // Restore first responder to terminal BEFORE removing overlay
                    // so the keyboard transitions smoothly without bounce
                    focusedTerminal.becomeFirstResponder()
                    focusedTerminal.showComposeOverlay = false
                    NotificationCenter.default.post(name: .ghosttyComposeStateChanged, object: focusedTerminal)
                },
                onTextChanged: { newText in
                    focusedTerminal.composeText = newText
                },
                keyboardAccessory: focusedTerminal.shouldShowKeyboardToolbar ? focusedTerminal.keyboardAccessory : nil,
                onTextViewCreated: { textView in
                    focusedTerminal.activeComposeTextView = textView
                }
            )
        }
    }

    /// The terminal overlays ZStack (reconnection, compose, full-size panels).
    @ViewBuilder
    func terminalOverlays() -> some View {
        Group {
            // Reconnection overlay for restored sessions
            reconnectionOverlay

            // YubiKey insert/touch prompt during SSH auth
            hardwareKeyOverlay

            // tmux -CC window placeholder restored from disk, awaiting reconcile
            tmuxReconnectingOverlay

            // Detach banner lives on MainView’s content area (not here) so it
            // still shows after tmux -CC prune empties every tab.

            // Full-size panels stand in for the terminal column only
            fileManagerOverlays(fullSize: true)

            #if !CHINA_BUILD
            httpCaptureOverlays(fullSize: true)
            #endif

            agentInboxOverlays(fullSize: true)

            // Compose text overlay
            composeOverlay(composeStateVersion: composeStateVersion)

            // Multiplexer session discovery overlay
            sessionDiscoveryOverlay(sessionDiscoveryVersion: sessionDiscoveryVersion)

            #if os(visionOS)
            // Floating button to toggle keyboard toolbar ornament
            visionOSKeyboardToggle
            #endif
        }
        .tint(sheetAccentColor)
        .optionalColorSchemeEnvironment(sheetColorSchemeForSheets)
    }

    /// Draggable HUDs. Laid over the docked sidebar and the terminal column so
    /// they can be dragged across both.
    @ViewBuilder
    func floatingHUDOverlays() -> some View {
        Group {
            // Search overlay for focused terminal
            searchOverlay(searchStateVersion: searchStateVersion)

            if showQuickSettingsOverlay && edgeSidebarUsesExternalPresentation(.quickSettings) {
                QuickSettingsHUD(isPresented: $showQuickSettingsOverlay)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showOpenInFolderOverlay && edgeSidebarUsesExternalPresentation(.openInFolder), let model = openInFolderModel {
                OpenInFolderHUD(isPresented: $showOpenInFolderOverlay, model: model, shortcut: openInFolderShortcut) { directory, placement in
                    openInFolder(model.target, directory: directory, placement: placement)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // File manager HUD, or the transfer pill while it is hidden
            fileManagerOverlays(fullSize: false)

            #if !CHINA_BUILD
            httpCaptureOverlays(fullSize: false)
            #endif

            agentInboxOverlays(fullSize: false)

            // Theme picker overlay
            themePickerOverlayView(isPresented: $showThemePickerOverlay)

            // Clipboard manager overlay (glass HUD; sheet on iPhone)
            clipboardManagerOverlayView(
                isPresented: $showClipboardManager,
                keyboardMode: $clipboardManagerKeyboardMode
            )

            if showIPLookup && edgeSidebarUsesExternalPresentation(.ipLookup), let model = ipLookupModel {
                IPLookupHUD(isPresented: $showIPLookup, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            #if canImport(FluidAudio) && !CHINA_BUILD
            if showDictationHUD && edgeSidebarUsesExternalPresentation(.dictation) {
                DictationHUD(isPresented: $showDictationHUD) { dictationTarget }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif
        }
        .tint(sheetAccentColor)
        .optionalColorSchemeEnvironment(sheetColorSchemeForSheets)
    }

    #if os(visionOS)
    @ViewBuilder
    private var visionOSKeyboardToggle: some View {
        if !showKeyboardToolbar {
            Button {
                NotificationCenter.default.post(name: .toggleKeyboardToolbar, object: nil)
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding([.trailing, .bottom], 16)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: showKeyboardToolbar)
        }
    }
    #endif

    /// Overlay shown when the selected tab is a restored tmux -CC window
    /// PLACEHOLDER still awaiting its reconcile (the gateway is reattaching the
    /// live `tmux -CC` over tssh). Disappears automatically when the controller
    /// adopts the placeholder (`awaitingTmuxReconcile` -> false, fills it with
    /// live panes) or the resume watchdog removes the tab.
    @ViewBuilder
    var tmuxReconnectingOverlay: some View {
        if terminals.indices.contains(selectedTabIndex),
           terminals[selectedTabIndex].awaitingTmuxReconcile {
            let tab = terminals[selectedTabIndex]
            if tab.splitTree.isEmpty {
                tmuxReconnectRecoveryPanel(for: tab)
            } else {
                tmuxReconnectStatusPill
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Purely informational — never swallow touches. Without this
                    // the overlay blocks gestures over the terminal area while a
                    // restored tmux -CC window reconnects.
                    .allowsHitTesting(false)
            }
        }
    }

    private var tmuxReconnectStatusPill: some View {
        tmuxReconnectStatusRow
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 400)
            .bannerBackground()
    }

    /// Post-detach / already-attached / missing-mux banner. Hosted above both
    /// the terminal stack and the empty state — tmux -CC detach prunes every
    /// tab immediately, so a terminal-only overlay never paints.
    ///
    /// Sized to the card only (no full-bleed VStack). A max-size container in
    /// `.overlay` steals Catalyst hits from the dismiss control even when the
    /// spacer disables hit testing.
    @ViewBuilder
    var muxDetachBannerOverlay: some View {
        if let banner = muxDetachBanner {
            HStack(spacing: 10) {
                Image(systemName: banner.offer == nil ? "exclamationmark.triangle.fill" : "eject.circle.fill")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if banner.isDetach {
                        Button("Never Show Again") {
                            neverShowMuxDetachBanner()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if banner.offer != nil {
                    Button("Reconnect") {
                        reconnectFromMuxDetachBanner()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button {
                    dismissMuxDetachBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: 480)
            .bannerBackground()
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: muxDetachBanner)
        }
    }

    private var tmuxReconnectStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Reconnecting tmux…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tmuxReconnectRecoveryPanel(for tab: TabModel) -> some View {
        let gatewayTab = tmuxReconnectGatewayTab(for: tab)
        return ZStack {
            Color.clear
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                tmuxReconnectStatusRow
                    .frame(maxWidth: 360, maxHeight: nil)

                tmuxReconnectActionButtons(for: tab, gatewayAvailable: gatewayTab != nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .bannerBackground()
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tmuxReconnectActionButtons(for tab: TabModel, gatewayAvailable: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                tmuxReconnectGatewayButton(for: tab, available: gatewayAvailable)
                tmuxReconnectCancelButton(for: tab)
            }

            VStack(spacing: 8) {
                tmuxReconnectGatewayButton(for: tab, available: gatewayAvailable)
                    .frame(maxWidth: .infinity)
                tmuxReconnectCancelButton(for: tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .controlSize(.small)
    }

    @ViewBuilder
    private func tmuxReconnectGatewayButton(for tab: TabModel, available: Bool) -> some View {
        if available {
            Button {
                selectTmuxReconnectGateway(for: tab)
            } label: {
                Label("Gateway", systemImage: "terminal")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(.bordered)
        }
    }

    private func tmuxReconnectCancelButton(for tab: TabModel) -> some View {
        Button(role: .destructive) {
            cancelTmuxReconnectRecovery(for: tab)
        } label: {
            Label("Cancel Recovery", systemImage: "xmark.circle")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(.bordered)
    }

    private func tmuxReconnectGatewayTab(for tab: TabModel) -> TabModel? {
        guard let owner = tab.owningGatewayTerminalUUID else { return nil }
        return TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: owner)?.tab
    }

    private func selectTmuxReconnectGateway(for tab: TabModel) {
        guard let owner = tab.owningGatewayTerminalUUID else { return }
        if let gatewayTab = terminals.first(where: { candidate in
            candidate.splitTree.contains { $0.uuid == owner }
        }) {
            gatewayTab.isHiddenTmuxWindow = false
            gatewayTab.pendingHiddenTmuxGatewayRestore = false
            selectTab(id: gatewayTab.id)
        } else if let located = TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: owner) {
            _ = TmuxWindowRegistry.selectGateway(ownerTerminalUUID: owner, allowFocus: true)
            activateWindowIfPossible(windowId: located.windowId)
        }
    }

    private func activateWindowIfPossible(windowId: String) {
        guard windowId != self.windowId,
              let sceneSessionId = TerminalWindowRegistry.sceneSessionId(for: windowId),
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.session.persistentIdentifier == sceneSessionId })
        else { return }
        UIApplication.shared.requestSceneSessionActivation(
            scene.session,
            userActivity: nil,
            options: nil,
            errorHandler: { error in
                Ghostty.logger.error("Failed to activate gateway window: \(error.localizedDescription)")
            }
        )
    }

    private func cancelTmuxReconnectRecovery(for tab: TabModel) {
        guard let owner = tab.owningGatewayTerminalUUID else {
            if let index = tabsModel.index(of: tab.id) {
                terminals.remove(at: index)
                tabsModel.repairSelectionIfNeeded()
            }
            return
        }

        if let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: owner) {
            gateway.cancelTmuxRestoreRecovery()
            return
        }

        TmuxWindowRegistry.removeAwaitingPlaceholders(ownerTerminalUUID: owner)
    }

    /// A gesture-only fallback for restored tmux window placeholders. Normal
    /// terminal swipes live on `TerminalView`, but an awaiting-reconcile
    /// placeholder has an empty split tree, so there is no terminal view under
    /// the reconnect pill to receive a screen swipe.
    @ViewBuilder
    var tmuxReconnectingSwipeFallback: some View {
        if terminals.indices.contains(selectedTabIndex) {
            let tab = terminals[selectedTabIndex]
            if tab.awaitingTmuxReconcile && tab.splitTree.isEmpty {
                TmuxReconnectSwipeFallbackView(
                    leftAction: reconnectPlaceholderSwipeAction(for: .left),
                    rightAction: reconnectPlaceholderSwipeAction(for: .right)
                )
                .allowsHitTesting(true)
            }
        }
    }

    private func reconnectPlaceholderSwipeAction(for direction: SwipeDirection) -> TmuxReconnectSwipeFallbackView.Action {
        switch SwipeGestureManager.shared.binding(for: direction) {
        case .preset(.nextTab):
            return .tabNavigation(nextTab)
        case .preset(.previousTab):
            return .tabNavigation(previousTab)
        default:
            // Sequence/custom-key/multiplexer bindings need a live terminal
            // surface to receive bytes. Leave them disabled on empty placeholders
            // instead of silently consuming the swipe.
            return .disabled
        }
    }

    /// Returns the session discovery overlay if the focused terminal has discovered sessions.
    @ViewBuilder
    func sessionDiscoveryOverlay(sessionDiscoveryVersion: Int) -> some View {
        let _ = sessionDiscoveryVersion
        if terminals.indices.contains(selectedTabIndex),
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           let sessions = focusedTerminal.discoveredSessions,
           // A manual run keeps the card for an empty result, so it can report back.
           !sessions.isEmpty || focusedTerminal.sessionDiscoveryIsManual {
            GeometryReader { geometry in
                // This overlay shares the terminal's keyboard-ignoring host,
                // but does not make the terminal's bottom safe-area escape.
                let _ = effectManager.keyboardStateVersion
                let bottomClearance = terminalBottomPadding(
                    geometry: geometry,
                    keyboardFrame: effectManager.keyboardFrame,
                    keyboardHeight: effectManager.keyboardHeight,
                    reservedBottomToolbarHeight: focusedTerminal.reservedKeyboardToolbarHeightAtBottom,
                    accessoryFrame: focusedTerminal.keyboardAccessoryFrameInScreen,
                    touchKeyboardFrame: focusedTerminal.dockedTouchKeyboardFrameInScreen,
                    containerBottomSafeAreaExpansion: 0,
                    terminalEffectsEnabled: false
                )
                SessionPickerOverlay(
                    sessions: sessions,
                    sessionTypes: focusedTerminal.discoveredSessionTypes,
                    selectedIndex: focusedTerminal.sessionSelectionIndex,
                    // The user invoking the command IS the intent, so skip the
                    // "you've already typed" confirmation on a manual run.
                    hasUserTyped: focusedTerminal.hasUserTyped && !focusedTerminal.sessionDiscoveryIsManual,
                    placeholder: focusedTerminal.sessionDiscoveryPlaceholder,
                    bottomClearance: bottomClearance,
                    tmuxAttachMode: Binding(
                        get: { focusedTerminal.tmuxDiscoveryAttachMode },
                        set: { newValue in
                            let resolvedValue = focusedTerminal.allowsTmuxControlDiscoveryAttach
                                ? newValue
                                : .regular
                            focusedTerminal.tmuxDiscoveryAttachMode = resolvedValue
                            if focusedTerminal.allowsTmuxControlDiscoveryAttach {
                                TmuxAutoMode.persistedDiscoveryAttachMode = resolvedValue
                            }
                            NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: focusedTerminal)
                        }
                    ),
                    allowsTmuxControlAttach: focusedTerminal.allowsTmuxControlDiscoveryAttach,
                    herdrAttachMode: Binding(
                        get: { focusedTerminal.herdrDiscoveryAttachMode },
                        set: { newValue in
                            let resolvedValue = focusedTerminal.allowsHerdrControlDiscoveryAttach
                                ? newValue
                                : .regular
                            focusedTerminal.herdrDiscoveryAttachMode = resolvedValue
                            if focusedTerminal.allowsHerdrControlDiscoveryAttach {
                                HerdrAutoMode.persistedDiscoveryAttachMode = resolvedValue
                            }
                            NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: focusedTerminal)
                        }
                    ),
                    allowsHerdrControlAttach: focusedTerminal.allowsHerdrControlDiscoveryAttach,
                    onSelect: { session in
                        focusedTerminal.attachToSession(session)
                    },
                    onChangeSelection: { index in
                        focusedTerminal.sessionSelectionIndex = index
                        NotificationCenter.default.post(name: .ghosttySessionDiscoveryChanged, object: focusedTerminal)
                    },
                    onDismiss: {
                        focusedTerminal.dismissSessionDiscovery()
                        focusedTerminal.becomeFirstResponder()
                    }
                )
            }
        }
    }

    /// Tabs whose split gaps the effect skips: those on screen, unless exposé
    /// or a full-size panel stands in for them.
    var effectGapTabIDs: [UUID] {
        guard roundedPanes, !tabExpose.isActive, !fullPanelHidesTerminal else { return [] }
        if let swipe = appTabSwipeState { return [swipe.sourceTabID, swipe.targetTabID] }
        return tabsModel.displayedTabID.map { [$0] } ?? []
    }

    /// The effect overlay layer (ocean, CRT, etc.)
    @ViewBuilder
    func effectOverlay(leadingExtension: CGFloat) -> some View {
        if effectManager.activeEffect != nil,
           visibleContentAllowsTerminalEffects {
            // The selected Integrated tab is a window onto this same effect,
            // which reaches up through the header row to draw there.
            let topExtension = effectTopExtension
            GeometryReader { geometry in
                let _ = effectManager.keyboardStateVersion
                let frame = geometry.frame(in: .global)
                let effectFrame = CGRect(x: frame.minX - leadingExtension, y: frame.minY - topExtension,
                                         width: frame.width + leadingExtension, height: frame.height + topExtension)
                TerminalEffectView()
                    .environment(\.terminalEffectBottomInset, effectBottomInset(in: effectFrame))
                    // GeometryReader keeps the widened effect out of the
                    // ZStack's layout calculation. The terminal therefore
                    // retains its exact frame while only the effect overflows
                    // left across the docked sidebar and up into the header.
                    .frame(width: effectFrame.width, height: effectFrame.height)
                    // Rounded Panes: paint only the cards, never the gaps or
                    // the square corners around them
                    .modifier(TerminalEffectWindowClip(
                        roundedPanes: roundedPanes,
                        sidebarWidth: leadingExtension,
                        topExtension: topExtension,
                        origin: effectFrame.origin,
                        join: topExtension > 0 ? integratedTabJoin : nil,
                        gaps: paneCardGaps,
                        gapTabIDs: effectGapTabIDs))
                    .offset(x: -leadingExtension, y: -topExtension)
                    // Use different blend mode for light vs dark themes
                    .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
            }
            .allowsHitTesting(false)
            // Extend into bottom safe area for ocean effect; cards end at the
            // column
            .ignoresSafeArea(edges: roundedPanes ? [] : .bottom)
            // Tab Exposé is normally the topmost terminal-content layer.
            // While it is active, keep this *same* effect view above the
            // mirrored terminal pixels so animations and video continue
            // seamlessly through the reveal instead of disappearing and
            // returning later. The controller flips `isActive` at progress
            // zero on both ends, where changing the stacking order is
            // visually lossless and does not recreate the effect view.
            // Text Above Effect keeps it beneath every glyph, the exposé's
            // included; the exposé backdrop moves beneath it instead.
            .zIndex(tabExpose.isActive && !effectManager.isTextAboveEffectActive ? 2 : 0)
        }
    }

    /// How far the effect reaches above the terminal to show through the
    /// selected Integrated tab.
    var effectTopExtension: CGFloat {
        integratedTabWindowsEffect ? TabMetrics.tabBarHeight : 0
    }

    /// Background fill when terminal is inset for ocean effect.
    @ViewBuilder
    var terminalBackgroundFill: some View {
        if visibleContentAllowsTerminalEffects,
           effectManager.terminalBottomInsetFraction > 0,
           let themeColors = effectiveThemeColors,
           let bgColor = Color(hex: themeColors.background) {
            bgColor
                .opacity(transparencyManager.effectiveBackgroundOpacity)
                .cardFillExtent(roundedPanes)
        }
    }

    /// Theme-colored fill shown while no tab content is displayable: a tab
    /// swap is mid-reveal with nothing to hold on screen (first tab at
    /// launch, the displayed tab was just closed, reveal timeout). Prevents
    /// the translucent window background from ever showing raw desktop on
    /// macOS. Deliberately NOT shown while a previous tab is still visible:
    /// the terminal's own background is already drawn at this opacity, and
    /// stacking a second fill behind it would darken the window.
    @ViewBuilder
    var tabRevealBackdropFill: some View {
        let displayedTab = tabsModel.displayedTabID.flatMap { id in
            terminals.first(where: { $0.id == id })
        }
        let hasDisplayedContent = displayedTab.map { !$0.splitTree.isEmpty } ?? false
        if !hasDisplayedContent,
           let themeColors = effectiveThemeColors,
           let bgColor = Color(hex: themeColors.background) {
            bgColor
                .opacity(transparencyManager.effectiveBackgroundOpacity)
                .cardFillExtent(roundedPanes)
                // Closing a tab clears the displayed tab inside its animation;
                // a fade-in would dip the window's opacity.
                .transition(.identity)
        }
    }

    /// How much of an effect drawn in `frame` (global space) the docked
    /// keyboard and toolbar cover, from the same frames the terminal reserves.
    func effectBottomInset(in frame: CGRect) -> CGFloat {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard terminals.indices.contains(selectedTabIndex),
              let pane = terminals[selectedTabIndex].focusedPane,
              let window = pane.window else { return 0 }
        func localFrame(_ frame: CGRect) -> CGRect {
            window.convert(frame, from: window.screen.coordinateSpace)
        }
        let bounds = window.bounds
        let keyboard = pane.dockedTouchKeyboardFrameInScreen.map(localFrame)
            ?? TerminalKeyboardGeometry.includingAccessory(
                keyboard: localFrame(effectManager.keyboardFrame),
                accessory: pane.keyboardAccessoryFrameInScreen.map(localFrame),
                container: bounds)
        // Docking is judged against the window, not this frame: a floating
        // keyboard can span a narrow sidebar while the terminal ignores it.
        let docked = keyboard.maxY >= bounds.maxY - 50
            && TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: bounds) > 0
        let keyboardCover = docked
            ? TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: frame, requireFullWidth: false) : 0
        // A latched toolbar-only reservation stands on the window's bottom edge.
        let toolbarHeight = pane.reservedKeyboardToolbarHeightAtBottom
        let toolbar = CGRect(x: bounds.minX, y: bounds.maxY - toolbarHeight, width: bounds.width, height: toolbarHeight)
        let toolbarCover = TerminalKeyboardGeometry.overlapHeight(keyboard: toolbar, container: frame, requireFullWidth: false)
        return max(keyboardCover, toolbarCover)
        #else
        return effectManager.keyboardOverlapHeight(in: frame)
        #endif
    }

    /// Calculates bottom padding for a terminal based on effects and keyboard.
    /// - Parameters:
    ///   - geometry: The geometry proxy for the terminal view
    ///   - keyboardFrame: The current keyboard frame (passed explicitly to ensure SwiftUI dependency tracking)
    ///   - keyboardHeight: The current keyboard height (passed explicitly to ensure SwiftUI dependency tracking)
    ///   - reservedBottomToolbarHeight: Actual toolbar/accessory height reserved by the selected focused terminal.
    ///   - accessoryFrame: Visible terminal toolbar in screen coordinates, when available.
    ///   - touchKeyboardFrame: Requested docked custom-keyboard frame, independent of system notifications.
    ///   - containerBottomSafeAreaExpansion: Height the container safe-area escape actually gained
    ///     this layout pass, measured by the reader pair in `terminalTabsView`.
    func terminalBottomPadding(
        geometry: GeometryProxy,
        keyboardFrame reportedKeyboardFrame: CGRect,
        keyboardHeight: CGFloat,
        reservedBottomToolbarHeight: CGFloat,
        accessoryFrame: CGRect?,
        touchKeyboardFrame: CGRect?,
        containerBottomSafeAreaExpansion: CGFloat,
        terminalEffectsEnabled: Bool
    ) -> CGFloat {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        let window = terminals.indices.contains(selectedTabIndex)
            ? terminals[selectedTabIndex].focusedPane?.window : nil
        // SwiftUI's global space belongs to this window; notification and
        // accessory frames belong to its screen. Convert on every layout so
        // moved/resized windows and the upper tabletop region stay accurate.
        func localFrame(_ frame: CGRect) -> CGRect {
            guard let window else { return .zero }
            return window.convert(frame, from: window.screen.coordinateSpace)
        }
        let containerFrame = geometry.frame(in: .global)
        let accessoryFrame = accessoryFrame.map(localFrame)
        let touchKeyboardFrame = touchKeyboardFrame.map(localFrame)
        // Use the notification's destination throughout the transition. The
        // live guide still describes an intermediate placement when UIKit
        // clears its animation flag; switching to it can shrink the grid again
        // after the shell has already redrawn for the dismissed keyboard.
        let systemKeyboardFrame = localFrame(reportedKeyboardFrame)
        let keyboardFrame = touchKeyboardFrame ?? TerminalKeyboardGeometry.includingAccessory(
            keyboard: systemKeyboardFrame, accessory: accessoryFrame, container: containerFrame)
        let isDocked = touchKeyboardFrame != nil || window.map {
            TerminalKeyboardGeometry.isDocked(keyboard: keyboardFrame, container: $0.bounds)
        } == true
        let keyboardHeight = TerminalKeyboardGeometry.overlapHeight(
            keyboard: keyboardFrame, container: containerFrame)
        let visibleKeyboardFrameHeight = keyboardHeight
        let isPhone = window?.traitCollection.horizontalSizeClass != .regular
        // Every "is a system keyboard docked" signal below is a height
        // threshold over the whole keyboard region — and that region is the
        // input accessory itself when no keyboard is up. A tall accessory then
        // reads as a keyboard: two stacked drawer rows alone reach 132pt, past
        // the 120pt line and EffectManager's 100pt dock test. Discount the
        // region the accessory accounts for first. Coverage is always clamped
        // to this terminal container, including in resized windows.
        let keyboardRegionHeight = max(
            visibleKeyboardFrameHeight,
            max(keyboardHeight, keyboardFrame.isNull || keyboardFrame.isEmpty ? 0 : keyboardFrame.height)
        )
        // Tolerance is the bottom safe area: UIKit may contribute part of the
        // home-indicator strip below the accessory itself. A real docked
        // keyboard is hundreds of points tall and stays clear of this window.
        let accessoryOwnsWholeKeyboardRegion = reservedBottomToolbarHeight > 0
            && keyboardRegionHeight <= reservedBottomToolbarHeight + windowSafeAreaInsets.bottom + 2
        let hasSoftwareKeyboard = !accessoryOwnsWholeKeyboardRegion && (
            KeyboardTracker.shared.isSoftwareKeyboardVisible ||
            keyboardHeight > 0 ||
            visibleKeyboardFrameHeight >= 120
        )
        let dockedKeyboardCoverage = visibleKeyboardFrameHeight
        let hasDockedKeyboard = isDocked && hasSoftwareKeyboard && dockedKeyboardCoverage > 0
        // A toolbar in the lower tabletop input region must not consume a
        // second toolbar-height strip from the upper terminal workspace.
        let toolbarIntersectsContainer = accessoryFrame.map {
            TerminalKeyboardGeometry.overlapHeight(keyboard: $0, container: containerFrame) > 0
        } ?? window.map {
            containerFrame.maxY >= $0.bounds.maxY - $0.safeAreaInsets.bottom - 2
        } ?? false
        let reservesBottomToolbar = reservedBottomToolbarHeight > 0 && toolbarIntersectsContainer

        // Calculate the raw keyboard coverage (for ocean calculation)
        let rawKeyboardCoverage: CGFloat
        if hasDockedKeyboard {
            rawKeyboardCoverage = dockedKeyboardCoverage
        } else if reservesBottomToolbar {
            rawKeyboardCoverage = reservedBottomToolbarHeight
        } else {
            rawKeyboardCoverage = 0
        }

        // The safe-area escape pushes the terminal's bottom edge below the
        // keyboard top by whatever it expanded; give that back as padding while
        // a docked keyboard occupies the bottom, so terminal bottom == keyboard
        // top by construction. Measured in this same pass, not modelled: the
        // previous version gated the reported inset on a "preserved keyboard is
        // physically hidden" flag, and on iOS 27 the flag and the safe-area
        // change stopped landing together, wobbling the terminal both ways.
        // A toolbar-only / accessory input view subsumes the inset the same
        // way (expansion is 0 while it is up), so a reserved toolbar gets the
        // same compensation when an overlay or app switch hides it.
        let preservedKeyboardSafeAreaCompensation: CGFloat =
            (hasDockedKeyboard || reservesBottomToolbar) ? containerBottomSafeAreaExpansion : 0

        // Calculate adjusted offset for terminal positioning (reduced to avoid excess gap)
        let keyboardOffset: CGFloat
        if hasDockedKeyboard {
            keyboardOffset = dockedKeyboardCoverage + preservedKeyboardSafeAreaCompensation
        } else if reservesBottomToolbar {
            if isPhone {
                // The terminal container already ends at the top of the
                // bottom safe-area strip, and the toolbar stands on the
                // screen's bottom edge (primary input view in toolbar-only
                // mode, flush accessory next to a hardware keyboard), so
                // reserve exactly the part of the accessory that rises above
                // the strip.
                keyboardOffset = max(
                    0,
                    reservedBottomToolbarHeight - windowSafeAreaInsets.bottom
                ) + preservedKeyboardSafeAreaCompensation
            } else {
                // The iPad container already keeps the terminal above the
                // bottom safe-area strip. Reserve only the toolbar height that
                // extends above that strip, or toolbar-only mode leaves the
                // Home-indicator clearance as a visible gap above the row.
                // Rounded cards end one card gap above the screen edge instead.
                let stripClearance = paneCardsEnterHomeIndicatorStrip ? PaneCardStyle.gap : windowSafeAreaInsets.bottom
                keyboardOffset = max(
                    0,
                    reservedBottomToolbarHeight - stripClearance
                ) + preservedKeyboardSafeAreaCompensation
            }
        } else {
            keyboardOffset = 0
        }

        #else
        let keyboardFrame = reportedKeyboardFrame
        let keyboardOffset = effectManager.keyboardOverlapHeight(in: geometry.frame(in: .global), keyboardFrame: keyboardFrame)
        let rawKeyboardCoverage = keyboardOffset
        #endif

        var padding: CGFloat = 0
        let hasOcean = terminalEffectsEnabled
            && effectManager.terminalBottomInsetFraction > 0

        if hasOcean {
            // The ocean is a fraction of the effect's height, which reaches
            // up into the header for the Integrated tab.
            padding += effectTopExtension * effectManager.terminalBottomInsetFraction
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            // `hasDockedKeyboard`, not raw `isDocked`: EffectManager calls any
            // full-width bottom-touching region over 100pt docked, which a drawer
            // row plus the reserved strip satisfies on its own.
            if reservesBottomToolbar && !hasDockedKeyboard {
                // Effects fit above an accessory-only toolbar too (see
                // effectBottomInset), so the ocean band sits on top of it.
                let toolbarCoverage = keyboardOffset - preservedKeyboardSafeAreaCompensation
                let visibleHeight = max(0, geometry.size.height - toolbarCoverage)
                padding += keyboardOffset
                padding += visibleHeight * effectManager.terminalBottomInsetFraction
            } else {
                // Docked keyboard or no keyboard with ocean: add ocean gap
                let visibleHeight = max(0, geometry.size.height - rawKeyboardCoverage)
                padding += visibleHeight * effectManager.terminalBottomInsetFraction
                padding += rawKeyboardCoverage
                padding += preservedKeyboardSafeAreaCompensation
            }
            #else
            // visionOS and Mac Catalyst do not have an undocked software
            // keyboard path, so only the standard ocean inset applies.
            let visibleHeight = max(0, geometry.size.height - rawKeyboardCoverage)
            padding += visibleHeight * effectManager.terminalBottomInsetFraction
            padding += rawKeyboardCoverage
            #endif
        } else {
            #if os(visionOS)
            // visionOS needs safe area padding when ocean is off
            padding += geometry.safeAreaInsets.bottom
            #endif
            // Use reduced keyboard offset when no ocean (tighter spacing)
            if keyboardOffset > 0 {
                padding += keyboardOffset
            }
        }

        #if os(visionOS)
        // Add clearance for the keyboard toolbar ornament when visible
        if showKeyboardToolbar {
            padding += KeyboardSizes.iPad.toolbar.height
        }
        #endif

        return padding
    }

    enum TerminalTabsLayer: Equatable {
        case content
        /// Text Above Effect pane backgrounds, laid out exactly like the content.
        case underlay
    }

    /// The terminal tabs ForEach view.
    @ViewBuilder
    func terminalTabsView(geometry: GeometryProxy, width: CGFloat, layer: TerminalTabsLayer = .content) -> some View {
        // Read keyboard state directly to ensure SwiftUI tracks these dependencies
        let keyboardFrame = effectManager.keyboardFrame
        let keyboardHeight = effectManager.keyboardHeight
        let _ = effectManager.keyboardStateVersion // Force re-render on keyboard state changes
        let _ = layer == .content ? checkUniquePaneOwnership() : ()
        // `inner` sits outside the container safe-area escape and `expanded`
        // inside it, so their height difference is the expansion UIKit granted
        // this pass. The escape lets the drawable extend into the home-indicator
        // strip; the grid stays above it via ghostty_surface_set_bottom_inset.
        // visionOS/macCatalyst add the bottom inset in terminalBottomPadding
        // instead, so they keep the single-reader path.
        GeometryReader { inner in
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            GeometryReader { expanded in
                terminalTabsStack(
                    // Coverage is measured before the safe-area escape;
                    // terminalBottomPadding adds the expansion exactly once.
                    geometry: inner,
                    width: width,
                    keyboardFrame: keyboardFrame,
                    keyboardHeight: keyboardHeight,
                    // Only the bottom escape; the top one is the surface's top inset.
                    containerBottomSafeAreaExpansion: max(
                        0, expanded.frame(in: .global).maxY - inner.frame(in: .global).maxY),
                    layer: layer
                )
            }
            // The top escape lets scrollback fill the band above the grid,
            // which ghostty_surface_set_top_inset keeps below the safe area.
            .ignoresSafeArea(.container, edges: terminalExtendsUnderTopSafeArea ? .top : [])
            // A floating keyboard still reports a keyboard region the size of
            // the strip, which would otherwise cancel the escape.
            .ignoresSafeArea([.container, .keyboard], edges: (duoTabletopAvailable && !duoTabletopDisabled) || roundedPanes ? [] : .bottom)
            // Keep in sync with the per-tab `.transaction` in terminalTabsStack.
            // The escape used to sit under that modifier, which is what kept the
            // strip-driven resize off any ambient sheet animation.
            .transaction {
                if appTabSwipeState?.isSettling != true {
                    $0.animation = nil
                }
            }
            #else
            terminalTabsStack(
                geometry: geometry,
                width: width,
                keyboardFrame: keyboardFrame,
                keyboardHeight: keyboardHeight,
                containerBottomSafeAreaExpansion: 0,
                layer: layer
            )
            #endif
        }
    }

    /// The tabs ZStack. Contains the per-tab `.zIndex` (set by
    /// `appTabSwipeVisualMetrics` to order tabs during an app-tab swipe)
    /// inside its OWN stacking context. A bare `ForEach` would flatten into
    /// the parent `terminalContentZStack`, so the displayed tab's zIndex (1)
    /// would compete with — and paint OVER — the zIndex-0 overlays and effect
    /// layer in that ZStack (theme picker, search, compose, reconnection,
    /// `effectOverlay`...), hiding them and swallowing touch/keyboard input.
    /// Wrapping in a ZStack scopes those zIndex values to the tabs alone and
    /// restores plain source-order layering against the overlays.
    @ViewBuilder
    private func terminalTabsStack(
        geometry: GeometryProxy,
        width: CGFloat,
        keyboardFrame: CGRect,
        keyboardHeight: CGFloat,
        containerBottomSafeAreaExpansion: CGFloat,
        layer: TerminalTabsLayer
    ) -> some View {
        // One measurement of the active pane's accessory for this layout pass;
        // existing keyboard notifications already invalidate the shared view.
        let accessoryFrame = terminals.indices.contains(selectedTabIndex)
            ? terminals[selectedTabIndex].focusedPane?.keyboardAccessoryFrameInScreen : nil
        let touchKeyboardFrame = terminals.indices.contains(selectedTabIndex)
            ? terminals[selectedTabIndex].focusedPane?.dockedTouchKeyboardFrameInScreen : nil
        let selectedBottomToolbarHeight = terminals.indices.contains(selectedTabIndex)
            ? (terminals[selectedTabIndex].focusedPane?.reservedKeyboardToolbarHeightAtBottom ?? 0)
            : 0
        ZStack {
            ForEach(Array(terminals.enumerated()), id: \.element.id) { index, tab in
                if !tab.splitTree.isEmpty {
                    let terminalEffectsEnabled = tabAllowsTerminalEffects(tab)
                    let visualMetrics = appTabSwipeVisualMetrics(for: tab.id, width: width)
                    let liveBottomToolbarHeight = tab.focusedPane?.reservedKeyboardToolbarHeightAtBottom ?? 0
                    // A herdr tab can be claimed while it is not showing (Take
                    // Control), and the size claimed is the size it lays out
                    // at. Its own pane is not first responder, so borrow the
                    // selected tab's reservation rather than reserving nothing,
                    // or it claims several rows too tall and reflows twice.
                    let hiddenBottomToolbarHeight: CGFloat =
                        (tab.isHerdrWindow || tab.isHerdrGateway) ? selectedBottomToolbarHeight : 0
                    // During an app-tab swipe both visible tabs must use the
                    // same reservation. The target is not first responder yet,
                    // so its live value is otherwise 0 and its viewport appears
                    // taller beside the toolbar-shortened source tab.
                    let reservedBottomToolbarHeight: CGFloat = appTabSwipeState?
                        .reservedBottomToolbarHeight(for: tab.id)
                        ?? ((index == selectedTabIndex || tab.id == tabsModel.displayedTabID)
                            ? liveBottomToolbarHeight
                            : hiddenBottomToolbarHeight)
                    let bottomPadding = terminalBottomPadding(
                        geometry: geometry,
                        keyboardFrame: keyboardFrame,
                        keyboardHeight: keyboardHeight,
                        reservedBottomToolbarHeight: reservedBottomToolbarHeight,
                        accessoryFrame: accessoryFrame,
                        touchKeyboardFrame: touchKeyboardFrame,
                        containerBottomSafeAreaExpansion: containerBottomSafeAreaExpansion,
                        terminalEffectsEnabled: terminalEffectsEnabled
                    )
                    Group {
                        switch layer {
                        case .underlay:
                            PaneUnderlay(model: tab.paneUnderlay)
                        case .content:
                            TerminalSplitTreeView(
                                tree: tab.splitTree,
                                onResize: { node, ratio in
                                    handleSplitResize(tabIndex: index, node: node, ratio: ratio)
                                },
                                onMove: { source, destination, zone in
                                    handlePaneMove(tabID: tab.id, source: source, destination: destination, zone: zone)
                                },
                                allowsPaneRearrangement: !tab.paneMove.isPending && !isAnySheetPresented
                                    && appTabSwipeState == nil && !tabExpose.isActive
                                    && tabsModel.fullScreenPaneID == nil,
                                isActive: index == selectedTabIndex,
                                focusedPane: tab.focusedPane,
                                terminalEffectsEnabled: terminalEffectsEnabled,
                                routesFocusedProgressToIntegratedEdge: topTabStyle == .integrated
                                    && showsHorizontalTabHeader,
                                integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabHeader ? integratedTabJoin : nil,
                                tracksSwipe: appTabSwipeState.map { $0.sourceTabID == tab.id || $0.targetTabID == tab.id } ?? false,
                                paneUnderlay: tab.paneUnderlay,
                                integratedTabSurface: topTabStyle == .integrated && showsHorizontalTabHeader
                                    ? integratedTabSurface : nil,
                                paneCardGaps: roundedPanes ? paneCardGaps : nil,
                                tabID: tab.id
                            )
                            // NOTE: the tmux control-mode client size is NOT driven from here.
                            // A tmux pane is a real ghostty surface, so its grid is recomputed
                            // in the core (cell/font/inset-aware) on every resize/keyboard/font
                            // change exactly like a normal surface, and the tmux backend relays
                            // it; the viewer turns a single-pane window's resize into
                            // `refresh-client -C`. Driving it from SwiftUI geometry here would
                            // re-derive the grid in the wrong place and add a round trip.
                            //
                            // The id is scoped by tab. `structuralIdentity` alone compares
                            // leaves by pane OBJECT identity, so two tabs holding the same
                            // pane (a tmux move-pane before the source tab's layout heals)
                            // gave sibling ForEach children an equal explicit id and SwiftUI
                            // trapped in DisplayList.ViewUpdater.ViewCache with "repeated
                            // view". Combining the stable tab UUID keeps the rebuild-on-
                            // structure-change behavior the tmux reconcile depends on.
                            .id(TabSplitTreeIdentity(tabID: tab.id, tree: tab.splitTree.structuralIdentity))
                            .overlay(alignment: .top) {
                                if let message = tab.paneMove.errorMessage {
                                    Text(message)
                                        .font(.callout)
                                        .padding(10)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                        .padding(8)
                                        .allowsHitTesting(false)
                                        .accessibilityLabel(message)
                                }
                            }
                        }
                    }
                    // Visibility keys off the lagging displayedTabID (not the
                    // selection) so a freshly opened tab stays hidden, and the
                    // previous tab stays on screen, until its renderer has
                    // presented a first frame. Hit testing and isActive stay on
                    // the selection: input must reach the new tab immediately.
                    //
                    // During an app-tab swipe, visual state deliberately diverges
                    // from selected/displayed state: source and target are both
                    // visible so they can slide beside each other, but input stays
                    // on the current selected/source tab until release commits.
                    .opacity(visualMetrics.opacity)
                    .offset(x: visualMetrics.offsetX)
                    .zIndex(visualMetrics.zIndex)
                    // Disabling interaction resigns a first responder inside, so the
                    // outgoing tab keeps it until the incoming pane (a herdr or tmux
                    // attach not yet in the window) can take the keyboard over.
                    .allowsHitTesting(layer == .content
                        && (index == selectedTabIndex || tab.focusedPane?.isFirstResponder == true)
                        && (appTabSwipeState == nil || tab.id == appTabSwipeState?.sourceTabID))
                    .padding(.bottom, bottomPadding)
                    // The safe-area escape moved up to the reader in
                    // terminalTabsView that measures the expansion it grants.
                    .transaction {
                        if appTabSwipeState?.isSettling != true {
                            $0.animation = nil
                        }
                    }
                    // An animated close would fade a translucent tab over the
                    // reveal backdrop. Hidden tabs are at opacity 0 anyway.
                    .transition(.identity)
                } else if let preview = tab.webPreview, layer == .content {
                    // A remote-port page lives in an ordinary app tab: keep
                    // the app foreground so its loopback forward stays alive.
                    let metrics = appTabSwipeVisualMetrics(for: tab.id, width: width)
                    PortPreviewTabView(
                        preview: preview,
                        roundedPanes: roundedPanes,
                        integratedTabJoin: integratedTabsJoinCards && showsHorizontalTabHeader
                            ? integratedTabJoin : nil
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(metrics.opacity)
                        .offset(x: metrics.offsetX)
                        .zIndex(metrics.zIndex)
                        .allowsHitTesting(index == selectedTabIndex && appTabSwipeState == nil)
                        .transition(.identity)
                }
            }
        }
        // App-tab swipe views deliberately travel beyond their own bounds.
        // Clip at the expanded terminal viewport (which already includes the
        // bottom safe-area escape) so they cannot smear beneath the sidebar.
        .clipped()
    }

    private func appTabSwipeVisualMetrics(for tabID: UUID, width: CGFloat) -> (opacity: Double, offsetX: CGFloat, zIndex: Double) {
        guard let state = appTabSwipeState else {
            return (tabID == tabsModel.displayedTabID ? 1 : 0, 0, tabID == tabsModel.displayedTabID ? 1 : 0)
        }
        guard let offsetX = state.offsetX(for: tabID, width: width) else { return (0, 0, 0) }
        return (1, offsetX, tabID == state.sourceTabID ? 2 : 1)
    }

    /// A pane may be a leaf of exactly one tab's split tree. Two tabs sharing a
    /// pane makes two SplitTreeHostingViews fight over the same UIView every
    /// layout pass, and used to crash SwiftUI outright ("repeated view"). Logs
    /// rather than traps so a device build keeps running and names the offenders.
    /// Debug-only; compiles to a no-op in release.
    private func checkUniquePaneOwnership() {
        #if DEBUG
        var owners: [ObjectIdentifier: UUID] = [:]
        for tab in terminals {
            let tabID = tab.id
            for pane in tab.splitTree.terminalLeaves {
                let key = ObjectIdentifier(pane)
                guard let other = owners[key] else {
                    owners[key] = tabID
                    continue
                }
                if other != tabID {
                    let paneUUID = pane.uuid
                    Ghostty.logger.fault(
                        "pane \(paneUUID) is in two tabs' split trees: \(other) and \(tabID)")
                }
            }
        }
        #endif
    }

    /// A translucent full-size file manager or HTTP capture would show the
    /// terminal through it. Exposé hides the panels and mirrors the terminal.
    var fullPanelHidesTerminal: Bool {
        guard transparencyManager.fullPanelIsTranslucent, !tabExpose.isActive else { return false }
        #if !CHINA_BUILD
        if httpCaptureShowsOverlay && httpCapturePresentation == .full { return true }
        #endif
        if agentInboxShowsOverlay && agentInboxPresentation == .full { return true }
        return fileManagerShowsOverlay && fileManagerPresentation == .full
    }

    /// The main terminal content ZStack (terminals + effects + overlays).
    @ViewBuilder
    func terminalContentZStack(
        geometry: GeometryProxy,
        width: CGFloat,
        effectLeadingExtension: CGFloat
    ) -> some View {
        let terminalOpacity: Double = fullPanelHidesTerminal ? 0 : 1
        let textAboveEffect = effectManager.isTextAboveEffectActive
        ZStack {
            terminalBackgroundFill
                .opacity(terminalOpacity)
            tabRevealBackdropFill
                .opacity(terminalOpacity)
            if terminals.isEmpty {
                EmptyStateResponder(onNewTab: addNewTab, onNewLocalShell: handleNewTabCommand)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Text Above Effect: pane backgrounds and the exposé backdrop,
                // then the effect, then glyph-only terminals and exposé mirrors.
                if textAboveEffect {
                    terminalTabsView(geometry: geometry, width: width, layer: .underlay)
                        .opacity(terminalOpacity)
                        .allowsHitTesting(false)
                    tabExposeBackdropHost(width: width)
                    effectOverlay(leadingExtension: effectLeadingExtension)
                }
                terminalTabsView(geometry: geometry, width: width)
                    .opacity(terminalOpacity)
                tmuxReconnectingSwipeFallback
                if !textAboveEffect {
                    effectOverlay(leadingExtension: effectLeadingExtension)
                }
                terminalOverlays()
                    .modifier(DuoControlClearance())
                    // A see-through exposé backdrop would show them.
                    .opacity(tabExpose.isActive ? 0 : 1)
                if tabTransferDropOverlayVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [TabTransferCoordinator.dragUTType],
                            delegate: WindowTabTransferDropDelegate(
                                windowId: windowId,
                                insertionIndex: {
                                    tabsModel.selectedTabID
                                        .flatMap { tabsModel.index(of: $0) }
                                        .map { $0 + 1 }
                                },
                                groupOverride: {
                                    tabsModel.isGroupedModeEnabled ? tabsModel.activeGroupID : nil
                                },
                                isWindowFocused: {
                                    isWindowFocused
                                }
                            )
                        )
                }
                // Tab exposé: live previews pulled down over the terminal. Last so it
                // covers the HUD overlays; inert (hit-test nil) while hidden. The
                // already-mounted background effect temporarily rises above it while
                // active so its animation remains continuous through the transition.
                tabExposeHost(geometry: geometry, width: width)
                    .modifier(DuoControlClearance())
            }
        }
        .frame(width: width)
        // Disable SwiftUI's automatic keyboard avoidance - we handle it manually via terminalBottomPadding
        // which correctly distinguishes docked vs undocked keyboards.
        // A tabletop keyboard frame starts at the terminal's bottom edge, so
        // ignoring it would expand the terminal across the reserved pane.
        .ignoresSafeArea(.keyboard, edges: duoTabletopAvailable && !duoTabletopDisabled ? [] : .all)
    }

    /// Default width of the docked (pinned) tab sidebar column, and the target
    /// the resize divider magnetically snaps to / double-tap resets to. The
    /// floating overlay panel (TabSidebarPresentation / TabSidebarPanelView) is
    /// a SEPARATE fixed 420; the docked column is now user-resizable (see
    /// `TabSidebarLayout`), so the two can differ once the user drags it.
    static let pinnedTabSidebarWidth: CGFloat = TabSidebarLayout.defaultWidth

    /// The width the docked (pinned) tab sidebar column occupies at the given
    /// window width; 0 when the sidebar isn't docked. Layout-only clamp: the
    /// column is user-resizable, capped at half the window so a narrow iPad
    /// pane can't starve the terminal. Do NOT write the clamped value back to
    /// `tabSidebarDockedWidth` — a transiently narrow window (Split View /
    /// Stage Manager) would otherwise permanently shrink the user's chosen
    /// width; it re-expands when the window grows.
    ///
    /// Shared by the layout HStack and by window-level overlays (e.g. the tab
    /// indicator HUD) that must center over the terminal, not the window.
    func dockedTabSidebarWidth(windowWidth: CGFloat) -> CGFloat {
        guard tabSidebarIsDocked else { return 0 }
        let dockedMin = TabSidebarLayout.dockedMinWidth(largeControls: tabSidebarLargeControls)
        return min(max(tabSidebarDockedWidth, dockedMin), windowWidth * 0.5)
    }

    var paneCardsEnterHomeIndicatorStrip: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return roundedPanes && !isPhone
        #else
        return false
        #endif
    }

    struct TerminalRowColumns {
        /// Existing header offset. Wide pinned mode maps this to the leading column.
        let docked: CGFloat
        let leadingEdgeSidebar: CGFloat
        let trailingEdgeSidebar: CGFloat
        let aiSidebar: CGFloat
        let fileManager: CGFloat
        let httpCapture: CGFloat
        let agentInbox: CGFloat
        let terminal: CGFloat

        static let minimumTerminalWidth: CGFloat = 320
    }

    /// Column widths for a content row `width` wide, after Rounded Panes' outer
    /// gaps. Shared with the header so it can find the terminal card.
    func terminalRowColumns(width: CGFloat) -> TerminalRowColumns {
        let cardGap: CGFloat = roundedPanes ? PaneCardStyle.gap : 0
        let rowWidth = width - cardGap * 2
        let leadingEdgePresented = edgeSidebarColumnIsPresented(.leading)
        let trailingEdgePresented = edgeSidebarColumnIsPresented(.trailing)
        let minimumTerminalWidth = TerminalRowColumns.minimumTerminalWidth

        if usesPinnedWideEdgeSidebarLayout && (leadingEdgePresented || trailingEdgePresented) {
            let edgeCount = CGFloat((leadingEdgePresented ? 1 : 0) + (trailingEdgePresented ? 1 : 0))
            let edgeCardGap: CGFloat = roundedPanes ? PaneCardStyle.gap : 0
            let terminalWidthFloor: CGFloat = 96
            let edgeGaps = edgeCardGap * edgeCount
            let edgeBudget = max(0, rowWidth - terminalWidthFloor - edgeGaps)
            let preferredLeading = leadingEdgePresented ? edgeSidebarPreferredWidth(.leading) : 0
            let preferredTrailing = trailingEdgePresented ? edgeSidebarPreferredWidth(.trailing) : 0
            let desiredTotal = preferredLeading + preferredTrailing
            let minimumColumnWidth = min(200, edgeBudget / max(edgeCount, 1))
            let minimumTotal = edgeCount * minimumColumnWidth
            let excessTotal = max(0, desiredTotal - minimumTotal)
            let excessScale = min(1, max(0, edgeBudget - minimumTotal) / max(excessTotal, 1))
            let leadingEdgeWidth = leadingEdgePresented ? minimumColumnWidth + max(0, preferredLeading - minimumColumnWidth) * excessScale : 0
            let trailingEdgeWidth = trailingEdgePresented ? minimumColumnWidth + max(0, preferredTrailing - minimumColumnWidth) * excessScale : 0

            #if !CHINA_BUILD
            let currentTabId = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : UUID()
            let desiredAISidebarWidth = shouldShowAISidebar(currentTabId: currentTabId)
                && !edgeSidebarColumnOwns(.aiAgent) ? aiAgentSidebarWidth : 0
            #else
            let desiredAISidebarWidth: CGFloat = 0
            #endif
            let desiredFileManagerWidth = fileManagerShowsSidebar && !edgeSidebarColumnOwns(.fileManager)
                ? min(fileManagerSidebarWidth, max(FileManagerSidebarView.minWidth, rowWidth - minimumTerminalWidth))
                : 0
            #if !CHINA_BUILD
            let desiredHTTPCaptureWidth = httpCaptureShowsSidebar && !edgeSidebarColumnOwns(.httpCapture)
                ? min(httpCaptureSidebarWidth, max(HTTPCaptureSidebarView.minWidth, rowWidth - minimumTerminalWidth))
                : 0
            #else
            let desiredHTTPCaptureWidth: CGFloat = 0
            #endif
            let desiredAgentInboxWidth = agentInboxShowsSidebar
                ? min(agentInboxSidebarWidth, max(AgentInboxSidebarView.minWidth, rowWidth - minimumTerminalWidth))
                : 0
            let legacyWidthDemand = desiredAISidebarWidth + desiredFileManagerWidth
                + desiredHTTPCaptureWidth + desiredAgentInboxWidth
            let legacyWidthBudget = max(0, rowWidth - terminalWidthFloor - edgeGaps - leadingEdgeWidth - trailingEdgeWidth)
            let legacyScale = min(1, legacyWidthBudget / max(legacyWidthDemand, 1))
            let aiSidebarWidth = desiredAISidebarWidth * legacyScale
            let fileManagerWidth = desiredFileManagerWidth * legacyScale
            let httpCaptureWidth = desiredHTTPCaptureWidth * legacyScale
            let agentInboxWidth = desiredAgentInboxWidth * legacyScale
            let terminalWidth = max(terminalWidthFloor, rowWidth - edgeGaps - leadingEdgeWidth - trailingEdgeWidth
                - aiSidebarWidth - fileManagerWidth - httpCaptureWidth - agentInboxWidth)

            return TerminalRowColumns(
                docked: leadingEdgeWidth,
                leadingEdgeSidebar: leadingEdgeWidth,
                trailingEdgeSidebar: trailingEdgeWidth,
                aiSidebar: aiSidebarWidth,
                fileManager: fileManagerWidth,
                httpCapture: httpCaptureWidth,
                agentInbox: agentInboxWidth,
                terminal: terminalWidth
            )
        }

        let dockedWidth = dockedTabSidebarWidth(windowWidth: width)
        let tabSwitcherSide = edgeSidebarAssignment.side(of: .tabSwitcher)
        let leadingEdgeWidth = tabSidebarIsDocked && tabSwitcherSide == .leading ? dockedWidth : 0
        let trailingEdgeWidth = tabSidebarIsDocked && tabSwitcherSide == .trailing ? dockedWidth : 0
        #if !CHINA_BUILD
        let currentTabId = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : UUID()
        let sidebarWidth = shouldShowAISidebar(currentTabId: currentTabId) ? aiAgentSidebarWidth : 0
        #else
        let sidebarWidth: CGFloat = 0
        #endif
        // The file manager column never squeezes the terminal below 320pt.
        let desiredFileManagerWidth = fileManagerShowsSidebar
            ? min(fileManagerSidebarWidth, max(FileManagerSidebarView.minWidth, rowWidth - dockedWidth - sidebarWidth - minimumTerminalWidth))
            : 0
        #if !CHINA_BUILD
        let desiredHTTPCaptureWidth = httpCaptureShowsSidebar
            ? min(httpCaptureSidebarWidth, max(HTTPCaptureSidebarView.minWidth, rowWidth - dockedWidth - sidebarWidth - minimumTerminalWidth))
            : 0
        #else
        let desiredHTTPCaptureWidth: CGFloat = 0
        #endif
        let agentInboxWidth = agentInboxShowsSidebar
            ? min(agentInboxSidebarWidth, max(AgentInboxSidebarView.minWidth, rowWidth - dockedWidth - sidebarWidth - minimumTerminalWidth))
            : 0
        // Opposite edges can both hold tools. Clamp their live widths together
        // without overwriting the user's saved resize preferences.
        let panelBudget = max(0, rowWidth - dockedWidth - sidebarWidth - agentInboxWidth - minimumTerminalWidth)
        let panelScale = min(1, panelBudget / max(desiredFileManagerWidth + desiredHTTPCaptureWidth, 1))
        let fileManagerWidth = desiredFileManagerWidth * panelScale
        let httpCaptureWidth = desiredHTTPCaptureWidth * panelScale
        return TerminalRowColumns(
            docked: dockedWidth,
            leadingEdgeSidebar: leadingEdgeWidth,
            trailingEdgeSidebar: trailingEdgeWidth,
            aiSidebar: sidebarWidth,
            fileManager: fileManagerWidth,
            httpCapture: httpCaptureWidth,
            agentInbox: agentInboxWidth,
            terminal: rowWidth - sidebarWidth - dockedWidth - fileManagerWidth - httpCaptureWidth - agentInboxWidth)
    }

    /// The complete terminal and AI sidebar content.
    @ViewBuilder
    func terminalAndSidebarContent(geometry: GeometryProxy, theme: ResolvedTabBarTheme) -> some View {
        let currentTabId = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : UUID()
        let columns = terminalRowColumns(width: geometry.size.width)
        let hasPinnedEdgeColumns = columns.leadingEdgeSidebar > 0 || columns.trailingEdgeSidebar > 0
        let dockedWidth = columns.docked
        let pinnedSidebarTheme: ResolvedSheetTheme? = hasPinnedEdgeColumns ? resolvedSheetTheme() : nil
        let dockedSidebarTheme: ResolvedSheetTheme? = tabSidebarIsDocked && !usesPinnedWideEdgeSidebarLayout
            ? pinnedSidebarTheme : nil
        // Rounded panes inset the whole row; columns divide what remains.
        let cardGap: CGFloat = roundedPanes ? PaneCardStyle.gap : 0
        // Floating tabs leave slack under them in the header row, which already
        // separates the cards, and Integrated tabs join the card below. Ledger
        // fills the row and keeps the gap.
        let cardTopGap: CGFloat = showsHorizontalTabHeader && topTabStyle != .ledger ? 0 : cardGap
        // Mac terminals draw their own translucent background, so the backdrop
        // is painted only around the cards (here and between splits), unless
        // the window backdrop shows there instead.
        #if targetEnvironment(macCatalyst)
        let cardBackdrop: Color? = roundedPanes && !effectManager.isBackdropEnabled
            ? tabBarChromeBackground(theme).opacity(transparencyManager.backgroundOpacity)
            : nil
        #else
        let cardBackdrop: Color? = nil
        #endif
        let tabSwitcherSide = edgeSidebarAssignment.side(of: .tabSwitcher)
        let fileManagerSide = edgeSidebarAssignment.side(of: .fileManager)
        let httpCaptureSide = edgeSidebarAssignment.side(of: .httpCapture)
        #if !CHINA_BUILD
        let shouldShowSidebar = shouldShowAISidebar(currentTabId: currentTabId)
        #endif
        let sidebarWidth = columns.aiSidebar
        let fileManagerWidth = columns.fileManager
        let httpCaptureWidth = columns.httpCapture
        let agentInboxWidth = columns.agentInbox
        let terminalWidth = columns.terminal
        let toolbarTab = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex] : nil
        let portsTerminal = toolbarTab?.focusedPane?.asTerminal
        // The terminal column ignores the keyboard, so the pill must lift
        // itself above it; otherwise the globe sits under the software
        // keyboard on iPhone and cannot be tapped.
        let portPillKeyboardLift = max(
            effectManager.keyboardHeight,
            portsTerminal?.reservedKeyboardToolbarHeightAtBottom ?? 0
        )

        HStack(spacing: 0) {
            if columns.leadingEdgeSidebar > 0, let pinnedSidebarTheme {
                pinnedEdgeSidebar(side: .leading, geometry: geometry, theme: pinnedSidebarTheme)
                    .frame(width: columns.leadingEdgeSidebar)
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }

            if fileManagerSide == .leading {
                fileManagerSidebarColumn(width: fileManagerWidth, totalWidth: geometry.size.width)
            }
            #if !CHINA_BUILD
            if httpCaptureSide == .leading {
                httpCaptureSidebarColumn(width: httpCaptureWidth, totalWidth: geometry.size.width)
            }
            #endif

            #if !CHINA_BUILD
            if edgeSidebarAssignment.side(of: .aiAgent) == .leading, shouldShowSidebar,
               !edgeSidebarColumnOwns(.aiAgent), let session = aiAgentSessions[currentTabId] {
                aiSidebarView(currentTabId: currentTabId, session: session, sidebarWidth: sidebarWidth, totalWidth: geometry.size.width)
            }
            #endif

            applyDuoChrome(terminalContentZStack(
                geometry: geometry,
                width: terminalWidth,
                effectLeadingExtension: backgroundEffectIncludesPinnedSidebar
                    && backgroundSidebarEffectID == BackgroundEffectSelection.followTerminalID
                    && columns.leadingEdgeSidebar > 0
                    ? columns.leadingEdgeSidebar
                    : 0
            ), inTerminalColumn: true)
            .frame(width: terminalWidth)
            .onGeometryChange(for: TerminalToolbarViewport.self) { [weak toolbarTab] proxy in
                let pane = toolbarTab?.focusedPane?.asTerminal
                return TerminalToolbarViewport(frame: proxy.frame(in: .global), paneID: pane?.window == nil ? nil : pane?.uuid)
            } action: { [weak toolbarTab] viewport in
                toolbarTab?.focusedPane?.asTerminal?.keyboardAccessoryController.setToolbarViewport(viewport.frame)
            }
            .overlay(alignment: .bottomTrailing) {
                if showRemotePorts, let portsTerminal {
                    ListeningPortsPill(
                        terminal: portsTerminal,
                        onOpen: { preview in
                            openPortPreviewTab(preview)
                        },
                        // Leave room for the pill's own 12 pt side padding so a
                        // long chip row scrolls instead of leaving the column.
                        maxWidth: max(120, terminalWidth - 24)
                    )
                    // Expanded/busy state belongs to one pane.
                    .id(portsTerminal.uuid)
                    .padding(.bottom, portPillKeyboardLift)
                    .opacity(tabExpose.isActive ? 0 : 1)
                }
            }

            if fileManagerSide == .trailing {
                fileManagerSidebarColumn(width: fileManagerWidth, totalWidth: geometry.size.width)
            }

            if columns.trailingEdgeSidebar > 0, let pinnedSidebarTheme {
                pinnedEdgeSidebar(side: .trailing, geometry: geometry, theme: pinnedSidebarTheme)
                    .frame(width: columns.trailingEdgeSidebar)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }

            agentInboxSidebarColumn(width: agentInboxWidth, totalWidth: geometry.size.width)

            #if !CHINA_BUILD
            if httpCaptureSide == .trailing {
                httpCaptureSidebarColumn(width: httpCaptureWidth, totalWidth: geometry.size.width)
            }

            if edgeSidebarAssignment.side(of: .aiAgent) == .trailing, shouldShowSidebar,
               !edgeSidebarColumnOwns(.aiAgent), let session = aiAgentSessions[currentTabId] {
                aiSidebarView(currentTabId: currentTabId, session: session, sidebarWidth: sidebarWidth, totalWidth: geometry.size.width)
            }
            #endif
        }
        // Above the docked column's zIndex, so HUDs can float over the sidebar.
        .overlay(alignment: .leading) {
            floatingHUDOverlays()
                .modifier(DuoControlClearance())
                // Exposé covers the terminal, and with it these HUDs.
                .opacity(tabExpose.isActive ? 0 : 1)
                .frame(width: dockedWidth + terminalWidth)
                .padding(.leading, (fileManagerSide == .leading ? fileManagerWidth : 0)
                    + (httpCaptureSide == .leading ? httpCaptureWidth : 0))
                .ignoresSafeArea(.keyboard, edges: duoTabletopAvailable && !duoTabletopDisabled ? [] : .all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The sidebar fill sits below its controls. Linked effects span in from
        // the terminal; independently selected effects draw inside this column.
        .background(alignment: .leading) {
            if let dockedSidebarTheme {
                let dockedSidebarSurface = dockedSidebarTheme.themeColors?.background ?? Color(uiColor: .systemBackground)
                dockedTabSidebarBackground(theme: dockedSidebarTheme)
                    .overlay {
                        if backgroundSidebarEffectID != BackgroundEffectSelection.followTerminalID,
                           let effect = effectManager.effect(withId: backgroundSidebarEffectID) {
                            GeometryReader { proxy in
                                let _ = effectManager.keyboardStateVersion
                                effect.createEffectView()
                                    .environment(\.terminalEffectBottomInset, effectBottomInset(in: proxy.frame(in: .global)))
                            }
                            .id(effect.id)
                            .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .frame(width: dockedWidth - cardGap)
                    .padding(.leading, dockedSidebarCardX(
                        tabSwitcherSide: tabSwitcherSide,
                        fileManagerSide: fileManagerSide,
                        columns: columns,
                        terminalWidth: terminalWidth,
                        fileManagerWidth: fileManagerWidth,
                        cardGap: cardGap
                    ))
                    .clipShape(PaneCardStyle.shape(rounded: roundedPanes))
                    .paneCardDepth(roundedPanes, shape: PaneCardStyle.shape(rounded: true),
                                   palette: IntegratedTabEdgePalette(cardSurface: dockedSidebarSurface))
                    // Keyboard too: a floating keyboard's strip-sized region
                    // would stop the fill short of the bottom edge.
                    .ignoresSafeArea([.container, .keyboard], edges: roundedPanes ? [] : .bottom)
            }
        }
        // iPad cards run into the home-indicator strip (the surface inset keeps
        // the grid above it). iPhone display corners would clip them there, so
        // its cards stop at the strip, which already separates the bottom edge.
        .padding(EdgeInsets(top: cardTopGap, leading: cardGap,
                            bottom: paneCardsEnterHomeIndicatorStrip || windowSafeAreaInsets.bottom < cardGap ? cardGap : 0,
                            trailing: cardGap))
        .background {
            if let cardBackdrop {
                GeometryReader { proxy in
                    let height = max(0, proxy.size.height - cardTopGap - cardGap)
                    PaneCardBackdropShape(holes: paneCardBackdropHoles(
                        tabSwitcherSide: tabSwitcherSide,
                        fileManagerSide: fileManagerSide,
                        columns: columns,
                        terminalWidth: terminalWidth,
                        fileManagerWidth: fileManagerWidth,
                        dockedWidth: dockedWidth,
                        cardGap: cardGap,
                        cardTopGap: cardTopGap,
                        height: height
                    ))
                    .fill(cardBackdrop, style: FillStyle(eoFill: true))
                }
                .allowsHitTesting(false)
            }
        }
        .environment(\.paneCardBackdrop, cardBackdrop)
        .environment(\.paneCardRimPalette, theme.integratedEdgePalette)
        // Keyboard too: a floating keyboard reports a strip-sized keyboard
        // region that would lift the cards out of the strip.
        .ignoresSafeArea([.container, .keyboard], edges: paneCardsEnterHomeIndicatorStrip ? .bottom : [])
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasPinnedEdgeColumns)
        // Animate width changes when a pinned edge column toggles/snaps, but never
        // during the live drag (the gesture drives width directly). Outside the
        // CHINA gate — the legacy tab-sidebar path ships on China builds too.
        .animation(tabSidebarIsDragging ? .none : .interactiveSpring(), value: dockedWidth)
        .animation(tabSidebarIsDragging ? .none : .interactiveSpring(), value: columns.trailingEdgeSidebar)
        .animation(fileManagerSidebarIsDragging ? .none : .spring(response: 0.3, dampingFraction: 0.85), value: fileManagerWidth)
        .animation(agentInboxSidebarIsDragging ? .none : .spring(response: 0.3, dampingFraction: 0.85), value: agentInboxWidth)
        #if !CHINA_BUILD
        .animation(httpCaptureSidebarIsDragging ? .none : .spring(response: 0.3, dampingFraction: 0.85), value: httpCaptureWidth)
        .animation(
            aiAgentSidebarIsDragging ? .none : .spring(response: 0.3, dampingFraction: 0.85),
            value: shouldShowSidebar
        )
        .animation(
            aiAgentSidebarIsDragging ? .none : .interactiveSpring(),
            value: sidebarWidth
        )
        #endif
    }

    /// X of the docked tab card inside the content row. A trailing column
    /// keeps the card gap on its terminal side.
    private func dockedSidebarCardX(
        tabSwitcherSide: EdgeSidebarSide,
        fileManagerSide: EdgeSidebarSide,
        columns: TerminalRowColumns,
        terminalWidth: CGFloat,
        fileManagerWidth: CGFloat,
        cardGap: CGFloat
    ) -> CGFloat {
        if tabSwitcherSide == .leading { return 0 }
        var x = leadingWidth(in: columns) + terminalWidth
        if fileManagerSide == .trailing { x += fileManagerWidth }
        return x + cardGap
    }

    private func paneCardBackdropHoles(
        tabSwitcherSide: EdgeSidebarSide,
        fileManagerSide: EdgeSidebarSide,
        columns: TerminalRowColumns,
        terminalWidth: CGFloat,
        fileManagerWidth: CGFloat,
        dockedWidth: CGFloat,
        cardGap: CGFloat,
        cardTopGap: CGFloat,
        height: CGFloat
    ) -> [PaneCardBackdropShape.Hole] {
        let leading = leadingWidth(in: columns)
        var holes = [
            PaneCardBackdropShape.Hole(
                rect: CGRect(x: cardGap + leading, y: cardTopGap, width: terminalWidth, height: height),
                cornerRadius: 0
            ),
        ]
        guard dockedWidth > cardGap else { return holes }
        let dockedX: CGFloat
        if tabSwitcherSide == .leading {
            dockedX = cardGap
        } else {
            var x = cardGap + leading + terminalWidth
            if fileManagerSide == .trailing { x += fileManagerWidth }
            dockedX = x + cardGap
        }
        holes.insert(
            PaneCardBackdropShape.Hole(
                rect: CGRect(x: dockedX, y: cardTopGap, width: dockedWidth - cardGap, height: height),
                cornerRadius: PaneCardStyle.cornerRadius
            ),
            at: 0
        )
        return holes
    }

    /// A pinned edge column. Reuses the same content the floating drawer hosts.
    @ViewBuilder
    private func pinnedEdgeSidebar(
        side: EdgeSidebarSide,
        geometry: GeometryProxy,
        theme: ResolvedSheetTheme
    ) -> some View {
        let innerGap: CGFloat = usesPinnedWideEdgeSidebarLayout && roundedPanes ? PaneCardStyle.gap : 0
        let card = HStack(spacing: 0) {
            if side == .trailing {
                edgePinnedSidebarDivider(side: .trailing, geometry: geometry)
            }
            edgeSidebarBody(
                side: side,
                sheetTheme: theme,
                isDocked: true,
                dockedBottomClearance: dockedSidebarBottomClearance()
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paneCardClip(roundedPanes)
            if side == .leading {
                edgePinnedSidebarDivider(side: .leading, geometry: geometry)
            }
        }
        .frame(maxHeight: .infinity)
        .background {
            if usesPinnedWideEdgeSidebarLayout {
                dockedTabSidebarBackground(theme: theme)
            }
        }
        .clipShape(PaneCardStyle.shape(rounded: roundedPanes))
        // Match the floating panel's `.tint(...)` so standard controls and
        // context menus in the edge column carry the theme accent too (and the
        // divider's drag-accent resolves to the theme color). The sidebar's own
        // glyphs use the explicit `accentTint`, since `.tint` doesn't reach
        // `Color.accentColor` inside its hosting controller — see
        // VerticalTabSidebar.accentTint. `nil` = no override.
        .tint(theme.accentColor)
        // Match the floating panel (TabSidebarPresentation): without this the
        // edge column's `.primary`/`.secondary` content follows the *device*
        // appearance, rendering black-on-dark (unreadable) under a dark theme
        // when the device is in Light mode. `nil` = no override.
        .optionalColorSchemeEnvironment(theme.colorScheme)

        if usesPinnedWideEdgeSidebarLayout {
            card
                .paneCardDepth(roundedPanes, shape: PaneCardStyle.shape(rounded: true),
                               palette: IntegratedTabEdgePalette(
                                cardSurface: theme.themeColors?.background ?? Color(uiColor: .systemBackground)
                               ))
                .padding(side == .leading ? .trailing : .leading, innerGap)
                .background(alignment: side == .leading ? .leading : .trailing) {
                    dockedTabSidebarBackground(theme: theme)
                        .ignoresSafeArea(.container, edges: side == .leading ? .leading : .trailing)
                }
        } else {
            card
        }
    }

    /// Resize divider on the column's inner edge. The 1pt line lives inside
    /// the column width so the hit area never overhangs the terminal.
    private func dockedTabSidebarDivider(side: SidebarResizeSide, geometry: GeometryProxy) -> some View {
        SidebarResizeDivider(
            side: side,
            width: $tabSidebarDockedWidth,
            isDragging: $tabSidebarIsDragging,
            minWidth: usesPinnedWideEdgeSidebarLayout
                ? TabSidebarLayout.minWidth
                : TabSidebarLayout.dockedMinWidth(largeControls: tabSidebarLargeControls),
            maxWidth: geometry.size.width * 0.5,
            defaultWidth: TabSidebarLayout.defaultWidth,
            cardGap: roundedPanes ? PaneCardStyle.gap : nil,
            backgroundColor: .clear,
            onCommit: { TabSidebarLayout.saveDockedWidth($0) }
        )
    }

    private func edgePinnedSidebarDivider(side: EdgeSidebarSide, geometry: GeometryProxy) -> some View {
        let key = edgeSidebarWidthKey(side)
        let otherSide = side.opposite
        let otherWidth = edgeSidebarColumnIsPresented(otherSide)
            ? edgeSidebarPreferredWidth(otherSide) + (roundedPanes ? PaneCardStyle.gap : 0)
            : 0
        let gap = roundedPanes ? PaneCardStyle.gap : 0
        let maximum = max(0, geometry.size.width - otherWidth - 96 - gap * 2)
        let minimum = min(200, maximum)
        return SidebarResizeDivider(
            side: side == .leading ? .left : .right,
            width: edgeSidebarWidthBinding(side),
            isDragging: $tabSidebarIsDragging,
            minWidth: minimum,
            maxWidth: maximum,
            defaultWidth: nil,
            cardGap: roundedPanes ? PaneCardStyle.gap : nil,
            backgroundColor: .clear,
            onCommit: { width in
                EdgeSidebarLayout.saveWidth(width, for: key)
                Ghostty.logger.info("Edge sidebar width commit side=\(side.rawValue, privacy: .public) width=\(width, privacy: .public)")
            },
            commitsOnRelease: true
        )
    }

    /// Theme surface below the legacy docked sidebar's share of the continuous effect
    /// canvas. Kept separate from `dockedTabSidebar` so the effect can composite
    /// over the fill while tab rows and controls remain crisp above it.
    private func dockedTabSidebarBackground(theme: ResolvedSheetTheme) -> Color {
        let opaque = theme.themeColors?.background ?? Color(uiColor: .systemBackground)
        guard transparencyManager.pinnedSidebarTransparencyEnabled else { return opaque }
        return (theme.translucentBackground ?? opaque).opacity(transparencyManager.effectiveBackgroundOpacity)
    }

    /// Bottom clearance for pinned edge content so it stays
    /// clear of whatever occupies the window's bottom edge. Two cases,
    /// mirroring the terminal's own `terminalBottomPadding`:
    ///
    /// - Docked software keyboard visible: the keyboard spans the full window
    ///   width, so the column's lower rows and footer are covered and
    ///   unreachable unless the content compresses. Clearance is the
    ///   keyboard's coverage (its frame already includes the accessory
    ///   toolbar), minus the bottom inset the column's content already sits
    ///   above (the safe area, or the card gap with rounded panes).
    /// - Otherwise, the keyboard toolbar docked at the bottom edge (hardware
    ///   keyboard, toolbar-only mode, or a floating software keyboard):
    ///   clearance is the focused pane's toolbar reservation.
    ///
    /// The sidebar applies `.ignoresSafeArea(.keyboard)`, so SwiftUI's own
    /// avoidance never double-applies; this value is the only bottom inset.
    private func dockedSidebarBottomClearance() -> CGFloat {
        #if os(visionOS) || targetEnvironment(macCatalyst)
        return 0
        #else
        // Register the SwiftUI dependency so keyboard show/hide, toolbar
        // collapse, and drawer-height changes re-evaluate this (same
        // mechanism terminalTabsView uses for the terminal's own padding).
        let _ = effectManager.keyboardStateVersion
        guard terminals.indices.contains(selectedTabIndex),
              let pane = terminals[selectedTabIndex].focusedPane,
              let window = pane.window else { return 0 }
        let touchKeyboardFrame = pane.dockedTouchKeyboardFrameInScreen
        let keyboardFrame = window.convert(touchKeyboardFrame ?? effectManager.keyboardFrame,
                                           from: window.screen.coordinateSpace)
        if (touchKeyboardFrame != nil || TerminalKeyboardGeometry.isDocked(keyboard: keyboardFrame, container: window.bounds)) {
            let coverage = TerminalKeyboardGeometry.overlapHeight(keyboard: keyboardFrame, container: window.bounds)
            guard coverage > 0 else { return 0 }
            // Rounded cards end one card gap above the screen edge, not at the strip.
            let stripClearance = paneCardsEnterHomeIndicatorStrip ? PaneCardStyle.gap : windowSafeAreaInsets.bottom
            return max(0, coverage - stripClearance)
        }
        // Not gated on the keyboard: the reservation itself requires the
        // pane to hold first responder, so it is 0 whenever no toolbar is
        // docked at the bottom edge.
        if pane.asTerminal?.keyboardAccessoryController.toolbarFollowsTerminalViewport == true { return 0 }
        guard terminals.indices.contains(selectedTabIndex) else { return 0 }
        return terminals[selectedTabIndex].focusedPane?.reservedKeyboardToolbarHeightAtBottom ?? 0
        #endif
    }

    #if !CHINA_BUILD
    /// Whether to show the AI sidebar for the given tab.
    func shouldShowAISidebar(currentTabId: UUID) -> Bool {
        !isPhone &&
        AICredentialsManager.shared.aiAgentPresentationMode == .sidebar &&
        terminals.indices.contains(selectedTabIndex) &&
        aiAgentSidebarVisibleTabs.contains(currentTabId) &&
        aiAgentSessions[currentTabId] != nil
    }

    /// The AI Agent sidebar view.
    @ViewBuilder
    func aiSidebarView(currentTabId: UUID, session: AIAgentSession, sidebarWidth: CGFloat, totalWidth: CGFloat) -> some View {
        AIAgentSidebarView(
            isPresented: Binding(
                get: { aiAgentSidebarVisibleTabs.contains(currentTabId) },
                set: { newValue in
                    if newValue {
                        aiAgentSidebarVisibleTabs.insert(currentTabId)
                    } else {
                        aiAgentSidebarVisibleTabs.remove(currentTabId)
                    }
                }
            ),
            session: session,
            tabID: currentTabId,
            isDragging: $aiAgentSidebarIsDragging,
            sidebarWidth: $aiAgentSidebarWidth,
            totalWidth: totalWidth,
            side: edgeSidebarAssignment.side(of: .aiAgent)
        )
        .environment(\.edgeSidebarTitleContext, EdgeSidebarTitleContext(
            pages: edgeSidebarAssignment.pages(on: edgeSidebarAssignment.side(of: .aiAgent)),
            selection: .aiAgent,
            side: edgeSidebarAssignment.side(of: .aiAgent),
            isPinned: edgeSidebarIsPinned(edgeSidebarAssignment.side(of: .aiAgent)),
            onTogglePin: { toggleEdgeSidebarPin(edgeSidebarAssignment.side(of: .aiAgent)) },
            onSelect: selectEdgeSidebarPage
        ))
        .frame(width: sidebarWidth)
        .transition(AnyTransition.move(edge: .trailing).combined(with: .opacity))
        .tint(sheetAccentColor)
        .optionalColorSchemeEnvironment(sheetColorSchemeForSheets)
    }
    #endif
}

// MARK: - Docked Tab Sidebar Width Persistence

/// Persistence + bounds for the user-resizable docked tab sidebar width.
/// Plain `UserDefaults` (not `@AppStorage`) so reads/writes don't republish and
/// re-render `MainView` during a live drag — the live value lives in MainView's
/// `tabSidebarDockedWidth` `@State` and is saved here only on drag end / reset.
enum TabSidebarLayout {
    /// Floor for the docked column in COMPACT control density (keeps the tab
    /// list usable).
    static let minWidth: CGFloat = 240
    /// Floor in LARGE control density. The header button row (eye / density /
    /// pin … gear / + / xmark — six 44pt targets, 4pt spacing, 16pt side
    /// padding ≈ 316pt) clips below this. See VerticalTabSidebar.headerRow and
    /// SidebarMetrics.large.
    static let minWidthLargeControls: CGFloat = 320
    /// Default width + the divider's magnetic-snap / double-tap-reset target.
    static let defaultWidth: CGFloat = 420

    /// The resize floor for the docked column at the current control density.
    static func dockedMinWidth(largeControls: Bool) -> CGFloat {
        largeControls ? minWidthLargeControls : minWidth
    }

    static func loadDockedWidth() -> CGFloat {
        let saved = SettingsStore.shared.get(Settings.Sidebar.dockedWidth)
        return saved >= Double(minWidth) ? CGFloat(saved) : defaultWidth
    }

    static func saveDockedWidth(_ width: CGFloat) {
        SettingsStore.shared.set(Settings.Sidebar.dockedWidth, Double(max(width, minWidth)))
    }
}

struct EdgeSidebarWidthKey: Hashable {
    let side: EdgeSidebarSide
    let isLandscape: Bool
}

@MainActor
enum EdgeSidebarLayout {
    static func loadWidths() -> [EdgeSidebarWidthKey: CGFloat] {
        [
            EdgeSidebarWidthKey(side: .leading, isLandscape: false): CGFloat(SettingsStore.shared.get(Settings.Sidebar.leadingPortraitWidth)),
            EdgeSidebarWidthKey(side: .leading, isLandscape: true): CGFloat(SettingsStore.shared.get(Settings.Sidebar.leadingLandscapeWidth)),
            EdgeSidebarWidthKey(side: .trailing, isLandscape: false): CGFloat(SettingsStore.shared.get(Settings.Sidebar.trailingPortraitWidth)),
            EdgeSidebarWidthKey(side: .trailing, isLandscape: true): CGFloat(SettingsStore.shared.get(Settings.Sidebar.trailingLandscapeWidth))
        ]
    }

    static func saveWidth(_ width: CGFloat, for key: EdgeSidebarWidthKey) {
        let value = Double(max(0, width))
        switch (key.side, key.isLandscape) {
        case (.leading, false): SettingsStore.shared.set(Settings.Sidebar.leadingPortraitWidth, value)
        case (.leading, true): SettingsStore.shared.set(Settings.Sidebar.leadingLandscapeWidth, value)
        case (.trailing, false): SettingsStore.shared.set(Settings.Sidebar.trailingPortraitWidth, value)
        case (.trailing, true): SettingsStore.shared.set(Settings.Sidebar.trailingLandscapeWidth, value)
        }
    }
}

/// Explicit SwiftUI identity for a tab's split-tree subtree: the tab's stable
/// UUID plus the tree's structure. See the `.id(...)` call in `terminalTabsView`.
private struct TabSplitTreeIdentity: Hashable {
    let tabID: UUID
    let tree: SplitTree<SplitPaneView>.StructuralIdentity
}

private struct TmuxReconnectSwipeFallbackView: UIViewRepresentable {
    enum Action {
        case disabled
        case tabNavigation(@MainActor () -> Void)

        var isEnabled: Bool {
            if case .tabNavigation = self { return true }
            return false
        }
    }

    let leftAction: Action
    let rightAction: Action

    func makeCoordinator() -> Coordinator {
        Coordinator(leftAction: leftAction, rightAction: rightAction)
    }

    func makeUIView(context: Context) -> SwipeFallbackUIView {
        let view = SwipeFallbackUIView()
        view.configure(coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: SwipeFallbackUIView, context: Context) {
        context.coordinator.leftAction = leftAction
        context.coordinator.rightAction = rightAction
        uiView.leftSwipe.isEnabled = leftAction.isEnabled
        uiView.rightSwipe.isEnabled = rightAction.isEnabled
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var leftAction: Action
        var rightAction: Action

        init(leftAction: Action, rightAction: Action) {
            self.leftAction = leftAction
            self.rightAction = rightAction
        }

        @objc
        func handleLeftSwipe(_ gesture: UISwipeGestureRecognizer) {
            perform(leftAction)
        }

        @objc
        func handleRightSwipe(_ gesture: UISwipeGestureRecognizer) {
            perform(rightAction)
        }

        private func perform(_ action: Action) {
            guard case .tabNavigation(let handler) = action else { return }
            #if !os(visionOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            handler()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard touch.type == .direct else { return false }
            guard let window = gestureRecognizer.view?.window,
                  let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return false }
            return !InteractiveEdgePanRecognizer.claimsHorizontalSwipe(
                in: window, startingAt: touch.location(in: window),
                translation: CGPoint(x: swipe.direction == .left ? -1 : 1, y: 0)
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    final class SwipeFallbackUIView: UIView {
        let leftSwipe = UISwipeGestureRecognizer()
        let rightSwipe = UISwipeGestureRecognizer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isOpaque = false
            isUserInteractionEnabled = true

            leftSwipe.direction = .left
            leftSwipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            leftSwipe.cancelsTouchesInView = false
            addGestureRecognizer(leftSwipe)

            rightSwipe.direction = .right
            rightSwipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            rightSwipe.cancelsTouchesInView = false
            addGestureRecognizer(rightSwipe)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(coordinator: Coordinator) {
            leftSwipe.removeTarget(nil, action: nil)
            rightSwipe.removeTarget(nil, action: nil)

            leftSwipe.addTarget(coordinator, action: #selector(Coordinator.handleLeftSwipe(_:)))
            rightSwipe.addTarget(coordinator, action: #selector(Coordinator.handleRightSwipe(_:)))
            leftSwipe.delegate = coordinator
            rightSwipe.delegate = coordinator
        }
    }
}

// MARK: - Remote Port Pages

extension MainView {
    /// Opens a forwarded remote port in its own app tab. The tab has no
    /// terminal: `terminalTabsStack` renders a WKWebView for `webPreview`.
    func openPortPreviewTab(_ preview: PortPreview) {
        let title = ":\(preview.remotePort)"
        let tab = TabModel(paneView: nil, title: title, windowId: windowId)
        tab.webPreview = preview
        tab.title = title
        tabsModel.insertTab(tab, at: selectedTabIndex + 1)
        // A web tab has no terminal to render a first frame, so make it the
        // displayed tab immediately instead of waiting for the reveal gate.
        tabsModel.displayedTabID = tab.id
    }
}
