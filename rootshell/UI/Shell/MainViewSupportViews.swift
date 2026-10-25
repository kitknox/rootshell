//
//  MainViewSupportViews.swift
//  rootshell
//
//  Standalone helper views and modifiers used by MainView's body and
//  modifier pipeline, extracted for build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// ConnectionSheetModifier has been replaced by ConnectionSidebarModifier
// (see ConnectionSidebarModifier.swift)

// MARK: - AI Agent Sheet Modifier

#if !CHINA_BUILD
/// Presents AI Agent overlay as sheet on iPhone only.
/// On iPad/Catalyst/visionOS, this is a no-op as the AI Agent is embedded in tab content.
struct AIAgentSheetModifier: ViewModifier {
    @Binding var showOverlay: Bool
    let session: AIAgentSession?
    let tabID: UUID

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
                .sheet(isPresented: $showOverlay) {
                    if let session = session {
                        AIAgentOverlayView(isPresented: $showOverlay, session: session, tabID: tabID)
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                }
        } else {
            // iPad/Catalyst/visionOS: no-op, AI Agent is embedded in tab content
            content
        }
    }
}
#endif

// MARK: - Health Popover Overlay

/// Hovered-tab health tooltip. Receives the hovered `TabModel` reference
/// (class, structural under Observation) and reads `tab.connectionHealth`
/// inside its own body. With the previous body-scope inline form, MainView
/// read `tab.connectionHealth` directly which registered per-tab health
/// observation on MainView.body — keepalive ping bursts during network
/// instability would then re-invalidate the whole MainView graph just to
/// re-evaluate whether to show the popover.
struct HealthPopoverOverlay: View {
    let hover: TabHoverController
    let tabsModel: TabsModel
    @Binding var tabFrames: [UUID: CGRect]
    let geometryWidth: CGFloat
    let enabled: Bool
    /// The hover preview card takes the same spot; the tooltip yields to it.
    /// Read here, not in MainView.body, so the card's show/hide invalidates
    /// only this overlay.
    let previews: TabHoverPreviewController

    var body: some View {
        let hoveredTabId = hover.hoveredTabId
        // Persistent container so the popover's insertion and removal animate.
        // Fixed full size keeps `.position` coordinates stable as it empties.
        ZStack {
            popover(hoveredTabId: hoveredTabId)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeOut(duration: 0.2), value: hoveredTabId)
    }

    @ViewBuilder
    private func popover(hoveredTabId: UUID?) -> some View {
        if enabled,
           let hoveredTabId,
           let tab = tabsModel.tabs.first(where: { $0.id == hoveredTabId }),
           previews.previewedTabID != tab.id,
           let health = tab.connectionHealth,
           let tabFrame = tabFrames[hoveredTabId] {
            ConnectionHealthPopover(health: health)
                .fixedSize()
                .position(
                    x: min(max(tabFrame.midX, 150), geometryWidth - 150),
                    y: tabFrame.maxY + 120
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                    )
                )
                .zIndex(1000)
        }
    }
}

// MARK: - Session Census Observer

/// Walks every tab's panes here rather than in MainView.body, keeping that
/// census off every MainView body pass.
struct SessionCensusObserver: View {
    let tabsModel: TabsModel
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: WindowSessionCensus.profileCounts(in: tabsModel.tabs)) { _, _ in
                onChange()
            }
    }
}

// MARK: - Current Window Title Accessor

/// Wraps `WindowAccessor` so the selected tab's title is read inside this
/// child view's body, not at MainView body construction time. Without this
/// indirection, MainView reads `terminals[selectedTabIndex].title` itself,
/// which registers per-tab title Observation on `MainView.body` — every
/// reconnect-driven OSC 0/2 title update then invalidates the entire
/// MainView graph and contributes to the 0x8BADF00D scene-update budget
/// pressure documented in the crash IPS files.
struct CurrentWindowTitleAccessor: View {
    let tabsModel: TabsModel

    var body: some View {
        let title: String = {
            let selectedTab = tabsModel.selectedTab ?? tabsModel.tabs.first
            guard let selectedTab else { return "Terminal" }
            return selectedTab.title
        }()
        WindowAccessor(windowTitle: title)
    }
}

// MARK: - Tab Indicator Overlay

/// Overlay shown briefly when switching tabs with the tab bar hidden.
/// Displays the current tab title, optional keyboard shortcut, and position indicator dots.
///
/// Takes the `TabModel` reference rather than a `String tabTitle` so the
/// `tab.title` Observation read happens inside this view's body. With the
/// previous `String`-parameter shape, MainView had to read the title at
/// construction time, which registered per-tab title observation on
/// `MainView.body` and made every reconnect-driven OSC 0/2 title update
/// invalidate the entire MainView graph.
struct TabIndicatorOverlay: View {
    let tab: TabModel?
    let allTabs: [TabModel]
    let currentIndex: Int
    let totalCount: Int
    let keyboardShortcut: String?
    let tmuxBadgePalette: TmuxTabBadgePalette

    var body: some View {
        VStack(spacing: 12) {
            // Tab title with optional keyboard shortcut
            if let tab {
                TabTitleLine(
                    tab: tab,
                    allTabs: allTabs,
                    tmuxBadgePalette: tmuxBadgePalette,
                    keyboardShortcut: keyboardShortcut
                )
            } else {
                Text("Terminal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            // Position indicator dots
            if totalCount > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<totalCount, id: \.self) { index in
                        Circle()
                            .fill(index == currentIndex ? Color.white : Color.white.opacity(0.4))
                            .frame(width: index == currentIndex ? 8 : 6, height: index == currentIndex ? 8 : 6)
                            .animation(.easeInOut(duration: 0.15), value: currentIndex)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

// MARK: - Container Corner Modifier

struct ContainerCornerModifier: ViewModifier {
    func body(content: Content) -> some View {
#if os(visionOS)
        // containerCornerOffset is not available on visionOS
        content
#else
        if #available(iOS 26.0, *) {
            content.containerCornerOffset(.leading, sizeToFit: true)
        } else {
            content
        }
#endif
    }
}

// MARK: - Titlebar Tabs Modifier

struct TitlebarTabsModifier: ViewModifier {
    let isEnabled: Bool
    let fullScreenEnabled: Bool

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        if isEnabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
#elseif !os(visionOS)
        if fullScreenEnabled {
            content.ignoresSafeArea(.container, edges: .top)
        } else {
            content
        }
#else
        content
#endif
    }
}
