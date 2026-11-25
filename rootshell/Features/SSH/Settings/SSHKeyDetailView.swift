import SwiftUI

struct SSHKeyDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var sshKeyManager = SSHKeyManager.shared

    let key: SSHKey

    @State private var showingDeleteConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingSecuritySettings = false

    // Public key display
    @State private var publicKeyString: String = ""
    @State private var isLoadingPublicKey = true
    @State private var showingInstallInstructions = false

    // Rename functionality
    @State private var showingRenameAlert = false
    @State private var newKeyName = ""

    // Install on server
    @State private var showingCopyIDSheet = false

    // Legacy key unlock
    @State private var showingUnlockAlert = false
    @State private var unlockPassphrase = ""
    @State private var isUnlocking = false

    // OpenPGP public key export
    @State private var showingGPGExportSheet = false

    // User certificate
    @State private var showingCertImport = false
    @State private var showingCertRemoveConfirmation = false
    @State private var certificateCopied = false

    #if targetEnvironment(macCatalyst) && STANDALONE
    // External agent availability probe
    @State private var isCheckingAgentAvailability = false
    @State private var agentAvailability: (ok: Bool, message: String)?
    #endif

    var body: some View {
        List {
            // Key info section
            Section("Key Information") {
                Button(action: {
                    newKeyName = currentKey.name
                    showingRenameAlert = true
                }) {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text(currentKey.name)
                            .foregroundColor(.secondary)
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .foregroundColor(.primary)
                .themedRow()
                LabeledRow(label: "Type", value: currentKey.keyType.displayName)
                    .themedRow()
                if currentKey.externalAgentInfo != nil {
                    LabeledRow(label: "Algorithm", value: currentKey.effectiveSSHKeyTypeString)
                        .themedRow()
                }
                if currentKey.secureEnclaveInfo != nil {
                    HStack {
                        Label("Protection", systemImage: "lock.shield.fill")
                        Spacer()
                        Text("Secure Enclave")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
                if currentKey.isPasskey {
                    HStack {
                        Label("Protection", systemImage: "person.badge.key.fill")
                        Spacer()
                        Text("Passkey")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
                LabeledRow(label: "Created", value: formattedDate)
                    .themedRow()
                if isSoftwareKey {
                    HStack {
                        Text("Key Material")
                        Spacer()
                        if keyNeedsUnlock {
                            Label("Unlock Required", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        } else {
                            Text(currentKey.hasPassphrase ? "Migration Pending" : "Keychain Protected")
                                .foregroundColor(.secondary)
                        }
                    }
                    .themedRow()
                    if keyNeedsUnlock {
                        Button {
                            unlockPassphrase = ""
                            showingUnlockAlert = true
                        } label: {
                            Label("Unlock Legacy Key", systemImage: "lock.open")
                        }
                        .disabled(isUnlocking)
                        .themedRow()
                    }
                }
            }

            // Fingerprint section
            Section("Fingerprint") {
                CopyableValueBlock(
                    title: "SHA256",
                    value: key.colonFormattedFingerprint,
                    copyText: "SHA256:\(key.colonFormattedFingerprint)"
                )
                .themedRow()
            }

            // Public Key section
            Section("Public Key") {
                if isLoadingPublicKey {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading public key...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                } else {
                    CopyableValueBlock(
                        title: String(localized: "OpenSSH Format", comment: "Public key format label"),
                        value: publicKeyString,
                        isCopyDisabled: publicKeyString.isEmpty || publicKeyString.hasPrefix("#")
                    )
                    .themedRow()
                }
            }

            // OpenPubkey / Smallstep identity section
            if currentKey.hasManagedCertificate {
                ManagedCertificateSection(key: currentKey)
            }

            // External agent section
            #if targetEnvironment(macCatalyst) && STANDALONE
            if let agentInfo = currentKey.externalAgentInfo {
                Section {
                    LabeledRow(
                        label: String(localized: "Agent", comment: "Agent key field: agent name"),
                        value: ExternalSSHAgentRegistry.shared.agent(for: agentInfo, publicKeyBlob: currentKey.publicKeyBlob)?.name
                            ?? String(localized: "Removed agent", comment: "Agent key field: agent entry no longer exists")
                    )
                    .themedRow()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Socket", comment: "Agent key field: socket path"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(ExternalSSHAgentRegistry.shared.resolveSocketPath(for: agentInfo, publicKeyBlob: currentKey.publicKeyBlob))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .themedRow()

                    if !agentInfo.comment.isEmpty {
                        LabeledRow(
                            label: String(localized: "Comment", comment: "Agent key field: agent-reported comment"),
                            value: agentInfo.comment
                        )
                        .themedRow()
                    }

                    Button(action: checkAgentAvailability) {
                        HStack {
                            Label(
                                String(localized: "Check Availability", comment: "Agent key: probe the agent for this key"),
                                systemImage: "checkmark.circle"
                            )
                            Spacer()
                            if isCheckingAgentAvailability {
                                ProgressView()
                            } else if let agentAvailability {
                                Text(agentAvailability.message)
                                    .font(.caption)
                                    .foregroundColor(agentAvailability.ok ? .green : .red)
                            }
                        }
                    }
                    .disabled(isCheckingAgentAvailability)
                    .themedRow()
                } header: {
                    Text(String(localized: "SSH Agent", comment: "Agent key section header"))
                } footer: {
                    Text(String(
                        localized: "This key lives in the agent; rootshell only keeps the public half. The agent may ask you to approve each signature, and the key only works on this Mac while the agent is running.",
                        comment: "Agent key section footer"
                    ))
                }
            }
            #endif

            // Certificate section
            Section {
                if let cert = currentKey.userCertificate {
                    certificateStatusRow(for: cert, autoRenewed: currentKey.hasManagedCertificate)
                        .themedRow()

                    LabeledRow(label: String(localized: "Key ID", comment: "Cert field: CA-assigned identity"), value: cert.keyID)
                        .themedRow()
                    LabeledRow(label: String(localized: "Serial", comment: "Cert field: serial number"), value: "\(cert.serial)")
                        .themedRow()
                    LabeledRow(
                        label: String(localized: "Principals", comment: "Cert field: valid usernames"),
                        value: cert.validPrincipals.isEmpty
                            ? String(localized: "Any user", comment: "Cert principals: unrestricted")
                            : cert.validPrincipals.joined(separator: ", ")
                    )
                    .themedRow()
                    LabeledRow(label: String(localized: "Valid From", comment: "Cert field: validity start"), value: SSHUserCertificateFormatting.validFrom(cert))
                        .themedRow()
                    LabeledRow(label: String(localized: "Valid Until", comment: "Cert field: validity end"), value: SSHUserCertificateFormatting.validUntil(cert))
                        .themedRow()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Certificate Authority")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(cert.caKeyType)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button {
                                UIPasteboard.general.string = cert.caFingerprint
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(cert.caFingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .themedRow()

                    Button(action: copyCertificate) {
                        HStack(spacing: 4) {
                            Image(systemName: certificateCopied ? "checkmark" : "doc.on.doc")
                            Text(certificateCopied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy Certificate", comment: "Cert detail: copy button"))
                        }
                    }
                    .themedRow()

                    // OpenPubkey and Smallstep certificates are managed by the section
                    // above (renew / re-login); manual replace or remove
                    // would orphan the identity.
                    if !currentKey.hasManagedCertificate {
                        Button(action: { showingCertImport = true }) {
                            Label("Replace Certificate…", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .themedRow()

                        Button(role: .destructive, action: { showingCertRemoveConfirmation = true }) {
                            Label("Remove Certificate", systemImage: "xmark.seal")
                        }
                        .themedRow()
                    }
                } else {
                    Button(action: { showingCertImport = true }) {
                        Label("Add Certificate", systemImage: "checkmark.seal")
                    }
                    .themedRow()
                }
            } header: {
                Text("Certificate")
            } footer: {
                if currentKey.userCertificate == nil {
                    Text("Attach an OpenSSH user certificate (-cert.pub) issued for this key by a certificate authority. The certificate is offered first when connecting; servers configured with TrustedUserCAKeys accept it without an authorized_keys entry.")
                }
            }

            // Installation Instructions section
            Section {
                DisclosureGroup("How to Use This Key", isExpanded: $showingInstallInstructions) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("1. Copy the public key above")
                            .font(.subheadline)

                        Text("2. Add it to the remote server's authorized_keys file:")
                            .font(.subheadline)

                        Text("~/.ssh/authorized_keys")
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(6)

                        Text("3. Make sure the file has correct permissions:")
                            .font(.subheadline)

                        Text("chmod 600 ~/.ssh/authorized_keys\nchmod 700 ~/.ssh")
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(6)

                        Text("4. If the .ssh directory doesn't exist:")
                            .font(.subheadline)

                        Text("mkdir -p ~/.ssh && chmod 700 ~/.ssh")
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(6)
                    }
                    .padding(.vertical, 8)
                }
                .themedRow()
            }

            // Install on Server section
            Section {
                Button(action: { showingCopyIDSheet = true }) {
                    Label("Install on Server", systemImage: "arrow.up.doc")
                }
                .disabled(publicKeyString.isEmpty || publicKeyString.hasPrefix("#"))
                .themedRow()
            } footer: {
                Text("Securely copy this key to a remote server's authorized_keys file")
            }

            // OpenPGP Public Key Export — only meaningful for keys
            // whose algorithm has a cached GPG keygrip (i.e. keys
            // SSHKeyGPGBridge can sign with). Hardware keys and
            // software Ed25519/ECDSA-P256/RSA qualify; FIDO2 keys
            // never will.
            if let keygripHex = currentKey.gpgKeygripHex {
                Section {
                    Button(action: { showingGPGExportSheet = true }) {
                        Label("Export OpenPGP Public Key", systemImage: "lock.shield")
                    }
                    .themedRow()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Keygrip")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = keygripHex
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                        Text(keygripHex)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .themedRow()
                } footer: {
                    Text("Generate an ASCII-armored OpenPGP public key block so the remote can `gpg --import` it. Without this, forwarded GPG signing requests have no key to sign with on the remote side.\n\nThe keygrip above is what we tell the remote `gpg-agent` we can sign for. It MUST match the output of `gpg --with-keygrip --list-keys <fingerprint>` on the remote after import; a mismatch means `gpg` won't recognize the agent-held secret.")
                }
            }

            // Default keys section
            Section {
                Toggle("Include in Default Keys", isOn: Binding(
                    get: { sshKeyManager.isDefault(id: key.id) },
                    set: { enabled in
                        if enabled {
                            sshKeyManager.addToDefaults(id: key.id)
                        } else {
                            sshKeyManager.removeFromDefaults(id: key.id)
                        }
                    }
                ))
                .themedRow()

                if sshKeyManager.isDefault(id: key.id),
                   let priority = sshKeyManager.defaultPriority(for: key.id) {
                    HStack {
                        Text("Priority")
                        Spacer()
                        Text("\(priority + 1) of \(sshKeyManager.defaultKeyIDs.count)")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()

                    NavigationLink("Manage Default Keys Order") {
                        DefaultKeysOrderView()
                    }
                    .themedRow()
                }
            } footer: {
                if defaultKeyAttemptCount > 6 {
                    Text("Warning: SSH servers typically allow only 6 authentication attempts, and a key with a certificate uses two (certificate, then plain key). Consider removing some default keys.")
                        .foregroundColor(.orange)
                } else {
                    Text("Default keys are tried in order when connecting following the selected key")
                }
            }

            // Security section
            Section("Security") {
                // Storage level
                if currentKey.isPasskey {
                    HStack {
                        Label("Storage", systemImage: "person.badge.key.fill")
                        Spacer()
                        Text("Passkey Provider")
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                } else {
                    HStack {
                        Label("Storage", systemImage: currentKey.storageLevel.iconName)
                        Spacer()
                        Text(currentKey.storageLevel.displayName)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                // Authentication requirement
                HStack {
                    Label("Authentication", systemImage: currentKey.authRequirement.iconName)
                    Spacer()
                    Text(currentKey.authRequirement.displayName)
                        .foregroundColor(.secondary)
                }
                .themedRow()

                // Last modified date if available
                if let modifiedDate = currentKey.securityModifiedDate {
                    HStack {
                        Text("Last Modified")
                        Spacer()
                        Text(formatDate(modifiedDate))
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }

                // Change security settings. Secure Enclave keys bake their
                // biometric/passcode gate into the enclave key at creation
                // time (it is immutable), so editing it after the fact would
                // desync metadata from real behavior — hide the control and
                // explain instead.
                if currentKey.isPasskey {
                    Text("The passkey and its per-use verification are managed by your passkey provider (iCloud Keychain or a third-party manager like 1Password). Its private key cannot be viewed, exported, or reconfigured by rootshell.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                } else if currentKey.externalAgentInfo != nil {
                    Text("This key is served by an SSH agent on this Mac. It stays on this device and its security is managed by the agent, so storage and authentication settings can't be changed here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                } else if currentKey.secureEnclaveInfo == nil {
                    Button(action: {
                        showingSecuritySettings = true
                    }) {
                        HStack {
                            Image(systemName: "shield.checkerboard")
                            Text("Change Security Settings")
                        }
                    }
                    .themedRow()
                } else {
                    Text("This key is generated in and bound to this device's Secure Enclave. Its protection cannot be exported, backed up, synced, or changed after creation.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            }

            // Delete section
            Section {
                Button(role: .destructive, action: {
                    showingDeleteConfirmation = true
                }) {
                    HStack {
                        Spacer()
                        Text("Delete Key")
                        Spacer()
                    }
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("SSH Key Details")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Key", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteKey()
            }
        } message: {
            if currentKey.isPasskey {
                Text(
                    "This removes '\(currentKey.name)' from rootshell on your synced devices. The passkey itself remains in your passkey provider (Passwords, 1Password, etc.) until you delete it there."
                )
            } else {
                Text("Are you sure you want to delete the key '\(currentKey.name)'? This cannot be undone.")
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showingSecuritySettings) {
            SSHKeySecuritySettingsView(key: currentKey)
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingCopyIDSheet) {
            SSHCopyIDView(key: currentKey)
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingGPGExportSheet) {
            SSHKeyGPGExportSheet(key: currentKey)
                .themedSubSheet(sheetThemeColors)
        }
        .navigationDestination(isPresented: $showingCertImport) {
            SSHUserCertificateImportView(targetKey: currentKey, embedInNavigationStack: false)
        }
        .alert("Remove Certificate", isPresented: $showingCertRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                sshKeyManager.removeUserCertificate(keyID: key.id)
            }
        } message: {
            Text("Remove the certificate from '\(currentKey.name)'? The key itself is not affected; connections will use the plain key.")
        }
        .alert("Unlock Legacy Key", isPresented: $showingUnlockAlert) {
            SecureField("Passphrase", text: $unlockPassphrase)
            Button("Cancel", role: .cancel) {
                unlockPassphrase = ""
            }
            Button("Unlock") {
                unlockLegacyKey()
            }
        } message: {
            Text("This key was imported with a passphrase on another device. Enter it once to decrypt the key; it will then be protected by the Keychain and won't need the passphrase again.")
        }
        .alert("Rename Key", isPresented: $showingRenameAlert) {
            TextField("Key name", text: $newKeyName)
            Button("Cancel", role: .cancel) {
                newKeyName = ""
            }
            Button("Rename") {
                renameKey()
            }
        } message: {
            Text("Enter a new name for this SSH key.")
        }
        .onAppear {
            loadPublicKey()
        }
        #if targetEnvironment(macCatalyst) && STANDALONE
        .task {
            // Makes the Agent/Socket rows show the verified socket.
            await ExternalSSHAgentRegistry.shared.verifyAgent(forKeyID: key.id)
        }
        #endif
    }

    // MARK: - Computed Properties

    /// Get the current state of the key from the manager (to reflect any updates)
    private var currentKey: SSHKey {
        sshKeyManager.findKey(id: key.id) ?? key
    }

    private var isDefault: Bool {
        sshKeyManager.isDefault(id: key.id)
    }

    /// Keys backed by software material in the Keychain (not hardware/agent references)
    private var isSoftwareKey: Bool {
        currentKey.yubiKeyInfo == nil &&
        currentKey.appleFIDO2Info == nil &&
        currentKey.secureEnclaveInfo == nil &&
        currentKey.externalAgentInfo == nil
    }

    private var keyNeedsUnlock: Bool {
        sshKeyManager.keysNeedingUnlock.contains(key.id)
    }

    private func unlockLegacyKey() {
        let passphrase = unlockPassphrase
        unlockPassphrase = ""
        guard !passphrase.isEmpty else { return }
        isUnlocking = true
        Task {
            defer { isUnlocking = false }
            do {
                try await sshKeyManager.unlockLegacyKey(id: key.id, passphrase: passphrase)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    /// Server auth attempts the default keys consume: certified keys count twice
    /// (certificate offer, then plain-key fallback).
    private var defaultKeyAttemptCount: Int {
        sshKeyManager.defaultKeyIDs.reduce(0) { total, id in
            total + (sshKeyManager.findKey(id: id)?.userCertificate != nil ? 2 : 1)
        }
    }

    private var formattedDate: String {
        formatDate(key.createdDate)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Actions

    #if targetEnvironment(macCatalyst) && STANDALONE
    private func checkAgentAvailability() {
        guard let agentInfo = currentKey.externalAgentInfo,
              let publicKeyBlob = currentKey.publicKeyBlob else { return }

        isCheckingAgentAvailability = true
        agentAvailability = nil
        Task {
            defer { isCheckingAgentAvailability = false }
            let registry = ExternalSSHAgentRegistry.shared
            // Explicit check: bypass cached results so an agent that just
            // came back is seen now.
            await registry.verifyAgent(for: agentInfo, publicKeyBlob: publicKeyBlob, force: true)
            let socketPath = registry.resolveSocketPath(for: agentInfo, publicKeyBlob: publicKeyBlob)
            let result: (ok: Bool, message: String) = await Task.detached(priority: .userInitiated) {
                do {
                    let identities = try ExternalSSHAgentClient(socketPath: socketPath).listIdentities()
                    if identities.contains(where: { $0.publicKeyBlob == publicKeyBlob }) {
                        return (true, String(localized: "Available", comment: "Agent key availability: key present"))
                    }
                    return (false, String(localized: "Not in agent", comment: "Agent key availability: key missing"))
                } catch {
                    return (false, error.localizedDescription)
                }
            }.value
            agentAvailability = result
        }
    }
    #endif

    private func loadPublicKey() {
        isLoadingPublicKey = true

        Task {
            do {
                let line = try SSHPublicKeyFormatter.authorizedKeysLine(for: currentKey)

                await MainActor.run {
                    publicKeyString = line
                    isLoadingPublicKey = false
                }
            } catch {
                await MainActor.run {
                    publicKeyString = "# Unable to load public key: \(error.localizedDescription)"
                    isLoadingPublicKey = false
                }
            }
        }
    }

    private func copyCertificate() {
        guard let cert = currentKey.userCertificate else { return }
        UIPasteboard.general.string = cert.exportLine(fallbackComment: currentKey.name)
        certificateCopied = true

        // Reset the copied state after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            certificateCopied = false
        }
    }

    private func deleteKey() {
        do {
            try sshKeyManager.deleteKey(id: key.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func renameKey() {
        let trimmedName = newKeyName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            errorMessage = "Key name cannot be empty"
            showingError = true
            return
        }

        sshKeyManager.updateKeyName(id: key.id, newName: trimmedName)
        newKeyName = ""
    }
}

// MARK: - Helper Views

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    NavigationView {
        SSHKeyDetailView(
            key: SSHKey(
                name: "Work Server",
                keyType: .ed25519,
                fingerprint: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2",
                hasPassphrase: true
            )
        )
    }
}
