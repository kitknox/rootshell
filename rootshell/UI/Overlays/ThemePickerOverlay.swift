//
//  ThemePickerOverlay.swift
//  rootshell
//
//  Floating overlay for quick theme selection with favorites and per-tab/window overrides
//

import SwiftUI

/// Floating theme picker overlay that can be opened via keyboard shortcut (Cmd+Shift+T)
/// or presented as a sheet when the available HUD area cannot fit a selectable row.
struct ThemePickerOverlay: View {
    enum Style { case hud, sheet }

    /// Minimum HUD container height needed for the 24pt host inset, the
    /// ultra-compact top row, and at least one 48pt selectable theme row.
    static let minimumHUDHeight: CGFloat = 24 + ultraCompactChromeHeight + 48

    var style: Style = .hud
    @Binding var isPresented: Bool
    let windowId: String
    let currentTabId: UUID?
    /// Available container size from the HUD host so the panel adapts to narrow
    /// displays, landscape, tabletop mode, and on-screen keyboards.
    var availableSize: CGSize? = nil
    let onThemeSelected: (String, ThemePickerScope) -> Void

    @Environment(\.sheetThemeColors) private var sheetThemeColors
    var themeManager = ThemeManager.shared
    @ObservedObject private var favoriteManager = FavoriteThemesManager.shared
    var overrideManager = ThemeOverrideManager.shared

    @State private var scope: ThemePickerScope = .global
    @State private var searchText = ""
    @State private var isSearchFocused = false
    @State private var keyboardSelection: ScrollTarget?
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()

