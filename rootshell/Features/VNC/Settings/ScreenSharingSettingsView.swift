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
    @Setting(Settings.ScreenSharing.pointerModeDefault) private var pointerModeDefault
    @Setting(Settings.ScreenSharing.pointerSpeed) private var pointerSpeed
    @Setting(Settings.ScreenSharing.cursorRenderingDefault) private var cursorRenderingDefault
    @Setting(Settings.ScreenSharing.cursorSizeDefault) private var cursorSizeDefault
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

            Section {
                Picker(selection: $pointerModeDefault) {
                    ForEach(ScreenSharingPointerModeDefault.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "cursorarrow.rays")
                        Text("Default Mode")
                    }
                    .settingRow(Settings.ScreenSharing.pointerModeDefault)
                }
                .themedRow()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "speedometer")
                            Text("Speed")
                        }
                        .settingRow(Settings.ScreenSharing.pointerSpeed)
                        Spacer()
                        Text(pointerSpeedLabel)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    Slider(value: $pointerSpeed, in: 0.5...3.0, step: 0.25)
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                SettingGroupHeader("Pointer", group: .screenSharing)
            } footer: {
                Text("Touch: tap to click, double-tap to double-click, two-finger tap to right-click. Drag to scroll, hold then drag to move things. Two fingers pan the screen, pinch zooms.\nTrackpad: one finger moves the pointer, tap to click, two-finger tap to right-click. Hold then drag to move things, two-finger swipe to scroll, pinch zooms. Speed applies to Trackpad only.\nThe default for new sessions. The Screen Sharing menu switches the current one.")
            }

            Section {
                Picker(selection: $cursorRenderingDefault) {
                    ForEach(ScreenSharingCursorRenderingDefault.allCases, id: \.rawValue) { rendering in
                        Text(rendering.displayName).tag(rendering)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "cursorarrow")
                        Text("Rendering")
                    }
                    .settingRow(Settings.ScreenSharing.cursorRenderingDefault)
                }
                .themedRow()

                if cursorRenderingDefault == .local {
                    Picker(selection: $cursorSizeDefault) {
                        ForEach(ScreenSharingCursorSizeDefault.allCases, id: \.rawValue) { size in
                            Text(size.displayName).tag(size)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "arrow.up.left.and.arrow.down.right")
                            Text("Size")
                        }
                        .settingRow(Settings.ScreenSharing.cursorSizeDefault)
                    }
                    .themedRow()
                }
            } header: {
                SettingGroupHeader("Cursor", group: .screenSharing)
            } footer: {
                Text(cursorRenderingDefault == .local
                    ? "Local draws the Trackpad pointer on this device, sharp at any zoom. Size applies to that pointer; Medium is the Mac's own. Rendering applies to new connections."
                    : "Remote lets the Mac draw the pointer into the picture: every shape, moving with the picture rather than your finger. Rendering applies to new connections.")
            }
        }
        .themedList()
        .navigationTitle("Screen Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The slider steps by 0.25, so half steps need only one decimal. Printing
    /// both would render the common values as "1.50×" beside a coarse control.
    private var pointerSpeedLabel: String {
        let halfSteps = pointerSpeed * 2
        let isHalfStep = halfSteps.rounded() == halfSteps
        return String(format: isHalfStep ? "%.1f×" : "%.2f×", pointerSpeed)
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
