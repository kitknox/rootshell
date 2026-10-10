// Copyright (c) 2026 Kit Knox / Rootshell LLC

import SwiftUI

/// Covers only the gateway pane, leaving any unrelated splits usable.
struct HerdrGatewayView: View {
    @Setting(Settings.Theme.themedUI) private var themedUIEnabled
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48
    @State private var showsInstallInstructions = false

    let tabID: UUID?
    let windowID: String
    let sessionName: String
    let hasSnapshot: Bool
    let hasTabs: Bool
    let isActive: Bool
    let isCreating: Bool
    let errorMessage: String?
    /// Install or upgrade advice for this host, if any.
    let upgrade: HerdrUpgradePrompt?
    let isFallbackForced: Bool
    /// Labels of other control streams on the session.
    let otherClients: [String]
    let workspaces: () -> Void
    let newTab: () -> Void
    let retryConnection: () -> Void
    let detach: () -> Void
    /// Types the install command into the gateway shell (detaching first).
    let typeIntoShell: ((String) -> Void)?

    private var showsCard: Bool { upgrade != nil || isFallbackForced || !otherClients.isEmpty }

    var body: some View {
        let theme = resolvedTheme
        gatewayContent(theme: theme)
            // Pane sizing settles over several passes on restore; the layout
            // switches below must snap, not animate.
            .transaction { $0.animation = nil }
            // Matches the terminal fill so a backdrop or the desktop shows through.
            .background((theme.themeColors?.background ?? Color(uiColor: .systemBackground))
                .opacity(TransparencyManager.shared.effectiveBackgroundOpacity))
            .environment(\.sheetThemeColors, theme.themeColors)
            .tint(theme.accentColor)
            .environment(\.colorScheme, theme.colorScheme ?? systemColorScheme)
            .sheet(isPresented: $showsInstallInstructions) {
                HerdrInstallInstructionsView(isFallbackForced: isFallbackForced, typeIntoShell: typeIntoShell)
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
            let usesColumns = showsCard && geometry.size.width >= 960
                && !dynamicTypeSize.isAccessibilitySize
            // Preserve view identity when resizing changes the arrangement.
            let layout = usesColumns
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 48))
                : AnyLayout(VStackLayout(spacing: isCompact ? 24 : 32))

            ScrollView {
                layout {
                    sessionSection
                        .frame(maxWidth: usesColumns ? 300 : .infinity)
                    if showsCard {
                        adviceSection
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

    private var adviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !otherClients.isEmpty {
                Label(otherClients.count == 1
                      ? String(localized: "Also viewed by \(otherClients[0])")
                      : String(localized: "Also viewed by \(otherClients.count) other clients: \(otherClients.joined(separator: ", "))"),
                      systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let upgrade {
                Text(upgrade.cardHeadline)
                    .font(.title3.weight(.semibold))
                Text(upgrade.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if upgrade.reason == .controlStreamMissing {
                    Text("Fallback mode gives you most control mode functionality with regular herdr. The fork adds pixel-smooth native scrolling, global scrollback search, and viewing one tab from several devices.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if isFallbackForced {
                Text("Fallback mode is forced in Debug settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if upgrade != nil {
                HerdrInstallCommandBlock(typeIntoShell: typeIntoShell)
                Button("Install Instructions") {
                    showsInstallInstructions = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

/// The fork's install command with copy and, when a host shell is at hand,
/// a button that types it there.
struct HerdrInstallCommandBlock: View {
    let typeIntoShell: ((String) -> Void)?

    var body: some View {
        CopyableValueBlock(
            title: String(localized: "Install on the herdr host"),
            value: HerdrUpgradePrompt.installCommand,
            font: .system(.callout, design: .monospaced)
        )
        if let typeIntoShell {
            Button {
                typeIntoShell(HerdrUpgradePrompt.installCommand)
            } label: {
                Label("Type into Gateway Shell", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
        }
    }
}

struct HerdrInstallInstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    let isFallbackForced: Bool
    let typeIntoShell: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Full control mode adds pixel-smooth native scrolling, global scrollback search, and viewing one tab from several devices at once.")
                    Label("This uses rootshell’s herdr fork, which tracks upstream herdr closely but may introduce breaking changes.", systemImage: "exclamationmark.triangle")
                        .fontWeight(.semibold)
                    HerdrInstallCommandBlock(typeIntoShell: typeIntoShell.map { type in
                        { command in dismiss(); type(command) }
                    })
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
            .navigationTitle("Install the herdr Fork")
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
