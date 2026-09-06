#if !CHINA_BUILD
//
//  HostFingerprint.swift
//  rootshell
//
//  System fingerprinting for AI Agent context
//

import Foundation
import os.log

/// Information about the remote host's system
struct HostFingerprint: Codable, Sendable {
    /// Hostname
    let hostname: String

    /// Operating system (e.g., "Linux", "Darwin", "FreeBSD")
    let os: String

    /// Distribution/variant (e.g., "Ubuntu 22.04", "macOS Sonoma")
    let distro: String?

    /// CPU architecture (e.g., "x86_64", "aarch64", "arm64")
    let arch: String

    /// Default shell (e.g., "/bin/bash", "/bin/zsh")
    let shell: String

    /// Current username
    let username: String

    /// Home directory
    let homeDirectory: String

    /// Kernel version
    let kernelVersion: String?

    /// Whether the user has sudo access
    let hasSudo: Bool?

    /// Current working directory (set dynamically)
    var currentDirectory: String?

    /// Timestamp when this fingerprint was collected
    let timestamp: Date

    /// PATH environment variable for command execution
    let path: String?

    /// Safe environment variables (sensitive ones filtered out)
    let environment: [String: String]

    /// Available tools/binaries detected on the system
    let availableTools: Set<String>

    /// Language runtimes with versions (e.g., ["python3": "3.11.2"])
    let languageRuntimes: [String: String]

    /// Generate a summary for the AI system prompt (basic host info)
    func summary() -> String {
        var lines = [String]()
        lines.append("- Hostname: \(hostname)")
        lines.append("- OS: \(os)\(distro.map { " (\($0))" } ?? "")")
        lines.append("- Architecture: \(arch)")
        lines.append("- Shell: \(shell)")
        lines.append("- User: \(username)")
        if let cwd = currentDirectory {
            lines.append("- Current Directory: \(cwd)")
        }
        if let kernel = kernelVersion {
            lines.append("- Kernel: \(kernel)")
        }
        if let sudo = hasSudo, sudo {
            lines.append("- Sudo: Available")
        }
        return lines.joined(separator: "\n")
    }

    /// Generate a summary of available tools by category
    func toolsSummary() -> String {
        guard !availableTools.isEmpty else {
            return "No tools discovered"
        }

        var sections = [String]()

        // Categorize tools
        let packageManagers = availableTools.intersection(ToolCategories.packageManagers)
        let versionControl = availableTools.intersection(ToolCategories.versionControl)
        let containers = availableTools.intersection(ToolCategories.containers)
        let cloudCLIs = availableTools.intersection(ToolCategories.cloudCLIs)
        let databases = availableTools.intersection(ToolCategories.databases)
        let networking = availableTools.intersection(ToolCategories.networking)
        let systemTools = availableTools.intersection(ToolCategories.systemTools)
        let textBuild = availableTools.intersection(ToolCategories.textAndBuild)

        // Languages with versions
        if !languageRuntimes.isEmpty {
            let formatted = languageRuntimes.map { "\($0.key) (\($0.value))" }.sorted().joined(separator: ", ")
            sections.append("- Languages: \(formatted)")
        }

        if !packageManagers.isEmpty {
            sections.append("- Package managers: \(packageManagers.sorted().joined(separator: ", "))")
        }
        if !versionControl.isEmpty {
            sections.append("- Version control: \(versionControl.sorted().joined(separator: ", "))")
        }
        if !containers.isEmpty {
            sections.append("- Container tools: \(containers.sorted().joined(separator: ", "))")
        }
        if !cloudCLIs.isEmpty {
            sections.append("- Cloud CLIs: \(cloudCLIs.sorted().joined(separator: ", "))")
        }
        if !databases.isEmpty {
            sections.append("- Databases: \(databases.sorted().joined(separator: ", "))")
        }
        if !networking.isEmpty {
            sections.append("- Networking: \(networking.sorted().joined(separator: ", "))")
        }
        if !systemTools.isEmpty {
            sections.append("- System: \(systemTools.sorted().joined(separator: ", "))")
        }
        if !textBuild.isEmpty {
            sections.append("- Text/Build: \(textBuild.sorted().joined(separator: ", "))")
        }

        return sections.isEmpty ? "No categorized tools found" : sections.joined(separator: "\n")
    }

