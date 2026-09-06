//
//  SSHKeyGenerateView.swift
//  rootshell
//
//  UI for generating new SSH keys in-app. Presents the choice between
//  software keys (RSA / Ed25519 / ECDSA, whose private bytes live in the
//  Keychain) and a hardware-protected Secure Enclave P-256 key (whose
//  private key is generated in and never leaves the enclave).
//

import SwiftUI
import os.log

/// What the user is generating: a software key (one of the standard
/// algorithms) or a hardware-protected Secure Enclave P-256 key.
private enum KeyProtectionSelection: Hashable {
    case software(GenerateKeyType)
    case secureEnclave

    var isSecureEnclave: Bool {
        if case .secureEnclave = self { return true }
        return false
    }

    var softwareType: GenerateKeyType? {
        if case .software(let type) = self { return type }
        return nil
    }
}

struct SSHKeyGenerateView: View {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHKeyGenerate")
    @Environment(\.dismiss) var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var sshKeyManager = SSHKeyManager.shared

    @State private var keyName = ""
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isGenerating = false
    @State private var selection: KeyProtectionSelection = .software(.ed25519)
    @State private var generationTask: Task<Void, Never>?

    // Security options
    @State private var showSecurityOptions = false
    @State private var storageLevel: KeyStorageLevel = .backupOnly
    @State private var authRequirement: KeyAuthRequirement = .none

    // Result sheet shown after a Secure Enclave key is created (its public
    // key / authorized_keys line is the only exportable artifact).
    @State private var generatedSecureEnclaveKey: SSHKey?

    private let secureEnclaveAvailable = SSHKeyManager.isSecureEnclaveAvailable

