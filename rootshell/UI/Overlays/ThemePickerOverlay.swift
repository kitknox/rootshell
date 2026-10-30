//
//  ThemePickerOverlay.swift
//  rootshell
//
//  Floating overlay for quick theme selection with favorites and per-tab/window overrides
//

import SwiftUI

/// Floating theme picker overlay that can be opened via keyboard shortcut (Cmd+Shift+T)
struct ThemePickerOverlay: View {
    @Binding var isPresented: Bool
    @Environment(\.edgeSidebarTitleContext) private var edgeSidebarTitleContext
    let windowId: String
    let currentTabId: UUID?
    let onThemeSelected: (String, ThemePickerScope) -> Void

    var fillsSidebar = false
    var profileSelection: String? = nil

    var themeManager = ThemeManager.shared
    @ObservedObject private var favoriteManager = FavoriteThemesManager.shared
    var overrideManager = ThemeOverrideManager.shared

    @State private var scope: ThemePickerScope = .global
    @State private var searchText = ""
    @State private var isSearchFocused = false
    @State private var keyboardSelection: ScrollTarget?
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()

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
        // Positioning + (no) dragging is handled by the hosting DraggableHUDContainer.
        // A native UIKit host is required: as a plain SwiftUI overlay the search
        // field's focus made .onKeyPress steal the X-button click on macOS.
        Group {
            if profileSelection != nil {
                pickerContent
            } else {
                pickerContent.floatingHUDPanelBackground()
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
            // Header with scope picker and close button
            if profileSelection != nil {
                EmptyView()
            } else if edgeSidebarTitleContext != nil {
                EdgeSidebarHeader(
                    title: String(localized: "Theme"),
                    systemImage: "paintpalette",
                    onClose: { isPresented = false }
                ) {
                    EmptyView()
                }
            } else {
                HStack {
                    Text("Theme").font(.headline).fontWeight(.semibold)

                    Spacer()

                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            // Scope picker
            if profileSelection == nil {
                Picker("Scope", selection: $scope) {
                    ForEach(ThemePickerScope.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                SidebarSearchField(
                    text: $searchText,
                    placeholder: String(localized: "Search themes"),
                    fontSize: 17,
                    canFocus: isPresented,
                    focusRequestID: 1,
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
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.08))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            // Theme list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let profileSelection {
                            Button {
                                onThemeSelected("", scope)
                                isPresented = false
                            } label: {
                                HStack {
                                    Text("Use Default")
                                    Spacer()
                                    if profileSelection.isEmpty {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
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
                .id(searchText)
                .onChange(of: keyboardSelection) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .center)
                }
            }
            // Fixed (not max) height: hosted in a UIHostingController, a ScrollView
            // with only a max height collapses under intrinsic sizing.
            .frame(height: fillsSidebar ? nil : 350)
        }
        .frame(width: fillsSidebar ? nil : 340)
        // Cmd-Shift-T / Escape dismissal is handled by host-level UIKeyCommands in
        // DraggableHUDContainer — a SwiftUI .onKeyPress here is preempted on macOS by
        // the app's registered Cmd-Shift-T menu shortcut.
    }

    // MARK: - Current Override Info

    private var currentOverrideInfo: (themeName: String, source: ThemeOverrideManager.ThemeSource)? {
        guard profileSelection == nil else { return nil }
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
        themeManager.availableThemes.first { $0.name == selectedThemeName }
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
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
        theme.name == selectedThemeName
    }

    private var selectedThemeName: String {
        if let profileSelection { return profileSelection }
        return overrideManager.resolveTheme(tabId: currentTabId, windowId: windowId).0
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
