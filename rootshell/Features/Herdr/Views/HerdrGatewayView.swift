// Copyright (c) 2026 Kit Knox / Rootshell LLC

import SwiftUI

/// Covers only the gateway pane, leaving any unrelated splits usable.
struct HerdrGatewayView: View {
    @Setting(Settings.Theme.themedUI) private var themedUIEnabled
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48
    @State private var showsInstallInstructions = false

    struct Fallback {
        let isForced: Bool
    }

    let tabID: UUID?
    let windowID: String
    let sessionName: String
    let hasSnapshot: Bool
    let hasTabs: Bool
    let isActive: Bool
    let isCreating: Bool
    let errorMessage: String?
    let fallback: Fallback?
    let workspaces: () -> Void
    let newTab: () -> Void
    let retryConnection: () -> Void
    let detach: () -> Void
    let installPresentationChanged: (Bool) -> Void

    var body: some View {
        let theme = resolvedTheme
        gatewayContent(theme: theme)
            .background(theme.themeColors?.background ?? Color(uiColor: .systemBackground))
            .environment(\.sheetThemeColors, theme.themeColors)
            .tint(theme.accentColor)
            .environment(\.colorScheme, theme.colorScheme ?? systemColorScheme)
            .sheet(isPresented: $showsInstallInstructions, onDismiss: {
                installPresentationChanged(false)
            }) {
                HerdrInstallInstructionsView(isFallbackForced: fallback?.isForced == true)
                    .themedSheet(themeColors: theme.themeColors, accentColor: theme.accentColor,
                                 colorScheme: theme.colorScheme)
            }
            #if targetEnvironment(macCatalyst)
            .catalystCursorRegion()
            #endif
    }

    /// This pane has its own hosting controller, so MainView's sheet-theme
    /// environment does not reach it. Resolve the same colors in the gateway's
    /// tab/window context; SwiftUI observes theme and UI-override changes here.
    private var resolvedTheme: ResolvedSheetTheme {
        guard themedUIEnabled else { return .none }
        return HerdrTheme.resolve(tabID: tabID, windowID: windowID)
    }

    private func gatewayContent(theme: ResolvedSheetTheme) -> some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 500
            let usesColumns = fallback != nil && geometry.size.width >= 960
                && !dynamicTypeSize.isAccessibilitySize
            // Preserve view identity when resizing changes the arrangement.
            let layout = usesColumns
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 48))
                : AnyLayout(VStackLayout(spacing: isCompact ? 24 : 32))

            ScrollView {
                layout {
                    sessionSection
                        .frame(maxWidth: usesColumns ? 300 : .infinity)
                    if let fallback {
                        fallbackSection(fallback)
                            .padding(isCompact ? 20 : 28)
                            .background(theme.themeColors?.rowBackground ?? Color.primary.opacity(0.035),
                                        in: RoundedRectangle(cornerRadius: 20))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                    }
                }
                .frame(maxWidth: usesColumns ? 1080 : 680)
                .padding(isCompact ? 16 : 32)
                .frame(maxWidth: .infinity)
                // A minimum, not a fixed height: center within roomy panes,
                // but let tall content scroll from its top in short splits.
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionSection: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "h.square")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.secondary)
                Text(sessionName)
                    .font(.title.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if isCreating {
                    ProgressView("Creating herdr tab…")
                } else if isActive {
                    if hasTabs {
                        Text("Connected to herdr")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No herdr tabs")
                            .font(.title3)
                        Text("Open a tab to start a shell in this session.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView(hasSnapshot ? "Reconnecting to herdr…" : "Connecting to herdr…")
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { sessionButtons }
                VStack(spacing: 12) { sessionButtons }
            }
            .controlSize(.large)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var sessionButtons: some View {
        Button(action: newTab) {
            Label("New herdr Tab", systemImage: "plus.rectangle.on.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isActive || isCreating)
        Button("Workspaces", systemImage: "square.grid.2x2", action: workspaces)
            .buttonStyle(.bordered)
        if !isActive {
            Button("Retry Connection", action: retryConnection)
                .buttonStyle(.bordered)
        }
        Button("Detach from herdr", action: detach)
            .buttonStyle(.bordered)
    }

    private func fallbackSection(_ fallback: Fallback) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("herdr fallback mode")
                .font(.title3.weight(.semibold))
            Text("You get most control mode functionality with regular herdr, including native text selection with automatic scrolling while selecting. No herdr modifications are required.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("The main difference is scrolling: scrollback is less smooth than fully pixel-smooth native scrolling, and global scrollback search is unavailable.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("If these scrolling and search improvements aren’t important to you, staying with regular herdr is the safer choice.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if fallback.isForced {
                Text("Fallback mode is forced in Debug settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Optional: Full Control Mode") {
                installPresentationChanged(true)
                showsInstallInstructions = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

private struct HerdrInstallInstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let isFallbackForced: Bool

    private static let installCommand = "curl -fsSL https://github.com/kitknox/herdr/releases/download/rootshell-channel/install.sh | sh"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Full control mode adds fully pixel-smooth native scrolling and global scrollback search.")
                    Label("This optional upgrade uses rootshell’s experimental herdr fork. It may introduce breaking changes.", systemImage: "exclamationmark.triangle")
                        .fontWeight(.semibold)
                    Text("Regular herdr already provides most control mode functionality. Staying with it is the safer choice if you don’t need these improvements.")
                        .foregroundStyle(.secondary)
                    CopyableValueBlock(
                        title: String(localized: "Install on the herdr host"),
                        value: Self.installCommand,
                        font: .system(.callout, design: .monospaced)
                    )
                    Text("Run this command in a shell on the macOS or Linux host running herdr, then open a new shell to use the installed fork.")
                    Text("Save your work before restarting the intended herdr server or named session. Stopping a server terminates its pane processes. Installing the new binary alone does not upgrade an already running server.")
                    Text("From a shell outside herdr, restart that session with the installed fork, then detach and reconnect to control mode in rootshell.")
                    if isFallbackForced {
                        Text("Turn off “Force herdr Fallback Mode” in Debug settings before reconnecting for full control mode.")
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background((sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea())
            .navigationTitle("Optional Full Control Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
