//
//  FileConnectionPool.swift
//  rootshell
//
//  App-wide remote connections (SFTP sessions and storage clients) keyed by
//  endpoint, shared by every file manager pane and transfer job so each host
//  is authenticated once. A connection closes after an idle delay once
//  nothing retains it.
//

import Foundation

/// A live remote filesystem the pool can share and close.
nonisolated protocol FileConnection: AnyObject, Sendable {
    var isActive: Bool { get }
    /// Who the connection signed in as, for binding edits to the account that serves them.
    var principal: EditPrincipal { get }
    /// For listings and small metadata calls.
    var browseFileSystem: FileSystemEndpoint { get }
    /// For bulk transfers; may be the browse filesystem.
    func transferFileSystem() async -> FileSystemEndpoint
    func close() async
}

@MainActor
final class FileConnectionPool {
    static let shared = FileConnectionPool()

    enum Purpose {
        case browse
        case transfer
    }

    private var connections: [FileEndpoint: any FileConnection] = [:]
    private var pending: [FileEndpoint: Task<any FileConnection, Error>] = [:]
    private var retainCounts: [FileEndpoint: Int] = [:]
    private var idleClosers: [FileEndpoint: Task<Void, Never>] = [:]

    private init() {}

    /// A filesystem for `endpoint`, connecting (and prompting) if needed.
    func fileSystem(for endpoint: FileEndpoint, purpose: Purpose, prompts: FileManagerPrompts) async throws -> FileSystemEndpoint {
        try await fileSystemAndPrincipal(for: endpoint, purpose: purpose, prompts: prompts).fs
    }

    /// `fileSystem(for:)` plus who the serving connection signed in as. Edits bind to this,
    /// not to `endpoint`, which a pane fallback or a cached connection can serve differently.
    func fileSystemAndPrincipal(
        for endpoint: FileEndpoint,
        purpose: Purpose,
        prompts: FileManagerPrompts
    ) async throws -> (fs: FileSystemEndpoint, principal: EditPrincipal) {
        if endpoint.isLocal {
            return (FileSystemEndpoint(backend: .local(.current())), EditPrincipal.local)
        }
        let connection = try await connection(for: endpoint, prompts: prompts)
        switch purpose {
        case .browse: return (connection.browseFileSystem, connection.principal)
        case .transfer: return (await connection.transferFileSystem(), connection.principal)
        }
    }

    /// The live connection's principal, else the one a connection opened now should have.
    func expectedPrincipal(for endpoint: FileEndpoint) -> EditPrincipal {
        if !endpoint.isLocal, let live = connections[endpoint], live.isActive { return live.principal }
        // Sudo layers on the base connection, which may predate an edit to its profile.
        if case .sudo(let base) = endpoint, let live = connections[base] as? SFTPConnection, live.isActive {
            return EditPrincipal(login: live.login, isSudo: true)
        }
        return endpoint.predictedPrincipal
    }

    private func connection(for endpoint: FileEndpoint, prompts: FileManagerPrompts) async throws -> any FileConnection {
        if let existing = connections[endpoint] {
            if existing.isActive { return existing }
            connections[endpoint] = nil
            Task { await existing.close() }
        }
        if let task = pending[endpoint] {
            return try await task.value
        }
        let task = Task<any FileConnection, Error> {
            let connection: any FileConnection
            if case .sudo(let base) = endpoint {
                connection = try await self.openSudo(on: base, prompts: prompts)
            } else {
                connection = try await Self.open(endpoint, prompts: prompts)
            }
            // Reconcile any interrupted SFTP swap on this endpoint inside the shared connection
            // task before publishing the connection so concurrent callers never list mid-recovery.
            await RemoteFileEditCenter.recoverPendingSwaps(
                endpointKey: connection.principal.key,
                displayName: endpoint.displayName,
                on: connection.browseFileSystem
            )
            if Task.isCancelled {
                await connection.close()
                throw CancellationError()
            }
            return connection
        }
        pending[endpoint] = task
        defer {
            if pending[endpoint] == task {
                pending[endpoint] = nil
            }
        }
        let connection = try await task.value
        guard pending[endpoint] == task else {
            await connection.close()
            throw CancellationError()
        }
        connections[endpoint] = connection
        scheduleIdleCloseIfUnused(endpoint)
        return connection
    }

    private static func open(_ endpoint: FileEndpoint, prompts: FileManagerPrompts) async throws -> any FileConnection {
        if case .storage(let id) = endpoint {
            guard let provider = StorageProviderStore.shared.provider(for: id) else {
                throw FileManagerConnectionError.storageProviderUnavailable
            }
            return try S3Connection(provider: provider)
        }
        return try await SFTPConnectionFactory.open(endpoint, prompts: prompts)
    }

    /// Sudo runs on the base connection's transport and keeps it retained.
    private func openSudo(on base: FileEndpoint, prompts: FileManagerPrompts) async throws -> any FileConnection {
        guard let connection = try await connection(for: base, prompts: prompts) as? SFTPConnection else {
            throw FileManagerConnectionError.sudoUnavailable
        }
        retain(base)
        do {
            return try await SudoSFTP.open(
                base: connection,
                host: base.sshConfig?.host ?? base.displayName,
                label: FileEndpoint.sudo(base).displayName,
                prompts: prompts,
                release: { await MainActor.run { FileConnectionPool.shared.release(base) } }
            )
        } catch {
            release(base)
            throw error
        }
    }

    /// Whether a live connection exists, without opening one.
    func isConnected(_ endpoint: FileEndpoint) -> Bool {
        endpoint.isLocal || connections[endpoint]?.isActive == true
    }

    func retain(_ endpoint: FileEndpoint) {
        guard !endpoint.isLocal else { return }
        retainCounts[endpoint, default: 0] += 1
        idleClosers.removeValue(forKey: endpoint)?.cancel()
    }

    func release(_ endpoint: FileEndpoint) {
        guard !endpoint.isLocal, let count = retainCounts[endpoint] else { return }
        if count <= 1 {
            retainCounts[endpoint] = nil
            scheduleIdleCloseIfUnused(endpoint)
        } else {
            retainCounts[endpoint] = count - 1
        }
    }

    /// Drops the connection now, e.g. after the user disconnects or edits its
    /// settings. Its sudo connection goes with it.
    func disconnect(_ endpoint: FileEndpoint) {
        if !endpoint.isSudo { disconnect(.sudo(endpoint)) }
        pending.removeValue(forKey: endpoint)?.cancel()
        idleClosers.removeValue(forKey: endpoint)?.cancel()
        if let connection = connections.removeValue(forKey: endpoint) {
            Task { await connection.close() }
        }
    }

    /// Disconnects now when no pane in any window retains `endpoint`;
    /// otherwise the idle closer handles it once the last pane lets go.
    func disconnectIfUnretained(_ endpoint: FileEndpoint) {
        guard retainCounts[endpoint] == nil else { return }
        disconnect(endpoint)
    }

    private func scheduleIdleCloseIfUnused(_ endpoint: FileEndpoint) {
        guard retainCounts[endpoint] == nil, connections[endpoint] != nil else { return }
        idleClosers[endpoint]?.cancel()
        let delay = SettingsStore.shared.value(Settings.Transfer.fileManagerIdleDisconnectMinutes)
        idleClosers[endpoint] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, delay) * 60))
            guard !Task.isCancelled, let self, self.retainCounts[endpoint] == nil else { return }
            self.idleClosers[endpoint] = nil
            self.disconnect(endpoint)
        }
    }
}
