//
//  RemoteFileEditorDocument.swift
//  rootshell
//
//  One file open in the file manager's editor: its text, load and save state,
//  and the upload back to its endpoint. Owned by FileManagerModel, so edits
//  survive hiding the panel and switching its presentation.
//

import Foundation

@MainActor
@Observable
final class RemoteFileEditorDocument: Identifiable {
    enum LoadState: Equatable {
        case loading
        case ready
        case binary
        case failed(String)
    }

    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    enum Conflict {
        case modified
        case deleted
    }

    struct CursorPosition: Equatable {
        var line: Int
        var column: Int
    }

    /// Leaving the in-app editor for another editor, or for Quick Look.
    enum Handoff {
        case external(URL?)
        case embedded(FileManagerEmbeddedEditor)
        case quickLook
    }

    private struct QueuedSave {
        /// The text when the save was asked for; later keystrokes stay unsaved.
        let text: String
        let afterSuccess: (() -> Void)?
    }

    let id = UUID()
    let request: RemoteFileEditorRequest

    /// Untracked so typing never re-renders SwiftUI; `isDirty` and
    /// `externalTextRevision` carry the changes views need.
    @ObservationIgnored var text = "" {
        didSet { refreshDirty() }
    }
    @ObservationIgnored private var originalText = "" {
        didSet { refreshDirty() }
    }
    private(set) var isDirty = false
    private(set) var document = EditableTextDocument(text: "", encoding: .utf8, lineEnding: .lf)
    private(set) var language: FileEditorSyntax.Language = .plain
    private(set) var indentation: EditableTextDocument.Indentation = .spaces(2)
    private(set) var loadState: LoadState = .loading
    var saveState: SaveState = .idle
    var cursorPosition = CursorPosition(line: 1, column: 1)
    var lineCount = 1
    var byteCount = 0
    /// Bumped when the text is replaced from outside the text view.
    private(set) var externalTextRevision = 0
    var fontSize: CGFloat = 13
    var inlineBanner: String?
    var conflict: Conflict?
    /// A handoff waiting on Save or Discard.
    var pendingHandoff: Handoff?
    /// A reload waiting on Discard.
    var confirmsReload = false
    /// Bumped to open the find bar, from the editor's toolbar or the side rail.
    var findRequestID = 0

    /// The last focus request the text view acted on.
    @ObservationIgnored var consumedFocusRequestID = 0

    @ObservationIgnored private var fingerprint: RemoteFileFingerprint?
    /// The serving connection's principal when the shown text was fetched.
    @ObservationIgnored private var loadedPrincipal: EditPrincipal?
    /// Caret to restore when a presentation switch rebuilds the text view.
    @ObservationIgnored var savedSelection = NSRange(location: 0, length: 0)
    /// A recovery copy written when the app went to the background, removed on return.
    @ObservationIgnored var checkpointFolder: URL?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// A save asked for during an upload; it runs once that upload succeeds.
    @ObservationIgnored private var queuedSave: QueuedSave?
    /// The text an in-flight upload is writing.
    @ObservationIgnored private var uploadingText: String? {
        didSet { refreshDirty() }
    }
    @ObservationIgnored private var isClosed = false

    init(request: RemoteFileEditorRequest) {
        self.request = request
        FileConnectionPool.shared.retain(request.endpoint)
        reload(usePreloaded: true)
    }

    var entry: RFEntry { request.entry }
    var endpoint: FileEndpoint { request.endpoint }
    var isRemote: Bool { !request.endpoint.isLocal }

    /// Whether opening `entry` through `endpoint` should land on this tab: the path
    /// matches byte for byte (S3 and Ceph keep NFC and NFD spellings apart), the
    /// account it would be served by is the one this text came from (aliases count:
    /// a pane and its profile share a tab), and this tab's own endpoint still connects
    /// with exactly the key it loaded with, which saving requires. A profile edited
    /// to another host, or to an alias of it, keeps its id but opens a fresh tab.
    func matches(_ entry: RFEntry, on endpoint: FileEndpoint, servedBy: EditPrincipal?) -> Bool {
        guard RemoteEditPathIdentity.matches(request.entry.path, entry.path) else { return false }
        guard let loadedPrincipal else { return request.endpoint == endpoint }
        let pool = FileConnectionPool.shared
        return loadedPrincipal.reachesSameAccount(as: servedBy ?? pool.expectedPrincipal(for: endpoint))
            && pool.expectedPrincipal(for: request.endpoint).key == loadedPrincipal.key
    }

