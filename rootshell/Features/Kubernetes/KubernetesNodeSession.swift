//
//  KubernetesNodeSession.swift
//  rootshell
//
//  TerminalSession implementation for Kubernetes node shell access
//

import Foundation
import os
import os.log
import SwiftkubeClient
import SwiftkubeModel
import Combine

/// Terminal session that provides shell access to a Kubernetes node via debug pod
@MainActor
final class KubernetesNodeSession: TerminalSession {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KubernetesNodeSession")

    // MARK: - Properties

    let pty: TerminalPTY
    let config: KubernetesNodeShellConfig

    private(set) var isRunning: Bool = false

    /// Current session state
    @Published private(set) var state: KubernetesNodeShellState = .initial

    private var k8sClient: KubernetesClient?
    private var execClient: KubernetesExecClient?
    private var authConfig: KubernetesAuthConfig?
    private var podCreated: Bool = false
    private var outputBatcher: OutputBatcher?

    /// Buffer for output that arrives while the app is backgrounded. The
    /// WebSocket exec channel keeps producing data, but we don't forward it
    /// upstream (which would queue main-actor work and trip the resume
    /// watchdog). Bounded so a chatty debug shell doesn't grow until jetsam;
    /// oldest bytes are dropped when the cap is hit. Drained by
    /// `resumeForForeground()`.
    private nonisolated let backgroundedBuffer = BoundedDataBuffer()

    /// Captured callbacks used by `forwardOutput()`. Captured at `start()`
    /// time when the upstream has finished installing them.
    private nonisolated let outputForwarderBox = OSAllocatedUnfairLock<OutputForwarder?>(initialState: nil)

    fileprivate nonisolated struct OutputForwarder: @unchecked Sendable {
        let onOutputData: (@Sendable (Data) -> Void)?
        let onOutput: (@Sendable (String) -> Void)?
        func send(_ data: Data) {
            if let onOutputData {
                onOutputData(data)
            } else if let onOutput {
                onOutput(String(decoding: data, as: UTF8.self))
            }
        }
    }

    // MARK: - TerminalSession Callbacks
    // NOTE: These callbacks may be called from a background thread.
    // Callers must ensure thread-safe handling.

