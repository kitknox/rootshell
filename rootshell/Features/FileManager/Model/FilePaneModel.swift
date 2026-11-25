//
//  FilePaneModel.swift
//  rootshell
//
//  One side of the file manager: an endpoint, a directory, its listing,
//  history, filter and selection. Survives the UI being hidden.
//

import Foundation
import os.log

extension RFEntry {
    /// Byte-exact row identity so canonically equivalent UTF-8 paths (NFC vs NFD)
    /// and a file sharing a name with a folder remain distinct across merging,
    /// rendering, and selection.
    nonisolated var rowID: FileEntryID {
        FileEntryID(path: path, isDirectory: isDirectory)
    }
}

@MainActor
@Observable
final class FilePaneModel: Identifiable {
    enum Side: String, CaseIterable {
        case left
        case right

        var other: Side { self == .left ? .right : .left }
    }

    enum Status: Equatable {
        case idle
        case connecting
        case loading
        case failed(String)
    }

    private enum LoadMoreTarget: Equatable {
        case base
        case prefix(String)
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "FileManagerPane")
    private static let prefixSearchDebounce: Duration = .milliseconds(250)

    let id: Side
    private let prompts: FileManagerPrompts

    private(set) var endpoint: FileEndpoint = .local
    private(set) var path = ""
    private(set) var entries: [RFEntry] = []
    private(set) var visibleEntries: [RFEntry] = []
    private(set) var status: Status = .idle
    private(set) var nextCursor: String?
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: String?
    private(set) var supportsServerPrefixSearch = false
    private(set) var prefixEntries: [RFEntry] = []
    private(set) var prefixNextCursor: String?
    private(set) var activePrefixQuery: String?
    private(set) var isSearchingPrefix = false
    private(set) var prefixSearchError: String?
    var selection = FileRowSelection<FileEntryID>()

    var filterText = "" {
        didSet { if !filterText.utf8.elementsEqual(oldValue.utf8) { handleFilterChange() } }
    }

    var sortOrder: RFSortOrder = .nameAsc {
        didSet { if sortOrder != oldValue { applyFilter() } }
    }

    var showHidden: Bool {
        didSet { if showHidden != oldValue { applyFilter() } }
    }

    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var forwardStack: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadMoreTask: Task<Void, Never>?
    @ObservationIgnored private var loadingMoreTarget: LoadMoreTarget?
    @ObservationIgnored private var prefixSearchTask: Task<Void, Never>?
    @ObservationIgnored private var seenBaseCursors: Set<[UInt8]> = []
    @ObservationIgnored private var seenPrefixCursors: Set<[UInt8]> = []
    @ObservationIgnored private var lastEffectiveFilterBytes: [UInt8] = []
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var prefixSearchGeneration: UInt64 = 0
    @ObservationIgnored private var retainedEndpoint: FileEndpoint?