    private var shouldAutoFocusSearch: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        KeyboardTracker.shared.isHardwareKeyboard
        #endif
    }

    private var panelWidth: CGFloat {
        guard let width = availableSize?.width, width > 0 else { return 340 }
        let maxUsable = max(240, width - 24)
        // Fill evenly on compact widths (such as iPhone Duo's front display
        // beside the side rail) so the panel sits centered instead of hugging
        // one side; keep the classic 340pt floating card on wider screens.
        return width <= 420 ? maxUsable : min(340, maxUsable)
    }

    private static let fullChromeHeight: CGFloat = 156
    private static let compactChromeHeight: CGFloat = 112
    private static let ultraCompactChromeHeight: CGFloat = 54
    private static let minPinnedListHeight: CGFloat = 120
    private static let minCompactListHeight: CGFloat = 80

    /// Maximum height the panel may occupy inside `DraggableHUDContainer` (which
    /// reserves `inset * 2` vertically). Nil when unconstrained.
    private var maxPanelHeight: CGFloat? {
        guard let height = availableSize?.height, height > 0 else { return nil }
        return max(0, height - 24)
    }

    /// When the host is too short for the full chrome + a usable list (e.g.,
    /// landscape with the on-screen keyboard visible), fold the scope picker
    /// into the scroll view.
    private var scrollsScope: Bool {
        guard let maxPanelHeight else { return false }
        return maxPanelHeight < Self.fullChromeHeight + Self.minPinnedListHeight
    }

    /// When even the header + search row would starve the results list (e.g.,
    /// a landscape phone with the software keyboard up), collapse the drag
    /// handle, search field, and close button onto one row so the list retains
    /// usable height.
    private var isUltraCompact: Bool {
        guard let maxPanelHeight else { return false }
        return maxPanelHeight < Self.compactChromeHeight + Self.minCompactListHeight
    }

    private var listHeight: CGFloat {
        guard let maxPanelHeight else { return 350 }
        let pinnedChrome: CGFloat
        if isUltraCompact {
            pinnedChrome = Self.ultraCompactChromeHeight
        } else if scrollsScope {
            pinnedChrome = Self.compactChromeHeight
        } else {
            pinnedChrome = Self.fullChromeHeight
        }
        return min(350, max(0, maxPanelHeight - pinnedChrome))
    }

    private enum ScrollTarget: Hashable {
        case current(String)
        case favorite(String)
        case theme(String)
    }

    enum ThemePickerScope: String, CaseIterable {
        case tab = "Tab"
        case window = "Window"
        case global = "Global"

        var displayName: String {
            switch self {
            case .tab: return String(localized: "Tab", comment: "Theme picker scope: apply to current tab")
            case .window: return String(localized: "Window", comment: "Theme picker scope: apply to current window")
            case .global: return String(localized: "Global", comment: "Theme picker scope: apply globally")
            }
        }
    }

    var body: some View {
        // Positioning + dragging is handled by the hosting DraggableHUDContainer
        // in `.hud` mode; `.sheet` mode is used as a fallback when the HUD area
        // is too short to display a selectable row (e.g., tabletop + bottom tabs).
        Group {
            switch style {
            case .hud:
                pickerContent
            case .sheet:
                sheetContent
            }
        }
            .onDisappear {
                arrowKeyRepeatManager.stop()
            }
            .onChange(of: searchText) { _, _ in
                arrowKeyRepeatManager.stop()
                keyboardSelection = navigationRows.first?.id
            }
            .onChange(of: navigationRows.map(\.id)) { _, ids in
                if let keyboardSelection, !ids.contains(keyboardSelection) {
                    self.keyboardSelection = ids.first
                }
            }
            // Awaits the background parse if the picker is opened before it
            // lands; normally it has already finished and this returns at once.
            .task { await themeManager.ensureThemesLoaded() }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            // Outside the ScrollView so the HUD stays draggable by its header;
            // hidden in ultra-compact mode where the drag handle and close
            // button share the search row below.
            if !isUltraCompact {
                pickerHeader
            }

            if !scrollsScope {
                scopePicker
            }

            // Always kept at the same structural slot (and searchFieldBox at
            // the same HStack slot) so SidebarSearchField stays mounted and
            // retains first responder when the software keyboard shrinks height.
            pickerSearchRow

            Divider()

            // Theme list (plus scope picker when compact)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if scrollsScope {
                            scopePicker
                                .padding(.top, 8)
                        }
                        themeListContent(proxy: proxy)
                            .id(searchText)
                    }
                }
                #if !os(visionOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onChange(of: keyboardSelection) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            // Fixed (not max) height: hosted in a UIHostingController, a ScrollView
            // with only a max height collapses under intrinsic sizing.
            .frame(height: listHeight)
        }
        .frame(width: panelWidth)
        .floatingHUDPanelBackground()
        // Cmd-Shift-T / Escape dismissal is handled by host-level UIKeyCommands in
        // DraggableHUDContainer — a SwiftUI .onKeyPress here is preempted on macOS by
        // the app's registered Cmd-Shift-T menu shortcut.
    }

    private var sheetContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scopePicker
                    .padding(.top, 12)

                searchFieldBox
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        themeListContent(proxy: proxy)
                            .id(searchText)
                    }
                    #if !os(visionOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
                    .onChange(of: keyboardSelection) { _, target in
                        guard let target else { return }
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background((sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea())
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private var pickerHeader: some View {
        HStack {
            Text("Theme")
                .font(.headline)
                .fontWeight(.semibold)

            Spacer()

            closeButton
        }
        .padding(.leading, 16)
        .padding(.trailing, PanelTouch.isTouchPlatform ? 6 : 16)
        .padding(.top, PanelTouch.isTouchPlatform ? 4 : 12)
        .padding(.bottom, PanelTouch.isTouchPlatform ? 0 : 8)
    }

    private var closeButton: some View {
        Button(action: { isPresented = false }) {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundColor(.secondary)
                .panelTouchTarget(PanelTouch.isTouchPlatform)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel(Text("Close"))
    }

    private var scopePicker: some View {
        Picker("Scope", selection: $scope) {
            ForEach(ThemePickerScope.allCases, id: \.self) { s in
                Text(s.displayName).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var pickerSearchRow: some View {
        HStack(spacing: isUltraCompact ? 6 : 0) {
            if isUltraCompact {
                // Non-control drag handle so the HUD remains repositionable when
                // the header collapses onto this single row.
                Image(systemName: "line.3.horizontal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 36)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }

            searchFieldBox

            if isUltraCompact {
                closeButton
            }
        }
        .padding(.leading, isUltraCompact ? 10 : 16)
        .padding(.trailing, isUltraCompact ? (PanelTouch.isTouchPlatform ? 4 : 10) : 16)
        .padding(.top, isUltraCompact ? 4 : 0)
        .padding(.bottom, isUltraCompact ? 4 : 12)
    }

    private var searchFieldBox: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            SidebarSearchField(
                text: $searchText,
                placeholder: String(localized: "Search themes"),
                fontSize: 17,
                canFocus: isPresented,
                focusRequestID: shouldAutoFocusSearch ? 1 : 0,
                onMoveUpBegan: { beginKeyboardMovement(by: -1, direction: .up) },
                onMoveUpEnded: { arrowKeyRepeatManager.stop(direction: .up) },
                onMoveDownBegan: { beginKeyboardMovement(by: 1, direction: .down) },
                onMoveDownEnded: { arrowKeyRepeatManager.stop(direction: .down) },
                onEscape: { isPresented = false },
                onSubmit: activateKeyboardSelection,
                onFocusChange: { focused in
                    DispatchQueue.main.async {
                        isSearchFocused = focused
                        if !focused { arrowKeyRepeatManager.stop() }
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 32, minHeight: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, PanelTouch.isTouchPlatform ? 8 : 10)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func themeListContent(proxy: ScrollViewProxy) -> some View {
        LazyVStack(spacing: 4) {
            // Current override info (if any)
            if let overrideInfo = currentOverrideInfo {
                overrideInfoSection(overrideInfo)
            }

            // Tap the pinned theme to reveal it in the full list.
            if searchText.isEmpty, let current = currentThemeInfo {
                currentSection(current) {
                    keyboardSelection = .theme(current.id)
                    withAnimation {
                        proxy.scrollTo(ScrollTarget.theme(current.id), anchor: .center)
                    }
                }
            }

            // Favorites section
            if searchText.isEmpty, !visibleFavoriteThemes.isEmpty {
                favoritesSection(visibleFavoriteThemes)
            }

            // All themes (filtered)
            themesSection
        }
        .padding(.vertical, 8)
    }

    // MARK: - Current Override Info

    private var currentOverrideInfo: (themeName: String, source: ThemeOverrideManager.ThemeSource)? {
        let (themeName, source) = overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId)
        if source != .global {
            return (themeName, source)
        }
        return nil
    }

    @ViewBuilder
    private func overrideInfoSection(_ info: (themeName: String, source: ThemeOverrideManager.ThemeSource)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paintbrush.fill")
                    .foregroundColor(.accentColor)
                Text("Current Override")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }

            HStack {
                Text(info.themeName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("(\(info.source == .tab ? String(localized: "Tab", comment: "Theme override source: tab") : String(localized: "Window", comment: "Theme override source: window")))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Clear") {
                    clearCurrentOverride()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func clearCurrentOverride() {
        if let tabId = currentTabId, overrideManager.hasTabOverride(tabId: tabId) {
            overrideManager.clearTabOverride(tabId: tabId)
        } else if overrideManager.hasWindowOverride(windowId: windowId) {
            overrideManager.clearWindowOverride(windowId: windowId)
        }
    }

    // MARK: - Current Section

    private var currentThemeInfo: ThemeManager.ThemeInfo? {
        let (currentName, _) = overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId)
        return themeManager.availableThemes.first { $0.name == currentName }
    }

    @ViewBuilder
    private func currentSection(_ theme: ThemeManager.ThemeInfo, onTap: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Current")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            themeRow(theme, isFavorite: favoriteManager.isFavorite(theme.id),
                     target: .current(theme.id), onTap: onTap)
                .id(ScrollTarget.current(theme.id))

            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Favorites Section

    private var visibleFavoriteThemes: [ThemeManager.ThemeInfo] {
        let currentThemeId = currentThemeInfo?.id
        return favoriteManager.favoriteThemes().filter { $0.id != currentThemeId }
    }

    @ViewBuilder
    private func favoritesSection(_ themes: [ThemeManager.ThemeInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Favorites")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            ForEach(themes) { theme in
                themeRow(theme, isFavorite: true, target: .favorite(theme.id))
                    .id(ScrollTarget.favorite(theme.id))
            }

            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Themes Section

    private var filteredThemes: [ThemeManager.ThemeInfo] {
        let allThemes = themeManager.availableThemes
        if searchText.isEmpty {
            return allThemes
        }
        return allThemes.filter { theme in
            theme.name.localizedCaseInsensitiveContains(searchText) ||
            theme.family.localizedCaseInsensitiveContains(searchText)
        }
    }

    @ViewBuilder
    private var themesSection: some View {
        let themes = filteredThemes
        if themes.isEmpty {
            Text("No themes found")
                .foregroundColor(.secondary)
                .padding()
        } else {
            ForEach(themes) { theme in
                themeRow(theme, isFavorite: favoriteManager.isFavorite(theme.id), target: .theme(theme.id))
                    .id(ScrollTarget.theme(theme.id))
            }
        }
    }

    // MARK: - Theme Row

    @ViewBuilder
    private func themeRow(_ theme: ThemeManager.ThemeInfo, isFavorite: Bool,
                          target: ScrollTarget, onTap: (() -> Void)? = nil) -> some View {
        Button(action: {
            if let onTap {
                onTap()
            } else {
                selectTheme(theme)
            }
        }) {
            HStack(spacing: 12) {
                // Color preview
                colorPreview(theme)

                // Theme name
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if theme.family != theme.displayName {
                        Text(theme.family)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Current indicator
                if isCurrentTheme(theme) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }

                // Favorite button
                Button(action: { toggleFavorite(theme) }) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .foregroundColor(isFavorite ? .yellow : .secondary.opacity(0.5))
                        .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 40, minHeight: 40)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFavorite
                    ? Text("Remove from Favorites")
                    : Text("Add to Favorites"))
            }
            .padding(.leading, 12)
            .padding(.trailing, PanelTouch.isTouchPlatform ? 4 : 12)
            .padding(.vertical, PanelTouch.isTouchPlatform ? 4 : 8)
            .contentShape(Rectangle())
            .background(isSearchFocused && keyboardSelection == target
                        ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.001))
        }
        .buttonStyle(.plain)
    }

    private func colorPreview(_ theme: ThemeManager.ThemeInfo) -> some View {
        HStack(spacing: 2) {
            // Background color
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: theme.colors.background) ?? .black)
                .frame(width: 20, height: 20)

            // Foreground color
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: theme.colors.foreground) ?? .white)
                .frame(width: 20, height: 20)

            // First palette color (if available)
            if let firstPalette = theme.colors.palette.first {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: firstPalette) ?? .gray)
                    .frame(width: 20, height: 20)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.05))
        .cornerRadius(6)
    }

    private func isCurrentTheme(_ theme: ThemeManager.ThemeInfo) -> Bool {
        let (currentTheme, _) = overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId)
        return theme.name == currentTheme
    }

    // MARK: - Actions

    private var navigationRows: [(id: ScrollTarget, theme: ThemeManager.ThemeInfo)] {
        var rows: [(id: ScrollTarget, theme: ThemeManager.ThemeInfo)] = []
        if searchText.isEmpty {
            if let current = currentThemeInfo {
                rows.append((.current(current.id), current))
            }
            rows += visibleFavoriteThemes.map { (.favorite($0.id), $0) }
        }
        rows += filteredThemes.map { (.theme($0.id), $0) }
        return rows
    }

    private func beginKeyboardMovement(by offset: Int, direction: ArrowKeyRepeatManager.Direction) {
        moveKeyboardSelection(by: offset)
        arrowKeyRepeatManager.start(direction: direction) {
            moveKeyboardSelection(by: offset)
        }
    }

    private func moveKeyboardSelection(by offset: Int) {
        let rows = navigationRows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == keyboardSelection }
        let nextIndex = index.map { min(max($0 + offset, 0), rows.count - 1) } ?? 0
        keyboardSelection = rows[nextIndex].id
    }

    private func activateKeyboardSelection() {
        let rows = navigationRows
        guard let row = rows.first(where: { $0.id == keyboardSelection }) ?? rows.first else { return }
        arrowKeyRepeatManager.stop()
        if case .current = row.id {
            keyboardSelection = .theme(row.theme.id)
        } else {
            selectTheme(row.theme)
        }
    }

    private func selectTheme(_ theme: ThemeManager.ThemeInfo) {
        onThemeSelected(theme.name, scope)
        isPresented = false
    }

    private func toggleFavorite(_ theme: ThemeManager.ThemeInfo) {
        favoriteManager.toggleFavorite(theme.id)
    }

}
