import SwiftUI

struct SavedPasswordsView: View {
    @State private var passwordManager = SSHPasswordManager.shared
    @State private var showingDeleteConfirmation = false
    @State private var passwordToDelete: SSHSavedPassword?
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var headerReplay = 0

    var body: some View {
        List {
            Section {
                SavedPasswordsHeaderView(
                    passwordCount: passwordManager.savedPasswords.count,
                    replayTrigger: headerReplay
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            .onChange(of: passwordManager.savedPasswords.count) { old, new in
                if new > old { headerReplay += 1 }
            }

            if !passwordManager.savedPasswords.isEmpty {
                Section {
                    ForEach(passwordManager.savedPasswords) { password in
                        SavedPasswordRow(password: password)
                            .themedRow()
                    }
                    .onDelete(perform: deletePasswords)
                }
            }

            // Default security settings for new passwords
            Section {
                SecurityOptionPicker(
                    title: "Storage Level",
                    options: KeyStorageLevel.allCases,
                    selection: passwordManager.defaultStorageLevel,
                    symbol: \.iconName,
                    name: \.displayName,
                    detail: \.passwordDescription,
                    onSelect: { passwordManager.defaultStorageLevel = $0 }
                )
                .themedRow()

                SecurityOptionPicker(
                    title: "Authentication",
                    options: KeyAuthRequirement.allCases,
                    selection: passwordManager.defaultAuthRequirement,
                    symbol: \.iconName,
                    name: \.displayName,
                    detail: { requirement in
                        // A synced password can't carry a device-bound access
                        // control, so say where the prompt actually comes from.
                        guard requirement != .none, passwordManager.defaultStorageLevel == .iCloudSync else {
                            return requirement.passwordDescription
                        }
                        return requirement.passwordDescription + " " + String(
                            localized: "Since a password synced with iCloud can't carry a device-bound access control, rootshell asks for it itself.",
                            comment: "Saved password authentication: added when the password syncs with iCloud"
                        )
                    },
                    onSelect: { passwordManager.defaultAuthRequirement = $0 }
                )
                .themedRow()
            } header: {
                Text("Default Security Settings")
            } footer: {
                Text("These settings apply to newly saved passwords. Existing passwords keep their original settings.")
            }
        }
        .themedList()
        .refreshable {
            await passwordManager.refreshPasswordsAsync()
            headerReplay += 1
        }
        .navigationTitle("Saved Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete Password", isPresented: $showingDeleteConfirmation, presenting: passwordToDelete) { password in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deletePassword(password)
            }
        } message: { password in
            Text("Are you sure you want to delete the saved password for '\(password.displayName)'?")
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func deletePasswords(at offsets: IndexSet) {
        for index in offsets {
            let password = passwordManager.savedPasswords[index]
            passwordToDelete = password
            showingDeleteConfirmation = true
        }
    }

    private func deletePassword(_ password: SSHSavedPassword) {
        do {
            try passwordManager.deletePassword(id: password.id)
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

/// Every option on screen at once as an icon tile, with the chosen one's
/// explanation underneath; the menu picker hid both behind a tap.
private struct SecurityOptionPicker<Option: Hashable>: View {
    let title: LocalizedStringKey
    let options: [Option]
    let selection: Option
    let symbol: (Option) -> String
    let name: (Option) -> String
    let detail: (Option) -> String
    let onSelect: (Option) -> Void

    @Namespace private var pillNamespace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var bounceCounts: [Option: Int] = [:]

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            (stacked ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))) {
                ForEach(options, id: \.self) { option in
                    tile(option, stacked: stacked)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .sensoryFeedback(.selection, trigger: selection)
            .accessibilityRepresentation {
                Picker(title, selection: Binding(get: { selection }, set: onSelect)) {
                    ForEach(options, id: \.self) { option in
                        Text(name(option)).tag(option)
                    }
                }
            }

            // Every explanation laid out at once, only the chosen one visible,
            // so the row keeps its height as the selection moves.
            ZStack(alignment: .topLeading) {
                ForEach(options, id: \.self) { option in
                    Text(detail(option))
                        .opacity(option == selection ? 1 : 0)
                        .accessibilityHidden(option != selection)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.2), value: selection)
        }
        .padding(.vertical, 6)
    }

    private func tile(_ option: Option, stacked: Bool) -> some View {
        let isSelected = option == selection
        return Button {
            guard !isSelected else { return }
            bounceCounts[option, default: 0] += 1
            withAnimation(.smooth(duration: 0.35)) { onSelect(option) }
        } label: {
            let icon = Image(systemName: symbol(option))
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: bounceCounts[option, default: 0])
                .frame(height: 24)
            let label = Text(name(option))
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
            Group {
                if stacked {
                    HStack(spacing: 10) {
                        icon
                        label.multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                } else {
                    VStack(spacing: 5) {
                        icon
                        label
                            .multilineTextAlignment(.center)
                            .lineLimit(2, reservesSpace: true)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.tint.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(.tint.opacity(0.85), lineWidth: 1.5)
                        }
                        .matchedGeometryEffect(id: "pill", in: pillNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One line per account: user and host on the leading side, how the password
/// is kept and when it was last used on the trailing side. Stacks at
/// accessibility text sizes, where a narrow screen can't fit both sides.
struct SavedPasswordRow: View {
    let password: SSHSavedPassword

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(password.username)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(hostLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !stacked { Spacer(minLength: 8) }
            VStack(alignment: stacked ? .leading : .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: password.storageLevel.iconName)
                        .accessibilityLabel(password.storageLevel.displayName)
                        .help(password.storageLevel.displayName)
                    if password.authRequirement != .none {
                        Image(systemName: password.authRequirement.iconName)
                            .accessibilityLabel(password.authRequirement.displayName)
                            .help(password.authRequirement.displayName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let lastUsed = password.lastUsedDate {
                    Text(lastUsed, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Host plus any non-default port; IPv6 literals get brackets so the port reads apart.
    private var hostLabel: String {
        guard password.port != 22 else { return password.host }
        let host = password.host.contains(":") ? "[\(password.host)]" : password.host
        return "\(host):\(password.port)"
    }
}

#Preview {
    NavigationStack {
        SavedPasswordsView()
    }
}

// The shared descriptions are written about keys.
private extension KeyStorageLevel {
    var passwordDescription: String {
        switch self {
        case .deviceOnly:
            return String(localized: "Stays on this device. Not in backups or sync, so it's lost if the device is reset.", comment: "Saved password storage description: device only")
        case .backupOnly:
            return String(localized: "Included in encrypted device backups, but not synced to iCloud.", comment: "Saved password storage description: include in backups")
        case .iCloudSync:
            return String(localized: "Syncs across your devices with iCloud Keychain.", comment: "Saved password storage description: iCloud sync")
        }
    }
}

private extension KeyAuthRequirement {
    var passwordDescription: String {
        switch self {
        case .none:
            return String(localized: "Used without asking, once your device is unlocked.", comment: "Saved password authentication description: none")
        case .perSession:
            return String(localized: "Asks for Face ID, Touch ID, or your passcode the first time it's used after opening the app.", comment: "Saved password authentication description: once per session")
        case .perUse:
            return String(localized: "Asks for Face ID, Touch ID, or your passcode every time it's used to connect.", comment: "Saved password authentication description: every use")
        }
    }
}
