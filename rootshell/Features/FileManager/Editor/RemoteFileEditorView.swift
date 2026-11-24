//
//  RemoteFileEditorView.swift
//  rootshell
//
//  In-app code, JSON and config editor for local and remote files.
//  Features syntax highlighting, aligned line numbers, smart indentation,
//  native Find & Replace, JSON formatting, conflict protection, and automatic
//  upload back to SFTP / S3 / local endpoints on save.
//

import SwiftUI
import UIKit

/// Input describing a file to open in the in-app editor.
struct RemoteFileEditorRequest: Identifiable {
    let id = UUID()
    let entry: RFEntry
    let endpoint: FileEndpoint
    let prompts: FileManagerPrompts
    /// Pre-fetched bytes and fingerprint when content sniffing already downloaded the file.
    let preloaded: (data: Data, fingerprint: RemoteFileFingerprint)?
}

// MARK: - SwiftUI Sheet

struct RemoteFileEditorView: View {
    let request: RemoteFileEditorRequest
    let onOpenExternal: (URL?) -> Void
    var onOpenEmbedded: ((FileManagerEmbeddedEditor) -> Void)? = nil
    let onQuickLook: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Setting(Settings.Transfer.fileManagerEditorWrapLines) private var wrapLines
    @Setting(Settings.Transfer.fileManagerEditorShowLineNumbers) private var showLineNumbers

    @State private var text = ""
    @State private var originalText = ""
    @State private var document = EditableTextDocument(text: "", encoding: .utf8, lineEnding: .lf)
    @State private var language: FileEditorSyntax.Language = .plain
    @State private var indentation: EditableTextDocument.Indentation = .spaces(2)
    @State private var fingerprint: RemoteFileFingerprint?
    @State private var loadState: LoadState = .loading
    @State private var saveState: SaveState = .idle
    @State private var cursorPosition = CursorPosition(line: 1, column: 1)
    @State private var fontSize: CGFloat = 13
    @State private var findTrigger = 0
    @State private var inlineBanner: String?

    @State private var confirmsDiscard = false
    @State private var confirmsReload = false
    @State private var activeConflict: ConflictReason?
    @State private var pendingHandoff: PendingHandoff?
    @State private var confirmsSaveBeforeHandoff = false

    private enum PendingHandoff {
        case external(URL?)
        case embedded(FileManagerEmbeddedEditor)
        case quickLook
    }

    private enum ConflictReason {
        case modified
        case deleted
    }

    #if targetEnvironment(macCatalyst)
    @State private var externalApps: [ExternalEditorBridge.ExternalApp] = []
    #endif

    private enum LoadState: Equatable {
        case loading
        case ready
        case binary
        case failed(String)
    }

    private enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    struct CursorPosition: Equatable {
        var line: Int
        var column: Int
    }

    private var isDirty: Bool {
        loadState == .ready && text != originalText
    }

    private var isRemote: Bool {
        !request.endpoint.isLocal
    }

    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var editorBackground: Color {
        sheetThemeColors?.background ?? Color(uiColor: .systemBackground)
    }

    private var chromeBackground: Color {
        sheetThemeColors?.rowBackground ?? Color(uiColor: .secondarySystemBackground)
    }

