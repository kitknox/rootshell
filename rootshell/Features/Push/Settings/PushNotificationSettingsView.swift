//
//  PushNotificationSettingsView.swift
//  rootshell
//
//  Settings → Notifications → Push Notifications: enable, paired
//  computers, and the pairing flow.
//

import RootshellPushKit
import SwiftUI

struct PushNotificationSettingsView: View {
    private let manager = PushRegistrationManager.shared
    @State private var senderToRevoke: PushPairedSender?

    var body: some View {
        List {
            Section {
                SettingToggle(
                    Settings.Notifications.pushEnabled,
                    isOn: Binding(
                        get: { manager.isEnabled },
                        set: { newValue in
                            Task {
                                if newValue { _ = await manager.enable() } else { manager.disable() }
                            }
                        }
                    ),
                    title: "Push Notifications",
                    icon: "lock.shield"
                )
                .themedRow()

                HStack(spacing: 12) {
                    SettingsIcon(systemName: statusIcon)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Agent events")
                                .fontWeight(.semibold)
                            Text("Coding-agent alerts follow the Agent Notifications policy and stay hidden while you are viewing the pane.")
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Privacy")
                                .fontWeight(.semibold)
                            Text("Messages use end-to-end encryption with post-quantum cryptography. The relay cannot read them and does not retain them.")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 6)
                } label: {
                    Label("How Push Notifications Work", systemImage: "info.circle")
                }
                .themedRow()
            } footer: {
                Text("Receive encrypted alerts from coding agents on your paired computers.")
            }

            if manager.state == .registered {
                Section {
                    SettingToggle(
                        Settings.Notifications.pushAgentBackgroundOnly,
                        isOn: Binding(
                            get: { manager.agentBackgroundOnly },
                            set: { manager.agentBackgroundOnly = $0 }
                        ),
                        title: "Only When in Background",
                        icon: "moon.zzz"
                    )
                    .themedRow()

                    SettingToggle(
                        Settings.Notifications.pushAgentLogos,
                        isOn: Binding(
                            get: { manager.agentLogosEnabled },
                            set: { manager.agentLogosEnabled = $0 }
                        ),
                        title: "Show Agent Logos",
                        icon: "photo"
                    )
                    .themedRow()
                } footer: {
                    Text("These options apply to detected agent events. Explicit `rootshell-notify send` messages always appear without agent artwork.")
                }

                Section {
                    ForEach(manager.senders) { sender in
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: sender.stale ? "exclamationmark.triangle" : "desktopcomputer")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sender.label)
                                Text(detail(sender))
                                    .font(.caption)
                                    .foregroundColor(sender.stale ? .orange : .secondary)
                            }
                            Spacer()
                        }
                        .themedRow()
                        .swipeActions {
                            Button(role: .destructive) { senderToRevoke = sender } label: {
                                Label("Revoke", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { senderToRevoke = sender } label: {
                                Label("Revoke", systemImage: "trash")
                            }
                        }
                    }

                    NavigationLink {
                        PushPairingView()
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "plus.circle")
                            Text("Pair a Computer…")
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Paired Computers")
                } footer: {
                    Text("Swipe or use the context menu to revoke a computer and stop accepting its notifications.")
                }

