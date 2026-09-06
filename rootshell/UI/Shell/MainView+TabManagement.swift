//
//  MainView+TabManagement.swift
//  rootshell
//
//  Tab creation, closing, and reordering for MainView.
//  Extracted for build parallelization.
//

import SwiftUI
import GhosttyKit
import os

// MARK: - Tab Management

extension MainView {

    #if targetEnvironment(macCatalyst)
    #if STANDALONE
    @MainActor
    func ensureVisorHasTerminal() async -> Bool {
        guard windowId == "visor" else { return !terminals.isEmpty }
        guard terminals.isEmpty else { return true }
        guard await waitForGhosttyAppReadyForVisor() else { return false }

        let isAvailable = await HelperConnection.shared.ensureHelperRunning()
        guard terminals.isEmpty else { return true }

        if let savedState = WindowStateManager.shared.getPendingStateExactly(forWindowId: "visor") {
            RestorationHealthTracker.shared.markRestorationStarted()
            Ghostty.logger.info("Restoring visor window state: \(savedState.tabs.count) tabs")
            restoreWindowState(savedState)
            return !terminals.isEmpty
        }

        if isAvailable {
            Ghostty.logger.info("Helper is running, creating visor local shell")
            createLocalShellTabInternal()
            return !terminals.isEmpty
        } else {
            Ghostty.logger.info("Helper not available, showing visor connection sheet")
            addNewTab()
            return false
        }
    }

    @MainActor
    private func waitForGhosttyAppReadyForVisor() async -> Bool {
        if ghosttyApp.readiness == .ready, ghosttyApp.app != nil { return true }
        if ghosttyApp.readiness == .error { return false }
        guard ghosttyApp.readiness == .loading else { return false }

        return await withCheckedContinuation { continuation in
            visorReadinessContinuations.append(continuation)
        }
    }

    @MainActor
    func handleVisorGhosttyReadinessChange(_ readiness: Ghostty.App.Readiness) {
        guard windowId == "visor", readiness != .loading else { return }
        resumeVisorReadinessWaiters(returning: readiness == .ready && ghosttyApp.app != nil)
    }

    @MainActor
    func cancelVisorReadinessWaiters() {
        resumeVisorReadinessWaiters(returning: false)
    }