    /// Generate a summary of environment variables (safe ones only)
    func environmentSummary() -> String {
        guard !environment.isEmpty else {
            return "No environment variables captured"
        }

        // Select the most useful variables for display
        let displayKeys = ["LANG", "LC_ALL", "TERM", "EDITOR", "VISUAL", "PAGER"]
        var lines = [String]()

        for key in displayKeys {
            if let value = environment[key] {
                lines.append("- \(key): \(value)")
            }
        }

        return lines.isEmpty ? "Standard environment" : lines.joined(separator: "\n")
    }
}

// MARK: - Tool Categories

/// Categories of tools for organized display
enum ToolCategories {
    static let packageManagers: Set<String> = [
        "apt", "apt-get", "yum", "dnf", "pacman", "brew", "zypper", "apk", "pkg", "snap", "flatpak",
        "pip", "pip3", "npm", "yarn", "pnpm", "cargo", "gem", "composer", "go"
    ]

    static let versionControl: Set<String> = ["git", "svn", "hg", "bzr"]

    static let containers: Set<String> = [
        "docker", "podman", "kubectl", "helm", "k9s", "crictl", "nerdctl", "containerd"
    ]

    static let cloudCLIs: Set<String> = [
        "aws", "gcloud", "az", "doctl", "linode-cli", "terraform", "pulumi", "ansible", "ansible-playbook"
    ]

    static let databases: Set<String> = [
        "mysql", "psql", "mongo", "mongosh", "redis-cli", "sqlite3"
    ]

    static let networking: Set<String> = [
        "curl", "wget", "ssh", "scp", "rsync", "nc", "netcat", "nmap", "dig", "nslookup",
        "host", "ping", "traceroute", "ip", "ifconfig", "ss", "netstat"
    ]

    static let systemTools: Set<String> = [
        "htop", "top", "ps", "free", "df", "du", "lsof", "strace", "ltrace",
        "dmesg", "journalctl", "systemctl"
    ]

    static let textAndBuild: Set<String> = [
        "vim", "nvim", "nano", "emacs", "less", "more", "jq", "yq",
        "make", "cmake", "ninja", "gcc", "g++", "clang"
    ]

    static let languages: Set<String> = [
        "python", "python3", "node", "ruby", "go", "java", "javac", "php", "perl", "lua", "R", "rustc"
    ]

    /// All tools to probe for
    static var allTools: Set<String> {
        packageManagers
            .union(versionControl)
            .union(containers)
            .union(cloudCLIs)
            .union(databases)
            .union(networking)
            .union(systemTools)
            .union(textAndBuild)
            .union(languages)
    }
}

// MARK: - Environment Parser

/// Parses environment variables and filters sensitive data
enum EnvironmentParser {
    /// Patterns for sensitive variable names (case-insensitive matching)
    private static let sensitivePatterns: [String] = [
        // API Keys and Tokens
        "API_KEY", "APIKEY", "API_SECRET", "SECRET", "TOKEN", "AUTH",
        "PASSWORD", "PASSWD", "PWD", "CREDENTIAL", "PRIVATE",
        // Cloud Provider
        "AWS_SECRET", "AWS_ACCESS", "AZURE_", "GCP_", "GOOGLE_APPLICATION",
        "DO_TOKEN", "DIGITALOCEAN", "LINODE",
        // Database
        "DB_PASS", "DATABASE_URL", "MONGO_URI", "REDIS_URL", "MYSQL_PWD",
        // Service-specific
        "GITHUB_TOKEN", "GITLAB_TOKEN", "NPM_TOKEN", "DOCKER_PASSWORD",
        "SSH_AUTH", "GPG_", "ENCRYPT", "CERT", "PEM"
    ]

    /// Variables that are safe and useful to include
    private static let allowedVariables: Set<String> = [
        "PATH", "HOME", "USER", "SHELL", "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE",
        "TERM", "COLORTERM", "EDITOR", "VISUAL", "PAGER", "HOSTNAME", "PWD", "OLDPWD",
        "DISPLAY", "XDG_SESSION_TYPE", "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME",
        "HISTSIZE", "HISTFILESIZE", "LINES", "COLUMNS", "LOGNAME", "MAIL", "TZ"
    ]

    /// Result of parsing environment output
    struct ParseResult: Sendable {
        let path: String?
        let filtered: [String: String]
    }

