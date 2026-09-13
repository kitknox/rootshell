import Foundation
import GhosttyKit

extension Ghostty.TerminalView {
    var localMultiplexerAttachmentForPersistence: LocalMultiplexerAttachment? {
        #if targetEnvironment(macCatalyst)
        guard case .local = connectionConfig else { return nil }
        let value = restoredLocalMultiplexerAttachment ?? localMultiplexerAttachment
        return value?.isValid == true ? value : nil
        #else
        return nil
        #endif
    }

    /// Shared by leaf and projected-tab serialization, including autosaves
    /// while a local attachment or tssh stream resume is still pending.
    var hasPersistableTmuxGateway: Bool {
        if connectionConfig.isTrzsz {
            return tmuxController != nil || restoredWasTmuxGateway || tmuxResumeRequested || tmuxResumeCancelRequested
        }
        return localMultiplexerAttachmentForPersistence?.isTmuxControl == true
    }

    var hasPersistableHerdrGateway: Bool { localMultiplexerAttachmentForPersistence?.isHerdrControl == true }

    var isRestoringLocalTmux: Bool { restoredLocalMultiplexerAttachment?.isTmuxControl == true }

    /// A fresh client supplies its own DCS preamble. Never synthesize tssh
    /// resume or replay the previous gateway's ANSI into this stream.
    func releaseLocalMultiplexerScrollbackGate() -> Bool {
        guard restoredLocalMultiplexerAttachment != nil || skipLocalMultiplexerScrollback else { return false }
        pendingScrollbackRestore = false
        pendingScrollbackRestoreForLayout = false
        scrollbackWrittenAwaitingTrailer = false
        pendingResumeTrailer = nil
        outputPipeline.finishScrollbackRestoreGate()
        return true
    }

    #if targetEnvironment(macCatalyst)
    func localMultiplexerSessionCreated(supported: Bool, accepted: Bool) {
        LocalMultiplexerTracker.shared.watch(self)
        guard restoredLocalMultiplexerAttachment != nil else { return }
        _ = releaseLocalMultiplexerScrollbackGate()
        guard supported, accepted else {
            finishLocalMultiplexerRecovery(failed: true)
            return
        }
        localMultiplexerRecoveryTask?.cancel()
        let expectedSession = session
        localMultiplexerRecoveryTask = Task { @MainActor [weak self, weak expectedSession] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, let expectedSession,
                  self.session === expectedSession, self.restoredLocalMultiplexerAttachment != nil else { return }
            self.cancelLocalMultiplexerRecovery()
        }
    }

    func finishLocalMultiplexerRecovery(failed: Bool) {
        guard let restored = restoredLocalMultiplexerAttachment else { return }
        localMultiplexerRecoveryTask?.cancel()
        localMultiplexerRecoveryTask = nil
        restoredLocalMultiplexerAttachment = nil
        restorationState = .none
        NotificationCenter.default.post(name: .terminalRestorationStateChanged, object: self)
        localMultiplexerAttachment = failed ? nil : restored
        if failed {
            let wasSelected = TmuxWindowRegistry.selectedAwaitingWindow(ownerTerminalUUID: uuid) != nil
            if restored.isTmuxControl { removeAwaitingTmuxPlaceholders() }
            if restored.controlMode, let gateway = TmuxWindowRegistry.gatewayTab(ownerTerminalUUID: uuid) {
                gateway.tab.isHiddenTmuxWindow = false
                gateway.tab.pendingHiddenTmuxGatewayRestore = false
                if gateway.model.pendingHerdrSelection?.gatewayTerminalUUID == uuid {
                    gateway.model.pendingHerdrSelection = nil
                }
                if wasSelected { _ = TmuxWindowRegistry.selectGateway(ownerTerminalUUID: uuid, allowFocus: false) }
            }
            writeToGhostty(string: "\r\n" + String(localized: "Could not restore the multiplexer session.") + "\r\n")
        }
        WindowStateManager.shared.forceSaveAllState()
    }

    func cancelLocalMultiplexerRecovery() {
        guard let restored = restoredLocalMultiplexerAttachment else { return }
        if restored.isHerdrControl {
            // The gateway already has an ordinary shell. Discard only this
            // controller's auxiliary connections when recovery is cancelled.
            herdrController?.stop()
            finishLocalMultiplexerRecovery(failed: true)
            _ = releaseLocalMultiplexerScrollbackGate()
            if (session as? CatalystLocalShellSession)?.isRunning == true { return }
        }
        let wasControlMode = isRestoringLocalTmux
        // Invalidate the old callbacks before closing its PTY. No server or
        // session kill is issued; only this startup client is discarded.
        session?.onSessionEnd = nil
        sessionController.teardown(reason: .sceneTeardown)
        if wasControlMode, let surface { ghostty_surface_tmux_force_exit(surface) }
        // The helper may have substituted home for a deleted saved directory.
        // The replacement request has no attachment, so normalize its CWD here
        // before clearing recovery state and persisting the ordinary shell.
        if case .local(let cwd) = connectionConfig, let cwd {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) || !isDirectory.boolValue {
                connectionConfig = .local(workingDirectory: nil)
            }
        }
        finishLocalMultiplexerRecovery(failed: true)
        _ = releaseLocalMultiplexerScrollbackGate()
        _ = sessionController.startSession()
    }
    #endif
}

