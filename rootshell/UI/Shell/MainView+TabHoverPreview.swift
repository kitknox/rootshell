//
//  MainView+TabHoverPreview.swift
//  rootshell
//
//  Wires this window's tab hover preview controller: the setting and
//  eligibility gates, renderer occlusion for the mirrored tab, the card's
//  caption and colors, and the hand-off into the tab exposé.
//

import SwiftUI
import UIKit

extension MainView {

    /// One-time wiring; the closures read live state through the property wrappers.
    func installTabHoverPreviewHooks() {
        let previews = tabHoverPreview
        previews.tabsModel = tabsModel
        previews.isEnabled = {
            #if os(visionOS)
            return false
            #else
            return UIDevice.current.userInterfaceIdiom != .phone
                && SettingsStore.shared.value(Settings.Tabs.hoverPreviews)
            #endif
        }
        previews.activation = {
            SettingsStore.shared.value(Settings.Tabs.hoverPreviewActivation)
        }
        previews.startObservingActivationInputs()
        // The floating sidebar counts as a sheet, except to its own rows,
        // which are a preview surface; a top-bar card still yields to it.
        previews.canPresent = { source in
            let sheetBlocks = source == .sidebar ? isSheetPresentedBesidesFloatingTabSidebar : isAnySheetPresented
            return !tabExpose.isActive && !sheetBlocks && appTabSwipeState == nil
                && tabsModel.draggingTabID == nil && tabsModel.fullScreenPaneID == nil
        }
        previews.reduceMotion = {
            SettingsStore.shared.value(Settings.Tabs.barAnimationsDisabled) || UIAccessibility.isReduceMotionEnabled
        }
        previews.style = { tabHoverPreviewStyle() }
        previews.captionProvider = { tab in AnyView(tabHoverPreviewCaption(for: tab)) }
        // Same contract as the exposé: wake the mirrored tab's renderer, and
        // let the reconcile (which treats the previewed tab as visible) put
        // whatever the card left behind back to sleep.
        previews.onWake = { id in setTabOcclusion(tabID: id, visible: true) }
        previews.onReconcile = { reconcileSurfaceOcclusion(reason: "tabHoverPreview") }
        previews.onEnterExpose = { id in
            // Like toggleTabExpose: the floating sidebar yields to the exposé.
            if showingTabSwitcher, !tabSidebarIsDocked { showingTabSwitcher = false }
            guard !isAnySheetPresented else { return }
            tabExpose.present(highlighting: id)
        }
        let expose = tabExpose
        previews.exposeHandoff = TabHoverPreviewExposeHandoff(
            isActive: { expose.isActive },
            isPresented: { expose.phase == .presented },
            progress: { expose.progress },
            restingPreview: { id in expose.previewFrameProvider?(id) }
        )
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        previews.onZoomSnapHaptic = {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    private func tabHoverPreviewStyle() -> TabHoverPreviewView.Style {
        var style = TabHoverPreviewView.Style()
        let theme = resolvedTabBarTheme()
        if let hex = effectiveThemeColors?.background, let color = UIColor(hex: hex) {
            style.backgroundColor = color
        } else {
            style.backgroundColor = UIColor(theme.tabBarBackground)
        }
        #if targetEnvironment(macCatalyst)
        // Keep the window's transparency in the mirrored picture.
        style.backgroundOpacity = transparencyManager.backgroundOpacity
        #endif
        style.isLight = theme.isLight
        if let accent = sheetAccentColor {
            style.accentColor = UIColor(accent)
        }
        return style
    }

    /// Title, badges and ⌘N shortcut under the picture; `.primary` so the
    /// text follows the card's light/dark override over the glass.
    private func tabHoverPreviewCaption(for tab: TabModel) -> some View {
        let theme = resolvedTabBarTheme()
        let shortcut = tabsModel.navigationIndex(of: tab.id).flatMap { keyboardShortcut(for: $0) }
        return TabTitleLine(
            tab: tab,
            allTabs: terminals,
            tmuxBadgePalette: TmuxTabBadgePalette(theme: theme),
            keyboardShortcut: shortcut,
            titleFont: .system(size: 12, weight: .semibold),
            shortcutFont: .system(size: 11, weight: .medium),
            textColor: .primary,
            showsBadges: true,
            showsAttentionDot: SettingsStore.shared.get(Settings.CodingAgents.attentionBadges)
        )
    }
}
