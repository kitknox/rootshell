//
//  ClipboardManagerOverlay.swift
//  rootshell
//
//  Clipboard manager UI. Regular width: a moveable glass HUD hosted in
//  DraggableHUDContainer (same pattern as the theme picker). iPhone: the
//  same content presented as a detented sheet. Includes the optional
//  biometric gate and the per-entry transform toolbox.
//

import LocalAuthentication
import SwiftUI

struct ClipboardManagerOverlay: View {
    enum Style { case hud, sheet, sidebar }

    let style: Style
    @Binding var isPresented: Bool
    /// HUD keyboard mode (2nd Cmd+Shift+C press): the search field holds first
    /// responder and arrows/Return/chords operate the list. The sheet style
    /// passes .constant(false).
    @Binding var keyboardMode: Bool
    var pasteHandler: (String) -> Void

    var manager = ClipboardHistoryManager.shared

    @State private var searchText = ""
    /// Entry IDs matching the debounced off-main search; nil = no active filter.
    @State private var searchMatchIDs: Set<UUID>?
    /// HUD-internal navigation: the panel swaps to the detail view in place.
    @State private var selectedEntryID: UUID?
    @State private var showClearConfirmation = false
    @State private var unlockFailed = false

    // Keyboard-mode navigation. The highlight tracks the entry ID, not a row
    // index: copy (markUsed) and live capture reorder the list underneath it.
    @State private var highlightedEntryID: UUID?
    /// Monotonic first-responder request for SidebarSearchField (0 = never).
    @State private var searchFocusRequestID = 0
    /// Whether the HUD search field holds first responder, via onFocusChange.
    @State private var searchFieldFocused = false
    /// Hold-to-repeat for arrow navigation (SwiftUI `.repeat` key phases do
    /// not arrive on iPad hardware keyboards).
    @State private var arrowKeyRepeatManager = ArrowKeyRepeatManager()
    /// In-flight context-menu Format action (single-flight, see runFormat).
    @State private var formatTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch style {
            case .hud, .sidebar: hudBody
            case .sheet: sheetBody
            }
        }
        .task(id: SearchKey(text: searchText, revision: manager.entriesRevision)) {
            await refreshSearchMatches()
        }
        .onDisappear {
            formatTask?.cancel()
        }
    }

    // MARK: - Shared state helpers

    private var isLocked: Bool { manager.requireBiometric && !manager.isUnlocked }

    private var filteredEntries: [ClipboardEntry] {
        guard let ids = searchMatchIDs else { return manager.entries }
        return manager.entries.filter { ids.contains($0.id) }
    }

    /// Single pass so a body eval doesn't re-filter once per section.
    private var partitionedEntries: (pinned: [ClipboardEntry], recent: [ClipboardEntry]) {
        var pinned: [ClipboardEntry] = []
        var recent: [ClipboardEntry] = []
        for entry in filteredEntries {
            if entry.pinned { pinned.append(entry) } else { recent.append(entry) }
        }
        return (pinned, recent)
    }

    // MARK: - Search

    /// Task identity: retriggers on keystrokes and on any entries mutation
    /// (revision covers in-place coalesce text rewrites that entry count misses).
    private struct SearchKey: Hashable {
        let text: String
        let revision: Int
    }

    /// Debounced, off-main full-text search. Locale-aware contains over every
    /// entry can walk the whole store, so it must never run per keystroke on main.
    private func refreshSearchMatches() async {
        guard !searchText.isEmpty else {
            searchMatchIDs = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        let needle = searchText
        let snapshot = manager.entries
        let handle = Task.detached(priority: .userInitiated) {
            var ids = Set<UUID>()
            for entry in snapshot {
                if Task.isCancelled { break }
                if entry.text.localizedCaseInsensitiveContains(needle) {
                    ids.insert(entry.id)
                }
            }
            return ids
        }
        let ids = await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
        guard !Task.isCancelled else { return }
        searchMatchIDs = ids
    }

    private var selectedEntry: ClipboardEntry? {
        guard let id = selectedEntryID else { return nil }
        return manager.entries.first { $0.id == id }
    }

    // MARK: - Keyboard mode (HUD)

    /// The list in display order (pinned section, then recent). Computed live
    /// so key-handler closures always act on current data, not a stale capture.
    private var flattenedEntries: [ClipboardEntry] {
        let (pinned, recent) = partitionedEntries
        return pinned + recent
    }

    private var highlightedEntry: ClipboardEntry? {
        guard let id = highlightedEntryID else { return nil }
        return flattenedEntries.first { $0.id == id }
    }

    /// 1-based Ctrl+digit badge for a row, or nil outside keyboard mode / past 9.
    private func quickSelectBadge(flatIndex: Int) -> Int? {
        guard keyboardMode, flatIndex < 9 else { return nil }
        return flatIndex + 1
    }

    private func enterKeyboardMode() {
        selectedEntryID = nil
        highlightedEntryID = flattenedEntries.first?.id
        searchFocusRequestID += 1
    }

    private func exitKeyboardModeCleanup() {
        arrowKeyRepeatManager.stop()
        highlightedEntryID = nil
    }

    private func closeFromKeyboardMode() {
        arrowKeyRepeatManager.stop()
        keyboardMode = false
        isPresented = false
    }

    private func moveHighlight(by delta: Int, proxy: ScrollViewProxy) {
        let entries = flattenedEntries
        guard !entries.isEmpty else { return }
        let currentIndex = highlightedEntryID.flatMap { id in
            entries.firstIndex(where: { $0.id == id })
        } ?? (delta > 0 ? -1 : entries.count)
        let next = max(0, min(entries.count - 1, currentIndex + delta))
        highlightedEntryID = entries[next].id
        proxy.scrollTo(entries[next].id, anchor: nil)
    }

    /// Enter: paste the highlighted entry and close. State first, paste second:
    /// the overlay-owns-keyboard gate must already be down when the paste path
    /// hands first responder back to the terminal.
    private func pasteHighlightedAndClose() {
        arrowKeyRepeatManager.stop()
        guard let entry = highlightedEntry else { return }
        keyboardMode = false
        isPresented = false
        pasteEntry(entry)
    }

    /// Cmd+Enter: copy to the system clipboard, stay open. markUsed moves the
    /// entry to the top; the ID-tracked highlight follows it.
    private func copyHighlighted(proxy: ScrollViewProxy) {
        guard let entry = highlightedEntry else { return }
        copyEntry(entry)
        proxy.scrollTo(entry.id, anchor: nil)
    }

    /// Ctrl+digit: paste the Nth visible entry (1-based) and close.
    private func quickSelect(_ digit: Int) {
        let entries = flattenedEntries
        guard digit >= 1, digit <= min(9, entries.count) else { return }
        arrowKeyRepeatManager.stop()
        let entry = entries[digit - 1]
        keyboardMode = false
        isPresented = false
        pasteEntry(entry)
    }

    /// Ctrl+P: the entry migrates between the Pinned and Recent sections; the
    /// ID-tracked highlight follows it. Refused silently at the pin cap.
    private func togglePinHighlighted(proxy: ScrollViewProxy) {
        guard let entry = highlightedEntry else { return }
        manager.togglePin(entry.id)
        proxy.scrollTo(entry.id, anchor: nil)
    }

    /// Ctrl+Delete: delete the highlighted entry, keep the highlight at the
    /// same visual position (previous row when the last one was deleted).
    private func deleteHighlighted(proxy: ScrollViewProxy) {
        guard let id = highlightedEntryID,
              let index = flattenedEntries.firstIndex(where: { $0.id == id }) else { return }
        manager.delete(id)
        let entries = flattenedEntries
        guard !entries.isEmpty else {
            highlightedEntryID = nil
            return
        }
        let next = entries[min(index, entries.count - 1)]
        highlightedEntryID = next.id
        proxy.scrollTo(next.id, anchor: nil)
    }

    // MARK: - Entry actions

    private func copyEntry(_ entry: ClipboardEntry) {
        UIPasteboard.general.string = entry.text
        manager.markUsed(entry.id)
    }

    private func pasteEntry(_ entry: ClipboardEntry) {
        pasteHandler(entry.text)
        manager.markUsed(entry.id)
        if style == .sheet {
            isPresented = false
        }
    }

    /// Columns used by the context menu's one-tap wrap. The transform panel's
    /// stepper is the way to wrap at any other width.
    private static let quickWrapColumns = 80

    /// Reflows off the main actor: a context-menu tap runs on the main actor and
    /// an entry can be a megabyte. nil columns unwraps, a value re-wraps.
    /// Cancellation reaches the detached job (which polls for it), so replacing
    /// one quick action with another abandons the first run's work instead of
    /// leaving two megabyte reflows racing. Returns nil when cancelled.
    private func formatted(_ text: String, columns: Int?) async -> String? {
        let handle = Task.detached(priority: .userInitiated) { () -> String? in
            guard let columns else { return try? ClipboardTextReflow.unwrap(text) }
            return try? ClipboardTextReflow.wrap(text, columns: columns)
        }
        return await withTaskCancellationHandler {
            await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// The reflow runs across a suspension point, and a background trip resets
    /// `isUnlocked` (and disabling the manager wipes the store). Re-check both
    /// before emitting the result: a formatting task started while unlocked
    /// must not paste or copy plaintext into a now-locked session.
    private func mayStillEmit(_ entry: ClipboardEntry) -> Bool {
        manager.isEnabled && !isLocked && manager.entries.contains { $0.id == entry.id }
    }

    private enum FormatDestination {
        case terminal
        case pasteboard
    }

    /// Single-flight, mirroring the detail view's transform runner: a second
    /// quick action cancels the first, so a slow "Copy Wrapped" can never land
    /// after the "Copy Unwrapped" that replaced it. Cancelled runs bail before
    /// touching the pasteboard or the terminal, and the overlay cancels the
    /// task when it goes away.
    private func runFormat(_ entry: ClipboardEntry, columns: Int?, into destination: FormatDestination) {
        formatTask?.cancel()
        let text = entry.text
        formatTask = Task {
            guard let result = await formatted(text, columns: columns) else { return }
            guard !Task.isCancelled, mayStillEmit(entry) else { return }
            switch destination {
            case .terminal:
                pasteHandler(result)
                if style == .sheet {
                    isPresented = false
                }
            case .pasteboard:
                UIPasteboard.general.string = result
            }
            manager.markUsed(entry.id)
        }
    }

    private func pasteFormatted(_ entry: ClipboardEntry, columns: Int?) {
        runFormat(entry, columns: columns, into: .terminal)
    }

    private func copyFormatted(_ entry: ClipboardEntry, columns: Int?) {
        runFormat(entry, columns: columns, into: .pasteboard)
    }

    private func attemptUnlock() {
        guard isLocked else { return }
        Task { @MainActor in
            let context = LAContext()
            let reason = String(localized: "Unlock clipboard history", comment: "Biometric prompt reason")
            do {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                if success {
                    manager.isUnlocked = true
                    unlockFailed = false
                }
            } catch {
                unlockFailed = true
            }
        }
    }

    // MARK: - HUD presentation

    /// Fixed content-area height (below the header). Keeping this constant across
    /// every internal state (disabled / locked / list / empty / detail) means the
    /// panel never changes size when the manager's data loads asynchronously — so
    /// the hosting container measures and anchors it once, with no reposition jump.
    private static let hudContentHeight: CGFloat = 440

    private var hudBody: some View {
        VStack(spacing: 0) {
            hudHeader

            hudContent
                .frame(width: style == .sidebar ? nil : 380, height: style == .sidebar ? nil : Self.hudContentHeight)
                .frame(maxWidth: .infinity, maxHeight: style == .sidebar ? .infinity : nil)
        }
        .frame(width: style == .sidebar ? nil : 380)
        .floatingHUDPanelBackground()
        // Normally the HUD opens in passthrough and keyboard mode arrives via
        // onChange; onAppear covers a re-mount while the mode is already on.
        .onAppear {
            if keyboardMode { enterKeyboardMode() }
        }
        .onChange(of: keyboardMode) { _, on in
            if on { enterKeyboardMode() } else { exitKeyboardModeCleanup() }
        }
        // Row tap opens the detail view: the search field unmounts, so keyboard
        // mode must drop (the focus gate releases and the terminal reclaims —
        // pointer intent).
        .onChange(of: selectedEntryID) { _, newValue in
            if newValue != nil, keyboardMode { keyboardMode = false }
        }
        // Filter changed: reset the highlight to the first visible match.
        .onChange(of: searchMatchIDs) {
            if keyboardMode { highlightedEntryID = flattenedEntries.first?.id }
        }
        // Entries mutated underneath the highlight (live capture, retention
        // sweep): keep the ID if still visible, else fall back to the top.
        .onChange(of: manager.entriesRevision) {
            guard keyboardMode else { return }
            if highlightedEntry == nil { highlightedEntryID = flattenedEntries.first?.id }
        }
        // Keyboard mode pins focus to the search field while the list pane is
        // up (a header button click on macOS can steal it); re-request instead
        // of silently going dead.
        .onChange(of: searchFieldFocused) { _, focused in
            if keyboardMode, !focused, selectedEntryID == nil, isPresented {
                searchFocusRequestID += 1
            }
        }
    }

    @ViewBuilder
    private var hudContent: some View {
        if !manager.isEnabled {
            disabledContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isLocked {
            lockedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let entry = selectedEntry {
            ClipboardEntryDetailView(
                entry: entry,
                style: .hud,
                onBack: { selectedEntryID = nil },
                onCopy: { copyEntry($0) },
                onPaste: { pasteEntry($0) },
                onTogglePin: { manager.togglePin($0.id) },
                onDelete: { entry in
                    manager.delete(entry.id)
                    selectedEntryID = nil
                }
            )
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    searchField(proxy: proxy)

                    Divider()

                    let (pinned, recent) = partitionedEntries
                    if pinned.isEmpty && recent.isEmpty {
                        emptyContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                if !pinned.isEmpty {
                                    hudSectionHeader(String(localized: "Pinned", comment: "Clipboard list section"))
                                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, entry in
                                        hudRow(entry, quickSelectIndex: quickSelectBadge(flatIndex: index))
                                    }
                                }
                                if !recent.isEmpty {
                                    hudSectionHeader(String(localized: "Recent", comment: "Clipboard list section"))
                                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                                        hudRow(entry, quickSelectIndex: quickSelectBadge(flatIndex: pinned.count + index))
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var hudHeader: some View {
        HStack(spacing: 8) {
            if selectedEntry != nil {
                Button {
                    selectedEntryID = nil
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            Text("Clipboard")
                .font(.headline)
                .fontWeight(.semibold)

            if manager.isEnabled, !isLocked, selectedEntryID == nil {
                Text("\(manager.entries.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if manager.isEnabled, !isLocked, !manager.entries.isEmpty, selectedEntryID == nil {
                Button {
                    showClearConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear All History"))
                // Attached here, NOT on the panel root: a presentation modifier
                // on the hosted root breaks DraggableHUDContainer's first
                // intrinsic-size measurement and the panel latches a bogus frame.
                .confirmationDialog(
                    "Clear all clipboard history?",
                    isPresented: $showClearConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Clear All History", role: .destructive) {
                        manager.clearAll()
                        selectedEntryID = nil
                    }
                } message: {
                    Text("This deletes every entry, including pinned ones.")
                }
            }

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

    /// UIKit-backed field (SidebarSearchField) so keyboard mode gets
    /// deterministic focus and key handling on iPad and Mac Catalyst: arrows
    /// move the highlight (hold-to-repeat), Return pastes, Escape closes, and
    /// the command chords ride first-responder keyCommands. Outside keyboard
    /// mode it behaves like the plain TextField it replaced (tap to focus,
    /// type to filter; the chord handlers are detached so arrows/Return keep
    /// their default text-field behavior).
    private func searchField(proxy: ScrollViewProxy) -> some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            SidebarSearchField(
                text: $searchText,
                placeholder: String(localized: "Search clipboard history"),
                fontSize: 17,
                canFocus: keyboardMode && isPresented && selectedEntryID == nil,
                focusRequestID: searchFocusRequestID,
                // Outside keyboard mode (tap-focused in passthrough) the arrows
                // keep their default text-field behavior.
                capturesNavigationKeys: keyboardMode,
                onMoveUpBegan: {
                    guard keyboardMode else { return }
                    moveHighlight(by: -1, proxy: proxy)
                    arrowKeyRepeatManager.start(direction: .up) {
                        moveHighlight(by: -1, proxy: proxy)
                    }
                },
                onMoveUpEnded: { arrowKeyRepeatManager.stop(direction: .up) },
                onMoveDownBegan: {
                    guard keyboardMode else { return }
                    moveHighlight(by: 1, proxy: proxy)
                    arrowKeyRepeatManager.start(direction: .down) {
                        moveHighlight(by: 1, proxy: proxy)
                    }
                },
                onMoveDownEnded: { arrowKeyRepeatManager.stop(direction: .down) },
                onEscape: { closeFromKeyboardMode() },
                onSubmit: {
                    if keyboardMode { pasteHighlightedAndClose() }
                },
                onFocusChange: { focused in
                    // Defer off this runloop: begin-editing can fire
                    // synchronously from becomeFirstResponder() inside
                    // updateUIView, where a direct @State write would be
                    // "modifying state during view update".
                    DispatchQueue.main.async {
                        searchFieldFocused = focused
                    }
                },
                onModifiedSubmit: keyboardMode ? { copyHighlighted(proxy: proxy) } : nil,
                onQuickSelect: keyboardMode ? { quickSelect($0) } : nil,
                onTogglePin: keyboardMode ? { togglePinHighlighted(proxy: proxy) } : nil,
                onDeleteEntry: keyboardMode ? { deleteHighlighted(proxy: proxy) } : nil
            )
            // Pin the height so focus and mode transitions never reflow the
            // panel (constant-size contract with DraggableHUDContainer).
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
        // Keyboard-mode indicator: an overlay stroke, so zero size impact.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor.opacity(keyboardMode ? 0.6 : 0), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func hudSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func hudRow(_ entry: ClipboardEntry, quickSelectIndex: Int? = nil) -> some View {
        Button {
            selectedEntryID = entry.id
        } label: {
            entryRowContent(entry, quickSelectIndex: quickSelectIndex)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Keyboard-mode highlight: a background fill, so zero size impact.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(
                    keyboardMode && entry.id == highlightedEntryID ? 0.18 : 0))
                .padding(.horizontal, 8)
        )
        .id(entry.id)
        .contextMenu { entryContextMenu(entry) }
    }

    // MARK: - Shared row context menu

    /// Long-press actions, shared by the HUD row and the iPhone sheet row.
    @ViewBuilder
    private func entryContextMenu(_ entry: ClipboardEntry) -> some View {
        Button {
            pasteEntry(entry)
        } label: {
            Label(String(localized: "Paste"), systemImage: "doc.on.clipboard")
        }
        Button {
            copyEntry(entry)
        } label: {
            Label(String(localized: "Copy"), systemImage: "doc.on.doc")
        }
        Menu {
            Button {
                pasteFormatted(entry, columns: nil)
            } label: {
                Label(String(localized: "Paste Unwrapped", comment: "Clipboard format action"),
                      systemImage: "text.append")
            }
            Button {
                pasteFormatted(entry, columns: Self.quickWrapColumns)
            } label: {
                Label(String(localized: "Paste Wrapped (\(Self.quickWrapColumns))", comment: "Clipboard format action, argument is a column count"),
                      systemImage: "text.justify")
            }
            Divider()
            Button {
                copyFormatted(entry, columns: nil)
            } label: {
                Label(String(localized: "Copy Unwrapped", comment: "Clipboard format action"),
                      systemImage: "text.append")
            }
            Button {
                copyFormatted(entry, columns: Self.quickWrapColumns)
            } label: {
                Label(String(localized: "Copy Wrapped (\(Self.quickWrapColumns))", comment: "Clipboard format action, argument is a column count"),
                      systemImage: "text.justify")
            }
        } label: {
            Label(String(localized: "Format", comment: "Clipboard row context menu submenu"), systemImage: "textformat")
        }
        Button {
            manager.togglePin(entry.id)
        } label: {
            entry.pinned
                ? Label(String(localized: "Unpin"), systemImage: "pin.slash")
                : Label(String(localized: "Pin"), systemImage: "pin")
        }
        Button(role: .destructive) {
            manager.delete(entry.id)
        } label: {
            Label(String(localized: "Delete"), systemImage: "trash")
        }
    }

    // MARK: - Sheet presentation (iPhone)

    private var sheetBody: some View {
        NavigationStack {
            Group {
                if !manager.isEnabled {
                    disabledContent
                } else if isLocked {
                    lockedContent
                } else if filteredEntries.isEmpty {
                    emptyContent
                } else {
                    sheetList
                }
            }
            .navigationTitle("Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if manager.isEnabled, !isLocked, !manager.entries.isEmpty {
                        Button {
                            showClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(Text("Clear All History"))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .confirmationDialog(
                "Clear all clipboard history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    manager.clearAll()
                }
            } message: {
                Text("This deletes every entry, including pinned ones.")
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
    }

    private var sheetList: some View {
        let (pinned, recent) = partitionedEntries
        return List {
            if !pinned.isEmpty {
                Section(String(localized: "Pinned", comment: "Clipboard list section")) {
                    ForEach(pinned) { entry in
                        sheetRow(entry)
                    }
                }
            }
            if !recent.isEmpty {
                Section(String(localized: "Recent", comment: "Clipboard list section")) {
                    ForEach(recent) { entry in
                        sheetRow(entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sheetRow(_ entry: ClipboardEntry) -> some View {
        NavigationLink {
            ClipboardEntryDetailView(
                entry: entry,
                style: .sheet,
                onBack: nil,
                onCopy: { copyEntry($0) },
                onPaste: { pasteEntry($0) },
                onTogglePin: { manager.togglePin($0.id) },
                onDelete: { manager.delete($0.id) }
            )
        } label: {
            entryRowContent(entry)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                manager.togglePin(entry.id)
            } label: {
                entry.pinned
                    ? Label(String(localized: "Unpin"), systemImage: "pin.slash")
                    : Label(String(localized: "Pin"), systemImage: "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                manager.delete(entry.id)
            } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .contextMenu { entryContextMenu(entry) }
    }

    // MARK: - Shared row content

    private func entryRowContent(_ entry: ClipboardEntry, quickSelectIndex: Int? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Keyboard mode swaps the source icon for the Ctrl+digit badge on
            // the first nine rows — same fixed 20pt slot, so no layout shift.
            Group {
                if let quickSelectIndex {
                    Text("\(quickSelectIndex)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.1))
                        )
                } else {
                    Image(systemName: entry.sourceIconName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 20)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preview)
                    .font(.system(.subheadline, design: .monospaced))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    Text(entry.sourceLabel)
                    Text(verbatim: "·")
                    Text(entry.lastUsedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.top, 3)
            }
        }
    }

    // MARK: - Empty / disabled / locked states

    private var emptyContent: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: searchText.isEmpty ? "list.clipboard" : "magnifyingglass")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No clipboard history yet" : "No matches")
                .font(.headline)
            if searchText.isEmpty {
                Text("Text you copy or paste in a terminal will appear here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var disabledContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.clipboard")
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Clipboard history is off")
                    .font(.headline)
                Text("Keeps an encrypted, device-only history of copies and pastes made inside the app.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                manager.isEnabled = true
            } label: {
                Text("Enable Clipboard History")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            // Neutral bordered style, not `.borderedProminent`: the terminal
            // theme's accent is piped into the SwiftUI tint, so a filled button
            // takes on arbitrary theme colors and reads badly. Matches the
            // Find HUD's `.bordered` + `.tint(.primary)`.
            .buttonStyle(.bordered)
            .tint(.primary)
            .controlSize(.large)
            .buttonBorderShape(.capsule)

            Label("Encrypted on this device, never synced", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
    }

    private var lockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: SSHKeyAuthManager.shared.biometricIconName)
                .font(.system(size: 44))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 6) {
                Text("Clipboard history is locked")
                    .font(.headline)
                if unlockFailed {
                    Text("Authentication failed")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                attemptUnlock()
            } label: {
                Label("Unlock with \(SSHKeyAuthManager.shared.biometricTypeName)",
                      systemImage: SSHKeyAuthManager.shared.biometricIconName)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .onAppear {
            attemptUnlock()
        }
    }
}

// MARK: - Entry detail + transforms

struct ClipboardEntryDetailView: View {
    let entry: ClipboardEntry
    let style: ClipboardManagerOverlay.Style
    var onBack: (() -> Void)?
    let onCopy: (ClipboardEntry) -> Void
    let onPaste: (ClipboardEntry) -> Void
    let onTogglePin: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void

    @State private var selectedTransformID: String?
    @State private var transformResult: Result<String, Error>?
    @State private var parameterValue = 80
    @State private var transformTask: Task<Void, Never>?
    @State private var isTransforming = false

    /// Pops the pushed detail in the iPhone sheet (NavigationStack). No-op in the
    /// HUD, where the parent swaps back to the list via `onDelete`.
    @Environment(\.dismiss) private var dismiss

    private var selectedTransform: ClipboardTransform? {
        guard let id = selectedTransformID else { return nil }
        return ClipboardTransformCatalog.all.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                metadataRow

                fullTextBox

                actionBar

                Divider()

                transformsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(style == .sheet ? Text("Entry") : Text(verbatim: ""))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            transformTask?.cancel()
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.sourceIconName)
                .foregroundColor(.secondary)
            Text(entry.sourceLabel)
            Text(verbatim: "·")
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
            Spacer()
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .foregroundColor(.orange)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private var fullTextBox: some View {
        BoundedMonospacedTextBox(
            text: entry.text,
            totalBytes: entry.byteCount,
            background: Color.primary.opacity(0.06)
        )
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                onPaste(entry)
            } label: {
                Label(String(localized: "Paste"), systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .tint(.primary)

            Button {
                onCopy(entry)
            } label: {
                Label(String(localized: "Copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                onTogglePin(entry)
            } label: {
                Image(systemName: entry.pinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(entry.pinned ? Text("Unpin") : Text("Pin"))

            Button(role: .destructive) {
                // Pop the sheet's pushed detail before deleting so it stops
                // rendering/acting on its now-stale value copy. The HUD path
                // swaps back to the list inside onDelete instead (dismiss no-ops).
                if style == .sheet {
                    dismiss()
                }
                onDelete(entry)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Text("Delete"))
        }
        .font(.subheadline)
        .controlSize(.small)
    }

    // MARK: Transforms

    private var transformsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transform")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Menu {
                    ForEach(ClipboardTransform.Category.allCases) { category in
                        let transforms = ClipboardTransformCatalog.transforms(in: category)
                        if !transforms.isEmpty {
                            Menu(category.displayName) {
                                ForEach(transforms) { transform in
                                    Button {
                                        select(transform)
                                    } label: {
                                        Label(transform.name, systemImage: transform.icon)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedTransform?.name ?? String(localized: "Choose…", comment: "Transform picker placeholder"))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                }
            }

            if let transform = selectedTransform {
                if case .integer(let label, _, let range) = transform.parameter {
                    Stepper(value: $parameterValue, in: range, step: 4) {
                        Text(verbatim: "\(label): \(parameterValue)")
                            .font(.caption)
                    }
                    .onChange(of: parameterValue) {
                        recompute()
                    }
                }

                if isTransforming {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else {
                    switch transformResult {
                    case .success(let result):
                        BoundedMonospacedTextBox(
                            text: result,
                            totalBytes: result.utf8.count,
                            background: Color.accentColor.opacity(0.08)
                        )

                        HStack(spacing: 8) {
                            Button {
                                UIPasteboard.general.string = result
                            } label: {
                                Label(String(localized: "Copy Result"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            if !transform.isDisplayOnly {
                                Button {
                                    ClipboardHistoryManager.shared.record(result, source: .transform(name: transform.name))
                                } label: {
                                    Label(String(localized: "Save as Entry"), systemImage: "plus.square.on.square")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .font(.caption)
                        .controlSize(.small)

                    case .failure(let error):
                        Label {
                            Text(error.localizedDescription)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(.caption)
                        .foregroundColor(.orange)

                    case nil:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func select(_ transform: ClipboardTransform) {
        selectedTransformID = transform.id
        if case .integer(_, let defaultValue, _) = transform.parameter {
            parameterValue = defaultValue
        }
        recompute()
    }

    /// Runs the transform off the main actor: applies can walk the full entry
    /// (JSON pretty-print, ANSI stripping, ...) and must not stall the UI.
    /// Single-flight: each run waits out its predecessor before starting its
    /// detached work, so mashing the stepper can never pile up concurrent jobs —
    /// cancelled wrappers in the chain exit without spawning theirs. The pure
    /// string transforms don't observe cancellation mid-apply, so at worst one
    /// stale job runs to completion and is discarded.
    private func recompute() {
        transformTask?.cancel()
        guard let transform = selectedTransform else {
            transformResult = nil
            isTransforming = false
            return
        }
        let text = entry.text
        let parameter = transform.parameter != nil ? parameterValue : nil
        let apply = transform.apply
        isTransforming = true
        let previous = transformTask
        transformTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            let handle = Task.detached(priority: .userInitiated) {
                Result { try apply(text, parameter) }
            }
            let result = await withTaskCancellationHandler {
                await handle.value
            } onCancel: {
                handle.cancel()
            }
            // A newer recompute cancelled this one; its own task owns the state.
            guard !Task.isCancelled else { return }
            transformResult = result
            isTransforming = false
        }
    }
}

// MARK: - Bounded text box

/// Renders a bounded excerpt of potentially huge text. SwiftUI lays out the whole
/// string it is given even behind a short scroll viewport, so megabyte entries must
/// never reach Text directly. Three caps because any single one is insufficient: a
/// character cap alone still admits thousands of short lines, a line cap alone
/// admits one megabyte-wide line on the horizontal axis. All slicing is
/// Character-based so graphemes never split.
private struct BoundedMonospacedTextBox: View {
    let text: String
    let totalBytes: Int
    let background: Color

    private static let maxCharacters = 16_384
    private static let maxLines = 200
    private static let maxLineCharacters = 2_048

    var body: some View {
        let (excerpt, truncated) = Self.makeExcerpt(from: text)
        VStack(alignment: .leading, spacing: 4) {
            ScrollView([.vertical, .horizontal]) {
                Text(excerpt)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 140)
            .background(background)
            .cornerRadius(8)

            if truncated {
                let shown = excerpt.utf8.count.formatted(.byteCount(style: .file))
                let total = totalBytes.formatted(.byteCount(style: .file))
                Text(String(localized: "Showing first \(shown) of \(total)",
                            comment: "Footer under a truncated clipboard text preview; arguments are formatted byte sizes like '16 KB' and '1 MB'"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Single bounded pass: never walks more than maxCharacters of the input.
    private static func makeExcerpt(from text: String) -> (text: String, truncated: Bool) {
        var truncated = false
        var slice = Substring(text)
        if let cutoff = text.index(text.startIndex, offsetBy: maxCharacters, limitedBy: text.endIndex),
           cutoff != text.endIndex {
            slice = text[..<cutoff]
            truncated = true
        }

        var lines = slice.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            truncated = true
        }
        for index in lines.indices where lines[index].count > maxLineCharacters {
            lines[index] = lines[index].prefix(maxLineCharacters)
            truncated = true
        }

        guard truncated else { return (text, false) }
        return (lines.joined(separator: "\n"), true)
    }
}