    var body: some View {
        Form {
                // Key name input
                Section {
                    TextField("Key Name", text: $keyName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    Text("A friendly name for this key (e.g., 'Work Server', 'GitHub')")
                }

                // Key type picker. NavigationLink + custom selection list
                // (grouped into Hardware-Protected vs Software) instead of a
                // menu picker so the trigger row stays compact and the
                // security distinction is legible.
                Section {
                    NavigationLink {
                        SSHKeyTypeSelectionList(
                            selection: $selection,
                            secureEnclaveAvailable: secureEnclaveAvailable
                        )
                    } label: {
                        HStack {
                            Label("Key Type", systemImage: selection.isSecureEnclave ? "lock.shield.fill" : "key.fill")
                            Spacer()
                            if selection.isSecureEnclave {
                                HardwarePill()
                            }
                            Text(selectionShortLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .themedRow()
                } footer: {
                    Text(selectionFooter)
                }

                // Hardware-protection explanation (Secure Enclave only).
                if selection.isSecureEnclave {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.indigo)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hardware-protected")
                                    .font(.subheadline.bold())
                                Text("The private key is generated inside the Secure Enclave and can never be read, exported, backed up, or synced — not even by this app. P-256 only.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .themedRow()
                    }
                }

                // Security options (collapsible)
                Section {
                    DisclosureGroup("Security Options", isExpanded: $showSecurityOptions) {
                        // Keep the divider inside one content row instead of a separate Form row.
                        VStack(alignment: .leading, spacing: 12) {
                            // Storage level
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Key Storage")
                                    .font(.subheadline.bold())

                                if selection.isSecureEnclave {
                                    // Secure Enclave keys are device-bound by
                                    // construction: no backup, no iCloud sync.
                                    HStack {
                                        Label("This Device Only", systemImage: "iphone")
                                        Spacer()
                                        Image(systemName: "lock.fill")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                    Text("Secure Enclave keys are bound to this device and cannot be backed up or synced.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Picker("Key Storage", selection: $storageLevel) {
                                        ForEach(KeyStorageLevel.allCases, id: \.self) { level in
                                            Label(level.displayName, systemImage: level.iconName)
                                                .tag(level)
                                        }
                                    }
                                    .pickerStyle(.menu)

                                    Text(storageLevel.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)

                            Divider()

                            // Auth requirement picker
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Require Authentication")
                                    .font(.subheadline.bold())

                                Picker("Authentication", selection: $authRequirement) {
                                    ForEach(KeyAuthRequirement.allCases, id: \.self) { req in
                                        Label(req.displayName, systemImage: req.iconName)
                                            .tag(req)
                                    }
                                }
                                .pickerStyle(.menu)

                                Text(authRequirement.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if authRequirement != .none {
                                    HStack {
                                        Image(systemName: SSHKeyAuthManager.shared.biometricIconName)
                                            .foregroundColor(.blue)
                                        Text("Uses \(SSHKeyAuthManager.shared.biometricTypeName) or device passcode")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    if storageLevel == .iCloudSync {
                                        Text(KeyAuthRequirement.iCloudAuthenticationAdvisory)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .themedRow()
                } footer: {
                    if !showSecurityOptions {
                        Text("Tap to configure storage and authentication options")
                    }
                }

                // Security recommendation for software keys with no auth.
                if !selection.isSecureEnclave && authRequirement == .none {
                    Section {
                        HStack {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                            Text("Consider enabling authentication in Security Options for additional protection of your private key.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }

                // Generate button
                Section {
                    Button(action: generateKey) {
                        HStack {
                            Spacer()
                            if isGenerating {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isGenerating ? String(localized: "Generating...", comment: "SSH key generation: in progress") : String(localized: "Generate Key", comment: "SSH key generation: button"))
                            Spacer()
                        }
                    }
                    .disabled(!canGenerate || isGenerating)
                    .themedRow()
                }

                // RSA-specific generation-time warning
                if selection.softwareType?.sshKeyType == .rsa {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.orange)
                            Text("Generating an RSA key on-device can take several seconds (especially at 4096 bits). Keep this screen open until it finishes.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                }
            }
            // Lock every form input while a generation/import is in flight so
            // the snapshot we took at the top of `generateKey()` always
            // matches what the user sees on screen. Back navigation remains
            // available outside the form.
            .disabled(isGenerating)
            .themedList()
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Generate SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                // A late RSA key-generation result must not be imported after
                // the user has navigated back from this view.
                generationTask?.cancel()
            }
            .onChange(of: selection) { _, newValue in
                // Secure Enclave keys are device-only; pick the agreed
                // "Once Per Session" default. Switching back to software
                // restores the software defaults.
                if newValue.isSecureEnclave {
                    storageLevel = .deviceOnly
                    authRequirement = .perSession
                } else {
                    storageLevel = .backupOnly
                    authRequirement = .none
                }
            }
            .alert("Generation Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .sheet(item: $generatedSecureEnclaveKey) { key in
                GeneratedSecureEnclaveKeyResultView(key: key) {
                    generatedSecureEnclaveKey = nil
                    dismiss()
                }
                .themedSubSheet(sheetThemeColors)
            }
    }

    // MARK: - Computed Properties

    private var canGenerate: Bool {
        !keyName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectionShortLabel: String {
        switch selection {
        case .software(let type): return type.shortDisplayName
        case .secureEnclave: return String(localized: "Secure Enclave P-256", comment: "SSH key generation: Secure Enclave option short label")
        }
    }

    private var selectionFooter: String {
        switch selection {
        case .software(let type): return type.footerDescription
        case .secureEnclave:
            return String(localized: "P-256 key generated inside the Secure Enclave. The private key never leaves this device and cannot be exported, backed up, or synced.", comment: "SSH key generation: Secure Enclave footer")
        }
    }

    // MARK: - Actions

    private func generateKey() {
        let trimmedName = keyName.trimmingCharacters(in: .whitespaces)

        switch selection {
        case .secureEnclave:
            generateSecureEnclaveKey(name: trimmedName, authRequirement: authRequirement)
        case .software(let keyType):
            generateSoftwareKey(
                name: trimmedName,
                keyType: keyType,
                storageLevel: storageLevel,
                authRequirement: authRequirement
            )
        }
    }

    private func generateSecureEnclaveKey(name: String, authRequirement: KeyAuthRequirement) {
        isGenerating = true
        generationTask = Task {
            defer { isGenerating = false }
            do {
                // Enclave key generation does not prompt (the biometric gate
                // is evaluated only when the key is later used to sign), so
                // this returns immediately on the MainActor.
                let key = try sshKeyManager.createSecureEnclaveKey(name: name, authRequirement: authRequirement)
                Self.logger.info("Generated Secure Enclave key: \(key.name)")
                generatedSecureEnclaveKey = key
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
                Self.logger.error("Secure Enclave key generation failed: \(error.localizedDescription)")
            }
        }
    }

    private func generateSoftwareKey(
        name: String,
        keyType: GenerateKeyType,
        storageLevel: KeyStorageLevel,
        authRequirement: KeyAuthRequirement
    ) {
        isGenerating = true

        generationTask = Task {
            defer { isGenerating = false }

            // Generate off the main actor — RSA at 3072/4096 bits takes
            // multiple seconds and would freeze the spinner / Cancel
            // button on @MainActor. BoringSSL's keygen is not
            // cancellable, so a mid-generation Cancel waits for RSA to
            // finish, then drops the result via the isCancelled check
            // below without importing the key.
            let generated: GeneratedSSHKey
            do {
                generated = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyGenerator.generate(type: keyType, comment: name)
                }.value
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
                Self.logger.error("SSH key generation failed: \(error.localizedDescription)")
                return
            }

            if Task.isCancelled {
                Self.logger.info("SSH key generation cancelled before import")
                return
            }

            do {
                let importedKey = try sshKeyManager.importKey(
                    name: name,
                    keyString: generated.privateKeyPEM,
                    passphrase: nil,
                    storageLevel: storageLevel,
                    authRequirement: authRequirement
                )
                Self.logger.info("Successfully generated SSH key: \(importedKey.name) (\(importedKey.keyType.displayName))")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
                Self.logger.error("Failed to import generated SSH key: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    SSHKeyGenerateView()
}

/// A small "Hardware" capsule used to flag the Secure Enclave option.
private struct HardwarePill: View {
    var body: some View {
        Text("Hardware")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.indigo.opacity(0.15)))
            .foregroundStyle(.indigo)
    }
}

/// Grouped key-type chooser: a Hardware-Protected section (Secure Enclave,
/// shown only when available) and a Software section (Ed25519 / ECDSA / RSA).
private struct SSHKeyTypeSelectionList: View {
    @Binding var selection: KeyProtectionSelection
    let secureEnclaveAvailable: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            if secureEnclaveAvailable {
                Section {
                    Button {
                        selection = .secureEnclave
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(.indigo)
                                .font(.title3)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Secure Enclave P-256")
                                        .foregroundStyle(.primary)
                                    HardwarePill()
                                }
                                Text("Private key never leaves this device. P-256 only.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection.isSecureEnclave {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Hardware-Protected")
                }
            }

            Section {
                ForEach(GenerateKeyType.allCases.filter { $0.isAvailable && !$0.isExperimental }, id: \.self) { type in
                    keyTypeRow(type)
                }
            } header: {
                Text("Software")
            } footer: {
                Text("Software keys are stored encrypted in the Keychain and can be included in backups or synced with iCloud.")
            }

            Section {
                ForEach(GenerateKeyType.allCases.filter { $0.isAvailable && $0.isExperimental }, id: \.self) { type in
                    keyTypeRow(type)
                }
            } header: {
                Text("Post-Quantum (Experimental)")
            } footer: {
                Text("Pure ML-DSA keys are NOT accepted by standard OpenSSH servers today — only experimental builds with ML-DSA support. For post-quantum protection with regular servers, use ML-DSA-44 + Ed25519 from the Software section instead.")
            }
        }
        .themedList()
        .navigationTitle("Key Type")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func keyTypeRow(_ type: GenerateKeyType) -> some View {
        Button {
            selection = .software(type)
            dismiss()
        } label: {
            HStack {
                Image(systemName: type.isExperimental ? "flask.fill" : "key.fill")
                    .foregroundStyle(type.isExperimental ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                Text(type.displayName)
                    .foregroundStyle(.primary)
                if type.isExperimental {
                    ExperimentalPill()
                }
                Spacer()
                if selection.softwareType == type {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .themedRow()
    }
}

private struct ExperimentalPill: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .foregroundStyle(.orange)
    }
}

/// Result sheet shown after a Secure Enclave key is created. The public key
/// (authorized_keys line) is the only exportable artifact — the private key
/// can never be read.
private struct GeneratedSecureEnclaveKeyResultView: View {
    let key: SSHKey
    let onDone: () -> Void

    @State private var publicKeyLine: String = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Key created in the Secure Enclave")
                                .font(.subheadline.bold())
                            Text("The private key never leaves this device. Install the public key below on your server to use it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .themedRow()
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Public Key (authorized_keys)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = publicKeyLine
                                copied = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    Text(copied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy", comment: "Copy button"))
                                }
                                .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(copied ? .green : .blue)
                            .disabled(publicKeyLine.isEmpty)
                        }
                        Text(publicKeyLine.isEmpty ? "…" : publicKeyLine)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                } footer: {
                    Text("Type ecdsa-sha2-nistp256 — a standard key your SSH server already understands.")
                }

                Section("Fingerprint") {
                    Text(key.colonFormattedFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .themedRow()
                }
            }
            .themedList()
            .navigationTitle("Secure Enclave Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .task {
                publicKeyLine = (try? SSHPublicKeyFormatter.authorizedKeysLine(for: key, comment: key.name)) ?? ""
            }
        }
    }
}
