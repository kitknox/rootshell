//
//  YubiKeyManagementView.swift
//  rootshell
//
//  UI for managing YubiKey hardware security keys
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// View for managing YubiKey PIV hardware security keys
/// Note: FIDO2 keys are managed via Apple AuthenticationServices (Settings > SSH Keys > FIDO2 Security Key)
struct YubiKeyManagementView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    var connectionManager = YubiKeyConnectionManager.shared
    @ObservedObject private var keyManager = SSHKeyManager.shared

    @State private var isDiscovering = false
    @State private var discoveredKeys: [DiscoveredYubiKeyKey] = []
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingPINPrompt = false
    @State private var pinInput = ""
    @State private var selectedTransport: YubiKeyConnectionMethod?
    @State private var showingGenerateSheet = false
    @State private var generatedKey: GeneratedYubiKeyKey?
    @State private var showingGeneratedKeySheet = false
    @State private var showingPINChangeSheet = false
    @State private var isChangingPIN = false
    @State private var showingDeleteConfirmation = false
    @State private var keyToDelete: DiscoveredYubiKeyKey?
    @State private var isDeletingKey = false
    @State private var showingImportSheet = false
    @State private var importResult: YubiKeyKeyImporter.ImportResult?
    @State private var showingImportResultSheet = false
    @State private var discoverTask: Task<Void, Never>?

    var body: some View {
        List {
            // Connection Status Section
            Section {
                connectionStatusRow
                    .themedRow()
            } header: {
                Text("YubiKey Status")
            }

            // Available Transports
            Section {
                ForEach(Array(connectionManager.availableTransports), id: \.self) { transport in
                    let isConnectingThis = connectionManager.connectionState.connectingTransport == transport
                    Button {
                        if isConnectingThis {
                            cancelConnect()
                        } else {
                            selectedTransport = transport
                            connectAndDiscover(preferredMethod: transport)
                        }
                    } label: {
                        HStack {
                            Label(transport.displayName, systemImage: transport.iconName)
                            Spacer()
                            if isConnectingThis {
                                ProgressView()
                            }
                        }
                    }
                    .accessibilityHint(isConnectingThis ? Text("Tap to cancel") : Text(""))
                    .themedRow()
                }
            } header: {
                Text("Connect via")
            } footer: {
                if let transport = connectionManager.connectionState.connectingTransport {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waiting for YubiKey... Tap the highlighted transport again to cancel.")
                        if transport == .usbc {
                            Text("Already plugged in? The key's smart card (PIV) interface may be turned off for USB. Turn it on in Yubico Authenticator, or run `ykman config usb --enable PIV`.")
                        }
                    }
                }
            }

            // Discovered Keys
            if !listedKeys.isEmpty {
                Section {
                    ForEach(listedKeys) { key in
                        DiscoveredKeyRow(key: key) { name in
                            importKey(key, name: name)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                keyToDelete = key
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Keys on YubiKey")
                } footer: {
                    Text("Swipe left on a key to delete it from the YubiKey.")
                }
            }

            // PIV Actions. Over NFC each action opens its own session, so they
            // stay available after the discovery session has ended.
            if canRunPIVActions {
                Section {
                    Button {
                        showingGenerateSheet = true
                    } label: {
                        Label("Generate PIV Key", systemImage: "plus.circle")
                    }
                    .themedRow()

                    Button {
                        showingImportSheet = true
                    } label: {
                        Label("Import Key from Keychain", systemImage: "square.and.arrow.down")
                    }
                    .themedRow()

                    Button {
                        showingPINChangeSheet = true
                    } label: {
                        Label("Change PIV PIN", systemImage: "lock.rotation")
                    }
                    .disabled(isChangingPIN)
                    .themedRow()

                    Button {
                        if connectionManager.connectionState.isConnected {
                            discoverKeys()
                        } else {
                            connectAndDiscover()
                        }
                    } label: {
                        Label("Refresh PIV Keys", systemImage: "arrow.clockwise")
                    }
                    .disabled(isDiscovering)
                    .themedRow()
                } header: {
                    Text("PIV Actions")
                } footer: {
                    Text("PIV keys use slots and require a 6-8 digit PIN.")
                }
            }

            // Disconnect
            if case .connected = connectionManager.connectionState {
                Section {
                    Button(role: .destructive) {
                        connectionManager.disconnect()
                        discoveredKeys = []
                    } label: {
                        Label("Disconnect", systemImage: "eject")
                    }
                    .themedRow()
                }
            }

            // Registered YubiKey Keys
            let yubiKeyKeys = keyManager.savedKeys.filter { $0.yubiKeyInfo != nil }
            if !yubiKeyKeys.isEmpty {
                Section {
                    ForEach(yubiKeyKeys) { key in
                        YubiKeyKeyRow(key: key)
                            .themedRow()
                    }
                    .onDelete { indexSet in
                        deleteKeys(at: indexSet, from: yubiKeyKeys)
                    }
                } header: {
                    Text("Registered YubiKey Keys")
                } footer: {
                    Text("These keys reference your YubiKey hardware. The actual private keys never leave the device.")
                }
            }
        }
        .themedList()
        .navigationTitle("YubiKey")
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error", comment: "Generic error fallback message"))
        }
        .sheet(isPresented: $showingPINPrompt) {
            if let request = connectionManager.pendingPINRequest {
                YubiKeyPINPromptView(request: request) { pin in
                    connectionManager.completePINRequest(with: pin)
                    showingPINPrompt = false
                } onCancel: {
                    connectionManager.completePINRequest(with: nil)
                    showingPINPrompt = false
                }
                .themedSubSheet(sheetThemeColors)
            }
        }
        .onChange(of: connectionManager.pendingPINRequest) { _, newValue in
            showingPINPrompt = newValue != nil
        }
        .sheet(isPresented: $showingGenerateSheet) {
            GenerateYubiKeyKeyView { generated, discovered in
                generatedKey = generated
                showingGenerateSheet = false
                showingGeneratedKeySheet = true
                showKeyInSlot(discovered)
            }
            .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingGeneratedKeySheet) {
            if let key = generatedKey {
                GeneratedKeyResultView(key: key) {
                    showingGeneratedKeySheet = false
                    generatedKey = nil
                }
                .themedSubSheet(sheetThemeColors)
            }
        }
        .sheet(isPresented: $showingPINChangeSheet) {
            YubiKeyPINChangeView { oldPIN, newPIN in
                showingPINChangeSheet = false
                changePIN(oldPIN: oldPIN, newPIN: newPIN)
            } onCancel: {
                showingPINChangeSheet = false
            }
            .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingImportSheet) {
            ImportKeyToYubiKeyView { result in
                importResult = result
                showingImportSheet = false
                showingImportResultSheet = true
                let key = result.yubiKeySSHKey
                if let info = key.yubiKeyInfo, let blob = key.publicKeyBlob {
                    showKeyInSlot(DiscoveredYubiKeyKey(
                        yubiKeySerial: info.serialNumber,
                        slot: info.pivSlot,
                        algorithm: info.algorithm,
                        publicKeyData: blob,
                        fingerprint: key.fingerprint,
                        requiresPIN: info.pivSlot?.requiresPIN ?? true
                    ))
                }
            }
            .themedSubSheet(sheetThemeColors)
        }
        .sheet(isPresented: $showingImportResultSheet) {
            if let result = importResult {
                ImportKeyResultView(result: result) {
                    showingImportResultSheet = false
                    importResult = nil
                }
                .themedSubSheet(sheetThemeColors)
            }
        }
        .alert("Delete Key from YubiKey?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                keyToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let key = keyToDelete {
                    deleteKeyFromYubiKey(key)
                }
                keyToDelete = nil
            }
        } message: {
            if let key = keyToDelete {
                Text("This will permanently delete the key from \(key.slot?.displayName ?? "this slot"). This cannot be undone.")
            } else {
                Text("This will permanently delete the key from the YubiKey. This cannot be undone.")
            }
        }
        .overlay {
            if isChangingPIN || isDeletingKey {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(overlayMessage)
                        .font(.headline)
                }
                .padding(32)
                .background(.regularMaterial)
                .cornerRadius(16)
            }
        }
        .onChange(of: connectionManager.connectionState) { oldState, newState in
            // Auto-discover keys when YubiKey connects spontaneously via USB-C/Lightning.
            // NFC connects only for an explicit action, which owns the session.
            if case .connected(_, let method) = newState, method != .nfc, !oldState.isConnected {
                // Only auto-discover if we're not already discovering (e.g., from connectAndDiscover)
                if !isDiscovering && discoveredKeys.isEmpty {
                    discoverKeys()
                }
            }
        }
        .onAppear {
            // Auto-discover if YubiKey is already connected when view loads
            if connectionManager.connectionState.isConnected && !isDiscovering && discoveredKeys.isEmpty {
                discoverKeys()
            }
        }
        .onDisappear {
            // Don't leave a wired connect attempt polling after the user leaves
            // this screen — the SDK's USBSmartCardConnection() loop would
            // otherwise keep running until the (now long) wired timeout fires.
            if connectionManager.connectionState.connectingTransport != nil {
                connectionManager.cancelPendingConnection()
            }
            discoverTask?.cancel()
            discoverTask = nil
        }
    }

    /// Rows for the key shown in the status section. A later tap with another
    /// YubiKey must not leave the first key's slots listed under it.
    private var listedKeys: [DiscoveredYubiKeyKey] {
        guard let serial = connectionManager.lastReadDevice?.serial else { return discoveredKeys }
        return discoveredKeys.filter { $0.yubiKeySerial == serial }
    }

    private var canRunPIVActions: Bool {
        switch connectionManager.connectionState {
        case .connected:
            return true
        case .disconnected, .error:
            return connectionManager.lastReadDevice != nil
        case .connecting, .waitingForDevice, .authenticating, .signing:
            return false
        }
    }

    @ViewBuilder
    private var connectionStatusRow: some View {
        if !connectionManager.connectionState.isBusy,
           !connectionManager.connectionState.isConnected,
           let device = connectionManager.lastReadDevice, device.method == .nfc {
            // NFC sessions end after each operation; show what was read.
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                    Text("Read via NFC")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isDiscovering {
                        ProgressView()
                    }
                }

                Divider()

                LabeledContent("Model", value: device.formFactor.displayName)
                LabeledContent("Firmware", value: device.firmwareVersion)
                LabeledContent("Serial", value: String(device.serial))

                Text("Actions below ask you to hold the key to your iPhone again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if case .connected(let serial, let method) = connectionManager.connectionState {
            // Expanded status view when connected
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                    Text("Connected")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isDiscovering {
                        ProgressView()
                    }
                }

                Divider()

                if let formFactor = connectionManager.connectedFormFactor {
                    LabeledContent("Model", value: formFactor.displayName)
                }

                if let firmware = connectionManager.connectedFirmwareVersion {
                    LabeledContent("Firmware", value: firmware)
                }

                LabeledContent("Serial", value: String(serial))

                LabeledContent("Connection", value: method.displayName)
            }
        } else {
            // Simple status row when not connected
            HStack {
                Circle()
                    .fill(connectionManager.connectionState.statusColor)
                    .frame(width: 12, height: 12)

                Text(connectionManager.connectionState.displayString)
                    .foregroundStyle(.secondary)

                Spacer()

                if isDiscovering {
                    ProgressView()
                }
            }
        }
    }

    private func connectAndDiscover(preferredMethod: YubiKeyConnectionMethod? = nil) {
        // If a previous attempt is still running, cancel it before starting a new one.
        // The connection manager also cancels its in-flight wired attempt, but
        // dropping the view-side Task here keeps isDiscovering accurate.
        discoverTask?.cancel()

        isDiscovering = true
        discoveredKeys = []

        discoverTask = Task {
            defer { isDiscovering = false }
            do {
                try await connectionManager.connect(preferredMethod: preferredMethod)
                try Task.checkCancellation()
                try await discoverKeysAsync()
                // Close NFC session when done (safe to call for non-NFC connections)
                #if os(iOS) && !os(visionOS)
                if case .connected(_, .nfc) = connectionManager.connectionState {
                    await connectionManager.closeNFCSession(withMessage: "Done. Remove your YubiKey.")
                }
                #endif
            } catch {
                // Don't show an alert for explicit cancellations — the user
                // either tapped to cancel or moved to another transport.
                if let yk = error as? YubiKeyError, case .userCancelled = yk {
                    // suppress
                } else if error is CancellationError {
                    // suppress
                } else {
                    errorMessage = error.localizedDescription
                    showingError = true
                }
                // Close NFC with error message if applicable
                #if os(iOS) && !os(visionOS)
                if case .connected(_, .nfc) = connectionManager.connectionState {
                    await connectionManager.closeNFCSession(withError: error.localizedDescription)
                }
                #endif
            }
        }
    }

    private func cancelConnect() {
        connectionManager.cancelPendingConnection()
        discoverTask?.cancel()
        isDiscovering = false
    }

    /// Show a key just written to a slot without reading the YubiKey again:
    /// over NFC the operation's session has already ended. Rows listed from
    /// another YubiKey are dropped; the write may have used a different key.
    private func showKeyInSlot(_ key: DiscoveredYubiKeyKey) {
        discoveredKeys.removeAll { $0.slot == key.slot || $0.yubiKeySerial != key.yubiKeySerial }
        discoveredKeys.append(key)
        discoveredKeys.sort { ($0.slot?.rawValue ?? "") < ($1.slot?.rawValue ?? "") }
    }

    private func discoverKeys() {
        isDiscovering = true

        Task {
            defer { isDiscovering = false }
            do {
                try await discoverKeysAsync()
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func discoverKeysAsync() async throws {
        guard case .connected(let serial, _) = connectionManager.connectionState else {
            throw YubiKeyError.notConnected
        }

        let discovery = YubiKeyKeyDiscovery()

        // Discover PIV keys (pass serial so it's captured in discovered keys)
        let pivKeys = try await discovery.discoverPIVKeys(yubiKeySerial: serial)
        discoveredKeys = pivKeys
    }

    private func importKey(_ key: DiscoveredYubiKeyKey, name: String) {
        Task {
            do {
                let discovery = YubiKeyKeyDiscovery()
                // Use serial from discovered key (captured during discovery)
                // so import works even after NFC session is closed
                _ = try discovery.importKey(key, name: name, yubiKeySerial: key.yubiKeySerial)

                // Remove from discovered list
                discoveredKeys.removeAll { $0.id == key.id }

            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func deleteKeys(at indexSet: IndexSet, from keys: [SSHKey]) {
        for index in indexSet {
            let key = keys[index]
            do {
                try keyManager.deleteKey(id: key.id)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func changePIN(oldPIN: String, newPIN: String) {
        isChangingPIN = true

        Task {
            defer { isChangingPIN = false }

            do {
                let signer = YubiKeySigner.shared
                try await signer.changePIN(oldPIN: oldPIN, newPIN: newPIN)
                // PIN changed successfully - no need to show additional UI
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func deleteKeyFromYubiKey(_ key: DiscoveredYubiKeyKey) {
        guard let slot = key.slot else {
            errorMessage = "Cannot delete this key - no PIV slot specified"
            showingError = true
            return
        }

        isDeletingKey = true

        Task {
            defer { isDeletingKey = false }

            do {
                let slotManager = YubiKeySlotManager()
                try await slotManager.deleteKey(in: slot, expectedSerial: key.yubiKeySerial)

                // Remove from discovered keys list
                discoveredKeys.removeAll { $0.id == key.id }

                // Also remove from SSHKeyManager if imported
                // Find any SSHKey that references this slot and serial
                let matchingKeys = keyManager.savedKeys.filter { sshKey in
                    guard let info = sshKey.yubiKeyInfo else { return false }
                    return info.serialNumber == key.yubiKeySerial && info.pivSlot == slot
                }

                for matchingKey in matchingKeys {
                    try? keyManager.deleteKey(id: matchingKey.id)
                }
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    // MARK: - Helper Properties

    private var overlayMessage: String {
        if isChangingPIN { return "Changing PIV PIN..." }
        if isDeletingKey { return "Deleting key..." }
        return "Working..."
    }
}

// MARK: - Supporting Views

struct DiscoveredKeyRow: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let key: DiscoveredYubiKeyKey
    let onImport: (String) -> Void

    @State private var keyName: String = ""
    @State private var showingImportSheet = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(key.suggestedName)
                    .font(.body)
                HStack(spacing: 4) {
                    Text(key.algorithm.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                    if key.requiresPIN {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button("Import") {
                showingImportSheet = true
            }
            .buttonStyle(.bordered)
        }
        .sheet(isPresented: $showingImportSheet) {
            NavigationStack {
                Form {
                    TextField("Key Name", text: $keyName)
                        .themedRow()

                    Section {
                        LabeledContent("Algorithm", value: key.algorithm.displayName)
                            .themedRow()
                        if let slot = key.slot {
                            LabeledContent("PIV Slot", value: slot.displayName)
                                .themedRow()
                        }
                        LabeledContent("Fingerprint") {
                            Text(formatFingerprint(key.fingerprint))
                                .font(.caption)
                                .fontDesign(.monospaced)
                        }
                        .themedRow()
                        LabeledContent("Requires PIN", value: key.requiresPIN ? "Yes" : "No")
                            .themedRow()
                    }
                }
                .themedList()
                .onAppear {
                    keyName = key.suggestedName
                }
                .navigationTitle("Import Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingImportSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") {
                            onImport(keyName)
                            showingImportSheet = false
                        }
                        .disabled(keyName.isEmpty)
                    }
                }
            }
            .presentationDetents([.medium])
            .themedSubSheet(sheetThemeColors)
        }
    }

    private func formatFingerprint(_ fingerprint: String) -> String {
        // Format as colon-separated pairs
        var result = ""
        for (index, char) in fingerprint.prefix(32).enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return result.uppercased() + "..."
    }
}

struct YubiKeyKeyRow: View {
    let key: SSHKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.viewfinder")
                .font(.title2)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(key.name)
                    .font(.body)

                HStack(spacing: 4) {
                    if let info = key.yubiKeyInfo {
                        Text(info.algorithm.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let slot = info.pivSlot {
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(slot.shortName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("SN: \(info.serialNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
    }
}

// MARK: - Generate Key View

struct GenerateYubiKeyKeyView: View {
    let onGenerated: (GeneratedYubiKeyKey, DiscoveredYubiKeyKey) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    var connectionManager = YubiKeyConnectionManager.shared

    @State private var selectedSlot: PIVSlot = .authentication
    @State private var selectedAlgorithm: YubiKeyAlgorithm = .ecdsaP256
    @State private var keyName: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingOverwriteWarning = false
    /// Generation will reach the key over NFC, where RSA-4096 never completes.
    @State private var willUseNFC = false

    // Ed25519 needs firmware 5.7+, ML-DSA 6.0+. ML-DSA stays listed while the
    // firmware is unknown; generation rejects it on older keys.
    private var supportedAlgorithms: [YubiKeyAlgorithm] {
        var classic: [YubiKeyAlgorithm] = [.ecdsaP256, .ecdsaP384, .ed25519, .rsa2048, .rsa4096]
        if willUseNFC { classic.removeAll { $0 == .rsa4096 } }
        if let major = connectionManager.lastReadDevice?.firmwareMajor, major < 6 { return classic }
        return classic + [.mldsa44, .mldsa65, .mldsa87]
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("PIV Slot", selection: $selectedSlot) {
                        ForEach(PIVSlot.allCases, id: \.self) { slot in
                            Text(slot.displayName).tag(slot)
                        }
                    }
                    .themedRow()

                    Picker("Algorithm", selection: $selectedAlgorithm) {
                        ForEach(supportedAlgorithms, id: \.self) { algo in
                            Text(algo.displayName).tag(algo)
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Key Settings")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The private key will be generated on the YubiKey and never leaves the device.")
                        if willUseNFC {
                            Text("RSA-4096 isn't offered over NFC because the YubiKey can't finish generating it on NFC power. Connect it with USB-C to generate one.")
                        }
                        if selectedAlgorithm == .ed25519 {
                            Text("Note: Ed25519 requires YubiKey firmware 5.7 or later.")
                                .foregroundStyle(.orange)
                        }
                        if selectedAlgorithm.isPostQuantum {
                            Text("Note: ML-DSA requires YubiKey firmware 6.0 or later, and the server must accept \(selectedAlgorithm.sshKeyTypeString) keys.")
                                .foregroundStyle(.orange)
                        }
                        if selectedSlot == .signature {
                            Text("Note: Digital Signature slot (9c) always requires PIN for signing.")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    TextField("Key Name", text: $keyName)
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    Text("A friendly name to identify this key in SSH connections.")
                }

                Section {
                    HStack {
                        Text("Slot")
                        Spacer()
                        Text(selectedSlot.shortName)
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                    HStack {
                        Text("Algorithm")
                        Spacer()
                        Text(selectedAlgorithm.sshKeyTypeString)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .themedRow()
                } header: {
                    Text("Summary")
                }
            }
            .themedList()
            .task {
                willUseNFC = await connectionManager.willUseNFC()
                if !supportedAlgorithms.contains(selectedAlgorithm) {
                    selectedAlgorithm = .ecdsaP256
                }
            }
            .navigationTitle("Generate YubiKey Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") {
                        showingOverwriteWarning = true
                    }
                    .disabled(keyName.isEmpty || isGenerating)
                }
            }
            .alert("Overwrite Existing Key?", isPresented: $showingOverwriteWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Generate", role: .destructive) {
                    generateKey()
                }
            } message: {
                Text("If a key already exists in \(selectedSlot.displayName), it will be permanently replaced. This cannot be undone.")
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? String(localized: "Unknown error", comment: "Generic error fallback message"))
            }
            .overlay {
                if isGenerating {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Generating key on YubiKey...")
                            .font(.headline)
                        Text("This may take a moment for RSA keys")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(.regularMaterial)
                    .cornerRadius(16)
                }
            }
        }
    }

    private func generateKey() {
        isGenerating = true

        Task {
            do {
                // NFC sessions end after each operation; reconnect on demand.
                try await connectionManager.connect()
                guard case .connected(let serial, _) = connectionManager.connectionState else {
                    throw YubiKeyError.notConnected
                }

                let generator = YubiKeyKeyGenerator()
                let generated: GeneratedYubiKeyKey
                do {
                    generated = try await generator.generateKey(
                        in: selectedSlot,
                        algorithm: selectedAlgorithm,
                        name: keyName
                    )
                } catch {
                    #if os(iOS) && !os(visionOS)
                    if case .connected(_, .nfc) = connectionManager.connectionState {
                        await connectionManager.closeNFCSession(withError: error.localizedDescription)
                    }
                    #endif
                    throw error
                }
                #if os(iOS) && !os(visionOS)
                if case .connected(_, .nfc) = connectionManager.connectionState {
                    await connectionManager.closeNFCSession(withMessage: "Key generated. Remove your YubiKey.")
                }
                #endif

                // Import the key automatically
                let discovery = YubiKeyKeyDiscovery()
                let discoveredKey = DiscoveredYubiKeyKey(
                    yubiKeySerial: serial,
                    slot: selectedSlot,
                    algorithm: selectedAlgorithm,
                    publicKeyData: generated.publicKeyData,
                    fingerprint: generated.fingerprint,
                    requiresPIN: selectedSlot.requiresPIN
                )
                _ = try discovery.importKey(discoveredKey, name: keyName, yubiKeySerial: serial)

                onGenerated(generated, discoveredKey)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
            isGenerating = false
        }
    }
}

// MARK: - Generated Key Result View

struct GeneratedKeyResultView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let key: GeneratedYubiKeyKey
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.green)

                        Text("Key Generated Successfully")
                            .font(.headline)

                        Text("Add the public key below to your server's authorized_keys file.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .themedRow()
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.sshPublicKeyString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                    }
                    .themedRow()

                    Button {
                        UIPasteboard.general.string = key.sshPublicKeyString
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    } label: {
                        HStack {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? String(localized: "Copied!", comment: "Copy button state: copied") : String(localized: "Copy Public Key", comment: "Copy public key button"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .themedRow()
                } header: {
                    Text("Public Key (for authorized_keys)")
                }

                Section {
                    LabeledContent("Slot", value: key.slot.displayName)
                        .themedRow()
                    LabeledContent("Algorithm", value: key.algorithm.displayName)
                        .themedRow()
                    LabeledContent("Fingerprint") {
                        Text(formatFingerprint(key.fingerprint))
                            .font(.caption)
                            .fontDesign(.monospaced)
                    }
                    .themedRow()
                } header: {
                    Text("Key Details")
                }
            }
            .themedList()
            .navigationTitle("Key Generated")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }

    private func formatFingerprint(_ fingerprint: String) -> String {
        var result = ""
        for (index, char) in fingerprint.prefix(32).enumerated() {
            if index > 0 && index % 2 == 0 {
                result += ":"
            }
            result.append(char)
        }
        return "SHA256:" + result.uppercased()
    }
}

// MARK: - State Extensions

extension YubiKeyConnectionState {
    var statusColor: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting, .waitingForDevice: return .orange
        case .connected: return .green
        case .authenticating, .signing: return .blue
        case .error: return .red
        }
    }

    var displayString: String {
        switch self {
        case .disconnected:
            return String(localized: "Not Connected", comment: "YubiKey connection status")
        case .connecting(let method):
            return String(localized: "Connecting via \(method.displayName)...", comment: "YubiKey connection status")
        case .waitingForDevice(let transport):
            return String(localized: "Insert your \(transport.displayName) YubiKey...", comment: "YubiKey connection status")
        case .connected(let serial, let method):
            return String(localized: "Connected (SN: \(serial)) via \(method.displayName)", comment: "YubiKey connection status")
        case .authenticating:
            return String(localized: "Authenticating...", comment: "YubiKey connection status")
        case .signing:
            return String(localized: "Signing...", comment: "YubiKey connection status")
        case .error(let msg):
            return String(localized: "Error: \(msg)", comment: "YubiKey connection status")
        }
    }
}

#Preview {
    NavigationStack {
        YubiKeyManagementView()
    }
}
