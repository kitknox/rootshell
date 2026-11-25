//
//  FileManagerModel.swift
//  rootshell
//
//  Per-window file manager state: two panes, focus, sheets, and the actions
//  that turn selections into transfer jobs. Owned by MainView and kept alive
//  while the UI is hidden, so reopening lands exactly where the user left.
//

import Foundation

@MainActor
@Observable
final class FileManagerModel {
    enum Sheet: Identifiable {
        case connect(FilePaneModel.Side)
        case goToPath
        case rename(RFEntry)
        case newFolder
        case info(RFEntry)
        case edit(RemoteFileEditorRequest)
        case shareLink(RFEntry)
        case incompleteUploads(RFEntry)
        case confirmDelete([RFEntry])
        case shortcuts

        var id: String {
            switch self {
            case .connect(let side): "connect-\(side.rawValue)"
            case .goToPath: "goto"
            case .rename(let entry): "rename-\(entry.path)"
            case .newFolder: "newFolder"
            case .info(let entry): "info-\(entry.path)"
            case .edit(let request): "edit-\(request.id.uuidString)"
            case .shareLink(let entry): "share-\(entry.path)"
            case .incompleteUploads(let entry): "uploads-\(entry.path)"
            case .confirmDelete: "delete"
            case .shortcuts: "shortcuts"
            }
        }
    }

    let prompts = FileManagerPrompts()
    let left: FilePaneModel
    let right: FilePaneModel

    var activeSide: FilePaneModel.Side = .left {
        didSet { if activeSide != oldValue { queueFocused = false } }
    }
    var queueFocused = false
    var queueCursor: UUID?
    var isQueueExpanded = false
    var sheet: Sheet?
    /// Bumped to move keyboard focus into the active pane's field.
    var focusRequestID = 0
    /// Quick Look request; the view presents it.
    var previewRequest: PreviewRequest?
    /// iOS / iPadOS external-editor export picker request (`asCopy: false` move + watch).
    var externalExportRequest: ExternalExportRequest?
    /// Queued export requests waiting behind an already-presented document picker so
    /// overlapping opens never displace a request and leak its open token.
    @ObservationIgnored private var pendingExternalExports: [ExternalExportRequest] = []
    /// Transition task waiting for UIKit to dismiss one export picker before presenting the next.
    /// Requests stay in `pendingExternalExports` during the delay so teardown always sees and releases them.
    @ObservationIgnored private var externalExportAdvanceTask: Task<Void, Never>?
    /// In-flight remote download/staging tasks keyed by `openToken`, cancelled on teardown.
    @ObservationIgnored private var inFlightExternalOpenTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isTornDown = false
    /// System share / Open-In sheet request for local or already-exported files.
    var activityShareRequest: ActivityShareRequest?
    #if targetEnvironment(macCatalyst)
    /// macOS app picker request ("Choose App…").
    var externalAppPickerRequest: ExternalAppPickerRequest?
    #endif
    var errorMessage: String?

    struct PreviewRequest: Identifiable {
        let id = UUID()
        let url: URL
    }

    struct ExternalExportRequest: Identifiable {
        let id = UUID()
        let entry: RFEntry
        let endpoint: FileEndpoint
        let stagedURL: URL
        let hash: Data
        let fingerprint: RemoteFileFingerprint
        let principal: EditPrincipal
        let prompts: FileManagerPrompts
        let openToken: UUID
    }

    struct ActivityShareRequest: Identifiable {
        let id = UUID()
        let urls: [URL]

        init(url: URL) { self.urls = [url] }
        init(urls: [URL]) { self.urls = urls }
    }

    #if targetEnvironment(macCatalyst)
    enum ExternalAppPickerRequest: Identifiable {
        case openFile(RFEntry, FileEndpoint)
        case setDefault

        var id: String {
            switch self {
            case .openFile(let entry, let endpoint): "open-\(endpoint.hashValue)-\(entry.path)"
            case .setDefault: "setDefault"
            }
        }
    }
    #endif

    /// Opens a pane directory in a terminal; wired by MainView.
    @ObservationIgnored var openInTerminal: ((FileEndpoint, String) -> Bool)?
    /// Opens a local or staged file path in a bundled terminal editor (`vim` / `hx`); wired by MainView on iOS/iPadOS/visionOS.
    @ObservationIgnored var openInEmbeddedEditor: ((String, FileManagerEmbeddedEditor) -> Bool)?
    /// The in-flight pane-to-pane drag, read by the drop target.
    @ObservationIgnored var dragPayload: DragPayload?
    /// The terminal pane the manager was last opened from, offered in the location picker.
    private(set) var originPane: FileEndpoint.PaneSource?

    @ObservationIgnored private var finishedObserver: Task<Void, Never>?
    @ObservationIgnored private var uploadedObserver: Task<Void, Never>?