    /// Parse the output of the `env` command
    /// - Parameters:
    ///   - envOutput: Raw output from `env` command
    ///   - filterSensitive: If true, filter out sensitive variables
    /// - Returns: Parsed result with PATH and filtered environment
    static func parse(_ envOutput: String, filterSensitive: Bool = true) -> ParseResult {
        var result: [String: String] = [:]
        var path: String?

        for line in envOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let equalIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalIndex])
            let value = String(line[line.index(after: equalIndex)...])

            // Always extract PATH
            if key == "PATH" {
                path = value
            }

            if filterSensitive {
                // Include if explicitly allowed OR if not matching sensitive patterns
                if allowedVariables.contains(key) {
                    result[key] = value
                } else if !matchesSensitivePattern(key) {
                    result[key] = value
                }
            } else {
                result[key] = value
            }
        }

        return ParseResult(path: path, filtered: result)
    }

    /// Check if a variable name matches any sensitive pattern
    private static func matchesSensitivePattern(_ name: String) -> Bool {
        let upperName = name.uppercased()
        return sensitivePatterns.contains { pattern in
            upperName.contains(pattern)
        }
    }
}

/// Collects system fingerprint from SSH host
@MainActor
final class HostFingerprintCollector {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HostFingerprintCollector")

    /// Cache duration in seconds (2 hours)
    private static let cacheDuration: TimeInterval = 2 * 60 * 60

    private let executor: AIAgentExecutor
    private var cache: [String: (fingerprint: HostFingerprint, expires: Date)] = [:]

    init(executor: AIAgentExecutor) {
        self.executor = executor
    }

    /// Collect fingerprint for the host
    /// - Parameter forceRefresh: If true, ignore cache and collect fresh data
    /// - Returns: The host fingerprint
    func collect(forceRefresh: Bool = false) async throws -> HostFingerprint {
        let cacheKey = "\(executor.sshConfig.host):\(executor.sshConfig.port)"

        // Check cache unless forcing refresh
        if !forceRefresh, let cached = cache[cacheKey], Date() < cached.expires {
            Self.logger.debug("Using cached fingerprint for \(cacheKey)")
            return cached.fingerprint
        }

        Self.logger.info("Collecting fingerprint for \(cacheKey)")

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

        // New: Collect environment and tools in parallel
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

        // Await new results
        let envParsed = await envResult
        let availableTools = await toolsResult

        // Detect language versions for discovered runtimes (sequential, but fast)
        let languageRuntimes = await detectLanguageVersions(available: availableTools)

        let fingerprint = HostFingerprint(
            hostname: hostname.isEmpty ? executor.sshConfig.host : hostname,
            os: os.isEmpty ? "Unknown" : os,
            distro: distro,
            arch: arch.isEmpty ? "Unknown" : arch,
            shell: shell.isEmpty ? "/bin/sh" : shell,
            username: username.isEmpty ? executor.sshConfig.username : username,
            homeDirectory: home.isEmpty ? "/home/\(executor.sshConfig.username)" : home,
            kernelVersion: kernel.isEmpty ? nil : kernel,
            hasSudo: hasSudo,
            currentDirectory: home,
            timestamp: Date(),
            path: envParsed.path,
            environment: envParsed.filtered,
            availableTools: availableTools,
            languageRuntimes: languageRuntimes
        )

        // Cache the result
        let expires = Date().addingTimeInterval(Self.cacheDuration)
        cache[cacheKey] = (fingerprint, expires)

        let toolCount = availableTools.count
        Self.logger.info("Fingerprint collected: \(os) \(arch), shell: \(shell), \(toolCount) tools discovered")

        return fingerprint
    }

    /// Update current directory in fingerprint
    func updateCurrentDirectory(_ directory: String) -> HostFingerprint? {
        let cacheKey = "\(executor.sshConfig.host):\(executor.sshConfig.port)"
        guard var cached = cache[cacheKey] else { return nil }

        var fingerprint = cached.fingerprint
        fingerprint.currentDirectory = directory
        cached.fingerprint = fingerprint
        cache[cacheKey] = cached

        return fingerprint
    }

    /// Clear cached fingerprint
    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private Helpers

    private func runCommand(_ command: String) async throws -> String {
        let result = try await executor.execute(command: command, timeout: 10)
        return result.output
    }

