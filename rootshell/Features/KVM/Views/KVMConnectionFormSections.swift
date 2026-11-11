//
//  KVMConnectionFormSections.swift
//  rootshell
//
//  Shared KVM over IP form: field state, sections, and config builder, used
//  by the connect sheet and the profile editor.
//

import SwiftUI

struct KVMFormState: Hashable {
    var hostname = ""
    var port = "\(KVMConnectionConfig.defaultPort)"
    var username = KVMConnectionConfig.defaultUsername
    var password = ""
    var savePassword = true
    var keyboardToolbar: VNCConnectionConfig.KeyboardToolbarPreference = .followAppSetting
    var automaticallyEnterFullScreen = false
    var hostKeyboardLayout = KVMInputTranslator.usLayout
    var reverseScrolling = false
    /// Only the `jump*` fields are used; Screen Sharing's jump UI and builder edit them.
    var jump = VNCFormState()

    init() {
        jump.quality = .standard
    }

    init(config: KVMConnectionConfig) {
        hostname = config.host
        port = "\(config.port)"
        username = config.username
        keyboardToolbar = config.keyboardToolbar
        automaticallyEnterFullScreen = config.automaticallyEnterFullScreen
        hostKeyboardLayout = config.hostKeyboardLayout
        reverseScrolling = config.reverseScrolling
        var jumpForm = VNCFormState(config: VNCConnectionConfig(host: config.host, quality: .standard, jump: config.jump))
        jumpForm.quality = .standard
        jump = jumpForm
    }

    var isValid: Bool {
        jumpForm().isValid && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func buildConfig(sanitizeJumpPasswordForPersistence: Bool = false) throws -> KVMConnectionConfig {
        let built = try jumpForm().buildConfig(
            sanitizeJumpPasswordForPersistence: sanitizeJumpPasswordForPersistence)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KVMConnectionConfig.baseURL(host: built.host, port: built.port) != nil else {
            throw VNCFormState.BuildError(message: String(localized: "Please enter a valid hostname."))
        }
        return KVMConnectionConfig(
            host: built.host,
            port: built.port,
            username: user.isEmpty ? KVMConnectionConfig.defaultUsername : user,
            jump: built.jump,
            keyboardToolbar: keyboardToolbar,
            automaticallyEnterFullScreen: automaticallyEnterFullScreen,
            hostKeyboardLayout: hostKeyboardLayout,
            reverseScrolling: reverseScrolling)
    }

    /// Host and port validate and build through the Screen Sharing form.
    private func jumpForm() -> VNCFormState {
        var form = jump
        form.hostname = hostname
        form.port = port
        form.quality = .standard
        return form
    }
}

struct KVMConnectionFormSections: View {
    @Binding var form: KVMFormState
    var hasSavedPassword = false

    var body: some View {
        Section {
            Group {
                TextField("Hostname or IP", text: $form.hostname)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack {
                    Text("HTTPS Port")
                    Spacer()
                    TextField("443", text: $form.port)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
            }
            .themedRow()
        } header: {
            Text("KVM")
        } footer: {
            Text("Connects to the KVM's web interface and streams its H.264 video directly. Supports GL.iNet Comet firmware 1.4 and later.")
        }

        Section {
            Group {
                TextField("Username", text: $form.username)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                SecureField("Password", text: $form.password)
                if hasSavedPassword && form.password.isEmpty {
                    Label("Password saved in Keychain. Enter a new one to replace it.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Toggle("Save Password", isOn: $form.savePassword)
            }
            .themedRow()
        } header: {
            Text("Authentication")
        } footer: {
            if hasSavedPassword && !form.savePassword {
                Text("Turning off Save Password removes the saved password when you save.")
            } else {
                Text("The KVM's web interface account. If two-factor authentication is on, you'll be asked for a code when connecting.")
            }
        }

        Section {
            Picker("Computer's Keyboard Layout", selection: $form.hostKeyboardLayout) {
                ForEach(KVMKeyboardLayouts.all, id: \.self) { keymap in
                    Text(KVMKeyboardLayouts.displayName(keymap)).tag(keymap)
                }
            }
            .themedRow()
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Hardware keys are sent by position. Text from the touch keyboard, dictation and paste is typed using this layout, so pick the one the remote computer uses.")
        }

        Section {
            Toggle("Reverse Scroll Direction", isOn: $form.reverseScrolling)
                .themedRow()
        } header: {
            Text("Mouse")
        } footer: {
            Text("Turn this on if scrolling moves the wrong way. A Mac usually needs it, because it applies its own natural scrolling to the KVM's mouse.")
        }

        RemoteScreenJumpSection(
            form: $form.jump,
            footer: String(localized: "Tunnel the KVM connection through an SSH host."))

        Section {
            Group {
                Toggle("Enter Full Screen on Connect", isOn: $form.automaticallyEnterFullScreen)
                #if !targetEnvironment(macCatalyst)
                Picker("Keyboard Toolbar", selection: $form.keyboardToolbar) {
                    Text("Follow App Setting").tag(VNCConnectionConfig.KeyboardToolbarPreference.followAppSetting)
                    Text("On").tag(VNCConnectionConfig.KeyboardToolbarPreference.on)
                    Text("Off").tag(VNCConnectionConfig.KeyboardToolbarPreference.off)
                }
                #endif
            }
            .themedRow()
        } header: {
            Text("Session")
        }
    }
}
