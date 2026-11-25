import SwiftUI
import UniformTypeIdentifiers

// MARK: - Add

/// Sheet for adding a trusted host certificate authority.
struct AddHostCertificateAuthorityView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = HostCAManager.shared

    @State private var name = ""
    @State private var keyText = ""
    @State private var patternsText = ""
    @State private var showingFileImporter = false
    @State private var errorMessage: String?

    private var canSave: Bool {
        !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !patternsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Acme Host CA", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .themedRow()
                }

                Section {
                    TextField("ssh-ed25519 AAAA…", text: $keyText, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(3...8)
                        .themedRow()

                    PasteButton(payloadType: String.self) { strings in
                        if let clip = strings.first {
                            keyText = clip
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .themedRow()

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import from File…", systemImage: "folder")
                    }
                    .themedRow()
                } header: {
                    Text("CA Public Key")
                } footer: {
                    Text("Paste the certificate authority's public key (the key used to sign host certificates), not a signed certificate. This is the `TrustedUserCAKeys`/host-CA `.pub` your administrator provides.")
                }

                Section {
                    TextField("*.example.com, 10.0.*", text: $patternsText, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(1...4)
                        .themedRow()
                } header: {
                    Text("Host Patterns")
                } footer: {
                    Text("Hostnames this CA is trusted for. Comma-separated, with `*` and `?` wildcards (e.g. `*.example.com`). Use `*` to trust the CA for every host.")
                }
            }
            .themedList()
            .navigationTitle("Add Certificate Authority")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }
                        .disabled(!canSave)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.plainText, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Couldn't Add Authority", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try manager.addCA(
                name: name,
                openSSHPublicKey: keyText,
                hostPatterns: [patternsText]
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try String(contentsOf: url, encoding: .utf8)
                keyText = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty {
                    name = url.deletingPathExtension().lastPathComponent
                }
            } catch {
                errorMessage = "Couldn't read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Detail

/// Detail / edit view for a configured host certificate authority.
struct HostCertificateAuthorityDetailView: View {
    let ca: HostCertificateAuthority

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @StateObject private var manager = HostCAManager.shared

    @State private var name: String
    @State private var patternsText: String
    @State private var showingDeleteAlert = false
    @State private var fingerprintCopied = false
    @State private var publicKeyCopied = false
    @State private var saveError: String?

    init(ca: HostCertificateAuthority) {
        self.ca = ca
        _name = State(initialValue: ca.name)
        _patternsText = State(initialValue: ca.hostPatterns.joined(separator: ", "))
    }

    private var hasChanges: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = HostCAManager.normalizePatterns([patternsText])
        return (trimmedName != ca.name && !trimmedName.isEmpty) ||
            (normalized != ca.hostPatterns && !normalized.isEmpty)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themedRow()
            }

            Section {
                TextField("*.example.com, 10.0.*", text: $patternsText, axis: .vertical)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(1...4)
                    .themedRow()
            } header: {
                Text("Host Patterns")
            } footer: {
                Text("Comma-separated, with `*` and `?` wildcards.")
            }

            Section("Key Details") {
                LabeledContent("Type", value: ca.keyType)
                    .themedRow()
                LabeledContent("Added", value: ca.addedDate.formatted(date: .abbreviated, time: .shortened))
                    .themedRow()
            }

            Section("Fingerprint") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("SHA256")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: copyFingerprint) {
                            HStack(spacing: 4) {
                                Image(systemName: fingerprintCopied ? "checkmark" : "doc.on.doc")
                                Text(fingerprintCopied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy", comment: "Copy button"))
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(fingerprintCopied ? .green : .blue)
                    }

                    Text(ca.fullFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            Section("Public Key") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("OpenSSH Format")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: copyPublicKey) {
                            HStack(spacing: 4) {
                                Image(systemName: publicKeyCopied ? "checkmark" : "doc.on.doc")
                                Text(publicKeyCopied ? String(localized: "Copied", comment: "Copy button state: copied") : String(localized: "Copy", comment: "Copy button"))
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(publicKeyCopied ? .green : .blue)
                    }

                    Text(ca.publicKeyOpenSSH)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                        .cornerRadius(6)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            Section {
                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Text("Remove Authority")
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(ca.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    // Stay on the editor if the save fails: dismissing would
                    // leave the previous (possibly broader) scope in place.
                    do {
                        try manager.update(id: ca.id, name: name, hostPatterns: [patternsText])
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .disabled(!hasChanges)
            }
        }
        .alert("Couldn't Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert("Remove This Authority?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                manager.removeCA(id: ca.id)
                dismiss()
            }
        } message: {
            Text("Hosts trusted via this CA will prompt for host-key verification again.")
        }
    }

    private func copyFingerprint() {
        UIPasteboard.general.string = ca.fullFingerprint
        fingerprintCopied = true

        // Reset the copied state after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            fingerprintCopied = false
        }
    }

    private func copyPublicKey() {
        UIPasteboard.general.string = ca.publicKeyOpenSSH
        publicKeyCopied = true

        // Reset the copied state after 2 seconds
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            publicKeyCopied = false
        }
    }
}
