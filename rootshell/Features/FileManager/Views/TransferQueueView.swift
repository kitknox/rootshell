//
//  TransferQueueView.swift
//  rootshell
//
//  Transfer progress: a one-line strip that expands into the queue, and a
//  pill shown over the terminal while the file manager is hidden.
//

import SwiftUI

struct TransferQueueView: View {
    @Bindable var manager: FileManagerModel
    private var center: FileTransferCenter { .shared }

    var body: some View {
        if !center.jobs.isEmpty {
            VStack(spacing: 0) {
                Divider()
                strip
                if manager.isQueueExpanded {
                    Divider()
                    jobList
                }
            }
        }
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.snappy) { manager.isQueueExpanded.toggle() } } label: {
                Image(systemName: "chevron.up")
                    .rotationEffect(.degrees(manager.isQueueExpanded ? 180 : 0))
                    .frame(width: 18)
            }
            .help(FileManagerShortcut.shortcut(for: .focusQueue).helpText)
            .accessibilityLabel(String(localized: "Show transfer queue", comment: "File manager queue toggle"))

            if let fraction = center.aggregateFraction {
                ProgressView(value: fraction).frame(maxWidth: 140)
            } else if center.hasActiveJobs {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: failedCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failedCount > 0 ? .orange : .green)
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            if center.hasActiveJobs {
                Button(String(localized: "Cancel All", comment: "File manager: cancel every transfer")) { center.cancelAll() }
                    .font(.caption)
            } else {
                Button(String(localized: "Clear", comment: "File manager: remove finished transfers")) { center.clearFinished() }
                    .font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var failedCount: Int {
        center.jobs.filter { if case .failed = $0.state { true } else { false } }.count
    }

    private var summary: String {
        let active = center.activeJobs.count
        guard active > 0 else {
            return failedCount > 0
                ? String(localized: "\(failedCount) failed", comment: "File manager queue summary")
                : String(localized: "Transfers complete", comment: "File manager queue summary")
        }
        var parts = [String(localized: "\(active) active", comment: "File manager queue summary: running job count")]
        let rate = center.aggregateBytesPerSecond
        if rate > 0 { parts.append(Self.rateText(rate)) }
        if let remaining = center.aggregateSecondsRemaining { parts.append(Self.remainingText(remaining)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Queue

    private var jobList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(center.jobs.reversed()) { job in
                        TransferJobRow(job: job, isCursor: manager.queueFocused && manager.queueCursor == job.id)
                            .id(job.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
            // Same floating-keyboard safe area as the file list: stay above the hint bar.
            .clipped()
            .onChange(of: manager.queueCursor) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    // MARK: - Formatting

    static func rateText(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        let value = formatter.string(from: max(1, seconds)) ?? ""
        return String(localized: "\(value) left", comment: "File manager: time remaining")
    }
}

private struct TransferJobRow: View {
    let job: TransferJob
    let isCursor: Bool
    private var center: FileTransferCenter { .shared }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    actions
                }
                if job.isActive, let fraction = job.fractionCompleted {
                    ProgressView(value: fraction)
                } else if job.isActive {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(isCursor ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if job.isActive || job.state == .queued {
                Button { center.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .help(FileManagerShortcut.shortcut(for: .cancelJob).helpText)
                    .accessibilityLabel(FileManagerShortcut.shortcut(for: .cancelJob).title)
            } else {
                if job.state != .completed {
                    Button { center.retry(job) } label: { Image(systemName: "arrow.clockwise.circle") }
                        .accessibilityLabel(String(localized: "Retry", comment: "File manager: retry a transfer"))
                }
                Button { center.remove(job) } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel(String(localized: "Remove from List", comment: "File manager: remove a finished transfer"))
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }

    private var symbol: String {
        switch job.state {
        case .queued: "clock"
        case .preparing, .running:
            switch job.operation {
            case .copy: "doc.on.doc"
            case .move: "arrow.right.doc.on.clipboard"
            case .delete: "trash"
            case .setPermissions: "lock"
            }
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var detail: String {
        switch job.state {
        case .queued:
            return String(localized: "Waiting", comment: "File manager: queued transfer")
        case .preparing:
            return String(localized: "Preparing…", comment: "File manager: transfer scanning folders")
        case .running:
            var parts: [String] = []
            if job.totalBytes > 0 {
                parts.append(String(localized: "\(FileRowView.sizeText(job.completedBytes)) of \(FileRowView.sizeText(job.totalBytes))",
                                    comment: "File manager: bytes done of total"))
            } else if job.totalItems > 0 {
                parts.append(String(localized: "\(job.completedItems) of \(job.totalItems)", comment: "File manager: items done of total"))
            }
            if job.bytesPerSecond > 0 { parts.append(TransferQueueView.rateText(job.bytesPerSecond)) }
            if let remaining = job.secondsRemaining { parts.append(TransferQueueView.remainingText(remaining)) }
            if let current = job.currentItem { parts.append(FileTransferLogic.lastComponent(of: current)) }
            return parts.joined(separator: " · ")
        case .completed:
            return job.routeDescription ?? ""
        case .failed(let message):
            return message
        case .cancelled:
            return String(localized: "Cancelled", comment: "File manager: cancelled transfer")
        }
    }
}

/// Floating progress over the terminal while the file manager is hidden.
struct TransferPill: View {
    /// Opens on the file list, where transfers and edit problems are listed.
    let manager: FileManagerModel?
    let onOpen: () -> Void
    private var center: FileTransferCenter { .shared }
    private var edits: RemoteFileEditCenter { .shared }

    private var showsEditStatus: Bool {
        !center.hasActiveJobs && (edits.hasActiveUploads || edits.hasAttentionItems)
    }

    var body: some View {
        if center.hasActiveJobs || showsEditStatus {
            Button {
                manager?.showFiles()
                onOpen()
            } label: {
                HStack(spacing: 8) {
                    if center.hasActiveJobs {
                        ZStack {
                            Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: center.aggregateFraction ?? 0.05)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 16, height: 16)
                        Text(pillText).font(.caption.weight(.medium)).monospacedDigit()
                    } else if edits.hasActiveUploads {
                        ProgressView().controlSize(.mini)
                        Text(editPillText).font(.caption.weight(.medium))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(editPillText).font(.caption.weight(.medium))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "File transfers in progress. Open file manager.", comment: "Transfer pill accessibility"))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var pillText: String {
        let active = center.activeJobs.count
        let rate = center.aggregateBytesPerSecond
        let count = String(localized: "\(active) transferring", comment: "Transfer pill: active job count")
        return rate > 0 ? "\(count) · \(TransferQueueView.rateText(rate))" : count
    }

    private var editPillText: String {
        if let uploading = edits.sessions.first(where: { $0.state == .uploading }) {
            return String(localized: "Uploading \(uploading.fileName)…", comment: "Transfer pill: auto-uploading external edit")
        }
        if let recovery = edits.recoveryConflicts.first {
            return String(localized: "Recovery conflict: \(recovery.fileName)", comment: "Transfer pill: interrupted save recovery conflict")
        }
        if let preserved = edits.preservedEdits.first {
            return String(localized: "Unsynced edit: \(preserved.fileName)", comment: "Transfer pill: preserved unsynced edit")
        }
        if let conflict = edits.sessions.first(where: { if case .conflict = $0.state { true } else { false } }) {
            return String(localized: "Edit conflict: \(conflict.fileName)", comment: "Transfer pill: external edit conflict")
        }
        if let swapPending = edits.sessions.first(where: { if case .stagingFilesRemaining = $0.state { true } else { false } }) {
            return String(localized: "Close editor: \(swapPending.fileName)", comment: "Transfer pill: editor swap file remains")
        }
        return String(localized: "Upload failed", comment: "Transfer pill: external edit upload failed")
    }
}
