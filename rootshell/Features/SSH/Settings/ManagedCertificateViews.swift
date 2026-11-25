//
//  ManagedCertificateViews.swift
//  rootshell
//
//  Form sections shared by the OpenPubkey and Smallstep sign-in sheets, and
//  the key-detail section that shows and renews a managed certificate.
//

import SwiftUI

/// Key name, key type and storage options for a new certificate identity.
struct ManagedKeyOptionsSections<ExtraOptions: View>: View {
    let defaultKeyName: String
    @Binding var keyName: String
    @Binding var keyAlgorithm: OpenPubkeyKeyAlgorithm
    let keyTypeFooter: Text
    @Binding var storageLevel: KeyStorageLevel
    @Binding var showOptions: Bool
    @ViewBuilder let extraOptions: () -> ExtraOptions

    var body: some View {
        Section {
            TextField(defaultKeyName, text: $keyName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .themedRow()
        } header: {
            Text("Key Name")
        }

        Section {
            Picker("Key Type", selection: $keyAlgorithm) {
                ForEach(OpenPubkeyKeyAlgorithm.allCases) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            .pickerStyle(.menu)
            .themedRow()
        } header: {
            Text("Key Type")
        } footer: {
            keyTypeFooter
        }

        Section {
            DisclosureGroup("Options", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 12) {
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

                    extraOptions()
                }
                .padding(.vertical, 4)
            }
            .themedRow()
        }
    }
}

extension ManagedKeyOptionsSections where ExtraOptions == EmptyView {
    init(
        defaultKeyName: String,
        keyName: Binding<String>,
        keyAlgorithm: Binding<OpenPubkeyKeyAlgorithm>,
        keyTypeFooter: Text,
        storageLevel: Binding<KeyStorageLevel>,
        showOptions: Binding<Bool>
    ) {
        self.init(
            defaultKeyName: defaultKeyName,
            keyName: keyName,
            keyAlgorithm: keyAlgorithm,
            keyTypeFooter: keyTypeFooter,
            storageLevel: storageLevel,
            showOptions: showOptions,
            extraOptions: { EmptyView() }
        )
    }
}

/// The full-width "Sign In" button with its in-progress state.
struct ManagedSignInButtonSection: View {
    let isAuthenticating: Bool
    let canSignIn: Bool
    let footer: Text
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack {
                    Spacer()
                    if isAuthenticating {
                        ProgressView()
                            .padding(.trailing, 8)
                    }
                    Text(isAuthenticating
                         ? String(localized: "Waiting for Sign-In...", comment: "Certificate sign-in: in progress")
                         : String(localized: "Sign In", comment: "Certificate sign-in: button"))
                    Spacer()
                }
            }
            .disabled(!canSignIn || isAuthenticating)
            .themedRow()
        } footer: {
            footer
        }
    }
}

/// Key-detail section for an OpenPubkey or Smallstep identity: who it is,
/// when the certificate expires, and the renew / sign-in-again actions.
struct ManagedCertificateSection: View {
    let key: SSHKey

    @State private var isRenewing = false
    @State private var isReauthenticating = false
    @State private var showingPasswordPrompt = false
    @State private var password = ""
    @State private var showingError = false
    @State private var errorMessage = ""

    private var isBusy: Bool { isRenewing || isReauthenticating }

