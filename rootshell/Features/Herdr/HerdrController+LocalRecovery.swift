import Foundation

#if targetEnvironment(macCatalyst)
extension HerdrController {
    var localInspectionTarget: LocalHerdrControlTarget {
        LocalHerdrControlTarget(sessionName: sessionName, attachment: localControlAttachment)
    }

    /// Resolve before opening so the stream and subsequent recovery record use
    /// the same socket even if a login profile changes later. A restore also
    /// requires the original server, not merely a live session with its name.
    func prepareLocalControlAttachment() async throws -> Bool {
        guard let gateway, case .local = gateway.connectionConfig,
              let session = gateway.session as? CatalystLocalShellSession else { return true }
        let expected = gateway.restoredLocalMultiplexerAttachment
        let result = try? await HelperConnection.shared.inspectLocalMultiplexers(
            herdrTargets: [session.sessionID.uuidString: localInspectionTarget])
        guard !didEnd, !Task.isCancelled, gateway.session === session else { return false }
        guard let observed = result?[session.sessionID.uuidString] else {
            if expected != nil { throw HerdrChannelError.closed }
            return true
        }
        let attachment = observed.flatMap { $0.isValid && $0.isHerdrControl ? $0 : nil }
        if let expected, attachment?.matchesIdentity(of: expected) != true {
            gateway.cancelLocalMultiplexerRecovery()
            return false
        }
        if let attachment { localControlAttachment = attachment }
        return true
    }

    /// Called only for verified observations after the initial topology is up.
    /// Publishing transient connection errors must not erase a saved session.
    func recordLocalControlAttachment(_ attachment: LocalMultiplexerAttachment) {
        guard isActive, hasProcessedInitialSnapshot, !didEnd,
              attachment.isHerdrControl, attachment.isValid, let gateway,
              case .local = gateway.connectionConfig else { return }
        if mode == .raw, let serverPid, serverPid != Int(attachment.serverPID) { return }
        if let pending = gateway.restoredLocalMultiplexerAttachment {
            guard attachment.matchesIdentity(of: pending) else { return }
        }
        localControlAttachment = attachment
        if gateway.restoredLocalMultiplexerAttachment != nil {
            gateway.finishLocalMultiplexerRecovery(failed: false)
        }
        if gateway.localMultiplexerAttachment != attachment {
            gateway.localMultiplexerAttachment = attachment
            WindowStateManager.shared.forceSaveAllState()
        }
    }
}
#endif
