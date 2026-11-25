//
//  FilePaneView.swift
//  rootshell
//
//  One pane: location header, filter field (the keyboard anchor), listing,
//  and the touch selection bar. Pointer and keyboard use click/cursor
//  semantics; touch taps open and an explicit Select mode multi-selects.
//

import SwiftUI
import UniformTypeIdentifiers

struct FilePaneView: View {
    @Bindable var pane: FilePaneModel
    @Bindable var manager: FileManagerModel
    let isActive: Bool
    /// False while the file manager is hidden, so the field never steals the keyboard back.
    let canFocus: Bool
    let columns: FileRowView.Columns
    let otherPaneName: String
    let chrome: FileManagerChrome
    /// The location button; one touch pane shows it in the switcher instead.
    let showsEndpoint: Bool
    /// This pane's own touch bar, for two panes side by side.
    let showsTouchBar: Bool
    let onClose: () -> Void

    @State private var arrowRepeat = ArrowKeyRepeatManager()
    @State private var lastClick: (rowID: FileEntryID, time: Date)?
    @State private var fieldFocused = false
    @State private var isDropTargeted = false

    private var hasHardwareKeyboard: Bool { KeyboardTracker.shared.isHardwareKeyboard }

    private var usesPointerSemantics: Bool { FileManagerInput.usesPointerSemantics }

