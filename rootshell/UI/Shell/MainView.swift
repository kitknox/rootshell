//
//  MainView.swift
//  rootshell
//
//  Main view for the terminal app: stored properties + `body` only.
//
//  Everything else lives in topic-named companion files, all
//  `extension MainView` unless noted:
//    MainViewBody             - body subview builders
//    MainViewPresentation     - applyScene/Sheet/OverlayChange modifier pipeline
//    MainViewAlerts           - unified alert UI (queue lives in MainAlertController)
//    MainViewChangeHandlers   - applyLifecycle/Change/RemainingHandlers
//    MainViewEventHandlers    - onAppear/onDisappear/tab-change/window-focus handlers
//    MainViewConnectionSheet  - connection sheet content + connect dispatch
//    MainViewDeepLinks        - ssh:// and mosh:// URL handling
//    MainViewTabBar           - tab bar content, hover, context-menu helpers
//    MainViewTabSidebar       - vertical tab sidebar content
//    MainViewSheetTheme       - SheetThemeColors env key + theme resolution
//    MainViewSupportViews     - standalone helper views/modifiers (not extensions)
//    MainViewWindowSceneReporter - window scene/frame reporting (not extensions)
//    MainViewTabDrag          - TabDragState + TabDragModifier (not extensions)
//  plus the pre-existing: MainViewFocus, MainViewLifecycle, MainViewModifiers,
//  MainViewNotifications, MainViewPersistence, MainViewSplits,
//  MainViewSSHValidation, MainViewTabBarStyling, MainViewTabManagement,
//  MainViewTerminalContent, MainViewTrzszTransfer, MainViewTypes, MainViewAIAgent.
//
//  Stored properties must stay in this file (Swift disallows stored
//  properties in extensions). Most are deliberately `internal`, not
//  `private` — the companion extensions live in other files and `private`
//  would hide the properties from them.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct MainView: View {
    
    // MARK: - Properties
    
    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow
    @SceneStorage("windowId") var sceneWindowId: String = UUID().uuidString
    var overrideWindowId: String? = nil
    var windowId: String { overrideWindowId ?? sceneWindowId }
    @State var isWindowFocused: Bool = false
    @State var windowIsKeyWindow: Bool = false
    @State var lifecycleScenePhase: ScenePhase = {
        switch UIApplication.shared.applicationState {
        case .active:
            return .active
        case .inactive:
            return .inactive
        case .background:
            return .background
        @unknown default:
            return .inactive
        }
    }()
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @State var shortRemoteSessionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State var shortRemoteSessionBackgroundTaskIDBox: ShortRemoteSessionBackgroundTaskIDBox?
    #endif

    /// Per-window tab state. Replaces the previous `@State var terminals:
    /// [TerminalTab] = []` design where any per-tab mutation invalidated all
    /// of `MainView`'s body. `TabsModel` is `@Observable`; SwiftUI tracks
    /// reads at property granularity, so a title change on one tab no longer
    /// invalidates sibling tabs or the surrounding chrome.
    @State var tabsModel = TabsModel()

    /// Source-compat shim. Most call sites use `terminals[i].xxx` (which works
    /// in-place because `TabModel` is a class) or array-mutating helpers like
    /// `terminals.append(_:)`. The set-path replaces the underlying tabs array,
    /// which is fine because `TabModel` instances are reference-typed and
    /// retained.
    var terminals: [TerminalTab] {
        get { tabsModel.tabs }
        nonmutating set { tabsModel.tabs = newValue }
    }

    /// Source-compat shim around `tabsModel.selectedTabID`. The `Int` index is
    /// what the existing `MainView` plumbing expects; the canonical truth lives
    /// as a UUID on the model so reorders don't desync the selection.
    var selectedTabIndex: Int {
        get {
            tabsModel.selectedTabIndex ?? 0
        }
        nonmutating set {
            guard newValue >= 0, newValue < tabsModel.tabs.count else {
                tabsModel.selectedTabID = tabsModel.tabs.first?.id
                return
            }
            tabsModel.selectedTabID = tabsModel.tabs[newValue].id
        }
    }

    @State var showSettings = false
    @State var showToolbarSettings = false
    @State var settingsDestination: SettingsDestination?
    @State var showConnectionSidebar = false
    @State var connectionSidebarInitialTab: ConnectionSidebarTab = .lastUsed
    @State var showPasswordPromptSheet = false
    @State var passwordPromptProfile: ConnectionProfile?
    @State var passwordPromptSplitOption: SSHConnectionView.SplitOption = .newTab
    @State var showKeyResolutionSheet = false
    @State var keyResolutionUnresolvedKeys: [UnresolvedKeyInfo] = []
    @State var keyResolutionConfig: SSHConfig?
    @State var keyResolutionProfileID: UUID?
    @State var keyResolutionConnectionIdentity: String?
    @State var keyResolutionProtocol: ConnectionProtocol = .ssh
    @State var keyResolutionTransportMode: ProfileTransportMode = .default
    @State var keyResolutionTrzszMTU: Int?
    @State var keyResolutionTrzszPortMin: Int?
    @State var keyResolutionTrzszPortMax: Int?
    @State var keyResolutionTrzszServerPath: String?
    @State var keyResolutionSplitOption: SSHConnectionView.SplitOption = .newTab
    @State var pendingBrowseSelection: BrowseHostSelection? = nil
    /// "Ask Each Time" tmux tab-close: the tab whose ⌘W/✕ is awaiting the
    /// user's choice in the close action sheet. (id=tmux-tab-close-action)
    @State var pendingTmuxCloseTabID: UUID?
    /// "Ask Each Time" tmux new-tab (⌘T): the tmux tab whose new-tab choice is
    /// awaiting the user (local shell vs new tmux window). (id=tmux-new-tab-action)
    @State var pendingTmuxNewTabTabID: UUID?
    @State var reconnectingTabIndex: Int?
    @State var reconnectConfig: SSHConfig?
    /// Source-compat shim around `tabsModel.draggingTabID`.
    var draggingTab: TerminalTab? {
        get {
            guard let id = tabsModel.draggingTabID else { return nil }
            return tabsModel.tabs.first(where: { $0.id == id })
        }
        nonmutating set {
            tabsModel.draggingTabID = newValue?.id
        }
    }
    @State var wigglingTabIds: Set<UUID> = []
    /// Debounced hover state for the tab health popover (see TabHoverController).
    @State var tabHover = TabHoverController()
    @State var tabFrames: [UUID: CGRect] = [:]

    // Namespace for glass effect tab transitions (iOS 26+)
    @Namespace var tabNamespace
    
    // Theme observation for tab bar styling
    var themeManager = ThemeManager.shared
    var transparencyManager = TransparencyManager.shared
    var effectManager = EffectManager.shared
    var themeOverrideManager = ThemeOverrideManager.shared
    var themeUIOverridesManager = ThemeUIOverridesManager.shared
