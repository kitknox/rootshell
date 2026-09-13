//
//  SSHCommandParser.swift
//  rootshell
//
//  Parses SSH command-line arguments into SSHConfig for internal SSH client integration
//

import Foundation
import os.log

/// Parser for SSH command-line arguments
/// Supports: -p (port), -l (user), -J (jump host), -i (identity), -A (agent forwarding),
///           -L (local forward), -R (remote forward), -o (options),
///           --path (Rootshell-specific remote exec wrapper)
@MainActor
struct SSHCommandParser {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHCommandParser")
    private static let prependPATHFlag = "--path"

    /// Result of parsing an SSH command
    enum ParseResult {
        /// Successfully parsed with complete config (has auth method)
        case success(SSHConfig)
        /// Parsed but needs password (no key match, no stored password)
        case needsPassword(PartialSSHConfig)
        /// Parse error with message
        case error(String)
        /// User requested help (bare ssh, -h, or --help)
        case help
    }

    /// Partial config when password is needed
    struct PartialSSHConfig: Sendable {
        var host: String
        var port: Int
        var username: String
        var jumpHost: SSHConfig.JumpHostConfig?
        var agentConfig: SSHAgentConfig
        var portForwardConfig: PortForwardConfig
        var cachedIP: String?
        var tmuxAutoEnable: Bool = false
        var tmuxAutoMode: TmuxAutoMode = .regular
        var herdrAutoEnable: Bool = false
        var herdrAutoMode: HerdrAutoMode = .regular
        var zmxAutoEnable: Bool = false
        var remoteCommand: String?
        var remoteCommandPolicy: SSHConfig.RemoteCommandPolicy = .verbatim
        /// Per-profile multiplexer session name, carried through the password
        /// prompt round-trip. Not settable from the command line.
        var multiplexerSessionName: String?

        /// Convert to full SSHConfig with password
        func toSSHConfig(password: String) -> SSHConfig {
            var config = SSHConfig(
                host: host,
                port: port,
                username: username,
                password: password,
                cachedIP: cachedIP,
                jumpHost: jumpHost,
                agentConfig: agentConfig,
                portForwardConfig: portForwardConfig,
                tmuxAutoEnable: tmuxAutoEnable,
                tmuxAutoMode: tmuxAutoMode
            )
            config.herdrAutoEnable = herdrAutoEnable
            config.herdrAutoMode = herdrAutoMode
            config.zmxAutoEnable = zmxAutoEnable
            config.multiplexerSessionName = multiplexerSessionName
            config.remoteCommand = remoteCommand
            config.remoteCommandPolicy = remoteCommandPolicy
            return config
        }
    }

