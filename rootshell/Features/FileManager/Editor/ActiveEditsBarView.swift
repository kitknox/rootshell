//
//  ActiveEditsBarView.swift
//  rootshell
//
//  Compact strip in the file manager showing remote files currently open in
//  external or embedded editors with live auto-upload status, conflict
//  resolution, flush-before-stop safety, and reopen / stop controls.
//

import SwiftUI

struct ActiveEditsBarView: View {
    @Bindable var manager: FileManagerModel
    private var center: RemoteFileEditCenter { .shared }
    @State private var isExpanded = false
    @State private var pendingDiscard: PendingDiscard?

    private enum PendingDiscard {
        case single(RemoteEditSession)
        case multiple([RemoteEditSession])

        var title: String {
            switch self {
            case .single(let session):
                String(localized: "Discard unuploaded changes to “\(session.fileName)”?", comment: "Active edits stop confirmation; argument is a file name")
            case .multiple(let sessions):
                String(localized: "Discard unuploaded changes to \(sessions.count) files?", comment: "Active edits stop all confirmation; argument is a count")
            }
        }

        var message: String {
            switch self {
            case .single(let session):
                session.ownsStagingDirectory
                    ? String(localized: "This file hasn't finished uploading to \(session.endpoint.displayName). Stopping will discard the local working copy.", comment: "Active edits stop confirmation message")
                    : String(localized: "This file hasn't finished uploading to \(session.endpoint.displayName). Stopping will stop watching it without uploading.", comment: "Active edits stop confirmation message")
            case .multiple:
                String(localized: "These files have unresolved conflicts or failed uploads. Stopping will stop watching them and remove any temporary working copies.", comment: "Active edits stop all confirmation message")
            }
        }
    }

