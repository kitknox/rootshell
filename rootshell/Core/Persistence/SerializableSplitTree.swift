//
//  SerializableSplitTree.swift
//  rootshell
//
//  Codable representation of a split tree for state persistence.
//  Captures tree structure and connection configs without UIView references.
//

import Foundation

/// Codable representation of a split tree for state persistence
nonisolated struct SerializableSplitTree: Codable, Equatable, Sendable {
    let root: SerializableNode?
    let zoomedPath: [PathComponent]?  // Path to zoomed node (if any)

    nonisolated enum PathComponent: String, Codable, Sendable {
        case left
        case right
    }

    nonisolated indirect enum SerializableNode: Codable, Equatable, Sendable {
        case leaf(LeafData)
        case split(SplitData)

        // Nonisolated via the enclosing types; spelling it here again applies
        // the attribute to the wrapped `var` below, which is not allowed.
        struct LeafData: Codable, Equatable, Sendable {
            /// Original terminal UUID (for matching focused terminal)
            let terminalId: UUID

            /// Connection configuration for this terminal
            let connectionConfig: SerializableConnectionConfig

            /// User-overridden title (if any)
            let userOverrideTitle: String?

            /// Last known working directory (for local shells)
            let lastKnownWorkingDirectory: String?

            /// Profile that created this terminal (if any)
            let sourceProfileID: UUID?

            /// Absolute per-surface font size override set by keyboard or
            /// pinch zoom. Nil means this terminal follows the global font.
            let fontSizeOverride: Double?

            /// For trzsz attachable sessions: the most recent moment the
            /// client was confirmed connected to the server. Used on resume
            /// to decide whether the server is still within its 24h
            /// `AliveTimeout` window. `nil` for non-trzsz terminals or
            /// sessions that have never connected.
            let trzszLastConnectedAt: Date?

            /// True when this terminal was running a live `tmux -CC` control-mode
            /// gateway at save time (its `tmuxController` was non-nil). On
            /// restore, once this terminal's tssh session resumes the live pty,
            /// the app calls `ghostty_surface_tmux_resume` to re-enter control
            /// mode and reproject the tmux window tabs. Optional so older saved
            /// state (without the key) decodes as `nil` (= not a gateway).
            let wasTmuxGateway: Bool?

            /// True when the user cancelled restored tmux recovery before the
            /// resumed pty was ready to accept `tmux_resume_abort`. On restore,
            /// the gateway still enters tmux-resume handling, then aborts
            /// immediately so raw control-mode output is not exposed.
            let tmuxResumeCancelRequested: Bool?

            @LossyLocalMultiplexerAttachment var localMultiplexerAttachment: LocalMultiplexerAttachment? = nil
        }

        nonisolated struct SplitData: Codable, Equatable, Sendable {
            let direction: Direction
            let ratio: Double
            let left: SerializableNode
            let right: SerializableNode
        }

        nonisolated enum Direction: String, Codable, Sendable {
            case horizontal
            case vertical
        }
    }

    /// Create an empty tree
    init() {
        self.root = nil
        self.zoomedPath = nil
    }

    /// Create from root and zoomed path
    init(root: SerializableNode?, zoomedPath: [PathComponent]?) {
        self.root = root
        self.zoomedPath = zoomedPath
    }

    /// Whether the tree is empty
    var isEmpty: Bool {
        root == nil
    }

    /// Get all terminal IDs in the tree (in order)
    var allTerminalIds: [UUID] {
        guard let root = root else { return [] }
        return root.allTerminalIds
    }

    /// Get all leaf data in the tree (in order)
    var allLeaves: [SerializableNode.LeafData] {
        guard let root = root else { return [] }
        return root.allLeaves
    }
}

// MARK: - Node Operations

nonisolated extension SerializableSplitTree.SerializableNode {
    /// Get all terminal IDs in this subtree
    var allTerminalIds: [UUID] {
        switch self {
        case .leaf(let data):
            return [data.terminalId]
        case .split(let data):
            return data.left.allTerminalIds + data.right.allTerminalIds
        }
    }

    /// Get all leaf data in this subtree
    var allLeaves: [SerializableSplitTree.SerializableNode.LeafData] {
        switch self {
        case .leaf(let data):
            return [data]
        case .split(let data):
            return data.left.allLeaves + data.right.allLeaves
        }
    }
}

// MARK: - SplitTree Extension for Serialization

extension SplitTree where ViewType == SplitPaneView {

    /// Serialize this split tree to a Codable representation
    @MainActor
    func serialize() -> SerializableSplitTree {
        guard let root = self.root, let serializedRoot = serializeNode(root) else {
            return SerializableSplitTree()
        }

        // Serialize zoomed path if present
        var zoomedPath: [SerializableSplitTree.PathComponent]? = nil
        if let zoomed = self.zoomed {
            zoomedPath = pathToNode(zoomed)
        }

        return SerializableSplitTree(root: serializedRoot, zoomedPath: zoomedPath)
    }

