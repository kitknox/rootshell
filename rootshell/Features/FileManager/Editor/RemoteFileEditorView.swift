//
//  RemoteFileEditorView.swift
//  rootshell
//
//  In-app code, JSON and config editor for local and remote files, shown as a
//  tab inside the file manager panel. Features syntax highlighting, aligned
//  line numbers, smart indentation, native Find & Replace, JSON formatting,
//  conflict protection, and automatic upload back to SFTP / S3 / local
//  endpoints on save. Document state lives in RemoteFileEditorDocument.
//

import SwiftUI
import UIKit

/// Input describing a file to open in the in-app editor.
struct RemoteFileEditorRequest: Identifiable {
    let id = UUID()
    let entry: RFEntry
    let endpoint: FileEndpoint
    let prompts: FileManagerPrompts
    /// Bytes, fingerprint, and serving principal when content sniffing already downloaded the file.
    let preloaded: FetchedRemoteFile?
}

// MARK: - Editor

struct RemoteFileEditorView: View {
    typealias CursorPosition = RemoteFileEditorDocument.CursorPosition

    /// Toggles the panel between full size and the presentation it came from.
    struct Zoom {
        let isZoomed: Bool
        let toggle: () -> Void

        var title: String {
            isZoomed
                ? String(localized: "Exit Full Size", comment: "File editor zoom button: leave full size")
                : String(localized: "Full Size", comment: "File editor zoom button: cover the terminal area")
        }

        var systemImage: String {
            isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        }
    }

    @Bindable var document: RemoteFileEditorDocument
    let manager: FileManagerModel
    var zoom: Zoom?
    /// The panel's focus request; a new value moves the keyboard into the text.
    let focusRequestID: Int
    /// False while another tab (or the file list) is on show over this one.
    var isActive = true
    var touchSized = false
    /// A side rail carries Find, Save, zoom and the menu; the toolbar keeps the path.
    var actionsInRail = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Setting(Settings.Transfer.fileManagerEditorWrapLines) private var wrapLines
    @Setting(Settings.Transfer.fileManagerEditorShowLineNumbers) private var showLineNumbers

    /// A question the editor needs answered. Asked in a bar inside the editor rather
    /// than a system dialog, which would float over the terminal in the window's
    /// appearance instead of the panel's theme.
    private enum Decision {
        case conflict(RemoteFileEditorDocument.Conflict)
        case close
        case handoff(RemoteFileEditorDocument.Handoff)
        case reload
    }

    private var decision: Decision? {
        if let conflict = document.conflict { return .conflict(conflict) }
        if manager.pendingEditorClose === document { return .close }
        if let handoff = document.pendingHandoff { return .handoff(handoff) }
        if document.confirmsReload { return .reload }
        return nil
    }

    private var request: RemoteFileEditorRequest { document.request }
    private var isRemote: Bool { document.isRemote }
    private var isReady: Bool { document.loadState == .ready }

    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var editorBackground: Color {
        sheetThemeColors?.background ?? Color(uiColor: .systemBackground)
    }

    private var editorBackgroundUIColor: UIColor {
        let traits = UITraitCollection(userInterfaceStyle: surfaceScheme == .dark ? .dark : .light)
        if let theme = sheetThemeColors {
            return UIColor(theme.background).resolvedColor(with: traits)
        }
        return UIColor.systemBackground.resolvedColor(with: traits)
    }