#if targetEnvironment(macCatalyst)
    var titlebarLayoutManager = TitlebarLayoutManager.shared
#endif

    // YubiKey connection manager for PIN prompt handling
    var yubiKeyConnectionManager = YubiKeyConnectionManager.shared

    // Surfaces the "insert / touch your YubiKey" overlay during SSH auth.
    var hardwareKeyCoordinator = HardwareKeyActivityCoordinator.shared
    
    // Theme-Aware UI toggle. Read by the sheet-theme helpers in
    // MainViewSheetTheme.swift; `private` would hide it from extensions
    // in other files.
    @AppStorage("themedUI") var themedUIEnabled: Bool = true

    // SSH settings
    @AppStorage("sshHealthMonitoringEnabled") var sshHealthMonitoringEnabled: Bool = true
#if targetEnvironment(macCatalyst)
    @AppStorage("tabsInTitlebarEnabled") var tabsInTitlebarEnabled: Bool = true
    @AppStorage("hideWindowTitleBar") var hideWindowTitleBar: Bool = false
#endif
    
    // Tab bar visibility
    @AppStorage("tabBarHidden") var tabBarHidden: Bool = false
    @AppStorage("showTabShortcutIndicators") var showTabShortcutIndicators: Bool = false
    @AppStorage("tabBarAnimationsDisabled") var tabBarAnimationsDisabled: Bool = false
    @AppStorage(TopTabStyle.storageKey) var topTabStyleRawValue: String = TopTabStyle.pills.rawValue
    @AppStorage(UserPreferences.showTabScopeMenuKey) var showTabScopeMenu: Bool = true

    var topTabStyle: TopTabStyle { TopTabStyle.resolve(topTabStyleRawValue) }