    @MainActor
    private func resumeVisorReadinessWaiters(returning isReady: Bool) {
        let continuations = visorReadinessContinuations
        visorReadinessContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: isReady)
        }
    }
    #endif

    /// Check if the local shell helper is running and create appropriate initial tab
    /// - If helper is active (or can be launched): create local shell tab directly
    /// - If helper is not available: show connection sheet as fallback
    func checkHelperAndCreateInitialTab() {
        Task {
            // Use ensureHelperRunning to auto-launch helper if non-sandboxed
            let isAvailable = await HelperConnection.shared.ensureHelperRunning()

            await MainActor.run {
                guard self.terminals.isEmpty else { return }

                if isAvailable {
                    // Helper is active - create local shell directly
                    Ghostty.logger.info("Helper is running, creating local shell on launch")
                    self.createLocalShellTab()
                    self.markPlaceholderShell()
                } else {
                    // Helper not available - show connection sheet
                    Ghostty.logger.info("Helper not available, showing connection sheet on launch")
                    self.addNewTab()
                }
            }
        }
    }
    #endif

    func addNewTab() {
        // Dismiss settings sidebar if open (mutual exclusion)
        if showSettings { showSettings = false }
        // Show connection sidebar
        connectionSidebarInitialTab = .lastUsed
        showConnectionSidebar = true
    }

    // MARK: - Tab/Split Factory

    /// Shared construction prefix for every terminal-creation site (tabs,
    /// splits, reconnect): build the view, attach profile/window metadata,
    /// and mark it logically focused BEFORE it joins the view hierarchy
    /// (prevents focus races during view lifecycle / first launch).
    /// `app` is passed in rather than guarded here so each caller keeps its
    /// own guard/log ordering (split creators guard app before the
    /// focused-terminal resolution side effect; reconnectTab guards silently).
    private func makeConnectedTerminalView(
        app: ghostty_app_t,
        config: ConnectionConfig,
        sourceProfileID: UUID? = nil
    ) -> Ghostty.TerminalView {
        let terminalView = Ghostty.TerminalView(app, ghosttyApp: ghosttyApp, connectionConfig: config, windowId: windowId)
        terminalView.sourceProfileID = sourceProfileID
        terminalView.setWindowActive(isWindowFocused)
        wireWindowScopedCallbacks(on: terminalView)
        terminalView.isLogicallyFocused = true
        return terminalView
    }

    /// Shared tab-creation tail: wrap the view in a TerminalTab, insert it
    /// after the current tab, and select/focus it.
    ///
    /// `title` is an explicit parameter and must NOT be derived from
    /// `ConnectionConfig.displayName` — for roam protocols (Mosh/Trzsz) that
    /// string is prefixed with "roam "; tab titles use the plain
    /// `sshConfig.displayName`.
    private func openTerminalTab(
        config: ConnectionConfig,
        title: String,
        sourceProfileID: UUID? = nil,
        suppressesTabBarAnimation: Bool = false,
        pendingFileToOpen: String? = nil,
        startupCommand: String? = nil
    ) {
        guard let app = ghosttyApp.app else {
            Ghostty.logger.error("Cannot create tab: Ghostty app not initialized")
            return
        }

        let terminalView = makeConnectedTerminalView(
            app: app,
            config: config,
            sourceProfileID: sourceProfileID
        )
        terminalView.pendingFileToOpen = pendingFileToOpen
        terminalView.pendingStartupCommand = startupCommand

        insertPaneAsTab(
            terminalView,
            title: title,
            suppressesTabBarAnimation: suppressesTabBarAnimation,
            profileThemeSourceID: sourceProfileID
        )
    }

    /// Pane-typed tab insertion core shared by every creation path: wrap the
    /// pane in a tab, stamp `containingTabID`, insert after the current tab,
    /// select it, wire title observation, and focus the pane. Callers are
    /// responsible for pre-insertion pane setup (window-active stamping,
    /// `isLogicallyFocused`, callbacks) — see `makeConnectedTerminalView`.
    /// Non-terminal panes (VNC) call this directly with their own factory.
    func insertPaneAsTab(
        _ pane: SplitPaneView,
        title: String,
        suppressesTabBarAnimation: Bool = false,
        profileThemeSourceID: UUID? = nil
    ) {
        let newTab = TerminalTab(paneView: pane, title: title, windowId: windowId)
        pane.containingTabID = newTab.id
        applyProfileTheme(profileID: profileThemeSourceID, tabID: newTab.id)

        // Insert tab after current tab (not at end)
        let insertionIndex = min(selectedTabIndex + 1, terminals.count)

        if suppressesTabBarAnimation {
            // Insert + select the new tab WITHOUT animation. Otherwise the tab
            // bar's structural appearance (the selected tab's Liquid Glass springs
            // in over ~0.4s) re-evaluates the expensive tab-bar body once per
            // animation frame — visible as the "one-time bounce on open" pulse and
            // a burst of MainActor work right when the window is opening. Instant
            // insertion collapses that storm to a single render.
            var tabCreationTxn = Transaction()
            tabCreationTxn.disablesAnimations = true
            withTransaction(tabCreationTxn) {
                terminals.insert(newTab, at: insertionIndex)
                selectedTabIndex = insertionIndex
            }

            // Request the scrolling tab bar scroll to the newly inserted tab
            // (covers the rightmost-add case where neither `terminals.count` nor
            // `selectedTabIndex` change observation reliably scrolls in time).
            tabsModel.pendingScrollToTabID = newTab.id

            // Set up title observation to sync terminal title changes to tab title
            setupTitleObservation(at: insertionIndex)
        } else {
            terminals.insert(newTab, at: insertionIndex)
            // Request the scrolling tab bar scroll to the newly inserted tab
            // (covers the rightmost-add case where neither `terminals.count` nor
            // `selectedTabIndex` change observation reliably scrolls in time).
            tabsModel.pendingScrollToTabID = newTab.id

            // Set up title observation to sync terminal title changes to tab title
            setupTitleObservation(at: insertionIndex)

            // Select the new tab
            selectedTabIndex = insertionIndex
        }

        // Set focus to the new tab
        setFocusedPane(pane, inTab: insertionIndex)
    }

    /// Shared split-creation tail: resolve the split target in the selected
    /// tab (falling back to a fresh tab when there is none), insert the new
    /// view into the split tree, and focus it.
    ///
    /// `configFor` receives the resolved split target because local-shell
    /// splits inherit the target's working directory; other protocols ignore
    /// it and return a fixed config.
    private func openTerminalSplit(
        direction: SplitTree<SplitPaneView>.NewDirection,
        logLabel: String,
        sourceProfileID: UUID? = nil,
        startupCommand: String? = nil,
        configFor: @MainActor (SplitPaneView) -> ConnectionConfig,
        fallbackToTab: @MainActor () -> Void
    ) {
        guard terminals.indices.contains(selectedTabIndex) else {
            // No tab exists, create a new tab instead
            fallbackToTab()
            return
        }
        guard let app = ghosttyApp.app else {
            Ghostty.logger.error("Cannot create split: Ghostty app not initialized")
            return
        }

        // Get the focused pane or use the first one in the current tab
        var focusedPane = terminals[selectedTabIndex].focusedPane
        if focusedPane == nil, let firstPane = terminals[selectedTabIndex].splitTree.first {
            focusedPane = firstPane
            terminals[selectedTabIndex].focusedPane = firstPane
        }

        guard let targetPane = focusedPane else {
            // No pane to split from, create a new tab instead
            fallbackToTab()
            return
        }

        let newTerminalView = makeConnectedTerminalView(
            app: app,
            config: configFor(targetPane),
            sourceProfileID: sourceProfileID
        )

        newTerminalView.pendingStartupCommand = startupCommand

        insertPaneAsSplit(
            newTerminalView,
            at: targetPane,
            inTab: selectedTabIndex,
            direction: direction,
            logLabel: logLabel,
            profileThemeSourceID: sourceProfileID
        )
    }

    /// Pane-typed split insertion core: stamp `containingTabID`, insert the
    /// pane into the tab's split tree at the target, and focus it. Same
    /// pre-insertion setup contract as `insertPaneAsTab`; non-terminal panes
    /// (VNC) call this directly with their own factory.
    func insertPaneAsSplit(
        _ pane: SplitPaneView,
        at targetPane: SplitPaneView,
        inTab tabIndex: Int,
        direction: SplitTree<SplitPaneView>.NewDirection,
        logLabel: String,
        profileThemeSourceID: UUID? = nil
    ) {
        pane.containingTabID = terminals[tabIndex].id

        // Insert the new split and set focus
        do {
            terminals[tabIndex].splitTree = try terminals[tabIndex].splitTree.insert(
                view: pane,
                at: targetPane,
                direction: direction
            )

            applyProfileTheme(profileID: profileThemeSourceID, tabID: terminals[tabIndex].id)

            // Set focus immediately - Ghostty focus is independent of UIKit focus
            setFocusedPane(pane, inTab: tabIndex)
        } catch {
            Ghostty.logger.error("Failed to create \(logLabel) split: \(error)")
        }
    }

    /// Only explicit launches pass a profile ID here. Restore and pane moves
    /// retain their saved/user-selected tab override instead of reapplying it.
    private func applyProfileTheme(profileID: UUID?, tabID: UUID) {
        guard let profileID,
              let name = ConnectionProfileManager.shared.profile(for: profileID)?.themeName,
              ThemeManager.shared.themeInfo(for: name) != nil else { return }
        themeOverrideManager.setTabTheme(tabId: tabID, themeName: name)
    }

    // MARK: - Per-Protocol Creators

    func createSSHTab(with config: SSHConfig, sourceProfileID: UUID? = nil) {
        openTerminalTab(config: .ssh(config), title: config.displayName, sourceProfileID: sourceProfileID)
    }

    func createMoshTab(with config: MoshConfig, sourceProfileID: UUID? = nil) {
        openTerminalTab(config: .mosh(config), title: config.sshConfig.displayName, sourceProfileID: sourceProfileID)
    }

    func createMoshSplit(with config: MoshConfig, direction: SplitTree<SplitPaneView>.NewDirection, sourceProfileID: UUID? = nil) {
        openTerminalSplit(
            direction: direction,
            logLabel: "Mosh",
            sourceProfileID: sourceProfileID,
            configFor: { _ in .mosh(config) },
            fallbackToTab: { self.createMoshTab(with: config, sourceProfileID: sourceProfileID) }
        )
    }

    func createTrzszTab(with config: TrzszConfig, sourceProfileID: UUID? = nil) {
        openTerminalTab(config: .trzsz(config), title: config.sshConfig.displayName, sourceProfileID: sourceProfileID)
    }

    func createTrzszSplit(with config: TrzszConfig, direction: SplitTree<SplitPaneView>.NewDirection, sourceProfileID: UUID? = nil) {
        openTerminalSplit(
            direction: direction,
            logLabel: "Trzsz",
            sourceProfileID: sourceProfileID,
            configFor: { _ in .trzsz(config) },
            fallbackToTab: { self.createTrzszTab(with: config, sourceProfileID: sourceProfileID) }
        )
    }

    /// Ensures ghostty-helper is available before running a local shell action on Catalyst
    /// Will auto-launch helper if running in non-sandboxed mode
    func performLocalShellAction(description: String, action: @escaping @MainActor () -> Void) {
#if targetEnvironment(macCatalyst)
        // Fast path: when the helper has already been confirmed running, run
        // the action synchronously instead of awaiting ensureHelperRunning()
        // on the (often congested) MainActor — the open-latency trace showed
        // that await costing 0.5–2s at window/tab open. Re-verify in the
        // background so a helper that has since died gets relaunched for the
        // session's own connect path.
        if HelperConnection.shared.isKnownRunning {
            action()
            // Re-verify the helper, but OFF the critical open path: this pings
            // the helper on the same MainActor/socket queue that the session's
            // createShell needs, so running it now would compete during shell
            // startup. A few seconds later is plenty to catch a died helper.
            Task(priority: .utility) {
                try? await Task.sleep(for: .seconds(3))
                if !(await HelperConnection.shared.ensureHelperRunning()) {
                    Ghostty.logger.warning("Local shell action (\(description)): helper re-verify failed")
                }
            }
            return
        }

        Task {
            let isAvailable = await HelperConnection.shared.ensureHelperRunning()
            await MainActor.run {
                if isAvailable {
                    action()
                } else {
                    Ghostty.logger.warning("Cannot \(description): ghostty-helper is not available")
                    alerts.showHelperMissingAlert = true
                }
            }
        }
#else
        action()
#endif
    }

    /// Global New Tab command; the legacy shortcut identifier remains stable.
    @MainActor
    func handleNewTabCommand() {
        guard pendingNewTabRequest == nil, unavailableNewTabRequest == nil else { return }
        let request = captureNewTabRequest()
        switch NewTabAction.current {
        case .localShell:
            createLocalShellTab(for: request)
        case .duplicateFocused:
            runNewTabDuplicate(request)
        case .ask:
            pendingNewTabRequest = request
        }
    }

    func captureNewTabRequest() -> NewTabRequest {
        guard terminals.indices.contains(selectedTabIndex),
              let pane = terminals[selectedTabIndex].focusedPane else {
            return NewTabRequest(target: .local, localDirectory: nil)
        }
        if let vnc = pane as? VNCPaneView {
            return NewTabRequest(target: .connection(.vnc(vnc.config), vnc.sourceProfileID), localDirectory: nil)
        }
        guard let terminal = pane.asTerminal else {
            return NewTabRequest(target: .connections, localDirectory: nil)
        }
        if let controller = newTabTmuxController(for: terminal), controller.isActive {
            return NewTabRequest(target: .tmux(terminal.uuid, controller), localDirectory: nil)
        }
        switch terminal.connectionConfig {
        case .local:
            // A stale tmux surface is not a real local shell.
            guard !terminal.isTmuxPane else {
                return NewTabRequest(target: .connections, localDirectory: nil)
            }
            if let profileID = terminal.sourceProfileID {
                return NewTabRequest(
                    target: .connection(.local(workingDirectory: terminal.pwd), profileID),
                    localDirectory: terminal.pwd
                )
            }
            return NewTabRequest(target: .local, localDirectory: terminal.pwd)
        case .trzszTransfer:
            return NewTabRequest(target: .connections, localDirectory: nil)
        default:
            return NewTabRequest(target: .connection(terminal.connectionConfig, terminal.sourceProfileID), localDirectory: nil)
        }
    }

    private func newTabTmuxController(for terminal: Ghostty.TerminalView) -> TmuxController? {
        if let binding = terminal.tmuxPaneBinding {
            return TmuxController.controller(forOwnerSurface: binding.parentSurface)
        }
        return terminal.tmuxController
    }

    private func requestNewTmuxWindow(on terminal: Ghostty.TerminalView, ownedBy controller: TmuxController) -> Bool {
        guard controller.isActive, newTabTmuxController(for: terminal) === controller else { return false }
        if terminal.isTmuxPane {
            terminal.requestTmuxNewWindow()
            return true
        }
        return terminal.requestTmuxNewWindowFromGateway()
    }

    func createLocalShellTab(for request: NewTabRequest) {
        performLocalShellAction(description: "open a local shell tab") {
            self.openTerminalTab(config: .local(workingDirectory: request.localDirectory),
                                 title: String(localized: "Local Shell"), suppressesTabBarAnimation: true)
        }
    }

    func runNewTabDuplicate(_ request: NewTabRequest) {
        switch request.target {
        case .local:
            createLocalShellTab(for: request)
        case .connections:
            addNewTab()
        case .tmux(let terminalID, let controller):
            guard controller.isActive else {
                unavailableNewTabRequest = request
                return
            }
            let panes = terminals.flatMap { $0.splitTree.terminalLeaves }
            // Prefer the captured pane to preserve insertion position. If tmux
            // removed it, the captured session can still create a new window.
            if let original = panes.first(where: { $0.uuid == terminalID }),
               requestNewTmuxWindow(on: original, ownedBy: controller) { return }
            if let gateway = TmuxWindowRegistry.gatewayView(ownerTerminalUUID: controller.ownerTerminalUUIDForNotifications),
               requestNewTmuxWindow(on: gateway, ownedBy: controller) { return }
            for pane in panes where pane.uuid != terminalID {
                if requestNewTmuxWindow(on: pane, ownedBy: controller) { return }
            }
            unavailableNewTabRequest = request
        case .connection(let original, let profileID):
            // Never reuse roam/cloud session IDs. Keep the effective config and
            // profile provenance rather than re-reading an edited saved profile.
            let config = original.forNewSplit()
            switch config {
            case .local:
                performLocalShellAction(description: "duplicate a local shell") {
                    self.openTerminalTab(config: config, title: config.displayName,
                                         sourceProfileID: profileID, suppressesTabBarAnimation: true)
                }
            case .vnc(let vnc):
                createVNCTab(with: vnc, sourceProfileID: profileID)
            case .mosh(let mosh), .shellLaunchedMosh(let mosh, _):
                createMoshTab(with: mosh, sourceProfileID: profileID)
            case .trzsz(let trzsz), .shellLaunchedTrzsz(let trzsz, _):
                createTrzszTab(with: trzsz, sourceProfileID: profileID)
            case .ssh(let ssh), .shellLaunchedSSH(let ssh, _):
                createSSHTab(with: ssh, sourceProfileID: profileID)
            case .trzszTransfer:
                addNewTab()
            default:
                openTerminalTab(config: config, title: config.displayName, sourceProfileID: profileID)
            }
        }
    }

    func createLocalProfile(_ profile: ConnectionProfile, splitOption: SSHConnectionView.SplitOption) {
        guard profile.isAvailableOnCurrentPlatform, let local = profile.localConfig else { return }
        performLocalShellAction(description: "open a local shell profile") {
            let configuredDirectory = local.workingDirectory.flatMap { raw -> String? in
                guard let path = Self.resolveIntentDirectory(raw) else { return nil }
                #if targetEnvironment(macCatalyst)
                // The helper exits if chdir fails; use HOME for a missing
                // directory (common when a profile syncs to another Mac).
                var isDirectory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    || !isDirectory.boolValue {
                    return Self.resolveIntentDirectory("~")
                }
                #endif
                return path
            }
            @MainActor func inheritedDirectory(from pane: SplitPaneView?) -> String? {
                guard let terminal = pane?.asTerminal,
                      case .local = terminal.connectionConfig else { return nil }
                return terminal.pwd
            }
            let openTab: @MainActor () -> Void = {
                let focused = self.terminals.indices.contains(self.selectedTabIndex)
                    ? self.terminals[self.selectedTabIndex].focusedPane : nil
                self.openTerminalTab(
                    config: .local(workingDirectory: configuredDirectory ?? inheritedDirectory(from: focused)),
                    title: profile.name, sourceProfileID: profile.id,
                    suppressesTabBarAnimation: true, startupCommand: local.startupCommand
                )
            }
            switch splitOption {
            case .newTab:
                openTab()
            case .splitRight, .splitDown:
                self.openTerminalSplit(
                    direction: splitOption == .splitRight ? .right : .down,
                    logLabel: "local profile", sourceProfileID: profile.id,
                    startupCommand: local.startupCommand,
                    configFor: { pane in
                        .local(workingDirectory: configuredDirectory ?? inheritedDirectory(from: pane))
                    },
                    fallbackToTab: openTab
                )
            }
        }
    }

    func createLocalShellTab() {
        performLocalShellAction(description: "open a local shell tab") {
            self.createLocalShellTabInternal()
        }
    }

    func createLocalShellTabInternal() {
        // Get CWD from focused terminal (if any) to inherit working directory
        let inheritedCwd: String?
        if selectedTabIndex >= 0 && selectedTabIndex < terminals.count,
           let focusedTerminal = terminals[selectedTabIndex].focusedTerminal,
           case .local = focusedTerminal.connectionConfig {
            inheritedCwd = focusedTerminal.pwd
        } else {
            inheritedCwd = nil
        }

        openTerminalTab(
            config: .local(workingDirectory: inheritedCwd),
            title: "Local Shell",
            suppressesTabBarAnimation: true
        )
    }

    /// Shortcuts entry point (see AppIntentCoordinator): opens a local shell
    /// in the requested directory instead of inheriting the focused tab's
    /// cwd. Accepts `~`-relative, relative, or absolute paths; anything
    /// non-absolute resolves against Documents (the shell's HOME). A path
    /// that doesn't exist falls back to HOME inside the session.
    /// `startupCommand` (AppleScript) is typed into the shell once it starts.
    func createLocalShellTab(intentDirectory: String?, startupCommand: String? = nil) {
        // Backstop: automation must never materialize a tab in the hidden visor.
        guard !isVisorWindow else { return }
        performLocalShellAction(description: "open a local shell tab") {
            let resolved = intentDirectory
                .flatMap { Self.resolveIntentDirectory($0) }
            self.openTerminalTab(
                config: .local(workingDirectory: resolved),
                title: "Local Shell",
                suppressesTabBarAnimation: true,
                startupCommand: startupCommand
            )
        }
    }

    static func resolveIntentDirectory(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Match the shell's HOME: the user home on macOS, Documents on iOS.
        #if targetEnvironment(macCatalyst)
        let home = NSHomeDirectory()
        #else
        let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #endif
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + "/" + String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("/") { return trimmed }
        return home + "/" + trimmed
    }

    /// Opens a local-shell tab that launches $EDITOR on a shared file that
    /// was imported into ~/incoming (see FileOpenCoordinator). iOS/iPadOS/
    /// visionOS only — macOS file-open requests become an alert upstream.
    func createFileEditorTab(filePath: String) {
        openTerminalTab(
            config: .local(workingDirectory: (filePath as NSString).deletingLastPathComponent),
            title: (filePath as NSString).lastPathComponent,
            suppressesTabBarAnimation: true,
            pendingFileToOpen: filePath
        )
    }

    func createLocalShellSplit(direction: SplitTree<SplitPaneView>.NewDirection) {
        performLocalShellAction(description: "create a local shell split") {
            self.createLocalShellSplitInternal(direction: direction)
        }
    }

    func createLocalShellSplitInternal(direction: SplitTree<SplitPaneView>.NewDirection) {
        openTerminalSplit(
            direction: direction,
            logLabel: "local shell",
            // Local splits inherit the working directory from the resolved
            // split target (not the tab's focused terminal at call time).
            // Non-terminal split targets have no cwd to inherit.
            configFor: {
                guard let terminal = $0.asTerminal,
                      case .local = terminal.connectionConfig else {
                    return .local(workingDirectory: nil)
                }
                return .local(workingDirectory: terminal.pwd)
            },
            fallbackToTab: { self.createLocalShellTabInternal() }
        )
    }
}

