//
//  SFTPConnection.swift
//  rootshell
//
//  A live SFTP session plus whatever owns it (an SSH client pair, a tssh
//  transport, or nothing when a terminal pane lends its connection).
//

import Foundation
@preconcurrency import Citadel
import os.log

actor SFTPConnection: FileConnection {
    private static let logger = Logger(subsystem: "com.rootshell", category: "FileManagerConnection")

    /// Channel for listings and small metadata calls.
    nonisolated let browseClient: SFTPClient
    nonisolated let label: String
    /// The account this connection actually signed in as, whatever endpoint asked for it.
    nonisolated let login: FileEditRecoveryKey.Login
    nonisolated let isSudo: Bool
    /// Runs a command on the same connection, stderr split out; nil when
    /// the connection can't run commands.
    nonisolated let openExec: (@Sendable (String) async throws -> RemoteExecChannel)?

    private let openChannel: @Sendable () async throws -> SFTPClient
    private let teardown: @Sendable () async -> Void
    private var transferClient: SFTPClient?
    private var isClosed = false

    init(
        browseClient: SFTPClient,
        label: String,
        login: FileEditRecoveryKey.Login,
        isSudo: Bool = false,
        openChannel: @escaping @Sendable () async throws -> SFTPClient,
        openExec: (@Sendable (String) async throws -> RemoteExecChannel)? = nil,
        teardown: @escaping @Sendable () async -> Void
    ) {
        self.browseClient = browseClient
        self.label = label
        self.login = login
        self.isSudo = isSudo
        self.openExec = openExec
        self.openChannel = openChannel
        self.teardown = teardown
    }

    nonisolated var isActive: Bool { browseClient.isActive }

    nonisolated var principal: EditPrincipal { EditPrincipal(login: login, isSudo: isSudo) }

    nonisolated var browseFileSystem: FileSystemEndpoint {
        FileSystemEndpoint(backend: .sftp(browseClient))
    }

    /// A second channel so bulk transfers never queue behind listings.
    /// Falls back to the browse channel when the server refuses another.
    func transferFileSystem() async -> FileSystemEndpoint {
        if let transferClient, transferClient.isActive {
            return FileSystemEndpoint(backend: .sftp(transferClient))
        }
        guard !isClosed else { return browseFileSystem }
        do {
            let client = try await openChannel()
            transferClient = client
            return FileSystemEndpoint(backend: .sftp(client))
        } catch {
            Self.logger.info("Transfer channel unavailable for \(self.label, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return browseFileSystem
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        let clients = [transferClient, browseClient].compactMap { $0 }
        transferClient = nil
        for client in clients {
            try? await withTimeout(seconds: 2) { try await client.close() }
        }
        await teardown()
    }
}