    init(side: Side, prompts: FileManagerPrompts) {
        id = side
        self.prompts = prompts
        showHidden = SettingsStore.shared.value(Settings.Transfer.fileManagerShowHidden)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isBusy: Bool { status == .connecting || status == .loading }
    var visibleRowIDs: [FileEntryID] { visibleEntries.map(\.rowID) }
    var trimmedFilterQuery: String { filterText.trimmingCharacters(in: .whitespaces) }
    var hasMoreBaseEntries: Bool { nextCursor != nil }
    var isTruncatedServerListing: Bool { supportsServerPrefixSearch && hasMoreBaseEntries }
    var isPrefixQueryValid: Bool { S3KeyLogic.isValidChildPrefix(trimmedFilterQuery) }

    /// True when the active filter is backed by a completed S3 prefix search
    /// (either exact match or a narrower UTF-8 prefix of an already-exhausted search).
    var hasActivePrefixResults: Bool {
        guard let activePrefixQuery, !trimmedFilterQuery.isEmpty else { return false }
        return trimmedFilterQuery.utf8.starts(with: activePrefixQuery.utf8)
    }

    var hasMorePrefixEntries: Bool {
        guard let activePrefixQuery else { return false }
        return activePrefixQuery.utf8.elementsEqual(trimmedFilterQuery.utf8) && prefixNextCursor != nil
    }

    var canLoadMore: Bool {
        status == .idle && !isLoadingMore && !isSearchingPrefix && (hasMorePrefixEntries || hasMoreBaseEntries)
    }

    var showsPaginationBar: Bool {
        guard status == .idle else { return false }
        // The empty-state view already owns full-pane prefix search progress and errors.
        if visibleEntries.isEmpty, isSearchingPrefix || (prefixSearchError != nil && !trimmedFilterQuery.isEmpty) {
            return false
        }
        return hasMoreBaseEntries || hasMorePrefixEntries || hasActivePrefixResults
            || isLoadingMore || isSearchingPrefix || loadMoreError != nil || prefixSearchError != nil
    }

    var showsListFooter: Bool {
        status == .idle && (
            isLoadingMore || loadMoreError != nil || hasMorePrefixEntries
                || (hasMoreBaseEntries && !hasActivePrefixResults && !isSearchingPrefix)
        )
    }

    var cursorEntry: RFEntry? {
        selection.cursor.flatMap { cursor in visibleEntries.first { $0.rowID == cursor } }
    }

    /// Selected entries, or the cursor row when nothing is selected.
    var actionEntries: [RFEntry] {
        let ids = Set(selection.effectiveIDs(in: visibleRowIDs))
        return visibleEntries.filter { ids.contains($0.rowID) }
    }

    var locationTitle: String {
        path.isEmpty ? endpoint.displayName : "\(endpoint.displayName):\(path)"
    }

    func fileSystem(purpose: FileConnectionPool.Purpose = .browse) async throws -> FileSystemEndpoint {
        try await FileConnectionPool.shared.fileSystem(for: endpoint, purpose: purpose, prompts: prompts)
    }

    // MARK: - Navigation

    /// Points the pane at `endpoint`, starting at `path` or its home directory.
    func connect(to endpoint: FileEndpoint, path: String? = nil) {
        let pool = FileConnectionPool.shared
        if let retainedEndpoint { pool.release(retainedEndpoint) }
        pool.retain(endpoint)
        retainedEndpoint = endpoint

        self.endpoint = endpoint
        backStack = []
        forwardStack = []
        entries = []
        visibleEntries = []
        resetPaginationState()
        selection = FileRowSelection<FileEntryID>()
        filterText = ""
        lastEffectiveFilterBytes = []
        self.path = ""
        load(path, resolvingHome: true)
    }

    func navigate(to newPath: String, focus: FileEntryID? = nil) {
        if newPath.utf8.elementsEqual(path.utf8) {
            if let focus {
                if visibleEntries.contains(where: { $0.rowID == focus }) {
                    selection.setCursor(focus)
                    return
                }
                if !filterText.isEmpty {
                    filterText = ""
                    if visibleEntries.contains(where: { $0.rowID == focus }) {
                        selection.setCursor(focus)
                        return
                    }
                }
                if entries.contains(where: { $0.rowID == focus }) {
                    return
                }
                return refresh(focus: focus)
            }
            return refresh()
        }
        if !path.isEmpty { backStack.append(path) }
        forwardStack = []
        filterText = ""
        load(newPath, focus: focus)
    }

    func goUp() {
        guard !path.isEmpty, path != "/" else { return }
        let child = FileEntryID(path: path, isDirectory: true)
        navigate(to: FileTransferLogic.parent(of: path), focus: child)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        load(previous, focus: nil)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        load(next, focus: nil)
    }

    func refresh(focus: FileEntryID? = nil) {
        load(path.isEmpty ? nil : path, focus: focus ?? selection.cursor, resolvingHome: path.isEmpty)
    }

    /// Enters a directory; returns false for files so the caller can preview them.
    @discardableResult
    func open(_ entry: RFEntry) -> Bool {
        guard entry.isDirectory else { return false }
        navigate(to: entry.path)
        return true
    }

    /// Resolves a typed path (relative, `~`) against the current directory.
    func goTo(_ typed: String) async {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            let fs = try await fileSystem()
            let resolved = try await fs.canonicalPath(trimmed, relativeTo: path.isEmpty ? "/" : path)
            let info = try await fs.info(resolved)
            if info.isDirectory {
                navigate(to: resolved)
            } else {
                let targetID = FileEntryID(path: resolved, isDirectory: false)
                navigate(to: FileTransferLogic.parent(of: resolved), focus: targetID)
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    @ObservationIgnored private var pendingCursor: FileEntryID?

    private func load(_ requested: String?, focus: FileEntryID? = nil, resolvingHome: Bool = false) {
        loadTask?.cancel()
        resetPaginationState()
        loadGeneration &+= 1
        let generation = loadGeneration
        pendingCursor = focus
        let endpoint = endpoint
        status = FileConnectionPool.shared.isConnected(endpoint) ? .loading : .connecting
        loadTask = Task { [weak self] in
            guard let self else { return }
            var connected = false
            do {
                let fs = try await self.fileSystem()
                connected = true
                var target = requested ?? ""
                if resolvingHome, target.isEmpty { target = try await fs.homeDirectory() }
                try Task.checkCancellation()
                guard self.endpoint == endpoint, self.loadGeneration == generation else { return }
                self.status = .loading
                let page = try await fs.listPage(target)
                try Task.checkCancellation()
                guard self.endpoint == endpoint, self.loadGeneration == generation else { return }
                var loadedEntries = page.entries
                let supportsPrefix = fs.supportsServerPrefixSearch(at: target)
                if page.hasMore,
                   let focus = self.pendingCursor,
                   FileTransferLogic.normalize(FileTransferLogic.parent(of: focus.path)).utf8
                    .elementsEqual(FileTransferLogic.normalize(target).utf8),
                   !loadedEntries.contains(where: { $0.rowID == focus }),
                   let focusedEntry = try await Self.fetchTargetEntry(
                       focus,
                       in: target,
                       on: fs,
                       supportsPrefixSearch: supportsPrefix
                   ) {
                    loadedEntries = S3KeyLogic.mergePage(loadedEntries, with: [focusedEntry]) { $0.rowID }
                }
                // Check cancellation and generation unconditionally before publishing,
                // including when `fetchTargetEntry` returned nil after a cancellation race.
                try Task.checkCancellation()
                guard self.endpoint == endpoint, self.loadGeneration == generation else { return }
                self.cancelLoadMore()
                self.cancelPrefixSearch(clearResults: true)
                self.path = target
                self.entries = loadedEntries
                self.nextCursor = page.nextCursor
                self.seenBaseCursors = page.nextCursor.map { [Array($0.utf8)] } ?? []
                self.supportsServerPrefixSearch = supportsPrefix
                self.loadMoreError = nil
                self.status = .idle
                self.applyFilter()
                self.pendingCursor = nil
                if self.isTruncatedServerListing && self.isPrefixQueryValid {
                    self.schedulePrefixSearch(for: self.trimmedFilterQuery, immediate: true)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.endpoint == endpoint, self.loadGeneration == generation, !Task.isCancelled else { return }
                Self.logger.error("Listing failed: \(error.localizedDescription, privacy: .public)")
                if connected, resolvingHome, let requested, !requested.isEmpty {
                    // A remembered folder that no longer exists: fall back to home.
                    // Not after a failed connect, which would prompt all over again.
                    self.load(nil, resolvingHome: true)
                    return
                }
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches a known target item that fell past page one of a truncated S3 folder
    /// or paginated bucket root (for Go to Path, Up, rename, or new folder) so it can
    /// be focused accurately.
    private static func fetchTargetEntry(
        _ target: FileEntryID,
        in directory: String,
        on fs: FileSystemEndpoint,
        supportsPrefixSearch: Bool
    ) async throws -> RFEntry? {
        let name = FileTransferLogic.lastComponent(of: target.path)
        if supportsPrefixSearch, S3KeyLogic.isValidChildPrefix(name) {
            do {
                let page = try await fs.listPage(directory, cursor: nil, namePrefix: name)
                if let match = page.entries.first(where: { $0.rowID == target }) {
                    return match
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Fall back to direct metadata lookup below.
            }
        }
        try Task.checkCancellation()
        do {
            let info = try await fs.info(target.path, isDirectory: target.isDirectory)
            guard info.isDirectory == target.isDirectory else { return nil }
            return RFEntry(
                name: name,
                path: target.path,
                isDirectory: info.isDirectory,
                isSymlink: info.isSymlink,
                isHidden: name.hasPrefix("."),
                isExecutable: false,
                size: Int64(clamping: info.size),
                modifiedDate: info.modified,
                gitStatus: nil,
                permissions: info.permissions
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    // MARK: - Pagination and S3 prefix search

    /// Loads the next page of the active server prefix search, or of the base folder listing.
    func loadMore() {
        guard status == .idle, !isLoadingMore, !isSearchingPrefix else { return }
        let target: LoadMoreTarget
        let cursor: String
        if hasMorePrefixEntries, let prefixCursor = prefixNextCursor {
            target = .prefix(trimmedFilterQuery)
            cursor = prefixCursor
        } else if let baseCursor = nextCursor {
            target = .base
            cursor = baseCursor
        } else {
            return
        }

        let endpoint = endpoint
        let currentPath = path
        let generation = loadGeneration
        let prefixGeneration = prefixSearchGeneration
        isLoadingMore = true
        loadingMoreTarget = target
        loadMoreError = nil

        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fs = try await self.fileSystem()
                let namePrefix: String? = switch target {
                case .base: nil
                case .prefix(let query): query
                }
                let page = try await fs.listPage(currentPath, cursor: cursor, namePrefix: namePrefix)
                try Task.checkCancellation()
                guard self.endpoint == endpoint,
                      self.path.utf8.elementsEqual(currentPath.utf8),
                      self.loadGeneration == generation else { return }
                switch target {
                case .base:
                    if let next = page.nextCursor {
                        guard self.seenBaseCursors.insert(Array(next.utf8)).inserted else {
                            throw S3KeyLogic.PaginationError.stalled
                        }
                        self.nextCursor = next
                    } else {
                        self.nextCursor = nil
                    }
                    self.entries = S3KeyLogic.mergePage(self.entries, with: page.entries) { $0.rowID }
                    if self.nextCursor == nil {
                        // The entire base listing is now in memory; discard any cached prefix
                        // results instead of merging them so deleted or modified keys stay accurate.
                        self.cancelPrefixSearch(clearResults: true)
                    }
                case .prefix(let query):
                    guard self.prefixSearchGeneration == prefixGeneration,
                          self.trimmedFilterQuery.utf8.elementsEqual(query.utf8) else { return }
                    if let next = page.nextCursor {
                        guard self.seenPrefixCursors.insert(Array(next.utf8)).inserted else {
                            throw S3KeyLogic.PaginationError.stalled
                        }
                        self.prefixNextCursor = next
                    } else {
                        self.prefixNextCursor = nil
                    }
                    self.prefixEntries = S3KeyLogic.mergePage(self.prefixEntries, with: page.entries) { $0.rowID }
                }
                self.isLoadingMore = false
                self.loadingMoreTarget = nil
                self.loadMoreTask = nil
                self.applyFilter()
            } catch is CancellationError {
                return
            } catch {
                guard self.endpoint == endpoint,
                      self.path.utf8.elementsEqual(currentPath.utf8),
                      self.loadGeneration == generation,
                      !Task.isCancelled else { return }
                if case .prefix = target, self.prefixSearchGeneration != prefixGeneration { return }
                Self.logger.error("Load more failed: \(error.localizedDescription, privacy: .public)")
                self.isLoadingMore = false
                self.loadingMoreTarget = nil
                self.loadMoreTask = nil
                self.loadMoreError = error.localizedDescription
            }
        }
    }

    /// Runs a pending or failed S3 prefix search immediately without waiting for debounce.
    func searchPrefixNow() {
        guard status == .idle, isTruncatedServerListing, isPrefixQueryValid else { return }
        if isSearchingPrefix || prefixSearchError != nil {
            schedulePrefixSearch(for: trimmedFilterQuery, immediate: true)
        }
    }

    func retryPrefixSearch() {
        guard status == .idle, isTruncatedServerListing, isPrefixQueryValid else { return }
        schedulePrefixSearch(for: trimmedFilterQuery, immediate: true)
    }

    private func handleFilterChange() {
        let query = trimmedFilterQuery
        let queryBytes = Array(query.utf8)
        guard queryBytes != lastEffectiveFilterBytes else { return }
        lastEffectiveFilterBytes = queryBytes

        let action = S3KeyLogic.prefixSearchAction(
            query: query,
            isListingReady: status == .idle,
            supportsPrefixSearch: supportsServerPrefixSearch,
            baseHasMore: nextCursor != nil,
            activePrefix: activePrefixQuery,
            prefixHasMore: prefixNextCursor != nil
        )
        switch action {
        case .clear:
            cancelPrefixSearch(clearResults: true)
            applyFilter()
        case .keepCurrent:
            cancelPrefixSearch(clearResults: false)
            applyFilter()
        case .fetch(let targetQuery, let keepExistingWhileLoading):
            if !keepExistingWhileLoading {
                prefixEntries = []
                prefixNextCursor = nil
                activePrefixQuery = nil
                seenPrefixCursors = []
            }
            if case .prefix = loadingMoreTarget { cancelLoadMore() }
            applyFilter()
            schedulePrefixSearch(for: targetQuery, immediate: false)
        }
    }

    private func schedulePrefixSearch(for query: String, immediate: Bool) {
        if case .prefix = loadingMoreTarget { cancelLoadMore() }
        prefixSearchTask?.cancel()
        prefixSearchGeneration &+= 1
        let prefixGeneration = prefixSearchGeneration
        let generation = loadGeneration
        let endpoint = endpoint
        let currentPath = path

        isSearchingPrefix = true
        prefixSearchError = nil
        loadMoreError = nil

        prefixSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediate {
                    try await Task.sleep(for: Self.prefixSearchDebounce)
                }
                try Task.checkCancellation()
                guard self.endpoint == endpoint,
                      self.path.utf8.elementsEqual(currentPath.utf8),
                      self.loadGeneration == generation,
                      self.prefixSearchGeneration == prefixGeneration else { return }
                let fs = try await self.fileSystem()
                let page = try await fs.listPage(currentPath, cursor: nil, namePrefix: query)
                try Task.checkCancellation()
                guard self.endpoint == endpoint,
                      self.path.utf8.elementsEqual(currentPath.utf8),
                      self.loadGeneration == generation,
                      self.prefixSearchGeneration == prefixGeneration,
                      self.trimmedFilterQuery.utf8.elementsEqual(query.utf8) else { return }
                self.prefixEntries = page.entries
                self.prefixNextCursor = page.nextCursor
                self.seenPrefixCursors = page.nextCursor.map { [Array($0.utf8)] } ?? []
                self.activePrefixQuery = query
                self.isSearchingPrefix = false
                self.prefixSearchError = nil
                self.prefixSearchTask = nil
                self.applyFilter()
            } catch is CancellationError {
                return
            } catch {
                guard self.endpoint == endpoint,
                      self.path.utf8.elementsEqual(currentPath.utf8),
                      self.loadGeneration == generation,
                      self.prefixSearchGeneration == prefixGeneration,
                      !Task.isCancelled else { return }
                Self.logger.error("Prefix search failed: \(error.localizedDescription, privacy: .public)")
                self.isSearchingPrefix = false
                self.prefixSearchTask = nil
                self.prefixSearchError = error.localizedDescription
            }
        }
    }

    private func cancelLoadMore() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadingMoreTarget = nil
        isLoadingMore = false
        loadMoreError = nil
    }

    private func cancelPrefixSearch(clearResults: Bool) {
        if case .prefix = loadingMoreTarget { cancelLoadMore() }
        prefixSearchTask?.cancel()
        prefixSearchTask = nil
        prefixSearchGeneration &+= 1
        isSearchingPrefix = false
        prefixSearchError = nil
        if clearResults {
            prefixEntries = []
            prefixNextCursor = nil
            activePrefixQuery = nil
            seenPrefixCursors = []
        }
    }

    private func resetPaginationState() {
        cancelLoadMore()
        cancelPrefixSearch(clearResults: true)
        nextCursor = nil
        seenBaseCursors = []
        supportsServerPrefixSearch = false
    }

    private func applyFilter() {
        let query = trimmedFilterQuery
        let matchesEntry: (RFEntry) -> Bool = { entry in
            (self.showHidden || !entry.isHidden || (!query.isEmpty && query.hasPrefix(".")))
                && (query.isEmpty
                    || entry.name.localizedCaseInsensitiveContains(query)
                    || entry.name.utf8.starts(with: query.utf8))
        }
        var shown = entries.filter(matchesEntry)
        if !query.isEmpty && !prefixEntries.isEmpty {
            let matchingPrefix = prefixEntries.filter(matchesEntry)
            shown = S3KeyLogic.mergePage(shown, with: matchingPrefix) { $0.rowID }
        }
        visibleEntries = RFEntry.sorted(shown, by: sortOrder)
        let rowIDs = visibleRowIDs
        if let pendingCursor, rowIDs.contains(pendingCursor) {
            selection.setCursor(pendingCursor)
            self.pendingCursor = nil
        }
        selection.reconcile(with: rowIDs)
        if selection.cursor == nil { selection.setCursor(rowIDs.first) }
    }

    // MARK: - Restore

    @ObservationIgnored private var pendingRestore: (endpoint: FileEndpoint, path: String)?

    /// Still on the default endpoint with nothing loaded or waiting to connect.
    var isUnopened: Bool { retainedEndpoint == nil && pendingRestore == nil }

    /// Shows a remembered remote location without connecting yet.
    func restorePending(endpoint: FileEndpoint, path: String) {
        pendingRestore = (endpoint, path)
        self.endpoint = endpoint
    }

    func activatePendingRestore() {
        guard let pendingRestore else { return }
        self.pendingRestore = nil
        connect(to: pendingRestore.endpoint, path: pendingRestore.path.isEmpty ? nil : pendingRestore.path)
    }

    /// Releases the pane's hold on its connection.
    func detach() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        cancelLoadMore()
        cancelPrefixSearch(clearResults: false)
        if let retainedEndpoint { FileConnectionPool.shared.release(retainedEndpoint) }
        retainedEndpoint = nil
    }
}
