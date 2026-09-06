//
//  ScreenSharingSettingsView.swift
//  rootshell
//
//  Defaults for newly opened Screen Sharing sessions.
//

import SwiftUI

struct ScreenSharingSettingsView: View {
    @Setting(Settings.ScreenSharing.clipboardSyncDefault) private var clipboardSyncDefault
    @Setting(Settings.ScreenSharing.panningDefault) private var panningDefault
    @Setting(Settings.ScreenSharing.controlOptionAsCommandDefault) private var controlOptionAsCommandDefault
    @Setting(Settings.ScreenSharing.routeReservedShortcutsToVNCDefault) private var routeReservedShortcutsToVNCDefault

    private var resolvedClipboardSyncDefault: ScreenSharingClipboardSyncDefault {
        clipboardSyncDefault
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $controlOptionAsCommandDefault) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "keyboard")
                        Text("Control+Option as Command")
                    }
                    .settingRow(Settings.ScreenSharing.controlOptionAsCommandDefault)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Hardware Keyboard", group: .screenSharing)
            } footer: {
                Text("Maps physical Control+Option to remote Command, including Tab and Shift shortcuts. Replaces existing Control+Option shortcuts, including Dictate. Sets the default for new sessions; change it for the current session from the Screen Sharing menu. Turn it off to send Control+Option combinations.")
            }

            Section {
                Toggle(isOn: $routeReservedShortcutsToVNCDefault) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "keyboard.badge.ellipsis")
                        Text("Route Reserved Shortcuts to VNC")
                    }
                    .settingRow(Settings.ScreenSharing.routeReservedShortcutsToVNCDefault)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Reserved Shortcuts", group: .screenSharing)
            } footer: {
                Text("Sends rootshell’s reserved keyboard shortcuts to the remote computer by default in new Screen Sharing sessions. Change it for the current session from the Screen Sharing menu or with Command+Shift+M. Command+Shift+M always stays local.")
            }

            Section {
                Picker(selection: $clipboardSyncDefault) {
                    ForEach(ScreenSharingClipboardSyncDefault.allCases, id: \.rawValue) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.triangle.2.circlepath")
                        Text("Default Clipboard Sync")
                    }
                    .settingRow(Settings.ScreenSharing.clipboardSyncDefault)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Shared Clipboard", group: .screenSharing)
            } footer: {
                Text(clipboardFooterText)
            }

            Section {
                Picker(selection: $panningDefault) {
                    ForEach(ScreenSharingPanningDefault.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "cursorarrow.motionlines")
                        Text("Default Mode")
                    }
                    .settingRow(Settings.ScreenSharing.panningDefault)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Screen Panning", group: .screenSharing)
            } footer: {
                Text("Sets the initial panning mode for new Screen Sharing sessions. You can change it for the current session from the Screen Sharing menu.")
            }
        }
        .themedList()
        .navigationTitle("Screen Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var clipboardFooterText: String {
        switch resolvedClipboardSyncDefault {
        case .automatic:
            return String(localized: "Auto enables Shared Clipboard only when the connection is protected by an SSH or tssh tunnel, VeNCrypt TLS, or Apple ComCryption. You can override it for the current session from the Screen Sharing menu.")
        case .off:
            return String(localized: "New Screen Sharing sessions start with Shared Clipboard off. You can enable it for the current session from the Screen Sharing menu.")
        case .alwaysOn:
            return String(localized: "New Screen Sharing sessions start with Shared Clipboard on, including unencrypted direct VNC connections. Clipboard contents may be exposed on untrusted networks.")
        }
    }
}
