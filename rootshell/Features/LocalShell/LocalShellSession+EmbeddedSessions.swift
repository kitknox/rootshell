#if !targetEnvironment(macCatalyst)

import Foundation
import OSLog
import Citadel

private struct EmbeddedSessionCoordinator {
    let session: TerminalSession
    let kind: EmbeddedSessionKind
    let titlePrefix: String?

    func attach(to owner: LocalShellSession) {
        owner.attachOutputCallbacks(to: session, kind: kind)
        owner.attachStandardCallbacks(
            to: session,
            titlePrefix: titlePrefix,
            kind: kind
        )
    }
}

enum EmbeddedSessionKind: Sendable {
    case ssh
    case mosh
    case trzsz
}

extension LocalShellSession {
    // MARK: - Embedded Session Helpers

    private func startEmbeddedConnectionTask(
        _ operation: @escaping @MainActor (LocalShellSession) async -> Void
    ) {
        cancelEmbeddedConnectionStartTask()

        let taskID = UUID()
        embeddedConnectionStartTaskID = taskID
        embeddedConnectionStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)

            guard self.embeddedConnectionStartTaskID == taskID else { return }
            self.embeddedConnectionStartTask = nil
            self.embeddedConnectionStartTaskID = nil
        }
    }

    func cancelEmbeddedConnectionStartTask() {
        embeddedConnectionStartTaskID = nil
        embeddedConnectionStartTask?.cancel()
        embeddedConnectionStartTask = nil
    }

    func launchEmbeddedSSHSession(config: SSHConfig) {
        startEmbeddedConnectionTask { session in
            await session.startEmbeddedSSHSession(config: config)
        }
    }

    func launchEmbeddedSFTPSession(config: SSHConfig) {
        startEmbeddedConnectionTask { session in
            await session.startEmbeddedSFTPSession(config: config)
        }
    }

    private func isCurrentEmbeddedSession(_ sessionID: ObjectIdentifier, kind: EmbeddedSessionKind) -> Bool {
        switch kind {
        case .ssh:
            guard let session = embeddedSSHSession else { return false }
            return ObjectIdentifier(session) == sessionID
        case .mosh:
            guard let session = embeddedMoshSession else { return false }
            return ObjectIdentifier(session) == sessionID
        case .trzsz:
            guard let session = embeddedTrzszSession else { return false }
            return ObjectIdentifier(session) == sessionID
        }
    }

    private func isCurrentSFTPSession(_ sessionID: ObjectIdentifier) -> Bool {
        guard let session = embeddedSFTPSession else { return false }
        return ObjectIdentifier(session) == sessionID
    }

    /// Build a partial SSH config for password prompts.
    private func makePartialSSHConfig(from config: SSHConfig) -> SSHCommandParser.PartialSSHConfig {
        SSHCommandParser.PartialSSHConfig(
            host: config.host,
            port: config.port,
            username: config.username,
            jumpHost: config.jumpHost,
            agentConfig: config.agentConfig,
            portForwardConfig: config.portForwardConfig,
            cachedIP: config.cachedIP,
            tmuxAutoEnable: config.tmuxAutoEnable,
            tmuxAutoMode: config.tmuxAutoMode,
            herdrAutoEnable: config.herdrAutoEnable,
            herdrAutoMode: config.herdrAutoMode,
            zmxAutoEnable: config.zmxAutoEnable,
            remoteCommand: config.remoteCommand,
            remoteCommandPolicy: config.remoteCommandPolicy,
            multiplexerSessionName: config.multiplexerSessionName
        )
    }

    /// Build a partial Mosh config for password prompts.
    private func makePartialMoshConfig(from config: MoshConfig) -> MoshCommandParser.PartialMoshConfig {
        MoshCommandParser.PartialMoshConfig(
            sshPartialConfig: makePartialSSHConfig(from: config.sshConfig),
            predictionMode: config.predictionMode,
            predictOverwrite: config.predictOverwrite,
            serverPath: config.serverPath
        )
    }

    /// Begin a password prompt for the given session mode.
    private func beginPasswordPrompt(_ mode: SessionMode) {
        sessionMode = mode
        passwordBuffer = ""
        onOutput?(normalizeLineEndings("Password: "))
    }

    /// Resolve SSH config or fall back to a password prompt.
    private func resolveSSHConfigOrPrompt(
        _ config: SSHConfig,
        promptMode: (SSHCommandParser.PartialSSHConfig) -> SessionMode
    ) async -> SSHConfig? {
        do {
            return try await config.resolvedConfig()
        } catch {
            let partialConfig = makePartialSSHConfig(from: config)
            beginPasswordPrompt(promptMode(partialConfig))
            return nil
        }
    }

    /// Start inline spinner animation with standard settings.
    func startInlineSpinner(
        message: String,
        style: SpinnerAnimator.ColorStyle = .connecting,
        jokeCategory: ConnectionJokeCategory = .ssh
    ) {
        inlineSpinnerAnimator = InlineSpinnerAnimator()
        let outputSink = outputSink
        inlineSpinnerAnimator?.start(
            message: message,
            style: style,
            jokeCategory: jokeCategory,
            terminalWidth: Int(pty.windowSize.cols)
        ) { [outputSink] output in
            outputSink.emitString(output)
        }
    }

    /// Stop inline spinner and emit cleanup sequence if needed.
    func cleanupInlineSpinner(emitIfEmpty: Bool = true) {
        guard let spinner = inlineSpinnerAnimator else { return }
        let cleanup = spinner.getCleanupSequence()
        spinner.stop()
        inlineSpinnerAnimator = nil
        if emitIfEmpty || !cleanup.isEmpty {
            onOutput?(cleanup)
        }
    }

    /// Attach shared output callbacks to a terminal session.
    func attachOutputCallbacks(to session: TerminalSession, kind: EmbeddedSessionKind) {
        let sessionID = ObjectIdentifier(session)
        let outputCallback = onOutput
        let outputDataCallback = onOutputData
        session.onOutput = { [weak self] output in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                outputCallback?(output)
            }
        }
        session.onOutputData = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                outputDataCallback?(data)
            }
        }
    }

    /// Attach standard title/bell/end/error callbacks to a terminal session.
    func attachStandardCallbacks(
        to session: TerminalSession,
        titlePrefix: String?,
        kind: EmbeddedSessionKind
    ) {
        let sessionID = ObjectIdentifier(session)
        session.onTitleChange = { [weak self] title in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                if let prefix = titlePrefix {
                    self.onTitleChange?("\(prefix)\(title)")
                } else {
                    self.onTitleChange?(title)
                }
            }
        }

        session.onBell = { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                self.onBell?()
            }
        }

        session.onSessionEnd = {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                switch kind {
                case .ssh:
                    self.handleSSHSessionEnd()
                case .mosh:
                    self.handleMoshSessionEnd()
                case .trzsz:
                    self.handleTrzszSessionEnd()
                }
            }
        }

        session.onError = { error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.isCurrentEmbeddedSession(sessionID, kind: kind) else { return }
                switch kind {
                case .ssh:
                    self.handleSSHSessionError(error)
                case .mosh:
                    self.handleMoshSessionError(error)
                case .trzsz:
                    self.handleTrzszSessionError(error)
                }
            }
        }
    }

    /// Record a successful SSH connection in history.
    private func recordSSHConnectionHistory(for config: SSHConfig, protocol connectionProtocol: ConnectionProtocol) {
        let targetAuthType: SSHAuthType
        if config.authMethod.isKey, let keyID = config.authMethod.keyID {
            let fingerprint = SSHKeyManager.shared.findKey(id: keyID)?.fingerprint
            targetAuthType = .key(keyID, fingerprint: fingerprint)
        } else if config.usedSavedPassword || config.authMethod.isSavedPassword {
            targetAuthType = .savedPassword
        } else {
            targetAuthType = .password
        }

        let jumpAuthType: SSHAuthType?
        if let jump = config.jumpHost {
            if jump.authMethod.isKey, let keyID = jump.authMethod.keyID {
                let fingerprint = SSHKeyManager.shared.findKey(id: keyID)?.fingerprint
                jumpAuthType = .key(keyID, fingerprint: fingerprint)
            } else if config.usedSavedJumpPassword || jump.authMethod.isSavedPassword {
                jumpAuthType = .savedPassword
            } else {
                jumpAuthType = .password
            }
        } else {
            jumpAuthType = nil
        }

        SSHConnectionHistoryManager.shared.recordConnection(
            username: config.username,
            host: config.host,
            port: config.port,
            authType: targetAuthType,
            connectionProtocol: connectionProtocol,
            jumpHost: config.jumpHost?.host,
            jumpPort: config.jumpHost?.port,
            jumpUsername: config.jumpHost?.username,
            jumpAuthType: jumpAuthType,
                tsshRelay: config.jumpHost?.tsshRelay,
            resolvedIP: config.cachedIP,
            agentConfig: config.agentConfig,
            portForwardConfig: config.portForwardConfig,
            tmuxAutoEnable: config.tmuxAutoEnable,
            tmuxAutoMode: config.tmuxAutoMode,
            herdrAutoEnable: config.herdrAutoEnable,
            zmxAutoEnable: config.zmxAutoEnable,
            launchCommand: config.launchCommand,
            launchCommandMode: config.launchCommandMode,
            terminalType: config.terminalType,
            multiplexerSessionName: config.multiplexerSessionName
        )
    }

    /// Save pending password if provided and not already stored.
    private func finalizePendingPasswordSaveIfNeeded() {
        if let pending = pendingPasswordToSave,
           !SSHPasswordManager.shared.hasPassword(host: pending.host, port: pending.port, username: pending.username) {
            do {
                try SSHPasswordManager.shared.savePassword(pending.password, host: pending.host, port: pending.port, username: pending.username)
                Self.logger.info("Password saved for \(pending.username)@\(pending.host)")
            } catch {
                Self.logger.warning("Failed to save password: \(error.localizedDescription)")
            }
        }
        pendingPasswordToSave = nil
    }

    /// Shared cleanup for embedded session end.
    private func handleEmbeddedSessionEnd(stopSession: () -> Void) {
        stopSession()
        sessionMode = .localShell
        lastCommandSucceeded = true
        scriptCommandExitCode = 0
        pendingPasswordToSave = nil

        // Notify that we've returned to local shell
        onEmbeddedConnectionConfigChanged?(nil)

        cleanupInlineSpinner()
        displayPrompt()
    }

    /// Cancel an in-progress embedded session connection (Ctrl-C during connect/auth).
    func cancelEmbeddedSessionConnection() {
        cancelEmbeddedConnectionStartTask()

        // Stop and release the session
        if let session = embeddedSSHSession {
            session.stop()
            embeddedSSHSession = nil
            activeEmbeddedSSHConfig = nil
            lastAttemptedSSHConfig = nil
        } else if let session = embeddedSFTPSession {
            session.stop()
            embeddedSFTPSession = nil
            lastAttemptedSFTPConfig = nil
        } else if let session = embeddedMoshSession {
            session.stop()
            embeddedMoshSession = nil
            activeEmbeddedMoshConfig = nil
            lastAttemptedMoshConfig = nil
        } else if let session = embeddedTrzszSession {
            session.stop()
            embeddedTrzszSession = nil
            activeEmbeddedTrzszConfig = nil
            lastAttemptedTrzszConfig = nil
        }

        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 130 // Standard SIGINT exit code
        pendingPasswordToSave = nil

        // Notify that we've returned to local shell
        onEmbeddedConnectionConfigChanged?(nil)

        // Clean up spinner and show cancellation
        cleanupInlineSpinner()
        onOutput?(normalizeLineEndings("\r\n^C\r\n"))
        displayPrompt()
    }

    /// Runs `teardown` — which nils the embedded session, clearing the card via
    /// its didSet — while preserving the auth banner that explains the failure.
    /// Tailscale-style rejection reasons arrive as banners immediately before
    /// the failure, so the card is the only surface holding the explanation.
    /// Restored on a countdown so it does not strand the local shell prompt.
    private func preservingAuthBannerCard(
        from provider: SSHAuthBannerCardProviding?,
        teardown: () -> Void
    ) {
        let banner = provider?.authBannerCardState ?? authBannerCardModel.current
        teardown()
        guard let banner else { return }
        authBannerCardModel.relay(banner)
        authBannerCardModel.scheduleAutoDismiss()
    }

    /// Attempt to fall back to a password prompt after auth failure.
    private func attemptPasswordFallback<Config>(
        error: Error,
        lastAttempted: inout Config?,
        isPasswordAuth: (Config) -> Bool,
        promptMode: (Config) -> SessionMode
    ) -> Bool {
        guard let config = lastAttempted,
              isAuthenticationError(error),
              !isPasswordAuth(config) else {
            return false
        }

        cleanupInlineSpinner()
        lastAttempted = nil
        pendingPasswordToSave = nil
        beginPasswordPrompt(promptMode(config))
        return true
    }

    // MARK: - Embedded SSH Support

    /// Handle an SSH command by parsing and starting an internal SSH session
    func handleSSHCommand(_ command: String) {
        let result = SSHCommandParser.parse(command: command)

        switch result {
        case .success(let config):
            // Have a complete config, start SSH session
            launchEmbeddedSSHSession(config: config)

        case .needsPassword(let partialConfig):
            // Check if we have a saved password for this connection
            if SSHPasswordManager.shared.hasPassword(host: partialConfig.host, port: partialConfig.port, username: partialConfig.username) {
                // Use saved password - create config with .savedPassword auth method
                var config = partialConfig.toSSHConfig(password: "")
                config.authMethod = .savedPassword
                launchEmbeddedSSHSession(config: config)
            } else {
                // No saved password, prompt for one
                beginPasswordPrompt(.passwordPrompt(partialConfig))
            }

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displaySSHHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?(normalizeLineEndings("ssh: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Start an embedded SSH session with the given configuration
    func startEmbeddedSSHSession(config: SSHConfig) async {
        // Guard against duplicate connection attempts
        guard embeddedSSHSession == nil else {
            Self.logger.warning("Ignoring duplicate SSH session start - session already in progress")
            return
        }

        // Resolve saved password if needed
        guard let resolvedConfig = await resolveSSHConfigOrPrompt(config, promptMode: { partialConfig in
            .passwordPrompt(partialConfig)
        }) else {
            return
        }

        // Start inline spinner animation with actual terminal width
        startInlineSpinner(message: "Connecting to \(resolvedConfig.displayName)...")

        // Create a PTY for the SSH session (uses same window size as our PTY)
        let sshPTY = TerminalPTY()
        sshPTY.windowSize = pty.windowSize

        // Use factory to create appropriate session type (SSHSession or CitadelSSHSession)
        let sshSession = SSHSessionFactory.createSession(pty: sshPTY, config: resolvedConfig)
        let sshSessionID = ObjectIdentifier(sshSession)

        // Configure callbacks - capture at setup time for thread-safe access
        let coordinator = EmbeddedSessionCoordinator(session: sshSession, kind: .ssh, titlePrefix: "ssh: ")
        coordinator.attach(to: self)

        // Handle SSH-specific callbacks if this is an SSH session
        if let sshTerminalSession = sshSession as? SSHTerminalSession {
            sshTerminalSession.onHostKeyValidation = { [weak self] request in
                guard let self = self else { return .reject }
                guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return .reject }
                return await self.handleHostKeyValidation(request)
            }

            sshTerminalSession.onStateChange = { [weak self, weak sshTerminalSession] state in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return }
                    // Update spinner with connection progress
                    switch state {
                    case .connecting(let host, let isJumpHost):
                        let message = isJumpHost ? "Connecting to jump host \(host)..." : "Connecting to \(host)..."
                        self.inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
                    case .authenticating(let host, let isJumpHost):
                        let message = isJumpHost ? "Authenticating with jump host \(host)..." : "Authenticating with \(host)..."
                        self.inlineSpinnerAnimator?.updateMessage(message, style: .authenticating)
                    case .connectingToTarget(let host):
                        self.inlineSpinnerAnimator?.updateMessage("Connecting to \(host) via jump host...", style: .connecting)
                    case .authenticatingTarget(let host):
                        self.inlineSpinnerAnimator?.updateMessage("Authenticating with \(host)...", style: .authenticating)
                    case .running:
                        self.cleanupInlineSpinner()
                        // Emit server auth banners captured during authentication, then
                        // post-connection warnings (e.g. non-PQ KEX) — both AFTER spinner
                        // cleanup, otherwise clearToEndOfScreen wipes them.
                        if let sshTerminalSession {
                            for raw in sshTerminalSession.consumeAuthBanners() {
                                let rendered = SSHBanner.renderAuthBanner(raw)
                                if !rendered.isEmpty { self.onOutput?(rendered) }
                            }
                        }
                        if let sshTerminalSession,
                           let banner = SSHBanner.postConnectionWarning(for: sshTerminalSession) {
                            self.onOutput?(banner)
                        }
                    case .waitingToReconnect(let attempt, let delay):
                        self.inlineSpinnerAnimator?.updateMessage("Reconnecting in \(delay)s (attempt \(attempt))...", style: .reconnecting)
                    case .reconnecting(let attempt):
                        self.inlineSpinnerAnimator?.updateMessage("Reconnecting (attempt \(attempt))...", style: .reconnecting)
                    case .reconnectionFailed(let reason):
                        self.inlineSpinnerAnimator?.updateMessage("Reconnection failed: \(reason)", style: .error)
                    case .disconnected, .failed, .initial:
                        break
                    }
                }
            }
        }

        if let citadelSession = sshSession as? CitadelSSHSession {
            citadelSession.onAgentApprovalRequest = { [weak self] request in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return }
                    self.onAgentApprovalRequired?(request)
                }
            }
            // Keyboard-interactive prompts render inline in the terminal (MFA/OTP/PAM).
            citadelSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
                guard let self else { return nil }
                guard self.isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else { return nil }
                return await self.handleKeyboardInteractiveChallenge(challenge)
            }
        }

        // Store session and switch mode
        embeddedSSHSession = sshSession
        sessionMode = .sshSession

        // Store config for potential auth failure retry with password
        lastAttemptedSSHConfig = resolvedConfig

        // Start the SSH session
        do {
            try await sshSession.start()

            guard isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else {
                sshSession.stop()
                return
            }

            // Clear retry config on success (but keep active config for session recovery)
            lastAttemptedSSHConfig = nil

            // Store active config for session recovery (allows serialization of shell-launched sessions)
            activeEmbeddedSSHConfig = resolvedConfig

            // Notify that we've transitioned to an embedded SSH session
            onEmbeddedConnectionConfigChanged?(activeEmbeddedConnectionConfig)

            // Record successful connection to history
            recordSSHConnectionHistory(for: resolvedConfig, protocol: .ssh)

            // Auto-save password if user entered it manually and it's not already saved
            finalizePendingPasswordSaveIfNeeded()

            Self.logger.info("Embedded SSH session started successfully")
        } catch is CancellationError {
            Self.logger.info("Embedded SSH connection cancelled")
        } catch {
            guard isCurrentEmbeddedSession(sshSessionID, kind: .ssh) else {
                Self.logger.debug("Ignoring stale SSH session error after cancellation")
                return
            }
            handleSSHSessionError(error)
        }
    }

    /// Handle SSH session end (normal disconnect)
    private func handleSSHSessionEnd() {
        handleEmbeddedSessionEnd {
            embeddedSSHSession?.stop()
            embeddedSSHSession = nil
            activeEmbeddedSSHConfig = nil
        }
    }

    /// Handle SSH session error
    private func handleSSHSessionError(_ error: Error) {
        // Guard against double-handling (onError callback + catch block can both fire)
        guard inlineFailureAnimator == nil else { return }

        // Also guard if we're already in password prompt mode (fallback already happened)
        if case .passwordPrompt = sessionMode { return }

        preservingAuthBannerCard(from: embeddedSSHSession as? SSHAuthBannerCardProviding) {
            embeddedSSHSession?.stop()
            embeddedSSHSession = nil
            activeEmbeddedSSHConfig = nil
        }

        // Check if this is an auth failure we can retry with password
        // Only offer password fallback if:
        // 1. We have the original config
        // 2. The error is authentication-related
        // 3. The original auth was NOT already a password (avoid infinite loop)
        if attemptPasswordFallback(
            error: error,
            lastAttempted: &lastAttemptedSSHConfig,
            isPasswordAuth: { $0.authMethod.isPassword },
            promptMode: { config in
                .passwordPrompt(makePartialSSHConfig(from: config))
            }
        ) {
            return
        }

        // Not an auth error or already tried password - show error normally
        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 1
        pendingPasswordToSave = nil
        lastAttemptedSSHConfig = nil

        // Notify that we've returned to local shell (in case session was previously running)
        onEmbeddedConnectionConfigChanged?(nil)

        // Clean up spinner first
        cleanupInlineSpinner()

        // Play inline failure animation
        inlineFailureAnimator = InlineFailureAnimator()
        inlineFailureAnimator?.play(
            for: error,
            terminalWidth: Int(pty.windowSize.cols),
            onFrame: { [weak self] output in
                self?.onOutput?(output)
            },
            onComplete: { [weak self] in
                guard let self = self else { return }

                // Keep the animation visible - just clear the animator reference
                self.inlineFailureAnimator = nil

                // Show error message and prompt below the animation
                let errorMessage = "\r\n\r\nssh: \(error.localizedDescription)\r\n"
                self.onOutput?(self.normalizeLineEndings(errorMessage))
                self.displayPrompt()
            }
        )
    }

    /// Check if an error is authentication-related
    private func isAuthenticationError(_ error: Error) -> Bool {
        // Check for SSHError.authenticationFailed
        if let sshError = error as? SSHError {
            if case .authenticationFailed = sshError {
                return true
            }
        }

        // Check for SSHJumpError.authenticationFailed
        if let jumpError = error as? SSHJumpError {
            if case .authenticationFailed = jumpError {
                return true
            }
        }

        // Check for SCPError.authenticationFailed
        if let scpError = error as? SCPError {
            if case .authenticationFailed = scpError {
                return true
            }
        }

        // Check for SFTPError.authenticationFailed
        if let sftpError = error as? SFTPError {
            if case .authenticationFailed = sftpError {
                return true
            }
        }

        // Check for Citadel SSHClientError authentication failures
        if let sshClientError = error as? SSHClientError {
            switch sshClientError {
            case .allAuthenticationOptionsFailed,
                    .unsupportedPasswordAuthentication,
                    .unsupportedPrivateKeyAuthentication:
                return true
            default:
                break
            }
        }

        // Check error description for common auth failure patterns
        let description = error.localizedDescription.lowercased()
        if description.contains("authentication failed") ||
            description.contains("permission denied") ||
            description.contains("publickey") {
            return true
        }

        return false
    }

    // MARK: - Embedded SCP Support

    /// Handle an SCP command by parsing and starting an internal SCP transfer
    func handleSCPCommand(_ command: String) {
        let result = SCPCommandParser.parse(command: command)

        switch result {
        case .success(let parsedCmd, let sshConfig):
            // Have a complete config, start SCP transfer
            Task { @MainActor in
                startSCPTransfer(command: parsedCmd, config: sshConfig)
            }

        case .needsPassword(let parsedCmd, let partialConfig):
            // Check if we have a saved password for this connection
            if SSHPasswordManager.shared.hasPassword(host: partialConfig.host, port: partialConfig.port, username: partialConfig.username) {
                // Use saved password - create config with .savedPassword auth method
                var config = partialConfig.toSSHConfig(password: "")
                config.authMethod = .savedPassword
                Task { @MainActor in
                    startSCPTransfer(command: parsedCmd, config: config)
                }
            } else {
                // No saved password, prompt for one
                sessionMode = .scpPasswordPrompt(parsedCmd, partialConfig)
                passwordBuffer = ""
                onOutput?(normalizeLineEndings("Password: "))
            }

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displaySCPHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?(normalizeLineEndings("scp: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Start an SCP file transfer with the given configuration
    func startSCPTransfer(command: SCPParsedCommand, config: SSHConfig) {
        // Guard against duplicate transfer attempts
        guard embeddedSCPTransfer == nil else {
            Self.logger.warning("Ignoring duplicate SCP transfer start - transfer already in progress")
            return
        }

        // Resolve saved password if needed (async inside Task since this is called from sync context)
        Task { @MainActor in
            let resolvedConfig: SSHConfig
            do {
                resolvedConfig = try await config.resolvedConfig()
            } catch SSHPasswordManager.PasswordError.authenticationCancelled {
                // User cancelled biometric auth - fall back to password prompt
                let partialConfig = SSHCommandParser.PartialSSHConfig(
                    host: config.host,
                    port: config.port,
                    username: config.username,
                    jumpHost: config.jumpHost,
                    agentConfig: config.agentConfig,
                    portForwardConfig: config.portForwardConfig,
                    cachedIP: config.cachedIP
                )
                sessionMode = .scpPasswordPrompt(command, partialConfig)
                passwordBuffer = ""
                onOutput?(normalizeLineEndings("Password: "))
                return
            } catch {
                // Failed to load saved password - fall back to password prompt
                let partialConfig = SSHCommandParser.PartialSSHConfig(
                    host: config.host,
                    port: config.port,
                    username: config.username,
                    jumpHost: config.jumpHost,
                    agentConfig: config.agentConfig,
                    portForwardConfig: config.portForwardConfig,
                    cachedIP: config.cachedIP
                )
                sessionMode = .scpPasswordPrompt(command, partialConfig)
                passwordBuffer = ""
                onOutput?(normalizeLineEndings("Password: "))
                return
            }

            // Start inline spinner animation
            inlineSpinnerAnimator = InlineSpinnerAnimator()
            let outputSink = outputSink
            inlineSpinnerAnimator?.start(
                message: "Connecting to \(resolvedConfig.displayName)...",
                style: .connecting,
                jokeCategory: .ssh,
                terminalWidth: Int(pty.windowSize.cols)
            ) { [outputSink] output in
                outputSink.emitString(output)
            }

            // Store command and config for potential auth failure retry with password
            lastAttemptedSCPCommand = command
            lastAttemptedSCPConfig = resolvedConfig

            // Create the SCP transfer
            let transfer = SCPTransfer(command: command, config: resolvedConfig)
            startSCPTransferInternal(transfer: transfer)
        }
    }

    /// Internal helper to start SCP transfer after config is resolved
    private func startSCPTransferInternal(transfer: SCPTransfer) {
        // Configure callbacks
        let outputSink = outputSink
        transfer.onOutput = { [outputSink] output in
            Task { @MainActor in
                outputSink.emitString(output)
            }
        }

        transfer.onHostKeyValidation = { [weak self] request in
            guard let self = self else { return .reject }
            return await self.handleHostKeyValidation(request)
        }

        transfer.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self = self else { return nil }
            return await self.handleKeyboardInteractiveChallenge(challenge)
        }

        transfer.onProgress = { [weak self] progress in
            guard let self = self else { return }
            self.updateSCPProgress(progress)
        }

        transfer.onComplete = { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    self?.handleSCPComplete()
                case .failure(let error):
                    self?.handleSCPError(error)
                }
            }
        }

        // Store transfer and switch mode
        embeddedSCPTransfer = transfer
        sessionMode = .scpTransfer

        // Start the transfer asynchronously (allows cancellation via cancel())
        transfer.startAsync()
    }

    /// Update progress display during SCP transfer
    private func updateSCPProgress(_ progress: SCPTransferProgress) {
        let message: String
        switch progress.state {
        case .connecting:
            message = "Connecting..."
        case .authenticating:
            message = "Authenticating..."
        case .enumerating:
            message = "Listing files..."
        case .transferring(let file):
            let pct = Int(progress.percentComplete)
            let throughput = formatThroughput(progress.throughput)
            if progress.totalFiles > 1 {
                message = "\(file) (\(progress.currentFileIndex)/\(progress.totalFiles)) \(pct)% | \(throughput)"
            } else {
                message = "\(file) \(pct)% | \(throughput)"
            }
        case .completed:
            message = "Transfer complete"
        case .failed:
            return  // Error handled separately
        }

        inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
    }

    /// Update progress display during SFTP transfer
    private func updateSFTPProgress(_ progress: SFTPTransferProgress) {
        switch progress.state {
        case .transferring(let file):
            let displayFile = file.isEmpty ? progress.currentFile : file
            let throughput = formatThroughput(progress.throughput)
            let detail: String
            if progress.totalBytes > 0 {
                detail = "\(Int(progress.percentComplete))% | \(throughput)"
            } else {
                detail = "\(formatByteCount(progress.bytesTransferred)) | \(throughput)"
            }

            let message: String
            if progress.totalFiles > 1 {
                message = "\(displayFile) (\(progress.currentFileIndex)/\(progress.totalFiles)) \(detail)"
            } else {
                message = "\(displayFile) \(detail)"
            }

            if inlineSpinnerAnimator == nil {
                inlineSpinnerAnimator = InlineSpinnerAnimator()
                inlineSpinnerAnimator?.start(
                    message: message,
                    style: .connecting,
                    jokeCategory: nil,
                    terminalWidth: Int(pty.windowSize.cols)
                ) { [weak self] output in
                    self?.onOutput?(output)
                }
            } else {
                inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
            }

        case .completed, .failed:
            finishSFTPProgress()
        }
    }

    private func finishSFTPProgress() {
        let cleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
        inlineSpinnerAnimator?.stop()
        inlineSpinnerAnimator = nil
        if !cleanup.isEmpty {
            onOutput?(cleanup)
            onOutput?("\r\n")
        }
    }

    /// Format throughput for display
    private func formatThroughput(_ bps: Double) -> String {
        if bps > 1_000_000 {
            return String(format: "%.1f MB/s", bps / 1_000_000)
        } else if bps > 1_000 {
            return String(format: "%.1f KB/s", bps / 1_000)
        } else {
            return String(format: "%.0f B/s", bps)
        }
    }

    /// Format byte counts for display
    private func formatByteCount(_ bytes: Int64) -> String {
        if bytes > 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes > 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes > 1_000 {
            return String(format: "%.1f KB", Double(bytes) / 1_000)
        } else {
            return "\(bytes) B"
        }
    }

    /// Handle successful SCP transfer completion
    private func handleSCPComplete() {
        // Guard against double-handling (e.g., if already cancelled via Ctrl-C)
        guard case .scpTransfer = sessionMode else { return }

        embeddedSCPTransfer = nil
        sessionMode = .localShell
        lastCommandSucceeded = true
        scriptCommandExitCode = 0

        // Clear stored command/config on success
        lastAttemptedSCPCommand = nil
        lastAttemptedSCPConfig = nil

        // Auto-save password if user entered it manually and it's not already saved
        if let pending = pendingPasswordToSave,
           !SSHPasswordManager.shared.hasPassword(host: pending.host, port: pending.port, username: pending.username) {
            do {
                try SSHPasswordManager.shared.savePassword(pending.password, host: pending.host, port: pending.port, username: pending.username)
                Self.logger.info("Password saved for \(pending.username)@\(pending.host)")
            } catch {
                Self.logger.warning("Failed to save password: \(error.localizedDescription)")
            }
        }
        pendingPasswordToSave = nil

        // Clean up spinner
        let cleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
        inlineSpinnerAnimator?.stop()
        inlineSpinnerAnimator = nil
        onOutput?(cleanup)

        // Show success message
        onOutput?(normalizeLineEndings("\r\nTransfer complete.\r\n"))
        displayPrompt()
    }

    /// Handle SCP transfer error
    private func handleSCPError(_ error: Error) {
        // Guard against double-handling (e.g., if already cancelled via Ctrl-C)
        guard inlineFailureAnimator == nil else { return }
        guard case .scpTransfer = sessionMode else { return }

        embeddedSCPTransfer = nil

        // Check if this is a cancelled transfer (no animation needed)
        if let scpError = error as? SCPError, !scpError.showsFailureAnimation {
            lastAttemptedSCPCommand = nil
            lastAttemptedSCPConfig = nil
            pendingPasswordToSave = nil
            sessionMode = .localShell
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            let cleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
            inlineSpinnerAnimator?.stop()
            inlineSpinnerAnimator = nil
            onOutput?(cleanup)
            displayPrompt()
            return
        }

        // Check if this is an auth failure we can retry with password
        if let command = lastAttemptedSCPCommand,
           let config = lastAttemptedSCPConfig,
           isAuthenticationError(error),
           !config.authMethod.isPassword {

            // Clean up spinner
            let spinnerCleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
            inlineSpinnerAnimator?.stop()
            inlineSpinnerAnimator = nil
            onOutput?(spinnerCleanup)

            // Clear stored config to prevent retry loops
            lastAttemptedSCPCommand = nil
            lastAttemptedSCPConfig = nil

            // Silently fall back to password prompt
            let partialConfig = SSHCommandParser.PartialSSHConfig(
                host: config.host,
                port: config.port,
                username: config.username,
                jumpHost: config.jumpHost,
                agentConfig: config.agentConfig,
                portForwardConfig: config.portForwardConfig,
                cachedIP: config.cachedIP
            )
            sessionMode = .scpPasswordPrompt(command, partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        }

        // Not an auth error or already tried password - show error normally
        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 1
        lastAttemptedSCPCommand = nil
        lastAttemptedSCPConfig = nil
        pendingPasswordToSave = nil

        // Clean up spinner first
        let spinnerCleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
        inlineSpinnerAnimator?.stop()
        inlineSpinnerAnimator = nil
        onOutput?(spinnerCleanup)

        // Play inline failure animation
        inlineFailureAnimator = InlineFailureAnimator()
        inlineFailureAnimator?.play(
            for: error,
            terminalWidth: Int(pty.windowSize.cols),
            onFrame: { [weak self] output in
                self?.onOutput?(output)
            },
            onComplete: { [weak self] in
                guard let self = self else { return }

                // Keep the animation visible - just clear the animator reference
                self.inlineFailureAnimator = nil

                // Show error message and prompt below the animation
                let errorMessage = "\r\n\r\nscp: \(error.localizedDescription)\r\n"
                self.onOutput?(self.normalizeLineEndings(errorMessage))
                self.displayPrompt()
            }
        )
    }

    // MARK: - SFTP Command Handling

    /// Handle an SFTP command by parsing and starting an interactive SFTP session
    func handleSFTPCommand(_ command: String) {
        let result = SFTPCommandParser.parse(command: command)

        switch result {
        case .success(let config):
            // Have a complete config, start SFTP session
            launchEmbeddedSFTPSession(config: config)

        case .needsPassword(let partialConfig):
            // Check if we have a saved password for this connection
            if SSHPasswordManager.shared.hasPassword(host: partialConfig.host, port: partialConfig.port, username: partialConfig.username) {
                // Use saved password - create config with .savedPassword auth method
                var config = partialConfig.toSSHConfig(password: "")
                config.authMethod = .savedPassword
                launchEmbeddedSFTPSession(config: config)
            } else {
                // No saved password, prompt for one
                sessionMode = .sftpPasswordPrompt(partialConfig)
                passwordBuffer = ""
                onOutput?(normalizeLineEndings("Password: "))
            }

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displaySFTPHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?(normalizeLineEndings("sftp: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Start an interactive SFTP session with the given configuration
    func startEmbeddedSFTPSession(config: SSHConfig) async {
        // Guard against duplicate session attempts
        guard embeddedSFTPSession == nil else {
            Self.logger.warning("Ignoring duplicate SFTP session start - session already in progress")
            return
        }

        // Resolve saved password if needed
        let resolvedConfig: SSHConfig
        do {
            resolvedConfig = try await config.resolvedConfig()
        } catch SSHPasswordManager.PasswordError.authenticationCancelled {
            // User cancelled biometric auth - fall back to password prompt
            let partialConfig = SSHCommandParser.PartialSSHConfig(
                host: config.host,
                port: config.port,
                username: config.username,
                jumpHost: config.jumpHost,
                agentConfig: config.agentConfig,
                portForwardConfig: config.portForwardConfig,
                cachedIP: config.cachedIP
            )
            sessionMode = .sftpPasswordPrompt(partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        } catch {
            // Failed to load saved password - fall back to password prompt
            let partialConfig = SSHCommandParser.PartialSSHConfig(
                host: config.host,
                port: config.port,
                username: config.username,
                jumpHost: config.jumpHost,
                agentConfig: config.agentConfig,
                portForwardConfig: config.portForwardConfig,
                cachedIP: config.cachedIP
            )
            sessionMode = .sftpPasswordPrompt(partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        }

        // Start inline spinner animation
        let outputSink = outputSink
        inlineSpinnerAnimator = InlineSpinnerAnimator()
        inlineSpinnerAnimator?.start(
            message: "Connecting to \(resolvedConfig.displayName)...",
            style: .connecting,
            jokeCategory: .ssh,
            terminalWidth: Int(pty.windowSize.cols)
        ) { [outputSink] output in
            outputSink.emitString(output)
        }

        // Get local working directory
        let localDir = sessionCurrentDirectory

        // Create SFTP session
        let sftpSession = SFTPSession(config: resolvedConfig, localWorkingDirectory: localDir)
        let sftpSessionID = ObjectIdentifier(sftpSession)

        // Seed the prompt's line-wrap math with the current terminal width.
        sftpSession.resize(cols: pty.windowSize.cols, rows: pty.windowSize.rows)

        // Configure callbacks
        sftpSession.onOutput = { [weak self, outputSink] output in
            Task { @MainActor [weak self] in
                guard let self = self, self.isCurrentSFTPSession(sftpSessionID) else { return }
                outputSink.emitString(output)
            }
        }

        sftpSession.onHostKeyValidation = { [weak self] request in
            guard let self = self else { return .reject }
            guard self.isCurrentSFTPSession(sftpSessionID) else { return .reject }
            return await self.handleHostKeyValidation(request)
        }

        sftpSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self = self else { return nil }
            guard self.isCurrentSFTPSession(sftpSessionID) else { return nil }
            return await self.handleKeyboardInteractiveChallenge(challenge)
        }

        sftpSession.onComplete = { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isCurrentSFTPSession(sftpSessionID) else { return }
                self.handleSFTPSessionEnd()
            }
        }

        sftpSession.onError = { [weak self] error in
            Task { @MainActor in
                guard let self = self, self.isCurrentSFTPSession(sftpSessionID) else { return }
                self.handleSFTPSessionError(error)
            }
        }

        sftpSession.onProgress = { [weak self] progress in
            Task { @MainActor in
                guard let self = self else { return }
                guard self.isCurrentSFTPSession(sftpSessionID) else { return }
                self.updateSFTPProgress(progress)
            }
        }

        // Clean up spinner
        if let cleanup = inlineSpinnerAnimator?.getCleanupSequence() {
            onOutput?(cleanup)
        }
        inlineSpinnerAnimator?.stop()
        inlineSpinnerAnimator = nil

        embeddedSFTPSession = sftpSession
        sessionMode = .sftpSession

        // Store config for potential auth failure retry with password
        lastAttemptedSFTPConfig = resolvedConfig

        // Start the SFTP session
        do {
            try await sftpSession.start()

            guard isCurrentSFTPSession(sftpSessionID) else {
                sftpSession.stop()
                return
            }

            // Clear config on success
            lastAttemptedSFTPConfig = nil

            // Auto-save password if user entered it manually and it's not already saved
            if let pending = pendingPasswordToSave,
               !SSHPasswordManager.shared.hasPassword(host: pending.host, port: pending.port, username: pending.username) {
                do {
                    try SSHPasswordManager.shared.savePassword(pending.password, host: pending.host, port: pending.port, username: pending.username)
                    Self.logger.info("Password saved for \(pending.username)@\(pending.host)")
                } catch {
                    Self.logger.warning("Failed to save password: \(error.localizedDescription)")
                }
            }
            pendingPasswordToSave = nil

            Self.logger.info("Embedded SFTP session started successfully")
        } catch is CancellationError {
            Self.logger.info("Embedded SFTP connection cancelled")
        } catch {
            guard isCurrentSFTPSession(sftpSessionID) else {
                Self.logger.debug("Ignoring stale SFTP session error after cancellation")
                return
            }
            handleSFTPSessionError(error)
        }
    }

    /// Handle SFTP session end (user typed exit/quit)
    private func handleSFTPSessionEnd() {
        embeddedSFTPSession?.stop()
        embeddedSFTPSession = nil
        sessionMode = .localShell
        lastCommandSucceeded = true
        scriptCommandExitCode = 0
        displayPrompt()
    }

    /// Handle SFTP session error
    private func handleSFTPSessionError(_ error: Error) {
        // Guard against double-handling
        guard inlineFailureAnimator == nil else { return }

        // Also guard if we're already in password prompt mode (fallback already happened)
        if case .sftpPasswordPrompt = sessionMode { return }

        embeddedSFTPSession?.stop()
        embeddedSFTPSession = nil

        // Determine if it was just cancelled
        if let sftpError = error as? SFTPError, case .cancelled = sftpError {
            lastAttemptedSFTPConfig = nil
            pendingPasswordToSave = nil
            sessionMode = .localShell
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            displayPrompt()
            return
        }

        // Check if this is an auth failure we can retry with password
        if let config = lastAttemptedSFTPConfig,
           isAuthenticationError(error),
           !config.authMethod.isPassword {

            // Clean up spinner
            let spinnerCleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
            inlineSpinnerAnimator?.stop()
            inlineSpinnerAnimator = nil
            onOutput?(spinnerCleanup)

            // Clear stored config to prevent retry loops
            lastAttemptedSFTPConfig = nil

            // Silently fall back to password prompt
            let partialConfig = SSHCommandParser.PartialSSHConfig(
                host: config.host,
                port: config.port,
                username: config.username,
                jumpHost: config.jumpHost,
                agentConfig: config.agentConfig,
                portForwardConfig: config.portForwardConfig,
                cachedIP: config.cachedIP
            )
            sessionMode = .sftpPasswordPrompt(partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        }

        // Not an auth error or already tried password - show error normally
        sessionMode = .localShell
        lastCommandSucceeded = false
        scriptCommandExitCode = 1
        lastAttemptedSFTPConfig = nil
        pendingPasswordToSave = nil

        // Clean up spinner first
        let spinnerCleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
        inlineSpinnerAnimator?.stop()
        inlineSpinnerAnimator = nil
        onOutput?(spinnerCleanup)

        // Play inline failure animation
        inlineFailureAnimator = InlineFailureAnimator()
        inlineFailureAnimator?.play(
            for: error,
            terminalWidth: Int(pty.windowSize.cols),
            onFrame: { [weak self] output in
                self?.onOutput?(output)
            },
            onComplete: { [weak self] in
                guard let self = self else { return }

                // Keep the animation visible - just clear the animator reference
                self.inlineFailureAnimator = nil

                // Show error message and prompt below the animation
                let errorMessage = "\r\n\r\nsftp: \(error.localizedDescription)\r\n"
                self.onOutput?(self.normalizeLineEndings(errorMessage))
                self.displayPrompt()
            }
        )
    }

    // MARK: - SSH Copy ID Support

    /// Handle an ssh-copy-id command by parsing and starting the operation
    func handleSSHCopyIDCommand(_ command: String) {
        let result = SSHCopyIDCommandParser.parse(command: command)

        switch result {
        case .success(let parsedCmd, let sshConfig):
            Task { @MainActor in
                await startSSHCopyIDTransfer(command: parsedCmd, config: sshConfig)
            }

        case .needsPassword(let parsedCmd, let partialConfig):
            // Check if we have a saved password for this connection
            if SSHPasswordManager.shared.hasPassword(host: partialConfig.host, port: partialConfig.port, username: partialConfig.username) {
                var config = partialConfig.toSSHConfig(password: "")
                config.authMethod = .savedPassword
                Task { @MainActor in
                    await startSSHCopyIDTransfer(command: parsedCmd, config: config)
                }
            } else {
                sessionMode = .sshCopyIDPasswordPrompt(parsedCmd, partialConfig)
                passwordBuffer = ""
                onOutput?(normalizeLineEndings("Password: "))
            }

        case .help:
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            displaySSHCopyIDHelp()

        case .error(let message):
            lastCommandSucceeded = false
            scriptCommandExitCode = 1
            onOutput?(normalizeLineEndings("ssh-copy-id: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Start an ssh-copy-id operation with the given configuration
    func startSSHCopyIDTransfer(command: SSHCopyIDParsedCommand, config: SSHConfig) async {
        // Guard against duplicate attempts
        guard embeddedSSHCopyID == nil else {
            Self.logger.warning("Ignoring duplicate ssh-copy-id start - operation already in progress")
            return
        }

        // Resolve saved password if needed
        let resolvedConfig: SSHConfig
        do {
            resolvedConfig = try await config.resolvedConfig()
        } catch SSHPasswordManager.PasswordError.authenticationCancelled {
            let partialConfig = makePartialSSHConfig(from: config)
            sessionMode = .sshCopyIDPasswordPrompt(command, partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        } catch {
            let partialConfig = makePartialSSHConfig(from: config)
            sessionMode = .sshCopyIDPasswordPrompt(command, partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        }

        // Start inline spinner
        startInlineSpinner(message: "Connecting to \(resolvedConfig.displayName)...")

        // Store for auth failure retry
        lastAttemptedSSHCopyIDCommand = command
        lastAttemptedSSHCopyIDConfig = resolvedConfig

        // Create the ssh-copy-id operation
        let copyID = SSHCopyID(command: command, config: resolvedConfig)

        let outputSink = outputSink
        copyID.onProgress = { [weak self] message in
            guard let self = self else { return }
            self.inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
        }

        copyID.onLog = { [outputSink] message in
            Task { @MainActor in
                outputSink.emitString(message + "\r\n")
            }
        }

        copyID.onHostKeyValidation = { [weak self] request in
            guard let self = self else { return .reject }
            return await self.handleHostKeyValidation(request)
        }

        copyID.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self = self else { return nil }
            return await self.handleKeyboardInteractiveChallenge(challenge)
        }

        embeddedSSHCopyID = copyID
        sessionMode = .sshCopyIDTransfer

        // Execute the operation
        do {
            let result = try await copyID.execute()
            handleSSHCopyIDComplete(result: result)
        } catch {
            handleSSHCopyIDError(error)
        }
    }

    /// Handle successful ssh-copy-id completion
    private func handleSSHCopyIDComplete(result: SSHCopyIDResult) {
        guard case .sshCopyIDTransfer = sessionMode else { return }

        embeddedSSHCopyID = nil
        sessionMode = .localShell

        lastAttemptedSSHCopyIDCommand = nil
        lastAttemptedSSHCopyIDConfig = nil

        // Auto-save password
        if let pending = pendingPasswordToSave,
           !SSHPasswordManager.shared.hasPassword(host: pending.host, port: pending.port, username: pending.username) {
            do {
                try SSHPasswordManager.shared.savePassword(pending.password, host: pending.host, port: pending.port, username: pending.username)
                Self.logger.info("Password saved for \(pending.username)@\(pending.host)")
            } catch {
                Self.logger.warning("Failed to save password: \(error.localizedDescription)")
            }
        }
        pendingPasswordToSave = nil

        // Clean up spinner
        cleanupInlineSpinner()

        // Show results
        var output = "\r\n"
        if !result.installedKeys.isEmpty {
            let count = result.installedKeys.count
            output += "Number of key(s) added: \(count)\r\n\r\n"
        }
        if !result.skippedKeys.isEmpty {
            let count = result.skippedKeys.count
            output += "Number of key(s) already installed: \(count)\r\n"
        }
        if result.installedKeys.isEmpty && !result.skippedKeys.isEmpty {
            output += "All keys were already installed.\r\n"
        }

        lastCommandSucceeded = true
        scriptCommandExitCode = 0
        onOutput?(normalizeLineEndings(output))
        displayPrompt()
    }

    /// Handle ssh-copy-id error
    private func handleSSHCopyIDError(_ error: Error) {
        guard inlineFailureAnimator == nil else { return }
        guard case .sshCopyIDTransfer = sessionMode else { return }

        embeddedSSHCopyID = nil

        // Check for "all keys already installed" - not really an error
        if let copyError = error as? SSHCopyIDError, case .allKeysAlreadyInstalled = copyError {
            sessionMode = .localShell
            lastAttemptedSSHCopyIDCommand = nil
            lastAttemptedSSHCopyIDConfig = nil
            pendingPasswordToSave = nil
            cleanupInlineSpinner()
            lastCommandSucceeded = true
            scriptCommandExitCode = 0
            onOutput?(normalizeLineEndings("\r\nAll keys are already installed on the server.\r\n"))
            displayPrompt()
            return
        }

        // Check if this is an auth failure we can retry with password
        if let command = lastAttemptedSSHCopyIDCommand,
           let config = lastAttemptedSSHCopyIDConfig,
           isAuthenticationError(error),
           !config.authMethod.isPassword {

            let spinnerCleanup = inlineSpinnerAnimator?.getCleanupSequence() ?? ""
            inlineSpinnerAnimator?.stop()
            inlineSpinnerAnimator = nil
            onOutput?(spinnerCleanup)

            lastAttemptedSSHCopyIDCommand = nil
            lastAttemptedSSHCopyIDConfig = nil

            let partialConfig = SSHCommandParser.PartialSSHConfig(
                host: config.host,
                port: config.port,
                username: config.username,
                jumpHost: config.jumpHost,
                agentConfig: config.agentConfig,
                portForwardConfig: config.portForwardConfig,
                cachedIP: config.cachedIP
            )
            sessionMode = .sshCopyIDPasswordPrompt(command, partialConfig)
            passwordBuffer = ""
            onOutput?(normalizeLineEndings("Password: "))
            return
        }

        // Show error normally
        sessionMode = .localShell
        lastAttemptedSSHCopyIDCommand = nil
        lastAttemptedSSHCopyIDConfig = nil
        pendingPasswordToSave = nil

        cleanupInlineSpinner()

        // Play inline failure animation
        inlineFailureAnimator = InlineFailureAnimator()
        inlineFailureAnimator?.play(
            for: error,
            terminalWidth: Int(pty.windowSize.cols),
            onFrame: { [weak self] output in
                self?.onOutput?(output)
            },
            onComplete: { [weak self] in
                guard let self = self else { return }

                self.inlineFailureAnimator = nil

                self.lastCommandSucceeded = false
                self.scriptCommandExitCode = 1
                let errorMessage = "\r\n\r\nssh-copy-id: \(error.localizedDescription)\r\n"
                self.onOutput?(self.normalizeLineEndings(errorMessage))
                self.displayPrompt()
            }
        )
    }

    // MARK: - Mosh/Roam Command Support

    /// Handle a mosh/roam command by parsing and starting an internal Mosh session
    func handleMoshCommand(_ command: String) {
        let result = MoshCommandParser.parse(command: command)

        switch result {
        case .success(let moshConfig):
            // Have a complete config, start Mosh session
            // Pass terminalId for credential persistence (enables session resume)
            Task { @MainActor in
                await startEmbeddedMoshSession(config: moshConfig, terminalId: terminalId)
            }

        case .needsPassword(let partialConfig):
            // Check if we have a saved password for this connection
            let host = partialConfig.sshPartialConfig.host
            let port = partialConfig.sshPartialConfig.port
            let username = partialConfig.sshPartialConfig.username

            if SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username) {
                // Use saved password - create config with .savedPassword auth method
                var sshConfig = partialConfig.sshPartialConfig.toSSHConfig(password: "")
                sshConfig.authMethod = .savedPassword
                let moshConfig = MoshConfig(
                    sshConfig: sshConfig,
                    predictionMode: partialConfig.predictionMode,
                    predictOverwrite: partialConfig.predictOverwrite,
                    serverPath: partialConfig.serverPath
                )
                // Pass terminalId for credential persistence (enables session resume)
                Task { @MainActor in
                    await startEmbeddedMoshSession(config: moshConfig, terminalId: terminalId)
                }
            } else {
                // No saved password, prompt for one
                beginPasswordPrompt(.moshPasswordPrompt(partialConfig))
            }

        case .help:
            displayMoshHelp()

        case .error(let message):
            onOutput?(normalizeLineEndings("mosh: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Start an embedded Mosh session with the given configuration
    /// - Parameters:
    ///   - config: The Mosh configuration
    ///   - terminalId: Optional terminal UUID for credential persistence (enables session resume)
    ///   - restoringFromTerminalId: If set, attempts to resume an existing session using stored credentials
    func startEmbeddedMoshSession(config: MoshConfig, terminalId: UUID? = nil, restoringFromTerminalId: UUID? = nil) async {
        // Guard against duplicate connection attempts
        guard embeddedMoshSession == nil else {
            Self.logger.warning("Ignoring duplicate Mosh session start - session already in progress")
            return
        }

        // Resolve saved password if needed
        guard let resolvedSSHConfig = await resolveSSHConfigOrPrompt(
            config.sshConfig,
            promptMode: { partialConfig in
                let moshPartial = MoshCommandParser.PartialMoshConfig(
                    sshPartialConfig: partialConfig,
                    predictionMode: config.predictionMode,
                    predictOverwrite: config.predictOverwrite,
                    serverPath: config.serverPath
                )
                return .moshPasswordPrompt(moshPartial)
            }
        ) else {
            return
        }

        // Create resolved Mosh config
        let resolvedMoshConfig = MoshConfig(
            sshConfig: resolvedSSHConfig,
            udpPortMin: config.udpPortMin,
            udpPortMax: config.udpPortMax,
            predictionMode: config.predictionMode,
            predictOverwrite: config.predictOverwrite,
            colors: config.colors,
            serverPath: config.serverPath,
            serverArgs: config.serverArgs,
            holePunchConfig: config.holePunchConfig
        )

        // Start inline spinner animation with actual terminal width
        let isRestoring = restoringFromTerminalId != nil
        let spinnerMessage = isRestoring
            ? "Resuming session to \(resolvedMoshConfig.displayName)..."
            : "Connecting to \(resolvedMoshConfig.displayName)..."
        startInlineSpinner(message: spinnerMessage)

        // Create Mosh session with terminal ID for credential persistence
        let moshSession = MoshSession(config: resolvedMoshConfig, pty: pty, terminalId: terminalId)

        // Keyboard-interactive (2FA/OTP/PAM) prompts during the mosh-server SSH
        // bootstrap render inline in the terminal.
        let moshSessionID = ObjectIdentifier(moshSession)
        moshSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self else { return nil }
            guard self.isCurrentEmbeddedSession(moshSessionID, kind: .mosh) else { return nil }
            return await self.handleKeyboardInteractiveChallenge(challenge)
        }
        moshSession.onHostKeyValidation = { [weak self] request in
            guard let self else { return .reject }
            return await self.handleHostKeyValidation(request)
        }

        // Configure callbacks - capture at setup time for thread-safe access
        let coordinator = EmbeddedSessionCoordinator(session: moshSession, kind: .mosh, titlePrefix: nil)
        coordinator.attach(to: self)

        moshSession.onStateChange = { [weak self] state in
            guard let self = self else { return }
            // Update spinner with connection progress
            switch state {
            case .connectingSSH(let host, let isJumpHost):
                let message = isJumpHost ? "Connecting to jump host \(host)..." : "Connecting via SSH to \(host)..."
                self.inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
            case .authenticatingSSH(let host, let isJumpHost):
                let message = isJumpHost ? "Authenticating with jump host \(host)..." : "Authenticating with \(host)..."
                self.inlineSpinnerAnimator?.updateMessage(message, style: .authenticating)
            case .connectingToTarget(let host):
                self.inlineSpinnerAnimator?.updateMessage("Connecting to \(host) via jump host...", style: .connecting)
            case .authenticatingTarget(let host):
                self.inlineSpinnerAnimator?.updateMessage("Authenticating with \(host)...", style: .authenticating)
            case .spawningServer:
                self.inlineSpinnerAnimator?.updateMessage("Teaching server to roam free...", style: .authenticating)
            case .tryingDirectUDP(let host, let family):
                self.inlineSpinnerAnimator?.updateMessage("Trying direct connection to \(host) (\(family.rawValue))...", style: .connecting)
            case .holePunching(let ip, let port):
                self.inlineSpinnerAnimator?.updateMessage("Punching through firewall (\(ip):\(port))...", style: .authenticating)
            case .connectingUDP(let host, let port):
                self.inlineSpinnerAnimator?.updateMessage("Connecting UDP to \(host):\(port)...", style: .connecting)
            case .synchronizing:
                self.inlineSpinnerAnimator?.updateMessage("Synchronizing...", style: .connecting)
            case .running:
                // Connected! Clean up spinner
                self.cleanupInlineSpinner()
                // Emit server auth banners (SSH_MSG_USERAUTH_BANNER) captured during
                // the mosh-server SSH bootstrap, AFTER spinner cleanup so
                // clearToEndOfScreen doesn't wipe them.
                for raw in moshSession.consumeAuthBanners() {
                    let rendered = SSHBanner.renderAuthBanner(raw)
                    if !rendered.isEmpty { self.onOutput?(rendered) }
                }
            case .roaming(let previousNetwork):
                self.inlineSpinnerAnimator?.updateMessage("Roaming from \(previousNetwork)...", style: .reconnecting)
            case .waitingToReconnect(let attempt, let delay):
                self.inlineSpinnerAnimator?.updateMessage("Reconnecting in \(delay)s (attempt \(attempt))...", style: .reconnecting)
            case .reconnecting(let attempt):
                self.inlineSpinnerAnimator?.updateMessage("Reconnecting (attempt \(attempt))...", style: .reconnecting)
            case .reconnectionFailed(let reason):
                self.inlineSpinnerAnimator?.updateMessage("Reconnection failed: \(reason)", style: .error)
            default:
                break
            }
        }

        // Store session and switch mode
        embeddedMoshSession = moshSession
        sessionMode = .moshSession
        NotificationCenter.default.post(name: .ghosttyEmbeddedMoshSessionDidChange, object: self)

        // Store config for potential auth failure retry with password
        lastAttemptedMoshConfig = resolvedMoshConfig

        // Start the Mosh session
        do {
            // If restoring from a previous session, use the restoration API to resume UDP state
            if let restoreId = restoringFromTerminalId {
                try await moshSession.start(restoringFromTerminalId: restoreId)
            } else {
                try await moshSession.start()
            }

            // Clear retry config on success (but keep active config for session recovery)
            lastAttemptedMoshConfig = nil

            // Store active config for session recovery (allows serialization of shell-launched sessions)
            activeEmbeddedMoshConfig = resolvedMoshConfig

            // Notify that we've transitioned to an embedded Mosh session
            onEmbeddedConnectionConfigChanged?(activeEmbeddedConnectionConfig)

            // Record successful connection to history (using SSH config info)
            recordSSHConnectionHistory(for: resolvedSSHConfig, protocol: .mosh)

            // Auto-save password if user entered it manually and it's not already saved
            finalizePendingPasswordSaveIfNeeded()

            Self.logger.info("Embedded Mosh session started successfully")
        } catch {
            handleMoshSessionError(error)
        }
    }

    /// Handle Mosh session end (normal disconnect)
    private func handleMoshSessionEnd() {
        handleEmbeddedSessionEnd {
            embeddedMoshSession?.stop()
            embeddedMoshSession = nil
            activeEmbeddedMoshConfig = nil
            NotificationCenter.default.post(name: .ghosttyEmbeddedMoshSessionDidChange, object: self)
        }
    }

    /// Handle Mosh session error
    private func handleMoshSessionError(_ error: Error) {
        // Guard against double-handling (onError callback + catch block can both fire)
        guard inlineFailureAnimator == nil else { return }

        // Also guard if we're already in password prompt mode (fallback already happened)
        if case .moshPasswordPrompt = sessionMode { return }

        preservingAuthBannerCard(from: embeddedMoshSession) {
            embeddedMoshSession?.stop()
            embeddedMoshSession = nil
            activeEmbeddedMoshConfig = nil
            NotificationCenter.default.post(name: .ghosttyEmbeddedMoshSessionDidChange, object: self)
        }

        // Check if this is an auth failure we can retry with password
        if attemptPasswordFallback(
            error: error,
            lastAttempted: &lastAttemptedMoshConfig,
            isPasswordAuth: { $0.sshConfig.authMethod.isPassword },
            promptMode: { config in
                .moshPasswordPrompt(makePartialMoshConfig(from: config))
            }
        ) {
            return
        }

        // Not an auth error or already tried password - show error normally
        sessionMode = .localShell
        pendingPasswordToSave = nil
        lastAttemptedMoshConfig = nil

        // Notify that we've returned to local shell (in case session was previously running)
        onEmbeddedConnectionConfigChanged?(nil)

        // Clean up spinner first
        cleanupInlineSpinner()

        // Play inline failure animation
        inlineFailureAnimator = InlineFailureAnimator()
        inlineFailureAnimator?.play(
            for: error,
            terminalWidth: Int(pty.windowSize.cols),
            onFrame: { [weak self] output in
                self?.onOutput?(output)
            },
            onComplete: { [weak self] in
                guard let self = self else { return }

                // Keep the animation visible - just clear the animator reference
                self.inlineFailureAnimator = nil

                // Show error message and prompt below the animation
                let errorMessage = "\r\n\r\nmosh: \(error.localizedDescription)\r\n"
                self.onOutput?(self.normalizeLineEndings(errorMessage))
                self.displayPrompt()
            }
        )
    }

    // MARK: - Trzsz/tssh Command Support

    /// Handle a tssh/trzsz command by parsing and starting an internal Trzsz session
    func handleTrzszCommand(_ command: String) {
        let result = TrzszCommandParser.parse(command: command)

        switch result {
        case .success(let trzszConfig):
            // Have a complete config, start Trzsz session
            // Pass terminalId for credential persistence (enables session resume)
            Task { @MainActor in
                await startEmbeddedTrzszSession(config: trzszConfig, terminalId: terminalId)
            }

        case .needsPassword(let partialConfig):
            // Check if we have a saved password for this connection
            let host = partialConfig.sshPartialConfig.host
            let port = partialConfig.sshPartialConfig.port
            let username = partialConfig.sshPartialConfig.username

            if SSHPasswordManager.shared.hasPassword(host: host, port: port, username: username) {
                // Use saved password - create config with .savedPassword auth method
                var sshConfig = partialConfig.sshPartialConfig.toSSHConfig(password: "")
                sshConfig.authMethod = .savedPassword
                let trzszConfig = TrzszConfig(
                    sshConfig: sshConfig,
                    transportMode: partialConfig.transportMode,
                    serverPath: partialConfig.serverPath
                )
                // Pass terminalId for credential persistence (enables session resume)
                Task { @MainActor in
                    await startEmbeddedTrzszSession(config: trzszConfig, terminalId: terminalId)
                }
            } else {
                // No saved password, prompt for one
                beginPasswordPrompt(.trzszPasswordPrompt(partialConfig))
            }

        case .help:
            displayTrzszHelp()

        case .error(let message):
            onOutput?(normalizeLineEndings("tssh: \(message)\r\n"))
            displayPrompt()
        }
    }

    /// Build a partial Trzsz config for password prompts.
    private func makePartialTrzszConfig(from config: TrzszConfig) -> TrzszCommandParser.PartialTrzszConfig {
        TrzszCommandParser.PartialTrzszConfig(
            sshPartialConfig: makePartialSSHConfig(from: config.sshConfig),
            transportMode: config.transportMode,
            serverPath: config.serverPath
        )
    }

    /// Start an embedded Trzsz session with the given configuration
    /// - Parameters:
    ///   - config: The Trzsz configuration
    ///   - terminalId: Optional terminal UUID for credential persistence (enables session resume)
    ///   - restoringFromTerminalId: If set, attempts to resume an existing session using stored credentials
    ///   - restoredLastConnectedAt: For restored sessions, the autosaved
    ///     `lastConnectedAt` heartbeat from the prior run. Used to bound
    ///     the resume retry loop to the server's 24h `AliveTimeout` window.
    func startEmbeddedTrzszSession(config: TrzszConfig, terminalId: UUID? = nil, restoringFromTerminalId: UUID? = nil, restoredLastConnectedAt: Date? = nil) async {
        // Guard against duplicate connection attempts
        guard embeddedTrzszSession == nil else {
            Self.logger.warning("Ignoring duplicate Trzsz session start - session already in progress")
            return
        }

        // Resolve saved password if needed
        guard let resolvedSSHConfig = await resolveSSHConfigOrPrompt(
            config.sshConfig,
            promptMode: { partialConfig in
                let trzszPartial = TrzszCommandParser.PartialTrzszConfig(
                    sshPartialConfig: partialConfig,
                    transportMode: config.transportMode,
                    serverPath: config.serverPath
                )
                return .trzszPasswordPrompt(trzszPartial)
            }
        ) else {
            return
        }

        // Create resolved Trzsz config
        let resolvedTrzszConfig = TrzszConfig(
            sshConfig: resolvedSSHConfig,
            transportMode: config.transportMode,
            udpPortMin: config.udpPortMin,
            udpPortMax: config.udpPortMax,
            serverPath: config.serverPath
        )

        // Start inline spinner animation with actual terminal width
        let isRestoring = restoringFromTerminalId != nil
        let spinnerMessage = isRestoring
            ? "Resuming session to \(resolvedTrzszConfig.displayName)..."
            : "Connecting to \(resolvedTrzszConfig.displayName)..."
        startInlineSpinner(message: spinnerMessage)

        // Create Trzsz session with terminal ID for credential persistence
        let trzszSession = TrzszSession(config: resolvedTrzszConfig, pty: pty, terminalId: terminalId)

        // Set up host key validation
        trzszSession.onHostKeyValidation = { [weak self] request in
            guard let self = self else { return .reject }
            return await self.handleHostKeyValidation(request)
        }

        // Configure callbacks - capture at setup time for thread-safe access
        let coordinator = EmbeddedSessionCoordinator(session: trzszSession, kind: .trzsz, titlePrefix: nil)
        coordinator.attach(to: self)

        let trzszSessionID = ObjectIdentifier(trzszSession)
        trzszSession.onAgentApprovalRequest = { [weak self] request in
            Task { @MainActor in
                guard let self else { return }
                guard self.isCurrentEmbeddedSession(trzszSessionID, kind: .trzsz) else { return }
                self.onAgentApprovalRequired?(request)
            }
        }

        // Keyboard-interactive (2FA/OTP/PAM) prompts during the tsshd SSH
        // bootstrap render inline in the terminal.
        trzszSession.onKeyboardInteractiveChallenge = { [weak self] challenge in
            guard let self else { return nil }
            guard self.isCurrentEmbeddedSession(trzszSessionID, kind: .trzsz) else { return nil }
            return await self.handleKeyboardInteractiveChallenge(challenge)
        }

        trzszSession.onStateChange = { [weak self] state in
            guard let self = self else { return }
            // Update spinner with connection progress
            switch state {
            case .connectingSSH(let host, let isJumpHost):
                let message = isJumpHost ? "Connecting to jump host \(host)..." : "Connecting via SSH to \(host)..."
                self.inlineSpinnerAnimator?.updateMessage(message, style: .connecting)
            case .authenticatingSSH(let host, let isJumpHost):
                let message = isJumpHost ? "Authenticating with jump host \(host)..." : "Authenticating with \(host)..."
                self.inlineSpinnerAnimator?.updateMessage(message, style: .authenticating)
            case .connectingToTarget(let host):
                self.inlineSpinnerAnimator?.updateMessage("Connecting to \(host) via jump host...", style: .connecting)
            case .authenticatingTarget(let host):
                self.inlineSpinnerAnimator?.updateMessage("Authenticating with \(host)...", style: .authenticating)
            case .spawningServer:
                self.inlineSpinnerAnimator?.updateMessage("Teaching server to roam free...", style: .authenticating)
            case .parsingServerInfo:
                self.inlineSpinnerAnimator?.updateMessage("Parsing server info...", style: .authenticating)
            case .establishingQUIC(let host, let port):
                self.inlineSpinnerAnimator?.updateMessage("Connecting QUIC to \(host):\(port)...", style: .connecting)
            case .establishingKCP(let host, let port):
                self.inlineSpinnerAnimator?.updateMessage("Connecting KCP to \(host):\(port)...", style: .connecting)
            case .authenticatingProxy:
                self.inlineSpinnerAnimator?.updateMessage("Authenticating with server...", style: .authenticating)
            case .running:
                // Connected! Clean up spinner.
                //
                // For resumed sessions, suppress the inline spinner's ESC[J
                // cleanup. That cleanup is buffered in the scrollback restore
                // gate alongside the spinner frames, the attach response, and
                // the resize-jiggle redraw. When the gate flushes after the
                // mode-restore trailer, ESC[J would land *after* the server's
                // redraw and wipe the alt-screen content the resumed remote
                // TUI just painted. Stop the animator without emitting the
                // cleanup — the alt-screen switch in the trailer plus the
                // server's own redraw clears any spinner-frame garbage.
                if trzszSession.wasResumed {
                    self.inlineSpinnerAnimator?.stop()
                    self.inlineSpinnerAnimator = nil
                } else {
                    self.cleanupInlineSpinner()
                }
                // Emit server auth banners (SSH_MSG_USERAUTH_BANNER) captured during
                // the bootstrap SSH auth, AFTER spinner cleanup so clearToEndOfScreen
                // doesn't wipe them. Empty on resume (no SSH re-auth), so this is a
                // safe no-op that won't disturb the alt-screen restore trailer.
                for raw in trzszSession.consumeAuthBanners() {
                    let rendered = SSHBanner.renderAuthBanner(raw)
                    if !rendered.isEmpty { self.onOutput?(rendered) }
                }
                // Notify the parent terminal view so it can apply the
                // mode-restoration trailer for resumed sessions, mirroring the
                // top-level `.trzsz` `.running` path. No-op when
                // wasResumed is false (handled inside applyResumeTrailer).
                self.onEmbeddedTrzszReady?(trzszSession)
            case .roaming(let previousNetwork):
                self.inlineSpinnerAnimator?.updateMessage("Roaming from \(previousNetwork)...", style: .reconnecting)
            case .resumingSession(let host, let port):
                self.inlineSpinnerAnimator?.updateMessage("Resuming session to \(host):\(port)...", style: .connecting)
            case .resumeFallback(let reason):
                self.inlineSpinnerAnimator?.updateMessage("Session expired: \(reason), reconnecting...", style: .reconnecting)
            default:
                break
            }
        }

        // Store session and switch mode
        embeddedTrzszSession = trzszSession
        sessionMode = .trzszSession
        NotificationCenter.default.post(name: .ghosttyEmbeddedTrzszSessionDidChange, object: self)

        // Store config for potential auth failure retry with password
        lastAttemptedTrzszConfig = resolvedTrzszConfig

        // Start the Trzsz session
        do {
            // If restoring from a previous session, use the restoration API to resume QUIC state
            if let restoreId = restoringFromTerminalId {
                try await trzszSession.start(
                    restoringFromTerminalId: restoreId,
                    restoredLastConnectedAt: restoredLastConnectedAt
                )
            } else {
                try await trzszSession.start()
            }

            // Clear retry config on success (but keep active config for session recovery)
            lastAttemptedTrzszConfig = nil

            // Note: tmux auto-connect is now handled via exec request in connectGoTransport,
            // so no terminal input workaround is needed here.

            // Store active config for session recovery (allows serialization of shell-launched sessions)
            activeEmbeddedTrzszConfig = resolvedTrzszConfig

            // Notify that we've transitioned to an embedded Trzsz session
            onEmbeddedConnectionConfigChanged?(activeEmbeddedConnectionConfig)

            // Record successful connection to history (using SSH config info)
            recordSSHConnectionHistory(for: resolvedSSHConfig, protocol: .trzsz)

            // Auto-save password if user entered it manually and it's not already saved
            finalizePendingPasswordSaveIfNeeded()

            Self.logger.info("Embedded Trzsz session started successfully")
        } catch is CancellationError {
            // User closed the tab during the resume retry loop. terminate()
            // already drove the cleanup; skip handleTrzszSessionError so we
            // don't surface a fake error or play the failure animation.
            Self.logger.info("Embedded Trzsz session start aborted (tab closing)")
        } catch {
            handleTrzszSessionError(error)
        }
    }

    /// Handle Trzsz session end (normal disconnect)
    private func handleTrzszSessionEnd() {
        handleEmbeddedSessionEnd {
            embeddedTrzszSession?.stop()
            embeddedTrzszSession = nil
            activeEmbeddedTrzszConfig = nil
            NotificationCenter.default.post(name: .ghosttyEmbeddedTrzszSessionDidChange, object: self)
        }
    }

    /// Handle Trzsz session error
    private func handleTrzszSessionError(_ error: Error) {
        // Guard against double-handling (onError callback + catch block can both fire)
        guard inlineFailureAnimator == nil else { return }

        // Also guard if we're already in password prompt mode (fallback already happened)
        if case .trzszPasswordPrompt = sessionMode { return }

        // Tell the parent terminal view to release the scrollback-restore gate
        // it may be holding open in anticipation of a resume trailer. Must run
        // before any output (cleanupInlineSpinner, password prompt, failure
        // animation, error message) is emitted below — otherwise that output
        // ends up buffered behind the still-open gate and the user sees only
        // the restored scrollback with no failure UI.
        onEmbeddedTrzszFailedBeforeRunning?()

        preservingAuthBannerCard(from: embeddedTrzszSession) {
            embeddedTrzszSession?.stop()
            embeddedTrzszSession = nil
            activeEmbeddedTrzszConfig = nil
            NotificationCenter.default.post(name: .ghosttyEmbeddedTrzszSessionDidChange, object: self)
        }

        // Check if this is an auth failure we can retry with password
        if attemptPasswordFallback(
            error: error,
            lastAttempted: &lastAttemptedTrzszConfig,
            isPasswordAuth: { $0.sshConfig.authMethod.isPassword },
            promptMode: { config in
                .trzszPasswordPrompt(makePartialTrzszConfig(from: config))
            }
        ) {
            return
        }

        // Not an auth error or already tried password - show error normally
        sessionMode = .localShell
        pendingPasswordToSave = nil
        lastAttemptedTrzszConfig = nil

        // Notify that we've returned to local shell (in case session was previously running)
        onEmbeddedConnectionConfigChanged?(nil)

        // Clean up spinner first
        cleanupInlineSpinner()

        // Play inline failure animation
        inlineFailureAnimator = InlineFailureAnimator()
        inlineFailureAnimator?.play(
            for: error,
            terminalWidth: Int(pty.windowSize.cols),
            onFrame: { [weak self] output in
                self?.onOutput?(output)
            },
            onComplete: { [weak self] in
                guard let self = self else { return }

                // Keep the animation visible - just clear the animator reference
                self.inlineFailureAnimator = nil

                // Show error message and prompt below the animation
                let errorMessage = "\r\n\r\ntrzsz: \(error.localizedDescription)\r\n"
                self.onOutput?(self.normalizeLineEndings(errorMessage))
                self.displayPrompt()
            }
        )
    }
}

#endif // !targetEnvironment(macCatalyst)
