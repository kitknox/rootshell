// VideoBackgroundLibraryView.swift
// rootshell
//
// Imported and downloadable looping videos, opened from the Video tile.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct VideoBackgroundLibraryView: View {
    let area: BackgroundEffectArea
    var effectManager = EffectManager.shared
    @ObservedObject private var videoManager = VideoBackgroundManager.shared
    @ObservedObject private var localVideoManager = LocalVideoBackgroundManager.shared
    @Setting(Settings.Shaders.sidebarEffectId) private var sidebarEffectID
    @Setting(Settings.Shaders.keyboardEffectId) private var keyboardEffectID

    @State private var showVideoFileImporter = false
    @State private var videoImportError: String?
    @State private var isImportingVideo = false
    @State private var selectedPhotosVideoItem: PhotosPickerItem?

    private func effectID(_ videoID: String) -> String { "videoBackground_\(videoID)" }

    private var selectedID: String? {
        switch area {
        case .terminal, .window: effectManager.activeEffect?.id
        case .sidebar: sidebarEffectID
        case .keyboard: keyboardEffectID
        }
    }

    /// Videos any area shows; deleting one would pull it out from under that area.
    private var videosInUse: Set<String> {
        var ids: Set<String> = [sidebarEffectID, keyboardEffectID]
        if let id = effectManager.activeEffect?.id { ids.insert(id) }
        if let pending = effectManager.pendingVideoActivation { ids.insert(effectID(pending)) }
        return ids
    }

    /// The terminal switches once a download lands; other areas need the video on hand.
    private func select(_ videoID: String) {
        guard area == .sidebar || area == .keyboard else {
            effectManager.requestVideoEffectActivation(videoID)
            return
        }
        let id = effectID(videoID)
        // A deleted download stays registered, so check the file itself.
        let onDisk = localVideoManager.videoInfo(for: videoID) != nil
            || VideoBackgroundDownloadManager.shared.isDownloaded(videoID)
        if onDisk, effectManager.effect(withId: id) != nil {
            if area == .sidebar { sidebarEffectID = id } else { keyboardEffectID = id }
        } else if let remote = videoManager.remoteVideo(for: videoID) {
            VideoBackgroundDownloadManager.shared.startDownload(for: remote)
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    showVideoFileImporter = true
                } label: {
                    Label(localVideoManager.localVideos.isEmpty ? LocalizedStringKey("Choose Local Video…") : LocalizedStringKey("Add Another Video…"),
                          systemImage: "folder.badge.plus")
                }
                .disabled(isImportingVideo)
                .themedRow()

                PhotosPicker(selection: $selectedPhotosVideoItem, matching: .videos, preferredItemEncoding: .current) {
                    HStack {
                        Label("Choose from Photos…", systemImage: "photo.on.rectangle.angled")
                        if isImportingVideo {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isImportingVideo)
                .themedRow()
                .onChange(of: selectedPhotosVideoItem) { _, newItem in
                    guard let newItem else { return }
                    handlePhotosVideoImport(item: newItem)
                }

                ForEach(localVideoManager.localVideos) { video in
                    LocalVideoBackgroundRow(video: video, isActive: selectedID == effectID(video.id)) {
                        select(video.id)
                    }
                    .themedRow()
                }

                if let videoImportError {
                    Label(videoImportError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .themedRow()
                }
            } header: {
                Text("My Videos")
            } footer: {
                Text("Import an MP4 (H.264 or HEVC) or MOV file. Looping works best when the first and last frames match. Audio tracks are ignored.")
            }
            .fileImporter(isPresented: $showVideoFileImporter,
                          allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                          allowsMultipleSelection: false) { result in
                handleVideoImport(result: result)
            }

            Section {
                if videoManager.isLoadingIndex && videoManager.remoteVideos.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading available videos...")
                            .foregroundStyle(.secondary)
                    }
                    .themedRow()
                } else if let error = videoManager.indexError, videoManager.remoteVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Failed to load videos", systemImage: "exclamationmark.triangle")
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await videoManager.fetchRemoteIndex() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                    .themedRow()
                } else if videoManager.remoteVideos.isEmpty {
                    Text("No video backgrounds available")
                        .foregroundStyle(.secondary)
                        .themedRow()
                } else {
                    ForEach(videoManager.remoteVideos) { video in
                        VideoBackgroundRow(video: video,
                                           isActive: selectedID == effectID(video.id),
                                           isPending: area == .terminal && effectManager.pendingVideoActivation == video.id,
                                           canDelete: !videosInUse.contains(effectID(video.id))) {
                            select(video.id)
                        }
                        .themedRow()
                    }
                }
            } header: {
                Text("Video Backgrounds")
            } footer: {
                if area == .terminal {
                    Text("The terminal keeps its current effect until a video finishes downloading.")
                } else {
                    Text("Download a video first, then choose it here.")
                }
            }
        }
        .themedList()
        .navigationTitle("Video Background")
        .navigationBarTitleDisplayMode(.inline)
        .task { await videoManager.fetchRemoteIndex() }
    }

    // MARK: Import

    /// Importing only registers the video; it goes to the area being edited.
    private func finishImport(_ entry: LocalVideoBackground) {
        select(entry.id)
    }

    private func handleVideoImport(result: Result<[URL], Error>) {
        videoImportError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImportingVideo = true
            Task {
                defer { isImportingVideo = false }
                do {
                    finishImport(try await localVideoManager.importVideo(from: url))
                } catch {
                    videoImportError = error.localizedDescription
                }
            }
        case .failure(let error):
            videoImportError = error.localizedDescription
        }
    }

    private func handlePhotosVideoImport(item: PhotosPickerItem) {
        videoImportError = nil
        isImportingVideo = true
        Task {
            defer {
                isImportingVideo = false
                selectedPhotosVideoItem = nil
            }
            do {
                guard let transferable = try await item.loadTransferable(type: PhotosVideoTransferable.self) else {
                    videoImportError = String(localized: "Could not load selected video.")
                    return
                }
                defer { try? FileManager.default.removeItem(at: transferable.url) }
                finishImport(try await localVideoManager.importVideo(from: transferable.url))
            } catch {
                videoImportError = error.localizedDescription
            }
        }
    }
}


private struct PhotosVideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDir = FileManager.default.temporaryDirectory
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let tempURL = tempDir.appendingPathComponent("photos-video-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.copyItem(at: received.file, to: tempURL)
            return PhotosVideoTransferable(url: tempURL)
        }
    }
}