#if !targetEnvironment(macCatalyst) && !os(visionOS)
    @AppStorage("fullScreenModeEnabled") var fullScreenModeEnabled: Bool = false
#endif

#if os(visionOS)
    @State var showKeyboardToolbar: Bool = true
#endif

    // Tab indicator overlay (shown when switching tabs with tab bar hidden)
    // and its one-shot suppression flags (see TabIndicatorController).
    @State var tabIndicator = TabIndicatorController()
    @State var appTabSwipeState: AppTabSwipeState?

    // Tab exposé (live previews of the current scope; see TabExposeController).
    @State var tabExpose = TabExposeController()
    /// Serves the exposé's multiplexer page (herdr / tmux / zellij tabs).
    @State var muxExposeFeed = MultiplexerExposeFeed()
    
    
    // Unified main-alert queue: host-key validation, SSH/GPG agent
    // approvals, helper-missing, and AI-agent alerts all route through this
    // per-window controller (see MainAlertController).
    @State var alerts = MainAlertController()

    // In-window full-screen takeover for VNC panes (one per window, like
    // the alert controller; see PaneFullScreenController).
    @State var paneFullScreen = PaneFullScreenController()

    // Keyboard-interactive (RFC 4256) challenges — queue of pending server prompt
    // rounds, presented one at a time via a sheet (needs free-form text entry).
    @State var keyboardInteractiveQueue: [PendingKeyboardInteractiveChallenge] = []
    @State var showKeyboardInteractivePrompt = false
    
    
    // Search state change trigger - incremented to force re-render when search opens/closes
    @State var searchStateVersion: Int = 0
    @State var composeStateVersion: Int = 0
    // Restoration state change trigger - incremented to force re-render when restoration state changes
    // (TerminalView is a class, so @State doesn't observe its @Published properties)
    @State var restorationVersion: Int = 0
    @State var sessionDiscoveryVersion: Int = 0
    @State var windowSceneSessionID: String?
    @State var windowSafeAreaInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
#if targetEnvironment(macCatalyst)
    // Per-window geometry restore is stashed in onAppear and applied exactly once
    // the windowId→scene link is published by WindowSceneReporter — an event,
    // not a 2s poll. `pendingRestoreFrame` is nil for a brand-new window.
    // Non-private: stash/apply live in the MainViewPersistence.swift extension
    // (a different file), so `private` would hide them there.
    @State var pendingRestoreFrame: CGRect?
    @State var isFirstRestoredWindow: Bool = false
    @State var geometryRestorePending: Bool = false
    @State var geometryRestoreApplied: Bool = false
    // This window's last observed system frame, captured CONTINUOUSLY during the
    // session by WindowSceneReporter (on layout/resize/focus) — NOT just at save
    // time. The save-time `windowScene(forWindowId:)` lookup returns nil on
    // macOS 27 (scenes torn down before terminate / registry unset), so
    // serializeWindowState reads this instead, giving each window its own frame.
    @State var lastKnownWindowFrame: CGRect?
#endif
#if STANDALONE && targetEnvironment(macCatalyst)
    @State var visorContentHostID = UUID()
    @State var visorReadinessContinuations: [CheckedContinuation<Bool, Never>] = []