#if targetEnvironment(macCatalyst)
/// One helper census for every local PTY, including tabs that are not visible.
/// Weak ownership and session-ID checks discard replies from closed/replaced PTYs.
@MainActor
final class LocalMultiplexerTracker {
    static let shared = LocalMultiplexerTracker()
    private let terminals = NSMapTable<NSUUID, Ghostty.TerminalView>.strongToWeakObjects()
    private var timer: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        for name in [Notification.Name.tmuxAttachedSessionDidChange, .tmuxControlModeDidEnd] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let ended = note.name == .tmuxControlModeDidEnd
                let id = note.object as? UUID
                Task { @MainActor [weak self] in
                    if let id, let view = self?.terminals.object(forKey: id as NSUUID) {
                        view.localMultiplexerTrackingRevision &+= 1
                        if ended || view.restoredLocalMultiplexerAttachment == nil { view.localMultiplexerAttachment = nil }
                    }
                    self?.refresh()
                }
            })
        }
        for name in [Notification.Name.herdrControlStateDidChange, .herdrControlModeDidEnd] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let ended = note.name == .herdrControlModeDidEnd
                let id = note.object as? UUID
                Task { @MainActor [weak self] in
                    if ended, let id, let view = self?.terminals.object(forKey: id as NSUUID), view.herdrController == nil {
                        view.localMultiplexerTrackingRevision &+= 1
                        view.localMultiplexerAttachment = nil
                        if view.restoredLocalMultiplexerAttachment?.isHerdrControl == true {
                            view.finishLocalMultiplexerRecovery(failed: true)
                        } else {
                            WindowStateManager.shared.forceSaveAllState()
                        }
                    }
                    self?.refresh()
                }
            })
        }
    }

    func watch(_ terminal: Ghostty.TerminalView) {
        guard case .local = terminal.connectionConfig,
              let session = terminal.session as? CatalystLocalShellSession, session.recoverySupported else { return }
        terminals.setObject(terminal, forKey: terminal.uuid as NSUUID)
        refresh()
        guard timer == nil else { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                guard self.terminals.objectEnumerator()?.allObjects.isEmpty == false else {
                    self.timer = nil
                    return
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard WindowStateManager.isSessionPersistenceEnabled else { return }
        guard refreshTask == nil else { refreshAgain = true; return }
        let views = (terminals.objectEnumerator()?.allObjects as? [Ghostty.TerminalView] ?? []).compactMap { view -> (Ghostty.TerminalView, UUID, UInt64, HerdrController?)? in
            guard case .local = view.connectionConfig, let session = view.session as? CatalystLocalShellSession, session.isRunning else { return nil }
            return (view, session.sessionID, view.localMultiplexerTrackingRevision, view.herdrController)
        }
        guard !views.isEmpty else { return }
        var herdrTargets: [String: LocalHerdrControlTarget] = [:]
        for (view, id, _, controller) in views {
            if let controller {
                herdrTargets[id.uuidString] = controller.localInspectionTarget
            } else if let pending = view.restoredLocalMultiplexerAttachment, pending.isHerdrControl {
                herdrTargets[id.uuidString] = .init(sessionName: pending.sessionName, attachment: pending)
            }
        }
        refreshTask = Task { @MainActor [weak self] in
            defer {
                self?.refreshTask = nil
                if self?.refreshAgain == true { self?.refreshAgain = false; self?.refresh() }
            }
            guard let result = try? await HelperConnection.shared.inspectLocalMultiplexers(herdrTargets: herdrTargets) else { return }
            var changed = false
            for (view, id, revision, controller) in views {
                guard (view.session as? CatalystLocalShellSession)?.sessionID == id,
                      view.localMultiplexerTrackingRevision == revision,
                      view.herdrController === controller else { continue }
                guard let observed = result[id.uuidString] else { continue }
                let attachment = observed.flatMap { $0.isValid ? $0 : nil }
                if herdrTargets[id.uuidString] != nil {
                    // An old helper ignores the payload and returns PTY data.
                    // Only a verified controller observation may update this owner.
                    if let attachment, attachment.isHerdrControl {
                        controller?.recordLocalControlAttachment(attachment)
                    }
                    continue
                }
                if let pending = view.restoredLocalMultiplexerAttachment {
                    guard let attachment, attachment.matchesIdentity(of: pending),
                          !pending.isTmuxControl || view.tmuxController != nil else { continue }
                    view.finishLocalMultiplexerRecovery(failed: false)
                }
                if let attachment, !attachment.controlMode, let type = MultiplexerType(rawValue: attachment.kind) {
                    if type.ownsAlternateScreen {
                        if view.rawMultiplexer?.type != type || view.rawMultiplexer?.sessionName != attachment.sessionName {
                            view.rawMultiplexer = .init(type: type, sessionName: attachment.sessionName, hasOwnedAltScreen: true)
                            AgentAttentionCenter.shared.topologyDidChange()
                        }
                    } else if view.passthroughMultiplexer?.sessionName != attachment.sessionName {
                        view.passthroughMultiplexer = .init(type: type, sessionName: attachment.sessionName, canDetachSwitch: true)
                    }
                }
                if view.localMultiplexerAttachment != attachment {
                    if attachment == nil, let previous = view.localMultiplexerAttachment {
                        if view.rawMultiplexer?.type.rawValue == previous.kind { view.rawMultiplexer = nil }
                        if view.passthroughMultiplexer?.type.rawValue == previous.kind { view.passthroughMultiplexer = nil }
                        AgentAttentionCenter.shared.topologyDidChange()
                    }
                    view.localMultiplexerAttachment = attachment
                    changed = true
                }
            }
            if changed { WindowStateManager.shared.saveAllState() }
        }
    }
}
#endif