    /// Parse an SSH command string into configuration
    /// - Parameter command: Full command string (e.g., "ssh -p 2222 user@host")
    /// - Returns: ParseResult with success, needsPassword, help, or error
    static func parse(command: String) -> ParseResult {
        let tokens = tokenize(command)

        guard !tokens.isEmpty else {
            return .error("Empty command")
        }

        // First token should be "ssh"
        guard tokens[0].text.lowercased() == "ssh" else {
            return .error("Not an ssh command")
        }

        // Check for help request: bare "ssh", "ssh -h", or "ssh --help"
        if tokens.count == 1 {
            return .help
        }
        if tokens.count == 2 && (tokens[1].text == "-h" || tokens[1].text == "--help") {
            return .help
        }

        var port = 22
        var username: String?
        var host: String?
        var identityFile: String?
        var jumpHostString: String?
        var agentForwarding = false
        var agentAutoApprove = false
        var sshOptions: [String: String] = [:]
        var localForwards: [PortForwardConfig.PortForward] = []
        var remoteForwards: [PortForwardConfig.PortForward] = []
        var tmuxAutoEnable = false
        var herdrAutoEnable = false
        var herdrAutoMode: HerdrAutoMode = .regular
        var zmxAutoEnable = false
        var remoteCommand: String?
        var remoteCommandPolicy: SSHConfig.RemoteCommandPolicy = .verbatim

        var i = 1
        while i < tokens.count {
            let token = tokens[i].text

            // Once we have a destination, all remaining tokens are the remote command
            if host != nil {
                remoteCommand = String(command[tokens[i].range.lowerBound...])
                break
            }

            if token.hasPrefix("-") {
                // Handle flags
                switch token {
                case "-L":
                    // Local port forwarding: -L [bind_address:]port:host:hostport
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing argument after -L")
                    }
                    guard let forward = PortForwardConfig.PortForward.parse(tokens[i].text, direction: .local) else {
                        return .error("Invalid local forward specification: \(tokens[i].text)")
                    }
                    localForwards.append(forward)

                case "-R":
                    // Remote port forwarding: -R [bind_address:]port:host:hostport
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing argument after -R")
                    }
                    guard let forward = PortForwardConfig.PortForward.parse(tokens[i].text, direction: .remote) else {
                        return .error("Invalid remote forward specification: \(tokens[i].text)")
                    }
                    remoteForwards.append(forward)

                case "-p":
                    // Port
                    i += 1
                    guard i < tokens.count, let p = Int(tokens[i].text), p > 0, p <= 65535 else {
                        return .error("Invalid port number")
                    }
                    port = p

                case "-l":
                    // Username
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing username after -l")
                    }
                    username = tokens[i].text

                case "-J":
                    // Jump host
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing jump host after -J")
                    }
                    jumpHostString = tokens[i].text

