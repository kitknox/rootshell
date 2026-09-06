//
//  SSHConnectionView+VNC.swift
//  rootshell
//
//  Screen Sharing / VNC connection form for SSHConnectionView. The form
//  sections themselves live in VNCConnectionFormSections (shared with the
//  profile editor); this extension wires them to the connect flow.
//

import SwiftUI

extension SSHConnectionView {

    // MARK: - Form

    var vncConnectionContent: some View {
        VStack(spacing: 0) {
            compactOpenAsHeader
            vncFormContent
        }
    }

    private var vncFormContent: some View {
        Form {
            if let errorMessage {
                Section {
                    Group {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)

                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                    .themedRow()
                }
            }

            VNCConnectionFormSections(form: $vncForm)
        }
        .themedList()
#if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
#endif
    }

    // MARK: - Validation

    var isVNCFormValid: Bool {
        vncForm.isValid
    }

    // MARK: - Populate helpers

    /// Populate the VNC form from a saved profile (QuickConnect suggestion
    /// accept). Mirrors handleProfileAccepted for SSH profiles.
    func applyVNCProfile(_ profile: ConnectionProfile) {
        guard let config = profile.vncConfig else { return }

        quickConnectProfile = profile
        connectionType = .vnc
        vncForm = VNCFormState(config: config)

        // Prefill a saved password so connect works without a prompt.
        if let saved = try? VNCPasswordManager.shared.loadPassword(for: config) {
            vncForm.password = saved
        }

    }

    /// Populate the VNC form from a discovered host or vnc:// quick connect.
    func applyVNCTarget(hostname: String, port: Int?) {
        quickConnectProfile = nil
        connectionType = .vnc
        var form = VNCFormState()
        form.hostname = hostname
        form.port = "\(port ?? 5900)"
        vncForm = form
    }

    /// Parse "vnc://host[:port]" into its parts. Returns nil when the text
    /// isn't a vnc URL.
    static func parseVNCQuickConnect(_ text: String) -> (host: String, port: Int?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vnc://") else { return nil }
        var remainder = String(trimmed.dropFirst("vnc://".count))
        if remainder.hasSuffix("/") {
            remainder = String(remainder.dropLast())
        }
        guard !remainder.isEmpty else { return (host: "", port: nil) }

        // host[:port] — only split when the suffix is numeric so bare IPv6
        // literals aren't mangled.
        if let colonIndex = remainder.lastIndex(of: ":"),
           case let portPart = String(remainder[remainder.index(after: colonIndex)...]),
           !portPart.isEmpty,
           portPart.allSatisfy(\.isNumber),
           let port = Int(portPart) {
            return (host: String(remainder[..<colonIndex]), port: port)
        }
        return (host: remainder, port: nil)
    }

    // MARK: - Connect

    func connectVNC() {
        errorMessage = nil

        let config: VNCConnectionConfig
        do {
            config = try vncForm.buildConfig()
        } catch {
            errorMessage = (error as? VNCFormState.BuildError)?.message ?? error.localizedDescription
            return
        }

        // Save the manual jump password like the SSH form does (best effort).
        if vncForm.jumpSelection == .manual,
           vncForm.jumpAuthMethod == .password,
           vncForm.saveJumpPassword,
           !vncForm.jumpPassword.isEmpty,
           case .sshConfig(let jumpSSH) = config.jump {
            _ = try? SSHPasswordManager.shared.savePassword(
                vncForm.jumpPassword,
                host: jumpSSH.host,
                port: jumpSSH.port,
                username: jumpSSH.username
            )
        }

        // Persist or stash the VNC password: saved passwords go to the
        // Keychain; an unsaved one is handed to the pane for this connection
        // only (otherwise it would immediately re-prompt in-pane).
        if !vncForm.password.isEmpty {
            if vncForm.savePassword {
                do {
                    try VNCPasswordManager.shared.savePassword(vncForm.password, for: config)
                } catch {
                    // Don't block the connection on a Keychain failure.
                    VNCPasswordManager.shared.stashEphemeralPassword(vncForm.password, for: config.passwordKey)
                }
            } else {
                VNCPasswordManager.shared.stashEphemeralPassword(vncForm.password, for: config.passwordKey)
            }
        }

        if var profile = quickConnectProfile,
           profile.connectionProtocol == .vnc,
           profile.vncConfig?.host == config.host,
           let onProfileConnect {
            profile.vncConfig = config
            onProfileConnect(profile, splitOption)
        } else {
            onVNCConnect?(config, splitOption)
        }
        close()
    }
}