    var body: some View {
        if center.hasVisibleBarItems {
            VStack(spacing: 0) {
                Divider()
                strip
                if isExpanded || center.hasAttentionItems {
                    Divider()
                    sessionList
                }
            }
            .confirmationDialog(
                pendingDiscard?.title ?? "",
                isPresented: Binding(
                    get: { pendingDiscard != nil },
                    set: { if !$0 { pendingDiscard = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Discard & Stop", comment: "Active edits confirm discard"), role: .destructive) {
                    switch pendingDiscard {
                    case .single(let session):
                        center.forceStop(session)
                    case .multiple(let sessions):
                        for session in sessions { center.forceStop(session) }
                    case .none:
                        break
                    }
                    pendingDiscard = nil
                }
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    pendingDiscard = nil
                }
            } message: {
                if let message = pendingDiscard?.message {
                    Text(message)
                }
            }
        }
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.snappy) { isExpanded.toggle() } } label: {
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees((isExpanded || center.hasAttentionItems) ? 180 : 0))
                    .frame(width: 18)
            }
            .accessibilityLabel(String(localized: "Show active external edits", comment: "File manager active edits toggle"))

            if center.hasActiveUploads {
                ProgressView().controlSize(.small)
            } else if center.hasAttentionItems {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if center.hasActiveSessions {
                Button(String(localized: "Stop All", comment: "File manager: stop watching all external edits")) {
                    Task {
                        let remaining = await center.requestStopAll(prompts: manager.prompts)
                        if !remaining.isEmpty {
                            pendingDiscard = remaining.count == 1 ? .single(remaining[0]) : .multiple(remaining)
                        }
                    }
                }
                .font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var summary: String {
        let sessions = center.sessions
        if let uploading = sessions.first(where: { $0.state == .uploading }) {
            return String(localized: "Uploading \(uploading.fileName)…", comment: "Active edits summary")
        }
        if let recovery = center.recoveryConflicts.first {
            return String(localized: "Recovery conflict on \(recovery.fileName)", comment: "Active edits summary")
        }
        if let preserved = center.preservedEdits.first {
            return String(localized: "Unsynced edit preserved: \(preserved.fileName)", comment: "Active edits summary")
        }
        if let conflict = sessions.first(where: { if case .conflict = $0.state { true } else { false } }) {
            return String(localized: "Conflict on \(conflict.fileName)", comment: "Active edits summary")
        }
        if let swapPending = sessions.first(where: { if case .stagingFilesRemaining = $0.state { true } else { false } }) {
            return String(localized: "Close editor before stopping \(swapPending.fileName)", comment: "Active edits summary")
        }
        if let failed = sessions.first(where: { if case .error = $0.state { true } else { false } }) {
            return String(localized: "Upload failed for \(failed.fileName)", comment: "Active edits summary")
        }
        if sessions.count == 1, let only = sessions.first {
            return String(localized: "Watching \(only.fileName) · Auto-upload on save", comment: "Active edits summary")
        }
        return String(localized: "Watching \(sessions.count) files · Auto-upload on save", comment: "Active edits summary")
    }

    // MARK: - List

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(center.recoveryConflicts) { notice in
                    RecoveryConflictRow(notice: notice) {
                        center.dismissRecoveryConflict(notice)
                    }
                }
                ForEach(center.preservedEdits) { edit in
                    PreservedUnsyncedEditRow(edit: edit, manager: manager) {
                        center.discardPreservedEdit(edit)
                    }
                }
                ForEach(center.sessions) { session in
                    ActiveEditSessionRow(session: session, manager: manager) {
                        Task {
                            let stopped = await center.requestStop(session, prompts: manager.prompts)
                            if !stopped {
                                pendingDiscard = .single(session)
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 190)
        .clipped()
    }
}

private struct PreservedUnsyncedEditRow: View {
    let edit: PreservedUnsyncedEdit
    let manager: FileManagerModel
    let onDiscard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.orange)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(edit.fileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let endpoint = edit.endpointDisplayName {
                        Text(endpoint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 8) {
                        #if targetEnvironment(macCatalyst)
                        Button {
                            ExternalEditorBridge.revealInFinder(edit.files.count == 1 ? edit.files[0] : edit.folderURL)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help(String(localized: "Reveal Preserved Copy in Finder", comment: "Preserved edit action"))
                        .accessibilityLabel(String(localized: "Reveal Preserved Copy in Finder", comment: "Preserved edit action"))
                        #else
                        if edit.files.count == 1, let onlyFile = edit.files.first {
                            Button {
                                manager.activityShareRequest = FileManagerModel.ActivityShareRequest(url: onlyFile)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .help(String(localized: "Share Preserved Copy", comment: "Preserved edit action"))
                            .accessibilityLabel(String(localized: "Share Preserved Copy", comment: "Preserved edit action"))
                        } else {
                            Menu {
                                Button {
                                    manager.activityShareRequest = FileManagerModel.ActivityShareRequest(url: edit.folderURL)
                                } label: {
                                    Label(String(localized: "Export Whole Folder", comment: "Preserved edit export folder"), systemImage: "folder")
                                }
                                if !edit.files.isEmpty {
                                    Button {
                                        manager.activityShareRequest = FileManagerModel.ActivityShareRequest(urls: edit.files)
                                    } label: {
                                        Label(String(localized: "Share All \(edit.files.count) Files", comment: "Preserved edit share all files"), systemImage: "square.and.arrow.up.on.square")
                                    }
                                    Divider()
                                    ForEach(edit.files, id: \.self) { fileURL in
                                        Button {
                                            manager.activityShareRequest = FileManagerModel.ActivityShareRequest(url: fileURL)
                                        } label: {
                                            Label(fileURL.lastPathComponent, systemImage: "doc")
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .help(String(localized: "Export Preserved Files", comment: "Preserved edit action"))
                            .accessibilityLabel(String(localized: "Export Preserved Files", comment: "Preserved edit action"))
                        }
                        #endif
                        Button(String(localized: "Discard", comment: "Discard preserved unsynced edit"), role: .destructive, action: onDiscard)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var detailText: String {
        let extraCount = max(0, edit.files.count - 1)
        if extraCount > 0 {
            if let remotePath = edit.remotePath {
                return String(localized: "Unsynced copy and \(extraCount) extra file(s) preserved (e.g. editor swap file) · \(remotePath)", comment: "Preserved unsynced edit detail with extra files")
            }
            return String(localized: "Unsynced copy and \(extraCount) extra file(s) preserved from a previous session.", comment: "Preserved unsynced edit detail with extra files")
        }
        if let remotePath = edit.remotePath {
            return String(localized: "Unsynced local copy from a previous session was preserved · \(remotePath)", comment: "Preserved unsynced edit detail")
        }
        return String(localized: "Unsynced local copy from a previous session was preserved.", comment: "Preserved unsynced edit detail")
    }
}

private struct RecoveryConflictRow: View {
    let notice: RemoteFileEditCenter.RecoveryConflictNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(notice.fileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(notice.endpointDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.primary.opacity(0.06), in: Capsule())
                    Spacer(minLength: 4)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(String(localized: "Dismiss notice", comment: "Recovery conflict dismiss button"))
                    .accessibilityLabel(String(localized: "Dismiss notice", comment: "Recovery conflict dismiss button"))
                }
                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ActiveEditSessionRow: View {
    let session: RemoteEditSession
    let manager: FileManagerModel
    let onRequestStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.fileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let editor = session.editorName {
                        Text(editor)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.06), in: Capsule())
                    }
                    Spacer(minLength: 4)
                    actions
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(session.state.needsAttention ? .orange : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch session.state {
        case .uploading:
            ProgressView().controlSize(.mini)
        case .synced:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .conflict, .error, .stagingFilesRemaining:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .watching:
            Image(systemName: "pencil.circle.fill").foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch session.state {
            case .conflict(let kind):
                if kind == .deleted {
                    Button(String(localized: "Recreate", comment: "Active edit conflict: recreate deleted remote file")) {
                        session.resolveConflictByOverwriting(prompts: manager.prompts)
                    }
                    .font(.caption.weight(.semibold))
                } else {
                    Button(String(localized: "Overwrite", comment: "Active edit conflict: overwrite remote")) {
                        session.resolveConflictByOverwriting(prompts: manager.prompts)
                    }
                    .font(.caption.weight(.semibold))
                    Button(String(localized: "Reload", comment: "Active edit conflict: pull remote")) {
                        session.resolveConflictByReloading(prompts: manager.prompts)
                    }
                    .font(.caption)
                }
            case .error:
                Button {
                    session.checkForLocalChanges(evenIfUnchanged: true, prompts: manager.prompts)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .help(String(localized: "Retry Upload", comment: "Active edit action"))
                .accessibilityLabel(String(localized: "Retry Upload", comment: "Active edit action"))
            case .watching, .synced, .uploading, .stagingFilesRemaining:
                Button {
                    session.checkForLocalChanges(evenIfUnchanged: true, prompts: manager.prompts)
                } label: {
                    Image(systemName: "arrow.up.circle")
                }
                .disabled(session.state == .uploading)
                .help(String(localized: "Upload Now", comment: "Active edit action"))
                .accessibilityLabel(String(localized: "Upload Now", comment: "Active edit action"))

                Button {
                    manager.reopenExternalEdit(session)
                } label: {
                    Image(systemName: session.embeddedEditor != nil ? "terminal" : "arrow.up.forward.app")
                }
                .help(session.embeddedEditor.map {
                    String(localized: "Open in \($0.title)", comment: "Active edit action; argument is editor name")
                } ?? String(localized: "Open in External Editor", comment: "Active edit action"))
                .accessibilityLabel(session.embeddedEditor.map {
                    String(localized: "Open in \($0.title)", comment: "Active edit action; argument is editor name")
                } ?? String(localized: "Open in External Editor", comment: "Active edit action"))

                #if targetEnvironment(macCatalyst)
                Button {
                    ExternalEditorBridge.revealInFinder(session.localURL)
                } label: {
                    Image(systemName: "folder")
                }
                .help(String(localized: "Reveal Working Copy in Finder", comment: "Active edit action"))
                .accessibilityLabel(String(localized: "Reveal Working Copy in Finder", comment: "Active edit action"))
                #endif
            }

            Button(action: onRequestStop) {
                Image(systemName: "xmark.circle")
            }
            .help(String(localized: "Stop Watching", comment: "Active edit action"))
            .accessibilityLabel(String(localized: "Stop Watching", comment: "Active edit action"))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private var detailText: String {
        switch session.state {
        case .watching:
            return String(localized: "\(session.remoteDisplayPath) · Waiting for saves", comment: "Active edit row detail")
        case .uploading:
            return String(localized: "Uploading to \(session.remoteDisplayPath)…", comment: "Active edit row detail")
        case .synced(let date):
            let time = date.formatted(date: .omitted, time: .shortened)
            return String(localized: "Uploaded \(time) · \(session.remoteDisplayPath)", comment: "Active edit row detail")
        case .conflict(.deleted):
            return String(localized: "Deleted or renamed on server · \(session.remoteDisplayPath)", comment: "Active edit row detail")
        case .conflict(.modified):
            return String(localized: "Changed on server since open · \(session.remoteDisplayPath)", comment: "Active edit row detail")
        case .error(let message), .stagingFilesRemaining(let message):
            return "\(message) · \(session.remoteDisplayPath)"
        }
    }
}
