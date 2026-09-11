// Copyright (c) 2026 Kit Knox / Rootshell LLC

import SwiftUI

/// Covers only the gateway pane, leaving any unrelated splits usable.
struct HerdrGatewayView: View {
    @Setting(Settings.Theme.themedUI) private var themedUIEnabled
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 48

    struct Fallback {
        let reason: String?
        let latestNotice: String?
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
    let newTab: () -> Void
    let retryConnection: () -> Void
    let detach: () -> Void

    var body: some View {
        let theme = resolvedTheme
        gatewayContent
            .background(theme.themeColors?.background ?? Color(uiColor: .systemBackground))
            .environment(\.sheetThemeColors, theme.themeColors)
            .tint(theme.accentColor)
            .environment(\.colorScheme, theme.colorScheme ?? systemColorScheme)
            #if targetEnvironment(macCatalyst)
            .catalystCursorRegion()
            #endif
    }

    /// This pane has its own hosting controller, so MainView's sheet-theme
    /// environment does not reach it. Resolve the same colors in the gateway's
    /// tab/window context; SwiftUI observes theme and UI-override changes here.
    private var resolvedTheme: ResolvedSheetTheme {
        guard themedUIEnabled else { return .none }
        let manager = ThemeManager.shared
        let (name, _) = ThemeOverrideManager.shared.resolveTheme(tabId: tabID, windowId: windowID)
        let colors = name == manager.currentTheme
            ? manager.currentThemeInfo?.colors
            : manager.themeInfo(for: name)?.colors
        guard let colors, let derived = ThemeUIColorDerivation.derive(from: colors) else { return .none }
        let overrides = ThemeUIOverridesManager.shared.overrides(for: name)
        let background = overrides.sheetBackground.flatMap { Color(hex: $0) } ?? derived.sheetBackground
        let row = overrides.sheetRowBackground.flatMap { Color(hex: $0) } ?? derived.sheetRowBackground
        let accent = overrides.sheetAccent.flatMap { Color(hex: $0) } ?? derived.sheetAccent
        return ResolvedSheetTheme(
            themeColors: SheetThemeColors(background: background, rowBackground: row.opacity(0.92), accentColor: accent),
            accentColor: accent,
            colorScheme: derived.isLight ? .light : .dark
        )
    }

    private var gatewayContent: some View {
        GeometryReader { geometry in
            let isCompact = geometry.size.width < 500
            let usesColumns = fallback != nil && geometry.size.width >= 960
                && !dynamicTypeSize.isAccessibilitySize
            // AnyLayout keeps Copy feedback and disclosure state in place
            // when resizing a pane changes the arrangement.
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
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
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
            Text("Vanilla herdr 0.9.0 or newer supports native scroll indicators and live text selection in fallback mode.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if fallback.isForced {
                Text("Fallback mode is forced in Debug settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if fallback.reason != nil || fallback.latestNotice != nil {
                DisclosureGroup("Fallback details") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = fallback.reason {
                            Text(reason)
                        }
                        if let notice = fallback.latestNotice, notice != fallback.reason {
                            Text(notice)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}
