import SwiftUI

struct MultiplexerSettingsView: View {
    @Setting(Settings.Multiplexer.sessionDiscoverySortOrder) private var sortOrder
    @Setting(Settings.Multiplexer.tmuxSessionName) private var sessionName
    @Setting(Settings.Multiplexer.tmuxCustomCommand) private var customCommand
    @Setting(Settings.Multiplexer.herdrSessionName) private var herdrSessionName
    @Setting(Settings.Multiplexer.herdrCustomCommand) private var herdrCustomCommand
    @Setting(Settings.Multiplexer.zmxSessionName) private var zmxSessionName
    @Setting(Settings.Multiplexer.zmxCustomCommand) private var zmxCustomCommand
    @Setting(Settings.Multiplexer.tmuxTabCloseAction) private var tabCloseAction

    private var hasCustomCommand: Bool {
        !customCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var autoStartCommandSummary: String {
        if hasCustomCommand {
            return "Custom"
        }
        let name = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "main" : name
    }

    private var herdrAutoStartCommandSummary: String {
        if !herdrCustomCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Custom"
        }
        let name = herdrSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "default" : name
    }

    private var zmxAutoStartCommandSummary: String {
        if !zmxCustomCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Custom"
        }
        let name = zmxSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unlike herdr there is no unnamed default session to fall back to, so
        // the placeholder is a real session name.
        return name.isEmpty ? SSHConfig.zmxDefaultSessionName : name
    }

    private var discoveryFooterText: String {
        let base = "Checks for active sessions after an SSH connection. Skipped for connections with multiplexer auto-start enabled."
        #if targetEnvironment(macCatalyst)
        return base + " Discover Local Sessions also scans when opening a local macOS shell tab."
        #else
        return base
        #endif
    }

    var body: some View {
        List {
            Section {
                SettingToggle(Settings.Multiplexer.tmuxSessionDiscovery, title: "Discover tmux Sessions", icon: MultiplexerType.tmux.iconName)
                    .themedRow()

                SettingToggle(Settings.Multiplexer.zellijSessionDiscovery, title: "Discover zellij Sessions", icon: MultiplexerType.zellij.iconName)
                    .themedRow()

                SettingToggle(Settings.Multiplexer.herdrSessionDiscovery, title: "Discover herdr Sessions", icon: MultiplexerType.herdr.iconName)
                    .themedRow()

                SettingToggle(Settings.Multiplexer.zmxSessionDiscovery, title: "Discover zmx Sessions", icon: MultiplexerType.zmx.iconName)
                    .themedRow()

                #if targetEnvironment(macCatalyst)
                SettingToggle(Settings.Multiplexer.localSessionDiscovery, title: "Discover Local Sessions", icon: "desktopcomputer")
                    .themedRow()
                #endif

                Picker(selection: $sortOrder) {
                    ForEach(SessionDiscoverySortOrder.allCases, id: \.rawValue) { order in
                        Text(order.displayName).tag(order)
                    }
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "arrow.up.arrow.down")
                        Text("Sort Order")
                    }
                    .settingRow(Settings.Multiplexer.sessionDiscoverySortOrder)
                }
                .themedRow()
            } header: {
                SettingGroupHeader("Session Discovery", group: .multiplexer)
            } footer: {
                Text(discoveryFooterText)
            }

            Section {
                SettingToggle(Settings.Multiplexer.tabExposeMultiplexer, title: "Show Multiplexer Tabs", icon: "rectangle.grid.2x2")
                    .themedRow()
            } header: {
                SettingGroupHeader("Tab Exposé", group: .multiplexer)
            } footer: {
                Text("On a tab attached to tmux, zellij, or herdr, Tab Exposé opens on that session's own tabs with live previews, and swiping sideways returns to your app tabs. Reads the session's layout and pane contents over the connection the tab already holds while the exposé is open.")
            }

            Section {
                SettingToggle(Settings.Multiplexer.tmuxAutoHideGatewayOnAttach, title: "Auto-hide Gateway on Attach", icon: "eye.slash")
                    .themedRow()

                NavigationLink {
                    TmuxTabCloseActionPickerView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "xmark.rectangle")
                        Text("Close Tab Action")
                        SettingPinTag(Settings.Multiplexer.tmuxTabCloseAction.erased)
                        Spacer()
                        Text(tabCloseAction.displayName)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
                .settingContextMenu(Settings.Multiplexer.tmuxTabCloseAction)
            } header: {
                SettingGroupHeader("tmux Control Mode", group: .multiplexer)
            } footer: {
                Text("These settings apply while attached with tmux -CC control mode, where each tmux window is its own tab.")
            }

            Section {
                NewTabActionSettingsRow()
            } header: {
                Text("New Tabs")
            } footer: {
                Text("New Tab Action applies globally, including outside multiplexer sessions. The tab-bar + always opens Connections.")
            }

            Section {
                NavigationLink {
                    TmuxAutoStartCommandView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "play.rectangle")
                        Text("Auto-Start Command")
                        Spacer()
                        Text(autoStartCommandSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("tmux Auto-Start", group: .multiplexer)
            } footer: {
                Text("The tmux command used when auto-start is enabled on a connection.")
            }

            Section {
                NavigationLink {
                    HerdrAutoStartCommandView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "play.rectangle")
                        Text("Auto-Start Command")
                        Spacer()
                        Text(herdrAutoStartCommandSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("herdr Auto-Start", group: .multiplexer)
            } footer: {
                Text("The herdr command used when auto-start is enabled on a connection.")
            }

            Section {
                NavigationLink {
                    ZmxAutoStartCommandView()
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "play.rectangle")
                        Text("Auto-Start Command")
                        Spacer()
                        Text(zmxAutoStartCommandSummary)
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                .themedRow()
            } header: {
                SettingGroupHeader("zmx Auto-Start", group: .multiplexer)
            } footer: {
                Text("The zmx command used when auto-start is enabled on a connection.")
            }

            Section {
                NavigationLink {
                    TmuxGuideView()
                } label: {
                    Label("Multiplexer Tips", systemImage: "questionmark.circle")
                }
                .themedRow()
            }
        }
        .themedList()
        .navigationTitle("Multiplexers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Pushed list for choosing the tmux -CC tab-close action. Each option gets a
/// title, leading icon, and a full-width description below it — so the
/// explanations have room instead of piling into the Multiplexers form footer
/// as a wall of text. Mirrors the SSH key security picker. (id=tmux-tab-close-action)
struct TmuxTabCloseActionPickerView: View {
    @Setting(Settings.Multiplexer.tmuxTabCloseAction) private var tabCloseAction

    var body: some View {
        List {
            Section {
                ForEach(TmuxTabCloseAction.allCases, id: \.rawValue) { action in
                    Button {
                        tabCloseAction = action
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.iconName)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.displayName)
                                    .foregroundColor(.primary)
                                Text(action.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if tabCloseAction == action {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                Text("Controls what ⌘W or the tab's ✕ does on a tmux -CC tab.")
            }
        }
        .themedList()
        .navigationTitle("Close Tab Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.multiplexer]) }
    }
}

/// Global New Tab behavior, shared by Terminal and Multiplexer settings.
struct NewTabActionPickerView: View {
    @Setting(Settings.Tabs.newTabAction) private var newTabAction

    var body: some View {
        List {
            Section {
                ForEach(NewTabAction.allCases, id: \.rawValue) { action in
                    Button {
                        newTabAction = action
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: action.iconName)
                                .foregroundColor(.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.displayName)
                                    .foregroundColor(.primary)
                                Text(action.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if newTabAction == action {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .themedRow()
                }
            } footer: {
                Text("Controls the New Tab command (⌘T by default, or your custom shortcut) in every session. The tab-bar + always opens Connections.")
            }
        }
        .themedList()
        .navigationTitle("New Tab Action")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { SettingsScreenPinMenu(groups: [.tabs]) }
    }
}

/// Both settings locations edit the same registered preference.
struct NewTabActionSettingsRow: View {
    @Setting(Settings.Tabs.newTabAction) private var action

    var body: some View {
        NavigationLink {
            NewTabActionPickerView()
        } label: {
            HStack(spacing: 12) {
                SettingsIcon(systemName: "plus.rectangle.on.rectangle")
                Text("New Tab Action")
                SettingPinTag(Settings.Tabs.newTabAction.erased)
                Spacer()
                Text(action.displayName)
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
        }
        .themedRow()
        .settingContextMenu(Settings.Tabs.newTabAction)
    }
}