    /// Fingerprinting runs before the executor knows the user's shell.
    private func runPOSIXProbe(_ command: String) async throws -> String {
        let probe = LoginShellCommand.runInPOSIXShell(command)
        let result = try await executor.execute(
            command: LoginShellCommand.runInLoginShell(probe, prependPATH: true),
            timeout: 10,
            prependPATH: false
        )
        return result.output
    }

    private func detectDistro() async throws -> String? {
        // Try various methods to detect the distribution

        // Method 1: Check for /etc/os-release (most Linux distros)
        if let osRelease = try? await runCommand("cat /etc/os-release 2>/dev/null") {
            if let name = parseOSRelease(osRelease, key: "PRETTY_NAME") {
                return name
            }
        }

        // Method 2: Check uname for macOS
        let os = try await runCommand("uname -s")
        if os.trimmingCharacters(in: .whitespacesAndNewlines) == "Darwin" {
            if let version = try? await runCommand("sw_vers -productVersion 2>/dev/null") {
                let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return "macOS \(trimmed)"
                }
            }
        }

        // Method 3: Check for lsb_release
        if let lsb = try? await runCommand("lsb_release -ds 2>/dev/null") {
            let trimmed = lsb.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // Method 4: Check for specific files
        let distroFiles: [(String, String?)] = [
            ("/etc/debian_version", "Debian"),
            ("/etc/redhat-release", nil),
            ("/etc/arch-release", "Arch Linux"),
            ("/etc/alpine-release", "Alpine Linux"),
        ]

        for (file, fallbackName) in distroFiles {
            if let content = try? await runCommand("cat \(file) 2>/dev/null") {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let name = fallbackName {
                        return "\(name) \(trimmed)"
                    }
                    return trimmed
                }
            }
        }

        return nil
    }

    private func parseOSRelease(_ content: String, key: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("\(key)=") {
                var value = String(line.dropFirst(key.count + 1))
                // Remove quotes if present
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return value
            }
        }
        return nil
    }

    private func checkSudo() async throws -> Bool? {
        // Check if user can run sudo without password (NOPASSWD)
        // This is a non-interactive check
        if let result = try? await runCommand("sudo -n true 2>&1 && echo yes || echo no") {
            return result.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
        }
        return nil
    }

    // MARK: - Environment & Tool Discovery

    /// Collect environment variables from the remote host using login shell
    private func collectEnvironment() async -> EnvironmentParser.ParseResult {
        do {
            // Use login shell to get full environment (PATH, aliases, etc.)
            let envOutput = try await runPOSIXProbe("env 2>/dev/null")
            return EnvironmentParser.parse(envOutput, filterSensitive: true)
        } catch {
            Self.logger.warning("Failed to collect environment: \(error.localizedDescription)")
            return EnvironmentParser.ParseResult(path: nil, filtered: [:])
        }
    }

    /// Discover available tools on the remote host using login shell
    private func discoverTools() async -> Set<String> {
        // Use a single efficient command to check multiple tools at once
        let allTools = Array(ToolCategories.allTools)

        // Split into batches to avoid command line length limits
        let batchSize = 30
        var discoveredTools = Set<String>()

        for batch in stride(from: 0, to: allTools.count, by: batchSize) {
            let endIndex = min(batch + batchSize, allTools.count)
            let toolBatch = Array(allTools[batch..<endIndex])

            do {
                // Use 'command -v' which is POSIX-compliant and efficient
                // Run in login shell to find tools in user's full PATH
                let toolList = toolBatch.joined(separator: " ")
                let script = "for cmd in \(toolList); do command -v \"$cmd\" >/dev/null 2>&1 && echo \"$cmd\"; done"
                let result = try await runPOSIXProbe(script)

                let found = result.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                discoveredTools.formUnion(found)
            } catch {
                Self.logger.warning("Tool discovery batch failed: \(error.localizedDescription)")
                // Continue with other batches
            }
        }

        Self.logger.debug("Discovered \(discoveredTools.count) tools")
        return discoveredTools
    }

    /// Detect versions for language runtimes
    private func detectLanguageVersions(available: Set<String>) async -> [String: String] {
        var versions: [String: String] = [:]

        // Only check languages that are actually available
        let languageCommands: [(tool: String, versionCommand: String, parser: (String) -> String?)] = [
            ("python3", "python3 --version 2>&1", { output in
                // "Python 3.11.2" -> "3.11.2"
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "Python ", with: "")
            }),
            ("python", "python --version 2>&1", { output in
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "Python ", with: "")
            }),
            ("node", "node --version 2>&1", { output in
                // "v20.10.0" -> "20.10.0"
                output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "v", with: "")
            }),
            ("ruby", "ruby --version 2>&1", { output in
                // "ruby 3.2.0 (2022-12-25 revision ...) ..." -> "3.2.0"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"ruby (\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "ruby ", with: "")
                }
                return nil
            }),
            ("go", "go version 2>&1", { output in
                // "go version go1.21.5 darwin/arm64" -> "1.21.5"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"go(\d+\.\d+\.?\d*)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "go", with: "")
                }
                return nil
            }),
            ("rustc", "rustc --version 2>&1", { output in
                // "rustc 1.75.0 (82e1608df 2023-12-21)" -> "1.75.0"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"rustc (\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "rustc ", with: "")
                }
                return nil
            }),
            ("java", "java -version 2>&1", { output in
                // Various formats: "openjdk version \"17.0.1\"" or "java version \"1.8.0_292\""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"version \"([^\"]+)\""#, options: .regularExpression) {
                    var version = String(trimmed[match])
                    version = version.replacingOccurrences(of: "version \"", with: "")
                    version = version.replacingOccurrences(of: "\"", with: "")
                    return version
                }
                return nil
            }),
            ("php", "php --version 2>&1", { output in
                // "PHP 8.2.0 (cli) ..." -> "8.2.0"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"PHP (\d+\.\d+\.\d+)"#, options: .regularExpression) {
                    return String(trimmed[match]).replacingOccurrences(of: "PHP ", with: "")
                }
                return nil
            }),
            ("perl", "perl --version 2>&1", { output in
                // "This is perl 5, version 36, subversion 0 (v5.36.0)..." -> "5.36.0"
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = trimmed.range(of: #"\(v(\d+\.\d+\.\d+)\)"#, options: .regularExpression) {
                    var version = String(trimmed[match])
                    version = version.replacingOccurrences(of: "(v", with: "")
                    version = version.replacingOccurrences(of: ")", with: "")
                    return version
                }
                return nil
            })
        ]

        for (tool, command, parser) in languageCommands {
            guard available.contains(tool) else { continue }

            do {
                // Use login shell to ensure tools in user's PATH are found
                let output = try await runPOSIXProbe(command)
                if let version = parser(output), !version.isEmpty {
                    versions[tool] = version
                }
            } catch {
                // Skip this tool if version detection fails
                Self.logger.debug("Failed to get version for \(tool): \(error.localizedDescription)")
            }
        }

        return versions
    }
}