    private var lineCount: Int {
        guard !text.isEmpty else { return 1 }
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let banner = activeBannerMessage {
                    errorBanner(banner)
                    Divider()
                }
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if loadState == .ready {
                    Divider()
                    statusBar
                }
            }
            .background(editorBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDirty
                           ? String(localized: "Close", comment: "File editor close button")
                           : String(localized: "Done", comment: "File editor done button")) {
                        attemptClose()
                    }
                    .keyboardShortcut("w", modifiers: .command)
                }
                ToolbarItem(placement: .principal) {
                    titleView
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if loadState == .ready {
                        statusIndicator
                        Button {
                            findTrigger += 1
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        .help(String(localized: "Find & Replace (⌘F)", comment: "File editor find tooltip"))
                        .accessibilityLabel(String(localized: "Find", comment: "File editor find button"))

                        Button {
                            save(forceOverwrite: false)
                        } label: {
                            Text(isRemote
                                 ? String(localized: "Save", comment: "File editor save and upload button")
                                 : String(localized: "Save", comment: "File editor save button"))
                                .fontWeight(.semibold)
                        }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty || saveState == .saving)
                        .help(isRemote
                              ? String(localized: "Save and Upload (⌘S)", comment: "File editor save tooltip")
                              : String(localized: "Save (⌘S)", comment: "File editor save tooltip"))
                    }
                    moreMenu
                }
            }
        }
        .environment(\.colorScheme, surfaceScheme)
        .presentationSizing(.page)
        .frame(minWidth: 320, idealWidth: 820, minHeight: 420, idealHeight: 620)
        .interactiveDismissDisabled(isDirty || saveState == .saving)
        .confirmationDialog(
            String(localized: "You have unsaved changes to “\(request.entry.name)”.", comment: "File editor unsaved changes title; argument is a file name"),
            isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button(isRemote
                   ? String(localized: "Save & Upload", comment: "File editor save and close button")
                   : String(localized: "Save", comment: "File editor save and close button")) {
                save(forceOverwrite: false, dismissOnSuccess: true)
            }
            Button(String(localized: "Discard Changes", comment: "File editor discard button"), role: .destructive) {
                onDismiss()
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        }
        .confirmationDialog(
            handoffConfirmationTitle,
            isPresented: $confirmsSaveBeforeHandoff,
            titleVisibility: .visible
        ) {
            Button(isRemote
                   ? String(localized: "Save & Continue", comment: "File editor save then continue handoff")
                   : String(localized: "Save & Continue", comment: "File editor save then continue handoff")) {
                let handoff = pendingHandoff
                pendingHandoff = nil
                save(forceOverwrite: false) {
                    onDismiss()
                    performHandoff(handoff)
                }
            }
            Button(String(localized: "Discard Changes", comment: "File editor discard then continue handoff"), role: .destructive) {
                let handoff = pendingHandoff
                pendingHandoff = nil
                onDismiss()
                performHandoff(handoff)
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                pendingHandoff = nil
            }
        }
        .confirmationDialog(
            String(localized: "Reload “\(request.entry.name)”?", comment: "File editor reload confirmation; argument is a file name"),
            isPresented: $confirmsReload,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Discard Changes & Reload", comment: "File editor confirm reload"), role: .destructive) {
                Task { await load(usePreloaded: false) }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
        } message: {
            Text("Your unsaved edits will be replaced with the current file from the server.")
        }
        .alert(
            conflictAlertTitle,
            isPresented: Binding(
                get: { activeConflict != nil },
                set: { if !$0 { activeConflict = nil } }
            )
        ) {
            if activeConflict == .deleted {
                Button(String(localized: "Recreate File", comment: "File editor conflict: recreate deleted remote file"), role: .destructive) {
                    activeConflict = nil
                    save(forceOverwrite: true)
                }
            } else {
                Button(String(localized: "Overwrite Remote", comment: "File editor conflict: overwrite"), role: .destructive) {
                    activeConflict = nil
                    save(forceOverwrite: true)
                }
                Button(String(localized: "Reload Remote", comment: "File editor conflict: reload")) {
                    activeConflict = nil
                    Task { await load(usePreloaded: false) }
                }
            }
            Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                activeConflict = nil
            }
        } message: {
            Text(conflictAlertMessage)
        }
        .task {
            FileConnectionPool.shared.retain(request.endpoint)
            #if targetEnvironment(macCatalyst)
            loadExternalApps()
            #endif
            await load(usePreloaded: true)
        }
        .onDisappear {
            FileConnectionPool.shared.release(request.endpoint)
        }
    }

    // MARK: - Subviews

    private var titleView: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                if isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(String(localized: "Unsaved changes", comment: "File editor dirty indicator"))
                }
                Text(request.entry.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(request.endpoint.displayName):\(FileTransferLogic.parent(of: request.entry.path))")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch saveState {
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

    private var moreMenu: some View {
        Menu {
            #if targetEnvironment(macCatalyst)
            Button {
                requestExternalOpen(appURL: nil)
            } label: {
                Label(String(localized: "Edit in External Editor", comment: "File editor menu"), systemImage: "arrow.up.forward.app")
            }
            if !externalApps.isEmpty {
                Menu {
                    ForEach(externalApps) { app in
                        Button(app.name) {
                            requestExternalOpen(appURL: app.url)
                        }
                    }
                } label: {
                    Label(String(localized: "Open With", comment: "File editor menu: choose macOS app"), systemImage: "square.grid.2x2")
                }
            }
            #else
            if onOpenEmbedded != nil {
                Button {
                    requestEmbeddedOpen(.vim)
                } label: {
                    Label(String(localized: "Edit in Vim", comment: "File editor menu"), systemImage: "terminal")
                }
                Button {
                    requestEmbeddedOpen(.hx)
                } label: {
                    Label(String(localized: "Edit in Helix (hx)", comment: "File editor menu"), systemImage: "terminal")
                }
            }
            Button {
                requestExternalOpen(appURL: nil)
            } label: {
                Label(String(localized: "Edit in External App…", comment: "File editor menu"), systemImage: "arrow.up.forward.app")
            }
            #endif

            Button {
                requestQuickLook()
            } label: {
                Label(String(localized: "Quick Look", comment: "File editor menu"), systemImage: "eye")
            }

            if loadState == .ready {
                Divider()
                if language == .json {
                    Button {
                        formatJSON()
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
                        fontSize = min(24, fontSize + 1)
                    }
                    Button(String(localized: "Smaller Text", comment: "File editor font size")) {
                        fontSize = max(10, fontSize - 1)
                    }
                    Button(String(localized: "Default Size", comment: "File editor font size")) {
                        fontSize = 13
                    }
                } label: {
                    Label(String(localized: "Font Size", comment: "File editor menu"), systemImage: "textformat.size")
                }
                Divider()
                Button {
                    if isDirty { confirmsReload = true } else { Task { await load(usePreloaded: false) } }
                } label: {
                    Label(isRemote
                          ? String(localized: "Reload from Server", comment: "File editor menu")
                          : String(localized: "Reload from Disk", comment: "File editor menu"),
                          systemImage: "arrow.clockwise")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(String(localized: "Editor Options", comment: "File editor overflow menu"))
    }

    private var activeBannerMessage: String? {
        if case .failed(let message) = saveState { return message }
        return inlineBanner
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
            if case .failed = saveState {
                Button(String(localized: "Retry", comment: "Retry button")) {
                    save(forceOverwrite: false)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            Button {
                inlineBanner = nil
                if case .failed = saveState { saveState = .idle }
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
        switch loadState {
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
                        onDismiss()
                        onQuickLook()
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "Open in External App", comment: "File editor binary external fallback")) {
                        onDismiss()
                        onOpenExternal(nil)
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
                    Task { await load(usePreloaded: false) }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            RemoteCodeTextView(
                text: $text,
                language: language,
                indentation: indentation,
                fontSize: fontSize,
                wrapLines: wrapLines,
                showLineNumbers: showLineNumbers,
                isDark: surfaceScheme == .dark,
                findTrigger: findTrigger,
                onCursorChange: { cursorPosition = $0 },
                onSaveShortcut: { if isDirty && saveState != .saving { save(forceOverwrite: false) } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(language.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Ln \(cursorPosition.line), Col \(cursorPosition.column)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text("\(lineCount) \(lineCount == 1 ? String(localized: "line", comment: "Singular line count") : String(localized: "lines", comment: "Plural line count")) · \(FileRowView.sizeText(Int64(text.utf8.count)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(document.encoding.rawValue) · \(document.lineEnding.rawValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(chromeBackground.opacity(0.6))
    }

    // MARK: - Actions

    private func load(usePreloaded: Bool) async {
        loadState = .loading
        saveState = .idle
        inlineBanner = nil
        do {
            let data: Data
            let loadedFingerprint: RemoteFileFingerprint
            if usePreloaded, let preloaded = request.preloaded {
                data = preloaded.data
                loadedFingerprint = preloaded.fingerprint
            } else {
                let fs = try await FileConnectionPool.shared.fileSystem(
                    for: request.endpoint, purpose: .transfer, prompts: request.prompts
                )
                (data, loadedFingerprint) = try await RemoteFileEditCenter.fetchRemoteFile(
                    path: request.entry.path,
                    fs: fs,
                    endpointKey: request.endpoint.recoveryKey,
                    maxBytes: FileEditClassification.maxInAppEditBytes
                )
            }

            guard FileEditClassification.isTextData(data),
                  let decoded = EditableTextDocument.decode(data) else {
                loadState = .binary
                return
            }

            document = decoded
            text = decoded.text
            originalText = decoded.text
            fingerprint = loadedFingerprint
            language = FileEditorSyntax.detectLanguage(
                fileName: request.entry.name,
                contentPrefix: String(decoded.text.prefix(512))
            )
            indentation = EditableTextDocument.detectIndentation(in: decoded.text, filename: request.entry.name)
            loadState = .ready
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func save(
        forceOverwrite: Bool,
        dismissOnSuccess: Bool = false,
        afterSuccess: (() -> Void)? = nil
    ) {
        guard loadState == .ready, saveState != .saving else { return }
        let snapshotText = text
        let encoded = document.encode(snapshotText)
        let expected = fingerprint
        saveState = .saving
        inlineBanner = nil

        Task {
            do {
                let fs = try await FileConnectionPool.shared.fileSystem(
                    for: request.endpoint, purpose: .transfer, prompts: request.prompts
                )
                let updatedFingerprint = try await RemoteFileEditCenter.uploadData(
                    encoded,
                    to: request.entry.path,
                    on: fs,
                    endpointKey: request.endpoint.recoveryKey,
                    expectedFingerprint: expected,
                    forceOverwrite: forceOverwrite
                )
                fingerprint = updatedFingerprint
                originalText = snapshotText
                saveState = .saved
                RemoteFileEditCenter.shared.notifyUploaded(endpoint: request.endpoint, remotePath: request.entry.path)

                // Keep the editor open if the user typed newer changes while the snapshot was uploading.
                if text != snapshotText {
                    inlineBanner = String(
                        localized: "Uploaded earlier changes. Save again to upload your newer edits.",
                        comment: "File editor notice when edits were typed during an in-flight save"
                    )
                } else if let afterSuccess {
                    afterSuccess()
                } else if dismissOnSuccess {
                    onDismiss()
                } else {
                    Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if saveState == .saved { saveState = .idle }
                    }
                }
            } catch RemoteEditError.remoteModified {
                saveState = .idle
                activeConflict = .modified
            } catch RemoteEditError.remoteDeleted {
                saveState = .idle
                activeConflict = .deleted
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private var handoffConfirmationTitle: String {
        switch pendingHandoff {
        case .quickLook:
            String(localized: "Save changes before opening Quick Look?", comment: "File editor Quick Look handoff confirmation")
        case .external, .embedded, .none:
            String(localized: "Save changes before switching editors?", comment: "File editor handoff confirmation")
        }
    }

    private var conflictAlertTitle: String {
        switch activeConflict {
        case .deleted:
            String(localized: "File Deleted on Server", comment: "File editor conflict alert title")
        case .modified, .none:
            String(localized: "File Changed on Server", comment: "File editor conflict alert title")
        }
    }

    private var conflictAlertMessage: String {
        switch activeConflict {
        case .deleted:
            String(localized: "“\(request.entry.name)” was deleted or renamed on \(request.endpoint.displayName) after you opened it. Recreating will write a new file at the original path.", comment: "File editor deleted conflict message")
        case .modified, .none:
            String(localized: "“\(request.entry.name)” was modified on \(request.endpoint.displayName) after you opened it. Overwriting will replace those changes.", comment: "File editor modified conflict message")
        }
    }

    private func attemptClose() {
        if isDirty {
            confirmsDiscard = true
        } else {
            onDismiss()
        }
    }

    private func requestExternalOpen(appURL: URL?) {
        if isDirty {
            pendingHandoff = .external(appURL)
            confirmsSaveBeforeHandoff = true
        } else {
            onDismiss()
            onOpenExternal(appURL)
        }
    }

    private func requestEmbeddedOpen(_ editor: FileManagerEmbeddedEditor) {
        if isDirty {
            pendingHandoff = .embedded(editor)
            confirmsSaveBeforeHandoff = true
        } else {
            onDismiss()
            onOpenEmbedded?(editor)
        }
    }

    private func requestQuickLook() {
        if isDirty {
            pendingHandoff = .quickLook
            confirmsSaveBeforeHandoff = true
        } else {
            onDismiss()
            onQuickLook()
        }
    }

    private func performHandoff(_ handoff: PendingHandoff?) {
        switch handoff {
        case .external(let appURL):
            onOpenExternal(appURL)
        case .embedded(let editor):
            onOpenEmbedded?(editor)
        case .quickLook:
            onQuickLook()
        case .none:
            break
        }
    }

    private func formatJSON() {
        do {
            text = try FileEditJSONFormatter.prettyPrint(text)
            inlineBanner = nil
        } catch {
            inlineBanner = error.localizedDescription
        }
    }

    #if targetEnvironment(macCatalyst)
    private func loadExternalApps() {
        let probeURL = FileManager.default.temporaryDirectory.appendingPathComponent(request.entry.name)
        externalApps = ExternalEditorBridge.availableApps(for: probeURL, includePlainText: true)
    }
    #endif
}

// MARK: - UIKit Code Editor (UITextView + Line-Number Gutter + Syntax Highlighting)

private struct RemoteCodeTextView: UIViewRepresentable {
    @Binding var text: String
    let language: FileEditorSyntax.Language
    let indentation: EditableTextDocument.Indentation
    let fontSize: CGFloat
    let wrapLines: Bool
    let showLineNumbers: Bool
    let isDark: Bool
    let findTrigger: Int
    let onCursorChange: (RemoteFileEditorView.CursorPosition) -> Void
    let onSaveShortcut: () -> Void

    func makeUIView(context: Context) -> CodeEditorContainerView {
        let container = CodeEditorContainerView()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.onSaveShortcut = onSaveShortcut
        textView.onIndent = { [weak textView, weak coordinator = context.coordinator] in
            guard let textView else { return }
            coordinator?.insertIndentation(in: textView)
        }
        textView.onOutdent = { [weak textView, weak coordinator = context.coordinator] in
            guard let textView else { return }
            coordinator?.outdentSelection(in: textView)
        }
        context.coordinator.container = container
        context.coordinator.configureAccessoryBarIfNeeded(on: textView)
        return container
    }

    static func dismantleUIView(_ container: CodeEditorContainerView, coordinator: Coordinator) {
        coordinator.tearDown()
        let textView = container.textView
        textView.delegate = nil
        textView.onSaveShortcut = nil
        textView.onIndent = nil
        textView.onOutdent = nil
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        textView.inputAccessoryView = nil
        #endif
    }

    func updateUIView(_ container: CodeEditorContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let textView = container.textView
        textView.onSaveShortcut = onSaveShortcut

        let styleChanged = coordinator.lastFontSize != fontSize
            || coordinator.lastIsDark != isDark
            || coordinator.lastLanguage != language
        let layoutChanged = coordinator.lastWrapLines != wrapLines
            || coordinator.lastShowLineNumbers != showLineNumbers
            || coordinator.lastFontSize != fontSize

        coordinator.lastFontSize = fontSize
        coordinator.lastIsDark = isDark
        coordinator.lastLanguage = language
        coordinator.lastWrapLines = wrapLines
        coordinator.lastShowLineNumbers = showLineNumbers

        if layoutChanged {
            container.applyLayout(
                wrapLines: wrapLines,
                showLineNumbers: showLineNumbers,
                fontSize: fontSize,
                isDark: isDark
            )
        } else if styleChanged {
            container.applyTheme(isDark: isDark, fontSize: fontSize)
        }

        if textView.text != text && !coordinator.isUpdatingBinding {
            let previousSelection = textView.selectedRange
            coordinator.isApplyingExternalText = true
            textView.text = text
            let clampedLocation = min(previousSelection.location, (text as NSString).length)
            textView.selectedRange = NSRange(location: clampedLocation, length: 0)
            coordinator.isApplyingExternalText = false
            coordinator.scheduleHighlight(immediate: true)
            container.refreshGutter()
        } else if styleChanged {
            coordinator.scheduleHighlight(immediate: true)
            container.refreshGutter()
        }

        if coordinator.lastFindTrigger != findTrigger {
            coordinator.lastFindTrigger = findTrigger
            if findTrigger > 0 {
                textView.findInteraction?.presentFindNavigator(showingReplace: false)
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
        var lastLanguage: FileEditorSyntax.Language?
        var lastWrapLines: Bool?
        var lastShowLineNumbers: Bool?
        var lastFindTrigger = 0

        var isUpdatingBinding = false
        var isApplyingExternalText = false

        private var highlightTask: Task<Void, Never>?
        private var highlightRevision = 0

        init(parent: RemoteCodeTextView) {
            self.parent = parent
        }

        func tearDown() {
            highlightTask?.cancel()
            highlightTask = nil
            container = nil
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            isUpdatingBinding = true
            parent.text = textView.text ?? ""
            isUpdatingBinding = false
            container?.refreshGutter()
            scheduleHighlight(immediate: false)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            container?.refreshGutter()
            let nsText = (textView.text ?? "") as NSString
            let location = min(textView.selectedRange.location, nsText.length)
            let prefix = nsText.substring(to: location)
            var line = 1
            var lastNewlineUTF16 = 0
            var index = 0
            for unit in prefix.utf16 {
                index += 1
                if unit == 0x0A {
                    line += 1
                    lastNewlineUTF16 = index
                }
            }
            let column = (location - lastNewlineUTF16) + 1
            parent.onCursorChange(RemoteFileEditorView.CursorPosition(line: line, column: column))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.refreshGutter()
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            // Skip smart indentation while an IME composition is active.
            guard textView.markedTextRange == nil else { return true }

            if replacement == "\t" {
                insertIndentation(in: textView)
                return false
            }

            if replacement == "\n" {
                let nsText = (textView.text ?? "") as NSString
                let lineRange = nsText.lineRange(for: NSRange(location: range.location, length: 0))
                let linePrefix = nsText.substring(with: NSRange(location: lineRange.location, length: max(0, range.location - lineRange.location)))
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
            let nsText = (textView.text ?? "") as NSString
            let sel = textView.selectedRange
            let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
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
            highlightRevision += 1
            let revision = highlightRevision
            let snapshot = textView.text ?? ""
            let language = parent.language
            let fontSize = parent.fontSize
            let isDark = parent.isDark

            // Apply immediately for small files on initial load; debounce during active typing.
            if immediate && snapshot.utf16.count <= 24_000 {
                let spans = FileEditorSyntax.highlight(snapshot, language: language)
                applyHighlight(spans, to: textView, fontSize: fontSize, isDark: isDark)
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
                      textView.text == snapshot else { return }
                self.applyHighlight(spans, to: textView, fontSize: fontSize, isDark: isDark)
            }
        }

        private func applyHighlight(
            _ spans: [FileEditorSyntax.Span],
            to textView: UITextView,
            fontSize: CGFloat,
            isDark: Bool
        ) {
            let storage = textView.textStorage
            let fullLength = storage.length
            let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
            let baseColor: UIColor = isDark ? UIColor(white: 0.92, alpha: 1) : UIColor(white: 0.12, alpha: 1)

            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: baseColor,
            ]
            textView.typingAttributes = baseAttrs

            guard fullLength > 0 else { return }
            let fullRange = NSRange(location: 0, length: fullLength)
            let palette = EditorSyntaxPalette(isDark: isDark)

            storage.beginEditing()
            storage.addAttributes(baseAttrs, range: fullRange)
            for span in spans {
                guard span.location >= 0, span.location + span.length <= fullLength else { continue }
                let range = NSRange(location: span.location, length: span.length)
                if let color = palette.color(for: span.token) {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
                if span.token == .section {
                    storage.addAttribute(.font, value: boldFont, range: range)
                }
            }
            storage.endEditing()
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

// MARK: - Custom UITextView & Container with Synchronized Line-Number Gutter

private final class CodeEditorUITextView: UITextView {
    var onSaveShortcut: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(handleSaveKey)))
        commands.append(UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(handleOutdentKey)))
        return commands
    }

    @objc private func handleSaveKey() {
        onSaveShortcut?()
    }

    @objc private func handleOutdentKey() {
        onOutdent?()
    }
}

private final class CodeEditorContainerView: UIView {
    let textView: CodeEditorUITextView
    private let gutterView = LineNumberGutterView()
    private let separatorView = UIView()

    private var showsGutter = true
    private var wrapLines = true
    private var currentFontSize: CGFloat = 13

    override init(frame: CGRect) {
        // TextKit 1 keeps line-fragment metrics exact for both wrapped and horizontal-scroll layouts.
        textView = CodeEditorUITextView(usingTextLayoutManager: false)
        super.init(frame: frame)

        textView.backgroundColor = .clear
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.inlinePredictionType = .no
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 24, right: 10)
        textView.textContainer.lineFragmentPadding = 4

        gutterView.textView = textView
        gutterView.isOpaque = false
        gutterView.clipsToBounds = true

        addSubview(gutterView)
        addSubview(separatorView)
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyLayout(wrapLines: Bool, showLineNumbers: Bool, fontSize: CGFloat, isDark: Bool) {
        self.wrapLines = wrapLines
        self.showsGutter = showLineNumbers
        self.currentFontSize = fontSize

        applyTheme(isDark: isDark, fontSize: fontSize)

        textView.textContainer.widthTracksTextView = wrapLines
        textView.textContainer.lineBreakMode = wrapLines ? .byWordWrapping : .byClipping
        textView.showsHorizontalScrollIndicator = !wrapLines
        if !wrapLines {
            textView.textContainer.size = CGSize(width: CGFloat(1_000_000), height: CGFloat.greatestFiniteMagnitude)
        }
        setNeedsLayout()
        layoutIfNeeded()
        refreshGutter()
    }

    func applyTheme(isDark: Bool, fontSize: CGFloat) {
        currentFontSize = fontSize
        textView.keyboardAppearance = isDark ? .dark : .light
        gutterView.isDark = isDark
        gutterView.fontSize = max(10, fontSize - 1)
        gutterView.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.03)
            : UIColor.black.withAlphaComponent(0.025)
        separatorView.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.09)
            : UIColor.black.withAlphaComponent(0.08)
        gutterView.setNeedsDisplay()
    }

    func refreshGutter() {
        guard showsGutter else { return }
        let desired = computeGutterWidth()
        if abs(gutterView.frame.width - desired) > 1 {
            setNeedsLayout()
        }
        gutterView.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gutterWidth = showsGutter ? computeGutterWidth() : 0
        gutterView.isHidden = !showsGutter
        separatorView.isHidden = !showsGutter

        gutterView.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        separatorView.frame = CGRect(x: gutterWidth, y: 0, width: showsGutter ? 0.5 : 0, height: bounds.height)
        let textX = showsGutter ? gutterWidth + 0.5 : 0
        textView.frame = CGRect(x: textX, y: 0, width: max(0, bounds.width - textX), height: bounds.height)

        if wrapLines {
            let containerWidth = max(40, textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right)
            if abs(textView.textContainer.size.width - containerWidth) > 0.5 {
                textView.textContainer.size = CGSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }
        gutterView.setNeedsDisplay()
    }

    private func computeGutterWidth() -> CGFloat {
        let count = max(1, (textView.text ?? "").utf8.reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) })
        let digits = max(2, String(count).count)
        let font = UIFont.monospacedDigitSystemFont(ofSize: max(10, currentFontSize - 1), weight: .regular)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * digitWidth + 16)
    }
}

private final class LineNumberGutterView: UIView {
    weak var textView: UITextView?
    var isDark = true
    var fontSize: CGFloat = 12

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let nsText = (textView.text ?? "") as NSString

        let font = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let normalColor: UIColor = isDark ? UIColor(white: 0.48, alpha: 1) : UIColor(white: 0.52, alpha: 1)
        let activeColor: UIColor = isDark ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 0.15, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        let visibleTextRect = CGRect(
            x: 0,
            y: max(0, textView.contentOffset.y - textView.textContainerInset.top),
            width: textContainer.size.width,
            height: textView.bounds.height + 40
        )
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleTextRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Compute the 1-based line number of the first visible character.
        var lineNumber = 1
        let prefixLimit = min(visibleCharRange.location, nsText.length)
        if prefixLimit > 0 {
            let prefix = nsText.substring(to: prefixLimit)
            for unit in prefix.utf16 where unit == 0x0A { lineNumber += 1 }
        }

        // Current cursor line number for highlighting.
        let cursorLocation = min(textView.selectedRange.location, nsText.length)
        let cursorLineRange = nsText.lineRange(for: NSRange(location: cursorLocation, length: 0))

        let topOffset = textView.textContainerInset.top - textView.contentOffset.y
        var charIndex = visibleCharRange.location

        if nsText.length == 0 {
            let label = "1" as NSString
            let drawRect = CGRect(x: 4, y: topOffset, width: bounds.width - 10, height: font.lineHeight)
            label.draw(in: drawRect, withAttributes: [.font: font, .foregroundColor: activeColor, .paragraphStyle: paragraph])
            return
        }

        while charIndex <= NSMaxRange(visibleCharRange) && charIndex < nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil, withoutAdditionalLayout: true)
            let y = lineRect.minY + topOffset
            if y > bounds.height { break }

            let isActiveLine = lineRange.location == cursorLineRange.location
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isActiveLine ? activeColor : normalColor,
                .paragraphStyle: paragraph,
            ]
            let drawRect = CGRect(x: 4, y: y + (lineRect.height - font.lineHeight) / 2, width: bounds.width - 10, height: font.lineHeight)
            ("\(lineNumber)" as NSString).draw(in: drawRect, withAttributes: attrs)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }

        // Trailing empty line after a final newline.
        if nsText.length > 0, nsText.character(at: nsText.length - 1) == 0x0A, charIndex == nsText.length {
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0 {
                let y = extraRect.minY + topOffset
                if y <= bounds.height {
                    let isActiveLine = cursorLocation == nsText.length
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: isActiveLine ? activeColor : normalColor,
                        .paragraphStyle: paragraph,
                    ]
                    let drawRect = CGRect(x: 4, y: y + (extraRect.height - font.lineHeight) / 2, width: bounds.width - 10, height: font.lineHeight)
                    ("\(lineNumber)" as NSString).draw(in: drawRect, withAttributes: attrs)
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
