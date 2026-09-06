#if !CHINA_BUILD
//
//  LocalFingerprintCollector.swift
//  rootshell
//
//  System fingerprinting for local Mac Catalyst AI Agent
//  Mac Catalyst only
//

#if targetEnvironment(macCatalyst)

import Foundation
import os.log

/// Collects system fingerprint for the local Mac
/// Used by AI Agent when running locally (not SSH)
@MainActor
final class LocalFingerprintCollector {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "LocalFingerprintCollector")

    /// Cache duration in seconds (2 hours)
    private static let cacheDuration: TimeInterval = 2 * 60 * 60

    private let executor: CatalystLocalExecutor
    private var cachedFingerprint: (fingerprint: HostFingerprint, expires: Date)?

    init(executor: CatalystLocalExecutor) {
        self.executor = executor
    }

    /// Collect fingerprint for the local machine
    /// - Parameter forceRefresh: If true, ignore cache and collect fresh data
    /// - Returns: The host fingerprint
    func collect(forceRefresh: Bool = false) async throws -> HostFingerprint {
        // Check cache unless forcing refresh
        if !forceRefresh, let cached = cachedFingerprint, Date() < cached.expires {
            Self.logger.debug("Using cached local fingerprint")
            return cached.fingerprint
        }

        Self.logger.info("Collecting local machine fingerprint")

        // Collect all information in parallel where possible
        async let hostnameResult = runCommand("hostname -f 2>/dev/null || hostname")
        async let osResult = runCommand("uname -s")
        async let archResult = runCommand("uname -m")
        async let kernelResult = runCommand("uname -r")
        async let shellResult = runCommand("echo $SHELL")
        async let usernameResult = runCommand("whoami")
        async let homeResult = runCommand("echo $HOME")
        async let distroResult = detectDistro()
        async let sudoResult = checkSudo()

        // Collect environment and tools in parallel
        async let envResult = collectEnvironment()
        async let toolsResult = discoverTools()

        let hostname = try await hostnameResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let os = try await osResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let arch = try await archResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let kernel = try await kernelResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = try await shellResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = try await usernameResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = try await homeResult.trimmingCharacters(in: .whitespacesAndNewlines)
        let distro = try await distroResult
        let hasSudo = try await sudoResult

        // Await environment and tools results
        let envParsed = await envResult
        let availableTools = await toolsResult

        // Detect language versions for discovered runtimes
        let languageRuntimes = await detectLanguageVersions(available: availableTools)

        let fingerprint = HostFingerprint(
            hostname: hostname.isEmpty ? "localhost" : hostname,
            os: os.isEmpty ? "Darwin" : os,
            distro: distro,
            arch: arch.isEmpty ? "arm64" : arch,
            shell: shell.isEmpty ? "/bin/zsh" : shell,
            username: username.isEmpty ? NSUserName() : username,
            homeDirectory: home.isEmpty ? NSHomeDirectory() : home,
            kernelVersion: kernel.isEmpty ? nil : kernel,
            hasSudo: hasSudo,
            currentDirectory: FileManager.default.currentDirectoryPath,
            timestamp: Date(),
            path: envParsed.path,
            environment: envParsed.filtered,
            availableTools: availableTools,
            languageRuntimes: languageRuntimes
        )

        // Cache the result
        let expires = Date().addingTimeInterval(Self.cacheDuration)
        cachedFingerprint = (fingerprint, expires)

        let toolCount = availableTools.count
        Self.logger.info("Local fingerprint collected: \(os) \(arch), shell: \(shell), \(toolCount) tools discovered")

        return fingerprint
    }

    /// Update current directory in fingerprint
    func updateCurrentDirectory(_ directory: String) -> HostFingerprint? {
        guard var cached = cachedFingerprint else { return nil }

        var fingerprint = cached.fingerprint
        fingerprint.currentDirectory = directory
        cached.fingerprint = fingerprint
        cachedFingerprint = cached

        return fingerprint
    }

    /// Clear cached fingerprint
    func clearCache() {
        cachedFingerprint = nil
    }

    // MARK: - Private Helpers

    private func runCommand(_ command: String) async throws -> String {
        let result = try await executor.execute(command: command, timeout: 10)
        return result.output
    }

    /// Fingerprinting runs before the executor knows the user's shell.
    private func runPOSIXProbe(_ command: String) async throws -> String {
        let probe = LoginShellCommand.runInPOSIXShell(command)
        return try await runCommand(LoginShellCommand.runInLoginShell(probe))
    }

    private func detectDistro() async throws -> String? {
        // For macOS, use sw_vers
        if let version = try? await runCommand("sw_vers -productVersion 2>/dev/null") {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Try to get product name too
                if let productName = try? await runCommand("sw_vers -productName 2>/dev/null") {
                    let name = productName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        return "\(name) \(trimmed)"
                    }
                }
                return "macOS \(trimmed)"
            }
        }
        return nil
    }

    private func checkSudo() async throws -> Bool? {
        // Check if user can run sudo without password (NOPASSWD)
        if let result = try? await runCommand("sudo -n true 2>&1 && echo yes || echo no") {
            return result.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
        }
        return nil
    }

    // MARK: - Environment & Tool Discovery

    /// Collect environment variables from the local machine using login shell
    private func collectEnvironment() async -> EnvironmentParser.ParseResult {
        do {
            let envOutput = try await runPOSIXProbe("env 2>/dev/null")
            return EnvironmentParser.parse(envOutput, filterSensitive: true)
        } catch {
            Self.logger.warning("Failed to collect environment: \(error.localizedDescription)")
            return EnvironmentParser.ParseResult(path: nil, filtered: [:])
        }
    }

    /// Discover available tools on the local machine
    private func discoverTools() async -> Set<String> {
        let allTools = Array(ToolCategories.allTools)
        let batchSize = 30
        var discoveredTools = Set<String>()

        for batch in stride(from: 0, to: allTools.count, by: batchSize) {
            let endIndex = min(batch + batchSize, allTools.count)
            let toolBatch = Array(allTools[batch..<endIndex])

            do {
                let toolList = toolBatch.joined(separator: " ")
                let script = "for cmd in \(toolList); do command -v \"$cmd\" >/dev/null 2>&1 && echo \"$cmd\"; done"
                let result = try await runPOSIXProbe(script)

                let found = result.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                discoveredTools.formUnion(found)
            } catch {
                Self.logger.warning("Tool discovery batch failed: \(error.localizedDescription)")
            }
        }

        Self.logger.debug("Discovered \(discoveredTools.count) tools")
        return discoveredTools
    }

    /// Detect versions for language runtimes
    private func detectLanguageVersions(available: Set<String>) async -> [String: String] {
        var versions: [String: String] = [:]

        let languageCommands: [(tool: String, versionCommand: String, parser: (String) -> String?)] = [
            ("python3", "python3 --version 2>&1", { output in
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "Python ", with: "")
            }),
            ("python", "python --version 2>&1", { output in
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "Python ", with: "")
            }),
            ("node", "node --version 2>&1", { output in
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "v", with: "")
            }),
            ("ruby", "ruby --version 2>&1", { output in
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"ruby (\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "ruby ", with: "")
                }
                return nil
            }),
            ("go", "go version 2>&1", { output in
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"go(\d+\.\d+\.?\d*)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "go", with: "")
                }
                return nil
            }),
            ("rustc", "rustc --version 2>&1", { output in
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"rustc (\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "rustc ", with: "")
                }
                return nil
            }),
            ("swift", "swift --version 2>&1", { output in
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"Swift version (\d+\.\d+\.?\d*)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "Swift version ", with: "")
                }
                return nil
            }),
        ]

        for (tool, command, parser) in languageCommands {
            guard available.contains(tool) else { continue }

            do {
                let output = try await runPOSIXProbe(command)
                if let version = parser(output), !version.isEmpty {
                    versions[tool] = version
                }
            } catch {
                Self.logger.debug("Failed to get version for \(tool): \(error.localizedDescription)")
            }
        }

        return versions
    }
}

#endif // targetEnvironment(macCatalyst)
#endif
