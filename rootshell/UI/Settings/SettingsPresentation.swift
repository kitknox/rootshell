//
//  SettingsPresentation.swift
//  rootshell
//
//  Settings sheet and sidebar presentation.
//

import SwiftUI

struct SettingsSplitView: View {
    var initialDestination: SettingsDestination? = nil
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) var dismiss
    @ObservedObject private var menuShortcuts = MenuShortcutState.shared
    @State private var navigationPath = NavigationPath()
    @State private var hasNavigatedToInitialDestination = false
    @State private var navigateToVPN = false

    @State private var showDebugSettings = false
    @State private var searchReservedHeight: CGFloat = 88

    private var showsRootSearch: Bool {
        navigationPath.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationStack(path: $navigationPath) {
                SettingsHomeList(showDebugSettings: $showDebugSettings)
                    .safeAreaInset(edge: .bottom) {
                        if showsRootSearch {
                            Color.clear.frame(height: searchReservedHeight)
                        }
                    }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") {
                                if let onClose {
                                    onClose()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    }
                    .navigationDestination(for: SettingsSection.self) { section in
                        sectionDetail(for: section)
                    }
                    .navigationDestination(for: SettingsDestination.self) { destination in
                        switch destination {
                        case .vpn:
                            #if !CHINA_BUILD
                            VPNSettingsView()
                            #else
                            EmptyView()
                            #endif
                        }
                    }
                    .navigationDestination(for: SettingsSearchDestination.self) { destination in
                        settingsSearchDestinationView(for: destination)
                    }
                    .onAppear {
                        handleInitialDestination()
                    }
            }

            if showsRootSearch {
                SettingsFloatingSearchChrome(
                    reservedHeight: $searchReservedHeight,
                    onSelect: handleSearchSelection
                )
            }
        }
        .background(toggleShortcutCatcher)
    }

    /// Catches the `open_settings` shortcut (CMD-, by default) while Settings
    /// is presented so a second press closes it — mirrors the tab sidebar's
    /// `toggleShortcutCatcher`. The terminal has resigned first responder
    /// behind the cover, so its UIKeyCommand can't catch the second press.
    /// Skipped where a menu bar exists: `.openSettings` toggles both ways from
    /// the menu item, and a duplicate shortcut would blank that item's glyph.
    /// Single-chord bindings only (sequence bindings keep working through the
    /// normal KeySequenceTracker path).
    @ViewBuilder
    private var toggleShortcutCatcher: some View {
        if !MenuShortcutState.menuRailOwnsShortcuts,
           let binding = KeybindManager.shared.activeBindings
            .first(where: { $0.action == .open_settings }),
           !binding.sequence.isSequence,
           let shortcut = menuShortcuts.shortcuts[.open_settings] {
            Button("") {
                if let onClose {
                    onClose()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(shortcut)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func sectionDetail(for section: SettingsSection) -> some View {
        switch section {
        case .appearance:
            SettingsAppearanceSection()
        case .terminal:
            SettingsTerminalSection()
        case .connections:
            SettingsConnectionsSection(navigateToVPN: $navigateToVPN)
        case .aiAssistant:
            SettingsAISection()
        case .privacyData:
            SettingsPrivacySection()
        case .notifications:
            SettingsNotificationsSection()
        case .about:
            SettingsAboutSection(externalShowDebugSettings: $showDebugSettings)
        }
    }

    private func handleInitialDestination() {
        guard let initialDestination, !hasNavigatedToInitialDestination else { return }
        hasNavigatedToInitialDestination = true
        DispatchQueue.main.async {
            switch initialDestination {
            case .vpn:
                navigationPath.append(SettingsSection.connections)
                DispatchQueue.main.async {
                    navigateToVPN = true
                }
            }
        }
    }

    private func handleSearchSelection(_ entry: SettingsSearchEntry) {
        switch entry.action {
        case .section(let section):
            navigationPath.append(section)
        case .destination(let destination):
            navigationPath.append(destination)
        }
    }
}

// MARK: - Settings Sheet Modifier

/// Presents settings differently based on device:
/// - iPhone: standard `.sheet()` with `SettingsView`
/// - visionOS: standard `.sheet()` with `SettingsSplitView`
/// - iPad/Catalyst: the shared deterministic `SidePanelOverlay` (trailing
///   edge), the same binding-driven overlay the tab and connection sidebars
///   use — so CMD-, toggles instantly and every dismiss animates identically.
struct SettingsSheetModifier: ViewModifier {
    @Binding var showSettings: Bool
    var settingsDestination: SettingsDestination?
    var onDismiss: (() -> Void)?

    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?

    // Re-injected into the iPad/Catalyst overlay below: SidePanelOverlay hosts
    // its content in a window-level UIHostingController that inherits none of
    // MainView's environment, and cursor settings read this object
    // (CursorEffectPreviewContainer). The sheet branches inherit it naturally.
    @EnvironmentObject private var ghosttyApp: Ghostty.App

    @AppStorage("themedUI") private var themedUIEnabled: Bool = true

    private var isPhone: Bool {
#if os(visionOS)
        return false
#else
        return UIDevice.current.userInterfaceIdiom == .phone
#endif
    }

    func body(content: Content) -> some View {
        if isPhone {
            content
                .sheet(isPresented: $showSettings, onDismiss: { onDismiss?() }) {
                    SettingsView(initialDestination: settingsDestination)
                        .themedSheet(themeColors: themeColors, accentColor: accentColor, colorScheme: colorScheme)
                }
        } else {
        #if os(visionOS)
            content
                .sheet(isPresented: $showSettings, onDismiss: { onDismiss?() }) {
                    SettingsSplitView(initialDestination: settingsDestination, onClose: { showSettings = false })
                        .themedSheet(themeColors: themeColors, accentColor: accentColor, colorScheme: colorScheme)
                }
        #else
            // iPad/Catalyst: the SAME deterministic, binding-driven overlay the
            // tab and connection sidebars use. Flipping `showSettings` animates
            // the slide-out directly (no deferred flip, no gate), so rapid
            // back-to-back CMD-, presses toggle reliably and every dismiss —
            // keyboard, Escape, Done, backdrop — looks identical.
            content
                .overlay {
                    SidePanelOverlay(
                        isPresented: $showSettings,
                        edge: .trailing,
                        panelWidth: 420,
                        backdropAlpha: themeColors != nil ? 0.4 : 0.5,
                        resignFirstResponderOnDismiss: true,
                        escapeDismisses: true,
                        content: {
                            SettingsSidebarPanelView(
                                settingsDestination: settingsDestination,
                                themeColors: themeColors,
                                accentColor: accentColor,
                                colorScheme: colorScheme,
                                onClose: { showSettings = false }
                            )
                            .environmentObject(ghosttyApp)
                        }
                    )
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard)
                }
                .onChange(of: showSettings) { _, newValue in
                    // The overlay has no onDismiss callback; mirror the sheet
                    // paths by clearing the requested destination on close.
                    if !newValue { onDismiss?() }
                }
        #endif
        }
    }
}

// MARK: - Settings Sidebar Panel

/// Panel content hosted inside the shared `SidePanelOverlay` (iPad/Catalyst).
/// The overlay owns the backdrop and the slide transform; this view only
/// supplies the panel chrome (rounded background, shadow, theming) plus the
/// Escape catcher — mirroring `ConnectionSidebarPanelView`.
private struct SettingsSidebarPanelView: View {
    let settingsDestination: SettingsDestination?
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    let onClose: () -> Void

    private let sidebarMaxWidth: CGFloat = 420
    private let sidebarCornerRadius: CGFloat = 20
    private let sidebarVerticalContentPadding: CGFloat = 6

    @AppStorage("hideWindowTitleBar") private var hideWindowTitleBar: Bool = false

    /// With the title bar hidden the OS may still report a top safe-area
    /// inset for chrome that isn't there, leaving a gap above the panel;
    /// extend to the top edge like the main content does.
    private var hiddenTitlebarTopEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
        hideWindowTitleBar ? .top : []
        #else
        []
        #endif
    }

    private var sheetBackground: Color {
        themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    /// Left edge rounded (the trailing/right panel's mirror of the connection
    /// sidebar); the right edge is flush against the screen.
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: sidebarCornerRadius,
            bottomLeadingRadius: sidebarCornerRadius,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            panelShape.fill(sheetBackground)

            SettingsSplitView(initialDestination: settingsDestination, onClose: onClose)
                .environment(\.sheetThemeColors, themeColors)
                .padding(.vertical, sidebarVerticalContentPadding)

            // Escape closes from inside the panel (the terminal is no longer
            // first responder behind the overlay).
            Button("") {
                onClose()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: sidebarMaxWidth)
        .frame(maxHeight: .infinity)
        // Set the scheme via the ENVIRONMENT, not `preferredColorScheme`: this
        // is an in-window overlay (like the connection/tab panels), and
        // `preferredColorScheme` would propagate up and darken the whole
        // window. The old fullScreenCover could use it because a cover is its
        // own presentation context.
        .optionalColorSchemeEnvironment(colorScheme)
        .clipShape(panelShape)
        .shadow(color: .black.opacity(0.3), radius: 20, x: -5)
        .tint(accentColor)
        .ignoresSafeArea(.keyboard)
        .ignoresSafeArea(.container, edges: hiddenTitlebarTopEdges)
        #if os(iOS)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        #endif
    }
}