    #if targetEnvironment(macCatalyst)
    @ObservationIgnored private var cachedExternalApps: [ExternalEditorBridge.ExternalApp]?

    /// Mac apps that open this kind of file, for Open With; looked up once.
    var externalApps: [ExternalEditorBridge.ExternalApp] {
        if let cachedExternalApps { return cachedExternalApps }
        let probe = FileManager.default.temporaryDirectory.appendingPathComponent(request.entry.name)
        let apps = ExternalEditorBridge.availableApps(for: probe, includePlainText: true)
        cachedExternalApps = apps
        return apps
    }
    #endif

    /// The text as it would be written, for recovery when the window closes unsaved.
    var encodedText: Data { document.encode(text) }

    /// Drops the background recovery copy once the tab is back in charge of its text.
    func discardCheckpoint() {
        guard let checkpointFolder else { return }
        self.checkpointFolder = nil
        RemoteFileEditCenter.removeStagingDirectory(checkpointFolder)
    }

    /// The unsaved text now lives in the edit center's recovery list.
    func markPreserved() {
        originalText = text
    }

    /// Ends the document's connection hold; it is never reused afterwards.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        loadTask?.cancel()
        loadTask = nil
        queuedSave = nil
        FileConnectionPool.shared.release(request.endpoint)
    }

    /// Byte comparison: String equality treats NFC and NFD as one, but they save differently.
    private func differs(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count != rhs.utf8.count || !lhs.utf8.elementsEqual(rhs.utf8)
    }

    private func refreshDirty() {
        // Mid-upload, text that differs from what is being written still needs a save,
        // an undo back to the original included.
        let dirty = loadState == .ready
            && (differs(text, originalText) || uploadingText.map { differs(text, $0) } ?? false)
        if dirty != isDirty { isDirty = dirty }
    }

    // MARK: - Load

    func reload(usePreloaded: Bool = false) {
        // An upload in flight would land after the read and contradict what it shows.
        guard saveState != .saving else {
            inlineBanner = String(
                localized: "Wait for the upload to finish, then reload.",
                comment: "File editor notice when a reload is asked for during a save"
            )
            return
        }
        loadTask?.cancel()
        loadTask = Task { await load(usePreloaded: usePreloaded) }
    }

    private func load(usePreloaded: Bool) async {
        loadState = .loading
        // The text view is rebuilt when loading ends; let it take the keyboard again.
        consumedFocusRequestID = 0
        saveState = .idle
        inlineBanner = nil
        refreshDirty()
        do {
            let data: Data
            let loadedFingerprint: RemoteFileFingerprint
            let principal: EditPrincipal
            if usePreloaded, let preloaded = request.preloaded {
                data = preloaded.data
                loadedFingerprint = preloaded.fingerprint
                principal = preloaded.principal
            } else {
                let (fs, served) = try await FileConnectionPool.shared.fileSystemAndPrincipal(
                    for: request.endpoint, purpose: .transfer, prompts: request.prompts
                )
                (data, loadedFingerprint) = try await RemoteFileEditCenter.fetchRemoteFile(
                    path: request.entry.path,
                    fs: fs,
                    endpointKey: served.key,
                    maxBytes: FileEditClassification.maxInAppEditBytes
                )
                principal = served
            }
            try Task.checkCancellation()

            guard FileEditClassification.isTextData(data),
                  let decoded = EditableTextDocument.decode(data) else {
                loadState = .binary
                return
            }

            document = decoded
            originalText = decoded.text
            text = decoded.text
            savedSelection = NSRange(location: 0, length: 0)
            cursorPosition = CursorPosition(line: 1, column: 1)
            lineCount = EditorLineIndex(text: decoded.text).lineCount
            byteCount = decoded.text.utf8.count
            externalTextRevision += 1
            fingerprint = loadedFingerprint
            loadedPrincipal = principal
            language = FileEditorSyntax.detectLanguage(
                fileName: request.entry.name,
                contentPrefix: String(decoded.text.prefix(512))
            )
            indentation = EditableTextDocument.detectIndentation(in: decoded.text, filename: request.entry.name)
            loadState = .ready
            refreshDirty()
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Save

    /// Uploads the current text. `afterSuccess` runs only when nothing was typed during the upload.
    /// Asked again mid-upload, it saves the text as of that request once the upload succeeds.
    func save(forceOverwrite: Bool = false, afterSuccess: (() -> Void)? = nil) {
        guard loadState == .ready, !isClosed else { return }
        guard saveState != .saving else {
            // A repeated ⌘S keeps a pending follow-up, such as Save & Close.
            if !forceOverwrite { queuedSave = QueuedSave(text: text, afterSuccess: afterSuccess ?? queuedSave?.afterSuccess) }
            return
        }
        upload(text, forceOverwrite: forceOverwrite, afterSuccess: afterSuccess)
    }

    private func upload(_ snapshotText: String, forceOverwrite: Bool, afterSuccess: (() -> Void)?) {
        let encoded = document.encode(snapshotText)
        let expected = fingerprint
        let principal = loadedPrincipal
        uploadingText = snapshotText
        saveState = .saving
        inlineBanner = nil

        Task {
            do {
                let (fs, served) = try await FileConnectionPool.shared.fileSystemAndPrincipal(
                    for: request.endpoint, purpose: .transfer, prompts: request.prompts
                )
                guard served.key == principal?.key else {
                    throw RemoteEditError.principalChanged(fileName: request.entry.name)
                }
                // Discarded while connecting or waiting on a prompt: write nothing.
                guard !isClosed else { return }
                let updatedFingerprint = try await RemoteFileEditCenter.uploadData(
                    encoded,
                    to: request.entry.path,
                    on: fs,
                    endpointKey: served.key,
                    expectedFingerprint: expected,
                    forceOverwrite: forceOverwrite
                )
                fingerprint = updatedFingerprint
                uploadingText = nil
                originalText = snapshotText
                let queued = queuedSave
                queuedSave = nil
                let next = queued.flatMap { differs($0.text, snapshotText) ? $0 : nil }
                // The background copy goes once no further upload will run and the buffer matches
                // what was committed; until then it may be the only copy of the text.
                if next == nil, !isDirty { discardCheckpoint() }
                saveState = .saved
                RemoteFileEditCenter.shared.notifyUploaded(endpoint: request.endpoint, remotePath: request.entry.path)

                // A tab closed mid-upload runs no follow-up (a handoff, a close).
                let then = isClosed ? nil : queued?.afterSuccess ?? afterSuccess
                if let next {
                    upload(next.text, forceOverwrite: false, afterSuccess: then)
                } else if differs(text, snapshotText) {
                    inlineBanner = String(
                        localized: "Uploaded earlier changes. Save again to upload your newer edits.",
                        comment: "File editor notice when edits were typed during an in-flight save"
                    )
                } else if let then {
                    then()
                } else {
                    try? await Task.sleep(for: .seconds(2.5))
                    if saveState == .saved { saveState = .idle }
                }
            } catch {
                uploadingText = nil
                queuedSave = nil
                switch error {
                case RemoteEditError.remoteModified:
                    saveState = .idle
                    conflict = .modified
                case RemoteEditError.remoteDeleted:
                    saveState = .idle
                    conflict = .deleted
                default:
                    saveState = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Editing

    func formatJSON() {
        do {
            let formatted = try FileEditJSONFormatter.prettyPrint(text)
            text = formatted
            lineCount = EditorLineIndex(text: formatted).lineCount
            byteCount = formatted.utf8.count
            externalTextRevision += 1
            inlineBanner = nil
        } catch {
            inlineBanner = error.localizedDescription
        }
    }
}