// MARK: - Kubernetes Node Shell Tab Management

extension MainView {

    func createKubernetesNodeShellTab(with config: KubernetesNodeShellConfig) {
        openTerminalTab(
            config: .kubernetes(config),
            title: config.displayName
        )
    }

    func createKubernetesNodeShellSplit(with config: KubernetesNodeShellConfig, direction: SplitTree<SplitPaneView>.NewDirection) {
        openTerminalSplit(
            direction: direction,
            logLabel: "Kubernetes node shell",
            configFor: { _ in .kubernetes(config) },
            fallbackToTab: { self.createKubernetesNodeShellTab(with: config) }
        )
    }
}

// MARK: - Console Tab Management

extension MainView {

    func createConsoleTab(with config: ConsoleConfig) {
        openTerminalTab(
            config: .console(config),
            title: config.displayName
        )
    }

    func createConsoleSplit(with config: ConsoleConfig, direction: SplitTree<SplitPaneView>.NewDirection) {
        openTerminalSplit(
            direction: direction,
            logLabel: "console",
            configFor: { _ in .console(config) },
            fallbackToTab: { self.createConsoleTab(with: config) }
        )
    }
}

// MARK: - EC2 Console Tab Creation

extension MainView {

    func createEC2ConsoleTab(with config: EC2ConsoleConfig) {
        // Adopts the shared insertion clamp and setupTitleObservation call —
        // both verified no-ops relative to this creator's previous bespoke
        // form (selectedTabIndex can't exceed bounds; startObserving is
        // idempotent and already runs in TabModel.init).
        openTerminalTab(
            config: .ec2Console(config),
            title: config.displayName
        )
    }