    var onOutput: (@Sendable (String) -> Void)?
    var onOutputData: (@Sendable (Data) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onSessionEnd: (() -> Void)?
    var onReady: (() -> Void)?
    var onError: ((Error) -> Void)?

    /// Callback for unexpected disconnection (for reconnection support)
    var onDisconnect: ((ReconnectionManager.DisconnectReason) -> Void)?

    /// Whether this session supports auto-reconnect
    var supportsAutoReconnect: Bool { true }

    // Connection metadata
    private(set) var connectionStartTime: Date?

    var connectionInfo: ConnectionInfo? {
        guard let startTime = connectionStartTime else { return nil }
        return .kubernetes(
            cluster: config.displayName,
            node: config.nodeName,
            connectedAt: startTime
        )
    }

    /// Flag to track if stop() was called by user action (vs unexpected disconnect)
    private var userInitiatedStop: Bool = false

    /// Flag to track if we received an exit status from the shell (indicates normal exit vs network failure)
    private var receivedExitStatus: Bool = false

    /// Additional callback for state changes
    var onStateChange: ((KubernetesNodeShellState) -> Void)?

    // MARK: - Initialization

    init(pty: TerminalPTY, config: KubernetesNodeShellConfig) {
        self.pty = pty
        self.config = config
    }

    // MARK: - TerminalSession Protocol

    func start() async throws {
        guard !isRunning else { return }
        receivedExitStatus = false  // Reset for fresh session

        // Initialize output batcher with captured callbacks to avoid MainActor isolation issues.
        // The forwarder is stored in a `nonisolated` lock so `resumeForForeground()`
        // can drain the backgrounded buffer through the same callbacks.
        let forwarder = OutputForwarder(
            onOutputData: self.onOutputData,
            onOutput: self.onOutput
        )
        outputForwarderBox.withLock { $0 = forwarder }
        let backgroundedBuffer = self.backgroundedBuffer
        outputBatcher = OutputBatcher(
            minBatchIntervalMs: 8,
            maxBatchIntervalMs: 32
        ) { data in
            // Called directly on batcher queue - NO MainActor crossing.
            // While backgrounded, accumulate into a bounded buffer that the
            // foreground hook drains. Forwarding now would queue main-actor
            // work upstream and trip the resume watchdog.
            if Ghostty.isAppBackgroundedAtomic {
                backgroundedBuffer.append(data)
                return
            }
            forwarder.send(data)
        }

        Self.logger.info("Starting Kubernetes node shell session for node: \(self.config.nodeName)")

        do {
            // Phase 1: Initialize
            transition(to: .initializing)

            // Load cluster
            guard let cluster = KubernetesClusterManager.shared.clusters.first(where: { $0.id == config.clusterId }) else {
                throw KubernetesNodeShellError.clusterNotFound
            }

            // Load kubeconfig
            let kubeconfigYAML: String
            do {
                kubeconfigYAML = try KubernetesClusterManager.shared.getKubeconfig(for: cluster)
            } catch {
                throw KubernetesNodeShellError.kubeconfigNotFound
            }

            // Parse kubeconfig
            let kubeConfig: KubeConfig
            do {
                kubeConfig = try KubeConfig.from(config: kubeconfigYAML)
            } catch {
                throw KubernetesNodeShellError.kubeconfigParseError(error.localizedDescription)
            }

            // Extract auth config for WebSocket
            authConfig = try KubernetesAuthConfig.from(kubeConfig: kubeConfig, contextName: cluster.contextName)

            // Create Kubernetes client for pod operations
            guard let client = KubernetesClient(kubeConfig: kubeConfig, contextName: cluster.contextName) else {
                throw KubernetesNodeShellError.kubeconfigParseError("Failed to create Kubernetes client")
            }
            k8sClient = client

            // Phase 2: Verify node
            transition(to: .verifyingNode)
            try await verifyNode(client: client)

            // Phase 3: Create debug pod
            transition(to: .creatingPod)
            try await createDebugPod(client: client)
            podCreated = true

            // Phase 4: Wait for pod to be running
            transition(to: .waitingForPod(startTime: Date()))
            try await waitForPodRunning(client: client)

            // Phase 5: Connect exec
            transition(to: .connecting)
            try await connectExec()

            // Phase 6: Running
            isRunning = true
            connectionStartTime = Date()
            transition(to: .running)

            // Update title
            onTitleChange?("Node: \(config.nodeName)")

            Self.logger.info("Kubernetes node shell session ready for node: \(self.config.nodeName)")
            onReady?()

        } catch {
            Self.logger.error("Failed to start node shell: \(error.localizedDescription)")

            let shellError: KubernetesNodeShellError
            if let nodeError = error as? KubernetesNodeShellError {
                shellError = nodeError
            } else {
                shellError = KubernetesDebugPodSpec.parseCreationError(error)
            }

            transition(to: .failed(shellError))
            onError?(shellError)

            // Cleanup if we created a pod
            if podCreated {
                await cleanupPod()
            }

            throw shellError
        }
    }

    /// Drain output buffered while backgrounded. The exec WebSocket keeps
    /// receiving data while suspended; the batcher closure stashed it in
    /// `backgroundedBuffer` to avoid forwarding it (and queueing main-actor
    /// work) until we resume.
    func resumeForForeground() {
        guard let drained = backgroundedBuffer.drain() else { return }
        if drained.droppedDuringBackground > 0 {
            Self.logger.warning("K8s buffer dropped \(drained.droppedDuringBackground) bytes during background")
        }
        if let forwarder = outputForwarderBox.withLock({ $0 }) {
            forwarder.send(drained.data)
        }
    }

    func stop() {
        Self.logger.info("Stopping Kubernetes node shell session")

        // Mark this as user-initiated so we don't trigger reconnection
        userInitiatedStop = true

        let wasRunning = isRunning
        isRunning = false
        outputBatcher?.flush()

        // Unregister from manager
        KubernetesNodeShellManager.shared.unregisterSession(config.sessionId)

        // Disconnect exec
        execClient?.disconnect()
        execClient = nil

        // Clean up pod if it was created
        if podCreated {
            transition(to: .cleaningUp)
            Task {
                await cleanupPod()
                await shutdownClient()
                transition(to: .terminated)
            }
        } else {
            // Even if pod wasn't created, we need to shut down the k8s client
            // to avoid HTTPClient crash on deallocation
            Task {
                await shutdownClient()
                transition(to: .terminated)
            }
        }

        if wasRunning || podCreated {
            onSessionEnd?()
        }
    }

    /// Shuts down the Kubernetes client's HTTP client to avoid crash on deallocation
    private func shutdownClient() async {
        guard let client = k8sClient else { return }

        Self.logger.info("Shutting down Kubernetes client")
        do {
            try client.syncShutdown()
            Self.logger.info("Kubernetes client shut down successfully")
        } catch {
            Self.logger.error("Error shutting down Kubernetes client: \(error.localizedDescription)")
        }
        k8sClient = nil
    }

    func sendInput(_ data: Data) {
        guard isRunning, let execClient = execClient else {
            Self.logger.warning("Cannot send input: session not ready")
            return
        }

        execClient.sendStdin(data)
    }

    func setSize(_ size: TerminalPTY.TerminalSize) throws {
        pty.windowSize = size

        guard isRunning, let execClient = execClient else {
            return
        }

        execClient.sendResize(cols: Int(size.cols), rows: Int(size.rows))
    }

    // MARK: - Private Methods

    private func transition(to newState: KubernetesNodeShellState) {
        state = newState
        onStateChange?(newState)
        Self.logger.info("State transition: \(newState.statusDescription)")
    }

    /// Verify the target node exists and is schedulable
    private func verifyNode(client: KubernetesClient) async throws {
        Self.logger.info("Verifying node: \(self.config.nodeName)")

        do {
            let node = try await client.nodes.get(name: config.nodeName)

            // Check if node is schedulable
            if node.spec?.unschedulable == true {
                throw KubernetesNodeShellError.nodeUnschedulable(config.nodeName)
            }

            Self.logger.info("Node verified: \(self.config.nodeName)")
        } catch let error as KubernetesNodeShellError {
            throw error
        } catch {
            // Check for 404
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("404") || errorString.contains("not found") {
                throw KubernetesNodeShellError.nodeNotFound(config.nodeName)
            }
            throw error
        }
    }

    /// Create the debug pod on the target node
    private func createDebugPod(client: KubernetesClient) async throws {
        Self.logger.info("Creating debug pod: \(self.config.podName)")

        let podSpec = KubernetesDebugPodSpec.build(config: config)

        do {
            _ = try await client.pods.create(inNamespace: NamespaceSelector.system, podSpec)
            Self.logger.info("Debug pod created: \(self.config.podName)")
        } catch {
            throw KubernetesDebugPodSpec.parseCreationError(error)
        }
    }

    /// Wait for the pod to reach Running state
    private func waitForPodRunning(client: KubernetesClient) async throws {
        Self.logger.info("Waiting for pod to be running: \(self.config.podName)")

        let timeout = KubernetesNodeShellConstants.podStartTimeout
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            do {
                let pod = try await client.pods.get(in: NamespaceSelector.system, name: config.podName)
                let (isReady, phase, message) = KubernetesDebugPodSpec.checkPodStatus(pod)

                if isReady {
                    Self.logger.info("Pod is running: \(self.config.podName)")
                    return
                }

                if phase == "Failed" || phase == "Terminated" {
                    throw KubernetesNodeShellError.podFailed(message ?? "Pod failed to start")
                }

                Self.logger.debug("Pod status: \(phase) - \(message ?? "")")

            } catch let error as KubernetesNodeShellError {
                throw error
            } catch {
                Self.logger.warning("Error checking pod status: \(error.localizedDescription)")
            }

            // Wait before checking again
            try await Task.sleep(nanoseconds: 500_000_000)  // 500ms
        }

        throw KubernetesNodeShellError.podStartTimeout
    }