    /// Serialize a single node. Returns nil for leaves that cannot be
    /// serialized; a split with one serializable child collapses to that
    /// child.
    @MainActor
    private func serializeNode(_ node: Node) -> SerializableSplitTree.SerializableNode? {
        switch node {
        case .leaf(let pane):
            // Screen Sharing pane: the connection config carries everything
            // needed to reconnect (password is a runtime Keychain lookup);
            // terminal-only fields stay nil.
            if let vncPane = pane as? VNCPaneView {
                return .leaf(SerializableSplitTree.SerializableNode.LeafData(
                    terminalId: vncPane.uuid,
                    connectionConfig: SerializableConnectionConfig(from: .vnc(vncPane.config)),
                    userOverrideTitle: vncPane.userOverrideTitle,
                    lastKnownWorkingDirectory: nil,
                    sourceProfileID: vncPane.sourceProfileID,
                    fontSizeOverride: nil,
                    trzszLastConnectedAt: nil,
                    wasTmuxGateway: nil,
                    tmuxResumeCancelRequested: nil
                ))
            }

            // Genuinely unknown pane kinds are skipped (never crash) so the
            // rest of the tab still persists.
            guard let view = pane.asTerminal else { return nil }

            // connectionConfig is kept up to date at runtime (including shell-launched
            // SSH/Mosh/Trzsz transitions), so we can serialize it directly.
            let configToSerialize = view.connectionConfig
            let cwd: String? = if case .local = view.connectionConfig { view.pwd } else { nil }

            // For trzsz attachable sessions, capture the in-memory "last
            // alive" timestamp so the next resume knows whether the
            // server's 24h AliveTimeout window has elapsed. Covers both
            // direct trzsz tabs (`session is TrzszSession`) and the
            // shell-launched / "roam" path (a TrzszSession embedded in a
            // LocalShellSession). Falls through to the previously-restored
            // value when no session is active yet (e.g. autosave runs
            // before reconnection completes).
            let trzszLastConnectedAt: Date? = {
                if let direct = view.session as? TrzszSession {
                    return direct.lastConnectedAt ?? view.restoredTrzszLastConnectedAt
                }
                #if !targetEnvironment(macCatalyst)
                if let embedded = (view.session as? LocalShellSession)?.embeddedTrzszSession {
                    return embedded.lastConnectedAt ?? view.restoredTrzszLastConnectedAt
                }
                #endif
                return view.restoredTrzszLastConnectedAt
            }()

            let leafData = SerializableSplitTree.SerializableNode.LeafData(
                terminalId: view.uuid,
                connectionConfig: SerializableConnectionConfig(from: configToSerialize),
                userOverrideTitle: view.userOverrideTitle,
                lastKnownWorkingDirectory: cwd,
                sourceProfileID: view.sourceProfileID,
                fontSizeOverride: view.fontSizeOverride,
                trzszLastConnectedAt: trzszLastConnectedAt,
                // This flag remains specific to tssh's surviving control stream.
                // Local clients use a fresh attach described separately below.
                wasTmuxGateway: (
                    view.tmuxController != nil
                    || view.restoredWasTmuxGateway
                    || view.tmuxResumeRequested
                    || view.tmuxResumeCancelRequested
                ) && view.connectionConfig.isTrzsz,
                tmuxResumeCancelRequested: view.tmuxResumeCancelRequested ? true : nil,
                localMultiplexerAttachment: view.localMultiplexerAttachmentForPersistence
            )
            return .leaf(leafData)

        case .split(let split):
            let direction: SerializableSplitTree.SerializableNode.Direction =
                split.direction == .horizontal ? .horizontal : .vertical

            let left = serializeNode(split.left)
            let right = serializeNode(split.right)
            switch (left, right) {
            case let (left?, right?):
                return .split(SerializableSplitTree.SerializableNode.SplitData(
                    direction: direction,
                    ratio: split.ratio,
                    left: left,
                    right: right
                ))
            case let (left?, nil):
                return left
            case let (nil, right?):
                return right
            case (nil, nil):
                return nil
            }
        }
    }

    /// Find the path to a specific node
    func pathToNode(_ target: Node) -> [SerializableSplitTree.PathComponent]? {
        guard let root = self.root else { return nil }
        return findPath(from: root, to: target)
    }

    private func findPath(from current: Node, to target: Node) -> [SerializableSplitTree.PathComponent]? {
        if current == target {
            return []
        }

        switch current {
        case .leaf:
            return nil

        case .split(let split):
            // Try left
            if let leftPath = findPath(from: split.left, to: target) {
                return [.left] + leftPath
            }
            // Try right
            if let rightPath = findPath(from: split.right, to: target) {
                return [.right] + rightPath
            }
            return nil
        }
    }
}
