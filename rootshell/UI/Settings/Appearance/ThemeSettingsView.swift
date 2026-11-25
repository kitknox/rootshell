//
//  ThemeSettingsView.swift
//  rootshell
//
//  Theme selection and import settings.
//

import SwiftUI
import UniformTypeIdentifiers

struct ThemeSettingsView: View {
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    var themeManager = ThemeManager.shared
    @ObservedObject private var dayNightManager = DayNightThemeManager.shared
    @ObservedObject private var favoriteManager = FavoriteThemesManager.shared
    @ObservedObject private var customThemeManager = CustomThemeManager.shared
    @State private var searchText = ""
    @State private var filterMode: ThemeManager.ThemeFilterMode = .all
    @State private var editingMode: ThemeEditingMode = .day
    @State private var activeEditorMode: ThemeEditorView.EditorMode?
    @State private var showingFilePicker = false
    @State private var showingImportNameSheet = false
    @State private var pendingImportURL: URL?
    @State private var importName = ""
    @State private var showingImportError = false
    @State private var importErrorMessage = ""
    @State private var showingDeleteConfirmation = false
    @State private var themeToDelete: ThemeManager.ThemeInfo?
    @State private var uiOverridesEditTarget: ThemeManager.ThemeInfo?

    /// Which theme slot we're editing when day/night mode is enabled
    enum ThemeEditingMode: String, CaseIterable {
        case day = "Day"
        case night = "Night"

        var localizedName: String {
            switch self {
            case .day: return String(localized: "Day")
            case .night: return String(localized: "Night")
            }
        }

        var icon: String {
            switch self {
            case .day: return "sun.max.fill"
            case .night: return "moon.fill"
            }
        }
    }