    init() {
        left = FilePaneModel(side: .left, prompts: prompts)
        right = FilePaneModel(side: .right, prompts: prompts)
        RemoteFileEditCenter.shared.registerLivePrompts(prompts)
        restore()
        finishedObserver = Task { [weak self] in
            for await job in FileTransferCenter.shared.finishedJobs() {
                self?.refreshPanes(affectedBy: job)
            }
        }
        uploadedObserver = Task { [weak self] in
            for await (endpoint, path) in RemoteFileEditCenter.shared.uploadedFiles() {
                self?.refreshPanes(affectedByEndpoint: endpoint, path: path)
            }
        }
    }

    func pane(_ side: FilePaneModel.Side) -> FilePaneModel {
        side == .left ? left : right
    }

    func pane(matching endpoint: FileEndpoint) -> FilePaneModel? {
        [activePane, otherPane].first { $0.endpoint == endpoint }
            ?? [activePane, otherPane].first { $0.endpoint.sharesFileSystem(with: endpoint) }
    }

    var activePane: FilePaneModel { pane(activeSide) }
    var otherPane: FilePaneModel { pane(activeSide.other) }

    /// Moves the keyboard into the active pane's filter field. Only with a hardware
    /// keyboard: without one, focusing would raise the on-screen keyboard and
    /// cover much of the listing, so touch users tap the field when they want it.
    func requestFocus() {
        guard KeyboardTracker.shared.isHardwareKeyboard else { return }
        focusRequestID += 1
    }

    // MARK: - Opening

    /// Brings the focused terminal's host into view. A pane already showing that
    /// host keeps its folder (state survives reopening); otherwise the host opens
    /// on the right at the terminal's working directory, local stays on the left.
    func present(from source: FileEndpoint.PaneSource?, directory: String?) {
        guard let source else { return }
        originPane = source
        let endpoint: FileEndpoint = source.fallbackConfig.underlyingSSHConfig == nil ? .local : .pane(source)
        if let existing = [left, right].first(where: { $0.endpoint.sharesFileSystem(with: endpoint) }) {
            activeSide = existing.id
            return
        }
        let side: FilePaneModel.Side = endpoint.isLocal ? .left : .right
        pane(side).connect(to: endpoint, path: directory)
        activeSide = side
    }


    /// Switches `pane` between its host as the login user and as root, keeping
    /// the folder. Leaving drops the root session unless something still uses it.
    func setSudo(_ enabled: Bool, on pane: FilePaneModel) {
        let base = pane.endpoint.withoutSudo
        let sudo = FileEndpoint.sudo(base)
        guard enabled ? pane.endpoint.canUseSudo : pane.endpoint.isSudo else { return }
        let directory = pane.path.isEmpty ? nil : pane.path
        pane.connect(to: enabled ? sudo : base, path: directory)
        // Transfers don't retain pool connections, so check them separately.
        guard !enabled,
              !FileTransferCenter.shared.activeJobs.contains(where: { $0.source == sudo || $0.destination == sudo })
        else { return }
        FileConnectionPool.shared.disconnectIfUnretained(sudo)
    }

    // MARK: - Commands

    func perform(_ command: FileManagerCommand) {
        let pane = activePane
        switch command {
        case .moveCursor, .extendSelection, .open, .close:
            break
        case .toggleSelection:
            pane.selection.toggleCursor()
        case .selectAll:
            pane.selection.selectAll(pane.visibleRowIDs)
        case .openInTerminal:
            openActiveInTerminal()
        case .parent:
            pane.goUp()
        case .back:
            pane.goBack()
        case .forward:
            pane.goForward()
        case .switchPane:
            activeSide = activeSide.other
            requestFocus()
        case .goToPath:
            sheet = .goToPath
        case .connect:
            sheet = .connect(activeSide)
        case .refresh:
            pane.refresh()
        case .toggleHidden:
            let show = !pane.showHidden
            left.showHidden = show
            right.showHidden = show
            SettingsStore.shared.set(Settings.Transfer.fileManagerShowHidden, show)
        case .edit:
            if let entry = pane.cursorEntry, !entry.isDirectory { editInApp(entry, in: pane) }
        case .editExternal:
            if let entry = pane.cursorEntry, !entry.isDirectory { editExternally(entry, in: pane) }
        case .quickLook:
            if let entry = pane.cursorEntry, !entry.isDirectory { preview(entry, in: pane) }
        case .copyToOther:
            transferToOther(move: false)
        case .moveToOther:
            transferToOther(move: true)
        case .paste:
            pasteFromClipboard(into: activeSide, directory: nil)
        case .rename:
            if let entry = pane.cursorEntry { sheet = .rename(entry) }
        case .newFolder:
            sheet = .newFolder
        case .delete:
            if queueFocused {
                FileTransferCenter.shared.cancelAll()
            } else {
                let entries = pane.actionEntries
                if !entries.isEmpty { sheet = .confirmDelete(entries) }
            }
        case .info:
            if let entry = pane.cursorEntry { sheet = .info(entry) }
        case .focusQueue:
            queueFocused.toggle()
            if queueFocused {
                isQueueExpanded = true
                queueCursor = queueCursor ?? FileTransferCenter.shared.jobs.last?.id
            }
        case .cancelJob:
            let center = FileTransferCenter.shared
            if let id = queueCursor, let job = center.jobs.first(where: { $0.id == id }) {
                job.state.isFinished ? center.remove(job) : center.cancel(job)
            }
        case .cancelAllJobs:
            FileTransferCenter.shared.cancelAll()
        case .showShortcuts:
            sheet = .shortcuts
        }
    }

