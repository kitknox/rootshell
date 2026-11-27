//
//  VideoBackgroundRow.swift
//  rootshell
//
//  Row component for displaying a video background with download state
//

import SwiftUI

struct VideoBackgroundRow: View {
    let video: RemoteVideoBackground
    let isActive: Bool
    let isPending: Bool
    /// False while any area shows this video, so another area's list cannot remove its file.
    var canDelete = true
    let onSelect: () -> Void

    @ObservedObject private var downloadManager = VideoBackgroundDownloadManager.shared

    private var downloadState: VideoDownloadState {
        downloadManager.downloadStates[video.id] ?? .notDownloaded
    }

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ThumbnailView(video: video)
                .frame(width: 60, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(video.displayName)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if isPending {
                        Text("Pending")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.2))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                    }
                }

                Text(video.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Download progress or status
                downloadStatusView
            }

            Spacer()

            // Action button / checkmark
            actionView
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap()
        }
    }

    @ViewBuilder
    private var downloadStatusView: some View {
        switch downloadState {
        case .notDownloaded:
            Label("Tap to download", systemImage: "arrow.down.circle")
                .font(.caption2)
                .foregroundColor(.blue)

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
                Text(progress, format: .wholePercent)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

        case .paused(let progress):
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.orange)
                Text("Paused at \(progress.formatted(.wholePercent))")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

        case .completed:
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.green)
            } else {
                Label("Downloaded", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

        case .failed(let error):
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundColor(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var actionView: some View {
        switch downloadState {
        case .notDownloaded:
            Button(action: startDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

        case .downloading:
            Button(action: pauseDownload) {
                Image(systemName: "pause.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
            }
            .buttonStyle(.plain)

        case .paused:
            Button(action: resumeDownload) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
            }
            .buttonStyle(.plain)

        case .completed:
            if isActive {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.blue)
            } else {
                Menu {
                    Button(action: onSelect) {
                        Label("Select", systemImage: "checkmark.circle")
                    }
                    if canDelete {
                        Button(role: .destructive, action: deleteVideo) {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }

        case .failed:
            Button(action: startDownload) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Actions

    /// The owner decides what a tap does in each download state; the terminal
    /// queues activation, other areas download first.
    private func handleTap() {
        onSelect()
    }

    private func startDownload() {
        downloadManager.startDownload(for: video)
    }

    private func pauseDownload() {
        downloadManager.pauseDownload(for: video.id)
    }

    private func resumeDownload() {
        downloadManager.resumeDownload(for: video.id, video: video)
    }

    private func deleteVideo() {
        downloadManager.deleteDownloadedVideo(video.id)
    }
}

// MARK: - Thumbnail View

struct ThumbnailView: View {
    let video: RemoteVideoBackground
    @ObservedObject private var downloadManager = VideoBackgroundDownloadManager.shared

    var body: some View {
        Group {
            if let image = downloadManager.thumbnailCache[video.id] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: video.previewIcon)
                            .foregroundColor(.secondary)
                    }
                    .task {
                        await downloadManager.downloadThumbnail(for: video)
                    }
            }
        }
    }
}

#Preview {
    List {
        VideoBackgroundRow(
            video: RemoteVideoBackground(
                id: "test",
                filename: "test.mp4",
                displayName: "Test Video",
                description: "A test video background",
                aspectRatio: .init(mode: "fill", alignment: "center"),
                resolution: .init(width: 1920, height: 1080),
                duration: 10.0,
                loop: .init(seamless: true, crossfadeDuration: 0),
                defaultIntensity: 0.3,
                previewIcon: "play.rectangle.fill",
                category: "test",
                thumbnail: "test_thumb.jpg"
            ),
            isActive: false,
            isPending: false,
            onSelect: {}
        )
        .themedRow()
    }
    .themedList()
}
