// Copyright (c) 2026 Kit Knox / Rootshell LLC
import SwiftUI

/// Gateway and sidebar content have independent hosting controllers. Resolve
/// their sheet colors in the same tab/window context as the app's other UI.
enum HerdrTheme {
    static func resolve(tabID: UUID?, windowID: String) -> ResolvedSheetTheme {
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
            accentColor: accent, colorScheme: derived.isLight ? .light : .dark)
    }
}

struct HerdrWorkspaceSheet: View {
    let request: HerdrWorkspaceDashboardRequest
    @Setting(Settings.Theme.themedUI) private var themedUIEnabled

    var body: some View {
        let controller = request.controller
        let theme = themedUIEnabled ? HerdrTheme.resolve(
            tabID: controller.tabsModel.selectedTabID ?? controller.gatewayTabID,
            windowID: controller.hostWindowId) : .none
        HerdrWorkspaceDashboardView(request: request)
            .themedSheet(themeColors: theme.themeColors, accentColor: theme.accentColor, colorScheme: theme.colorScheme)
    }
}
