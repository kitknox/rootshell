import SwiftUI
import Observation
import UIKit

extension Notification.Name {
    nonisolated static let toggleVisorOverlay = Notification.Name("com.rootshell.toggleVisorOverlay")
}

nonisolated extension Settings {
    enum iPadVisor {
        static let enabled = SettingKey("ipad.visor.enabled", default: false,
            group: .visor, policy: .localByDefault,
            title: String(localized: "Enable iPad Visor"))
    }
}

/// Shared defaults; persisted overrides retain their existing values.
nonisolated enum VisorDefaultShortcut {
    static let carbonKeyCode = 53 // Escape
    static let carbonModifiers = 512 // shiftKey
}

extension KeybindAction {
    static var supportsVisorOverlay: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    /// Keep the binding editable while disabled, but release its keys to the terminal.
    var isAvailableForVisorDispatch: Bool {
        guard self == .toggle_visor else { return true }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return UIDevice.current.userInterfaceIdiom == .pad && iPadVisorSettings.shared.enabled
        #else
        return false
        #endif
    }
}

@MainActor
@Observable
final class iPadVisorSettings {
    static let shared = iPadVisorSettings()
    var enabled: Bool {
        didSet {
            SettingsStore.shared.set(Settings.iPadVisor.enabled, enabled)
            KeybindManager.shared.keybindsDidChange.send()
        }
    }
    private init() {
        enabled = SettingsStore.shared.get(Settings.iPadVisor.enabled)
        SettingsRefreshHub.shared.register(keys: [Settings.iPadVisor.enabled.name]) { [weak self] _ in
            let value = SettingsStore.shared.get(Settings.iPadVisor.enabled)
            if self?.enabled != value { self?.enabled = value }
        }
    }
}

struct iPadVisorSettingsView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Bindable private var settings = iPadVisorSettings.shared
    @ObservedObject private var keybinds = KeybindManager.shared
    @State private var editing = false
    @State private var outcome: KeybindEditorOutcome?

    var body: some View {
        Form {
            Section {
                SettingToggle(Settings.iPadVisor.enabled, isOn: $settings.enabled, title: "Enable Visor")
                    .themedRow()
                Button { editing = true } label: {
                    HStack {
                        Text("Keyboard Shortcut")
                        Spacer()
                        Text(keybinds.keybind(for: .toggle_visor)?.sequence.symbolDescription ?? String(localized: "Unassigned"))
                            .foregroundStyle(.secondary)
                    }
                }
                .themedRow()
            } footer: {
                Text("A separate local terminal above each iPad window. Shift–Escape toggles Visor by default. Drag its bottom edge to resize.")
            }
        }
        .themedList()
        .navigationTitle("Visor")
        .sheet(isPresented: $editing, onDismiss: applyOutcome) {
            KeybindEditorView(action: .toggle_visor) { _, result in outcome = result }
                .themedSubSheet(sheetThemeColors)
        }
    }

    private func applyOutcome() {
        guard let outcome else { return }
        switch outcome {
        case .captured(let sequence): keybinds.setOverride(sequence: sequence, action: .toggle_visor)
        case .restoreDefault: keybinds.removeOverride(for: .toggle_visor)
        case .unbind: keybinds.unbindAction(.toggle_visor)
        }
        self.outcome = nil
    }
}
