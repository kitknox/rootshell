//
//  GenerateAppleFIDO2KeyView.swift
//  rootshell
//
//  UI for generating WebAuthn SSH credentials via Apple AuthenticationServices.
//  Supports platform passkeys (any passkey provider) and external security keys.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI
import UIKit
import AuthenticationServices

// MARK: - Window Finder Helper

/// Gets the frontmost key window so Authentication Services presents above the
/// settings sidebar that initiated the request.
private func getKeyWindow() -> UIWindow? {
    let activeScenes = UIApplication.shared.deviceWindowScenes
        .filter { $0.activationState == .foregroundActive }

    return activeScenes.lazy
        .compactMap { scene in scene.windows.first(where: { $0.isKeyWindow && !$0.isExternalDisplayPresentation }) }
        .first
        ?? activeScenes.lazy
        .flatMap(\.windows)
        .first(where: { !$0.isHidden && !$0.isExternalDisplayPresentation })
}

/// View for generating a passkey or external FIDO2 SSH credential.
struct GenerateAppleFIDO2KeyView: View {
    let backing: AppleFIDO2CredentialBacking

    @Environment(\.dismiss) private var dismiss
    @StateObject private var keyManager = SSHKeyManager.shared

    @State private var keyName: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var generatedCredential: AppleFIDO2CredentialInfo?

    @ViewBuilder
    var body: some View {
        if let credential = generatedCredential {
            GeneratedAppleFIDO2KeyResultView(credential: credential) {
                dismiss()
            }
        } else {
            Form {
            Section {
                TextField("Key Name", text: $keyName).textContentType(.username).themedRow()
            } header: {
                Text("Name")
            } footer: {
                Text("A friendly name to identify this key. This will be shown when authenticating.")
            }

            Section {
                HStack {
                    Text("Algorithm")
                    Spacer()
                    Text("ECDSA P-256").foregroundStyle(.secondary)
                }.themedRow()
                HStack {
                    Text("SSH Key Type")
                    Spacer()
                    Text("sk-ecdsa-sha2-nistp256").foregroundStyle(.secondary).font(.caption)
                }.themedRow()
            } header: {
                Text("Key Type")
            } footer: {
                Text("Authentication Services creates WebAuthn credentials using ECDSA P-256, which OpenSSH exposes as an sk-ecdsa key.")
            }

            // Security notice
            Section {
                HStack(spacing: 12) {
                    Image(systemName: isPasskey ? "person.badge.key.fill" : "key.viewfinder").foregroundStyle(isPasskey ? .blue : .teal).font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            isPasskey
                                ? String(localized: "Stored by Your Passkey Provider", comment: "Passkey generation storage heading")
                                : String(localized: "Connect Your Security Key", comment: "External security-key generation heading")
                        ).font(.subheadline).fontWeight(.medium)
                        Text(
                            isPasskey
                                ? String(
                                    localized: "Your passkey provider creates and syncs this key across your devices. That's iCloud Keychain by default, or a third-party manager like 1Password if you use one for passkeys.",
                                    comment: "Passkey generation sync explanation")
                                : String(
                                    localized: "When you tap Generate, the system will prompt you to connect your security key via USB-C, NFC, or Lightning.",
                                    comment: "External security-key connection explanation")
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }.listRowBackground((isPasskey ? Color.blue : Color.teal).opacity(0.1))
            }

            // Per-signature verification notice
            Section {
                HStack(spacing: 12) {
                    Image(systemName: isPasskey ? "faceid" : "hand.tap.fill").foregroundStyle(.orange).font(.title2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            isPasskey
                                ? String(localized: "Verification Required", comment: "Passkey generation verification heading")
                                : String(localized: "Touch Required", comment: "External security-key touch heading")
                        ).font(.subheadline).fontWeight(.medium)
                        Text(
                            isPasskey
                                ? String(
                                    localized: "Your passkey provider verifies you whenever the key signs, with Face ID, Touch ID, your passcode, or the provider's own unlock.",
                                    comment: "Passkey per-signature verification explanation")
                                : String(
                                    localized: "You'll need to touch your security key to create the credential and for each future signing operation.",
                                    comment: "External security-key touch explanation")
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }.listRowBackground(Color.orange.opacity(0.1))
            }
        }.themedList().navigationTitle(
            isPasskey
                ? String(localized: "Passkey", comment: "Passkey generation navigation title")
                : String(localized: "Security Key", comment: "External security-key generation navigation title")
        ).navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Generate") { generateKey() }.disabled(keyName.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)
            }
            }.alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? String(localized: "Unknown error", comment: "Generic error fallback message"))
            }.overlay {
                if isGenerating {
                    generatingOverlay
                }
            }
        }
    }

    private var generatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView().scaleEffect(1.5)

                Text(
                    isPasskey
                        ? String(localized: "Creating passkey...", comment: "Passkey generation progress")
                        : String(localized: "Waiting for security key...", comment: "External security-key generation progress")
                ).font(.headline)

                Text(
                    isPasskey
                        ? String(localized: "Follow the system prompt to verify your identity.", comment: "Passkey generation progress instruction")
                        : String(localized: "Follow the system prompts to connect your key.", comment: "External security-key generation progress instruction")
                ).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(32).background(.regularMaterial).cornerRadius(16)
        }
    }

    private func generateKey() {
        let trimmedName = keyName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isGenerating = true

        Task {
            do {
                let generator = AppleFIDO2KeyGenerator()

                // Set the presentation anchor for the authorization UI
                // Use the app's key window, not the sheet's window
                generator.setPresentationAnchor(getKeyWindow())

                let credentialInfo = try await generator.generateKey(userName: trimmedName, backing: backing)

                // Create SSHKey metadata
                var sshKey = SSHKey(
                    name: trimmedName, keyType: isPasskey ? .applePasskey : .appleFIDO2, fingerprint: credentialInfo.fingerprint, hasPassphrase: false,
                    storageLevel: isPasskey ? .iCloudSync : .backupOnly, authRequirement: isPasskey ? .perUse : .none)
                sshKey.appleFIDO2Info = credentialInfo
                sshKey.publicKeyBlob = credentialInfo.publicKeySSH

                // Save to keychain
                try keyManager.saveAppleFIDO2Reference(sshKey)

                generatedCredential = credentialInfo
            } catch let error as AppleFIDO2Error {
                errorMessage = error.localizedDescription
                showingError = true
            } catch {
                errorMessage = error.localizedDescription
                showingError = true
            }
            isGenerating = false
        }
    }

    private var isPasskey: Bool { backing == .platformPasskey }
}

