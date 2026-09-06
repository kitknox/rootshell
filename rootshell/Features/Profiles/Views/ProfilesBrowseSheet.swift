//
//  ProfilesBrowseSheet.swift
//  rootshell
//
//  Sheet for browsing and managing connection profiles
//

import SwiftUI

// MARK: - Selection Result

/// Result of selecting a profile from the browse sheet
struct ProfileSelection {
    let profile: ConnectionProfile
    let splitOption: SSHConnectionView.SplitOption
}

// MARK: - Tag Item (for FilterChipBar)

/// Wraps a tag name as an Identifiable item for use with FilterChipBar.
private struct TagItem: Identifiable {
    let name: String
    var id: String { name }
}

// MARK: - Profiles Browse Sheet

/// Sheet for browsing connection profiles with folder and tag organization
struct ProfilesBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    // Manager
    private var profileManager: ConnectionProfileManager { ConnectionProfileManager.shared }
    private var availableTags: [ProfileTag] {
        profileManager.tags(showAllPlatforms: showAllPlatforms)
    }

    // State
    @State private var searchQuery: String = ""
    @State private var selectedTags: Set<String> = []
    @State private var showAllPlatforms = false
    @State private var showTagFilter: Bool = false
    @Setting(Settings.Connections.profilesSortOrder) private var sortOrder
    @State private var showingNewProfileSheet: Bool = false
    @State private var editingProfile: ConnectionProfile?
    @State private var profileToDelete: ConnectionProfile?
    @State private var newProfileFolder: String = ""
    @State private var splitOption: SSHConnectionView.SplitOption = .newTab

    // Navigation path for folder browsing
    @State private var folderPath: [String] = []
    @State private var activeFolder: String = ""

    // Focus state for search field
    @State private var isSearchFocused: Bool = false

    // Keyboard navigation
    @State private var highlightedIndex: Int = 0
    @State private var scrollTargetID: String?
    @State private var searchFocusRequestID: Int = 0
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()
    @State private var pendingFocusTask: Task<Void, Never>?
    @State private var prefetchDebounceTask: Task<Void, Never>?

    let onProfileSelected: ((ProfileSelection) -> Void)?

    init(onProfileSelected: ((ProfileSelection) -> Void)? = nil) {
        self.onProfileSelected = onProfileSelected
    }

    // MARK: - Navigable Items

    private enum NavigableItem: Identifiable {
        case folder(ProfileFolder)
        case profile(ConnectionProfile)

        var id: String {
            switch self {
            case .folder(let f): return "folder:\(f.id)"
            case .profile(let p): return "profile:\(p.id.uuidString)"
            }
        }
    }

    private func navigableItems(in folder: String) -> [NavigableItem] {
        var items: [NavigableItem] = []
        if searchQuery.isEmpty && selectedTags.isEmpty {
            items.append(contentsOf: filteredFolders(in: folder).map { .folder($0) })
        }
        items.append(contentsOf: filteredProfiles(in: folder).map { .profile($0) })
        return items
    }

    private func isItemHighlighted(_ item: NavigableItem, in folder: String) -> Bool {
        guard KeyboardTracker.shared.isHardwareKeyboard else { return false }
        let items = navigableItems(in: folder)
        guard highlightedIndex < items.count else { return false }
        return items[highlightedIndex].id == item.id
    }

    var body: some View {
        NavigationStack(path: $folderPath) {
            profileListView(folder: "")
                .navigationDestination(for: String.self) { folder in
                    profileListView(folder: folder)
                }
        }
        .overlay {
            // Hidden button to handle Esc at the UIKit key command level,
            // which fires before SwiftUI's .onKeyPress and before the sheet's
            // built-in dismiss. Navigates back through folders first, then dismisses.
            Button("") { handleEscapeKey() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onAppear {
            activeFolder = folderPath.last ?? ""
            scheduleSearchFocus(for: activeFolder)
            triggerDNSPrefetch()
        }
        .onDisappear {
            arrowKeyRepeatManager.stop()
            pendingFocusTask?.cancel()
            pendingFocusTask = nil
            prefetchDebounceTask?.cancel()
            prefetchDebounceTask = nil
        }
        .onChange(of: folderPath) { _, newPath in
            arrowKeyRepeatManager.stop()
            pendingFocusTask?.cancel()
            pendingFocusTask = nil
            activeFolder = newPath.last ?? ""
            highlightedIndex = 0
            scrollTargetID = nil
            isSearchFocused = false
            scheduleSearchFocus(for: activeFolder)
            triggerDNSPrefetch()
        }
        .onChange(of: searchQuery) { _, _ in
            highlightedIndex = 0
            triggerDNSPrefetch()
        }
        .onChange(of: selectedTags) { _, _ in
            highlightedIndex = 0
            triggerDNSPrefetch()
        }
        .onChange(of: Set(availableTags.map(\.name))) { _, names in
            selectedTags.formIntersection(names)
            if names.isEmpty { showTagFilter = false }
        }
        .onChange(of: profileManager.hasUnavailableProfiles) { _, hasUnavailable in
            if !hasUnavailable { showAllPlatforms = false }
        }
        .onChange(of: showAllPlatforms) { _, _ in
            highlightedIndex = 0
            triggerDNSPrefetch()
        }
        .onChange(of: sortOrder) { _, _ in
            highlightedIndex = 0
        }
        .onChange(of: highlightedIndex) { _, _ in
            triggerDNSPrefetch()
        }
        .navigationDestination(isPresented: $showingNewProfileSheet) {
            ProfileEditorSheet(folderPath: folderPath.last ?? "", embedded: true)
        }
        .navigationDestination(item: $editingProfile) { profile in
            ProfileEditorSheet(profile: profile, embedded: true)
        }
    }

    // MARK: - Profile List View

    @ViewBuilder
    private func profileListView(folder: String) -> some View {
        ScrollViewReader { scrollProxy in
            List {
                // Open As section at top
                Section("Open As") {
                    Group {
                        Picker("Open As", selection: $splitOption) {
                            ForEach(SSHConnectionView.SplitOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .themedRow()
                }

                // Search section
                searchSection(in: folder)

                // Folders in current location
                foldersSection(in: folder)

                // Profiles in current location
                profilesSection(in: folder)

                // No results message
                noResultsSection(in: folder)
            }
            .themedList()
            .onChange(of: scrollTargetID) { _, target in
                guard folder == activeFolder, let target else { return }
                scrollProxy.scrollTo(target, anchor: .center)
            }
        }
        .confirmationDialog(
            "Delete Profile",
            isPresented: Binding(
                get: { activeFolder == folder && profileToDelete != nil },
                set: { if !$0 { profileToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: profileToDelete
        ) { profile in
            Button("Delete", role: .destructive) {
                deleteProfile(profile)
                profileToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
        } message: { profile in
            Text("Are you sure you want to delete \"\(profile.name)\"?")
        }
        .navigationTitle(folder.isEmpty ? "Profiles" : folderName(from: folder))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }

            if profileManager.hasUnavailableProfiles {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Toggle("Show All Platforms", isOn: $showAllPlatforms)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Platform Filter")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentNewProfileSheet(in: folder)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        #if !os(visionOS)
        .onKeyPress(.downArrow, phases: .down) { _ in
            moveHighlightDown()
            arrowKeyRepeatManager.start(direction: .down) { [self] in
                moveHighlightDown()
            }
            return .handled
        }
        .onKeyPress(.downArrow, phases: .up) { _ in
            arrowKeyRepeatManager.stop(direction: .down)
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { _ in
            moveHighlightUp()
            arrowKeyRepeatManager.start(direction: .up) { [self] in
                moveHighlightUp()
            }
            return .handled
        }
        .onKeyPress(.upArrow, phases: .up) { _ in
            arrowKeyRepeatManager.stop(direction: .up)
            return .handled
        }
        .onKeyPress(.return) {
            arrowKeyRepeatManager.stop()
            if activateHighlightedItem() {
                return .handled
            }
            return .ignored
        }
        #endif
    }

    // MARK: - Search Section

    @ViewBuilder
    private func searchSection(in folder: String) -> some View {
        Section {
            Group {
                searchBar(in: folder)

                if !selectedTags.isEmpty {
                    activeTagChips
                }
            }
            .themedRow()
        }
    }

    private func searchFocusBinding(for folder: String) -> Binding<Bool> {
        Binding(
            get: { folder == activeFolder && isSearchFocused },
            set: { newValue in
                guard folder == activeFolder else { return }
                isSearchFocused = newValue
            }
        )
    }

    // MARK: - Search Bar

    private func searchBar(in folder: String) -> some View {
        BrowseSearchBar(
            searchQuery: $searchQuery,
            placeholder: String(localized: "Search profiles..."),
            focusedBinding: searchFocusBinding(for: folder),
            focusRequestID: searchFocusRequestID,
            onEscape: { handleEscapeKey() },
            onMoveUp: {
                moveHighlightUp()
                arrowKeyRepeatManager.start(direction: .up) { [self] in
                    moveHighlightUp()
                }
            },
            onMoveDown: {
                moveHighlightDown()
                arrowKeyRepeatManager.start(direction: .down) { [self] in
                    moveHighlightDown()
                }
            },
            onStopMoveUp: { arrowKeyRepeatManager.stop(direction: .up) },
            onStopMoveDown: { arrowKeyRepeatManager.stop(direction: .down) },
            onSubmit: { activateHighlightedItem() }
        ) {
            // Tag filter button (only show if tags exist)
            if !availableTags.isEmpty {
                Button(action: { showTagFilter = true }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "tag")
                            .font(.title3)
                        if !selectedTags.isEmpty {
                            Circle()
                                .fill(.blue)
                                .frame(width: 8, height: 8)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .popover(isPresented: $showTagFilter, arrowEdge: .top) {
                    TagFilterPopover(
                        tags: availableTags,
                        selectedTags: $selectedTags
                    )
                    .themedSubSheet(sheetThemeColors)
                    .presentationCompactAdaptation(.popover)
                }
            }

            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(ProfileSortOrder.allCases, id: \.rawValue) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                if SettingPinActions.hasActions(for: Settings.Connections.profilesSortOrder.erased) {
                    Section {
                        SettingPinActions(definition: Settings.Connections.profilesSortOrder.erased)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.title3)
            }
        }
        .id("profiles-search-\(folder.isEmpty ? "root" : folder)")
        .onAppear {
            guard folder == activeFolder else { return }
            scheduleSearchFocus(for: folder)
        }
    }

    // MARK: - Active Tag Chips

    private var activeTagChips: some View {
        FilterChipBar(
            items: Array(selectedTags).sorted().map { TagItem(name: $0) },
            label: { $0.name },
            icon: { _ in
                Image(systemName: "tag.fill")
                    .font(.caption2)
            },
            onRemove: { selectedTags.remove($0.name) }
        )
    }

    // MARK: - Folders Section

    @ViewBuilder
    private func foldersSection(in parentPath: String) -> some View {
        let subfolders = filteredFolders(in: parentPath)
        if !subfolders.isEmpty && searchQuery.isEmpty && selectedTags.isEmpty {
            Section("Folders") {
                ForEach(subfolders) { folder in
                    Button {
                        navigateIntoFolder(folder.path)
                    } label: {
                        FolderRow(folder: folder)
                    }
                    .id("folder:\(folder.id)")
                    .listRowBackground(
                        isItemHighlighted(.folder(folder), in: parentPath)
                            ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                    )
                }
            }
        }
    }

    // MARK: - Profiles Section

    @ViewBuilder
    private func profilesSection(in folder: String) -> some View {
        let profiles = filteredProfiles(in: folder)
        if !profiles.isEmpty {
            Section(searchQuery.isEmpty && selectedTags.isEmpty ? "Profiles" : "Results") {
                ForEach(profiles) { profile in
                    ProfileRow(profile: profile)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                profileToDelete = profile
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingProfile = profile
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)

                            Button {
                                duplicateProfile(profile)
                            } label: {
                                Label("Duplicate", systemImage: "doc.on.doc")
                            }
                            .tint(.orange)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectProfile(profile)
                        }
                        .contextMenu {
                            profileContextMenu(profile)
                        }
                        .id("profile:\(profile.id.uuidString)")
                        .listRowBackground(
                            isItemHighlighted(.profile(profile), in: folder)
                                ? Color.accentColor.opacity(0.15) : sheetThemeColors?.rowBackground
                        )
                }
            }
        }
    }

    // MARK: - No Results Section

    @ViewBuilder
    private func noResultsSection(in folder: String) -> some View {
        let subfolders = filteredFolders(in: folder)
        let profiles = filteredProfiles(in: folder)

        if subfolders.isEmpty && profiles.isEmpty {
            Section {
                Group {
                    if !searchQuery.isEmpty || !selectedTags.isEmpty {
                        NoResultsRow(message: "No profiles match your search")
                    } else {
                        NoResultsRow(icon: "star", message: "No profiles yet")
                        Button {
                            presentNewProfileSheet(in: folder)
                        } label: {
                            Label("Create Profile", systemImage: "plus")
                        }
                    }
                }
                .themedRow()
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func profileContextMenu(_ profile: ConnectionProfile) -> some View {
        if HostAddressCopyActions.hasActions(
            hostname: profile.sshConfig.host,
            ipAddress: nil
        ) {
            HostAddressCopyActions(hostname: profile.sshConfig.host)
            Divider()
        }

        Button {
            editingProfile = profile
        } label: {
            Label("Edit", systemImage: "pencil")
        }

        Button {
            duplicateProfile(profile)
        } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }

        Divider()

        Button(role: .destructive) {
            profileToDelete = profile
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Filtering

    private func filteredFolders(in parentPath: String) -> [ProfileFolder] {
        profileManager.subfolders(of: parentPath, showAllPlatforms: showAllPlatforms)
    }

    private func filteredProfiles(in folder: String) -> [ConnectionProfile] {
        var profiles: [ConnectionProfile]

        if !searchQuery.isEmpty {
            // Search across all profiles
            profiles = profileManager.profiles(matching: searchQuery)
        } else if !selectedTags.isEmpty {
            // Filter by tags across all profiles
            profiles = profileManager.profiles.filter { profile in
                !selectedTags.isDisjoint(with: profile.tags)
            }
        } else {
            // Show profiles in current folder only
            profiles = profileManager.profiles(inFolder: folder)
        }

        return profiles.filter { showAllPlatforms || $0.isAvailableOnCurrentPlatform }
            .sorted(by: sortOrder.compare)
    }

    // MARK: - Actions

    @discardableResult
    private func activateHighlightedItem() -> Bool {
        let items = navigableItems(in: activeFolder)
        guard highlightedIndex < items.count else { return false }
        switch items[highlightedIndex] {
        case .folder(let folder):
            navigateIntoFolder(folder.path)
        case .profile(let profile):
            selectProfile(profile)
        }
        return true
    }

    private func selectProfile(_ profile: ConnectionProfile) {
        guard profile.isAvailableOnCurrentPlatform else {
            editingProfile = profile
            return
        }
        onProfileSelected?(ProfileSelection(profile: profile, splitOption: splitOption))
        dismiss()
    }

    private func duplicateProfile(_ profile: ConnectionProfile) {
        _ = try? profileManager.duplicateProfile(id: profile.id)
    }

    private func deleteProfile(_ profile: ConnectionProfile) {
        try? profileManager.deleteProfile(id: profile.id)
    }

    private func presentNewProfileSheet(in folder: String) {
        newProfileFolder = folder
        showingNewProfileSheet = true
    }

    private func folderName(from path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else {
            return path
        }
        return String(path[path.index(after: lastSlash)...])
    }

    private func handleEscapeKey() {
        if !folderPath.isEmpty {
            navigateToParentFolder()
            return
        }
        dismiss()
    }

    private func restoreSearchFocus() {
        guard KeyboardTracker.shared.isHardwareKeyboard else {
            isSearchFocused = false
            return
        }
        isSearchFocused = true
        searchFocusRequestID &+= 1
    }

    private func scheduleSearchFocus(for folder: String) {
        pendingFocusTask?.cancel()
        pendingFocusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, activeFolder == folder else { return }
            restoreSearchFocus()
        }
    }

    private func moveHighlightDown() {
        let items = navigableItems(in: activeFolder)
        guard !items.isEmpty else { return }
        let lastIndex = items.count - 1
        let current = min(max(highlightedIndex, 0), lastIndex)
        highlightedIndex = min(current + 1, lastIndex)
        scrollTargetID = items[highlightedIndex].id
    }

    private func moveHighlightUp() {
        let items = navigableItems(in: activeFolder)
        guard !items.isEmpty else { return }
        let lastIndex = items.count - 1
        let current = min(max(highlightedIndex, 0), lastIndex)
        highlightedIndex = max(current - 1, 0)
        scrollTargetID = items[highlightedIndex].id
    }

    private func triggerDNSPrefetch() {
        prefetchDebounceTask?.cancel()
        let folderAtSchedule = activeFolder
        prefetchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            guard folderAtSchedule == activeFolder else { return }

            let items = navigableItems(in: activeFolder)
            guard !items.isEmpty else { return }

            let clampedIdx = min(max(highlightedIndex, 0), items.count - 1)
            let lower = max(0, clampedIdx - 1)
            let upper = min(items.count - 1, clampedIdx + 5)
            guard lower <= upper else { return }

            var hosts: [String] = []
            for item in items[lower...upper] {
                if case .profile(let profile) = item, profile.connectionProtocol != .local {
                    let host = profile.sshConfig.host
                    if !host.isEmpty { hosts.append(host) }
                }
            }
            guard !hosts.isEmpty else { return }

            Task.detached {
                await DNSPrefetcher.shared.prefetch(hostnames: hosts)
            }
        }
    }

    private func navigateIntoFolder(_ path: String) {
        isSearchFocused = false
        activeFolder = path
        folderPath.append(path)
    }

    private func navigateToParentFolder() {
        guard !folderPath.isEmpty else { return }
        isSearchFocused = false
        folderPath.removeLast()
        activeFolder = folderPath.last ?? ""
    }
}

// MARK: - Folder Row

struct FolderRow: View {
    let folder: ProfileFolder

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .frame(width: 24)

            Text(folder.name)

            Spacer()

            Text("\(folder.totalProfileCount)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: ConnectionProfile
    var action: (() -> Void)? = nil

    @ObservedObject private var sessionTracker = SessionTracker.shared

    var body: some View {
        rowContent
    }

    @ViewBuilder
    private var rowContent: some View {
        HStack {
            // Icon
            profileIcon

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .foregroundColor(.primary)

                if profile.connectionProtocol == .local {
                    Text(profile.localConfig?.platform.displayName ?? String(localized: "Unavailable"))
                        .font(.caption)
                        .foregroundStyle(profile.isAvailableOnCurrentPlatform ? Color.secondary : Color.orange)
                    if !profile.isAvailableOnCurrentPlatform {
                        Text("Unavailable on this device · Tap to edit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(profile.displayString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Key availability warning badge
            ProfileKeyAvailabilityBadge(profile: profile)

            // Active session count
            if let count = sessionTracker.profileSessionCounts[profile.id], count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileIcon: some View {
        let iconColor: Color = if let colorTag = profile.colorTag {
            color(for: colorTag)
        } else {
            .accentColor
        }

        ProfileIconView(storageString: profile.iconName, tint: iconColor, host: profile.sshConfig.host)
            .frame(width: 24)
    }

    private func color(for tag: ProfileColorTag) -> Color {
        switch tag {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

// MARK: - Tag Filter Popover

struct TagFilterPopover: View {
    let tags: [ProfileTag]
    @Binding var selectedTags: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tags) { tag in
                    Button {
                        toggleTag(tag.name)
                    } label: {
                        HStack {
                            Image(systemName: "tag.fill")
                                .foregroundColor(.accentColor)

                            Text(tag.name)
                                .foregroundColor(.primary)

                            Spacer()

                            Text("\(tag.usageCount)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if selectedTags.contains(tag.name) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .themedList()
            .navigationTitle("Filter by Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }

                if !selectedTags.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") { selectedTags.removeAll() }
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .frame(minWidth: 300, minHeight: 300)
    }

    private func toggleTag(_ name: String) {
        if selectedTags.contains(name) {
            selectedTags.remove(name)
        } else {
            selectedTags.insert(name)
        }
    }
}
