//
//  DirectoryLister.swift
//  rootshell
//
//  Transports for listing directories on the target behind a pane: the local
//  filesystem, an exec channel of a live SSH/tssh/gateway session, or a side
//  SSH connection for mosh (whose UDP transport cannot exec).
//

import Foundation
import os.log

private let listerLogger = Logger(subsystem: "com.rootshell", category: "DirectoryLister")

@MainActor
protocol DirectoryLister: AnyObject {
    var targetKey: String { get }
    /// Known up front locally; learned from the first remote reply otherwise.
    var homeDirectory: String? { get }
    /// Whether one round trip can list several children (remote transports).
    var supportsScanAhead: Bool { get }
    func list(_ target: DirectoryTarget) async throws -> DirectoryListingResult
    func scanAhead(directory: String, children: [String]) async throws -> [String: DirectoryListingResult]
    /// The palette closed; release anything held open for it.
    func end()
}

enum DirectoryListingUnavailableReason: Equatable {
    /// The session exists but its client is still connecting; not cached.
    case notConnectedYet
    case unsupportedTarget
}

enum DirectoryListerResolution {
    case available(any DirectoryLister)
    case unavailable(DirectoryListingUnavailableReason)
}

@MainActor
enum DirectoryListerFactory {
    /// `owner` is the pane holding the connection (see TerminalConnectionOwner).
    static func make(for owner: Ghostty.TerminalView) -> DirectoryListerResolution {
        let targetKey = TerminalConnectionOwner.targetKey(for: owner)
        switch owner.connectionConfig {
        case .local:
            return .available(LocalDirectoryLister(targetKey: targetKey, helperFallback: owner))
        case .kubernetes, .console, .ec2Console, .trzszTransfer, .vnc, .kvm:
            return .unavailable(.unsupportedTarget)
        case .mosh(let config), .shellLaunchedMosh(let config, _):
            return .available(MoshSideConnectionDirectoryLister(targetKey: targetKey, config: config.sshConfig))
        case .ssh, .trzsz, .shellLaunchedSSH, .shellLaunchedTrzsz:
            guard RemoteExecProbe.canProbe(owner) else { return .unavailable(.notConnectedYet) }
            return .available(RemoteExecDirectoryLister(targetKey: targetKey, owner: owner))
        }
    }
}

// MARK: - Local

@MainActor
final class LocalDirectoryLister: DirectoryLister {
    let targetKey: String
    let supportsScanAhead = false
    private(set) var homeDirectory: String?
    private let helperFallback: RemoteExecDirectoryLister?

    init(targetKey: String, helperFallback owner: Ghostty.TerminalView?) {
        self.targetKey = targetKey
        homeDirectory = Self.shellHome
        #if targetEnvironment(macCatalyst)
        // A sandboxed Catalyst build cannot read outside its container; the
        // helper lists on its behalf, exactly as RemoteExecProbe does.
        helperFallback = owner.map { RemoteExecDirectoryLister(targetKey: targetKey, owner: $0) }
        #else
        helperFallback = nil
        #endif
    }

    /// Matches the local shell's HOME: the user home on macOS, Documents on iOS.
    nonisolated static var shellHome: String {
        #if targetEnvironment(macCatalyst)
        return NSHomeDirectory()
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        #endif
    }

    func list(_ target: DirectoryTarget) async throws -> DirectoryListingResult {
        let home = Self.shellHome
        let path: String
        switch target {
        case .absolute(let absolute): path = absolute
        case .home: path = home
        case .homeRelative(let rest): path = PathCompletion.join(home, rest)
        case .userHome(let user, let rest):
            #if targetEnvironment(macCatalyst)
            guard let userHome = NSHomeDirectoryForUser(user) else {
                return DirectoryListingResult(home: home, error: .notFound, complete: true)
            }
            path = rest.isEmpty ? userHome : PathCompletion.join(userHome, rest)
            #else
            return DirectoryListingResult(home: home, error: .unsupportedPath, complete: true)
            #endif
        }
        #if targetEnvironment(macCatalyst)
        let scoped: URL? = nil
        #else
        // Bookmarked folders are reachable only through their security-scoped URL.
        let scoped = BookmarkedLocationsManager.shared.accessibleURL(for: path)
        #endif
        var result = await Task.detached(priority: .userInitiated) {
            Self.listLocal(path: path, home: home, scoped: scoped)
        }.value
        if result.error == .permissionDenied, let helperFallback {
            result = try await helperFallback.list(.absolute(path))
        }
        return result
    }

    func scanAhead(directory: String, children: [String]) async throws -> [String: DirectoryListingResult] { [:] }

    func end() {}

