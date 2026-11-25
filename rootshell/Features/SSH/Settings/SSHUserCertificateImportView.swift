//
//  SSHUserCertificateImportView.swift
//  rootshell
//
//  Imports an OpenSSH user certificate (-cert.pub) and attaches it to a saved
//  SSH key. Two modes: from a key's detail view (targetKey set, the cert must
//  match that key) or global (targetKey nil, the matching key is auto-located
//  from the certificate's embedded public key).
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI
import UniformTypeIdentifiers
import os.log

struct SSHUserCertificateImportView: View {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "SSHCertImport")

    @Environment(\.dismiss) var dismiss
    @StateObject private var sshKeyManager = SSHKeyManager.shared

    /// When set, the certificate must certify this key. When nil, the owning
    /// key is located automatically from the embedded public key.
    let targetKey: SSHKey?
    var embedInNavigationStack = true

    @State private var importMethod: ImportMethod = .paste
    @State private var pastedCertText = ""
    @State private var showingFilePicker = false
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var showingReplaceConfirmation = false

    /// Parse state, refreshed live as the input changes.
    @State private var parsed: ParsedUserCertificate?
    @State private var parseError: String?
    /// The key the parsed certificate belongs to (target key or auto-located).
    @State private var resolvedKey: SSHKey?

    enum ImportMethod: String, CaseIterable {
        case paste, file

        var displayName: String {
            switch self {
            case .paste: return String(localized: "Paste", comment: "Cert import method: paste")
            case .file: return String(localized: "File", comment: "Cert import method: file")
            }
        }
    }

    var body: some View {
        if embedInNavigationStack {
            NavigationStack {
                content
            }
        } else {
            content
        }
    }

    private var content: some View {
        Form {
            // Import method picker
            Section {
                Picker("Import Method", selection: $importMethod) {
                    ForEach(ImportMethod.allCases, id: \.self) { method in
                        Text(method.displayName).tag(method)
                    }
                }
                .pickerStyle(.segmented)
                .themedRow()
            }

            if importMethod == .paste {
                Section {
                    TextEditor(text: $pastedCertText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                } header: {
                    Text("Certificate")
                } footer: {
                    Text("Paste the contents of the -cert.pub file issued by your certificate authority (one line starting with the certificate type, e.g. ssh-ed25519-cert-v01@openssh.com).")
                }
            } else {
                Section {
                    Button(action: { showingFilePicker = true }) {
                        HStack {
                            Image(systemName: "doc.fill")
                            Text("Select Certificate File")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .themedRow()

                    if !pastedCertText.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("File loaded")
                                .foregroundColor(.secondary)
                        }
                        .themedRow()
                    }
                } header: {
                    Text("Certificate File")
                } footer: {
                    Text("Select the -cert.pub file produced by ssh-keygen -s")
                }
            }

            // Live parse result
            if let parseError, !pastedCertText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(parseError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .themedRow()
                }
            }

            if let parsed {
                certificatePreviewSection(parsed)
            }

            // Import button
            Section {
                Button(action: attemptSave) {
                    HStack {
                        Spacer()
                        Label(replaceMode ? String(localized: "Replace Certificate", comment: "Cert import: replace button") : String(localized: "Attach Certificate", comment: "Cert import: attach button"), systemImage: "checkmark.seal")
                        Spacer()
                    }
                }
                .disabled(parsed == nil || resolvedKey == nil)
                .themedRow()
            } footer: {
                if replaceMode {
                    Text("This key already has a certificate. Attaching a new one replaces it.")
                }
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle(targetKey == nil ? String(localized: "Import Certificate", comment: "Cert import: global title") : String(localized: "Add Certificate", comment: "Cert import: per-key title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if embedInNavigationStack {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result: result)
        }
        .alert("Import Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Replace Certificate", isPresented: $showingReplaceConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Replace", role: .destructive) {
                save()
            }
        } message: {
            if let resolvedKey, let existing = resolvedKey.userCertificate {
                Text("'\(resolvedKey.name)' already has certificate '\(existing.keyID)' (serial \(existing.serial)). Replace it?")
            }
        }
        .onChange(of: pastedCertText) { _, _ in
            reparse()
        }
    }

    // MARK: - Preview section

    @ViewBuilder
    private func certificatePreviewSection(_ parsed: ParsedUserCertificate) -> some View {
        Section {
            // Which key this certifies
            if let resolvedKey {
                HStack {
                    Label("Certifies Key", systemImage: "key.fill")
                    Spacer()
                    Text(resolvedKey.name)
                        .foregroundColor(.secondary)
                }
                .themedRow()
            }

            certificateStatusRow(for: parsed.info)
                .themedRow()

            LabeledRow(label: String(localized: "Key ID", comment: "Cert field: CA-assigned identity"), value: parsed.info.keyID)
                .themedRow()
            LabeledRow(label: String(localized: "Serial", comment: "Cert field: serial number"), value: "\(parsed.info.serial)")
                .themedRow()
            LabeledRow(
                label: String(localized: "Principals", comment: "Cert field: valid usernames"),
                value: parsed.info.validPrincipals.isEmpty
                    ? String(localized: "Any user", comment: "Cert principals: unrestricted")
                    : parsed.info.validPrincipals.joined(separator: ", ")
            )
            .themedRow()
            LabeledRow(label: String(localized: "Valid From", comment: "Cert field: validity start"), value: SSHUserCertificateFormatting.validFrom(parsed.info))
                .themedRow()
            LabeledRow(label: String(localized: "Valid Until", comment: "Cert field: validity end"), value: SSHUserCertificateFormatting.validUntil(parsed.info))
                .themedRow()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Certificate Authority")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(parsed.info.caKeyType)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(parsed.info.caFingerprint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .themedRow()
        } header: {
            Text("Certificate Details")
        }
    }

    // MARK: - Computed

    private var replaceMode: Bool {
        resolvedKey?.userCertificate != nil
    }

    // MARK: - Actions

    private func reparse() {
        let text = pastedCertText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            parsed = nil
            parseError = nil
            resolvedKey = nil
            return
        }

        do {
            let result = try SSHUserCertificateParser.parse(line: text)

            if let targetKey {
                // Detail-view mode: the cert must match the target key.
                guard let cachedBlob = targetKey.publicKeyBlob,
                      SSHUserCertificateParser.normalizedCachedBlob(cachedBlob) == result.embeddedPublicKeyBlob else {
                    // Identify the actual owner for a helpful message.
                    if let owner = sshKeyManager.findKey(forCertificateEmbeddedBlob: result.embeddedPublicKeyBlob) {
                        parseError = String(localized: "This certificate belongs to '\(owner.name)', not '\(targetKey.name)'. Open that key's details to attach it there.", comment: "Cert import error: belongs to another key")
                    } else {
                        parseError = SSHUserCertificateImportError.keyMismatch(expectedKeyName: targetKey.name).localizedDescription
                    }
                    parsed = nil
                    resolvedKey = nil
                    return
                }
                parsed = result
                parseError = nil
                resolvedKey = sshKeyManager.findKey(id: targetKey.id) ?? targetKey
            } else {
                // Global mode: locate the owning key.
                guard let owner = sshKeyManager.findKey(forCertificateEmbeddedBlob: result.embeddedPublicKeyBlob) else {
                    let described = SSHUserCertificateParser.embeddedKeyDescription(for: result.certifiedKey)
                    parseError = SSHUserCertificateImportError.noMatchingKey(
                        embeddedKeyType: described.keyType,
                        embeddedFingerprint: described.fingerprint
                    ).localizedDescription
                    parsed = nil
                    resolvedKey = nil
                    return
                }
                parsed = result
                parseError = nil
                resolvedKey = owner
            }
        } catch let error as SSHUserCertificateImportError {
            parsed = nil
            resolvedKey = nil
            parseError = error.localizedDescription
        } catch {
            parsed = nil
            resolvedKey = nil
            parseError = error.localizedDescription
        }
    }

    private func attemptSave() {
        guard replaceMode else {
            save()
            return
        }
        showingReplaceConfirmation = true
    }

    private func save() {
        guard let parsed, let resolvedKey else { return }
        do {
            try sshKeyManager.attachUserCertificate(keyID: resolvedKey.id, parsed: parsed)
            Self.logger.info("Attached certificate to key: \(resolvedKey.name)")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = String(localized: "Unable to access the file", comment: "Cert import: file access error")
                showingError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                pastedCertText = try String(contentsOf: url, encoding: .utf8)
            } catch {
                errorMessage = String(localized: "Failed to read file: \(error.localizedDescription)", comment: "Cert import: file read error")
                showingError = true
            }

        case .failure(let error):
            errorMessage = String(localized: "File selection failed: \(error.localizedDescription)", comment: "Cert import: file picker error")
            showingError = true
        }
    }
}