    /// Connect to the pod via exec WebSocket
    private func connectExec() async throws {
        guard let authConfig = authConfig else {
            throw KubernetesNodeShellError.execConnectionFailed("No auth config available")
        }

        Self.logger.info("Connecting exec to pod: \(self.config.podName)")

        let client = KubernetesExecClient()

        // Set up callbacks
        client.onStdout = { [weak self] data in
            self?.outputBatcher?.enqueue(data)
        }

        client.onStderr = { [weak self] data in
            self?.outputBatcher?.enqueue(data)
        }

        client.onError = { [weak self] errorMessage in
            Self.logger.warning("Exec error channel: \(errorMessage)")

            // Parse exit status if present - Kubernetes sends JSON on the error channel
            // Success: {"status":"Success"}
            // Failure: {"status":"Failure","message":"command terminated with exit code N",...}
            if let data = errorMessage.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                // Any exit status (Success or Failure) means the shell exited normally
                Self.logger.info("Shell exited with status: \(status)")
                self?.receivedExitStatus = true
            } else if !errorMessage.isEmpty {
                // Non-JSON error message - treat as error
                self?.onError?(KubernetesNodeShellError.execConnectionFailed(errorMessage))
            }
        }

        client.onClose = { [weak self] reason in
            guard let self = self else { return }
            Self.logger.info("Exec connection closed: \(reason ?? "no reason")")
            self.outputBatcher?.flush()

            if self.isRunning {
                self.isRunning = false
                self.transition(to: .disconnected(reason: .connectionLost))

                // Check if this was user-initiated or a normal shell exit
                if self.userInitiatedStop {
                    // User-initiated stop - end session normally
                    self.onSessionEnd?()
                } else if self.receivedExitStatus {
                    // Shell exited normally (user typed 'exit' or Ctrl+D)
                    Self.logger.info("Session ended normally (received exit status)")
                    self.onSessionEnd?()
                } else if let onDisconnect = self.onDisconnect {
                    // Unexpected disconnect - trigger reconnection
                    let disconnectReason: ReconnectionManager.DisconnectReason
                    if let reasonStr = reason?.lowercased() {
                        if reasonStr.contains("network") || reasonStr.contains("connection") {
                            disconnectReason = .networkLost
                        } else if reasonStr.contains("timeout") {
                            disconnectReason = .timeout
                        } else {
                            disconnectReason = .serverClosed
                        }
                    } else {
                        disconnectReason = .serverClosed
                    }
                    onDisconnect(disconnectReason)
                    // Don't call onSessionEnd - let reconnection manager handle it
                } else {
                    // No reconnection handler - fall back to session end
                    self.onSessionEnd?()
                }

                // Clean up pod in background
                Task {
                    await self.cleanupPod()
                    self.transition(to: .terminated)
                }
            }
        }

        client.onOpen = { [weak self, weak client] in
            Self.logger.info("Exec connection opened")

            // Send initial resize
            if let self = self {
                let size = self.pty.windowSize
                client?.sendResize(cols: Int(size.cols), rows: Int(size.rows))
            }
        }

        // Connect
        try await client.connect(
            authConfig: authConfig,
            podName: config.podName,
            podType: config.podType
        )

        self.execClient = client
    }

    /// Clean up the debug pod
    private func cleanupPod() async {
        guard let client = k8sClient, podCreated else { return }

        Self.logger.info("Cleaning up debug pod: \(self.config.podName)")

        do {
            try await client.pods.delete(inNamespace: NamespaceSelector.system, name: config.podName)
            Self.logger.info("Debug pod deleted: \(self.config.podName)")
        } catch {
            Self.logger.warning("Failed to delete debug pod \(self.config.podName): \(error.localizedDescription)")
        }

        // Shutdown client
        do {
            try await client.shutdown()
        } catch {
            Self.logger.warning("Failed to shutdown Kubernetes client: \(error.localizedDescription)")
        }

        k8sClient = nil
        podCreated = false
    }

}
