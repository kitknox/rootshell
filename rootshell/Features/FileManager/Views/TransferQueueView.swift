//
//  TransferQueueView.swift
//  rootshell
//
//  Transfer progress: a one-line strip in the file manager that expands into
//  the queue.
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