    /// A tab that isn't on show keeps only its text view mounted (for undo and
    /// scroll); its chrome comes back when selected. Each `if` keeps a fixed slot,
    /// so the text view is never rebuilt by the switch.
    var body: some View {
        VStack(spacing: 0) {
            if isActive {
                toolbar
                Divider()
            }
            if isActive, let decision {
                decisionBar(decision)
                Divider()
            }
            if isActive, let banner = activeBannerMessage {
                errorBanner(banner)
                Divider()
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isActive, isReady {
                Divider()
                RemoteFileEditorStatusBar(document: document, chromeBackground: chromeBackground)
            }
        }
        .background(editorBackground)
        .environment(\.colorScheme, surfaceScheme)
        .accessibilityHidden(!isActive)
    }

    private var chromeBackground: Color {
        sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemBackground)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: touchSized ? 0 : 12) {
            // The host gives up its middle only after the path has given up its start,
            // and the row never grows past the panel (that pushed the text under a side rail).
            HStack(spacing: 6) {
                Text(request.endpoint.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(verbatim: request.entry.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(Text(verbatim: "\(request.endpoint.displayName):\(request.entry.path)"))
            .accessibilityElement(children: .combine)
            .layoutPriority(-1)
            Spacer(minLength: 4)
            statusIndicator
            if !actionsInRail {
                if isReady {
                    Button {
                        document.findRequestID += 1
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .panelTouchTarget(touchSized)
                    }
                    .help(String(localized: "Find & Replace (⌘F)", comment: "File editor find tooltip"))
                    .accessibilityLabel(String(localized: "Find", comment: "File editor find button"))

                    Button {
                        document.save()
                    } label: {
                        Text(String(localized: "Save", comment: "File editor save button"))
                            .fontWeight(.semibold)
                            .panelTouchTarget(touchSized)
                    }
                    .disabled(!document.isDirty || document.saveState == .saving)
                    .help(isRemote
                          ? String(localized: "Save and Upload (⌘S)", comment: "File editor save tooltip")
                          : String(localized: "Save (⌘S)", comment: "File editor save tooltip"))
                }
                if let zoom {
                    Button(action: zoom.toggle) {
                        Label(zoom.title, systemImage: zoom.systemImage)
                            .labelStyle(.iconOnly)
                            .panelTouchTarget(touchSized)
                    }
                    .help(zoom.title)
                }
                RemoteFileEditorMenu(document: document, manager: manager, touchSized: touchSized)
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, 12)
        .padding(.trailing, touchSized ? 4 : 12)
        .padding(.vertical, touchSized ? 0 : 6)
        .frame(minHeight: actionsInRail ? 32 : nil)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch document.saveState {
        case .saving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(isRemote
                     ? String(localized: "Uploading…", comment: "File editor uploading status")
                     : String(localized: "Saving…", comment: "File editor saving status"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .saved:
            Label(isRemote
                  ? String(localized: "Uploaded", comment: "File editor uploaded status")
                  : String(localized: "Saved", comment: "File editor saved status"),
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .idle, .failed:
            EmptyView()
        }
    }

    private var activeBannerMessage: String? {
        if case .failed(let message) = document.saveState { return message }
        return document.inlineBanner
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if case .failed = document.saveState {
                Button(String(localized: "Retry", comment: "Retry button")) {
                    document.save()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            Button {
                document.inlineBanner = nil
                if case .failed = document.saveState { document.saveState = .idle }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private var mainContent: some View {
        switch document.loadState {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(isRemote
                     ? String(localized: "Downloading \(request.entry.name)…", comment: "File editor loading remote file")
                     : String(localized: "Opening \(request.entry.name)…", comment: "File editor loading local file"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .binary:
            VStack(spacing: 12) {
                Image(systemName: "doc.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(String(localized: "Binary File", comment: "File editor binary file title"))
                    .font(.headline)
                Text(String(localized: "“\(request.entry.name)” doesn't look like plain text and can't be edited in the text editor.", comment: "File editor binary file message"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 10) {
                    Button(String(localized: "Quick Look", comment: "File editor binary fallback")) {
                        manager.performHandoff(.quickLook, from: document)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "Open in External App", comment: "File editor binary external fallback")) {
                        manager.performHandoff(.external(nil), from: document)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 380)
                Button(String(localized: "Retry", comment: "Retry button")) {
                    document.reload()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            RemoteCodeTextView(
                text: $document.text,
                externalTextRevision: document.externalTextRevision,
                language: document.language,
                indentation: document.indentation,
                fontSize: document.fontSize,
                wrapLines: wrapLines,
                showLineNumbers: showLineNumbers,
                isDark: surfaceScheme == .dark,
                backgroundColor: editorBackgroundUIColor,
                findTrigger: document.findRequestID,
                focusRequestID: focusRequestID,
                isActive: isActive,
                document: document,
                onCursorChange: { document.cursorPosition = $0 },
                onStatsChange: { lines, bytes in
                    if document.lineCount != lines { document.lineCount = lines }
                    if document.byteCount != bytes { document.byteCount = bytes }
                },
                onSaveShortcut: {
                    if document.isDirty { document.save() }
                },
                onCloseShortcut: { manager.requestCloseEditor(document) },
                onToggleZoom: zoom?.toggle,
                onEscape: { cancelDecision() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Decisions

    private struct DecisionAction: Identifiable {
        enum Kind { case primary, destructive, cancel }
        var id: String { title }
        let title: String
        let kind: Kind
        let perform: () -> Void
    }

    private func decisionBar(_ decision: Decision) -> some View {
        let (title, message, actions) = decisionContent(decision)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isConflict(decision) ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .foregroundStyle(isConflict(decision) ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    if let message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            // One row when it fits; a narrow sidebar stacks the buttons.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { decisionButtons(actions) }
                VStack(alignment: .leading, spacing: 6) { decisionButtons(actions) }
            }
            .controlSize(touchSized ? .regular : .small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func decisionButtons(_ actions: [DecisionAction]) -> some View {
        ForEach(actions) { action in
            switch action.kind {
            case .primary:
                // Tinted text on a tinted fill reads on any theme accent; white on a light accent did not.
                Button(action: action.perform) {
                    Text(action.title).fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            case .destructive:
                Button(action.title, role: .destructive, action: action.perform)
                    .buttonStyle(.bordered)
                    .tint(.red)
            case .cancel:
                Button(action.title, role: .cancel, action: action.perform)
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Escape answers the bar with Cancel.
    private func cancelDecision() -> Bool {
        switch decision {
        case .conflict: document.conflict = nil
        case .close: manager.pendingEditorClose = nil
        case .handoff: document.pendingHandoff = nil
        case .reload: document.confirmsReload = false
        case nil: return false
        }
        return true
    }

    private func isConflict(_ decision: Decision) -> Bool {
        if case .conflict = decision { true } else { false }
    }

    private func decisionContent(_ decision: Decision) -> (String, String?, [DecisionAction]) {
        let name = request.entry.name
        let cancelTitle = String(localized: "Cancel", comment: "Cancel button")
        let discardTitle = String(localized: "Discard Changes", comment: "File editor discard button")
        let saveTitle = isRemote
            ? String(localized: "Save & Upload", comment: "File editor save and close button")
            : String(localized: "Save", comment: "File editor save and close button")
        switch decision {
        case .close:
            return (
                String(localized: "You have unsaved changes to “\(name)”.", comment: "File editor unsaved changes title; argument is a file name"),
                nil,
                [
                    DecisionAction(title: saveTitle, kind: .primary) {
                        manager.pendingEditorClose = nil
                        document.save { manager.closeEditor(document) }
                    },
                    DecisionAction(title: discardTitle, kind: .destructive) {
                        manager.closeEditor(document)
                    },
                    DecisionAction(title: cancelTitle, kind: .cancel) { manager.pendingEditorClose = nil },
                ]
            )
        case .handoff(let handoff):
            let title = if case .quickLook = handoff {
                String(localized: "Save changes before opening Quick Look?", comment: "File editor Quick Look handoff confirmation")
            } else {
                String(localized: "Save changes before switching editors?", comment: "File editor handoff confirmation")
            }
            return (title, nil, [
                DecisionAction(title: String(localized: "Save & Continue", comment: "File editor save then continue handoff"), kind: .primary) {
                    document.pendingHandoff = nil
                    document.save { manager.performHandoff(handoff, from: document) }
                },
                DecisionAction(title: discardTitle, kind: .destructive) {
                    document.pendingHandoff = nil
                    manager.performHandoff(handoff, from: document)
                },
                DecisionAction(title: cancelTitle, kind: .cancel) { document.pendingHandoff = nil },
            ])
        case .reload:
            return (
                String(localized: "Reload “\(name)”?", comment: "File editor reload confirmation; argument is a file name"),
                isRemote
                    ? String(localized: "Your unsaved edits will be replaced with the current file from the server.", comment: "File editor reload confirmation message")
                    : String(localized: "Your unsaved edits will be replaced with the file as it is on disk.", comment: "File editor reload confirmation message for a local file"),
                [
                    DecisionAction(title: String(localized: "Discard Changes & Reload", comment: "File editor confirm reload"), kind: .destructive) {
                        document.confirmsReload = false
                        document.reload()
                    },
                    DecisionAction(title: cancelTitle, kind: .cancel) { document.confirmsReload = false },
                ]
            )
        case .conflict(.deleted):
            return (
                String(localized: "File Deleted on Server", comment: "File editor conflict alert title"),
                String(localized: "“\(name)” was deleted or renamed on \(request.endpoint.displayName) after you opened it. Recreating will write a new file at the original path.", comment: "File editor deleted conflict message"),
                [
                    DecisionAction(title: String(localized: "Recreate File", comment: "File editor conflict: recreate deleted remote file"), kind: .destructive) {
                        document.conflict = nil
                        document.save(forceOverwrite: true)
                    },
                    DecisionAction(title: cancelTitle, kind: .cancel) { document.conflict = nil },
                ]
            )
        case .conflict(.modified):
            return (
                String(localized: "File Changed on Server", comment: "File editor conflict alert title"),
                String(localized: "“\(name)” was modified on \(request.endpoint.displayName) after you opened it. Overwriting will replace those changes.", comment: "File editor modified conflict message"),
                [
                    DecisionAction(title: String(localized: "Reload Remote", comment: "File editor conflict: reload"), kind: .primary) {
                        document.conflict = nil
                        document.reload()
                    },
                    DecisionAction(title: String(localized: "Overwrite Remote", comment: "File editor conflict: overwrite"), kind: .destructive) {
                        document.conflict = nil
                        document.save(forceOverwrite: true)
                    },
                    DecisionAction(title: cancelTitle, kind: .cancel) { document.conflict = nil },
                ]
            )
        }
    }
}

/// The editor's ⋯ button, in its toolbar.
private struct RemoteFileEditorMenu: View {
    let document: RemoteFileEditorDocument
    let manager: FileManagerModel
    let touchSized: Bool

    var body: some View {
        Menu {
            RemoteFileEditorMenuItems(document: document, manager: manager)
        } label: {
            Image(systemName: "ellipsis.circle")
                .panelTouchTarget(touchSized)
        }
        // A save that ends in a conflict presents an alert; under an open menu that locked up the app.
        .disabled(document.saveState == .saving)
        .accessibilityLabel(String(localized: "Editor Options", comment: "File editor overflow menu"))
    }
}

/// The editor's menu: other ways to open the file, and view and reload options.
/// Shared by the toolbar's ⋯ button and a side rail's.
struct RemoteFileEditorMenuItems: View {
    let document: RemoteFileEditorDocument
    let manager: FileManagerModel

    @Setting(Settings.Transfer.fileManagerEditorWrapLines) private var wrapLines
    @Setting(Settings.Transfer.fileManagerEditorShowLineNumbers) private var showLineNumbers

    var body: some View {
        #if targetEnvironment(macCatalyst)
        Button {
            manager.requestHandoff(.external(nil), from: document)
        } label: {
            Label(String(localized: "Edit in External Editor", comment: "File editor menu"), systemImage: "arrow.up.forward.app")
        }
        if !document.externalApps.isEmpty {
            Menu {
                ForEach(document.externalApps) { app in
                    Button(app.name) {
                        manager.requestHandoff(.external(app.url), from: document)
                    }
                }
            } label: {
                Label(String(localized: "Open With", comment: "File editor menu: choose macOS app"), systemImage: "square.grid.2x2")
            }
        }
        #else
        if manager.openInEmbeddedEditor != nil {
            Button {
                manager.requestHandoff(.embedded(.vim), from: document)
            } label: {
                Label(String(localized: "Edit in Vim", comment: "File editor menu"), systemImage: "terminal")
            }
            Button {
                manager.requestHandoff(.embedded(.hx), from: document)
            } label: {
                Label(String(localized: "Edit in Helix (hx)", comment: "File editor menu"), systemImage: "terminal")
            }
        }
        Button {
            manager.requestHandoff(.external(nil), from: document)
        } label: {
            Label(String(localized: "Edit in External App…", comment: "File editor menu"), systemImage: "arrow.up.forward.app")
        }
        #endif

        Button {
            manager.requestHandoff(.quickLook, from: document)
        } label: {
            Label(String(localized: "Quick Look", comment: "File editor menu"), systemImage: "eye")
        }

        if document.loadState == .ready {
            Divider()
            if document.language == .json {
                Button {
                    document.formatJSON()
                } label: {
                    Label(String(localized: "Format JSON", comment: "File editor menu"), systemImage: "curlybraces")
                }
            }
            Toggle(isOn: Binding(
                get: { wrapLines },
                set: { SettingsStore.shared.set(Settings.Transfer.fileManagerEditorWrapLines, $0) }
            )) {
                Label(String(localized: "Wrap Lines", comment: "File editor menu"), systemImage: "text.word.spacing")
            }
            Toggle(isOn: Binding(
                get: { showLineNumbers },
                set: { SettingsStore.shared.set(Settings.Transfer.fileManagerEditorShowLineNumbers, $0) }
            )) {
                Label(String(localized: "Line Numbers", comment: "File editor menu"), systemImage: "list.number")
            }
            Menu {
                Button(String(localized: "Larger Text", comment: "File editor font size")) {
                    document.fontSize = min(24, document.fontSize + 1)
                }
                Button(String(localized: "Smaller Text", comment: "File editor font size")) {
                    document.fontSize = max(10, document.fontSize - 1)
                }
                Button(String(localized: "Default Size", comment: "File editor font size")) {
                    document.fontSize = 13
                }
            } label: {
                Label(String(localized: "Font Size", comment: "File editor menu"), systemImage: "textformat.size")
            }
            Divider()
            Button {
                if document.isDirty { document.confirmsReload = true } else { document.reload() }
            } label: {
                Label(document.isRemote
                      ? String(localized: "Reload from Server", comment: "File editor menu")
                      : String(localized: "Reload from Disk", comment: "File editor menu"),
                      systemImage: "arrow.clockwise")
            }
        }
    }
}

/// Its own view so per-keystroke cursor and size updates redraw only this row.
private struct RemoteFileEditorStatusBar: View {
    let document: RemoteFileEditorDocument
    let chromeBackground: Color

    var body: some View {
        HStack(spacing: 12) {
            Text(document.language.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Ln \(document.cursorPosition.line), Col \(document.cursorPosition.column)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(document.lineCount) \(document.lineCount == 1 ? String(localized: "line", comment: "Singular line count") : String(localized: "lines", comment: "Plural line count")) · \(FileRowView.sizeText(Int64(document.byteCount)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(document.document.encoding.rawValue) · \(document.document.lineEnding.rawValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(chromeBackground.opacity(0.6))
    }
}

/// The editor's tab row: the file list, then one tab per open document.
struct RemoteFileEditorTabStrip: View {
    let manager: FileManagerModel
    var touchSized = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    filesTab
                    ForEach(manager.editors) { document in
                        RemoteFileEditorTab(
                            document: document,
                            isSelected: manager.focusedEditorID == document.id,
                            touchSized: touchSized,
                            onSelect: { manager.showEditor(document) },
                            onClose: { manager.requestCloseEditor(document) }
                        )
                        .id(document.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
            .onChange(of: manager.focusedEditorID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Open Files", comment: "File manager editor tab row"))
    }

    private var filesTab: some View {
        let isSelected = manager.focusedEditorID == nil
        return Button {
            manager.showFiles()
        } label: {
            // Icon only: the panel header above already says Files.
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(minWidth: touchSized ? 44 : 32, minHeight: editorTabHeight(touchSized))
                .editorTabBackground(selected: isSelected)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Show Files", comment: "File manager editor tab row: back to the file list"))
        .accessibilityLabel(String(localized: "Files", comment: "File manager editor tab row: back to the file list"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Its own view so a document's dirty dot redraws only its tab.
private struct RemoteFileEditorTab: View {
    let document: RemoteFileEditorDocument
    let isSelected: Bool
    let touchSized: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 5) {
                    if document.loadState == .loading || document.saveState == .saving {
                        ProgressView().controlSize(.mini)
                    }
                    Text(document.entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                }
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .frame(minHeight: editorTabHeight(touchSized))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "\(document.endpoint.displayName):\(document.entry.path)"))

            // Unsaved files show a dot that turns into the close button on hover.
            Button(action: onClose) {
                ZStack {
                    if document.isDirty && !isHovering {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    } else {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: touchSized ? 28 : 16, height: editorTabHeight(touchSized))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(document.isDirty
                ? String(localized: "Close \(document.entry.name), unsaved changes", comment: "File editor tab close button with unsaved changes; argument is a file name")
                : String(localized: "Close \(document.entry.name)", comment: "File editor tab close button; argument is a file name"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .editorTabBackground(selected: isSelected)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "Close", comment: "File editor tab context menu"), action: onClose)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - UIKit Code Editor (Pre-Laid-Out TextKit 1 UITextView + GPU-Composited Line-Number Gutter)

private struct ResolvedColorKey: Equatable {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

private struct RemoteCodeTextView: UIViewRepresentable {
    @Binding var text: String
    let externalTextRevision: Int
    let language: FileEditorSyntax.Language
    let indentation: EditableTextDocument.Indentation
    let fontSize: CGFloat
    let wrapLines: Bool
    let showLineNumbers: Bool
    let isDark: Bool
    let backgroundColor: UIColor
    let findTrigger: Int
    let focusRequestID: Int
    /// False for an open tab that isn't on show; it keeps its view but not the keyboard.
    let isActive: Bool
    /// Records the caret and which focus request the text view already acted on.
    let document: RemoteFileEditorDocument
    let onCursorChange: (RemoteFileEditorView.CursorPosition) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onSaveShortcut: () -> Void
    let onCloseShortcut: () -> Void
    let onToggleZoom: (() -> Void)?
    let onEscape: () -> Bool

    func makeUIView(context: Context) -> CodeEditorContainerView {
        let container = CodeEditorContainerView()
        let textView = container.textView
        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.onIndent = { [weak textView, weak coordinator] in
            guard let textView else { return }
            coordinator?.insertIndentation(in: textView)
        }
        textView.onOutdent = { [weak textView, weak coordinator] in
            guard let textView else { return }
            coordinator?.outdentSelection(in: textView)
        }
        coordinator.attach(to: container)
        coordinator.configureAccessoryBarIfNeeded(on: textView)
        return container
    }

    static func dismantleUIView(_ container: CodeEditorContainerView, coordinator: Coordinator) {
        coordinator.tearDown()
        let textView = container.textView
        MenuShortcutState.shared.setSaveChordOwner(textView, active: false)
        textView.delegate = nil
        textView.layoutManager.delegate = nil
        textView.onSaveShortcut = nil
        textView.onCloseShortcut = nil
        textView.onToggleZoom = nil
        textView.onEscape = nil
        textView.onIndent = nil
        textView.onOutdent = nil
        textView.onDidLayoutNonContiguousViewport = nil
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        textView.inputAccessoryView = nil
        #endif
    }

    func updateUIView(_ container: CodeEditorContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let textView = container.textView
        textView.onSaveShortcut = onSaveShortcut
        textView.onCloseShortcut = onCloseShortcut
        textView.onToggleZoom = onToggleZoom
        textView.onEscape = onEscape
        if !isActive {
            // Its find bar holds the keyboard while open, so close that too.
            if textView.findInteraction?.isFindNavigatorVisible == true {
                textView.findInteraction?.dismissFindNavigator()
            }
            if textView.isFirstResponder { textView.resignFirstResponder() }
        }
        // SwiftUI's accessibilityHidden doesn't reach into a representable, so an
        // inactive tab hides its text view and reports no accessibility children.
        textView.isHidden = !isActive
        container.accessibilityElements = isActive ? nil : []

        let bgKey = ResolvedColorKey(backgroundColor)
        let fontChanged = coordinator.lastFontSize != fontSize
        let appearanceChanged = coordinator.lastIsDark != isDark
            || coordinator.lastBackgroundKey != bgKey
        let languageChanged = coordinator.lastLanguage != language
        let styleChanged = fontChanged || appearanceChanged || languageChanged
        let layoutChanged = coordinator.lastWrapLines != wrapLines
            || coordinator.lastShowLineNumbers != showLineNumbers
            || fontChanged
        let isFirstText = coordinator.lastExternalTextRevision == -1
        let textReplacedExternally = coordinator.lastExternalTextRevision != externalTextRevision

        coordinator.lastFontSize = fontSize
        coordinator.lastIsDark = isDark
        coordinator.lastBackgroundKey = bgKey
        coordinator.lastLanguage = language
        coordinator.lastWrapLines = wrapLines
        coordinator.lastShowLineNumbers = showLineNumbers
        coordinator.lastExternalTextRevision = externalTextRevision

        if layoutChanged {
            container.applyLayout(
                wrapLines: wrapLines,
                showLineNumbers: showLineNumbers,
                fontSize: fontSize,
                isDark: isDark,
                backgroundColor: backgroundColor
            )
        } else if appearanceChanged {
            container.applyTheme(isDark: isDark, fontSize: fontSize, backgroundColor: backgroundColor)
        }

        if textReplacedExternally {
            // A rebuilt view (presentation switch) picks up the caret where the last one left it.
            let previousSelection = isFirstText ? document.savedSelection : textView.selectedRange
            coordinator.isApplyingExternalText = true
            coordinator.clearHighlightSpans()
            let baseAttrs = coordinator.baseTextAttributes(fontSize: fontSize, isDark: isDark)
            textView.attributedText = NSAttributedString(string: text, attributes: baseAttrs)
            textView.typingAttributes = baseAttrs
            let newUTF16Length = textView.textStorage.length
            let clampedLocation = min(previousSelection.location, newUTF16Length)
            let clampedLength = isFirstText ? min(previousSelection.length, newUTF16Length - clampedLocation) : 0
            textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
            coordinator.isApplyingExternalText = false

            coordinator.rebuildLineIndex(from: text)
            container.updateLineIndex(coordinator.lineIndex, activeLine: coordinator.currentCursorLine, needsFullLayout: true)
            coordinator.scheduleHighlight(immediate: true)
            coordinator.reportCursor(for: textView, deferParentNotification: true)
            if isFirstText, clampedLocation > 0 {
                DispatchQueue.main.async { [weak textView] in
                    guard let textView else { return }
                    textView.scrollRangeToVisible(textView.selectedRange)
                }
            }
        } else if styleChanged {
            if fontChanged {
                let baseAttrs = coordinator.baseTextAttributes(fontSize: fontSize, isDark: isDark)
                let savedSelection = textView.selectedRange
                let storage = textView.textStorage
                if storage.length > 0 {
                    storage.beginEditing()
                    storage.addAttribute(.font, value: baseAttrs[.font]!, range: NSRange(location: 0, length: storage.length))
                    storage.endEditing()
                }
                textView.font = baseAttrs[.font] as? UIFont
                textView.typingAttributes = baseAttrs
                textView.selectedRange = savedSelection
                container.markNeedsFullLayout()
            }
            if appearanceChanged {
                let baseAttrs = coordinator.baseTextAttributes(fontSize: fontSize, isDark: isDark)
                textView.typingAttributes = baseAttrs
            }
            if languageChanged {
                coordinator.clearHighlightSpans()
                coordinator.scheduleHighlight(immediate: true)
            } else if appearanceChanged {
                coordinator.reapplyStoredHighlight(to: textView)
            }
            container.refreshVisibleGutterLines()
        }

        if coordinator.lastFindTrigger != findTrigger {
            coordinator.lastFindTrigger = findTrigger
            if findTrigger > 0 {
                textView.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        }

        // Only with a hardware keyboard, as for the file list: a software one would cover the text.
        if isActive, focusRequestID > 0, document.consumedFocusRequestID != focusRequestID,
           KeyboardTracker.shared.isHardwareKeyboard {
            document.consumedFocusRequestID = focusRequestID
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil, !textView.isFirstResponder else { return }
                textView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RemoteCodeTextView
        weak var container: CodeEditorContainerView?

        var lastFontSize: CGFloat = 0
        var lastIsDark: Bool?
        var lastBackgroundKey: ResolvedColorKey?
        var lastLanguage: FileEditorSyntax.Language?
        var lastWrapLines: Bool?
        var lastShowLineNumbers: Bool?
        var lastFindTrigger = 0
        var lastExternalTextRevision = -1

        var isApplyingExternalText = false
        private(set) var lineIndex = EditorLineIndex()
        private(set) var currentCursorLine = 1
        private var lastReportedCursor: RemoteFileEditorView.CursorPosition?

        private var highlightSpans: [FileEditorSyntax.Span] = []
        private var hasAppliedSyntaxColors = false
        private var pendingHighlight: (spans: [FileEditorSyntax.Span], expectedUTF16Length: Int)?
        private var highlightTask: Task<Void, Never>?
        private var highlightRevision = 0

        init(parent: RemoteCodeTextView) {
            self.parent = parent
            // A rebuilt view opens the find bar only on a new request.
            lastFindTrigger = parent.findTrigger
        }

        func attach(to container: CodeEditorContainerView) {
            self.container = container
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleTextStorageDidProcessEditing(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: container.textView.textStorage
            )
        }

        func tearDown() {
            highlightTask?.cancel()
            highlightTask = nil
            pendingHighlight = nil
            NotificationCenter.default.removeObserver(self)
            container = nil
        }

        func baseTextAttributes(fontSize: CGFloat, isDark: Bool) -> [NSAttributedString.Key: Any] {
            let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let baseColor: UIColor = isDark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.12, alpha: 1)
            return [
                .font: font,
                .foregroundColor: baseColor,
            ]
        }

        func rebuildLineIndex(from text: String) {
            lineIndex = EditorLineIndex(text: text)
        }

        func clearHighlightSpans() {
            highlightSpans = []
            hasAppliedSyntaxColors = false
            pendingHighlight = nil
        }

        func reapplyStoredHighlight(to textView: UITextView) {
            applyHighlightColors(highlightSpans, to: textView, isDark: parent.isDark)
        }

        @objc private func handleTextStorageDidProcessEditing(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let storage = notification.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else {
                return
            }
            lineIndex.applyEdit(
                editedRange: storage.editedRange,
                changeInLength: storage.changeInLength,
                in: storage.string as NSString
            )
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            let storage = textView.textStorage
            if lineIndex.utf16Length != storage.length {
                lineIndex = EditorLineIndex(nsString: storage.string as NSString)
            }
            let updatedText = textView.text ?? ""
            parent.text = updatedText
            parent.onStatsChange(lineIndex.lineCount, updatedText.utf8.count)
            reportCursor(for: textView)
            container?.updateLineIndex(lineIndex, activeLine: currentCursorLine, needsFullLayout: false)
            scheduleHighlight(immediate: false)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            parent.document.savedSelection = textView.selectedRange
            reportCursor(for: textView)
        }

        func reportCursor(for textView: UITextView, deferParentNotification: Bool = false) {
            let location = min(textView.selectedRange.location, lineIndex.utf16Length)
            let (line, column) = lineIndex.lineAndColumn(forUTF16Offset: location)
            if line != currentCursorLine {
                currentCursorLine = line
                container?.updateActiveLine(line)
            }
            let pos = RemoteFileEditorView.CursorPosition(line: line, column: column)
            if pos != lastReportedCursor {
                lastReportedCursor = pos
                if deferParentNotification {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.lastReportedCursor == pos else { return }
                        self.parent.onCursorChange(pos)
                    }
                } else {
                    parent.onCursorChange(pos)
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.syncGutterForScroll()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                flushPendingHighlightIfIdle()
                container?.refreshGutterAfterScrollEnded()
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            flushPendingHighlightIfIdle()
            container?.refreshGutterAfterScrollEnded()
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            flushPendingHighlightIfIdle()
            container?.refreshGutterAfterScrollEnded()
        }

        private func flushPendingHighlightIfIdle() {
            guard let pending = pendingHighlight,
                  let textView = container?.textView,
                  !textView.isDragging,
                  !textView.isDecelerating else {
                return
            }
            pendingHighlight = nil
            guard textView.markedTextRange == nil,
                  textView.textStorage.length == pending.expectedUTF16Length else {
                return
            }
            highlightSpans = pending.spans
            applyHighlightColors(pending.spans, to: textView, isDark: parent.isDark)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            // Skip smart indentation while an IME composition is active.
            guard textView.markedTextRange == nil else { return true }

            if replacement == "\t" {
                insertIndentation(in: textView)
                return false
            }

            if replacement == "\n" {
                let nsText = textView.textStorage.string as NSString
                let safeLocation = min(range.location, nsText.length)
                let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
                let prefixLength = max(0, safeLocation - lineRange.location)
                let linePrefix = nsText.substring(with: NSRange(location: lineRange.location, length: prefixLength))
                let leading = String(linePrefix.prefix(while: { $0 == " " || $0 == "\t" }))
                if !leading.isEmpty {
                    let inserted = "\n" + leading
                    if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                       let end = textView.position(from: start, offset: range.length),
                       let textRange = textView.textRange(from: start, to: end) {
                        textView.replace(textRange, withText: inserted)
                        return false
                    }
                }
            }
            return true
        }

        func insertIndentation(in textView: UITextView) {
            let indent = parent.indentation.insertString
            if let range = textView.selectedTextRange {
                textView.replace(range, withText: indent)
            }
        }

        func outdentSelection(in textView: UITextView) {
            let nsText = textView.textStorage.string as NSString
            let sel = textView.selectedRange
            let safeLocation = min(sel.location, nsText.length)
            let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
            let line = nsText.substring(with: lineRange)
            let removeCount: Int
            if line.hasPrefix("\t") {
                removeCount = 1
            } else {
                let spaces = line.prefix(while: { $0 == " " }).count
                let step = parent.indentation == .spaces(2) ? 2 : 4
                removeCount = min(spaces, step)
            }
            guard removeCount > 0,
                  let start = textView.position(from: textView.beginningOfDocument, offset: lineRange.location),
                  let end = textView.position(from: start, offset: removeCount),
                  let textRange = textView.textRange(from: start, to: end) else { return }
            textView.replace(textRange, withText: "")
        }

        func scheduleHighlight(immediate: Bool) {
            guard let textView = container?.textView else { return }
            guard textView.markedTextRange == nil else { return }

            highlightTask?.cancel()
            pendingHighlight = nil
            highlightRevision += 1
            let revision = highlightRevision
            let language = parent.language

            let utf16Count = textView.textStorage.length
            if language == .plain || utf16Count == 0 || utf16Count > FileEditorSyntax.maxHighlightUTF16Length {
                let needsClear = hasAppliedSyntaxColors
                highlightSpans = []
                if needsClear {
                    applyHighlightColors([], to: textView, isDark: parent.isDark)
                }
                return
            }

            let snapshot = textView.text ?? ""

            // Apply immediately for small files on initial load; debounce during active typing.
            if immediate && utf16Count <= 24_000 {
                let spans = FileEditorSyntax.highlight(snapshot, language: language)
                highlightSpans = spans
                applyHighlightColors(spans, to: textView, isDark: parent.isDark)
                return
            }

            highlightTask = Task { [weak self, weak textView] in
                if !immediate {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { return }
                let spans = await Task.detached(priority: .userInitiated) {
                    FileEditorSyntax.highlight(snapshot, language: language)
                }.value
                guard !Task.isCancelled, let self, let textView else { return }
                guard self.highlightRevision == revision,
                      textView.markedTextRange == nil,
                      textView.textStorage.length == utf16Count else { return }
                // Never mutate textStorage while the user is actively dragging or coasting.
                if textView.isDragging || textView.isDecelerating {
                    self.pendingHighlight = (spans: spans, expectedUTF16Length: utf16Count)
                    return
                }
                self.highlightSpans = spans
                self.applyHighlightColors(spans, to: textView, isDark: self.parent.isDark)
            }
        }

        /// Applies only `.foregroundColor` attributes — never `.font` — so TextKit 1
        /// invalidates display without invalidating glyphs, line layout, or `contentSize`.
        private func applyHighlightColors(
            _ spans: [FileEditorSyntax.Span],
            to textView: UITextView,
            isDark: Bool
        ) {
            let storage = textView.textStorage
            let fullLength = storage.length
            let baseColor: UIColor = isDark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.12, alpha: 1)
            let font = UIFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: baseColor,
            ]

            guard fullLength > 0 else { return }
            let fullRange = NSRange(location: 0, length: fullLength)
            let palette = EditorSyntaxPalette(isDark: isDark)

            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: baseColor, range: fullRange)
            for span in spans {
                guard span.location >= 0, span.location + span.length <= fullLength else { continue }
                if let color = palette.color(for: span.token) {
                    storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: span.location, length: span.length))
                }
            }
            storage.endEditing()
            hasAppliedSyntaxColors = !spans.isEmpty
        }

        func configureAccessoryBarIfNeeded(on textView: UITextView) {
            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            guard !KeyboardTracker.shared.isHardwareKeyboard else { return }
            let bar = CodeEditorAccessoryBar(
                onInsert: { [weak textView, weak self] symbol in
                    guard let textView else { return }
                    if symbol == "\t" {
                        self?.insertIndentation(in: textView)
                    } else {
                        textView.insertText(symbol)
                    }
                },
                onUndo: { [weak textView] in textView?.undoManager?.undo() },
                onRedo: { [weak textView] in textView?.undoManager?.redo() },
                onFind: { [weak textView] in textView?.findInteraction?.presentFindNavigator(showingReplace: false) },
                onDismiss: { [weak textView] in textView?.resignFirstResponder() }
            )
            textView.inputAccessoryView = bar
            #endif
        }
    }
}

// MARK: - Syntax Palette

private struct EditorSyntaxPalette {
    let isDark: Bool

    func color(for token: FileEditorSyntax.Token) -> UIColor? {
        switch token {
        case .plain:
            nil
        case .keyword:
            isDark ? UIColor(red: 0.86, green: 0.55, blue: 0.82, alpha: 1)
                   : UIColor(red: 0.61, green: 0.14, blue: 0.58, alpha: 1)
        case .key:
            isDark ? UIColor(red: 0.55, green: 0.74, blue: 0.98, alpha: 1)
                   : UIColor(red: 0.11, green: 0.36, blue: 0.78, alpha: 1)
        case .string:
            isDark ? UIColor(red: 0.93, green: 0.69, blue: 0.45, alpha: 1)
                   : UIColor(red: 0.72, green: 0.30, blue: 0.05, alpha: 1)
        case .comment:
            isDark ? UIColor(white: 0.55, alpha: 1)
                   : UIColor(white: 0.46, alpha: 1)
        case .number:
            isDark ? UIColor(red: 0.50, green: 0.80, blue: 0.93, alpha: 1)
                   : UIColor(red: 0.04, green: 0.44, blue: 0.66, alpha: 1)
        case .variable:
            isDark ? UIColor(red: 0.45, green: 0.82, blue: 0.68, alpha: 1)
                   : UIColor(red: 0.07, green: 0.48, blue: 0.36, alpha: 1)
        case .section:
            isDark ? UIColor(red: 0.74, green: 0.62, blue: 0.96, alpha: 1)
                   : UIColor(red: 0.44, green: 0.22, blue: 0.76, alpha: 1)
        }
    }
}

// MARK: - Custom TextKit 1 UITextView & Container with GPU-Composited Line-Number Gutter

private final class CodeEditorUITextView: UITextView, PanelKeyboardClaiming {
    var onSaveShortcut: (() -> Void)?
    var onCloseShortcut: (() -> Void)?
    var onToggleZoom: (() -> Void)?
    /// Returns true when Escape answered a question the editor was asking.
    var onEscape: (() -> Bool)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?
    var onDidLayoutNonContiguousViewport: (() -> Void)?

    /// Docked beside the terminal, the editor still keeps the keyboard it was given.
    var claimsKeyboard: Bool { true }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { MenuShortcutState.shared.setSaveChordOwner(self, active: true) }
        return became
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { MenuShortcutState.shared.setSaveChordOwner(self, active: false) }
        return resigned
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only notify in noncontiguous mode (>1M chars) so normal pre-laid-out scrolling
        // does zero extra work inside layoutSubviews().
        if layoutManager.allowsNonContiguousLayout {
            onDidLayoutNonContiguousViewport?()
        }
    }

    // The menu rail dispatches its key equivalents before any responder UIKeyCommand,
    // and its items send to the first responder. While the editor is focused, Find,
    // Close and Toggle Split Zoom act on the editor; the menu gives up ⌘S instead
    // (MenuShortcutState.setSaveChordOwner), so a clicked menu item keeps its action.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(findInTerminal(_:)) { return isFindInteractionEnabled }
        if action == #selector(closeSplit(_:)) { return onCloseShortcut != nil }
        if action == #selector(menuToggleSplitZoom(_:)) { return onToggleZoom != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func findInTerminal(_ sender: Any?) {
        findInteraction?.presentFindNavigator(showingReplace: false)
    }

    @objc func closeSplit(_ sender: Any?) {
        onCloseShortcut?()
    }

    @objc func menuToggleSplitZoom(_ sender: Any?) {
        onToggleZoom?()
    }

    /// Without a menu rail (or with no menu item on these chords) they arrive here.
    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(UIKeyCommand(input: MenuShortcutState.saveChordInput,
                                     modifierFlags: MenuShortcutState.saveChordModifiers,
                                     action: #selector(handleSaveKey)))
        commands.append(UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleOutdentKey)))
        // Close goes ahead of the system's Close Window on the same chord.
        if onCloseShortcut != nil,
           let command = Self.keyCommand(for: .close_tab, selector: #selector(closeSplit(_:)), wantsPriority: true) {
            commands.append(command)
        }
        if onToggleZoom != nil,
           let command = Self.keyCommand(for: .toggle_split_zoom, selector: #selector(menuToggleSplitZoom(_:))) {
            commands.append(command)
        }
        // The panel HUD closes on Escape; a reflexive Escape while typing shouldn't.
        // Composition keeps Escape so the input method can cancel it.
        if markedTextRange == nil {
            commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscapeKey)))
        }
        return commands
    }

    /// The user's binding for `action`, unless it was remapped onto Save's chord, which the editor keeps.
    private static func keyCommand(for action: KeybindAction, selector: Selector, wantsPriority: Bool = false) -> UIKeyCommand? {
        guard let command = KeybindManager.shared.keyCommand(for: action, selector: selector, wantsPriority: wantsPriority),
              let input = command.input,
              !MenuShortcutState.isSaveChord(input: input, modifiers: command.modifierFlags) else { return nil }
        return command
    }

    @objc private func handleEscapeKey() {
        _ = onEscape?()
    }

    @objc private func handleSaveKey() {
        onSaveShortcut?()
    }

    @objc private func handleOutdentKey() {
        onOutdent?()
    }
}

private final class CodeEditorContainerView: UIView, NSLayoutManagerDelegate {
    /// Files up to 1M UTF-16 code units pre-layout contiguously so `contentSize` stays 100%
    /// static during scrolling — eliminating scrollbar jutter and momentum interruptions.
    private static let maxContiguousLayoutUTF16Length = 1_000_000

    let textView: CodeEditorUITextView
    private let gutterView = LineNumberGutterView()
    private let separatorView = UIView()

    private var showsGutter = true
    private var wrapLines = true
    private var currentFontSize: CGFloat = 13
    private var lineIndex = EditorLineIndex()

    private var needsFullLayout = false
    private var lastLaidOutTextWidth: CGFloat = 0
    private var gutterLayoutRefreshScheduled = false

    private var cachedDigitFontSize: CGFloat = 0
    private var cachedDigitWidth: CGFloat = 8
    private var cachedGutterDigits = 2
    private var cachedGutterWidth: CGFloat = 0

    override init(frame: CGRect) {
        // TextKit 1 with contiguous pre-layout keeps contentSize completely static during
        // trackpad and touch scrolling (TextKit 2 viewport height estimation causes scrollbar
        // jutter and disrupts momentum coasting).
        textView = CodeEditorUITextView(usingTextLayoutManager: false)
        super.init(frame: frame)

        isOpaque = true
        textView.isOpaque = true
        textView.layoutManager.allowsNonContiguousLayout = false
        textView.layoutManager.delegate = self
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        textView.keyboardDismissMode = KeyboardTracker.shared.isHardwareKeyboard ? .none : .interactive
        #endif
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 24, right: 10)
        textView.textContainer.lineFragmentPadding = 4
        textView.onDidLayoutNonContiguousViewport = { [weak self] in
            self?.syncGutterAfterNonContiguousViewportLayout()
        }

        gutterView.textView = textView
        gutterView.isUserInteractionEnabled = false
        separatorView.isUserInteractionEnabled = false

        addSubview(gutterView)
        addSubview(separatorView)
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Route touch pan and trackpad/scroll-wheel gestures over the gutter straight to textView.
        if showsGutter && !gutterView.isHidden && gutterView.frame.contains(point) {
            return textView
        }
        return super.hitTest(point, with: event)
    }

    func applyLayout(
        wrapLines: Bool,
        showLineNumbers: Bool,
        fontSize: CGFloat,
        isDark: Bool,
        backgroundColor: UIColor
    ) {
        let wrapChanged = self.wrapLines != wrapLines
        self.wrapLines = wrapLines
        self.showsGutter = showLineNumbers
        self.currentFontSize = fontSize

        applyTheme(isDark: isDark, fontSize: fontSize, backgroundColor: backgroundColor)

        textView.textContainer.widthTracksTextView = wrapLines
        textView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        textView.showsHorizontalScrollIndicator = !wrapLines
        textView.alwaysBounceHorizontal = false
        if wrapLines {
            if textView.bounds.width > 0 {
                let containerWidth = max(40, textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right)
                textView.textContainer.size = CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
            if wrapChanged && textView.contentOffset.x != -textView.adjustedContentInset.left {
                textView.setContentOffset(
                    CGPoint(x: -textView.adjustedContentInset.left, y: textView.contentOffset.y),
                    animated: false
                )
            }
        } else {
            textView.textContainer.size = CGSize(width: CGFloat(1_000_000), height: CGFloat.greatestFiniteMagnitude)
        }

        if wrapChanged {
            needsFullLayout = true
        }

        setNeedsLayout()
    }

    func applyTheme(isDark: Bool, fontSize: CGFloat, backgroundColor: UIColor) {
        currentFontSize = fontSize
        overrideUserInterfaceStyle = isDark ? .dark : .light
        self.backgroundColor = backgroundColor
        textView.backgroundColor = backgroundColor
        textView.keyboardAppearance = isDark ? .dark : .light

        gutterView.applyTheme(isDark: isDark, editorFontSize: fontSize, backgroundColor: backgroundColor)
        separatorView.backgroundColor = Self.blendedOpaqueColor(
            overlay: isDark ? UIColor.white : UIColor.black,
            alpha: isDark ? 0.09 : 0.08,
            over: backgroundColor
        )
        separatorView.isOpaque = true
    }

    func markNeedsFullLayout() {
        needsFullLayout = true
        setNeedsLayout()
    }

    func updateLineIndex(_ index: EditorLineIndex, activeLine: Int, needsFullLayout: Bool) {
        lineIndex = index
        gutterView.setActiveLine(activeLine)

        let shouldUseNonContiguous = textView.textStorage.length > Self.maxContiguousLayoutUTF16Length
        let crossedThreshold = textView.layoutManager.allowsNonContiguousLayout != shouldUseNonContiguous
        if crossedThreshold {
            textView.layoutManager.allowsNonContiguousLayout = shouldUseNonContiguous
        }

        if needsFullLayout || (crossedThreshold && !shouldUseNonContiguous) {
            self.needsFullLayout = true
            setNeedsLayout()
        }
        guard showsGutter else { return }
        let desired = computeGutterWidth()
        if abs(gutterView.frame.width - desired) > 0.5 {
            setNeedsLayout()
        }
        if !self.needsFullLayout {
            gutterView.updateVisibleLines(lineIndex: lineIndex)
        }
    }

    func updateActiveLine(_ line: Int) {
        gutterView.setActiveLine(line)
    }

    func syncGutterForScroll() {
        guard showsGutter else { return }
        // During active drag/coasting, never request layout; for an instant programmatic jump
        // (such as Find & Replace) in noncontiguous mode, allow visible-rect layout immediately.
        let allowLayout = textView.layoutManager.allowsNonContiguousLayout
            && !textView.isDragging
            && !textView.isDecelerating
        gutterView.syncScroll(contentOffsetY: textView.contentOffset.y, lineIndex: lineIndex, allowLayout: allowLayout)
    }

    private func syncGutterAfterNonContiguousViewportLayout() {
        guard showsGutter, textView.layoutManager.allowsNonContiguousLayout else { return }
        gutterView.syncScroll(contentOffsetY: textView.contentOffset.y, lineIndex: lineIndex, allowLayout: false)
    }

    func refreshVisibleGutterLines(allowLayout: Bool = false) {
        guard showsGutter else { return }
        gutterView.updateVisibleLines(lineIndex: lineIndex, allowLayout: allowLayout)
    }

    func refreshGutterAfterScrollEnded() {
        guard showsGutter, textView.layoutManager.allowsNonContiguousLayout else { return }
        gutterView.updateVisibleLines(lineIndex: lineIndex, allowLayout: true)
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        didCompleteLayoutFor textContainer: NSTextContainer?,
        atEnd layoutFinishedFlag: Bool
    ) {
        guard showsGutter, layoutManager.allowsNonContiguousLayout, !gutterLayoutRefreshScheduled else { return }
        gutterLayoutRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gutterLayoutRefreshScheduled = false
            self.refreshVisibleGutterLines(allowLayout: false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutterWidth = showsGutter ? computeGutterWidth() : 0
        gutterView.isHidden = !showsGutter
        separatorView.isHidden = !showsGutter

        let gutterFrame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        if gutterView.frame != gutterFrame {
            gutterView.frame = gutterFrame
        }
        let separatorFrame = CGRect(x: gutterWidth, y: 0, width: showsGutter ? 0.5 : 0, height: bounds.height)
        if separatorView.frame != separatorFrame {
            separatorView.frame = separatorFrame
        }
        let textX = showsGutter ? gutterWidth + 0.5 : 0
        let textFrame = CGRect(x: textX, y: 0, width: max(0, bounds.width - textX), height: bounds.height)
        let widthChanged = abs(textView.frame.width - textFrame.width) > 0.5
        if textView.frame != textFrame {
            textView.frame = textFrame
        }

        let shouldPreLayout = textView.bounds.width > 0
            && (needsFullLayout || (wrapLines && widthChanged && abs(lastLaidOutTextWidth - textView.bounds.width) > 0.5))
        if shouldPreLayout {
            needsFullLayout = false
            lastLaidOutTextWidth = textView.bounds.width
            if wrapLines {
                let containerWidth = max(40, textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right)
                if abs(textView.textContainer.size.width - containerWidth) > 0.5 {
                    textView.textContainer.size = CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
                }
            }
            let useNonContiguous = textView.textStorage.length > Self.maxContiguousLayoutUTF16Length
            textView.layoutManager.allowsNonContiguousLayout = useNonContiguous
            if !useNonContiguous {
                textView.layoutManager.ensureLayout(for: textView.textContainer)
                textView.layoutIfNeeded()
            }
        }

        if showsGutter {
            gutterView.syncScroll(contentOffsetY: textView.contentOffset.y, lineIndex: lineIndex)
        }
    }

    private func computeGutterWidth() -> CGFloat {
        let digits = max(2, Self.digitCount(of: lineIndex.lineCount))
        let gutterFontSize = max(10, currentFontSize - 1)
        if cachedDigitFontSize != gutterFontSize {
            let font = UIFont.monospacedDigitSystemFont(ofSize: gutterFontSize, weight: .regular)
            cachedDigitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
            cachedDigitFontSize = gutterFontSize
            cachedGutterWidth = 0
        }
        if cachedGutterDigits != digits || cachedGutterWidth == 0 {
            cachedGutterDigits = digits
            cachedGutterWidth = ceil(CGFloat(digits) * cachedDigitWidth + 16)
        }
        return cachedGutterWidth
    }

    private static func digitCount(of value: Int) -> Int {
        var n = max(1, value)
        var count = 0
        while n > 0 {
            n /= 10
            count += 1
        }
        return count
    }

    static func blendedOpaqueColor(overlay: UIColor, alpha: CGFloat, over base: UIColor) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 1
        var or_: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 1
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        overlay.getRed(&or_, green: &og, blue: &ob, alpha: &oa)
        let inv = 1 - alpha
        return UIColor(
            red: br * inv + or_ * alpha,
            green: bg * inv + og * alpha,
            blue: bb * inv + ob * alpha,
            alpha: 1
        )
    }
}

/// Hardware-composited line-number gutter backed by a pool of recycled `CATextLayer`s.
/// During scrolling, `contentLayer.bounds.origin.y` shifts in lockstep with `textView.contentOffset.y`
/// in the same Core Animation transaction — zero `draw(_:)` rasterization, zero layout calls,
/// and zero full-text scans.
private final class LineNumberGutterView: UIView {
    weak var textView: UITextView?

    private let contentLayer = CALayer()
    private var activeLayers: [Int: CATextLayer] = [:]
    private var reusePool: [CATextLayer] = []
    private var seenLines: Set<Int> = []
    private var linesToRemove: [Int] = []

    private var isDark = true
    private var fontSize: CGFloat = 12
    private var activeLine = 1
    private var gutterFont: UIFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private var gutterLineHeight: CGFloat = 15
    private var editorLineHeight: CGFloat = 16
    private var normalColor: CGColor = UIColor(white: 0.48, alpha: 1).cgColor
    private var activeColor: CGColor = UIColor(white: 0.88, alpha: 1).cgColor
    private var lastContentOffsetY: CGFloat = .nan
    private var lastWidth: CGFloat = 0

    private static let disabledActions: [String: CAAction] = [
        "bounds": NSNull(),
        "position": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "foregroundColor": NSNull(),
        "string": NSNull(),
        "fontSize": NSNull(),
        "hidden": NSNull(),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isOpaque = true
        contentLayer.actions = Self.disabledActions
        layer.addSublayer(contentLayer)

        registerForTraitChanges([UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateContentsScale()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var currentDisplayScale: CGFloat {
        let scale = traitCollection.displayScale
        return scale > 0 ? scale : 2
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = currentDisplayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in activeLayers.values {
            layer.contentsScale = scale
        }
        for layer in reusePool {
            layer.contentsScale = scale
        }
        CATransaction.commit()
    }

    func applyTheme(isDark: Bool, editorFontSize: CGFloat, backgroundColor: UIColor) {
        self.isDark = isDark
        let newFontSize = max(10, editorFontSize - 1)
        let fontChanged = newFontSize != fontSize
        fontSize = newFontSize
        gutterFont = .monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        gutterLineHeight = gutterFont.lineHeight
        editorLineHeight = UIFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular).lineHeight
        normalColor = (isDark ? UIColor(white: 0.48, alpha: 1) : UIColor(white: 0.52, alpha: 1)).cgColor
        activeColor = (isDark ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.15, alpha: 1)).cgColor
        self.backgroundColor = CodeEditorContainerView.blendedOpaqueColor(
            overlay: isDark ? UIColor.white : UIColor.black,
            alpha: isDark ? 0.03 : 0.025,
            over: backgroundColor
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let labelHeight = ceil(gutterLineHeight)
        for (line, layer) in activeLayers {
            if fontChanged {
                layer.font = gutterFont
                layer.fontSize = fontSize
                var f = layer.frame
                f.size.height = labelHeight
                layer.frame = f
            }
            layer.foregroundColor = (line == activeLine) ? activeColor : normalColor
        }
        if fontChanged {
            for layer in reusePool {
                layer.font = gutterFont
                layer.fontSize = fontSize
            }
        }
        CATransaction.commit()
    }

    func setActiveLine(_ newLine: Int) {
        guard newLine != activeLine else { return }
        let oldLine = activeLine
        activeLine = newLine
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        activeLayers[oldLine]?.foregroundColor = normalColor
        activeLayers[newLine]?.foregroundColor = activeColor
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let offsetY = textView?.contentOffset.y ?? 0
        lastContentOffsetY = offsetY
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        contentLayer.bounds = CGRect(x: 0, y: offsetY, width: bounds.width, height: bounds.height)
        if abs(bounds.width - lastWidth) > 0.5 {
            lastWidth = bounds.width
            let labelWidth = max(0, bounds.width - 10)
            for layer in activeLayers.values {
                var f = layer.frame
                f.size.width = labelWidth
                layer.frame = f
            }
        }
        CATransaction.commit()
    }

    func syncScroll(contentOffsetY: CGFloat, lineIndex: EditorLineIndex, allowLayout: Bool = false) {
        if contentOffsetY != lastContentOffsetY {
            lastContentOffsetY = contentOffsetY
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.bounds = CGRect(x: 0, y: contentOffsetY, width: bounds.width, height: bounds.height)
            CATransaction.commit()
        }
        updateVisibleLines(lineIndex: lineIndex, allowLayout: allowLayout)
    }

    func updateVisibleLines(lineIndex: EditorLineIndex, allowLayout: Bool = false) {
        guard !isHidden,
              bounds.width > 0,
              bounds.height > 0,
              let textView else {
            return
        }

        let insetTop = textView.textContainerInset.top
        let offsetY = textView.contentOffset.y
        let scale = currentDisplayScale
        let labelWidth = max(0, bounds.width - 10)
        let labelHeight = ceil(gutterLineHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if offsetY != lastContentOffsetY {
            lastContentOffsetY = offsetY
            contentLayer.bounds = CGRect(x: 0, y: offsetY, width: bounds.width, height: bounds.height)
        }

        seenLines.removeAll(keepingCapacity: true)

        let visibleLines = EditorGutterLayout.visibleLines(
            in: textView,
            lineIndex: lineIndex,
            editorLineHeight: editorLineHeight,
            allowLayout: allowLayout
        )
        for line in visibleLines {
            let rawY = insetTop + line.minY + (line.height - gutterLineHeight) / 2
            let alignedY = round(rawY * scale) / scale
            seenLines.insert(line.lineNumber)
            placeLayer(for: line.lineNumber, y: alignedY, width: labelWidth, height: labelHeight, scale: scale)
        }

        recycleUnseenLayers()
        CATransaction.commit()
    }

    private func placeLayer(for lineNumber: Int, y: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat) {
        let targetFrame = CGRect(x: 4, y: y, width: width, height: height)
        let targetColor = (lineNumber == activeLine) ? activeColor : normalColor

        if let existing = activeLayers[lineNumber] {
            if existing.frame != targetFrame {
                existing.frame = targetFrame
            }
            if existing.foregroundColor != targetColor {
                existing.foregroundColor = targetColor
            }
            return
        }

        let layer: CATextLayer
        if let recycled = reusePool.popLast() {
            layer = recycled
            layer.isHidden = false
        } else {
            layer = CATextLayer()
            layer.actions = Self.disabledActions
            layer.alignmentMode = .right
            layer.truncationMode = .none
            layer.contentsScale = scale
            layer.font = gutterFont
            layer.fontSize = fontSize
            contentLayer.addSublayer(layer)
        }

        layer.string = "\(lineNumber)"
        layer.foregroundColor = targetColor
        layer.frame = targetFrame
        activeLayers[lineNumber] = layer
    }

    private func recycleUnseenLayers() {
        linesToRemove.removeAll(keepingCapacity: true)
        for line in activeLayers.keys where !seenLines.contains(line) {
            linesToRemove.append(line)
        }
        for line in linesToRemove {
            if let layer = activeLayers.removeValue(forKey: line) {
                if reusePool.count < 128 {
                    layer.isHidden = true
                    reusePool.append(layer)
                } else {
                    layer.removeFromSuperlayer()
                }
            }
        }
    }
}

// MARK: - Touch Keyboard Accessory Bar (iOS / iPadOS)

#if !targetEnvironment(macCatalyst) && !os(visionOS)
private final class CodeEditorAccessoryBar: UIInputView {
    private let onInsert: (String) -> Void
    private let onUndo: () -> Void
    private let onRedo: () -> Void
    private let onFind: () -> Void
    private let onDismiss: () -> Void

    init(
        onInsert: @escaping (String) -> Void,
        onUndo: @escaping () -> Void,
        onRedo: @escaping () -> Void,
        onFind: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onInsert = onInsert
        self.onUndo = onUndo
        self.onRedo = onRedo
        self.onFind = onFind
        self.onDismiss = onDismiss
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 42), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let keys: [(title: String, value: String)] = [
            ("⇥", "\t"), ("{", "{"), ("}", "}"), ("[", "["), ("]", "]"),
            ("\"", "\""), ("'", "'"), (":", ":"), ("=", "="), ("#", "#"),
            ("/", "/"), ("-", "-"), ("_", "_"), ("\\", "\\"), ("$", "$"),
        ]
        for key in keys {
            stack.addArrangedSubview(makeKeyButton(title: key.title) { [weak self] in
                self?.onInsert(key.value)
            })
        }

        scroll.addSubview(stack)

        let trailing = UIStackView()
        trailing.axis = .horizontal
        trailing.spacing = 4
        trailing.alignment = .center
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addArrangedSubview(makeIconButton("arrow.uturn.backward") { [weak self] in self?.onUndo() })
        trailing.addArrangedSubview(makeIconButton("arrow.uturn.forward") { [weak self] in self?.onRedo() })
        trailing.addArrangedSubview(makeIconButton("magnifyingglass") { [weak self] in self?.onFind() })
        trailing.addArrangedSubview(makeIconButton("keyboard.chevron.compact.down") { [weak self] in self?.onDismiss() })

        addSubview(scroll)
        addSubview(trailing)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 42),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -6),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor),

            trailing.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeKeyButton(title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.title = title
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            return out
        }
        let button = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
        return button
    }

    private func makeIconButton(_ systemName: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
    }
}
#endif

private extension View {
    /// Selected: an accent fill with a hairline edge, so it reads on any theme.
    func editorTabBackground(selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05), in: shape)
            .overlay(shape.strokeBorder(selected ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1))
    }
}

/// Tab row height: a finger needs more than a pointer.
private func editorTabHeight(_ touchSized: Bool) -> CGFloat {
    touchSized ? 34 : 26
}

/// Save for a side rail; its own view so typing redraws only this item.
struct RemoteFileEditorRailSave: View {
    let document: RemoteFileEditorDocument

    var body: some View {
        Button {
            document.save()
        } label: {
            Label(document.isRemote
                  ? String(localized: "Save and Upload", comment: "File editor save button in a side rail")
                  : String(localized: "Save", comment: "File editor save button"),
                  systemImage: "square.and.arrow.down")
        }
        .labelStyle(.iconOnly)
        .disabled(!document.isDirty || document.saveState == .saving)
    }
}