#endif
    
    // Theme picker overlay state
    @State var showThemePickerOverlay = false

    // Clipboard manager overlay state
    @State var showClipboardManager = false
    /// Keyboard mode for the regular-width clipboard HUD (2nd Cmd+Shift+C
    /// press): the HUD's search field takes the keyboard and the list becomes
    /// keyboard-navigable. Per-window @State on purpose — a flag on the shared
    /// ClipboardHistoryManager would leak keyboard mode across windows.
    @State var clipboardManagerKeyboardMode = false

    // Vertical tab sidebar state (toggled by the tab-switcher button/shortcut)
    @State var showingTabSwitcher = false
    @State var tabSidebarCollapsedGateways: Set<UUID> = TabSidebarCollapseStore.load()
    /// When pinned, the sidebar renders as a docked left column that shrinks
    /// the terminal (instead of a floating overlay over it). Routes
    /// `showingTabSwitcher` to docked vs floating — see `tabSidebarIsDocked`.
    @AppStorage("tabSidebarPinned") var tabSidebarPinned: Bool = false

    /// When the floating (non-pinned) sidebar is open, auto-close it after the
    /// user selects a tab. Off by default (sidebar stays open until dismissed).
    /// No effect on phone/visionOS (those always dismiss) or in pinned/docked mode.
    @AppStorage("tabSidebarAutoHideOnSelect") var tabSidebarAutoHideOnSelect: Bool = false

    /// Mirror of the tab sidebar's control-density setting so the docked
    /// column's resize floor (`TabSidebarLayout.dockedMinWidth`) widens when the
    /// user switches to large controls. Default must match VerticalTabSidebar's
    /// own @AppStorage("tabSidebarLargeControls") (large on phone, compact else).
    @AppStorage("tabSidebarLargeControls") var tabSidebarLargeControls: Bool =
        UIDevice.current.userInterfaceIdiom == .phone

    /// User-resizable width of the docked (pinned) tab sidebar column. Local
    /// `@State` drives layout live during a divider drag; the value is
    /// persisted (via `TabSidebarLayout`) only on release. Deliberately NOT
    /// `@AppStorage` — that would republish and re-render `MainView` on every
    /// drag frame (mirrors how `aiAgentSidebarWidth` works).
    @State var tabSidebarDockedWidth: CGFloat = TabSidebarLayout.loadDockedWidth()
    /// True only while the user is actively dragging the docked sidebar's
    /// resize divider; used solely to disable the width animation mid-drag.
    /// Must NOT feed any keyboard/focus/`isAnySheetPresented` predicate.
    @State var tabSidebarIsDragging: Bool = false

    /// Pinning (docked column that shrinks the terminal) only makes sense
    /// where there is room beside the terminal: iPad + Mac Catalyst. iPhone
    /// has none; visionOS presents the sidebar as a sheet.
    var canPinTabSidebar: Bool {
        #if os(visionOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom != .phone
        #endif
    }

    /// The sidebar is currently shown as a docked left column rather than the
    /// floating overlay. The single switch that routes presentation, keyboard
    /// ownership (`isAnySheetPresented`), and tab-select focus.
    /// Full-screen VNC is a window-level takeover, so an inline docked column
    /// would remain underneath it. Preserve the user's pin preference but use
    /// the floating window overlay until the takeover ends.
    var tabSidebarUsesDockedPresentation: Bool {
        tabSidebarPinned && canPinTabSidebar && tabsModel.fullScreenPaneID == nil
    }

    var tabSidebarIsDocked: Bool {
        showingTabSwitcher && tabSidebarUsesDockedPresentation
    }

    // Connection info sheet state
    @State var connectionInfoToShow: ConnectionInfo?
    /// tmux session dashboard sheet (opened from a gateway/window tab's
    /// context menu). Carries the gateway's controller.
    @State var tmuxDashboardRequest: TmuxDashboardRequest?

    // Trzsz transfer (Continuity Handoff) state
    @State var trzszTransferOriginRequest: TrzszTransferOriginRequest?
    @State var trzszTransferIncomingOffer: TrzszTransferReceiver.Offer?
    
    #if !CHINA_BUILD
    // AI Agent state
    @State var showAIAgentOverlay = false  // For iPhone sheet presentation
    @State var aiAgentSidebarVisibleTabs: Set<UUID> = []  // For sidebar mode on iPad/Catalyst/visionOS
    @State var aiAgentSidebarIsDragging: Bool = false  // Track sidebar resize drag
    @State var aiAgentSidebarWidth: CGFloat = AICredentialsManager.shared.aiAgentSidebarWidth  // Local state for smooth drag
    @State var aiAgentSessions: [UUID: AIAgentSession] = [:]
    // Tracks which TerminalView spawned each agent session, so a connection-config
    // change in a sibling split of the same tab doesn't tear down an agent attached
    // to a different split.
    @State var aiAgentSessionOwnerIDs: [UUID: ObjectIdentifier] = [:]
    @State var voiceAgentSessions: [UUID: VoiceAgentSession] = [:]
    @State var showVoiceAgentExpanded = false
    #endif

    // YubiKey PIN prompt state
    @State var showYubiKeyPINPrompt = false
    #if !CHINA_BUILD
    var aiAgentWindowState: AIAgentWindowState { AIAgentWindowState.shared }
    #endif

    /// Holds tokens from NotificationCenter's block-based addObserver API so
    /// they can be removed on `handleOnDisappear`. See MainViewObserverBag
    /// doc for the leak this fixes.
    @State var observerBag = MainViewObserverBag()
    @State var didCleanUpWindow = false
    @State var windowClosingAfterTabTransfer = false
    @State var tabTransferDropOverlayVisible = false
    
    var body: some View {
        // Bump the body-evaluation counter at the very top so even early-exit
        // paths are counted. Snapshot+reset on each BG/FG transition prints the
        // count as a `bodyEvals=N` key on those lifecycle checkpoints, letting
        // us verify post-refactor that sustained network instability does not
        // re-evaluate the body. Pre-refactor the count grew with per-tab
        // title/health/roam-protocol mutations; post-refactor it should only
        // grow on structural events (tab add/remove, manual selection, sheet
        // visibility, theme picker, keyboard frame).
        LifecycleDebugLogger.shared.bumpBodyEvaluation()
        let content = GeometryReader { geometry in
            #if !os(visionOS)
            let _ = effectManager.keyboardStateVersion
            let defersBottomSystemGesture = !isAnySheetPresented
                && terminals.indices.contains(selectedTabIndex)
                && terminals[selectedTabIndex].focusedPane?
                    .defersBottomSystemGestureForKeyboardToolbar == true
            #endif

            // Resolve all tab bar styling once for this body evaluation rather
            // than letting each computed property (`tabBarBackgroundColor`,
            // `tabTextColor`, etc.) independently re-resolve the override
            // theme and re-extract UIColor RGB components. See
            // `ResolvedTabBarTheme` doc for details.
            let resolvedTheme = resolvedTabBarTheme()
            ZStack {
                // Full-bleed backgrounds
                fullBleedBackground(geometry: geometry, theme: resolvedTheme)

                VStack(spacing: 0) {
                    // Top toolbar spacer when tab bar is hidden (Catalyst only)
                    catalystTabBarSpacer(geometry: geometry)

                    if !tabBarHidden {
                        HStack(spacing: 0) {
                            tabBarLeadingSpacer(geometry: geometry, theme: resolvedTheme)

                            // Tab bar - switches between display modes
                            //
                            // The previous design carried a `tabBarVersion`
                            // counter that was bumped from drop completions
                            // and notification observers, with `.id(tabBarVersion)`
                            // forcing a structural rebuild of the entire tab
                            // bar subtree on every increment. With per-tab
                            // observation via `TabModel`, the tab bar
                            // re-evaluates only on the property reads it
                            // actually performs, so no manual refresh signal
                            // is needed.
                            tabBarTrack(in: geometry, theme: resolvedTheme)
                                .layoutPriority(0)
                                // Toggling grouped mode changes `navigationTabs`,
                                // which can flip the tab-bar display mode (e.g.
                                // equalWidth→singleTab when two tabs live in
                                // different groups). Animating that structural
                                // swap makes the selected tab's glass capsule
                                // morph for ~1s, during which the roam "R" badge
                                // composites against the unsettled glass and looks
                                // washed out. Snap the layout for grouped-mode
                                // toggles so the badge is correct immediately;
                                // ordinary tab add/remove + resize still animate
                                // (this innermost transaction only fires when
                                // `isGroupedModeEnabled` itself changes).
                                .transaction(value: tabsModel.isGroupedModeEnabled) { $0.animation = nil }
                                .animation(.easeInOut(duration: 0.25), value: terminals.count)
#if targetEnvironment(macCatalyst)
                                .blockWindowDrag(when: usesTitlebarTabs)
#endif

                            if topTabStyle == .integrated {
                                tabBarAddButton(theme: resolvedTheme)
                                integratedTabBarDragRegion()
                                    .layoutPriority(-1)
                                tabBarSettingsButton(theme: resolvedTheme)
                            } else {
                                Spacer(minLength: 0)
                                tabBarActionButtons(theme: resolvedTheme)
                            }
                        }
                        .frame(height: TabMetrics.tabBarHeight)
                        .frame(maxWidth: .infinity)
                        .background(tabBarChromeBackground(resolvedTheme))
                        .modifier(ContainerCornerModifier())
#if targetEnvironment(macCatalyst)
                        .catalystCursorRegion()
#endif
                        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
                            // Tab frame preferences are only used by Catalyst
                            // titlebar dragging. Guard and defer the write so
                            // selection animations don't feed layout-pass
                            // preferences back into MainView every frame.
                            DispatchQueue.main.async {
                                if tabFrames != frames {
                                    tabFrames = frames
                                }
                            }
                        }
                    }
                    
                    // Terminal view
                    if ghosttyApp.readiness == .ready, !terminals.isEmpty {
                        terminalAndSidebarContent(geometry: geometry)
                    } else if ghosttyApp.readiness == .ready, terminals.isEmpty, !windowClosingAfterTabTransfer {
                        // Empty state - shown when all tabs are closed
                        EmptyStateResponder(
                            onNewTab: addNewTab,
                            onNewLocalShell: createLocalShellTab
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if ghosttyApp.readiness == .ready, terminals.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if ghosttyApp.readiness == .loading {
                        loadingView
                    } else if ghosttyApp.readiness == .error {
                        errorView
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(WindowSceneReporter(onUpdate: { scene, safeAreaInsets, isKeyWindow in
                    let newID = scene?.session.persistentIdentifier
                    let newInsets = EdgeInsets(
                        top: safeAreaInsets.top,
                        leading: safeAreaInsets.left,
                        bottom: safeAreaInsets.bottom,
                        trailing: safeAreaInsets.right
                    )
                    // Dispatch to avoid modifying state during view update
                    DispatchQueue.main.async {
                        if windowSceneSessionID != newID {
                            windowSceneSessionID = newID
                            TerminalWindowRegistry.updateSceneSessionId(newID, for: windowId)
                            #if targetEnvironment(macCatalyst)
                            // The scene link is now resolvable — this is the
                            // precise event the geometry restore was waiting for.
                            // Apply once (no-ops if nothing is pending or already
                            // applied, or if onAppear hasn't stashed yet — in
                            // which case onAppear's own call will apply it).
                            if newID != nil {
                                tryApplyPendingGeometry()
                            }
                            #endif
                        }
                        if windowSafeAreaInsets.top != newInsets.top ||
                            windowSafeAreaInsets.leading != newInsets.leading ||
                            windowSafeAreaInsets.bottom != newInsets.bottom ||
                            windowSafeAreaInsets.trailing != newInsets.trailing {
                            windowSafeAreaInsets = newInsets
                        }
                        if windowIsKeyWindow != isKeyWindow {
                            windowIsKeyWindow = isKeyWindow
                            #if targetEnvironment(macCatalyst) && STANDALONE
                            MainAlertController.registerWindowController(alerts, isKeyWindow: isKeyWindow)
                            #endif
                        }
                        #if targetEnvironment(macCatalyst) && STANDALONE
                        MainAlertController.registerWindowController(alerts, isKeyWindow: isKeyWindow)
                        #endif
                    }
                }, onFrameUpdate: { frame in
                    // Continuously track this window's own frame so save doesn't
                    // depend on the terminate-time scene lookup (nil on macOS 27).
                    #if targetEnvironment(macCatalyst)
                    DispatchQueue.main.async {
                        if lastKnownWindowFrame != frame {
                            lastKnownWindowFrame = frame
                        }
                    }
                    #endif
                }))
                #if !os(visionOS)
                // Pull the tab sidebar in from the left screen edge (iPad).
                .background(TabSidebarEdgeSwipe(
                    showingTabSwitcher: $showingTabSwitcher,
                    canOpen: { !showingTabSwitcher && !isAnySheetPresented },
                    opensDocked: tabSidebarUsesDockedPresentation,
                    panelWidth: 420
                ))
                // Defer the iPad leading edge for the sidebar gesture. Also
                // defer Home while an iPhone/iPad toolbar sits at the screen
                // edge without a docked software keyboard. Gesture arbitration
                // changes; keyboard geometry does not.
                .defersSystemGestures(
                    on: ((UIDevice.current.userInterfaceIdiom == .pad
                          && ((!showingTabSwitcher && !isAnySheetPresented)
                              || (showingTabSwitcher && !tabSidebarIsDocked)))
                        ? Edge.Set.leading : [])
                        .union(
                            (((UIDevice.current.userInterfaceIdiom == .phone
                               || UIDevice.current.userInterfaceIdiom == .pad)
                              && defersBottomSystemGesture)
                                ? Edge.Set.bottom : [])
                        )
                )
                #endif

            } // ZStack
#if targetEnvironment(macCatalyst)
            .overlay(alignment: .top) {
                catalystDragStripShield()
            }
#endif
            .overlay {
                // Tab indicator overlay - shown when switching tabs with tab bar hidden.
                // Pass the TabModel (class reference, structural under Observation),
                // not the title — keeps the title read inside the overlay's body
                // so per-tab title mutations don't invalidate MainView.body.
                if tabIndicator.isShowing && tabBarHidden && terminals.indices.contains(selectedTabIndex) {
                    // Position/count/shortcut reflect navigable tabs; hidden
                    // tmux windows are skipped, and grouped mode scopes this
                    // to the active group.
                    let visiblePosition = tabsModel.navigationIndex(of: terminals[selectedTabIndex].id)
                        ?? selectedTabIndex
                    TabIndicatorOverlay(
                        tab: terminals[selectedTabIndex],
                        allTabs: terminals,
                        currentIndex: visiblePosition,
                        totalCount: tabsModel.navigationTabs.count,
                        keyboardShortcut: keyboardShortcut(for: visiblePosition),
                        tmuxBadgePalette: TmuxTabBadgePalette(theme: resolvedTheme)
                    )
                    // Center over the terminal, not the window: the docked
                    // (pinned) tab sidebar consumes the leading edge and the
                    // AI agent sidebar the trailing edge.
                    .padding(.leading, dockedTabSidebarWidth(windowWidth: geometry.size.width))
                    .padding(.trailing, aiAgentSidebarCurrentWidth())
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                // Health tooltip overlay - positioned using global coordinates.
                // Placed in overlay to ensure it renders above all other content.
                // The hovered TabModel lookup uses `id` (a `let UUID`) which is
                // immutable and not Observation-tracked. The `connectionHealth`
                // read happens inside HealthPopoverOverlay.body, scoping
                // keepalive-ping invalidations to that overlay subview.
                let hoveredTab = tabHover.hoveredTabId.flatMap { id in
                    terminals.first(where: { $0.id == id })
                }
                HealthPopoverOverlay(
                    tab: hoveredTab,
                    tabFrame: tabHover.hoveredTabId.flatMap { tabFrames[$0] },
                    geometryWidth: geometry.size.width,
                    enabled: sshHealthMonitoringEnabled
                )
            }
            .animation(.easeOut(duration: 0.2), value: tabHover.hoveredTabId)
        } // GeometryReader
        // The terminal manages keyboard clearance explicitly. Keep the root
        // layout stable when iOS hides/restores the keyboard around app
        // activation so foregrounding does not bounce the terminal.
        .ignoresSafeArea(.keyboard)

        let sceneContent = applySceneModifiers(content)
        // Resolve sheet styling once for this body evaluation. Without this,
        // each .themedSheet / sheet-aware modifier inside `applySheetModifiers`
        // independently re-reads sheet theme + accent + color-scheme — 8+
        // attachments × 3 properties = 30+ effectiveThemeColors walks per
        // body. Combined with network-driven body invalidations
        // (TabsModel.tabs, EffectManager.keyboardStateVersion,
        // ThemeOverrideManager.tabOverrides), that workload is what
        // FrontBoard's 10s foreground / 30s background scene-update budget
        // catches in the 52 0x8BADF00D crash IPS files (varying frames; same
        // root cause: MainView.body is too expensive).
        let sheetTheme = resolvedSheetTheme()
        let sheetContent = applySheetModifiers(sceneContent, sheetTheme: sheetTheme)
        let overlayContent = applyOverlayChangeHandlers(sheetContent)
        let alertContent = applyAlertModifiers(overlayContent)
        return applyLifecycleHandlers(alertContent)
    }

}

#Preview {
    MainView()
        .environmentObject(Ghostty.App())
}
