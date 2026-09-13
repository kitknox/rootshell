// Transport-independent connection metadata for a herdr control-mode gateway.
import Foundation

nonisolated struct HerdrConnectionInfo: Sendable {
    let gatewayID: UUID
    let controllerID: UUID?
    let tabID: String?
    /// herdr's stable terminal id; survives pane moves, unlike the pane id.
    let terminalID: String?
    let openedAt: Date
}

nonisolated struct HerdrConnectionSnapshot: Sendable {
    let server: Server
    let session: Session
    let client: Client
    let tab: Tab?
    let pane: Pane?
    let updatedAt: Date

    struct Server: Sendable {
        let version: String?
        let protocolVersion: Int?
        let bootID: String?
        let pid: Int?
        let socketPath: String?
        let startedAt: Date?
        let controlStreamVersion: Int?
        let liveHandoff: Bool?
    }

    struct Session: Sendable {
        let name: String
        let workspaces: Int
        let tabs: Int
        let panes: Int
        let agents: Int
        let createdAt: Date?
    }

    struct Client: Sendable {
        let connectionID: UInt64?
        let isDegraded: Bool
        let connectedAt: Date?
        let isActive: Bool
        let isReconnecting: Bool
        let reconnectAttempt: Int
        let endpointOverlay: String?
    }

    struct Tab: Sendable {
        let id: String
        let label: String
        let number: Int
        let workspaceLabel: String?
        let workspaceNumber: Int?
        let panes: Int
        let columns: Int?
        let rows: Int?
        let worktreePath: String?
    }

    struct Pane: Sendable {
        let id: String
        let terminalID: String
        let attachID: String?
        let title: String?
        let agent: String?
        let agentStatus: String?
        let workingDirectory: String?
        let width: Int?
        let height: Int?
        let focused: Bool
    }
}

nonisolated enum HerdrConnectionInfoError: Error, LocalizedError {
    case unavailable
    case gatewayEnded

    var errorDescription: String? {
        switch self {
        case .unavailable: return "The herdr control-mode gateway is unavailable or reconnecting."
        case .gatewayEnded: return "herdr control mode has ended for this gateway."
        }
    }
}
