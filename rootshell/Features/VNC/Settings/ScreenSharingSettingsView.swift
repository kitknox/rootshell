//
//  ScreenSharingSettingsView.swift
//  rootshell
//
//  Defaults for newly opened Screen Sharing sessions.
//

import SwiftUI
import rootshellVNC

struct ScreenSharingSettingsView: View {
    @Setting(Settings.ScreenSharing.clipboardSyncDefault) private var clipboardSyncDefault
    @Setting(Settings.ScreenSharing.panningDefault) private var panningDefault
    @Setting(Settings.ScreenSharing.pointerModeDefault) private var pointerModeDefault
    @Setting(Settings.ScreenSharing.pointerSpeed) private var pointerSpeed
    @Setting(Settings.ScreenSharing.cursorRenderingDefault) private var cursorRenderingDefault
    @Setting(Settings.ScreenSharing.cursorSizeDefault) private var cursorSizeDefault
    @Setting(Settings.ScreenSharing.kvmLocalCursorDefault) private var kvmLocalCursorDefault
    @Setting(Settings.ScreenSharing.controlOptionAsCommandDefault) private var controlOptionAsCommandDefault
    @Setting(Settings.ScreenSharing.routeReservedShortcutsToVNCDefault) private var routeReservedShortcutsToVNCDefault
    @Setting(Settings.ScreenSharing.floatingToolbarDefault) private var floatingToolbarDefault
    #if targetEnvironment(macCatalyst)
    /// On Mac this setting has no other use: only remote screens have a toolbar.
    @Setting(Settings.KeyboardToolbar.showWithHardwareKeyboard) private var showKeyboardToolbar
    #endif
    @Setting(Settings.ScreenSharing.touchHoldDelay) private var touchHoldDelay
    @Setting(Settings.ScreenSharing.showsHeldButton) private var showsHeldButton
    @Setting(Settings.ScreenSharing.swipeUpAction) private var swipeUpAction
    @Setting(Settings.ScreenSharing.swipeDownAction) private var swipeDownAction
    @Setting(Settings.ScreenSharing.swipeLeftAction) private var swipeLeftAction
    @Setting(Settings.ScreenSharing.swipeRightAction) private var swipeRightAction
    @Setting(Settings.ScreenSharing.fourFingerNavigation) private var fourFingerNavigation
    @Setting(Settings.ScreenSharing.rememberLastScreen) private var rememberLastScreen
    @State private var downloadStore = VNCDownloadStore.shared

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
                        Text("Route Reserved Shortcuts to Remote Computer")
                    }
                    .settingRow(Settings.ScreenSharing.routeReservedShortcutsToVNCDefault)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Reserved Shortcuts", group: .screenSharing)
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("Sends rootshell’s keyboard shortcuts, such as Command+T and Command+1, to the remote computer by default in new Screen Sharing sessions. Change it for the current session from the Screen Sharing menu or with Command+Shift+M. Command+Shift+M always stays local.")
                #else
                Text("Sends rootshell’s reserved keyboard shortcuts to the remote computer by default in new Screen Sharing sessions. Change it for the current session from the Screen Sharing menu or with Command+Shift+M. Command+Shift+M always stays local.")
                #endif
            }

            #if !os(visionOS)
            Section {
                #if targetEnvironment(macCatalyst)
                Toggle(isOn: Binding(
                    get: { showKeyboardToolbar },
                    set: {
                        showKeyboardToolbar = $0
                        NotificationCenter.default.post(name: .keyboardToolbarHardwareSettingChanged, object: nil)
                    }
                )) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "ellipsis.rectangle")
                        Text("Show Keyboard Toolbar")
                    }
                    .settingRow(Settings.KeyboardToolbar.showWithHardwareKeyboard)
                }
                .themedRow()
                #endif
                Toggle(isOn: $floatingToolbarDefault) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "rectangle.bottomthird.inset.filled")
                        Text("Floating Toolbar")
                    }
                    .settingRow(Settings.ScreenSharing.floatingToolbarDefault)
                }
                .themedRow()
                #if targetEnvironment(macCatalyst)
                // Also under Keyboard; here is where a Mac user looks for it.
                NavigationLink(value: SettingsSearchDestination.toolbarKeys) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "keyboard")
                        Text("Toolbar Keys")
                        Spacer()
                        if KeyboardToolbarManager.shared.isCustomized {
                            Text("Customized")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }
                .themedRow()
                #endif
            } header: {
                SettingGroupHeader("Keyboard Toolbar", group: .screenSharing)
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("Show Keyboard Toolbar adds a bar of keys to Screen Sharing and KVM sessions whose connection follows the app setting. Change it for the current session from the Screen Sharing menu. Floating Toolbar puts the bar in glass over the remote screen, where you can drag and fold it away; turn it off to dock the bar along the bottom. Click and hold the bar's chevron to switch the current session.")
                #else
                Text("Shows the keyboard toolbar in a glass bar over the remote screen that you can drag and fold away. Turn it off to dock the toolbar to the keyboard. Sets the default for new sessions; touch and hold the bar's chevron, or the docked toolbar's keyboard key, to switch the current one.")
                #endif
            }
            #endif

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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 12) {
                            SettingsIcon(systemName: "hand.tap")
                            Text("Hold Delay")
                        }
                        .settingRow(Settings.ScreenSharing.touchHoldDelay)
                        Spacer()
                        Text(String(format: "%.2f s", touchHoldDelay))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                    Slider(value: $touchHoldDelay, in: 0.15...1.0, step: 0.05)
                }
                .padding(.vertical, 4)
                .themedRow()

                Toggle(isOn: $showsHeldButton) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "computermouse")
                        Text("Show Held Button")
                    }
                    .settingRow(Settings.ScreenSharing.showsHeldButton)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Mouse Buttons", group: .screenSharing)
            } footer: {
                Text("Works in Touch and Trackpad modes. Three-finger tap to middle-click. Hold two fingers still, then drag with the right button held; hold three fingers for the middle button. Hold Delay is how long fingers rest before a button goes down, one-finger drags included. Show Held Button names the button while it is held.")
            }

            Section {
                swipePicker("Swipe Up", systemImage: "arrow.up", selection: $swipeUpAction,
                            key: Settings.ScreenSharing.swipeUpAction)
                swipePicker("Swipe Down", systemImage: "arrow.down", selection: $swipeDownAction,
                            key: Settings.ScreenSharing.swipeDownAction)
                swipePicker("Swipe Left", systemImage: "arrow.left", selection: $swipeLeftAction,
                            key: Settings.ScreenSharing.swipeLeftAction)
                swipePicker("Swipe Right", systemImage: "arrow.right", selection: $swipeRightAction,
                            key: Settings.ScreenSharing.swipeRightAction)
            } header: {
                SettingGroupHeader("Three-Finger Swipes", group: .screenSharing)
            } footer: {
                Text("Sends the Mac keyboard shortcut for each action, so the defaults match a Mac trackpad. Turn them off for computers that are not Macs. Applies to touch on iPhone and iPad.")
            }

            #if !os(visionOS) && !targetEnvironment(macCatalyst)
            Section {
                Toggle(isOn: $fourFingerNavigation) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "hand.raised.fingers.spread")
                        Text("Use Four Fingers")
                    }
                    .settingRow(Settings.ScreenSharing.fourFingerNavigation)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Tab and Pane Swipes", group: .screenSharing)
            } footer: {
                Text("Swipe Gestures that switch tabs or panes use three fingers over a remote screen, and only in a direction whose Three-Finger Swipe above is Off. Turn this on to use four fingers instead, leaving every three-finger swipe to the remote computer. On iPad, a four-finger swipe switches apps unless Four & Five Finger Gestures is turned off in the Settings app under Multitasking & Gestures.")
            }
            #endif

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

            Section {
                Toggle(isOn: $kvmLocalCursorDefault) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "smallcircle.filled.circle")
                        Text("Local Cursor")
                    }
                    .settingRow(Settings.ScreenSharing.kvmLocalCursorDefault)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("KVM", group: .screenSharing)
            } footer: {
                Text("Draws a dot where your pointer is, ahead of the remote computer’s own pointer in the video. Sets the default for new KVM sessions; change it for the current session from the Screen Sharing menu.")
            }

            Section {
                Toggle(isOn: $rememberLastScreen) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "photo.on.rectangle")
                        Text("Remember Last Screen")
                    }
                    .settingRow(Settings.ScreenSharing.rememberLastScreen)
                }
                .themedRow()
                .onChange(of: rememberLastScreen) { _, enabled in
                    // The store also deletes on its own; this makes it immediate.
                    if !enabled { RemoteScreenSnapshotStore.shared.removeAll() }
                }
            } header: {
                SettingGroupHeader("Last Screen", group: .screenSharing)
            } footer: {
                Text("Keeps a picture of the last screen seen on each Screen Sharing and KVM connection. It shows softened while the connection is made again, and as a thumbnail beside a saved profile. Pictures are encrypted, stay on this device, and are never synced or backed up. Turn this off to delete them.")
            }

            Section {
                NavigationLink(value: SettingsSearchDestination.screenSharingDownloads) {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.down.circle")
                        Text("Downloads")
                        Spacer()
                        if downloadStore.hasLoaded {
                            Text(ScreenSharingDownloadsView.size(downloadStore.totalByteCount))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .themedRow()
            } header: {
                Text("File Transfer")
            } footer: {
                Text("Files downloaded with Drag to Download that are still on this device. Save, share, or delete them without reconnecting.")
            }
        }
        .themedList()
        .task { await downloadStore.refresh() }
        .navigationTitle("Screen Sharing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swipePicker(
        _ title: LocalizedStringKey,
        systemImage: String,
        selection: Binding<ScreenSharingSwipeAction>,
        key: SettingKey<ScreenSharingSwipeAction>
    ) -> some View {
        Picker(selection: selection) {
            ForEach(ScreenSharingSwipeAction.allCases, id: \.rawValue) { action in
                Text(action.displayName).tag(action)
            }
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: systemImage)
                Text(title)
            }
            .settingRow(key)
        }
        .themedRow()
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