// MARK: - Fingerprint Cache Manager

/// Manages persistent caching of host fingerprints
@MainActor
final class HostFingerprintCache {
    static let shared = HostFingerprintCache()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "HostFingerprintCache")
    private let cacheFile = "host_fingerprints.json"

    private var fingerprints: [String: HostFingerprint] = [:]

    private init() {
        loadFromDisk()
    }

    /// Get cached fingerprint for a host
    func get(host: String, port: Int) -> HostFingerprint? {
        let key = "\(host):\(port)"
        guard let fingerprint = fingerprints[key] else { return nil }

        // Check if cache is still valid (2 hours)
        let maxAge: TimeInterval = 2 * 60 * 60
        if Date().timeIntervalSince(fingerprint.timestamp) > maxAge {
            fingerprints.removeValue(forKey: key)
            saveToDisk()
            return nil
        }

        return fingerprint
    }

    /// Save fingerprint for a host
    func set(_ fingerprint: HostFingerprint, host: String, port: Int) {
        let key = "\(host):\(port)"
        fingerprints[key] = fingerprint
        saveToDisk()
    }

    /// Clear all cached fingerprints
    func clearAll() {
        fingerprints.removeAll()
        saveToDisk()
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        let url = cacheFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            fingerprints = try JSONDecoder().decode([String: HostFingerprint].self, from: data)
            Self.logger.debug("Loaded \(self.fingerprints.count) cached fingerprints")
        } catch {
            Self.logger.error("Failed to load fingerprint cache: \(error.localizedDescription)")
        }
    }

    private func saveToDisk() {
        let url = cacheFileURL()

        do {
            let data = try JSONEncoder().encode(fingerprints)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save fingerprint cache: \(error.localizedDescription)")
        }
    }

    private func cacheFileURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent(cacheFile)
    }
}
#endif
