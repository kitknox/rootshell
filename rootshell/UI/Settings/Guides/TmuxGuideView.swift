//
//  TmuxGuideView.swift
//  rootshell
//
//  Explains tmux -CC control mode (gateway tab, auto-hide, tab shortcuts)
//  and zmx's detach key and attach-or-create behaviour, and shows the
//  recommended ~/.tmux.conf lines, so the Multiplexers screen can keep its
//  footers short.
//

import SwiftUI

struct TmuxGuideView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var configCopied = false

    private static let recommendedConfig = """
        set -g mouse on
        set -g set-titles on
        set -g set-titles-string '#T'
        """

    var body: some View {
        List {
            // MARK: - Control Mode
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    guideRow(
                        icon: "rectangle.stack",
                        title: "Gateway Tab",
                        description: "Attaching with tmux -CC keeps a gateway tab for the tmux client itself. Each tmux window opens as its own tab."
                    )

                    Divider()

                    guideRow(
                        icon: "eye.slash",
                        title: "Auto-hide Gateway",
                        description: "When enabled, the gateway tab hides once the session's windows appear and returns when you detach. A hidden gateway always keeps at least one visible window tab."
                    )

                    Divider()

                    guideRow(
                        icon: "eject",
                        title: "Detach Session",
                        description: "Detach Session on any tmux tab (including when the gateway is auto-hidden), or Tabs → Detach Session, leaves control mode cleanly. Window tabs close; sessions keep running. A banner offers Reconnect. Opening the same auto-start profile again focuses the live attachment instead of spawning a second client. Detach All Sessions leaves every multiplexer attachment in the window. ESC on the gateway still detaches too. ⌘⇧X detaches other tmux clients only (not yourself). Assign your own Detach shortcuts under Settings → Keybinds if you want them (defaults omit a chord so we don’t steal macOS Dock ⌘⌥D or anyone’s existing ⌘⌥E)."
                    )

                    Divider()

                    guideRow(
                        icon: "command",
                        title: "Tab Shortcuts",
                        description: "Close Tab Action sets what ⌘W or the tab's ✕ does on a tmux -CC tab. New Tab Action sets what ⌘T does while attached. Outside tmux, ⌘T always opens a local shell."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Control Mode")
            }

            // MARK: - zmx
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    guideRow(
                        icon: "arrow.right.square",
                        title: "Detaching",
                        description: "Detach Session on the tab (or Tabs → Detach Session) closes the local client and leaves the zmx session running for later reattach — zmx’s recommended leave path. Closing the tab instead runs `zmx kill` so the session is destroyed. A banner offers Reconnect after detach; reopening the same auto-start profile focuses a live attachment instead of opening a second client to the same session. Auto-start must use the same session name (default \"main\" under Settings → Multiplexers, or the name on the profile). After detach, `zmx list` on the host should still show that name. You can also press ctrl+\\ yourself to leave zmx and stay in the shell. Set ZMX_NO_DETACH_KEY=1 on the host to disable that key if it conflicts with something you use. If zmx is missing on the host, auto-start prints a clear message and opens a normal shell (it no longer silently pretends to be zmx)."
                    )

                    Divider()

                    guideRow(
                        icon: "plus.square.on.square",
                        title: "Attach or Create",
                        description: "zmx attach joins the session if it exists and creates it otherwise, so auto-start never fails on a fresh host. There is no unnamed default session, so a name is always used — \"main\" unless you set another."
                    )

                    Divider()

                    guideRow(
                        icon: "arrow.up.left.and.arrow.down.right",
                        title: "Resizing",
                        description: "A zmx session has one size shared by every attached client, and the last client to type sets it. Attaching from rootshell will reflow the session for anyone else attached as soon as you type. This is how zmx works, not a rootshell limitation."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("zmx")
            }

            // MARK: - Other Multiplexers
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    guideRow(
                        icon: "rectangle.split.3x1",
                        title: "zellij & herdr",
                        description: "Detach Session also works for raw zellij (Ctrl-o then d) and herdr (Ctrl-b then q) attachments, then closes the local tab. Sessions keep running for later reattach via session discovery. Missing remote binaries print a clear fallback message instead of silently looking like a mux session."
                    )
                }
                .padding(.vertical, 4)
                .themedRow()
            } header: {
                Text("Other Multiplexers")
            }

            // MARK: - Recommended Configuration
            Section {
                Text("Add these lines to enable mouse support and pass window titles through to rootshell tab titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .themedRow()

                HStack(alignment: .top) {
                    Text(Self.recommendedConfig)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = Self.recommendedConfig
                        configCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            configCopied = false
                        }
                    } label: {
                        Image(systemName: configCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(configCopied ? .green : .accentColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                }
                .themedRow()
            } header: {
                Text("Recommended Configuration")
            } footer: {
                Text("Add to ~/.tmux.conf on the remote host.")
            }
        }
        .themedList()
        .navigationTitle("Multiplexer Tips")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    private func guideRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    NavigationView {
        TmuxGuideView()
    }
}
