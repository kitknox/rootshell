//
//  StepCASignInView.swift
//  rootshell
//
//  "Sign In with Smallstep" sheet: find a step-ca SSH authority (hosted team
//  or CA URL + root fingerprint), pick a provisioner, sign in, and get back a
//  key with a short-lived CA-signed SSH certificate attached.
//

import SwiftUI
import os.log

struct StepCASignInView: View {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "StepCASignIn")
    @Environment(\.dismiss) var dismiss
    /// False once the sheet is popped; in-flight work is cancelled then.
    /// (onDisappear would also fire under the browser sign-in sheet.)
    @Environment(\.isPresented) private var isPresented
    var embedInNavigationStack = true

    private enum Source: String, CaseIterable, Identifiable {
        case team
        case caURL
        var id: String { rawValue }
    }

    @State private var source: Source = .caURL
    @State private var teamName = ""
    @State private var caURL = ""
    @State private var fingerprint = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case team, caURL, fingerprint, username, password, hostPatterns
    }

    @State private var isDiscovering = false
    @State private var discoveryTask: Task<Void, Never>?
    /// Bumped whenever the CA inputs change, so a slower in-flight discovery
    /// can't land a result for inputs no longer on screen.
    @State private var discoveryGeneration = 0
    @State private var authority: StepCAManager.Authority?
    @State private var provisioners: [StepCAClient.Provisioner] = []
    @State private var selectedProvisionerID: String?

    // JWK provisioners
    @State private var jwkUsername = ""
    @State private var jwkPassword = ""
    @State private var rememberPassword = true

    @State private var keyName = ""
    @State private var keyAlgorithm: OpenPubkeyKeyAlgorithm = .ecdsaP256
    @State private var storageLevel: KeyStorageLevel = .backupOnly
    @State private var showOptions = false
    @State private var trustHostKeys = false
    @State private var hostPatterns = ""

    @State private var isAuthenticating = false
    @State private var signInTask: Task<Void, Never>?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var dismissAfterError = false

    private var selectedProvisioner: StepCAClient.Provisioner? {
        provisioners.first { $0.id == selectedProvisionerID }
    }

    private var canDiscover: Bool {
        switch source {
        case .team:
            return !teamName.trimmingCharacters(in: .whitespaces).isEmpty
        case .caURL:
            return !caURL.trimmingCharacters(in: .whitespaces).isEmpty
                && StepCAClient.normalizedFingerprint(fingerprint) != nil
        }
    }

    private var canSignIn: Bool {
        guard authority != nil, let provisioner = selectedProvisioner else { return false }
        if provisioner.kind == .jwk {
            guard !jwkUsername.trimmingCharacters(in: .whitespaces).isEmpty, !jwkPassword.isEmpty else { return false }
        }
        return !trustHostKeys || !parsedHostPatterns.isEmpty
    }

    private var parsedHostPatterns: [String] {
        hostPatterns
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
    }

    private var defaultKeyName: String {
        guard let authority else { return "step" }
        return "step \(URL(string: authority.caURL)?.host ?? authority.caURL)"
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
            // A pending sign-in already captured every setting below; lock
            // them so the form can't show values it won't apply. Cancel stays
            // in the toolbar.
            Group {
                authoritySection

                if authority != nil {
                    provisionerSection

                    if selectedProvisioner?.kind == .jwk {
                        passwordSection
                    }

                    ManagedKeyOptionsSections(
                        defaultKeyName: defaultKeyName,
                        keyName: $keyName,
                        keyAlgorithm: $keyAlgorithm,
                        keyTypeFooter: Text("ECDSA P-256 is what the step CLI uses by default. Both types work with step-ca."),
                        storageLevel: $storageLevel,
                        showOptions: $showOptions
                    )

                    hostTrustSection
                }
            }
            .disabled(isAuthenticating)

            if authority != nil {
                ManagedSignInButtonSection(
                    isAuthenticating: isAuthenticating,
                    canSignIn: canSignIn,
                    footer: Text("step-ca certificates usually last 16 hours. The app renews them before connecting when it can, or asks you to sign in again."),
                    action: signIn
                )
            }
        }
        .themedList()
        #if !os(visionOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle("Smallstep")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if embedInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        signInTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .alert("Sign-In Failed", isPresented: $showingError) {
            Button("OK", role: .cancel) {
                if dismissAfterError { dismiss() }
            }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: isPresented) {
            if !isPresented {
                discoveryTask?.cancel()
                signInTask?.cancel()
            }
        }
        .onChange(of: source) { resetDiscovery() }
        .onChange(of: teamName) { resetDiscovery() }
        .onChange(of: caURL) { resetDiscovery() }
        .onChange(of: fingerprint) { resetDiscovery() }
    }

    // MARK: - Sections

    private var authoritySection: some View {
        Section {
            Picker("Find CA By", selection: $source) {
                Text("CA URL").tag(Source.caURL)
                Text("Smallstep Team").tag(Source.team)
            }
            .pickerStyle(.segmented)
            .themedRow()

            switch source {
            case .team:
                TextField("Team Name", text: $teamName)
                    .focused($focusedField, equals: .team)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themedRow()
            case .caURL:
                TextField("CA URL (https://...)", text: $caURL)
                    .focused($focusedField, equals: .caURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .themedRow()
                // Wraps so the whole 64-character digest stays checkable on
                // narrow screens.
                TextField("Root Fingerprint", text: $fingerprint, axis: .vertical)
                    .focused($focusedField, equals: .fingerprint)
                    .lineLimit(1...3)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.callout.monospaced())
                    .themedRow()
            }

            Button(action: discover) {
                HStack {
                    Label(authority == nil ? "Connect to CA" : "Connected", systemImage: authority == nil ? "network" : "checkmark.circle.fill")
                    if isDiscovering {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!canDiscover || isDiscovering || authority != nil)
            .themedRow()
        } header: {
            Text("Certificate Authority")
        } footer: {
            switch source {
            case .team:
                Text("The team name from your Smallstep sign-in URL.")
            case .caURL:
                Text("From `step ca bootstrap`: the CA URL and the SHA-256 fingerprint of its root certificate (`step certificate fingerprint root_ca.crt`).")
            }
        }
    }

    private var provisionerSection: some View {
        Section {
            Picker("Provisioner", selection: $selectedProvisionerID) {
                ForEach(provisioners) { provisioner in
                    Text(provisionerLabel(provisioner)).tag(Optional(provisioner.id))
                }
            }
            .pickerStyle(.menu)
            .themedRow()
        } header: {
            Text("Provisioner")
        } footer: {
            if selectedProvisioner?.kind == .jwk {
                Text("Password provisioners issue a certificate for the username you enter.")
            } else {
                Text("Signs in through your identity provider in the browser. The CA issues a certificate for your email address.")
            }
        }
    }

    private var passwordSection: some View {
        Section {
            TextField("Username", text: $jwkUsername)
                .focused($focusedField, equals: .username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .themedRow()
            SecureField("Provisioner Password", text: $jwkPassword)
                .focused($focusedField, equals: .password)
                .themedRow()
            Toggle("Remember Password", isOn: $rememberPassword)
                .themedRow()
        } header: {
            Text("Password")
        } footer: {
            Text("The username becomes the certificate's principal. A remembered password is stored in the Keychain with this key so the certificate renews without asking.")
        }
    }

    private var hostTrustSection: some View {
        Section {
            Toggle("Trust CA for Host Keys", isOn: $trustHostKeys)
                .themedRow()
            if trustHostKeys {
                TextField("Host Patterns (*.example.com)", text: $hostPatterns)
                    .focused($focusedField, equals: .hostPatterns)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .themedRow()
            }
        } header: {
            Text("Host Keys")
        } footer: {
            if trustHostKeys {
                if parsedHostPatterns.isEmpty {
                    Text("Enter the hostnames this CA may vouch for, such as *.example.com.")
                } else {
                    Text("Hosts matching \(parsedHostPatterns.joined(separator: ", ")) are accepted without a fingerprint prompt when they present a host certificate from this CA, even if they were trusted with a different key before.")
                }
            } else {
                Text("Optional. Lets this CA vouch for SSH host keys, like an @cert-authority line in known_hosts.")
            }
        }
    }

    private func provisionerLabel(_ provisioner: StepCAClient.Provisioner) -> String {
        switch provisioner.kind {
        case .oidc:
            return String(localized: "\(provisioner.name) (OIDC)", comment: "Smallstep provisioner picker: OIDC provisioner")
        case .jwk:
            return String(localized: "\(provisioner.name) (Password)", comment: "Smallstep provisioner picker: JWK provisioner")
        case nil:
            return provisioner.name
        }
    }

    // MARK: - Actions

    private func resetDiscovery() {
        discoveryGeneration += 1
        discoveryTask?.cancel()
        isDiscovering = false
        // Host-trust consent belongs to the CA it was given for.
        trustHostKeys = false
        hostPatterns = ""
        authority = nil
        provisioners = []
        selectedProvisionerID = nil
    }

    private func discover() {
        let team = source == .team ? teamName.trimmingCharacters(in: .whitespaces) : nil
        let url = caURL
        let print = fingerprint
        let generation = discoveryGeneration
        isDiscovering = true
        discoveryTask = Task {
            defer {
                if generation == discoveryGeneration { isDiscovering = false }
            }
            do {
                let (found, list) = try await StepCAManager.shared.discover(teamName: team, caURL: url, fingerprint: print)
                guard generation == discoveryGeneration else { return }
                // The provisioner and key sections appear below; drop the
                // keyboard so they aren't hidden behind it.
                focusedField = nil
                authority = found
                provisioners = list
                selectedProvisionerID = list.first(where: { $0.kind == .oidc })?.id ?? list.first?.id
            } catch {
                guard generation == discoveryGeneration else { return }
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func signIn() {
        guard let authority, let provisioner = selectedProvisioner else { return }
        let trimmedName = keyName.trimmingCharacters(in: .whitespaces)
        let name = trimmedName.isEmpty ? defaultKeyName : trimmedName
        let level = storageLevel
        let algorithm = keyAlgorithm
        let password = jwkPassword
        let remember = rememberPassword
        let subject = jwkUsername
        let trustPatterns = trustHostKeys ? parsedHostPatterns : []

        focusedField = nil
        isAuthenticating = true
        signInTask = Task {
            defer { isAuthenticating = false }
            do {
                let key = try await StepCAManager.shared.createIdentity(
                    authority: authority,
                    provisioner: provisioner,
                    password: password,
                    rememberPassword: remember,
                    jwkSubject: subject,
                    name: name,
                    keyAlgorithm: algorithm,
                    storageLevel: level
                )
                guard !Task.isCancelled else { return }
                if !trustPatterns.isEmpty {
                    do {
                        try await StepCAManager.shared.trustHostKeys(authority: authority, hostPatterns: trustPatterns)
                    } catch {
                        // Sheet closed mid-request: nothing to report.
                        if error is CancellationError || Task.isCancelled { return }
                        // The key exists now; say host trust failed, then leave.
                        Self.logger.error("Could not add step-ca host keys: \(error.localizedDescription)")
                        errorMessage = String(localized: "Signed in, but the CA's host keys couldn't be trusted: \(error.localizedDescription)")
                        dismissAfterError = true
                        showingError = true
                        return
                    }
                }
                Self.logger.info("Smallstep sign-in complete for \(key.stepCAInfo?.identity ?? name)")
                dismiss()
            } catch OIDCLoginClient.ClientError.cancelled {
                // User closed the browser sheet; stay on the form.
            } catch is CancellationError {
                // The sheet was closed; nothing was saved.
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
