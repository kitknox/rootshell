//
//  MainView+TerminalContent.swift
//  rootshell
//
//  Terminal content area views for MainView.
//  Extracted to help compiler type-checking and build parallelization.
//

import SwiftUI
import GhosttyKit
import os
import UIKit

// MARK: - Terminal Content Views

extension MainView {

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
                        NotificationCenter.default.post(name: .terminalRestorationStateChanged, object: focusedTerminal)
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
        if showThemePickerOverlay {
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
        if showClipboardManager && UIDevice.current.userInterfaceIdiom != .phone {
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

    /// The terminal overlays ZStack (search, reconnection, theme picker, compose).
    @ViewBuilder
    func terminalOverlays() -> some View {
        Group {
            // Search overlay for focused terminal
            searchOverlay(searchStateVersion: searchStateVersion)

            // Reconnection overlay for restored sessions
            reconnectionOverlay

            // YubiKey insert/touch prompt during SSH auth
            hardwareKeyOverlay

            // tmux -CC window placeholder restored from disk, awaiting reconcile
            tmuxReconnectingOverlay

            // Theme picker overlay
            themePickerOverlayView(isPresented: $showThemePickerOverlay)

            // Clipboard manager overlay (glass HUD; sheet on iPhone)
            clipboardManagerOverlayView(
                isPresented: $showClipboardManager,
                keyboardMode: $clipboardManagerKeyboardMode
            )

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
        // The external window has no activatable scene of its own.
        guard windowId != self.windowId,
              windowId != ExternalDisplay.windowId,
              let sceneSessionId = TerminalWindowRegistry.sceneSessionId(for: windowId),
              let scene = UIApplication.shared.deviceWindowScenes
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
           !sessions.isEmpty {
            SessionPickerOverlay(
                sessions: sessions,
                sessionTypes: focusedTerminal.discoveredSessionTypes,
                selectedIndex: focusedTerminal.sessionSelectionIndex,
                hasUserTyped: focusedTerminal.hasUserTyped,
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

    /// The effect overlay layer (ocean, CRT, etc.)
    @ViewBuilder
    var effectOverlay: some View {
        if effectManager.activeEffect != nil {
            TerminalEffectView()
                // Use different blend mode for light vs dark themes
                .blendMode(effectManager.isLightTheme ? .multiply : .plusLighter)
                .allowsHitTesting(false)
                // Extend into bottom safe area for ocean effect
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// Background fill when terminal is inset for ocean effect.
    @ViewBuilder
    var terminalBackgroundFill: some View {
        if effectManager.terminalBottomInsetFraction > 0,
           let themeColors = effectiveThemeColors,
           let bgColor = Color(hex: themeColors.background) {
            bgColor
                .opacity(transparencyManager.backgroundOpacity)
                .ignoresSafeArea()
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
                .opacity(transparencyManager.backgroundOpacity)
                .ignoresSafeArea()
        }
    }

    /// Calculates bottom padding for a terminal based on effects and keyboard.
    /// - Parameters:
    ///   - geometry: The geometry proxy for the terminal view
    ///   - keyboardFrame: The current keyboard frame (passed explicitly to ensure SwiftUI dependency tracking)
    ///   - keyboardHeight: The current keyboard height (passed explicitly to ensure SwiftUI dependency tracking)
    ///   - reservedBottomToolbarHeight: Actual toolbar/accessory height reserved by the selected focused terminal.
    ///   - containerBottomSafeAreaExpansion: Height the container safe-area escape actually gained
    ///     this layout pass, measured by the reader pair in `terminalTabsView`.
    func terminalBottomPadding(
        geometry: GeometryProxy,
        keyboardFrame: CGRect,
        keyboardHeight: CGFloat,
        reservedBottomToolbarHeight: CGFloat,
        containerBottomSafeAreaExpansion: CGFloat
    ) -> CGFloat {
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // The device keyboard never covers the external display.
        if isExternalDisplayWindow { return 0 }
        let isDocked = effectManager.isKeyboardDocked
        let containerFrame = geometry.frame(in: .global)
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let visibleKeyboardFrameHeight: CGFloat = {
            guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return 0 }
            let bounds = isPhone ? containerFrame : UIScreen.main.bounds
            // Narrow bottom HUDs (the pencil's minimized-keyboard pill, the
            // floating mini keyboard) are not keyboard coverage.
            guard keyboardFrame.width >= bounds.width - 50 else { return 0 }
            let intersection = bounds.intersection(keyboardFrame)
            guard !intersection.isNull, !intersection.isEmpty else { return 0 }
            return intersection.height
        }()
        let hasSoftwareKeyboard =
            KeyboardTracker.shared.isSoftwareKeyboardVisible ||
            keyboardHeight > 0 ||
            visibleKeyboardFrameHeight >= 120
        let dockedKeyboardCoverage = isPhone
            ? visibleKeyboardFrameHeight
            : max(keyboardHeight, visibleKeyboardFrameHeight, keyboardFrame.height)
        let hasDockedKeyboard = isDocked && hasSoftwareKeyboard && dockedKeyboardCoverage > 0
        let reservesBottomToolbar = reservedBottomToolbarHeight > 0

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
        let preservedKeyboardSafeAreaCompensation: CGFloat =
            hasDockedKeyboard ? containerBottomSafeAreaExpansion : 0

        // Calculate adjusted offset for terminal positioning (reduced to avoid excess gap)
        let keyboardOffset: CGFloat
        if hasDockedKeyboard {
            if isPhone {
                // The keyboard frame is in screen coordinates while the
                // terminal container can move when fullscreen hides/shows the
                // status bar. On iPhone, use the exact overlap with the
                // current container so the terminal ends at the keyboard top.
                keyboardOffset = dockedKeyboardCoverage + preservedKeyboardSafeAreaCompensation
            } else {
                // Docked software keyboard: subtract visual padding already provided by toolbar
                let bottomClearance: CGFloat = max(20, windowSafeAreaInsets.bottom)
                keyboardOffset = max(0, dockedKeyboardCoverage - bottomClearance) + preservedKeyboardSafeAreaCompensation
            }
        } else if reservesBottomToolbar {
            if isPhone {
                if containerFrame.width > containerFrame.height {
                    // In iPhone landscape UIKit exposes only the bottom
                    // home-indicator strip as keyboard-region clearance here,
                    // rather than the full accessory row. Reserve the remainder:
                    // using 0 overlaps the toolbar, while using the full height
                    // double-counts this strip and leaves an obvious gap.
                    keyboardOffset = max(
                        0,
                        reservedBottomToolbarHeight - windowSafeAreaInsets.bottom
                    )
                } else {
                    // In portrait the input-accessory toolbar already contributes
                    // a keyboard-region safe-area inset for its base row. UIKit
                    // does not grow that inset when drawer rows expand upward,
                    // though, so reserve only the height beyond the base row.
                    let baseToolbarHeight = KeyboardSizes.current().toolbar.height
                    keyboardOffset = max(0, reservedBottomToolbarHeight - baseToolbarHeight)
                }
            } else {
                // The iPad container already keeps the terminal above the
                // bottom safe-area strip. Reserve only the toolbar height that
                // extends above that strip, or toolbar-only mode leaves the
                // Home-indicator clearance as a visible gap above the row.
                keyboardOffset = max(
                    0,
                    reservedBottomToolbarHeight - windowSafeAreaInsets.bottom
                )
            }
        } else {
            keyboardOffset = 0
        }

        #else
        let keyboardOffset = effectManager.keyboardOverlapHeight(in: geometry.frame(in: .global), keyboardFrame: keyboardFrame)
        let rawKeyboardCoverage = keyboardOffset
        #endif

        var padding: CGFloat = 0
        let hasOcean = effectManager.terminalBottomInsetFraction > 0

        if hasOcean {
            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            if reservesBottomToolbar && !isDocked {
                // An accessory-only toolbar covers the ocean from the bottom
                // up, but a single iPhone row can be shorter than the 8% ocean
                // band. Keep the normal toolbar clearance, then reserve only
                // the water still exposed above it. Expanded toolbars that
                // cover the whole band naturally add no separate ocean gap.
                let oceanHeight = geometry.size.height * effectManager.terminalBottomInsetFraction
                let uncoveredOceanHeight = max(0, oceanHeight - rawKeyboardCoverage)
                padding += keyboardOffset
                padding += uncoveredOceanHeight
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

    /// The terminal tabs ForEach view.
    @ViewBuilder
    func terminalTabsView(geometry: GeometryProxy, width: CGFloat) -> some View {
        // Read keyboard state directly to ensure SwiftUI tracks these dependencies
        let keyboardFrame = effectManager.keyboardFrame
        let keyboardHeight = effectManager.keyboardHeight
        let _ = effectManager.keyboardStateVersion // Force re-render on keyboard state changes
        let _ = checkUniquePaneOwnership()
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
                    geometry: geometry,
                    width: width,
                    keyboardFrame: keyboardFrame,
                    keyboardHeight: keyboardHeight,
                    containerBottomSafeAreaExpansion: max(0, expanded.size.height - inner.size.height)
                )
            }
            .ignoresSafeArea(.container, edges: .bottom)
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
                containerBottomSafeAreaExpansion: 0
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
        containerBottomSafeAreaExpansion: CGFloat
    ) -> some View {
        ZStack {
            ForEach(Array(terminals.enumerated()), id: \.element.id) { index, tab in
                if !tab.splitTree.isEmpty {
                    let visualMetrics = appTabSwipeVisualMetrics(for: tab.id, width: width)
                    let liveBottomToolbarHeight = tab.focusedPane?.reservedKeyboardToolbarHeightAtBottom ?? 0
                    // During an app-tab swipe both visible tabs must use the
                    // same reservation. The target is not first responder yet,
                    // so its live value is otherwise 0 and its viewport appears
                    // taller beside the toolbar-shortened source tab.
                    let reservedBottomToolbarHeight: CGFloat = appTabSwipeState?
                        .reservedBottomToolbarHeight(for: tab.id)
                        ?? ((index == selectedTabIndex || tab.id == tabsModel.displayedTabID)
                            ? liveBottomToolbarHeight
                            : 0)
                    TerminalSplitTreeView(
                        tree: tab.splitTree,
                        onResize: { node, ratio in
                            handleSplitResize(tabIndex: index, node: node, ratio: ratio)
                        },
                        isActive: index == selectedTabIndex,
                        focusedPane: tab.focusedPane
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
                    .allowsHitTesting(index == selectedTabIndex && (appTabSwipeState == nil || tab.id == appTabSwipeState?.sourceTabID))
                    .padding(.bottom, terminalBottomPadding(
                        geometry: geometry,
                        keyboardFrame: keyboardFrame,
                        keyboardHeight: keyboardHeight,
                        reservedBottomToolbarHeight: reservedBottomToolbarHeight,
                        containerBottomSafeAreaExpansion: containerBottomSafeAreaExpansion
                    ))
                    // The safe-area escape moved up to the reader in
                    // terminalTabsView that measures the expansion it grants.
                    .transaction {
                        if appTabSwipeState?.isSettling != true {
                            $0.animation = nil
                        }
                    }
                }
            }
        }
    }

    private func appTabSwipeVisualMetrics(for tabID: UUID, width: CGFloat) -> (opacity: Double, offsetX: CGFloat, zIndex: Double) {
        guard let state = appTabSwipeState else {
            return (tabID == tabsModel.displayedTabID ? 1 : 0, 0, tabID == tabsModel.displayedTabID ? 1 : 0)
        }

        let effectiveWidth = max(max(width, state.width), 1)
        let translation: CGFloat = switch state.direction {
        case .left:
            min(0, max(-effectiveWidth, state.translationX))
        case .right:
            max(0, min(effectiveWidth, state.translationX))
        }
        let targetEntryOffset = state.direction == .left ? effectiveWidth : -effectiveWidth

        if tabID == state.sourceTabID {
            return (1, translation, 2)
        }
        if tabID == state.targetTabID {
            return (1, translation + targetEntryOffset, 1)
        }
        return (0, 0, 0)
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

    /// The main terminal content ZStack (terminals + effects + overlays).
    @ViewBuilder
    func terminalContentZStack(geometry: GeometryProxy, width: CGFloat) -> some View {
        ZStack {
            terminalBackgroundFill
            tabRevealBackdropFill
            terminalTabsView(geometry: geometry, width: width)
            tmuxReconnectingSwipeFallback
            effectOverlay
            terminalOverlays()
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
            // covers the HUD overlays; inert (hit-test nil) while hidden.
            tabExposeHost(geometry: geometry, width: width)
        }
        .frame(width: width)
        // Disable SwiftUI's automatic keyboard avoidance - we handle it manually via terminalBottomPadding
        // which correctly distinguishes docked vs undocked keyboards
        .ignoresSafeArea(.keyboard)
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

    /// The width the AI agent sidebar occupies on the trailing edge; 0 when
    /// hidden (and on China builds, which ship without the AI sidebar).
    /// Counterpart to `dockedTabSidebarWidth(windowWidth:)` for overlays that
    /// center over the terminal.
    func aiAgentSidebarCurrentWidth() -> CGFloat {
        #if !CHINA_BUILD
        guard terminals.indices.contains(selectedTabIndex),
              shouldShowAISidebar(currentTabId: terminals[selectedTabIndex].id) else { return 0 }
        return aiAgentSidebarWidth
        #else
        return 0
        #endif
    }

    /// The complete terminal and AI sidebar content.
    @ViewBuilder
    func terminalAndSidebarContent(geometry: GeometryProxy) -> some View {
        let currentTabId = terminals.indices.contains(selectedTabIndex) ? terminals[selectedTabIndex].id : UUID()
        // Docked (pinned) tab sidebar: a left column that shrinks the terminal.
        // Available on both China and non-China builds.
        let docked = tabSidebarIsDocked
        let dockedWidth = dockedTabSidebarWidth(windowWidth: geometry.size.width)
        #if !CHINA_BUILD
        let shouldShowSidebar = shouldShowAISidebar(currentTabId: currentTabId)
        let sidebarWidth = shouldShowSidebar ? aiAgentSidebarWidth : 0
        let terminalWidth = geometry.size.width - sidebarWidth - dockedWidth
        #else
        let terminalWidth = geometry.size.width - dockedWidth
        #endif

        HStack(spacing: 0) {
            if docked {
                dockedTabSidebar(geometry: geometry)
                    .frame(width: dockedWidth)
                    .transition(.move(edge: .leading))
                    // Paint the docked column above the terminal content so an
                    // app-tab swipe's `.offset(x:)` tab (the content isn't
                    // clipped) can't smear over the opaque, full-height column.
                    .zIndex(1)
            }

            terminalContentZStack(geometry: geometry, width: terminalWidth)

            #if !CHINA_BUILD
            if shouldShowSidebar, let session = aiAgentSessions[currentTabId] {
                aiSidebarView(currentTabId: currentTabId, session: session, sidebarWidth: sidebarWidth, totalWidth: geometry.size.width)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: docked)
        // Animate width changes when the docked column toggles/snaps, but never
        // during the live drag (the gesture drives width directly). Outside the
        // CHINA gate — the docked path ships on China builds too.
        .animation(tabSidebarIsDragging ? .none : .interactiveSpring(), value: dockedWidth)
        #if !CHINA_BUILD
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

    /// The pinned tab sidebar rendered inline as a docked left column (square
    /// edges + trailing separator). Reuses the same `VerticalTabSidebar`
    /// content the floating overlay hosts. On Mac Catalyst the user can opt
    /// into matching the terminal window's background opacity.
    @ViewBuilder
    private func dockedTabSidebar(geometry: GeometryProxy) -> some View {
        let theme = resolvedSheetTheme()
        let bg = theme.themeColors?.background ?? Color(uiColor: .systemBackground)
        #if targetEnvironment(macCatalyst)
        let sidebarBackground = bg.opacity(
            transparencyManager.pinnedSidebarTransparencyEnabled
                ? transparencyManager.backgroundOpacity
                : 1.0
        )
        #else
        let sidebarBackground = bg
        #endif
        HStack(spacing: 0) {
            verticalTabSidebarContent(
                sheetTheme: theme,
                isDocked: true,
                dockedBottomClearance: dockedSidebarBottomClearance()
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Resize divider on the column's trailing edge (drag right widens).
            // Its 1pt line replaces the old static trailing separator and lives
            // INSIDE the column's width so the 16pt hit area never overhangs the
            // terminal. Snaps to / double-taps back to the default width.
            SidebarResizeDivider(
                side: .left,
                width: $tabSidebarDockedWidth,
                isDragging: $tabSidebarIsDragging,
                minWidth: TabSidebarLayout.dockedMinWidth(largeControls: tabSidebarLargeControls),
                maxWidth: geometry.size.width * 0.5,
                defaultWidth: TabSidebarLayout.defaultWidth,
                // The HStack's background supplies the fill. Keeping the
                // divider hit area clear avoids stacking the translucent color
                // twice across its 16pt interaction strip.
                backgroundColor: .clear,
                onCommit: { TabSidebarLayout.saveDockedWidth($0) }
            )
        }
        .frame(maxHeight: .infinity)
        // Match the floating panel's `.tint(...)` so standard controls and
        // context menus in the docked column carry the theme accent too (and the
        // divider's drag-accent resolves to the theme color). The sidebar's own
        // glyphs use the explicit `accentTint`, since `.tint` doesn't reach
        // `Color.accentColor` inside its hosting controller — see
        // VerticalTabSidebar.accentTint. `nil` = no override.
        .tint(theme.accentColor)
        // Match the floating panel (TabSidebarPresentation): without this the
        // docked column's `.primary`/`.secondary` content follows the *device*
        // appearance, rendering black-on-dark (unreadable) under a dark theme
        // when the device is in Light mode. `nil` = no override.
        .optionalColorSchemeEnvironment(theme.colorScheme)
        // Bleed the column fill into the bottom safe area (home-indicator
        // strip) without moving the tab list. The terminal's drawable extends
        // into that strip (TerminalSplitTreeView `.ignoresSafeArea(.bottom)`), so
        // during an app-tab swipe a sliding tab would otherwise smear a sliver
        // into the bottom-left corner the column's frame doesn't reach. Extending
        // only the background keeps the corner covered (paired with the column's
        // `.zIndex(1)` above) and makes the docked column fill to the screen
        // bottom. No-op on Catalyst (no bottom safe area).
        .background(sidebarBackground.ignoresSafeArea(.container, edges: .bottom))
    }

    /// Bottom clearance for the docked tab sidebar's content so it stays
    /// clear of whatever occupies the window's bottom edge. Two cases,
    /// mirroring the terminal's own `terminalBottomPadding`:
    ///
    /// - Docked software keyboard visible: the keyboard spans the full window
    ///   width, so the column's lower rows and footer are covered and
    ///   unreachable unless the content compresses. Clearance is the
    ///   keyboard's coverage (its frame already includes the accessory
    ///   toolbar), minus the bottom safe-area inset the column's content
    ///   already sits above.
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
        // The device keyboard never covers the external display.
        if isExternalDisplayWindow { return 0 }
        // Register the SwiftUI dependency so keyboard show/hide, toolbar
        // collapse, and drawer-height changes re-evaluate this (same
        // mechanism terminalTabsView uses for the terminal's own padding).
        let _ = effectManager.keyboardStateVersion
        let keyboardFrame = effectManager.keyboardFrame
        let hasSoftwareKeyboard =
            KeyboardTracker.shared.isSoftwareKeyboardVisible ||
            effectManager.keyboardHeight > 0
        if effectManager.isKeyboardDocked && hasSoftwareKeyboard {
            let visibleKeyboardFrameHeight: CGFloat = {
                guard !keyboardFrame.isNull, !keyboardFrame.isEmpty else { return 0 }
                // Same narrow-HUD exclusion as terminalBottomPadding.
                guard keyboardFrame.width >= UIScreen.main.bounds.width - 50 else { return 0 }
                let intersection = UIScreen.main.bounds.intersection(keyboardFrame)
                guard !intersection.isNull, !intersection.isEmpty else { return 0 }
                return intersection.height
            }()
            let coverage = max(
                effectManager.keyboardHeight,
                visibleKeyboardFrameHeight,
                keyboardFrame.height
            )
            guard coverage > 0 else { return 0 }
            return max(0, coverage - max(20, windowSafeAreaInsets.bottom))
        }
        // Not gated on the keyboard: the reservation itself requires the
        // pane to hold first responder, so it is 0 whenever no toolbar is
        // docked at the bottom edge.
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
        AIAgentSidebarContainer(
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
            totalWidth: totalWidth
        )
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
    private static let key = "tabSidebar.docked.width"

    /// The resize floor for the docked column at the current control density.
    static func dockedMinWidth(largeControls: Bool) -> CGFloat {
        largeControls ? minWidthLargeControls : minWidth
    }

    static func loadDockedWidth() -> CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        return saved >= Double(minWidth) ? CGFloat(saved) : defaultWidth
    }

    static func saveDockedWidth(_ width: CGFloat) {
        UserDefaults.standard.set(Double(max(width, minWidth)), forKey: key)
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
            guard let view = gestureRecognizer.view else { return false }

            // Preserve the window-level tab-sidebar edge pan. A left-edge
            // rightward swipe should open the drawer, not switch to the previous
            // tab. This mirrors TabSidebarEdgeSwipe's activation band.
            if let fallbackView = view as? SwipeFallbackUIView,
               gestureRecognizer === fallbackView.rightSwipe,
               touch.location(in: view).x <= 32 {
                return false
            }
            return true
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