    var body: some View {
        Section {
            if let opk = key.openPubkeyInfo {
                HStack {
                    Text(String(localized: "Provider", comment: "OpenPubkey field: OIDC provider"))
                    Spacer()
                    if let logo = opk.provider.logoImageName {
                        Image(logo)
                            .renderingMode(.original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 20, height: 20)
                    }
                    Text(opk.provider.displayName)
                        .foregroundColor(.secondary)
                }
                .themedRow()
                LabeledRow(label: String(localized: "Identity", comment: "Certificate identity field: signed-in account"), value: opk.identityDisplay)
                    .themedRow()
            } else if let step = key.stepCAInfo {
                LabeledRow(label: String(localized: "CA", comment: "Smallstep field: certificate authority host"), value: step.teamName.map { "\($0) (\(step.caHost))" } ?? step.caHost)
                    .themedRow()
                LabeledRow(label: String(localized: "Provisioner", comment: "Smallstep field: CA provisioner"), value: step.provisionerName)
                    .themedRow()
                LabeledRow(label: String(localized: "Identity", comment: "Certificate identity field: signed-in account"), value: step.identity)
                    .themedRow()
            }

            HStack {
                Text("Certificate Expires")
                Spacer()
                if let expiry = key.managedCertificateExpiry {
                    Text(expiry, format: .relative(presentation: .named))
                        .foregroundColor(expiryColor(expiry))
                } else {
                    Text("Unknown")
                        .foregroundColor(.secondary)
                }
            }
            .themedRow()

            if let lastLogin = key.openPubkeyInfo?.lastLoginDate ?? key.stepCAInfo?.lastLoginDate {
                LabeledRow(
                    label: String(localized: "Last Sign-In", comment: "Certificate identity field: last interactive sign-in"),
                    value: lastLogin.formatted(date: .abbreviated, time: .shortened)
                )
                .themedRow()
            }

            Button(action: renew) {
                HStack {
                    Label("Renew Now", systemImage: "arrow.clockwise")
                    if isRenewing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!key.canRenewManagedCertificateSilently || isBusy)
            .themedRow()

            Button(action: signInAgain) {
                HStack {
                    Label("Sign In Again", systemImage: "person.crop.circle.badge.checkmark")
                    if isReauthenticating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isBusy)
            .themedRow()
        } header: {
            Text(key.stepCAInfo != nil ? "Smallstep" : "OpenPubkey")
        } footer: {
            footer
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("Provisioner Password", isPresented: $showingPasswordPrompt) {
            SecureField("Password", text: $password)
            Button("Sign In") {
                let entered = password
                password = ""
                reauthenticate(password: entered)
            }
            Button("Cancel", role: .cancel) {
                password = ""
            }
        } message: {
            if key.stepCAInfo?.rememberPassword == true {
                Text("Enter the password for the \(key.stepCAInfo?.provisionerName ?? "") provisioner. If it changed, the new password replaces the remembered one.")
            } else {
                Text("Enter the password for the \(key.stepCAInfo?.provisionerName ?? "") provisioner.")
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let opk = key.openPubkeyInfo {
            if opk.hasRefreshToken {
                Text("The certificate renews automatically before connections. Renewal keeps this key; only the embedded token changes.")
            } else {
                Text("The provider did not issue a refresh token, so a new browser sign-in is needed roughly every 24 hours.")
            }
        } else if let step = key.stepCAInfo {
            switch (step.provisionerKind, step.canRenewSilently) {
            case (.oidc, true):
                Text("The certificate renews automatically before connections. Renewal keeps this key; the CA signs a new certificate.")
            case (.oidc, false):
                Text("The identity provider did not issue a refresh token, so connecting opens a browser sign-in when the certificate expires.")
            case (.jwk, true):
                Text("The certificate renews automatically with the saved provisioner password.")
            case (.jwk, false):
                Text("When the certificate expires, use Sign In Again and enter the provisioner password.")
            }
        }
    }

    private func expiryColor(_ expiry: Date) -> Color {
        let remaining = expiry.timeIntervalSinceNow
        if remaining <= 0 { return .red }
        if remaining < 3600 { return .orange }
        return .secondary
    }

    private func renew() {
        isRenewing = true
        Task {
            defer { isRenewing = false }
            do {
                try await ManagedCertificateIdentities.renewCertificate(forKeyID: key.id)
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }

    private func signInAgain() {
        // Always ask: a remembered password may be the stale one that just
        // failed silent renewal. A new one replaces it once the CA accepts it.
        if let step = key.stepCAInfo, step.provisionerKind == .jwk {
            showingPasswordPrompt = true
        } else {
            reauthenticate(password: nil)
        }
    }

    private func reauthenticate(password: String?) {
        isReauthenticating = true
        Task {
            defer { isReauthenticating = false }
            do {
                try await ManagedCertificateIdentities.reauthenticate(keyID: key.id, password: password)
            } catch OIDCLoginClient.ClientError.cancelled {
                // User closed the browser sheet.
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
        }
    }
}
