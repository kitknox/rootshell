//
//  StorageProvidersSettingsView.swift
//  rootshell
//
//  Settings → Connections → Storage Providers: the saved S3-compatible
//  accounts the file manager can open, and the editor for one.
//

import SwiftUI

struct StorageProvidersSettingsView: View {
    @State private var isAdding = false
    @State private var pendingDelete: StorageProvider?
    @State private var errorMessage: String?

    private var store: StorageProviderStore { .shared }

    var body: some View {
        List {
            if store.providers.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("No Storage Providers").font(.headline)
                        Text("Add Amazon S3, Akamai, Cloudflare R2, Backblaze B2 or any S3-compatible service to browse and transfer files in the file manager.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(String(localized: "Add Provider", comment: "Storage providers: add button")) { isAdding = true }
                            .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .themedRow()
                }
            } else {
                Section {
                    ForEach(store.providers) { provider in
                        NavigationLink {
                            StorageProviderEditView(provider: provider, isNew: false)
                        } label: {
                            StorageProviderRow(provider: provider)
                        }
                        .themedRow()
                    }
                    .onDelete { offsets in
                        pendingDelete = offsets.first.map { store.providers[$0] }
                    }
                } footer: {
                    Text("Providers and their keys are stored in iCloud Keychain and sync to your other devices.")
                }
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Storage Providers", comment: "Settings screen title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(String(localized: "Add Provider", comment: "Storage providers: add button"))
            }
        }
        .onAppear { store.reload() }
        // Pushed, not a sheet, so it stays inside the settings sidebar.
        .navigationDestination(isPresented: $isAdding) {
            StorageProviderEditView(provider: StorageProvider(), isNew: true)
        }
        .alert(
            String(localized: "Delete Provider", comment: "Storage providers: delete confirmation title"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { provider in
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
            Button(String(localized: "Delete", comment: "Delete button"), role: .destructive) { delete(provider) }
        } message: { provider in
            Text("“\(provider.displayName)” and its keys will be removed from all your devices. Files in storage are not affected.")
        }
        .alert(
            String(localized: "Couldn't Delete Provider", comment: "Storage providers: delete failure title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func delete(_ provider: StorageProvider) {
        do {
            try store.delete(provider.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StorageProviderRow: View {
    let provider: StorageProvider

    var body: some View {
        HStack(spacing: 12) {
            FaviconIcon(domain: provider.faviconDomain, fallbackSymbol: FileEndpoint.storageSymbol)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text([provider.preset.name, provider.effectiveBucket].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Editor

struct StorageProviderEditView: View {
    let isNew: Bool

    @State private var draft: StorageProvider
    @State private var test: TestState = .idle
    @State private var saveError: String?
    @State private var testTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    init(provider: StorageProvider, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: provider)
    }

    private var preset: StorageProviderPreset { draft.preset }

    var body: some View {
        Form {
            Section {
                // Full-width row and pushed list: service names are too long for a menu picker's trailing value.
                NavigationLink {
                    StorageServicePicker(selection: $draft.presetID)
                } label: {
                    HStack(spacing: 12) {
                        // The preset's domain, so typing an endpoint doesn't fetch per keystroke.
                        FaviconIcon(domain: preset.faviconDomain, fallbackSymbol: FileEndpoint.storageSymbol)
                            .frame(width: 28, height: 28)
                        Text(preset.name)
                    }
                }
                .themedRow()
                labeledRow(String(localized: "Name", comment: "Storage provider field")) {
                    TextField(String(localized: "Name", comment: "Storage provider field"), text: $draft.name, prompt: Text(optionalPrompt))
                }
                .themedRow()
            } header: {
                Text("Service")
            } footer: {
                Text("The name defaults to the service name.")
            }

            Section {
                if preset.showsRegion {
                    HStack {
                        plainField(String(localized: "Region", comment: "Storage provider field"), text: $draft.region, prompt: preset.defaultRegion)
                        if !preset.regions.isEmpty {
                            Menu {
                                ForEach(preset.regions, id: \.self) { region in
                                    Button(region) { draft.region = region }
                                }
                            } label: {
                                Image(systemName: "chevron.up.chevron.down")
                            }
                            .accessibilityLabel(String(localized: "Choose Region", comment: "Storage provider: region suggestions menu"))
                        }
                    }
                    .themedRow()
                }
                if let label = preset.accountIDLabel {
                    plainField(label, text: $draft.accountID, prompt: requiredPrompt)
                        .themedRow()
                }
                if preset.requiresCustomEndpoint {
                    plainField(String(localized: "Endpoint", comment: "Storage provider field"), text: $draft.customEndpoint, prompt: "https://s3.example.com")
                        .keyboardType(.URL)
                        .themedRow()
                }
            } header: {
                Text("Connection")
            } footer: {
                if let endpoint = draft.resolvedEndpoint, !preset.requiresCustomEndpoint {
                    Text(endpoint)
                }
            }

            Section {
                plainField(String(localized: "Access Key ID", comment: "Storage provider field"), text: $draft.accessKeyID, prompt: optionalPrompt)
                    .themedRow()
                secureField(String(localized: "Secret Access Key", comment: "Storage provider field"), text: $draft.secretAccessKey)
                    .themedRow()
            } header: {
                Text("Credentials")
            } footer: {
                Text("Leave both empty to browse public buckets. Keys are stored in iCloud Keychain.")
            }

            Section {
                plainField(String(localized: "Bucket", comment: "Storage provider field"), text: $draft.bucket,
                           prompt: String(localized: "All buckets", comment: "Storage provider: bucket placeholder"))
                    .themedRow()
                plainField(String(localized: "Start In", comment: "Storage provider field: initial folder"), text: $draft.initialPath, prompt: "/")
                    .themedRow()
            } header: {
                Text("Location")
            } footer: {
                Text("Set a bucket when your keys can't list buckets, or to open straight into one. Start In is a folder within that bucket.")
            }

            Section {
                Picker(String(localized: "Addressing", comment: "Storage provider field: path or virtual-host style URLs"), selection: $draft.addressingStyle) {
                    Text("Automatic").tag(StorageProvider.AddressingStyle?.none)
                    ForEach(StorageProvider.AddressingStyle.allCases, id: \.self) { style in
                        Text(title(for: style)).tag(StorageProvider.AddressingStyle?.some(style))
                    }
                }
                .themedRow()
                if !preset.requiresCustomEndpoint {
                    plainField(String(localized: "Custom Endpoint", comment: "Storage provider field"), text: $draft.customEndpoint,
                               prompt: String(localized: "Use preset", comment: "Storage provider: custom endpoint placeholder"))
                        .keyboardType(.URL)
                        .themedRow()
                }
                if !preset.isAWS {
                    plainField(String(localized: "Signing Region", comment: "Storage provider field: region used in request signatures"),
                               text: $draft.signingRegion, prompt: preset.signingRegion ?? draft.effectiveRegion)
                        .themedRow()
                }
                secureField(String(localized: "Session Token", comment: "Storage provider field: temporary credentials token"), text: $draft.sessionToken)
                    .themedRow()
            } header: {
                Text("Advanced")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatic addressing uses \(title(for: preset.addressing)) for \(preset.name).")
                    if !preset.isAWS {
                        Text("Change the signing region only if the service reports that the request signature doesn't match.")
                    }
                }
            }

            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        switch test {
                        case .idle: EmptyView()
                        case .running: ProgressView()
                        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                }
                .disabled(draft.validationError != nil || test == .running)
                .themedRow()
            } footer: {
                switch test {
                case .succeeded(let message), .failed(let message): Text(message)
                case .idle, .running: if let problem = draft.validationError { Text(problem) }
                }
            }
        }
        .themedList()
        .navigationTitle(isNew
            ? String(localized: "New Provider", comment: "Storage provider editor title")
            : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Save", comment: "Save button"), action: save)
                    .disabled(draft.validationError != nil)
            }
        }
        .onChange(of: draft) { _, _ in
            testTask?.cancel()
            test = .idle
        }
        .onChange(of: draft.presetID) { _, _ in
            // Regions differ per service; keep a typed one only if the new preset knows it.
            if !draft.preset.regions.contains(draft.region) { draft.region = "" }
        }
        .onDisappear { testTask?.cancel() }
        .alert(
            String(localized: "Couldn't Save Provider", comment: "Storage provider save failure title"),
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button(String(localized: "OK", comment: "OK button"), role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var requiredPrompt: String { String(localized: "Required", comment: "Storage provider: placeholder for a required field") }
    private var optionalPrompt: String { String(localized: "Optional", comment: "Storage provider: placeholder for an optional field") }

    /// iOS forms hide a text field's title once it has a prompt, so the label is drawn separately.
    private func labeledRow<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        HStack {
            Text(title)
            Spacer()
            field()
                .multilineTextAlignment(.trailing)
        }
    }

    private func plainField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        labeledRow(title) {
            TextField(title, text: text, prompt: Text(prompt))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func secureField(_ title: String, text: Binding<String>) -> some View {
        labeledRow(title) {
            SecureField(title, text: text, prompt: Text(optionalPrompt))
        }
    }

    private func title(for style: StorageProvider.AddressingStyle) -> String {
        switch style {
        case .path: String(localized: "Path", comment: "Storage addressing style: bucket in the URL path")
        case .virtualHost: String(localized: "Virtual Host", comment: "Storage addressing style: bucket in the host name")
        }
    }

    private func save() {
        do {
            try StorageProviderStore.shared.save(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Lists the starting folder with the unsaved settings.
    private func runTest() {
        let provider = draft
        test = .running
        testTask = Task {
            let result: TestState
            do {
                let connection = try S3Connection(provider: provider)
                do {
                    let fs = connection.browseFileSystem
                    let page = try await fs.listPage(try await fs.homeDirectory())
                    result = .succeeded(
                        page.hasMore
                            ? String(localized: "Connected. \(page.entries.count)+ items found.", comment: "Storage provider test result when more items exist; argument is an item count")
                            : String(localized: "Connected. \(page.entries.count) items found.", comment: "Storage provider test result; argument is an item count")
                    )
                } catch {
                    result = .failed(error.localizedDescription)
                }
                await connection.close()
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            test = result
        }
    }
}

private struct StorageServicePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(StorageProviderPreset.all) { preset in
                Button {
                    selection = preset.id
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        FaviconIcon(domain: preset.faviconDomain, fallbackSymbol: FileEndpoint.storageSymbol)
                            .frame(width: 28, height: 28)
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if preset.id == selection {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle(String(localized: "Service", comment: "Storage provider field"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