/// Result view shown after successful Apple FIDO2 key generation
struct GeneratedAppleFIDO2KeyResultView: View {
    let credential: AppleFIDO2CredentialInfo
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)

                    Text(
                        credential.backing.isPasskey
                            ? String(localized: "Passkey Created", comment: "Passkey creation success heading")
                            : String(localized: "Security Key Registered", comment: "External security-key registration success heading")
                    ).font(.headline)

                    Text("Add the public key below to your server's authorized_keys file.").font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 8).themedRow()
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(credential.sshPublicKeyString).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(nil)
                }.themedRow()

                Button {
                    UIPasteboard.general.string = credential.sshPublicKeyString
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    HStack {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(
                            copied
                                ? String(localized: "Copied!", comment: "Copy button state: copied")
                                : String(localized: "Copy Public Key", comment: "Copy public key button"))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).themedRow()
            } header: {
                Text("Public Key (for authorized_keys)")
            }

            Section {
                LabeledContent("Algorithm", value: "ECDSA P-256").themedRow()
                LabeledContent("Key Type", value: "sk-ecdsa-sha2-nistp256").themedRow()
                LabeledContent("User Name", value: credential.userName).themedRow()
                LabeledContent("Fingerprint") { Text(formatFingerprint(credential.fingerprint)).font(.caption).fontDesign(.monospaced) }.themedRow()
            } header: {
                Text("Key Details")
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: credential.backing.isPasskey ? "faceid" : "hand.tap.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            credential.backing.isPasskey
                                ? String(localized: "Verification for Every Sign", comment: "Passkey result security heading")
                                : String(localized: "Touch Required for Every Sign", comment: "External security-key result security heading")
                        ).font(.subheadline).fontWeight(.medium)
                        Text(
                            credential.backing.isPasskey
                                ? String(
                                    localized: "The private key is held by your passkey provider (iCloud Keychain or a third-party manager like 1Password) and syncs across your devices. rootshell can never export it.",
                                    comment: "Passkey result security explanation")
                                : String(
                                    localized: "FIDO2 keys require physical touch for each signing operation.",
                                    comment: "External security-key result security explanation")
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }.themedRow()
            } header: {
                Text("Security Note")
            }
        }.themedList().navigationTitle("Key Generated").navigationBarTitleDisplayMode(.inline).toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { onDismiss() } }
        }
    }

    private func formatFingerprint(_ fingerprint: String) -> String {
        var result = ""
        for (index, char) in fingerprint.prefix(32).enumerated() {
            if index > 0 && index % 2 == 0 { result += ":" }
            result.append(char)
        }
        return "SHA256:" + result.uppercased()
    }
}

#Preview("Generate Apple FIDO2 Key") { GenerateAppleFIDO2KeyView(backing: .securityKey) }