                case "-i":
                    // Identity file
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing identity file after -i")
                    }
                    identityFile = tokens[i].text

                case "-AA":
                    // Agent forwarding with auto-approval
                    agentForwarding = true
                    agentAutoApprove = true

                case "-A":
                    // Agent forwarding
                    agentForwarding = true

                case "-o":
                    // SSH option
                    i += 1
                    guard i < tokens.count else {
                        return .error("Missing option after -o")
                    }
                    if let (key, value) = parseOption(tokens[i].text) {
                        sshOptions[key] = value
                    }

                case "--tmux":
                    // Enable tmux auto-start
                    tmuxAutoEnable = true

                case "--herdr":
                    // Enable herdr auto-attach
                    herdrAutoEnable = true

                case "--herdr-control":
                    // herdr control mode: shell stays, herdr drives tabs
                    herdrAutoEnable = true
                    herdrAutoMode = .control

                case "--zmx":
                    // Enable zmx auto-attach
                    zmxAutoEnable = true

                case Self.prependPATHFlag:
                    // Rootshell-specific opt-in that preserves the old PATH wrapper
                    // for shell-launched SSH exec requests.
                    remoteCommandPolicy = .prependPATH

                default:
                    // Unknown flag - skip or combine short flags
                    if token.hasPrefix("-") && token.count > 2 && !token.hasPrefix("--") {
                        // Could be combined flags like -Ap
                        for char in token.dropFirst() {
                            if char == "A" {
                                agentForwarding = true
                                if token == "-AA" {
                                    agentAutoApprove = true
                                }
                            }
                            // Other single-char flags we might care about
                        }
                    }
                    // Otherwise ignore unknown flags
                }
            } else {
                // First positional argument - should be [user@]host[:port]
                let parsed = parseDestination(token)
                if let u = parsed.username {
                    username = u
                }
                host = parsed.host
                if let p = parsed.port {
                    port = p
                }
            }

            i += 1
        }

        // Apply -o options that we recognize
        if let optPort = sshOptions["Port"], let p = Int(optPort) {
            port = p
        }
        if let optUser = sshOptions["User"] {
            username = optUser
        }
        if let optJump = sshOptions["ProxyJump"] {
            jumpHostString = optJump
        }
        if let optIdentity = sshOptions["IdentityFile"] {
            identityFile = optIdentity
        }

        // Validate we have a host
        guard let finalHost = host, !finalHost.isEmpty else {
            return .error("Missing hostname")
        }

        // Default username to current user if not specified
        let finalUsername = username ?? UserPreferences.effectiveUsername

        logger.info("Parsed SSH: \(finalUsername)@\(finalHost):\(port), identity=\(identityFile ?? "none"), jump=\(jumpHostString ?? "none"), agent=\(agentForwarding), agentAutoApprove=\(agentAutoApprove)")

        // Build jump host config if specified
        var jumpHostConfig: SSHConfig.JumpHostConfig?
        if let jumpStr = jumpHostString {
            let jumpParsed = parseDestination(jumpStr)
            let jumpUser = jumpParsed.username ?? finalUsername
            guard let jumpHost = jumpParsed.host, !jumpHost.isEmpty else {
                return .error("Invalid jump host")
            }
            // For jump host auth, we'll try to find a matching key or fall back to password prompt
            let jumpKeyID = findMatchingKey(for: jumpUser, host: jumpHost, identityHint: nil)

            // Build fallback keys for jump host
            let jumpFallbackIDs: [UUID]?
            if let keyID = jumpKeyID {
                jumpFallbackIDs = SSHKeyManager.shared.defaultKeyIDs.filter { $0 != keyID }
            } else {
                jumpFallbackIDs = nil
            }

            jumpHostConfig = SSHConfig.JumpHostConfig(
                host: jumpHost,
                port: jumpParsed.port ?? 22,
                username: jumpUser,
                authMethod: jumpKeyID != nil ? .key(jumpKeyID!) : .password(""),
                fallbackKeyIDs: jumpFallbackIDs?.isEmpty == true ? nil : jumpFallbackIDs
            )
        }

        // Build agent config
        let agentConfig: SSHAgentConfig
        if agentForwarding {
            let approvalMode: SSHAgentConfig.ApprovalMode = agentAutoApprove ? .autoApprove : .sessionApprove
            agentConfig = SSHAgentConfig.withAllKeys(mode: approvalMode)
        } else {
            agentConfig = .disabled
        }

        // Build port forward config
        let allForwards = localForwards + remoteForwards
        let portForwardConfig = allForwards.isEmpty ? .none : PortForwardConfig(forwards: allForwards)

        // Check connection history for cached IP
        let historyEntry = findHistoryEntry(username: finalUsername, host: finalHost, port: port)
        let cachedIP = historyEntry?.cachedIP

        // Check if "none" authentication was explicitly requested (Tailscale/WireGuard)
        if let preferredAuth = sshOptions["PreferredAuthentications"]?.lowercased(),
           preferredAuth == "none" {
            logger.info("Using 'none' authentication (PreferredAuthentications=none)")
            var config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                authMethod: .none,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig,
                portForwardConfig: portForwardConfig,
                tmuxAutoEnable: tmuxAutoEnable
            )
            config.herdrAutoEnable = herdrAutoEnable
            config.herdrAutoMode = herdrAutoMode
            config.zmxAutoEnable = zmxAutoEnable
            config.remoteCommand = remoteCommand
            config.remoteCommandPolicy = remoteCommandPolicy
            return .success(config)
        }

        // Try to find a matching key
        var keyID: UUID?

        // First try explicit identity file
        if let identity = identityFile {
            keyID = findKeyByIdentityPath(identity)
        }

        // If no explicit key, try to find from history
        if keyID == nil {
            keyID = findMatchingKey(for: finalUsername, host: finalHost, identityHint: identityFile)
        }

        // If we found a key, return success
        if let foundKeyID = keyID {
            var config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                keyID: foundKeyID,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig,
                portForwardConfig: portForwardConfig,
                tmuxAutoEnable: tmuxAutoEnable
            )
            config.herdrAutoEnable = herdrAutoEnable
            config.herdrAutoMode = herdrAutoMode
            config.zmxAutoEnable = zmxAutoEnable
            config.remoteCommand = remoteCommand
            config.remoteCommandPolicy = remoteCommandPolicy
            return .success(config)
        }

        // Check if we have a saved password for this connection
        if SSHPasswordManager.shared.hasPassword(host: finalHost, port: port, username: finalUsername) {
            logger.info("Found saved password for \(finalUsername)@\(finalHost):\(port)")
            var config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                authMethod: .savedPassword,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig,
                portForwardConfig: portForwardConfig,
                tmuxAutoEnable: tmuxAutoEnable
            )
            config.herdrAutoEnable = herdrAutoEnable
            config.herdrAutoMode = herdrAutoMode
            config.zmxAutoEnable = zmxAutoEnable
            config.remoteCommand = remoteCommand
            config.remoteCommandPolicy = remoteCommandPolicy
            return .success(config)
        }

        // Fall back to default keys if set and no saved password found
        if let primaryKeyID = SSHKeyManager.shared.primaryDefaultKeyID {
            // Build fallback keys list from remaining defaults
            let allDefaults = SSHKeyManager.shared.defaultKeyIDs
            let fallbackIDs = Array(allDefaults.dropFirst())

            logger.info("Using default key for \(finalUsername)@\(finalHost): \(primaryKeyID) (+ \(fallbackIDs.count) fallbacks)")
            var config = SSHConfig(
                host: finalHost,
                port: port,
                username: finalUsername,
                keyID: primaryKeyID,
                fallbackKeyIDs: fallbackIDs.isEmpty ? nil : fallbackIDs,
                cachedIP: cachedIP,
                jumpHost: jumpHostConfig,
                agentConfig: agentConfig,
                portForwardConfig: portForwardConfig,
                tmuxAutoEnable: tmuxAutoEnable
            )
            config.herdrAutoEnable = herdrAutoEnable
            config.herdrAutoMode = herdrAutoMode
            config.zmxAutoEnable = zmxAutoEnable
            config.remoteCommand = remoteCommand
            config.remoteCommandPolicy = remoteCommandPolicy
            return .success(config)
        }

        // If jump host needs password, we need to prompt for that too
        // For now, just prompt for target password
        let partial = PartialSSHConfig(
            host: finalHost,
            port: port,
            username: finalUsername,
            jumpHost: jumpHostConfig,
            agentConfig: agentConfig,
            portForwardConfig: portForwardConfig,
            cachedIP: cachedIP,
            tmuxAutoEnable: tmuxAutoEnable,
            herdrAutoEnable: herdrAutoEnable,
            herdrAutoMode: herdrAutoMode,
            zmxAutoEnable: zmxAutoEnable,
            remoteCommand: remoteCommand,
            remoteCommandPolicy: remoteCommandPolicy
        )

        return .needsPassword(partial)
    }

    // MARK: - Private Helpers

    private struct Token {
        let text: String
        let range: Range<String.Index>
    }

    /// Tokenize command string, respecting quotes and preserving source ranges.
    private static func tokenize(_ command: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuote: Character?
        var tokenStart: String.Index?

        var index = command.startIndex
        while index < command.endIndex {
            let char = command[index]
            if let quote = inQuote {
                if char == quote {
                    inQuote = nil
                } else {
                    current.append(char)
                }
            } else if char == "\"" || char == "'" {
                if tokenStart == nil {
                    tokenStart = index
                }
                inQuote = char
            } else if char.isWhitespace {
                if let start = tokenStart {
                    tokens.append(Token(text: current, range: start..<index))
                    current = ""
                    tokenStart = nil
                }
            } else {
                if tokenStart == nil {
                    tokenStart = index
                }
                current.append(char)
            }

            index = command.index(after: index)
        }

        if let tokenStart {
            tokens.append(Token(text: current, range: tokenStart..<command.endIndex))
        }

        return tokens
    }

    /// Parse -o option string (key=value or key value)
    private static func parseOption(_ option: String) -> (String, String)? {
        if let eqIndex = option.firstIndex(of: "=") {
            let key = String(option[..<eqIndex])
            let value = String(option[option.index(after: eqIndex)...])
            return (key, value)
        }
        return nil
    }

    /// Parse [user@]host[:port] destination string
    private static func parseDestination(_ dest: String) -> (username: String?, host: String?, port: Int?) {
        var remaining = dest
        var username: String?
        var port: Int?

        // Extract user@ prefix (split on LAST @ so usernames containing @ — e.g.
        // Active-Directory-style user@domain — survive host separation)
        if let atIndex = remaining.lastIndex(of: "@") {
            username = String(remaining[..<atIndex])
            remaining = String(remaining[remaining.index(after: atIndex)...])
        }

        // Extract :port suffix (but be careful with IPv6 [host]:port)
        if remaining.hasPrefix("[") {
            // IPv6 format: [host]:port
            if let closeIndex = remaining.firstIndex(of: "]") {
                let afterClose = remaining.index(after: closeIndex)
                if afterClose < remaining.endIndex && remaining[afterClose] == ":" {
                    let portStr = String(remaining[remaining.index(after: afterClose)...])
                    port = Int(portStr)
                    remaining = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                } else {
                    remaining = String(remaining[remaining.index(after: remaining.startIndex)..<closeIndex])
                }
            }
        } else if let colonIndex = remaining.lastIndex(of: ":") {
            // Regular host:port - but only if what follows looks like a port number
            let portStr = String(remaining[remaining.index(after: colonIndex)...])
            if let p = Int(portStr), p > 0, p <= 65535 {
                port = p
                remaining = String(remaining[..<colonIndex])
            }
        }

        return (username, remaining.isEmpty ? nil : remaining, port)
    }

    /// Find an SSH key by identity file path
    /// Matches the filename against key names in the key manager
    static func findKeyByIdentityPath(_ path: String) -> UUID? {
        // Extract filename from path
        let filename = (path as NSString).lastPathComponent
        // Remove common extensions
        let baseName = filename
            .replacingOccurrences(of: ".pub", with: "")
            .replacingOccurrences(of: ".pem", with: "")

        let keys = SSHKeyManager.shared.savedKeys

        // Try exact match first
        if let key = keys.first(where: { $0.name.lowercased() == baseName.lowercased() }) {
            logger.info("Found exact key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        // Try prefix match
        if let key = keys.first(where: { $0.name.lowercased().hasPrefix(baseName.lowercased()) }) {
            logger.info("Found prefix key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        // Try contains match
        if let key = keys.first(where: { $0.name.lowercased().contains(baseName.lowercased()) }) {
            logger.info("Found partial key match for identity '\(baseName)': \(key.name)")
            return key.id
        }

        logger.info("No key match found for identity '\(baseName)'")
        return nil
    }

    /// Find a matching key from connection history or default key
    private static func findMatchingKey(for username: String, host: String, identityHint: String?) -> UUID? {
        let historyManager = SSHConnectionHistoryManager.shared
        let keyManager = SSHKeyManager.shared

        // Check connection history for this host - only return key if history shows key auth was used
        for entry in historyManager.entries {
            if entry.host.lowercased() == host.lowercased() &&
               entry.username.lowercased() == username.lowercased() {
                if case .key(let keyID, let fingerprint) = entry.authType {
                    // Verify key still exists (use resolveKey for cross-device support)
                    if keyManager.resolveKey(id: keyID, fingerprint: fingerprint) != nil {
                        logger.info("Found key from history for \(username)@\(host): \(keyID)")
                        return keyID
                    }
                }
            }
        }

        // Don't fall back to default key here - let the parser check saved passwords first.
        // The default key will be used only if there's no matching history entry and no saved password.
        return nil
    }

    /// Find a connection history entry for the given target
    private static func findHistoryEntry(username: String, host: String, port: Int) -> SSHConnectionHistoryEntry? {
        let historyManager = SSHConnectionHistoryManager.shared

        return historyManager.entries.first { entry in
            entry.host.lowercased() == host.lowercased() &&
            entry.username.lowercased() == username.lowercased() &&
            entry.port == port
        }
    }
}
