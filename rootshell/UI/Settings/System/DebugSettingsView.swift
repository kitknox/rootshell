//
//  DebugSettingsView.swift
//  rootshell
//
//  Hidden debug settings, accessible by long-pressing the rootshell logo for 5 seconds.
//

import SwiftUI

struct DebugSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @AppStorage(ResumeDebugLogger.enabledKey) private var resumeDebugLogging: Bool = false
    @AppStorage(LifecycleDebugLogger.enabledKey) private var lifecycleDebugLogging: Bool = false
    @AppStorage(LifecycleDebugLogger.syncRendererDrainEnabledKey) private var syncRendererDrain: Bool = false
    @AppStorage(SSHDebugLogger.enabledKey) private var sshDebugLogging: Bool = false
    @AppStorage(VNCDebugLogger.enabledKey) private var vncDebugLogging: Bool = false
    @AppStorage(TmuxDebugLogger.enabledKey) private var tmuxDebugLogging: Bool = false
    @AppStorage(AgentDetectionCapture.enabledKey) private var agentCaptureEnabled: Bool = false
    @AppStorage(
        "vpnConnectionDebugLoggingEnabled",
        store: UserDefaults(suiteName: AppIdentifiers.defaultAppGroupID)
    ) private var vpnConnectionDebugLogging: Bool = false

    /// Log file sizes for display
    @State private var logFileSize: String = "—"
    @State private var lifecycleLogFileSize: String = "—"
    @State private var sshLogFileSize: String = "—"
    @State private var vncLogFileSize: String = "—"
    @State private var tmuxLogFileSize: String = "—"
    @State private var vpnLogFileSize: String = "—"
    @State private var agentCaptureFileSize: String = "—"

    private static let vpnAppGroupID = AppIdentifiers.defaultAppGroupID
    private static let vpnLogFilename = "vpn_connection_debug.log"
    private static let vpnRotatedLogFilename = "vpn_connection_debug.1.log"

    var body: some View {
        List {
            // MARK: - Agent Detection Capture

            Section {
                Toggle("Record Detection Snapshots", isOn: $agentCaptureEnabled)
                    .onChange(of: agentCaptureEnabled) { _, enabled in
                        if enabled { AgentDetectionCapture.shared.reset() }
                        refreshAgentCaptureFileSize()
                    }
                    .themedRow()

                HStack {
                    Text("Capture File Size")
                    Spacer()
                    Text(agentCaptureFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Clear Captures", role: .destructive) {
                    AgentDetectionCapture.shared.reset()
                    refreshAgentCaptureFileSize()
                }
                .themedRow()
            } header: {
                Text("Agent Detection")
            } footer: {
                Text("Records every screen the coding-agent detector reads to .ghostty/agent-detection-captures.jsonl: the exact rows, terminal size, alternate-screen state and OSC title, with whichever agent and rule matched. This is what misdetections should be diagnosed from: a screenshot or a copy-paste loses the row boundaries the rules match on. Frames that differ only by a spinner or a ticking counter are skipped. At 2 MB the file rotates to agent-detection-captures.1.jsonl and recording continues, so the newest frames are always the ones kept.")
            }

            // MARK: - Session Resume Debug

            Section {
                Toggle("Resume Debug Logging", isOn: $resumeDebugLogging)
                    .themedRow()
            } header: {
                Text("Session Resume")
            } footer: {
                Text("Logs detailed trzsz/mosh session resume diagnostics to a file that survives force-quit. Useful for debugging reconnection failures.")
            }

            Section {
                HStack {
                    Text("Log File Size")
                    Spacer()
                    Text(logFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Export Log File") {
                    exportLogFile()
                }
                .themedRow()

                Button("Clear Log File", role: .destructive) {
                    clearLogFile()
                    refreshLogFileSize()
                }
                .themedRow()
            } header: {
                Text("Resume Log File")
            } footer: {
                Text("Log is stored at Documents/.ghostty/resume_debug.log")
            }

            // MARK: - Lifecycle Debug

            Section {
                Toggle("Lifecycle Debug Logging", isOn: $lifecycleDebugLogging)
                    .themedRow()

                Toggle("Synchronous Renderer Drain", isOn: $syncRendererDrain)
                    .themedRow()
            } header: {
                Text("App Lifecycle")
            } footer: {
                Text("Logs every checkpoint on the background → foreground path with timestamps and deltas. The renderer drain toggle restores the old scene-update behavior for A/B testing and is off by default.")
            }

            Section {
                HStack {
                    Text("Log File Size")
                    Spacer()
                    Text(lifecycleLogFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Export Log File") {
                    exportLifecycleLogFile()
                }
                .themedRow()

                Button("Clear Log File", role: .destructive) {
                    clearLifecycleLogFile()
                    refreshLifecycleLogFileSize()
                }
                .themedRow()
            } header: {
                Text("Lifecycle Log File")
            } footer: {
                Text("Log is stored at Documents/.ghostty/lifecycle_debug.log")
            }

            // MARK: - SSH Connection Debug

            Section {
                Toggle("SSH Connection Debug Logging", isOn: $sshDebugLogging)
                    .themedRow()
            } header: {
                Text("SSH Connection")
            } footer: {
                Text("Logs SSH handshake details (KEX, host key, auth, channel) similar to `ssh -vv`. Passwords and private keys are never logged.")
            }

            Section {
                HStack {
                    Text("Log File Size")
                    Spacer()
                    Text(sshLogFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Export Log File") {
                    exportSSHLogFile()
                }
                .themedRow()

                Button("Clear Log File", role: .destructive) {
                    clearSSHLogFile()
                    refreshSSHLogFileSize()
                }
                .themedRow()
            } header: {
                Text("SSH Log File")
            } footer: {
                Text("Log is stored at Documents/.ghostty/ssh_debug.log")
            }

            // MARK: - Screen Sharing (VNC) Debug

            Section {
                Toggle("Screen Sharing Debug Logging", isOn: $vncDebugLogging)
                    .themedRow()
            } header: {
                Text("Screen Sharing")
            } footer: {
                Text("Logs the whole VNC connection timeline: handshake, negotiated encodings and media generations, a health heartbeat while connected, and a summary line naming why a session dropped. Passwords, clipboard contents and screen pixels are never logged. Leave this on to catch an unexplained “Connection interrupted”.")
            }

            Section {
                HStack {
                    Text("Log File Size")
                    Spacer()
                    Text(vncLogFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Export Log File") {
                    exportVNCLogFile()
                }
                .themedRow()

                Button("Clear Log File", role: .destructive) {
                    clearVNCLogFile()
                    refreshVNCLogFileSize()
                }
                .themedRow()
            } header: {
                Text("Screen Sharing Log File")
            } footer: {
                Text("Log is stored at Documents/.ghostty/vnc_debug.log")
            }

            // MARK: - tmux Control Mode Debug

            Section {
                Toggle("tmux Control Mode Debug Logging", isOn: $tmuxDebugLogging)
                    .themedRow()
            } header: {
                Text("tmux Control Mode")
            } footer: {
                Text("Logs the tmux -CC reconcile/apply timeline, commands sent, the resume watchdog, and a live-state heartbeat (with a core viewer snapshot). Terminal output, titles, and keystrokes are never logged — only ids, sizes, byte counts, and durations.")
            }

            Section {
                HStack {
                    Text("Log File Size")
                    Spacer()
                    Text(tmuxLogFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Capture tmux State") {
                    TmuxController.captureAllState()
                    refreshTmuxLogFileSize()
                }
                .themedRow()

                Button("Export Log File") {
                    exportTmuxLogFile()
                }
                .themedRow()

                Button("Clear Log File", role: .destructive) {
                    clearTmuxLogFile()
                    refreshTmuxLogFileSize()
                }
                .themedRow()
            } header: {
                Text("tmux Log File")
            } footer: {
                Text("Log is stored at Documents/.ghostty/tmux_debug.log. Use “Capture tmux State” while reproducing a hang to snapshot the current state.")
            }

            #if !CHINA_BUILD
            // MARK: - VPN Connection Debug

            Section {
                Toggle("VPN Connection Debug Logging", isOn: $vpnConnectionDebugLogging)
                    .themedRow()
            } header: {
                Text("VPN Connection")
            } footer: {
                Text("Logs detailed VPN connection timeline (DNS, SSH, tsshd, netstack) with phase durations. Takes effect on next VPN connection start.")
            }

            Section {
                HStack {
                    Text("Log File Size")
                    Spacer()
                    Text(vpnLogFileSize)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                Button("Export Log File") {
                    exportVPNLogFile()
                }
                .themedRow()

                Button("Clear Log File", role: .destructive) {
                    clearVPNLogFiles()
                    refreshVPNLogFileSize()
                }
                .themedRow()
            } header: {
                Text("VPN Connection Log File")
            } footer: {
                Text("Export copies the log to Documents/.ghostty/ for local shell access.")
            }
            #endif

            // MARK: - Settings Registry

            Section {
                NavigationLink {
                    SettingsRegistryDebugView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "list.bullet.rectangle")
                        Text("Settings Registry")
                    }
                }
                .themedRow()
            } header: {
                Text("Settings Sync")
            } footer: {
                Text("Every UserDefaults key must be registered with a type, default, and sync policy before it can sync. Lists keys that are still unregistered or stored with an unexpected type.")
            }
        }
        .themedList()
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshAgentCaptureFileSize()
            refreshLogFileSize()
            refreshLifecycleLogFileSize()
            refreshSSHLogFileSize()
            refreshVNCLogFileSize()
            refreshTmuxLogFileSize()
            #if !CHINA_BUILD
            refreshVPNLogFileSize()
            #endif
        }
        .onChange(of: vncDebugLogging) { _, isOn in
            // Same reasoning as tmux below: enabling mid-session emits nothing
            // until the next package log record, so write a marker now to
            // create the file and make "Export Log File" work immediately.
            if isOn {
                VNCDebugLogger.shared.logMarker("DEBUG LOGGING ENABLED (runtime toggle)")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    refreshVNCLogFileSize()
                }
            }
        }
        .onChange(of: tmuxDebugLogging) { _, isOn in
            // Let live TmuxControllers start/stop their heartbeat immediately.
            NotificationCenter.default.post(name: TmuxDebugLogger.enabledDidChange, object: nil)
            // Enabling at runtime emits no line until the next tmux event, so the
            // log file didn't exist right after flipping it on (a restart created
            // it via AppDelegate's APP LAUNCH marker). Write a marker now so the
            // file exists and "Export Log File" works without any tmux activity,
            // then refresh the size row once the write lands on the logger's
            // serial ioQueue.
            if isOn {
                TmuxDebugLogger.shared.marker("DEBUG LOGGING ENABLED (runtime toggle)")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(200))
                    refreshTmuxLogFileSize()
                }
            }
        }
    }

    // MARK: - Agent Capture Helpers

    private func refreshAgentCaptureFileSize() {
        // Both windows, so a rotation never reads as "the capture shrank".
        let urls = [AgentDetectionCapture.fileURL, AgentDetectionCapture.rotatedFileURL]
            .compactMap { $0 }
        let total = urls.reduce(into: UInt64(0)) { sum, url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? UInt64
            else { return }
            sum += size
        }
        guard total > 0 else {
            agentCaptureFileSize = "No captures"
            return
        }
        agentCaptureFileSize = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    // MARK: - Resume Log Helpers

    private func refreshLogFileSize() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/resume_debug.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64 {
            logFileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            logFileSize = "No log file"
        }
    }

    private func exportLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/resume_debug.log")

        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        presentShareSheet(for: logURL)
    }

    private func clearLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/resume_debug.log")
        let rotatedURL = documentsURL.appendingPathComponent(".ghostty/resume_debug.1.log")
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    // MARK: - Lifecycle Log Helpers

    private func refreshLifecycleLogFileSize() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/lifecycle_debug.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64 {
            lifecycleLogFileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            lifecycleLogFileSize = "No log file"
        }
    }

    private func exportLifecycleLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/lifecycle_debug.log")

        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        presentShareSheet(for: logURL)
    }

    private func clearLifecycleLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/lifecycle_debug.log")
        let rotatedURL = documentsURL.appendingPathComponent(".ghostty/lifecycle_debug.1.log")
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    // MARK: - SSH Log Helpers

    private func refreshSSHLogFileSize() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/ssh_debug.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64 {
            sshLogFileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            sshLogFileSize = "No log file"
        }
    }

    private func exportSSHLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/ssh_debug.log")

        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        presentShareSheet(for: logURL)
    }

    private func clearSSHLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/ssh_debug.log")
        let rotatedURL = documentsURL.appendingPathComponent(".ghostty/ssh_debug.1.log")
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    // MARK: - Screen Sharing (VNC) Log Helpers

    private func refreshVNCLogFileSize() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/vnc_debug.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64 {
            vncLogFileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            vncLogFileSize = "No log file"
        }
    }

    private func exportVNCLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/vnc_debug.log")

        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        presentShareSheet(for: logURL)
    }

    private func clearVNCLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/vnc_debug.log")
        let rotatedURL = documentsURL.appendingPathComponent(".ghostty/vnc_debug.1.log")
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    // MARK: - tmux Log Helpers

    private func refreshTmuxLogFileSize() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/tmux_debug.log")

        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? UInt64 {
            tmuxLogFileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        } else {
            tmuxLogFileSize = "No log file"
        }
    }

    private func exportTmuxLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/tmux_debug.log")

        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        presentShareSheet(for: logURL)
    }

    private func clearTmuxLogFile() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = documentsURL.appendingPathComponent(".ghostty/tmux_debug.log")
        let rotatedURL = documentsURL.appendingPathComponent(".ghostty/tmux_debug.1.log")
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }

    // MARK: - VPN Connection Log Helpers

    private static func vpnLogFileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: vpnAppGroupID
        )?.appendingPathComponent(vpnLogFilename)
    }

    private static func vpnRotatedLogFileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: vpnAppGroupID
        )?.appendingPathComponent(vpnRotatedLogFilename)
    }

    private func refreshVPNLogFileSize() {
        guard let url = Self.vpnLogFileURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else {
            vpnLogFileSize = "No log file"
            return
        }
        vpnLogFileSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func exportVPNLogFile() {
        guard let logURL = Self.vpnLogFileURL(),
              FileManager.default.fileExists(atPath: logURL.path) else { return }

        // Copy to Documents so it's accessible from the local shell too
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ghosttyDir = documentsURL.appendingPathComponent(".ghostty", isDirectory: true)
        try? FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
        let destURL = ghosttyDir.appendingPathComponent(Self.vpnLogFilename)
        try? FileManager.default.removeItem(at: destURL)
        try? FileManager.default.copyItem(at: logURL, to: destURL)

        presentShareSheet(for: destURL)
    }

    private func clearVPNLogFiles() {
        if let url = Self.vpnLogFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = Self.vpnRotatedLogFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        // Also clean the Documents copy
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destURL = documentsURL.appendingPathComponent(".ghostty/\(Self.vpnLogFilename)")
        try? FileManager.default.removeItem(at: destURL)
    }

    // MARK: - Share Sheet

    private func presentShareSheet(for url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else { return }

        // Walk up to the topmost presented VC so the share sheet presents correctly
        // when deep in a navigation/sheet stack.
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topVC.present(activityVC, animated: true)
    }
}
