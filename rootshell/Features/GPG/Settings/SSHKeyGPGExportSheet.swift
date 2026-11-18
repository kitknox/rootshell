//
//  SSHKeyGPGExportSheet.swift
//  rootshell
//
//  Prompts the user for a User ID (name + optional email), runs
//  ``OpenPGPPublicKeyExport.export`` against the chosen ``SSHKey``,
//  and shows the resulting ASCII-armored block with copy + share.
//  The export performs one signing operation (the self-signature)
//  which will trigger Face ID / passcode / YubiKey PIN as required by
//  the key's auth settings.
//
//  Without this output, GPG agent forwarding has nothing for the
//  remote `gpg` client to bind to — the remote has no way to know
//  the key exists or what its public material is. After importing
//  this block with `gpg --import` on the remote, signing requests
//  via the forwarded agent will resolve to this key.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import SwiftUI
import os.log

struct SSHKeyGPGExportSheet: View {

    private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "SSHKeyGPGExportSheet"
    )

    let key: SSHKey

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    @State private var name: String = ""
    @State private var email: String = ""
    @State private var armoredOutput: String = ""
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var copied = false
    @State private var showingShareSheet = false

    // YubiKey PIN prompt — when the export's self-signature triggers
    // a PIV signing operation on a hardware key, YubiKeyConnectionManager
    // publishes a `pendingPINRequest`. Every view that drives YubiKey
    // signing has to present the prompt itself; without this the
    // request fires but the prompt UI never appears, leaving the
    // export's progress spinner hanging and an open NFC session
    // dangling. Pattern mirrors YubiKeyManagementView.
    @State private var showingPINPrompt = false
    // YubiKeyConnectionManager uses the @Observable macro (not
    // ObservableObject) so SwiftUI tracks property reads via the
    // Observation framework — no property wrapper needed.
    private var yubiKeyConnectionManager: YubiKeyConnectionManager {
        YubiKeyConnectionManager.shared
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .themedRow()
                    TextField("Email (optional)", text: $email)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .themedRow()
                } header: {
                    Text("User ID")
                } footer: {
                    Text("Appears on the OpenPGP key as `Name <email>` and is what the remote will display when verifying signatures.")
                }

                if !armoredOutput.isEmpty {
                    Section {
                        Text(armoredOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(nil)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(6)
                            .themedRow()

                        HStack {
                            Button(action: copy) {
                                HStack(spacing: 4) {
                                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    Text(copied ? "Copied" : "Copy")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(copied ? .green : .blue)

                            Button(action: { showingShareSheet = true }) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }
                        .themedRow()
                    } header: {
                        Text("OpenPGP Public Key")
                    } footer: {
                        Text("On the remote, save this to a file and run `gpg --import <file>`, then verify with `gpg --list-keys`.")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .themedRow()
                    }
                }

                Section {
                    Text("Generating the public key produces a self-signature, so the same authentication you use for signing with this key will be required (Face ID, passcode, or YubiKey tap/PIN).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .themedRow()
                }
            }
            .themedList()
            #if !os(visionOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle("Export GPG Public Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await runExport() }
                    } label: {
                        if isExporting {
                            ProgressView()
                        } else {
                            Text("Generate").bold()
                        }
                    }
                    .disabled(isExporting || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ActivityShareSheet(items: [armoredOutput])
            }
            .sheet(isPresented: $showingPINPrompt) {
                if let request = yubiKeyConnectionManager.pendingPINRequest {
                    // Completions carry the displayed request's ID and the view is keyed
                    // by it, so a sheet left over from a withdrawn request can neither
                    // answer nor hide the prompt of the request that replaced it.
                    YubiKeyPINPromptView(request: request) { pin in
                        yubiKeyConnectionManager.completePINRequest(id: request.id, with: pin)
                        showingPINPrompt = yubiKeyConnectionManager.pendingPINRequest != nil
                    } onCancel: {
                        yubiKeyConnectionManager.completePINRequest(id: request.id, with: nil)
                        showingPINPrompt = yubiKeyConnectionManager.pendingPINRequest != nil
                    }
                    .id(request.id)
                    .themedSubSheet(sheetThemeColors)
                }
            }
            .onChange(of: yubiKeyConnectionManager.pendingPINRequest) { _, newValue in
                showingPINPrompt = newValue != nil
            }
            .onAppear {
                if name.isEmpty {
                    name = key.name
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func runExport() async {
        errorMessage = nil
        armoredOutput = ""
        isExporting = true
        defer { isExporting = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let userID: String
        if trimmedEmail.isEmpty {
            userID = trimmedName
        } else {
            userID = "\(trimmedName) <\(trimmedEmail)>"
        }

        do {
            armoredOutput = try await OpenPGPPublicKeyExport.export(
                sshKey: key,
                userID: userID
            )
        } catch {
            Self.logger.warning("GPG export failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func copy() {
        UIPasteboard.general.string = armoredOutput
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

// MARK: - Share sheet wrapper

/// Thin `UIViewControllerRepresentable` over `UIActivityViewController`
/// so the user can route the armored block through the standard iOS
/// share sheet (AirDrop, Mail, Files, etc.).
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