    func createEC2ConsoleSplit(with config: EC2ConsoleConfig, direction: SplitTree<SplitPaneView>.NewDirection) {
        openTerminalSplit(
            direction: direction,
            logLabel: "EC2 console",
            configFor: { _ in .ec2Console(config) },
            fallbackToTab: { self.createEC2ConsoleTab(with: config) }
        )
    }
}

// MARK: - Tab Duplication

extension MainView {

    func duplicateCurrentTabWithSSH() {
        runNewTabDuplicate(captureNewTabRequest())
    }
}

// MARK: - Tab Reordering

extension MainView {

    /// Move a tab from one position to another (user gesture: sidebar drag
    /// or Move Left/Right context menu)
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < terminals.count,
              destinationIndex >= 0, destinationIndex < terminals.count else { return }

        // Store the ID of the currently selected tab to preserve selection
        let selectedTabId = terminals[selectedTabIndex].id
        let movingTab = terminals[sourceIndex]
        let targetTab = terminals[destinationIndex]

        guard tabsModel.moveTabInActiveOrder(movingID: movingTab.id, toTargetID: targetTab.id) else {
            return
        }

        // Restore selection based on ID
        if let newIndex = terminals.firstIndex(where: { $0.id == selectedTabId }) {
            selectedTabIndex = newIndex
        }