                PushCommandSection(
                    title: String(localized: "Install or Upgrade the Hook Client"),
                    command: PushCommandSection.upgradeCommand,
                    footer: String(localized: "Updates rootshell-notify and refreshes Claude Code and Codex hooks. Existing pairings are kept."))
            }
        }
        .themedList()
        .navigationTitle("Push Notifications")
        .confirmationDialog("Revoke this computer?", isPresented: Binding(
            get: { senderToRevoke != nil }, set: { if !$0 { senderToRevoke = nil } }
        ), titleVisibility: .visible) {
            Button("Revoke", role: .destructive) {
                if let sender = senderToRevoke { manager.revokeSender(id: sender.id) }
                senderToRevoke = nil
            }
        }
    }

    private var statusIcon: String {
        switch manager.state {
        case .disabled: return "circle"
        case .waitingForToken: return "clock"
        case .registered: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusText: String {
        switch manager.state {
        case .disabled: return String(localized: "Off")
        case .waitingForToken: return String(localized: "Registering with push.rootshell.com…")
        case .registered: return String(localized: "Registered")
        case .failed(let message): return String(localized: "Registration failed: \(message)")
        }
    }

    private func detail(_ sender: PushPairedSender) -> String {
        if sender.stale {
            return String(localized: "Re-pair required: this device was re-registered")
        }
        return String(localized: "Paired \(sender.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// Mints a sender credential and hands the pairing bundle to a terminal.
/// Pushed inside the settings navigation so it stays in the split view.
struct PushPairingView: View {
    @Environment(\.dismiss) private var dismiss
    private let manager = PushRegistrationManager.shared
    @State private var label = ""
    @State private var hasSeededLabel = false
    @State private var bundle: String?
    @State private var error: String?
    private static let installCommand = PushCommandSection.installCommand

    var body: some View {
        List {
            if let bundle {
                pairedContent(bundle)
            } else {
                Section {
                    HStack {
                        TextField("Computer name", text: $label)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !label.isEmpty {
                            Button {
                                label = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear computer name")
                        }
                    }
                    .themedRow()
                    if let error {
                        Text(error).font(.caption).foregroundColor(.red).themedRow()
                    }
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            Text("Create Pairing")
                            if manager.isBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || manager.isBusy)
                    .themedRow()
                } footer: {
                    Text("A name to recognise this computer by, e.g. the hostname.")
                }
            }
        }
        .themedList()
        .navigationTitle("Pair a Computer")
        .onAppear {
            seedLabelFromFocusedConnection()
        }
    }

    @ViewBuilder
    private func pairedContent(_ bundle: String) -> some View {
        commandSection(
            title: String(localized: "Run on the computer"),
            command: setupCommand(bundle),
            previewCommand: setupCommand(Self.pairingCodePlaceholder),
            footer: String(localized: "Installs or updates rootshell-notify, pairs this device, and configures available Claude Code and Codex hooks.")
        )
        commandSection(
            title: String(localized: "Already installed?"),
            command: pairCommand(bundle),
            previewCommand: pairCommand(Self.pairingCodePlaceholder),
            footer: String(localized: "Pairs this computer using its device-specific, revocable credential.")
        )
    }

    private func commandSection(
        title: String,
        command: String,
        previewCommand: String? = nil,
        footer: String? = nil
    ) -> some View {
        PushCommandSection(
            title: title,
            command: command,
            previewCommand: previewCommand,
            footer: footer,
            onTyped: { dismiss() }
        )
    }

    private static let pairingCodePlaceholder = "<pairing-code>"

    private func pairCommand(_ bundle: String) -> String {
        "rootshell-notify setup --pair '\(bundle)'"
    }

    private func setupCommand(_ bundle: String) -> String {
        "\(Self.installCommand) -s -- --pair '\(bundle)'"
    }

    private func seedLabelFromFocusedConnection() {
        guard !hasSeededLabel else { return }
        hasSeededLabel = true
        label = Self.focusedRemoteHost ?? ""
    }

    private static var focusedRemoteHost: String? {
        guard let connectionInfo = PushCommandSection.focusedConnectionInfo?.transportInfo else { return nil }
        switch connectionInfo {
        case .ssh(let info), .mosh(let info):
            return info.host
        case .trzsz(let info, _, _):
            return info.host
        case .local, .kubernetes, .console, .vnc, .tmux, .herdr:
            return nil
        }
    }

    private func create() async {
        error = nil
        do {
            bundle = try await manager.createPairing(label: label.trimmingCharacters(in: .whitespaces)).encoded()
        } catch {
            self.error = PushRegistrationManager.describe(error)
        }
    }
}

/// A shell command with "Type into Current Terminal" and "Copy" actions.
struct PushCommandSection: View {
    static let installCommand = "curl -fsSL https://push.rootshell.com/install.sh | sh"
    /// Installs or upgrades the client and refreshes hooks without re-pairing.
    static let upgradeCommand = "\(installCommand) -s -- --hooks auto"

    let title: String
    let command: String
    var previewCommand: String? = nil
    var footer: String?
    var onTyped: (() -> Void)?
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        Section {
            CopyableValueBlock(
                title: previewCommand == nil
                    ? String(localized: "Shell Command", comment: "Push command block header")
                    : String(localized: "Command Preview", comment: "Push command block header"),
                value: previewCommand ?? command,
                copyText: command,
                font: .system(.footnote, design: .monospaced)
            ) {
                if previewCommand != nil {
                    Label("Preview shortened; actions use the complete command.", systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            if let terminal = Self.focusedTerminal {
                Button {
                    terminal.sendUserInput(Data(command.utf8))
                    onTyped?()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "terminal")
                        Text("Type into Current Terminal")
                    }
                }
                .themedRow()
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private static var focusedTabsModel: TabsModel? {
        let windows = TmuxWindowRegistry.allWindows()
        if let activeSceneID = WindowFocusRegistry.shared.activeSceneSessionId(),
           let activeWindow = windows.first(where: {
               TerminalWindowRegistry.sceneSessionId(for: $0.windowId) == activeSceneID
           }) {
            return activeWindow.model
        }
        return windows.lazy.map(\.model).first(where: {
            $0.selectedTab?.focusedTerminal != nil
        }) ?? windows.first?.model
    }

    static var focusedTerminal: Ghostty.TerminalView? {
        focusedTabsModel?.selectedTab?.focusedTerminal
    }

    static var focusedConnectionInfo: ConnectionInfo? {
        focusedTabsModel?.selectedTab?.connectionInfo
    }
}