    nonisolated private static func listLocal(path: String, home: String, scoped: URL?) -> DirectoryListingResult {
        var result = DirectoryListingResult(home: home, complete: true)
        let fileManager = FileManager.default
        var listingPath = path
        if let scoped {
            listingPath = scoped.path
            _ = scoped.startAccessingSecurityScopedResource()
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: listingPath, isDirectory: &isDirectory) else {
            result.error = .notFound
            return result
        }
        guard isDirectory.boolValue else {
            result.error = .notDirectory
            return result
        }
        guard fileManager.isReadableFile(atPath: listingPath) else {
            result.error = .permissionDenied
            return result
        }
        do {
            let names = try fileManager.contentsOfDirectory(atPath: listingPath)
            result.resolvedPath = PathCompletion.normalize(path)
            for name in names {
                var childIsDirectory: ObjCBool = false
                let child = (listingPath as NSString).appendingPathComponent(name)
                // fileExists follows symlinks, so a link to a folder counts.
                let exists = fileManager.fileExists(atPath: child, isDirectory: &childIsDirectory)
                result.entries.append(DirectoryEntry(name: name, isDirectory: exists && childIsDirectory.boolValue))
            }
            if result.entries.count > DirectoryListingProbe.defaultMaxEntries {
                result.entries.removeLast(result.entries.count - DirectoryListingProbe.defaultMaxEntries)
                result.truncated = true
            }
        } catch {
            result.error = (error as NSError).code == NSFileReadNoPermissionError ? .permissionDenied : .notFound
        }
        return result
    }
}

// MARK: - Exec channel of a live session

/// SSH (separate exec channel of the pane's client), tssh (probe slot on the
/// Go transport), tmux/herdr gateways, and the Catalyst helper for local panes.
@MainActor
final class RemoteExecDirectoryLister: DirectoryLister {
    static let timeout: TimeInterval = 8

    let targetKey: String
    let supportsScanAhead = true
    private(set) var homeDirectory: String?
    private weak var owner: Ghostty.TerminalView?

    init(targetKey: String, owner: Ghostty.TerminalView) {
        self.targetKey = targetKey
        self.owner = owner
    }

    func list(_ target: DirectoryTarget) async throws -> DirectoryListingResult {
        guard let owner else { throw RemoteExecProbe.ProbeError.notConnected }
        let (command, nonce) = DirectoryListingProbe.command(target: target)
        let output = try await RemoteExecProbe.run(
            command, on: owner, timeout: Self.timeout, maxResponseBytes: DirectoryListingProbe.maxResponseBytes
        )
        let result = DirectoryListingProbe.parse(output: output, nonce: nonce)
        if let home = result.home { homeDirectory = home }
        return result
    }

    func scanAhead(directory: String, children: [String]) async throws -> [String: DirectoryListingResult] {
        guard let owner else { throw RemoteExecProbe.ProbeError.notConnected }
        let (command, nonce) = DirectoryListingProbe.scanAheadCommand(directory: directory, children: children)
        let output = try await RemoteExecProbe.run(
            command, on: owner, timeout: Self.timeout, maxResponseBytes: DirectoryListingProbe.maxResponseBytes
        )
        return DirectoryListingProbe.parseScanAhead(output: output, nonce: nonce, directory: directory)
    }

    func end() {}
}

// MARK: - Mosh side connection

/// Mosh closes its bootstrap SSH client once mosh-server is up, so browsing
/// borrows one headless SSH connection for the palette's lifetime. A failed
/// connection is remembered: the palette degrades to typed paths rather than
/// prompting or retrying on every keystroke.
@MainActor
final class MoshSideConnectionDirectoryLister: DirectoryLister {
    static let timeout: TimeInterval = 8

    let targetKey: String
    let supportsScanAhead = true
    private(set) var homeDirectory: String?
    private let config: SSHConfig
    private var connection: HeadlessSSHExecutor.LiveConnection?
    private var connectTask: Task<HeadlessSSHExecutor.LiveConnection, Error>?
    private var ended = false

    init(targetKey: String, config: SSHConfig) {
        self.targetKey = targetKey
        self.config = config
    }

    func list(_ target: DirectoryTarget) async throws -> DirectoryListingResult {
        let (command, nonce) = DirectoryListingProbe.command(target: target)
        let output = try await run(command)
        let result = DirectoryListingProbe.parse(output: output, nonce: nonce)
        if let home = result.home { homeDirectory = home }
        return result
    }

    func scanAhead(directory: String, children: [String]) async throws -> [String: DirectoryListingResult] {
        let (command, nonce) = DirectoryListingProbe.scanAheadCommand(directory: directory, children: children)
        let output = try await run(command)
        return DirectoryListingProbe.parseScanAhead(output: output, nonce: nonce, directory: directory)
    }

    func end() {
        ended = true
        connectTask?.cancel()
        let connection = connection
        self.connection = nil
        Task { await connection?.close() }
    }

    private func run(_ command: String) async throws -> String {
        let connection = try await openIfNeeded()
        let output = try await connection.execute(
            command: command, timeout: Self.timeout, maxOutputBytes: DirectoryListingProbe.maxResponseBytes
        )
        return output.stdout
    }

    private func openIfNeeded() async throws -> HeadlessSSHExecutor.LiveConnection {
        if let connection { return connection }
        guard !ended else { throw HeadlessSSHExecutor.ExecError.connectionFailed("closed") }
        // One attempt per palette session; a second caller awaits the first.
        let task = connectTask ?? Task { [config] in
            let resolved = try await config.resolvedConfig()
            return try await HeadlessSSHExecutor.open(config: resolved, logLabel: "Open in Folder")
        }
        connectTask = task
        do {
            let opened = try await task.value
            if ended {
                await opened.close()
                throw HeadlessSSHExecutor.ExecError.connectionFailed("closed")
            }
            connection = opened
            return opened
        } catch {
            listerLogger.error("mosh side connection failed: \(error.localizedDescription)")
            throw error
        }
    }
}
