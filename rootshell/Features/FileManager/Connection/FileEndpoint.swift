//
//  FileEndpoint.swift
//  rootshell
//
//  Where a file manager pane points: this device, a saved SSH profile, the
//  connection a terminal pane already holds, or a cloud storage provider.
//  Any SSH endpoint can be wrapped in `.sudo` to browse it as root.
//

import UIKit

enum FileEndpoint: Hashable {
    case local
    case profile(UUID)
    case pane(PaneSource)
    case storage(UUID)
    /// `base` reached through sftp-server run under sudo.
    indirect case sudo(FileEndpoint)

    /// A terminal pane whose live connection can be borrowed. When the pane is
    /// gone, `fallbackProfileID` or `fallbackConfig` opens a dedicated connection.
    final class PaneSource: Hashable {
        let paneID: UUID
        let displayName: String
        weak var terminal: Ghostty.TerminalView?
        let fallbackProfileID: UUID?
        let fallbackConfig: ConnectionConfig
        /// Snapshot for "Open in Terminal", taken when the manager was opened from this pane.
        let openInFolderTarget: OpenInFolderTarget?

        init(terminal: Ghostty.TerminalView, openInFolderTarget: OpenInFolderTarget?) {
            let owner = TerminalConnectionOwner.resolve(for: terminal) ?? terminal
            paneID = owner.uuid
            displayName = owner.connectionConfig.displayName
            self.terminal = owner
            fallbackProfileID = owner.sourceProfileID
            fallbackConfig = owner.connectionConfig
            self.openInFolderTarget = openInFolderTarget
        }

        static func == (lhs: PaneSource, rhs: PaneSource) -> Bool { lhs.paneID == rhs.paneID }
        func hash(into hasher: inout Hasher) { hasher.combine(paneID) }
    }

    var isLocal: Bool {
        switch self {
        case .local: true
        case .sudo(let base): base.isLocal
        case .pane(let source): source.fallbackConfig.underlyingSSHConfig == nil
        case .profile, .storage: false
        }
    }

    /// The server config behind an SSH endpoint.
    var sshConfig: SSHConfig? {
        switch self {
        case .local, .storage: nil
        case .profile(let id): ConnectionProfileManager.shared.profile(for: id)?.sshConfig
        case .pane(let source): source.fallbackConfig.underlyingSSHConfig
        case .sudo(let base): base.sshConfig
        }
    }

    var isSudo: Bool {
        if case .sudo = self { return true }
        return false
    }

    /// Only SSH endpoints can run sftp-server under sudo.
    var canUseSudo: Bool { !isSudo && !isLocal && sshConfig != nil }

    /// This endpoint as the login user.
    var withoutSudo: FileEndpoint {
        if case .sudo(let base) = self { return base.withoutSudo }
        return self
    }

    var storageProvider: StorageProvider? {
        guard case .storage(let id) = self else { return nil }
        return StorageProviderStore.shared.provider(for: id)
    }

    /// Only shell-reachable endpoints can open a terminal in a folder.
    var supportsTerminal: Bool {
        if case .storage = self { return false }
        return true
    }

    /// True when both endpoints reach the same files: this device, the same
    /// server account through any route (a borrowed pane and its profile, say),
    /// or the same bucket namespace. Proven, so rename shortcuts and same-path
    /// skips may rely on it; overwrite guards use `mayShareFiles`. Never `==`.
    /// Sudo runs inside its base session, so it has the base's path namespace.
    func sharesFileSystem(with other: FileEndpoint) -> Bool {
        if self == other { return true }
        if isSudo || other.isSudo { return withoutSudo.sharesFileSystem(with: other.withoutSudo) }
        if isLocal || other.isLocal { return isLocal && other.isLocal }
        if let provider = storageProvider, let otherProvider = other.storageProvider {
            return provider.reachesSameNamespace(as: otherProvider)
        }
        guard let config = sshConfig, let otherConfig = other.sshConfig else { return false }
        return config.reachesSameAccount(as: otherConfig)
    }

    /// True when the two might reach the same files, even at different paths
    /// (root beside another account on its server, which may be chrooted, or two
    /// different-credential profiles on the same multi-tenant S3 gateway).
    /// Guards against overwriting or deleting a source must use this.
    func mayShareFiles(with other: FileEndpoint) -> Bool {
        if sharesFileSystem(with: other) { return true }
        if let provider = storageProvider, let otherProvider = other.storageProvider {
            return provider.mayShareNamespace(with: otherProvider)
        }
        guard isSudo || other.isSudo, let config = sshConfig, let otherConfig = other.sshConfig else { return false }
        return config.reachesSameServer(as: otherConfig)
    }

    var displayName: String {
        switch self {
        case .local:
            return Self.localDeviceName
        case .profile(let id):
            return ConnectionProfileManager.shared.profile(for: id)?.name
                ?? String(localized: "Missing Profile", comment: "File manager: endpoint whose profile was deleted")
        case .pane(let source):
            return source.displayName
        case .storage:
            return storageProvider?.displayName
                ?? String(localized: "Missing Storage Provider", comment: "File manager: endpoint whose storage provider was deleted")
        case .sudo(let base):
            return String(localized: "\(base.displayName) (sudo)", comment: "File manager: endpoint browsed as root; the argument is the server name")
        }
    }

    static let storageSymbol = "externaldrive.connected.to.line.below"

    /// Shown in place of `symbol` when it loads.
    var faviconDomain: String? {
        storageProvider?.faviconDomain
    }

    var symbol: String {
        switch self {
        case .storage:
            return Self.storageSymbol
        case .sudo:
            return "lock.shield"
        case .local, .pane, .profile:
            guard isLocal else { return "server.rack" }
            #if targetEnvironment(macCatalyst)
            return "laptopcomputer"
            #else
            return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            #endif
        }
    }

    private static var localDeviceName: String {
        #if targetEnvironment(macCatalyst)
        return String(localized: "This Mac", comment: "File manager: local endpoint name")
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
            ? String(localized: "This iPad", comment: "File manager: local endpoint name")
            : String(localized: "This iPhone", comment: "File manager: local endpoint name")
        #endif
    }

    /// The profile this endpoint connects through, if any.
    var profileID: UUID? {
        switch self {
        case .local, .storage: nil
        case .profile(let id): id
        case .pane(let source): source.fallbackProfileID
        case .sudo(let base): base.profileID
        }
    }

    /// Persistable form: panes are remembered by the profile they came from,
    /// sudo panes as their base so a relaunch never reopens as root.
    var persistentKey: String? {
        switch self {
        case .sudo(let base): base.persistentKey
        case .local: "local"
        case .profile(let id): "profile:\(id.uuidString)"
        case .pane(let source): source.fallbackProfileID.map { "profile:\($0.uuidString)" }
        case .storage(let id): "storage:\(id.uuidString)"
        }
    }

    init?(persistentKey: String) {
        if persistentKey == "local" {
            self = .local
        } else if persistentKey.hasPrefix("profile:"),
                  let id = UUID(uuidString: String(persistentKey.dropFirst("profile:".count))),
                  ConnectionProfileManager.shared.profile(for: id) != nil {
            self = .profile(id)
        } else if persistentKey.hasPrefix("storage:"),
                  let id = UUID(uuidString: String(persistentKey.dropFirst("storage:".count))),
                  StorageProviderStore.shared.provider(for: id) != nil {
            self = .storage(id)
        } else {
            return nil
        }
    }
}