    /// Enter on the cursor row: a folder navigates in, an editable file opens in the editor,
    /// and binary or oversized files open in Quick Look.
    func openCursor() {
        let pane = activePane
        guard let entry = pane.cursorEntry else { return }
        if !pane.open(entry) { open(entry, in: pane) }
    }

    func moveQueueCursor(by delta: Int) {
        let ids = FileTransferCenter.shared.jobs.map(\.id)
        guard !ids.isEmpty else { return }
        let current = queueCursor.flatMap(ids.firstIndex(of:)) ?? (delta > 0 ? -1 : ids.count)
        queueCursor = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    // MARK: - File operations

    func transferToOther(move: Bool, entries: [RFEntry]? = nil, from side: FilePaneModel.Side? = nil) {
        let source = pane(side ?? activeSide)
        let destination = pane((side ?? activeSide).other)
        let items = entries ?? source.actionEntries
        guard !items.isEmpty, !destination.path.isEmpty else { return }
        enqueue(TransferJob(
            operation: move ? .move : .copy,
            source: source.endpoint,
            sources: items.map { TransferJob.Source(path: $0.path, isDirectory: $0.isDirectory) },
            destination: destination.endpoint,
            destinationDirectory: destination.path
        ))
        source.selection.clear()
    }

    /// Drops onto a pane: items from the other pane, or local files dragged in.
    /// `destination` pins the endpoint read before an async staging step.
    func receive(paths: [String], from endpoint: FileEndpoint, into side: FilePaneModel.Side, directory: String? = nil, destination: FileEndpoint? = nil, move: Bool = false) {
        receive(
            sources: paths.map { TransferJob.Source(path: $0) },
            from: endpoint,
            into: side,
            directory: directory,
            destination: destination,
            move: move
        )
    }

    func receive(sources: [TransferJob.Source], from endpoint: FileEndpoint, into side: FilePaneModel.Side, directory: String? = nil, destination: FileEndpoint? = nil, move: Bool = false) {
        let pane = pane(side)
        guard let directory = directory ?? (pane.path.isEmpty ? nil : pane.path) else { return }
        enqueue(TransferJob(
            operation: move ? .move : .copy,
            source: endpoint,
            sources: sources,
            destination: destination ?? pane.endpoint,
            destinationDirectory: directory
        ))
    }

    func delete(_ entries: [RFEntry]) {
        let pane = activePane
        enqueue(TransferJob(
            operation: .delete,
            source: pane.endpoint,
            sources: entries.map { TransferJob.Source(path: $0.path, isDirectory: $0.isDirectory) }
        ))
        pane.selection.clear()
    }

    func setPermissions(_ mode: UInt32, for entries: [RFEntry]) {
        enqueue(TransferJob(
            operation: .setPermissions(mode),
            source: activePane.endpoint,
            sources: entries.map { TransferJob.Source(path: $0.path, isDirectory: $0.isDirectory) }
        ))
    }

    func rename(_ entry: RFEntry, to newName: String) async {
        let pane = activePane
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.utf8.elementsEqual(entry.name.utf8), !trimmed.utf8.contains(UInt8(ascii: "/")) else { return }
        let target = FileTransferLogic.join(FileTransferLogic.parent(of: entry.path), trimmed)
        await run(in: pane, focus: FileEntryID(path: target, isDirectory: entry.isDirectory)) { fs in
            if !entry.isSymlink, !fs.foldersAreImplicit {
                let current = try await fs.info(entry.path, followLinks: false)
                if !current.isSymlink, current.isDirectory != entry.isDirectory {
                    throw FileTransferLogic.ItemTypeChanged(name: entry.name)
                }
            }
            let targetTypeHint: Bool? = fs.foldersAreImplicit ? entry.isDirectory : nil
            if try await fs.infoIfExists(target, followLinks: false, isDirectory: targetTypeHint) != nil {
                throw FileManagerActionError.alreadyExists(trimmed)
            }
            try await fs.rename(entry.path, to: target, isDirectory: entry.isDirectory)
        }
    }

    func createFolder(named name: String) async {
        let pane = activePane
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.utf8.contains(UInt8(ascii: "/")), !pane.path.isEmpty else { return }
        let target = FileTransferLogic.join(pane.path, trimmed)
        await run(in: pane, focus: FileEntryID(path: target, isDirectory: true)) { fs in
            if let s3 = fs.s3, s3.bucketName(of: target) != nil {
                try await s3.createBucket(trimmed)
            } else {
                try await fs.makeDirectory(target)
            }
        }
    }

    /// At a storage provider's top level, New Folder creates a bucket.
    var createsBucket: Bool {
        activePane.endpoint.storageProvider != nil && FileTransferLogic.normalize(activePane.path) == "/"
    }

    /// Runs a quick metadata operation inline, then refreshes with the cursor on `focus`.
    private func run(in pane: FilePaneModel, focus: FileEntryID?, _ body: (FileSystemEndpoint) async throws -> Void) async {
        do {
            try await body(try await pane.fileSystem())
            pane.refresh(focus: focus)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func enqueue(_ job: TransferJob) {
        FileTransferCenter.shared.enqueue(job, prompts: prompts)
    }

    // MARK: - Open, edit, preview and terminal

    /// Default action for opening a file: editable text/config/code files open in the editor
    /// (sniffing extensionless files once); known binary or large files open in Quick Look.
    func open(_ entry: RFEntry, in pane: FilePaneModel) {
        guard !entry.isDirectory else {
            _ = pane.open(entry)
            return
        }
        let endpoint = pane.endpoint
        switch FileEditClassification.decision(forName: entry.name, size: entry.size) {
        case .quickLook:
            preview(entry, on: endpoint)
        case .edit:
            openForPreferredEditor(entry, on: endpoint, preloaded: nil)
        case .sniffThenDecide:
            let prompts = prompts
            Task {
                do {
                    let (fs, served) = try await FileConnectionPool.shared.fileSystemAndPrincipal(
                        for: endpoint, purpose: .browse, prompts: prompts
                    )
                    let (data, fingerprint) = try await RemoteFileEditCenter.fetchRemoteFile(
                        path: entry.path,
                        fs: fs,
                        endpointKey: served.key,
                        maxBytes: FileEditClassification.maxInAppEditBytes
                    )
                    // Abort if the window closed or the pane switched to another endpoint while downloading.
                    guard !isTornDown, !Task.isCancelled, pane.endpoint == endpoint else { return }
                    if FileEditClassification.isTextData(data) {
                        openForPreferredEditor(
                            entry,
                            on: endpoint,
                            preloaded: FetchedRemoteFile(data: data, fingerprint: fingerprint, principal: served)
                        )
                    } else if endpoint.isLocal {
                        preview(entry, on: endpoint)
                    } else {
                        let url = try FileManagerPreviewCache.storePreviewData(data, named: entry.name)
                        previewRequest = PreviewRequest(url: url)
                    }
                } catch RemoteEditError.tooLarge {
                    guard !isTornDown, !Task.isCancelled, pane.endpoint == endpoint else { return }
                    preview(entry, on: endpoint)
                } catch is CancellationError {
                    return
                } catch {
                    guard !isTornDown, !Task.isCancelled, pane.endpoint == endpoint else { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openForPreferredEditor(
        _ entry: RFEntry,
        on endpoint: FileEndpoint,
        preloaded: FetchedRemoteFile?
    ) {
        let rawPreference = SettingsStore.shared.value(Settings.Transfer.fileManagerEditorPreference)
        #if targetEnvironment(macCatalyst)
        let preference = rawPreference.resolved(isMacCatalyst: true)
        if preference == .external {
            editExternally(entry, on: endpoint, appURL: nil, preloaded: preloaded)
            return
        }
        #else
        let preference = rawPreference.resolved(isMacCatalyst: false)
        if let embedded = preference.embeddedEditor, openInEmbeddedEditor != nil {
            editInEmbeddedEditor(entry, on: endpoint, editor: embedded, preloaded: preloaded)
            return
        }
        #endif
        editInApp(entry, on: endpoint, preloaded: preloaded)
    }

    /// Opens `entry` in one of the bundled terminal editors (`vim` or `hx`) on iOS/iPadOS/visionOS.
    /// Remote files are staged locally and watched for `:w` saves to auto-upload back to the server.
    func editInEmbeddedEditor(
        _ entry: RFEntry,
        in pane: FilePaneModel,
        editor: FileManagerEmbeddedEditor,
        preloaded: FetchedRemoteFile? = nil
    ) {
        editInEmbeddedEditor(entry, on: pane.endpoint, editor: editor, preloaded: preloaded)
    }

    func editInEmbeddedEditor(
        _ entry: RFEntry,
        on endpoint: FileEndpoint,
        editor: FileManagerEmbeddedEditor,
        preloaded: FetchedRemoteFile? = nil
    ) {
        guard !entry.isDirectory else { return }
        guard let launcher = openInEmbeddedEditor else {
            editInApp(entry, on: endpoint, preloaded: preloaded)
            return
        }

        if endpoint.isLocal {
            let resolved = LocalPathResolver.current().resolve(entry.path)
            if !launcher(resolved, editor) {
                errorMessage = String(localized: "Couldn't launch \(editor.title).", comment: "File manager embedded editor error; argument is editor name")
            }
            return
        }

        if let existing = RemoteFileEditCenter.shared.existingSession(for: endpoint, remotePath: entry.path) {
            reopenEmbeddedEdit(existing, editor: editor, launcher: launcher)
            return
        }

        guard entry.size <= FileEditClassification.maxExternalEditBytes else {
            errorMessage = RemoteEditError.tooLarge(limitBytes: FileEditClassification.maxExternalEditBytes).localizedDescription
            return
        }

        guard !isTornDown else { return }

        // Deduplicate overlapping opens before staging so two clicks never clobber each other.
        guard let openToken = RemoteFileEditCenter.shared.beginOpen(for: endpoint, remotePath: entry.path) else {
            return
        }

        let prompts = prompts
        let task = Task {
            defer {
                inFlightExternalOpenTasks.removeValue(forKey: openToken)
                RemoteFileEditCenter.shared.endOpen(token: openToken)
            }
            do {
                let (stagedURL, hash, fingerprint, principal) = try await RemoteFileEditCenter.shared.stageForExternalEdit(
                    entry: entry,
                    endpoint: endpoint,
                    prompts: prompts,
                    preloaded: preloaded
                )
                guard !isTornDown, !Task.isCancelled else {
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    return
                }
                switch RemoteFileEditCenter.shared.confirmStagedOpen(token: openToken, servedBy: principal, remotePath: entry.path) {
                case .launch:
                    break
                case .reuse(let existing):
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    reopenEmbeddedEdit(existing, editor: editor, launcher: launcher)
                    return
                case .drop:
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    return
                }
                guard launcher(stagedURL.path, editor) else {
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    errorMessage = String(localized: "Couldn't launch \(editor.title).", comment: "File manager embedded editor error; argument is editor name")
                    return
                }
                RemoteFileEditCenter.shared.registerSession(
                    endpoint: endpoint,
                    principal: principal,
                    remotePath: entry.path,
                    fileName: entry.name,
                    localURL: stagedURL,
                    initialHash: hash,
                    remoteFingerprint: fingerprint,
                    holdsSecurityScope: false,
                    ownsLocalDirectory: true,
                    editorName: editor.shortTitle,
                    embeddedEditor: editor,
                    prompts: prompts
                )
            } catch is CancellationError {
                return
            } catch {
                if !isTornDown {
                    errorMessage = error.localizedDescription
                }
            }
        }
        inFlightExternalOpenTasks[openToken] = task
    }

    private func reopenEmbeddedEdit(
        _ session: RemoteEditSession,
        editor: FileManagerEmbeddedEditor,
        launcher: (String, FileManagerEmbeddedEditor) -> Bool
    ) {
        session.embeddedEditor = editor
        session.editorName = editor.shortTitle
        if !launcher(session.localURL.path, editor) {
            errorMessage = String(localized: "Couldn't launch \(editor.title).", comment: "File manager embedded editor error; argument is editor name")
        }
    }

    func editInApp(
        _ entry: RFEntry,
        in pane: FilePaneModel,
        preloaded: FetchedRemoteFile? = nil
    ) {
        editInApp(entry, on: pane.endpoint, preloaded: preloaded)
    }

    func editInApp(
        _ entry: RFEntry,
        on endpoint: FileEndpoint,
        preloaded: FetchedRemoteFile? = nil
    ) {
        guard !entry.isDirectory else { return }
        guard entry.size <= FileEditClassification.maxInAppEditBytes else {
            errorMessage = RemoteEditError.tooLarge(limitBytes: FileEditClassification.maxInAppEditBytes).localizedDescription
            return
        }
        sheet = .edit(RemoteFileEditorRequest(
            entry: entry,
            endpoint: endpoint,
            prompts: prompts,
            preloaded: preloaded
        ))
    }

    /// Opens `entry` in an external editor. For remote files, stages a local working copy and
    /// watches it for saves to automatically upload changes back to the remote endpoint.
    func editExternally(
        _ entry: RFEntry,
        in pane: FilePaneModel,
        appURL: URL? = nil,
        preloaded: FetchedRemoteFile? = nil
    ) {
        editExternally(entry, on: pane.endpoint, appURL: appURL, preloaded: preloaded)
    }

    func editExternally(
        _ entry: RFEntry,
        on endpoint: FileEndpoint,
        appURL: URL? = nil,
        preloaded: FetchedRemoteFile? = nil
    ) {
        guard !entry.isDirectory else { return }

        if endpoint.isLocal {
            let resolved = LocalPathResolver.current().resolve(entry.path)
            let url = URL(fileURLWithPath: resolved)
            #if targetEnvironment(macCatalyst)
            Task {
                do {
                    _ = try await ExternalEditorBridge.open(url, withApplication: appURL)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            #else
            activityShareRequest = ActivityShareRequest(url: url)
            #endif
            return
        }

        if let existing = RemoteFileEditCenter.shared.existingSession(for: endpoint, remotePath: entry.path) {
            reopenExternalEdit(existing, withApp: appURL)
            return
        }

        guard entry.size <= FileEditClassification.maxExternalEditBytes else {
            errorMessage = RemoteEditError.tooLarge(limitBytes: FileEditClassification.maxExternalEditBytes).localizedDescription
            return
        }

        guard !isTornDown else { return }

        // Deduplicate overlapping opens before staging so two clicks never clobber each other.
        guard let openToken = RemoteFileEditCenter.shared.beginOpen(for: endpoint, remotePath: entry.path) else {
            return
        }

        let prompts = prompts
        let task = Task {
            var tokenHandedOff = false
            defer {
                inFlightExternalOpenTasks.removeValue(forKey: openToken)
                if !tokenHandedOff {
                    RemoteFileEditCenter.shared.endOpen(token: openToken)
                }
            }
            do {
                let (stagedURL, hash, fingerprint, principal) = try await RemoteFileEditCenter.shared.stageForExternalEdit(
                    entry: entry,
                    endpoint: endpoint,
                    prompts: prompts,
                    preloaded: preloaded
                )
                guard !isTornDown, !Task.isCancelled else {
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    return
                }
                switch RemoteFileEditCenter.shared.confirmStagedOpen(token: openToken, servedBy: principal, remotePath: entry.path) {
                case .launch:
                    break
                case .reuse(let existing):
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    reopenExternalEdit(existing, withApp: appURL)
                    return
                case .drop:
                    RemoteFileEditCenter.removeStagingDirectory(stagedURL.deletingLastPathComponent())
                    return
                }
                #if targetEnvironment(macCatalyst)
                // Transfer ownership of `openToken` and `stagedURL` from this window's teardown
                // map to the app-wide launch BEFORE handing the file to macOS, so closing this
                // window mid-launch never lets a second window open a competing copy.
                tokenHandedOff = true
                inFlightExternalOpenTasks.removeValue(forKey: openToken)
                startAppWideExternalLaunch(
                    openToken: openToken,
                    entry: entry,
                    endpoint: endpoint,
                    stagedURL: stagedURL,
                    hash: hash,
                    fingerprint: fingerprint,
                    principal: principal,
                    appURL: appURL,
                    prompts: prompts
                )
                #else
                tokenHandedOff = true
                enqueueExternalExport(ExternalExportRequest(
                    entry: entry,
                    endpoint: endpoint,
                    stagedURL: stagedURL,
                    hash: hash,
                    fingerprint: fingerprint,
                    principal: principal,
                    prompts: prompts,
                    openToken: openToken
                ))
                #endif
            } catch is CancellationError {
                return
            } catch {
                if !isTornDown {
                    errorMessage = error.localizedDescription
                }
            }
        }
        inFlightExternalOpenTasks[openToken] = task
    }

    #if targetEnvironment(macCatalyst)
    private func startAppWideExternalLaunch(
        openToken: UUID,
        entry: RFEntry,
        endpoint: FileEndpoint,
        stagedURL: URL,
        hash: Data,
        fingerprint: RemoteFileFingerprint,
        principal: EditPrincipal,
        appURL: URL?,
        prompts: FileManagerPrompts
    ) {
        Task { @MainActor [weak self] in
            do {
                try await RemoteFileEditCenter.shared.launchAndRegisterExternalEdit(
                    openToken: openToken,
                    entry: entry,
                    endpoint: endpoint,
                    stagedURL: stagedURL,
                    hash: hash,
                    fingerprint: fingerprint,
                    principal: principal,
                    appURL: appURL,
                    prompts: prompts
                )
            } catch {
                if let self, !self.isTornDown {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    #endif

    private func enqueueExternalExport(_ request: ExternalExportRequest) {
        guard !isTornDown else {
            cleanupExternalExport(request)
            return
        }
        if externalExportRequest == nil && externalExportAdvanceTask == nil {
            externalExportRequest = request
        } else {
            pendingExternalExports.append(request)
        }
    }

    private func advanceExternalExportQueue() {
        guard !isTornDown,
              externalExportRequest == nil,
              externalExportAdvanceTask == nil,
              !pendingExternalExports.isEmpty else { return }
        externalExportAdvanceTask = Task { @MainActor [weak self] in
            // Let UIKit finish dismissing the previous document picker before presenting the next.
            // Keep the next request owned by `pendingExternalExports` during the delay so teardown
            // always finds and releases its staged folder and open token.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.externalExportAdvanceTask = nil
            guard !Task.isCancelled,
                  !self.isTornDown,
                  self.externalExportRequest == nil,
                  !self.pendingExternalExports.isEmpty else { return }
            self.externalExportRequest = self.pendingExternalExports.removeFirst()
        }
    }

    private func cleanupExternalExport(_ request: ExternalExportRequest) {
        RemoteFileEditCenter.shared.endOpen(token: request.openToken)
        RemoteFileEditCenter.removeStagingDirectory(request.stagedURL.deletingLastPathComponent())
    }

    func completeExternalExport(_ request: ExternalExportRequest, destinationURL: URL) {
        if externalExportRequest?.id == request.id {
            externalExportRequest = nil
        }
        defer {
            RemoteFileEditCenter.shared.endOpen(token: request.openToken)
            advanceExternalExportQueue()
        }
        let scoped = destinationURL.startAccessingSecurityScopedResource()
        // The file was moved out of the temporary staging folder; remove the leftover directory & manifest.
        RemoteFileEditCenter.removeStagingDirectory(request.stagedURL.deletingLastPathComponent())

        let folderLabel = destinationURL.deletingLastPathComponent().lastPathComponent
        RemoteFileEditCenter.shared.registerSession(
            endpoint: request.endpoint,
            principal: request.principal,
            remotePath: request.entry.path,
            fileName: request.entry.name,
            localURL: destinationURL,
            initialHash: request.hash,
            remoteFingerprint: request.fingerprint,
            holdsSecurityScope: scoped,
            ownsLocalDirectory: false,
            editorName: folderLabel.isEmpty ? nil : folderLabel,
            prompts: request.prompts
        )
    }

    func cancelExternalExport(_ request: ExternalExportRequest) {
        if externalExportRequest?.id == request.id {
            externalExportRequest = nil
        }
        cleanupExternalExport(request)
        advanceExternalExportQueue()
    }

    /// `reuseRememberedApp` is for Active Edits → Reopen only; a fresh Edit must resolve the
    /// current editor preference, never a remembered Open With app that may run the file.
    func reopenExternalEdit(_ session: RemoteEditSession, withApp appURL: URL? = nil, reuseRememberedApp: Bool = false) {
        #if targetEnvironment(macCatalyst)
        Task {
            do {
                let remembered = reuseRememberedApp
                    ? session.editorAppURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                    : nil
                let appName = try await ExternalEditorBridge.open(session.localURL, withApplication: appURL ?? remembered)
                session.editorName = appName
                session.editorAppURL = appURL ?? remembered
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        #else
        if let embedded = session.embeddedEditor, let launcher = openInEmbeddedEditor {
            if !launcher(session.localURL.path, embedded) {
                errorMessage = String(localized: "Couldn't launch \(embedded.title).", comment: "File manager embedded editor error; argument is editor name")
            }
            return
        }
        activityShareRequest = ActivityShareRequest(url: session.localURL)
        #endif
    }

    func preview(_ entry: RFEntry, in pane: FilePaneModel) {
        preview(entry, on: pane.endpoint)
    }

    func preview(_ entry: RFEntry, on endpoint: FileEndpoint) {
        let prompts = prompts
        Task {
            do {
                let fs = try await FileConnectionPool.shared.fileSystem(for: endpoint, purpose: .browse, prompts: prompts)
                let url = try await FileManagerPreviewCache.localURL(for: entry, fs: fs)
                previewRequest = PreviewRequest(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var canOpenActiveInTerminal: Bool {
        openInTerminal != nil && !activePane.path.isEmpty && activePane.endpoint.supportsTerminal
    }

    func openActiveInTerminal() {
        let pane = activePane
        var directory = pane.path
        if let entry = pane.cursorEntry, entry.isDirectory, pane.selection.count <= 1 { directory = entry.path }
        guard !directory.isEmpty else { return }
        if openInTerminal?(pane.endpoint, directory) == false {
            errorMessage = String(localized: "This location can't be opened in a terminal.", comment: "File manager error")
        }
    }

    // MARK: - Refresh after jobs

    private func refreshPanes(affectedBy job: TransferJob) {
        for pane in [left, right] where !pane.path.isEmpty {
            let touchesSource = pane.endpoint.mayShareFiles(with: job.source)
                && job.sourcePaths.contains {
                    FileTransferLogic.parent(of: $0).utf8.elementsEqual(pane.path.utf8)
                        || $0.utf8.elementsEqual(pane.path.utf8)
                }
            let touchesDestination = job.destination.map(pane.endpoint.mayShareFiles) == true
                && job.destinationDirectory?.utf8.elementsEqual(pane.path.utf8) == true
            if touchesSource || touchesDestination { pane.refresh() }
        }
    }

    private func refreshPanes(affectedByEndpoint endpoint: FileEndpoint, path: String) {
        let parent = FileTransferLogic.parent(of: path)
        for pane in [left, right] where !pane.path.isEmpty {
            if pane.endpoint.mayShareFiles(with: endpoint), pane.path.utf8.elementsEqual(parent.utf8) {
                pane.refresh()
            }
        }
    }

    // MARK: - Persistence

    private struct SavedState: Codable {
        var left: SavedPane?
        var right: SavedPane?
        var activeSide: String

        struct SavedPane: Codable {
            var endpoint: String
            var path: String
        }
    }

    func save() {
        func saved(_ pane: FilePaneModel) -> SavedState.SavedPane? {
            guard let key = pane.endpoint.persistentKey else { return nil }
            return SavedState.SavedPane(endpoint: key, path: pane.path)
        }
        let state = SavedState(left: saved(left), right: saved(right), activeSide: activeSide.rawValue)
        guard let data = try? JSONEncoder().encode(state) else { return }
        SettingsStore.shared.set(Settings.Transfer.fileManagerPaneState, String(decoding: data, as: UTF8.self))
    }

    private func restore() {
        if let json = SettingsStore.shared.value(Settings.Transfer.fileManagerPaneState),
           let state = try? JSONDecoder().decode(SavedState.self, from: Data(json.utf8)) {
            for (pane, saved) in [(left, state.left), (right, state.right)] {
                guard let saved, let endpoint = FileEndpoint(persistentKey: saved.endpoint) else { continue }
                // Remote panes reconnect lazily on first show, so restoring never prompts.
                if endpoint.isLocal {
                    pane.connect(to: endpoint, path: saved.path.isEmpty ? nil : saved.path)
                } else {
                    pane.restorePending(endpoint: endpoint, path: saved.path)
                }
            }
            activeSide = FilePaneModel.Side(rawValue: state.activeSide) ?? .left
        }
        // A pane with nothing to restore would otherwise show this device, empty, until refreshed.
        for pane in [left, right] where pane.isUnopened { pane.connect(to: .local) }
    }

    /// Connects panes whose remote endpoint was restored but not yet opened.
    func activatePendingRestores() {
        left.activatePendingRestore()
        right.activatePendingRestore()
    }

    func tearDown() {
        isTornDown = true
        save()
        // Resolve any auth/sudo/host-key prompts owned by this closing window so shared
        // connection tasks awaiting them unblock immediately instead of stranding other windows,
        // and unregister from app-wide live prompt fallback so surviving sessions switch windows.
        RemoteFileEditCenter.shared.unregisterLivePrompts(prompts)
        prompts.cancelAll()
        finishedObserver?.cancel()
        uploadedObserver?.cancel()
        externalExportAdvanceTask?.cancel()
        externalExportAdvanceTask = nil
        let runningOpens = inFlightExternalOpenTasks
        inFlightExternalOpenTasks.removeAll()
        for (token, task) in runningOpens {
            // Release app-wide open tokens synchronously in teardown so another window is never
            // blocked even while a cancelled waiter unwinds from a shared connection task.
            RemoteFileEditCenter.shared.endOpen(token: token)
            task.cancel()
        }
        if let active = externalExportRequest {
            externalExportRequest = nil
            cleanupExternalExport(active)
        }
        let queued = pendingExternalExports
        pendingExternalExports = []
        for req in queued {
            cleanupExternalExport(req)
        }
        left.detach()
        right.detach()
    }
}

enum FileManagerActionError: LocalizedError {
    case alreadyExists(String)
    case nothingToPaste
    case pasteNeedsBucket
    case unreadableItems(Int, of: Int)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let name):
            String(localized: "“\(name)” already exists.", comment: "File manager error; argument is a file name")
        case .nothingToPaste:
            String(localized: "The clipboard has no files to paste.", comment: "File manager error: paste with only text on the clipboard")
        case .pasteNeedsBucket:
            String(localized: "Open a bucket to paste files into.", comment: "File manager error: paste at a storage provider's bucket list")
        case .unreadableItems(let failed, let total) where failed == total:
            String(localized: "Couldn’t read the pasted or dropped items.", comment: "File manager error: no clipboard or drop item could be loaded")
        case .unreadableItems(let failed, let total):
            String(localized: "Couldn’t read \(failed) of \(total) items; the rest are being copied.", comment: "File manager error: some clipboard or drop items could not be loaded; arguments are counts")
        }
    }
}