        // tmux window tabs: mirror the user's reorder to the server so the
        // order sticks (and propagates to other attached clients) instead of
        // snapping back at the next reconcile.
        if !tabsModel.isProjectGroupingActive {
            TmuxController.syncWindowOrderAfterUserMove(of: movingTab, in: terminals)
        }
    }

    /// Reorder tabs WITHIN the raw slots occupied by the given class
    /// members, leaving every other tab's raw index untouched (the sidebar's
    /// tmux-WINDOW drag path; regular tabs use the top bar's raw `moveTab`).
    /// The sidebar groups tmux window tabs under their gateway, so visually
    /// adjacent rows can be far apart in the raw array; a raw remove+insert
    /// move would shift unrelated tabs that sit between them.
    /// `orderedClassIDs` is the class's complete membership in its new
    /// order; `draggedID` is the row the user moved.
    ///
    /// Local-only: live drag steps call this on every hover change; the
    /// tmux server commit happens ONCE per gesture via
    /// `commitTabReorderToTmux` at drop time.
    func reorderTabsPreservingSlots(orderedClassIDs: [UUID], draggedID: UUID) {
        let selectedTabId = terminals.indices.contains(selectedTabIndex)
            ? terminals[selectedTabIndex].id
            : nil
        tabsModel.setActiveOrderSubsequence(orderedClassIDs)

        if let selectedTabId,
           let newIndex = terminals.firstIndex(where: { $0.id == selectedTabId }) {
            selectedTabIndex = newIndex
        }
    }

    /// Commit a finished sidebar drag: push the dragged tmux window tab's
    /// final order to the server with one move-window (user gesture, never
    /// reconcile-driven; no-op for non-tmux tabs or unchanged order).
    func commitTabReorderToTmux(draggedID: UUID) {
        guard let draggedTab = terminals.first(where: { $0.id == draggedID }) else { return }
        TmuxController.syncWindowOrderAfterUserMove(of: draggedTab, in: terminals)
    }
}