    var body: some View {
        VStack(spacing: 0) {
            if chrome == .pointer {
                header
                filterRow
            } else {
                touchLocation
            }
            Divider()
            content
                .contentShape(Rectangle())
                // Rows keep their own menus; empty space gets the ⋯ menu for this pane.
                .contextMenu { FileManagerMoreMenuItems(manager: manager, side: pane.id) }
            if pane.showsPaginationBar {
                Divider()
                paginationBar
            }
            if showsTouchBar {
                Divider()
                FileManagerTouchBar(manager: manager, side: pane.id)
            }
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        // Clear backgrounds and the empty-folder view aren't hit-testable; without
        // this an empty pane only accepts drops on its label.
        .contentShape(Rectangle())
        .onDrop(of: FileManagerDragDrop.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            manager.handleDrop(providers, onto: pane.id, directory: nil)
        }
        .onDisappear { arrowRepeat.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            endpointButton

            Spacer(minLength: 4)

            // One Back, as on touch; Forward and Parent stay on their shortcuts.
            navButton("chevron.left", command: .back, enabled: pane.touchBackTarget != nil,
                      help: FileManagerTouchAction.backDestinationName(pane).map {
                          String(localized: "Back to \($0)", comment: "File manager touch back button; argument is a folder name")
                      }) { pane.goBackOrUp() }
            navButton("arrow.clockwise", command: .refresh, enabled: !pane.isBusy) { pane.refresh() }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var endpointButton: some View {
        Button { manager.sheet = .connect(pane.id) } label: {
            HStack(spacing: 6) {
                if let domain = pane.endpoint.faviconDomain {
                    FaviconIcon(domain: domain, fallbackSymbol: pane.endpoint.symbol, size: 15, tint: nil)
                } else {
                    Image(systemName: pane.endpoint.symbol)
                }
                Text(pane.endpoint.displayName).fontWeight(.semibold).lineLimit(1)
                if pane.status == .connecting {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minHeight: chrome == .pointer ? nil : 40)
            .contentShape(Rectangle())
        }
        .help(FileManagerShortcut.shortcut(for: .connect).helpText)
        .accessibilityLabel(String(localized: "Location: \(pane.endpoint.displayName)", comment: "File manager endpoint button"))
    }

    /// Touch: the location button where the switcher doesn't name it, then the
    /// path and filter. Navigation lives in the bottom bar or the rail.
    private var touchLocation: some View {
        VStack(spacing: 0) {
            if showsEndpoint {
                HStack {
                    endpointButton
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                FilePaneBreadcrumbMenu(pane: pane, manager: manager, path: pane.path, minHeight: 40)
                    .equatable()
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
                    filterField(fontSize: 15)
                        .frame(height: 34)
                        .accessibilityLabel(String(localized: "Filter files", comment: "File manager filter accessibility"))
                    if pane.status == .loading || pane.isSearchingPrefix {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, 9)
                .frame(minWidth: 110, maxWidth: 170)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func navButton(_ symbol: String, command: FileManagerCommand, enabled: Bool, help: String? = nil,
                           action: @escaping () -> Void) -> some View {
        let shortcut = FileManagerShortcut.shortcut(for: command)
        return Button(action: {
            manager.activeSide = pane.id
            action()
        }) {
            Image(systemName: symbol).frame(width: 22, height: 22)
        }
        .disabled(!enabled)
        .help(help ?? shortcut.helpText)
        .accessibilityLabel(help ?? shortcut.title)
    }

    // MARK: - Filter field

    private var filterRow: some View {
        HStack(spacing: 6) {
            breadcrumb
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.caption)
            filterField(fontSize: 14)
                .frame(height: 22)
                .frame(minWidth: 60, maxWidth: 180)
                .accessibilityLabel(String(localized: "Filter files", comment: "File manager filter accessibility"))
            if pane.status == .loading || pane.isSearchingPrefix {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// The pane's keyboard anchor: filter text, arrow keys and every pane shortcut.
    private func filterField(fontSize: CGFloat) -> some View {
        SidebarSearchField(
            text: $pane.filterText,
            placeholder: pane.isTruncatedServerListing
                ? String(localized: "Prefix or filter", comment: "File manager filter placeholder for truncated S3 listings")
                : String(localized: "Filter", comment: "File manager filter placeholder"),
            fontSize: fontSize,
            canFocus: canFocus && isActive,
            // Touch never takes a focus request: a fresh field after the keyboard
            // detaches would replay the last one and raise the on-screen keyboard.
            focusRequestID: isActive && usesPointerSemantics ? manager.focusRequestID : 0,
            onMoveUpBegan: { beginMove(-1, .up) },
            onMoveUpEnded: { arrowRepeat.stop(direction: .up) },
            onMoveDownBegan: { beginMove(1, .down) },
            onMoveDownEnded: { arrowRepeat.stop(direction: .down) },
            onEscape: handleEscape,
            onSubmit: {
                arrowRepeat.stop()
                // On touch, Return closes the keyboard and kicks off any pending S3 prefix search immediately.
                guard hasHardwareKeyboard else {
                    pane.searchPrefixNow()
                    return dismissSoftwareKeyboard()
                }
                if !manager.queueFocused {
                    if pane.cursorEntry != nil {
                        manager.openCursor()
                    } else {
                        pane.searchPrefixNow()
                    }
                }
            },
            onFocusChange: { focused in
                Task { @MainActor in
                    fieldFocused = focused
                    if focused { manager.activeSide = pane.id } else { arrowRepeat.stop() }
                }
            },
            onModifiedSubmit: { manager.perform(.openInTerminal) },
            onTab: { arrowRepeat.stop(); manager.perform(.switchPane) },
            onBackTab: { arrowRepeat.stop(); pane.goUp() },
            extraCommands: keyCommands,
            onSelectAll: { manager.perform(.selectAll) },
            onPaste: { manager.paste($0, into: pane.id, directory: nil) },
            claimsKeyboard: true
        )
    }

    private var breadcrumb: some View {
        FilePaneBreadcrumbMenu(pane: pane, manager: manager, path: pane.path)
            .equatable()
    }

    private var keyCommands: [SidebarSearchExtraCommand] {
        var commands = FileManagerShortcut.paneCommands { command, chord in
            arrowRepeat.stop()
            switch command {
            case .extendSelection:
                pane.selection.moveCursor(by: chord.input == UIKeyCommand.inputUpArrow ? -1 : 1, in: pane.visibleRowIDs, extending: true)
            default:
                manager.perform(command)
            }
        }
        if pane.filterText.isEmpty {
            commands.append(SidebarSearchExtraCommand(input: " ", modifiers: [], title: FileManagerShortcut.shortcut(for: .toggleSelection).title) {
                manager.perform(.toggleSelection)
            })
        }
        if manager.queueFocused {
            commands.append(SidebarSearchExtraCommand(input: UIKeyCommand.inputDelete, modifiers: [], title: FileManagerShortcut.shortcut(for: .cancelJob).title) {
                manager.perform(.cancelJob)
            })
        }
        return commands
    }

    private func beginMove(_ delta: Int, _ direction: ArrowKeyRepeatManager.Direction) {
        let step = {
            if manager.queueFocused {
                manager.moveQueueCursor(by: delta)
            } else {
                pane.selection.moveCursor(by: delta, in: pane.visibleRowIDs, extending: false)
            }
        }
        step()
        arrowRepeat.start(direction: direction, action: step)
    }

    /// Esc unwinds one layer at a time: filter, queue focus, selection, then the panel.
    private func handleEscape() {
        arrowRepeat.stop()
        if !pane.filterText.isEmpty {
            pane.filterText = ""
        } else if manager.queueFocused {
            manager.queueFocused = false
        } else if !pane.selection.isEmpty {
            pane.selection.clear()
            pane.isSelecting = false
        } else {
            onClose()
        }
    }

    // MARK: - Listing

    @ViewBuilder
    private var content: some View {
        switch pane.status {
        case .connecting where pane.entries.isEmpty:
            statusView {
                ProgressView()
                Text("Connecting to \(pane.endpoint.displayName)…").foregroundStyle(.secondary)
            }
        case .failed(let message):
            statusView {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button(String(localized: "Retry", comment: "File manager: retry listing")) {
                        pane.path.isEmpty ? pane.connect(to: pane.endpoint) : pane.refresh()
                    }
                    Button(String(localized: "Choose Location", comment: "File manager: pick another endpoint")) {
                        manager.sheet = .connect(pane.id)
                    }
                }
                .buttonStyle(.bordered)
            }
        default:
            if pane.visibleEntries.isEmpty && pane.status == .idle {
                emptyListingView
            } else {
                list
            }
        }
    }

    private var emptyListingView: some View {
        statusView {
            let query = pane.trimmedFilterQuery
            if pane.isSearchingPrefix {
                ProgressView()
                Text(String(localized: "Searching prefix “\(query)”…", comment: "File manager S3 prefix search status; argument is prefix"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let error = pane.prefixSearchError, !query.isEmpty {
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary).textSelection(.enabled)
                Button(String(localized: "Retry", comment: "File manager: retry listing")) {
                    pane.retryPrefixSearch()
                }
                .buttonStyle(.bordered)
            } else if query.isEmpty {
                if pane.hasMoreBaseEntries {
                    Text(String(localized: "No visible items in the first \(pane.entries.count.formatted()) entries", comment: "File manager: all loaded items are hidden while more pages exist"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "Load More", comment: "File manager: load next page of S3 listing")) {
                        pane.loadMore()
                    }
                    .buttonStyle(.bordered)
                    .disabled(pane.isLoadingMore)
                } else {
                    Text(String(localized: "Empty folder", comment: "File manager: no files"))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "No matches", comment: "File manager: filter matched nothing"))
                    .foregroundStyle(.secondary)
                if pane.hasMoreBaseEntries {
                    if pane.supportsServerPrefixSearch {
                        Text(
                            pane.isPrefixQueryValid
                                ? String(localized: "S3 searches exact key prefixes (case-sensitive).", comment: "File manager S3 prefix search empty-state hint")
                                : String(localized: "Only loaded items are filtered when the query contains “/”.", comment: "File manager S3 slash query hint")
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    }
                    Button(String(localized: "Load More Folder Items", comment: "File manager: load next page of base S3 folder")) {
                        pane.loadMore()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(pane.isLoadingMore)
                }
            }
        }
    }

    private func statusView<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if columns == .detailed { columnHeader }
                LazyVStack(spacing: 1) {
                    ForEach(pane.visibleEntries, id: \.rowID) { entry in
                        row(entry)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                if pane.showsListFooter {
                    listPaginationFooter
                }
            }
            // A floating keyboard leaves a bottom safe area here; the scroll view
            // would extend into it and draw rows over the queue and hint bar.
            .clipped()
            #if !os(visionOS)
            // With a hardware keyboard the field must keep focus while the list scrolls.
            .scrollDismissesKeyboard(hasHardwareKeyboard ? .never : .immediately)
            #endif
            .onChange(of: pane.selection.cursor) { _, cursor in
                guard let cursor else { return }
                proxy.scrollTo(cursor)
            }
        }
    }

    private var listPaginationFooter: some View {
        VStack(spacing: 6) {
            if pane.isLoadingMore {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Loading more…", comment: "File manager pagination status"))
                        .foregroundStyle(.secondary)
                }
            } else if let error = pane.loadMoreError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String(localized: "Retry", comment: "File manager: retry listing")) {
                    pane.loadMore()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if pane.canLoadMore {
                Button(String(localized: "Load More", comment: "File manager: load next page of S3 listing")) {
                    pane.loadMore()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var paginationBar: some View {
        HStack(spacing: 8) {
            if pane.isLoadingMore {
                ProgressView().controlSize(.mini)
                Text(String(localized: "Loading more…", comment: "File manager pagination status"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
            } else if pane.isSearchingPrefix {
                ProgressView().controlSize(.mini)
                Text(String(localized: "Searching prefix “\(pane.trimmedFilterQuery)”…", comment: "File manager S3 prefix search status; argument is prefix"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
            } else if let error = pane.loadMoreError ?? pane.prefixSearchError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button(String(localized: "Retry", comment: "File manager: retry listing")) {
                    if pane.loadMoreError != nil {
                        pane.loadMore()
                    } else {
                        pane.retryPrefixSearch()
                    }
                }
                .buttonStyle(.borderless)
            } else if pane.hasMorePrefixEntries {
                Text(String(localized: "Prefix “\(pane.trimmedFilterQuery)” · \(pane.prefixEntries.count.formatted())+ loaded", comment: "File manager S3 paginated prefix search status; arguments are prefix and count"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(String(localized: "Load More", comment: "File manager: load next page of S3 listing")) {
                    pane.loadMore()
                }
                .buttonStyle(.borderless)
            } else if pane.hasActivePrefixResults {
                Text(String(localized: "Prefix “\(pane.trimmedFilterQuery)” · \(pane.visibleEntries.count.formatted()) shown", comment: "File manager S3 completed prefix search status; arguments are prefix and count"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if pane.hasMoreBaseEntries {
                    Button(String(localized: "Load More Folder", comment: "File manager: load next page of unfiltered S3 folder")) {
                        pane.loadMore()
                    }
                    .buttonStyle(.borderless)
                }
            } else if pane.hasMoreBaseEntries {
                Text(String(localized: "\(pane.entries.count.formatted()) loaded · More available", comment: "File manager S3 paginated listing status; argument is loaded item count"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(String(localized: "Load More", comment: "File manager: load next page of S3 listing")) {
                    pane.loadMore()
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.03))
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            sortButton(String(localized: "Name", comment: "File manager column"), ascending: .nameAsc, descending: .nameDesc)
            Spacer()
            sortButton(String(localized: "Size", comment: "File manager column"), ascending: .sizeAsc, descending: .sizeDesc)
                .frame(width: 70, alignment: .trailing)
            sortButton(String(localized: "Modified", comment: "File manager column"), ascending: .modifiedAsc, descending: .modifiedDesc)
                .frame(width: 118, alignment: .trailing)
            Text("Mode").frame(width: 84, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func sortButton(_ title: String, ascending: RFSortOrder, descending: RFSortOrder) -> some View {
        Button {
            pane.sortOrder = pane.sortOrder == ascending ? descending : ascending
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if pane.sortOrder == ascending { Image(systemName: "chevron.up") }
                if pane.sortOrder == descending { Image(systemName: "chevron.down") }
            }
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: RFEntry) -> some View {
        let rowID = entry.rowID
        return folderDropTarget(for: entry) {
            FileRowContextMenuRow(
                row: FileRowView(
                    entry: entry,
                    isSelected: pane.selection.contains(rowID),
                    isCursor: pane.selection.cursor == rowID,
                    showsCursor: isActive && (fieldFocused || usesPointerSemantics),
                    showsCheckbox: pane.isSelecting,
                    isExternallyEdited: !entry.isDirectory && RemoteFileEditCenter.shared.isWatching(endpoint: pane.endpoint, path: entry.path),
                    columns: columns
                ),
                pane: pane,
                otherPaneName: otherPaneName
            ) {
                contextMenu(for: entry)
            }
            .equatable()
            .id(rowID)
            .onTapGesture { tap(entry) }
            .onDrag { manager.beginDrag(of: dragEntries(for: entry), from: pane.id) }
        }
    }

    /// Only folder rows are drop targets. A file row must have none at all: an
    /// empty-typed target still wins the hit test and refuses the drop, so the
    /// pane behind it never sees drops over files.
    @ViewBuilder
    private func folderDropTarget(for entry: RFEntry, @ViewBuilder content: () -> some View) -> some View {
        if entry.isDirectory {
            content().onDrop(of: FileManagerDragDrop.acceptedTypes, isTargeted: nil) { providers in
                manager.handleDrop(providers, onto: pane.id, directory: entry.path)
            }
        } else {
            content()
        }
    }

    private func dragEntries(for entry: RFEntry) -> [RFEntry] {
        pane.selection.contains(entry.rowID) ? pane.actionEntries : [entry]
    }

    /// Touch has no Esc, so the filter gives up the on-screen keyboard on
    /// Return, on a row tap, and when the list scrolls.
    private func dismissSoftwareKeyboard() {
        guard !hasHardwareKeyboard else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func tap(_ entry: RFEntry) {
        let rowID = entry.rowID
        manager.activeSide = pane.id
        manager.requestFocus()
        dismissSoftwareKeyboard()
        if pane.isSelecting && chrome != .pointer {
            pane.selection.toggle(rowID)
            return
        }
        let flags = KeyboardTracker.shared.hardwareModifierFlags
        if flags.contains(.command) {
            pane.selection.click(rowID, in: pane.visibleRowIDs, modifier: .toggle)
        } else if flags.contains(.shift) {
            pane.selection.click(rowID, in: pane.visibleRowIDs, modifier: .range)
        } else if usesPointerSemantics {
            let now = Date()
            if let lastClick, lastClick.rowID == rowID, now.timeIntervalSince(lastClick.time) < 0.4 {
                self.lastClick = nil
                open(entry)
            } else {
                pane.selection.click(rowID, in: pane.visibleRowIDs, modifier: .none)
                lastClick = (rowID, now)
            }
        } else {
            pane.selection.setCursor(rowID)
            open(entry)
        }
    }

    private func open(_ entry: RFEntry) {
        if !pane.open(entry) { manager.open(entry, in: pane) }
    }

    @ViewBuilder
    private func contextMenu(for entry: RFEntry) -> some View {
        let targets = dragEntries(for: entry)
        let plural = targets.count > 1
        if entry.isDirectory {
            Button { open(entry) } label: {
                Label(String(localized: "Open", comment: "File manager context menu"), systemImage: "folder")
            }
        } else {
            Button { manager.editInApp(entry, in: pane) } label: {
                Label(FileManagerShortcut.shortcut(for: .edit).title, systemImage: "square.and.pencil")
            }
            #if targetEnvironment(macCatalyst)
            Button { manager.editExternally(entry, in: pane) } label: {
                Label(FileManagerShortcut.shortcut(for: .editExternal).title, systemImage: "arrow.up.forward.app")
            }
            openWithSubmenu(for: entry)
            #else
            if manager.openInEmbeddedEditor != nil {
                Button { manager.editInEmbeddedEditor(entry, in: pane, editor: .vim) } label: {
                    Label(String(localized: "Edit in Vim", comment: "File manager context menu"), systemImage: "terminal")
                }
                Button { manager.editInEmbeddedEditor(entry, in: pane, editor: .hx) } label: {
                    Label(String(localized: "Edit in Helix (hx)", comment: "File manager context menu"), systemImage: "terminal")
                }
            }
            Button { manager.editExternally(entry, in: pane) } label: {
                Label(String(localized: "Edit in External App…", comment: "File manager context menu"), systemImage: "arrow.up.forward.app")
            }
            #endif
            Button { manager.preview(entry, in: pane) } label: {
                Label(FileManagerShortcut.shortcut(for: .quickLook).title, systemImage: "eye")
            }
        }
        Divider()
        Button { manager.transferToOther(move: false, entries: targets, from: pane.id) } label: {
            Label(String(localized: "Copy to \(otherPaneName)", comment: "File manager context menu; argument is the other pane's location"), systemImage: "doc.on.doc")
        }
        Button { manager.transferToOther(move: true, entries: targets, from: pane.id) } label: {
            Label(String(localized: "Move to \(otherPaneName)", comment: "File manager context menu; argument is the other pane's location"), systemImage: "arrow.right.doc.on.clipboard")
        }
        // Like a drop: onto a folder row pastes into that folder.
        Button { manager.pasteFromClipboard(into: pane.id, directory: entry.isDirectory ? entry.path : nil) } label: {
            Label(FileManagerShortcut.shortcut(for: .paste).title, systemImage: "doc.on.clipboard")
        }
        Divider()
        if !plural {
            Button { manager.activeSide = pane.id; manager.sheet = .rename(entry) } label: {
                Label(FileManagerShortcut.shortcut(for: .rename).title, systemImage: "pencil")
            }
            Button { manager.activeSide = pane.id; manager.sheet = .info(entry) } label: {
                Label(FileManagerShortcut.shortcut(for: .info).title, systemImage: "info.circle")
            }
            if pane.endpoint.storageProvider != nil {
                if !entry.isDirectory {
                    Button { manager.activeSide = pane.id; manager.sheet = .shareLink(entry) } label: {
                        Label(String(localized: "Share Link…", comment: "File manager context menu: presigned storage URL"), systemImage: "link")
                    }
                } else if FileTransferLogic.parent(of: entry.path) == "/" {
                    Button { manager.activeSide = pane.id; manager.sheet = .incompleteUploads(entry) } label: {
                        Label(String(localized: "Incomplete Uploads…", comment: "File manager context menu: a bucket's unfinished multipart uploads"), systemImage: "icloud.slash")
                    }
                }
            }
        }
        if entry.isDirectory, manager.openInTerminal != nil, pane.endpoint.supportsTerminal {
            Button { manager.activeSide = pane.id; pane.selection.setCursor(entry.rowID); manager.perform(.openInTerminal) } label: {
                Label(FileManagerShortcut.shortcut(for: .openInTerminal).title, systemImage: "terminal")
            }
        }
        Divider()
        Button(role: .destructive) { manager.activeSide = pane.id; manager.sheet = .confirmDelete(targets) } label: {
            Label(FileManagerShortcut.shortcut(for: .delete).title, systemImage: "trash")
        }
    }

    #if targetEnvironment(macCatalyst)
    @ViewBuilder
    private func openWithSubmenu(for entry: RFEntry) -> some View {
        let probeURL: URL = pane.endpoint.isLocal
            ? URL(fileURLWithPath: LocalPathResolver.current().resolve(entry.path))
            : FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        let apps = ExternalEditorBridge.availableApps(for: probeURL, includePlainText: !FileEditClassification.isKnownBinary(name: entry.name))
        Menu {
            ForEach(apps) { app in
                Button(app.name) {
                    manager.editExternally(entry, in: pane, appURL: app.url)
                }
            }
            if !apps.isEmpty { Divider() }
            Button(String(localized: "Choose App…", comment: "File manager Open With submenu")) {
                manager.externalAppPickerRequest = .openFile(entry, pane.endpoint)
            }
        } label: {
            Label(String(localized: "Open With", comment: "File manager context menu"), systemImage: "square.grid.2x2")
        }
    }
    #endif
}

// MARK: - Menu isolation
//
// FilePaneView re-renders on every FileManagerView/MainView render (its
// closure input never compares equal) and on filter, focus and selection
// changes. Menus live in equatable owners so those renders never rebuild one
// that is open.

/// Ancestors of the current folder, tappable.
private struct FilePaneBreadcrumbMenu: View, Equatable {
    let pane: FilePaneModel
    let manager: FileManagerModel
    let path: String
    var minHeight: CGFloat? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pane === rhs.pane && lhs.manager === rhs.manager && lhs.path == rhs.path && lhs.minHeight == rhs.minHeight
    }

    var body: some View {
        Menu {
            ForEach(ancestors, id: \.self) { ancestor in
                Button(ancestor) { pane.navigate(to: ancestor) }
            }
            Divider()
            Button(FileManagerShortcut.shortcut(for: .goToPath).title) { manager.sheet = .goToPath }
        } label: {
            Text(path.isEmpty ? "…" : path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    private var ancestors: [String] {
        var result: [String] = []
        var current = path
        while !current.isEmpty, current != "/" {
            result.append(current)
            current = FileTransferLogic.parent(of: current)
        }
        if !path.isEmpty { result.append("/") }
        return result
    }
}

/// Row plus its context menu. `menu` is excluded from equality; it reads the
/// live selection and endpoint when presented.
private struct FileRowContextMenuRow<MenuContent: View>: View, Equatable {
    let row: FileRowView
    let pane: FilePaneModel
    let otherPaneName: String
    @ViewBuilder let menu: () -> MenuContent

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.pane === rhs.pane && lhs.otherPaneName == rhs.otherPaneName
    }

    var body: some View {
        row.contextMenu {
            FileRowContextMenuContents(build: menu)
        }
    }
}

/// Non-equatable so availability is evaluated per presentation, not snapshotted.
private struct FileRowContextMenuContents<Content: View>: View {
    @ViewBuilder let build: () -> Content

    var body: some View {
        build()
    }
}
