//
//  ImportKeyToYubiKeyView.swift
//  rootshell
//
//  UI for importing existing SSH keys from Keychain to YubiKey PIV slots
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI

/// View for importing an existing SSH key from Keychain to a YubiKey PIV slot
struct ImportKeyToYubiKeyView: View {
    let onImported: (YubiKeyKeyImporter.ImportResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    var connectionManager = YubiKeyConnectionManager.shared
    @ObservedObject private var keyManager = SSHKeyManager.shared

    @State private var selectedKeyID: UUID?
    @State private var selectedSlot: PIVSlot = .authentication
    @State private var deleteAfterImport: Bool = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var showingOverwriteWarning = false
    /// YubiKey and slot named by the overwrite confirmation.
    @State private var confirmedTarget: YubiKeyWriteTarget?
    /// The import in flight, cancelled when the sheet goes away so one still
    /// waiting for the key never writes after the sheet is dismissed.
    @State private var importTask: Task<Void, Never>?
    @State private var validation: YubiKeyKeyImporter.ImportValidation?

    private let importer = YubiKeyKeyImporter()

    /// Filtered list of keys that can be imported
    private var importableKeys: [SSHKey] {
        importer.getImportableKeys()
    }

    /// Currently selected key
    private var selectedKey: SSHKey? {
        guard let id = selectedKeyID else { return nil }
        return keyManager.findKey(id: id)
    }

    var body: some View {
        NavigationStack {
            Form {
                // Key Selection Section
                Section {
                    if importableKeys.isEmpty {
                        Text("No software keys available for import")
                            .foregroundStyle(.secondary)
                            .themedRow()
                    } else {
                        Picker("Select Key", selection: $selectedKeyID) {
                            Text("Select a key...").tag(nil as UUID?)
                            ForEach(importableKeys) { key in
                                HStack {
                                    Text(key.name)
                                    Spacer()
                                    Text(key.keyType.shortName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(key.id as UUID?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .themedRow()
                    }
                } header: {
                    Text("Source Key")
                } footer: {
                    if importableKeys.isEmpty {
                        Text("Import software SSH keys first, then you can move them to your YubiKey.")
                    } else {
                        Text("Select an existing software key to import to your YubiKey.")
                    }
                }

                // Selected Key Details
                if let key = selectedKey {
                    Section {
                        LabeledContent("Name", value: key.name)
                            .themedRow()
                        LabeledContent("Type", value: key.keyType.displayName)
                            .themedRow()
                        LabeledContent("Fingerprint") {
                            Text(key.formattedFingerprint)
                                .font(.caption)
                                .fontDesign(.monospaced)
                        }
                        .themedRow()
                    } header: {
                        Text("Key Details")
                    }

                    // Validation Warnings
                    if let validation = validation, !validation.warnings.isEmpty {
                        Section {
                            ForEach(validation.warnings, id: \.self) { warning in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(warning)
                                        .font(.subheadline)
                                }
                                .themedRow()
                            }
                        } header: {
                            Text("Warnings")
                        }
                    }
                }

                // Target Slot Section
                Section {
                    Picker("PIV Slot", selection: $selectedSlot) {
                        ForEach(PIVSlot.allCases, id: \.self) { slot in
                            Text(slot.displayName).tag(slot)
                        }
                    }
                    .themedRow()
                } header: {
                    Text("Target Slot")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The key will be stored in this PIV slot on your YubiKey.")
                        if selectedSlot == .signature {
                            Text("Note: Digital Signature slot (9c) always requires PIN for every signing operation.")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                // Options Section
                Section {
                    Toggle("Delete from Keychain after import", isOn: $deleteAfterImport)
                        .themedRow()
                } header: {
                    Text("Options")
                } footer: {
                    if deleteAfterImport {
                        Text("The software key will be permanently deleted from this device after successful import to YubiKey.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Keep a copy of the key in the iOS Keychain as backup.")
                    }
                }

                // Connection Status
                Section {
                    HStack {
                        Circle()
                            .fill(connectionManager.connectionState.isConnected ? Color.green : Color.gray)
                            .frame(width: 12, height: 12)
                        Text(connectionStatusText)
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                } header: {
                    Text("YubiKey Status")
                } footer: {
                    if !canReachKey {
                        Text("Connect your YubiKey before importing.")
                    } else if readOverNFCOnly {
                        Text("Private keys can't be imported over NFC, where the transfer isn't encrypted. Connect this YubiKey with USB-C to import.")
                    }
                }

                // Import Summary
                if selectedKey != nil && canReachKey {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundStyle(.blue)
                                Text("Import \"\(selectedKey?.name ?? "")\"")
                            }
                            HStack {
                                Image(systemName: "sdcard.fill")
                                    .foregroundStyle(.orange)
                                Text("To YubiKey slot \(selectedSlot.shortName)")
                            }
                            if deleteAfterImport {
                                HStack {
                                    Image(systemName: "trash.fill")
                                        .foregroundStyle(.red)
                                    Text("Delete software copy after import")
                                }
                            }
                        }
                        .font(.subheadline)
                        .themedRow()
                    } header: {
                        Text("Summary")
                    }
                }
            }
            .themedList()
            .navigationTitle("Import to YubiKey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        confirmImport()
                    }
                    .disabled(!canImport)
                }
            }
            .onChange(of: selectedKeyID) { _, newValue in
                if let id = newValue, let key = keyManager.findKey(id: id) {
                    validation = importer.canImport(key: key)
                } else {
                    validation = nil
                }
            }
            .alert("Overwrite Existing Key?", isPresented: $showingOverwriteWarning, presenting: confirmedTarget) { target in
                Button("Cancel", role: .cancel) {}
                Button("Import", role: .destructive) {
                    performImport(to: target)
                }
            } message: { target in
                Text("If a key already exists in \(target.slot.displayName) on YubiKey \(String(target.serial)), it will be permanently replaced. The private key will move from software storage to your YubiKey hardware.")
            }
            .alert("Import Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? String(localized: "Unknown error", comment: "Generic error fallback message"))
            }
            .overlay {
                if isImporting {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Importing key to YubiKey...")
                            .font(.headline)
                        Text("This may take a moment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(32)
                    .background(.regularMaterial)
                    .cornerRadius(16)
                }
            }
        }
        .onDisappear {
            importTask?.cancel()
        }
    }

    private var connectionStatusText: String {
        switch connectionManager.connectionState {
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
            return String(localized: "Busy...", comment: "YubiKey connection status")
        case .error(let msg):
            return String(localized: "Error: \(msg)", comment: "YubiKey connection status")
        }
    }

    /// Connected now, or read earlier. Import reconnects on demand, wired only.
    private var canReachKey: Bool {
        connectionManager.connectionState.isConnected || connectionManager.lastReadDevice != nil
    }

    /// The key was read over NFC and no wired connection is up.
    private var readOverNFCOnly: Bool {
        !connectionManager.connectionState.isConnected && connectionManager.lastReadDevice?.method == .nfc
    }

    private var canImport: Bool {
        selectedKeyID != nil &&
        canReachKey &&
        validation?.canImport == true &&
        !isImporting
    }

    /// Name the YubiKey and slot in the overwrite confirmation; the import is
    /// then bound to both.
    private func confirmImport() {
        do {
            confirmedTarget = YubiKeyWriteTarget(
                serial: try connectionManager.confirmableSerial(),
                slot: selectedSlot
            )
            showingOverwriteWarning = true
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func performImport(to target: YubiKeyWriteTarget) {
        guard let keyID = selectedKeyID else { return }

        isImporting = true

        importTask = Task {
            // Held for the whole import, so no other operation shares the connection.
            guard await connectionManager.beginExclusiveUse(preemptingPendingConnect: true) else {
                // The sheet was dismissed while this was queued.
                isImporting = false
                return
            }
            defer { connectionManager.endExclusiveUse() }

            do {
                try Task.checkCancellation()
                // Connect with the wired transport chosen here, so an import
                // never opens an NFC session. Any NFC session that is up belongs
                // to another operation and is left alone.
                let transport = try await importer.requireWiredTransport()
                try await connectionManager.connect(preferredMethod: transport)

                // Last point where a dismissed sheet stops the import: nothing
                // has been written or deleted yet.
                try Task.checkCancellation()

                // The write itself runs in its own task, which dismissal does not
                // cancel: stopping midway could leave the slot holding a key
                // without its certificate.
                let deleteSoftwareCopy = deleteAfterImport
                let result = try await Task {
                    try await importer.importKey(
                        keyID: keyID,
                        target: target,
                        deleteFromKeychain: deleteSoftwareCopy
                    )
                }.value

                isImporting = false
                onImported(result)
                dismiss()

            } catch {
                isImporting = false
                // No alert for an import the user dismissed.
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}

// MARK: - Import Result View

/// View shown after successful import
struct ImportKeyResultView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let result: YubiKeyKeyImporter.ImportResult
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

                        Text("Key Imported Successfully")
                            .font(.headline)

                        Text("Your key is now stored on the YubiKey hardware. The private key cannot be extracted.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .themedRow()
                }

                Section {
                    LabeledContent("Name", value: result.yubiKeySSHKey.name)
                        .themedRow()
                    if let info = result.yubiKeySSHKey.yubiKeyInfo {
                        LabeledContent("Algorithm", value: info.algorithm.displayName)
                            .themedRow()
                        if let slot = info.pivSlot {
                            LabeledContent("PIV Slot", value: slot.displayName)
                                .themedRow()
                        }
                        LabeledContent("YubiKey Serial", value: String(info.serialNumber))
                            .themedRow()
                    }
                    LabeledContent("Fingerprint") {
                        Text(formatFingerprint(result.fingerprint))
                            .font(.caption)
                            .fontDesign(.monospaced)
                    }
                    .themedRow()
                } header: {
                    Text("Key Details")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.publicKeyString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                    }
                    .themedRow()

                    Button {
                        UIPasteboard.general.string = result.publicKeyString
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
                    Text("Public Key")
                } footer: {
                    Text("Add this to your server's authorized_keys file if needed.")
                }
            }
            .themedList()
            .navigationTitle("Import Complete")
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

#Preview {
    ImportKeyToYubiKeyView { _ in }
}