// MARK: - Tab Closing

extension MainView {

    /// Dispatch the user-configured close action for a tmux -CC window tab
    /// (the tab's ✕ button, or ⌘W on a single-pane tmux window). Returns true
    /// when it handled the close — the caller must NOT tear the tab down
    /// locally: the server reconcile (or the chosen action) drives teardown.
    /// Returns false when the tab isn't a live tmux window tab so the caller
    /// falls back to a normal local close. (id=tmux-tab-close-action)
    @MainActor
    func handleTmuxWindowTabClose(_ tab: TerminalTab) -> Bool {
        guard tab.isTmuxWindow, let windowId = tab.tmuxWindowId,
              let pane = tab.splitTree.terminalLeaves.first(where: { $0.isTmuxPane }),
              let binding = pane.tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return false }

        let action = TmuxTabCloseAction.current
        if action == .ask {
            pendingTmuxCloseTabID = tab.id
            return true
        }
        return performTmuxClose(action, tab: tab, pane: pane,
                                controller: controller, windowId: windowId)
    }

    /// Perform a concrete tmux tab-close action (never resolves `.ask`).
    /// Factored out so the "Ask Each Time" action sheet can invoke each branch
    /// directly. (id=tmux-tab-close-action)
    @MainActor
    @discardableResult
    func performTmuxClose(_ action: TmuxTabCloseAction,
                          tab: TerminalTab,
                          pane: Ghostty.TerminalView,
                          controller: TmuxController,
                          windowId: Int) -> Bool {
        switch action {
        case .closeWindow:
            return pane.requestTmuxKillWindow()
        case .detachSession:
            controller.requestGracefulDetach(source: "tab-close")
            return true
        case .detachSessionAndCloseGateway:
            controller.closeGatewayTabAfterDetach = true
            controller.requestGracefulDetach(source: "tab-close-gateway")
            return true
        case .hideTab:
            // Hiding an already-hidden tab is a no-op — e.g. the destructive
            // "Close Tab" on an already-hidden window row in the sidebar. Don't
            // report that as handled (the close would silently do nothing).
            // Falling through to a local close would desync (the window still
            // lives on the server), so the real fallback is to destroy it.
            // (id=tmux-tab-close-action)
            if controller.hideWindow(windowId: windowId) {
                return true
            }
            return pane.requestTmuxKillWindow()
        case .ask:
            // Safety net: a re-prompt instead of silently dropping the close.
            pendingTmuxCloseTabID = tab.id
            return true
        }
    }

    /// Resolve the tab captured by the "Ask Each Time" action sheet and run the
    /// chosen action. Re-resolves by id (the tab array may have shifted) and
    /// no-ops if the tab or its live gateway is gone. (id=tmux-tab-close-action)
    @MainActor
    func runPendingTmuxClose(_ action: TmuxTabCloseAction) {
        defer { pendingTmuxCloseTabID = nil }
        guard let id = pendingTmuxCloseTabID,
              let tab = terminals.first(where: { $0.id == id }),
              tab.isTmuxWindow, let windowId = tab.tmuxWindowId,
              let pane = tab.splitTree.terminalLeaves.first(where: { $0.isTmuxPane }),
              let binding = pane.tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              controller.isActive else { return }
        performTmuxClose(action, tab: tab, pane: pane, controller: controller, windowId: windowId)
    }

    func closeTab(at index: Int) {
        // Validate index before accessing array
        guard terminals.indices.contains(index) else { return }

        // tmux -CC gateway: closing the gateway tab must also tear down the tmux
        // window tabs it projected, otherwise they're left frozen with no live
        // gateway behind them. forceQuit() prunes those tabs/panes (each pane via
        // cleanup) and clears the gateway flag; we then re-resolve this tab's index
        // (the array shifted) and recurse, which takes the normal close path.
        // Gate on `hasProjectedWindows` (window tabs still exist) rather than
        // `isActive`: a gateway closed mid graceful-detach has isActive == false
        // (isDetaching) yet still has window tabs to prune. It also can't re-enter —
        // forceQuit empties windowTabs, so the recursion sees hasProjectedWindows ==
        // false and falls through to a normal close.
        // ROOTSHELL-TMUX (id=tmux-gateway-close-cascade)
        let closingTab = terminals[index]
        if closingTab.isTmuxGateway,
           let controller = closingTab.splitTree.terminalLeaves.first(where: { $0.tmuxController != nil })?.tmuxController,
           controller.hasProjectedWindows {
            controller.forceQuit()
            guard let resolved = terminals.firstIndex(where: { $0.id == closingTab.id }) else { return }
            closeTab(at: resolved)
            return
        }

        // tmux -CC window tab: route the close to the tmux server, mirroring
        // closeSplit's kill-pane routing. Removing the tab locally would
        // desync: the window survives on the server while the controller
        // keeps stale windowTabs/paneViews entries that every later reconcile
        // early-returns on (the tab would never come back while attached).
        // The reconcile's prune removes the tab and selects its neighbor once
        // tmux confirms. When the gateway is gone or detaching
        // (requestTmuxKillWindow returns false), fall through to a normal
        // local close so the user can still clear a frozen tab; ensureWindow
        // suppresses its self-heal while the controller is detaching/ended,
        // so a queued reconcile cannot resurrect that intentional close.
        // Restored placeholders have tmuxWindowId == nil and take the local
        // path too. ROOTSHELL-TMUX (id=tmux-window-tab-close-server)
        if closingTab.isTmuxWindow, closingTab.tmuxWindowId != nil,
           handleTmuxWindowTabClose(closingTab) {
            return
        }

        // Allow closing the last tab (will show empty state or new connection sheet)
        // guard terminals.count > 1 else { return }

        let tabId = terminals[index].id
        #if !CHINA_BUILD
        // Clean up AI Agent state for this tab (disconnects executor, removes from
        // dictionary / sidebar / window state / dismisses sheet if active).
        invalidateAIAgentSession(for: tabId)
        voiceAgentSessions[tabId]?.stop()
        voiceAgentSessions.removeValue(forKey: tabId)
        #endif

        // Cleanup all panes in this tab before removing
        for paneView in terminals[index].splitTree {
            // Resign first responder before cleanup if this pane has focus
            if paneView.isFirstResponder {
                paneView.resignFirstResponder()
            }
            paneView.isLogicallyFocused = false
            if let terminalView = paneView.asTerminal {
                // Resume any pending keyboard-interactive prompt for this terminal
                // (cancel), so its auth future doesn't park until the login timeout.
                withdrawKeyboardInteractive(for: terminalView)
                terminalView.cleanup(reason: .userClose)
            } else {
                paneView.prepareForClose()
            }
        }

        // Track whether we're closing left of the active tab
        let closingLeftOfActive = index < selectedTabIndex
        let closingActiveTab = index == selectedTabIndex
        // In grouped mode, neighbor selection must follow the sidebar's
        // grouped display order — prefer a sibling in the closing tab's group,
        // and only when that group empties fall to the nearest tab in the
        // flattened display order. Computed before removal so the grouping
        // snapshot still contains the closing tab. (id=grouped-close-neighbor)
        let groupedCloseFallbackID: UUID? = closingActiveTab
            ? tabsModel.groupedCloseNeighbor(for: tabId)
            : nil

        // Calculate new selection index AFTER removal
        let newIndex: Int
        if closingLeftOfActive {
            // Tab closed to the left - adjust index to stay on same tab
            newIndex = selectedTabIndex - 1
        } else if closingActiveTab {
            // Closing active tab - select the tab that will slide into this position
            // or the previous one if we're at the end
            newIndex = min(index, terminals.count - 2)  // -2 because we haven't removed yet
        } else {
            // Tab closed to the right - no change needed
            newIndex = selectedTabIndex
        }

        // Closing down to a single tab crosses equal-width/scrolling →
        // singleTab mode, which animates the lone remaining tab's Liquid Glass
        // appearance and re-renders the tab bar every frame — visible as a tab
        // bar "pulse" and a dull roam/tmux badge over the transitioning glass
        // (the same single-tab appearance storm fixed in
        // createLocalShellTabInternal). Suppress animation for that crossing;
        // multi-tab closes keep the slide. `withAnimation`/`withTransaction`
        // also force the selection re-evaluation even when the index is
        // unchanged.
        let collapsingToSingleTab = tabsModel.navigationTabs.filter { $0.id != tabId }.count <= 1
        if collapsingToSingleTab {
            var closeTxn = Transaction()
            closeTxn.disablesAnimations = true
            _ = withTransaction(closeTxn) {
                terminals.remove(at: index)
            }
        } else {
            _ = withAnimation(.easeInOut(duration: 0.2)) {
                terminals.remove(at: index)
            }
        }

        // Handle empty state
        guard !terminals.isEmpty else {
            selectedTabIndex = 0
            #if STANDALONE && targetEnvironment(macCatalyst)
            if windowId == "visor" {
                // Keep the visor usable: closing its final tab immediately
                // provisions a fresh local shell instead of leaving an
                // empty hidden MainView that may never receive another
                // first-launch creation signal.
                Task { @MainActor in
                    _ = await ensureVisorHasTerminal()
                }
                return
            }
            #endif

            // Auto-show connection sheet (same as first launch)
            // since there's no UI to recover from empty state
            addNewTab()
            return
        }

        // Clamp newIndex to valid range
        var clampedIndex = max(0, min(newIndex, terminals.count - 1))
        if let groupedCloseFallbackID,
           let fallbackIndex = terminals.firstIndex(where: { $0.id == groupedCloseFallbackID }) {
            clampedIndex = fallbackIndex
        }

        // Always update selectedTabIndex to trigger onChange and UI refresh
        // Even if the numerical value is the same, the transaction should cause a refresh.
        // When collapsing to a single tab, suppress animation here too — animating
        // the selection drives the lone tab's Liquid Glass appearance (the pulse /
        // dull badge). Multi-tab closes keep the slide.
        if collapsingToSingleTab {
            var selectTxn = Transaction()
            selectTxn.disablesAnimations = true
            withTransaction(selectTxn) {
                selectedTabIndex = clampedIndex
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTabIndex = clampedIndex
            }
        }

        // Restore focus to the selected tab
        // When a tab closes and another slides into the same index position, onChange(of: selectedTabIndex)
        // doesn't fire because the value hasn't changed. We must manually activate the new tab's terminal.
        if closingLeftOfActive || closingActiveTab {
            if clampedIndex < terminals.count {
                // Mark all surfaces in the new active tab as visible (mirrors handleSelectedTabChange)
                for terminal in terminals[clampedIndex].splitTree {
                    terminal.setOcclusion(true)
                }

                if let pane = terminals[clampedIndex].focusedPane ?? terminals[clampedIndex].splitTree.first {
                    terminals[clampedIndex].focusedPane = pane
                    pane.isLogicallyFocused = true
                    // Set flag so window observers will focus this terminal when window becomes ready
                    pane.asTerminal?.shouldBecomeFirstResponderWhenReady = true
                    // Try immediate focus - succeeds if window is already ready
                    _ = pane.becomeFirstResponder()

                    // USER closed a tab and landed on a tmux pane: sync tmux's
                    // active window/pane explicitly. The core no longer echoes
                    // select-pane on focus gain, so bare becomeFirstResponder
                    // paths must send it themselves.
                    // ROOTSHELL-TMUX (id=tmux-select-pane-user-only)
                    if let terminal = pane.asTerminal, terminal.isTmuxPane {
                        terminal.requestTmuxSelectPane()
                    }

                    ghosttyApp.appTick()
                }
            }
        }
    }
}