    var body: some View {
        PanelSideRailReader { inRail in
            VStack(spacing: 0) {
                // Header: Search + Light/Dark filter
                filterHeader(inRail: inRail)

                // Responsive content
                if horizontalSizeClass == .compact {
                    // iPhone: List layout with inline terminal preview
                    themeList
                } else {
                    // iPad/Mac/unfolded Duo: 2-column grid
                    themeGrid
                }
            }
        }
        // Awaits the background parse if the browser is opened before it lands;
        // normally it has already finished and this returns immediately.
        .task { await themeManager.ensureThemesLoaded() }
        .background((sheetThemeColors?.background ?? Color(uiColor: .systemGroupedBackground)).ignoresSafeArea())
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        activeEditorMode = .new()
                    } label: {
                        Label("Create Theme", systemImage: "paintbrush")
                    }

                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import Theme File...", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label("Add Theme", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                dayNightMenu
            }
            SettingsScreenPinMenu(groups: [.theme])
        }
        .sheet(item: $activeEditorMode) { mode in
            ThemeEditorView(mode: mode)
                .presentationDragIndicator(.visible)
                .themedSubSheet(sheetThemeColors)
        }
        .sheet(item: $uiOverridesEditTarget) { theme in
            ThemeUIOverridesEditorView(theme: theme)
                .presentationDragIndicator(.visible)
                .themedSubSheet(sheetThemeColors)
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.plainText, .item],
            allowsMultipleSelection: false
        ) { result in
            handleThemeFileImport(result: result)
        }
        .sheet(isPresented: $showingImportNameSheet) {
            themeImportNameSheet
                .presentationDragIndicator(.visible)
                .themedSubSheet(sheetThemeColors)
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage)
        }
        .alert("Delete Theme", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let theme = themeToDelete,
                   let custom = customThemeManager.customThemes.first(where: { $0.name == theme.name }) {
                    customThemeManager.deleteTheme(id: custom.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let theme = themeToDelete {
                Text("Are you sure you want to delete \"\(theme.name)\"? This cannot be undone.")
            }
        }
    }

    // MARK: - Day/Night Menu

    private var dayNightMenu: some View {
        Menu {
            Toggle(isOn: $dayNightManager.enabled) {
                Label("Match System Theme", systemImage: "circle.lefthalf.filled")
            }

            if dayNightManager.enabled {
                Divider()

                Label(
                    dayNightManager.isCurrentlyLight ? "Currently: Light Mode" : "Currently: Dark Mode",
                    systemImage: dayNightManager.isCurrentlyLight ? "sun.max" : "moon.stars"
                )
            }
        } label: {
            Label("Theme Options", systemImage: "ellipsis.circle")
                .symbolVariant(dayNightManager.enabled ? .fill : .none)
                .foregroundStyle(dayNightManager.enabled ? .orange : .primary)
        }
        .labelStyle(.iconOnly)
    }

    // MARK: - Filter Header

    private func filterHeader(inRail: Bool) -> some View {
        let isShort = verticalSizeClass == .compact
        return VStack(spacing: isShort ? 8 : 12) {
            // Day/Night mode picker (when enabled)
            if dayNightManager.enabled {
                Picker("Editing", selection: $editingMode) {
                    ForEach(ThemeEditingMode.allCases, id: \.self) { mode in
                        Label(mode.localizedName, systemImage: mode.icon)
                    }
                }
                .pickerStyle(.segmented)

                // Show which theme is currently set
                HStack {
                    Image(systemName: editingMode.icon)
                        .foregroundColor(editingMode == .day ? .orange : .indigo)
                    Text(editingMode == .day
                        ? String(localized: "Setting day theme:")
                        : String(localized: "Setting night theme:"))
                        .font(.caption)
                    Text(editingMode == .day ? dayNightManager.dayTheme : dayNightManager.nightTheme)
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .foregroundColor(.secondary)
            }

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search themes", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 32, minHeight: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, isShort ? 8 : 10)
            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .systemGray6))
            .cornerRadius(10)

            // Light/Dark filter
            Picker("Filter", selection: $filterMode) {
                ForEach(ThemeManager.ThemeFilterMode.allCases, id: \.self) { mode in
                    Label(mode.localizedName, systemImage: mode.icon)
                }
            }
            .pickerStyle(.segmented)

            // Theme count
            HStack {
                Text("\(filteredThemes.count) themes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.leading, 16)
        // Inset-grouped lists align flush with the side rail's safe edge on Duo;
        // matching that trailing inset prevents the header from looking indented.
        .padding(.trailing, inRail && horizontalSizeClass == .compact ? 0 : 16)
        .padding(.vertical, isShort ? 8 : 12)
    }

    // MARK: - Theme Selection

    private func selectTheme(_ theme: ThemeManager.ThemeInfo) {
        if dayNightManager.enabled {
            switch editingMode {
            case .day:
                dayNightManager.dayTheme = theme.name
            case .night:
                dayNightManager.nightTheme = theme.name
            }
        } else {
            themeManager.currentTheme = theme.name
        }
    }

    private func isThemeSelected(_ theme: ThemeManager.ThemeInfo) -> Bool {
        if dayNightManager.enabled {
            switch editingMode {
            case .day:
                return dayNightManager.dayTheme == theme.name
            case .night:
                return dayNightManager.nightTheme == theme.name
            }
        } else {
            return themeManager.currentTheme == theme.name
        }
    }

    private var selectedThemeName: String {
        if dayNightManager.enabled {
            switch editingMode {
            case .day:
                return dayNightManager.dayTheme
            case .night:
                return dayNightManager.nightTheme
            }
        } else {
            return themeManager.currentTheme
        }
    }

    // MARK: - List Layout (iPhone)

    private var showFavoritesSection: Bool {
        !favoriteManager.favoriteThemeIds.isEmpty && searchText.isEmpty
    }

    private var themeList: some View {
        ScrollViewReader { proxy in
            List {
                // Favorites section (only show if favorites exist and not searching)
                if showFavoritesSection {
                    Section {
                        ForEach(favoriteManager.favoriteThemes()) { theme in
                            themeRow(theme)
                        }
                    } header: {
                        Label("Favorites", systemImage: "star.fill")
                            .foregroundColor(.yellow)
                    }
                }

                // All themes section
                Section {
                    ForEach(filteredThemes) { theme in
                        themeRow(theme)
                            .id(theme.id)
                    }
                } header: {
                    if showFavoritesSection {
                        Text("All Themes")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .themedList()
            .onAppear {
                scrollToSelectedTheme(proxy: proxy)
            }
            .onChange(of: editingMode) { _, _ in
                scrollToSelectedTheme(proxy: proxy)
            }
        }
    }

    private func scrollToSelectedTheme(proxy: ScrollViewProxy) {
        if let selectedTheme = filteredThemes.first(where: { $0.name == selectedThemeName }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    proxy.scrollTo(selectedTheme.id, anchor: .center)
                }
            }
        }
    }

    private func themeRow(_ theme: ThemeManager.ThemeInfo) -> some View {
        let isFavorite = favoriteManager.isFavorite(theme.id)
        return Button {
            selectTheme(theme)
        } label: {
            HStack(spacing: 10) {
                // Terminal preview (compact)
                TerminalSnippetView(colors: theme.colors, compact: true)
                    .frame(width: 108, height: 45)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                // Theme name and family
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(theme.displayName)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        if theme.isCustom {
                            Text("Custom")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.blue.opacity(0.7)))
                        }
                    }
                    if theme.family != theme.displayName {
                        Text(theme.family)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(" ")
                            .font(.caption)
                            .foregroundColor(.clear)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    // Favorite button
                    Button {
                        favoriteManager.toggleFavorite(theme.id)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundColor(isFavorite ? .yellow : .secondary.opacity(0.5))
                            .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 36, minHeight: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite
                        ? Text("Remove from Favorites")
                        : Text("Add to Favorites"))

                    if isThemeSelected(theme) {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { themeContextMenu(theme) }
        .swipeActions(edge: .trailing) {
            if theme.isCustom {
                Button(role: .destructive) {
                    themeToDelete = theme
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    if let custom = customThemeManager.customThemes.first(where: { $0.name == theme.name }) {
                        activeEditorMode = .edit(custom)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.orange)
            } else {
                Button {
                    activeEditorMode = .duplicate(theme)
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                .tint(.blue)
                Button {
                    uiOverridesEditTarget = theme
                } label: {
                    Label("UI Colors", systemImage: "paintpalette")
                }
                .tint(.purple)
            }
        }
        .themedRow()
    }

    // MARK: - Grid Layout (iPad/Mac)

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private var themeGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Favorites section
                    if showFavoritesSection {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Favorites", systemImage: "star.fill")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.yellow)

                            LazyVGrid(columns: gridColumns, spacing: 12) {
                                ForEach(favoriteManager.favoriteThemes()) { theme in
                                    themeCard(theme)
                                }
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Text("All Themes")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                    }

                    // Main theme grid
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(filteredThemes) { theme in
                            themeCard(theme)
                                .id(theme.id)
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .id(searchText + filterMode.rawValue)
            .onAppear {
                scrollToSelectedTheme(proxy: proxy)
            }
            .onChange(of: editingMode) { _, _ in
                scrollToSelectedTheme(proxy: proxy)
            }
        }
    }

    private func themeCard(_ theme: ThemeManager.ThemeInfo) -> some View {
        let isSelected = isThemeSelected(theme)
        let isFavorite = favoriteManager.isFavorite(theme.id)
        return Button {
            selectTheme(theme)
        } label: {
            VStack(spacing: 0) {
                // Terminal preview with favorite button overlay
                ZStack(alignment: .topTrailing) {
                    TerminalSnippetView(colors: theme.colors, compact: false)
                        .frame(height: 70)

                    // Favorite button
                    Button {
                        favoriteManager.toggleFavorite(theme.id)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14))
                            .foregroundColor(isFavorite ? .yellow : .white.opacity(0.7))
                            .padding(6)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                            .panelTouchTarget(PanelTouch.isTouchPlatform, minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite
                        ? Text("Remove from Favorites")
                        : Text("Add to Favorites"))
                    .padding(PanelTouch.isTouchPlatform ? 0 : 4)
                }

                // Theme name
                HStack {
                    Text(theme.displayName)
                        .font(.caption)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(.primary)
                    if theme.isCustom {
                        Text("Custom")
                            .font(.system(size: 9))
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.blue.opacity(0.7)))
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .contextMenu { themeContextMenu(theme) }
    }

    // MARK: - Theme Import

    private var themeImportNameSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Theme Name", text: $importName)
                        .textInputAutocapitalization(.words)
                        .themedRow()
                } header: {
                    Text("Name")
                } footer: {
                    Text("Give your imported theme a name.")
                }
            }
            .themedList()
            .navigationTitle("Import Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingImportNameSheet = false
                        pendingImportURL = nil
                        importName = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        performThemeImport()
                    }
                    .disabled(importName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func handleThemeFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let filename = url.deletingPathExtension().lastPathComponent
            importName = filename.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
            pendingImportURL = url
            showingImportNameSheet = true
        case .failure(let error):
            importErrorMessage = error.localizedDescription
            showingImportError = true
        }
    }

    private func performThemeImport() {
        guard let url = pendingImportURL else { return }
        let name = importName.trimmingCharacters(in: .whitespaces)
        do {
            _ = try customThemeManager.importFromFile(url: url, name: name)
        } catch {
            importErrorMessage = error.localizedDescription
            showingImportError = true
        }
        showingImportNameSheet = false
        pendingImportURL = nil
        importName = ""
    }

    // MARK: - Custom Theme Context Menu

    private func themeContextMenu(_ theme: ThemeManager.ThemeInfo) -> some View {
        Group {
            Button {
                uiOverridesEditTarget = theme
            } label: {
                Label("Customize UI Colors…", systemImage: "paintpalette")
            }

            Divider()

            if theme.isCustom {
                Button {
                    if let custom = customThemeManager.customThemes.first(where: { $0.name == theme.name }) {
                        activeEditorMode = .edit(custom)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    if let custom = customThemeManager.customThemes.first(where: { $0.name == theme.name }) {
                        let duplicate = CustomTheme(
                            id: UUID(),
                            name: "\(custom.name) Copy",
                            createdDate: Date(),
                            modifiedDate: Date(),
                            background: custom.background,
                            foreground: custom.foreground,
                            cursorColor: custom.cursorColor,
                            cursorText: custom.cursorText,
                            selectionBackground: custom.selectionBackground,
                            selectionForeground: custom.selectionForeground,
                            palette: custom.palette,
                            extendedPalette: custom.extendedPalette
                        )
                        activeEditorMode = .edit(duplicate)
                    }
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }

                if let custom = customThemeManager.customThemes.first(where: { $0.name == theme.name }),
                   let url = customThemeManager.exportURL(for: custom.id) {
                    ShareLink(item: url) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    themeToDelete = theme
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Button {
                    activeEditorMode = .duplicate(theme)
                } label: {
                    Label("Duplicate as Custom Theme", systemImage: "doc.on.doc")
                }
            }
        }
    }

    // MARK: - Filtering

    private var filteredThemes: [ThemeManager.ThemeInfo] {
        var themes = themeManager.availableThemes

        // Apply search filter
        if !searchText.isEmpty {
            themes = themes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        // Apply light/dark filter
        switch filterMode {
        case .all:
            break
        case .light:
            themes = themes.filter { $0.isLight }
        case .dark:
            themes = themes.filter { !$0.isLight }
        }

        return themes
    }
}

// MARK: - Font Settings