// MARK: - Shared formatting + status row

/// Display helpers shared by the import preview and the key detail view.
enum SSHUserCertificateFormatting {
    static func validFrom(_ info: SSHUserCertificateInfo) -> String {
        guard info.validAfter != 0 else {
            return String(localized: "Always", comment: "Cert validity: no start bound")
        }
        return formatDate(Date(timeIntervalSince1970: Double(info.validAfter)))
    }

    static func validUntil(_ info: SSHUserCertificateInfo) -> String {
        guard info.validBefore != .max else {
            return String(localized: "Never expires", comment: "Cert validity: no end bound")
        }
        return formatDate(Date(timeIntervalSince1970: Double(info.validBefore)))
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Days until expiry (only meaningful when expiring soon).
    static func daysUntilExpiry(_ info: SSHUserCertificateInfo) -> Int {
        guard info.validBefore != .max else { return Int.max }
        let seconds = Double(info.validBefore) - Date().timeIntervalSince1970
        return max(0, Int(seconds / 86400))
    }
}

/// Status row showing Valid / Expired / Not yet valid / Expires in N days.
/// `autoRenewed` certificates (OpenPubkey, step-ca) are short-lived by
/// design, so the 30-day "expires soon" warning is skipped for them.
@ViewBuilder
func certificateStatusRow(for info: SSHUserCertificateInfo, autoRenewed: Bool = false) -> some View {
    HStack {
        if info.isExpired {
            Label(String(localized: "Expired", comment: "Cert status"), systemImage: "xmark.seal.fill")
                .foregroundColor(.red)
        } else if info.isNotYetValid {
            Label(String(localized: "Not Yet Valid", comment: "Cert status"), systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        } else if info.isExpiringSoon, !autoRenewed {
            Label(String(localized: "Expires in \(SSHUserCertificateFormatting.daysUntilExpiry(info)) days", comment: "Cert status"), systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        } else {
            Label(String(localized: "Valid", comment: "Cert status"), systemImage: "checkmark.seal.fill")
                .foregroundColor(.green)
        }
        Spacer()
    }
}

#Preview {
    SSHUserCertificateImportView(targetKey: nil)
}