// MARK: - SSH Split Creation

extension MainView {

    func createSSHSplit(with config: SSHConfig, direction: SplitTree<SplitPaneView>.NewDirection, sourceProfileID: UUID? = nil) {
        openTerminalSplit(
            direction: direction,
            logLabel: "SSH",
            sourceProfileID: sourceProfileID,
            configFor: { _ in .ssh(config) },
            fallbackToTab: { self.createSSHTab(with: config, sourceProfileID: sourceProfileID) }
        )
    }
}

// MARK: - SSH Authentication Handling

extension MainView {

    func handleAuthenticationRequired(for terminal: Ghostty.TerminalView, config: SSHConfig) {
        guard terminals.contains(where: { $0.splitTree.contains { $0 === terminal } }),
              authenticationRetryRequest == nil else { return }
        // Snapshot the failing pane before focus, topology, or profile changes.
        // A second callback must not retarget the picker already on screen.
        authenticationRetryRequest = SSHAuthenticationRetryRequest(
            terminalID: terminal.uuid, sourceProfileID: terminal.sourceProfileID, config: config)
        reconnectConfig = config
        showConnectionSidebar = true
    }

    func reconnectTerminal(for request: SSHAuthenticationRetryRequest, with config: SSHConfig) {
        guard let index = terminals.firstIndex(where: { tab in
            tab.splitTree.terminalLeaves.contains { $0.uuid == request.terminalID }
        }), let previous = terminals[index].splitTree.terminalLeaves.first(where: { $0.uuid == request.terminalID }),
              let app = ghosttyApp.app else {
            Ghostty.logger.info("Authentication retry source is no longer in this window")
            return
        }

        // Preserve captured provenance for credential edits, but not when the
        // user chooses a different endpoint in the connection picker.
        let sourceProfileID = request.config.host == config.host &&
            request.config.port == config.port && request.config.username == config.username
            ? request.sourceProfileID : nil
        let terminalView = makeConnectedTerminalView(app: app, config: .ssh(config), sourceProfileID: sourceProfileID)
        let tab = terminals[index]
        terminalView.containingTabID = tab.id
        do {
            tab.splitTree = try tab.splitTree.replace(node: .leaf(view: previous), with: .leaf(view: terminalView))
        } catch {
            terminalView.prepareForClose()
            Ghostty.logger.error("Cannot replace authentication retry pane: \(error)")
            return
        }
        if previous.isFirstResponder { previous.resignFirstResponder() }
        previous.isLogicallyFocused = false
        withdrawKeyboardInteractive(for: previous)
        previous.prepareForClose()
        selectedTabIndex = index
        setFocusedTerminal(terminalView, inTab: index)
        setupTitleObservation(at: index)
        notifySessionCountChanged()
    }
}

/// Stable authentication retry context; tab indexes and focus are transient.
struct SSHAuthenticationRetryRequest {
    let terminalID: UUID
    let sourceProfileID: UUID?
    let config: SSHConfig
}

/// Snapshot taken before showing the chooser so a later focus change cannot
/// silently select a different host or tmux session.
struct NewTabRequest {
    enum Target {
        case local
        case connection(ConnectionConfig, UUID?)
        case tmux(UUID, TmuxController)
        case connections
    }

    let target: Target
    let localDirectory: String?

    var duplicateTitle: String? {
        switch target {
        case .local, .connections: return nil
        case .tmux: return String(localized: "New tmux Window")
        case .connection(let config, _):
            // Roaming transports decorate displayName with "roam". Use the
            // connection's own name here without removing user-authored text.
            let name: String
            switch config {
            case .mosh(let mosh), .shellLaunchedMosh(let mosh, _):
                name = mosh.sshConfig.displayName
            case .trzsz(let trzsz), .shellLaunchedTrzsz(let trzsz, _):
                name = trzsz.sshConfig.displayName
            default:
                name = config.displayName
            }
            return String(localized: "Duplicate “\(name)”")
        }
    }
}
