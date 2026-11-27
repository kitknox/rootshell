import SwiftUI

struct SSHKeyManagementView: View {
    @StateObject private var sshKeyManager = SSHKeyManager.shared
    @State private var showingImport = false
    @State private var showingCertImportSheet = false
    @State private var showingGenerate = false
    @State private var showingOpenPubkeySignIn = false
    @State private var showingStepCASignIn = false
    @State private var showingDeleteConfirmation = false
    @State private var showingPasskeySheet = false
    #if !os(visionOS)
    @State private var showingFIDO2KeySheet = false
    #endif
    #if targetEnvironment(macCatalyst) && STANDALONE
    @State private var showingExternalAgents = false
    #endif
    @State private var keyToDelete: SSHKey?
    @State private var showingError = false
    @State private var errorMessage = ""

    @State private var headerPuff = 0

    var body: some View {
        List {
            Section {
                SSHKeysHeaderView(
                    keyCount: sshKeyManager.savedKeys.count,
                    puffTrigger: headerPuff
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .onChange(of: sshKeyManager.savedKeys.count) { old, new in
                if new > old { headerPuff += 1 }
            }

            if !sshKeyManager.savedKeys.isEmpty {
                Section {
                    ForEach(sshKeyManager.savedKeys) { key in
                        NavigationLink {
                            SSHKeyDetailView(key: key)
                        } label: {
                            SSHKeyRow(
                                key: key,
                                defaultPriority: sshKeyManager.defaultPriority(for: key.id),
                                needsUnlock: sshKeyManager.keysNeedingUnlock.contains(key.id)
                            )
                        }
                    }.onDelete(perform: deleteKeys).themedRow()
                }
            }

            // YubiKey Section
            Section {
                NavigationLink {
                    YubiKeyManagementView()
                } label: {
                    HStack {
                        Image(systemName: "key.viewfinder").foregroundStyle(.orange)
                        Text("YubiKey")
                        Spacer()
                        let yubiKeyCount = sshKeyManager.savedKeys.filter { $0.yubiKeyInfo != nil }.count
                        if yubiKeyCount > 0 { Text("\(yubiKeyCount) keys").foregroundColor(.secondary).font(.subheadline) }
                    }
                }.themedRow()
            } header: {
                Text("Hardware Keys")
            } footer: {
                Text("Manage YubiKey hardware security keys for SSH authentication").font(.caption)
            }
        }.themedList().refreshable {
            await sshKeyManager.refreshKeysAsync()
            headerPuff += 1
        }.navigationTitle("SSH Keys").navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: { showingGenerate = true }) { Label("Generate New Key", systemImage: "wand.and.stars") }

                    Button(action: { showingImport = true }) { Label("Import Existing Key", systemImage: "square.and.arrow.down") }

                    Button(action: { showingCertImportSheet = true }) { Label("Import Certificate", systemImage: "checkmark.seal") }

                    Button(action: { showingOpenPubkeySignIn = true }) { Label("Sign In with OpenPubkey", systemImage: "person.badge.key") }

                    Button(action: { showingStepCASignIn = true }) { Label("Sign In with Smallstep", systemImage: "checkmark.shield") }

                    #if targetEnvironment(macCatalyst) && STANDALONE
                    Button(action: { showingExternalAgents = true }) { Label("Import from SSH Agent", systemImage: "key.radiowaves.forward") }
                    #endif

                    Divider()

                    Button(action: { showingPasskeySheet = true }) { Label("Passkey", systemImage: "person.badge.key.fill") }

                    #if !os(visionOS)
                    Button(action: { showingFIDO2KeySheet = true }) { Label("FIDO2 Security Key", systemImage: "key.viewfinder") }
                    #endif
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showingImport) {
            SSHKeyImportView()
        }
        .navigationDestination(isPresented: $showingCertImportSheet) {
            SSHUserCertificateImportView(targetKey: nil, embedInNavigationStack: false)
        }
        .navigationDestination(isPresented: $showingGenerate) {
            SSHKeyGenerateView()
        }
        .navigationDestination(isPresented: $showingOpenPubkeySignIn) {
            OpenPubkeySignInView(embedInNavigationStack: false)
        }
        .navigationDestination(isPresented: $showingStepCASignIn) {
            StepCASignInView(embedInNavigationStack: false)
        }
        #if targetEnvironment(macCatalyst) && STANDALONE
        .navigationDestination(isPresented: $showingExternalAgents) { ExternalSSHAgentsView() }
        #endif
        .navigationDestination(isPresented: $showingPasskeySheet) {
            GenerateAppleFIDO2KeyView(backing: .platformPasskey)
        }
        #if !os(visionOS)
        .navigationDestination(isPresented: $showingFIDO2KeySheet) {
            GenerateAppleFIDO2KeyView(backing: .securityKey)
        }
        #endif
        .alert("Delete Key", isPresented: $showingDeleteConfirmation, presenting: keyToDelete) { key in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteKey(key)
            }
        } message: { key in
            if key.isPasskey {
                Text("This removes '\(key.name)' from rootshell on your synced devices. The passkey itself remains in your passkey provider (Passwords, 1Password, etc.) until you delete it there.")
            } else {
                Text("Are you sure you want to delete the key '\(key.name)'? This cannot be undone.")
            }
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func deleteKeys(at offsets: IndexSet) {
        for index in offsets {
            let key = sshKeyManager.savedKeys[index]
            keyToDelete = key
            showingDeleteConfirmation = true
        }
    }

    private func deleteKey(_ key: SSHKey) {
        do { try sshKeyManager.deleteKey(id: key.id) } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

// MARK: - SSH Key Row

struct SSHKeyRow: View {
    let key: SSHKey
    /// Priority in the default keys list (0 = highest priority, nil = not a default)
    let defaultPriority: Int?
    /// Legacy-encrypted key that needs a one-time manual unlock on this device
    let needsUnlock: Bool

    /// Fixed width for badge alignment (accommodates "ED25519")
    private static let badgeWidth: CGFloat = 62

    /// Backward-compatible initializer
    init(key: SSHKey, isDefault: Bool) {
        self.key = key
        self.defaultPriority = isDefault ? 0 : nil
        self.needsUnlock = false
    }

    init(key: SSHKey, defaultPriority: Int?, needsUnlock: Bool = false) {
        self.key = key
        self.defaultPriority = defaultPriority
        self.needsUnlock = needsUnlock
    }

    var body: some View {
        HStack(spacing: 12) {
            // Key type badge with fixed width for alignment
            Text(key.keyType.shortName).font(.caption.bold()).foregroundStyle(keyTypeColor).frame(width: Self.badgeWidth).padding(.vertical, 4).background(
                keyTypeColor.opacity(0.18)
            ).cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.name).font(.body).lineLimit(1)

                    if let priority = defaultPriority {
                        // Show priority badge for default keys
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill").font(.caption2)
                            if priority > 0 { Text("\(priority + 1)").font(.caption2.bold()) }
                        }.foregroundColor(.yellow).padding(.horizontal, 4).padding(.vertical, 2).background(Color.yellow.opacity(0.2)).cornerRadius(4)
                    }

                    if key.hasManagedCertificate, let expiry = key.managedCertificateExpiry {
                        // OpenPubkey / Smallstep badge: colored by how soon the app
                        // must renew (OpenPubkey: ID token expiry; step-ca: cert expiry).
                        let expired = expiry.timeIntervalSinceNow <= 0
                        Image(systemName: expired ? "person.badge.key.fill" : "person.badge.key").font(.caption2).foregroundColor(
                            managedCertificateBadgeColor(expiry)
                        ).padding(.horizontal, 4).padding(.vertical, 2).background(managedCertificateBadgeColor(expiry).opacity(0.2)).cornerRadius(4)
                    } else if let cert = key.userCertificate {
                        // Certificate badge: green valid, orange expiring soon, red expired
                        Image(systemName: cert.isExpired ? "xmark.seal.fill" : "checkmark.seal.fill").font(.caption2).foregroundColor(
                            certificateBadgeColor(cert)
                        ).padding(.horizontal, 4).padding(.vertical, 2).background(certificateBadgeColor(cert).opacity(0.2)).cornerRadius(4)
                    }

                    if needsUnlock {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundColor(.orange).padding(
                            .horizontal, 4
                        ).padding(.vertical, 2).background(Color.orange.opacity(0.2)).cornerRadius(4)
                    }
                }

                // Fingerprint with middle truncation to show both ends
                Text("SHA256:\(key.fingerprint)").font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)

                // Created date
                Text(key.createdDate, format: .dateTime.month(.abbreviated).day().year()).font(.caption2).foregroundStyle(.tertiary)
            }

            Spacer()
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private var keyTypeColor: Color {
        switch key.keyType {
        case .rsa: return .red
        case .ed25519: return .blue
        case .ecdsaP256: return .green
        case .ecdsaP384: return .orange
        case .ecdsaP521: return .purple
        case .yubiKeyPIV: return .yellow
        case .yubiKeyFIDO2: return .cyan
        case .appleFIDO2: return .teal
        case .applePasskey: return .blue
        case .secureEnclaveP256: return .indigo
        case .externalAgent: return .mint
        case .mldsa44Ed25519, .mldsa44, .mldsa65, .mldsa87: return .pink
        }
    }

    private func certificateBadgeColor(_ cert: SSHUserCertificateInfo) -> Color {
        if cert.isExpired { return .red }
        if cert.isExpiringSoon || cert.isNotYetValid { return .orange }
        return .green
    }

    private func managedCertificateBadgeColor(_ expiry: Date) -> Color {
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 { return .red }
        if remaining < 3600 { return .orange }
        return .green
    }
}

#Preview { NavigationView { SSHKeyManagementView() } }
