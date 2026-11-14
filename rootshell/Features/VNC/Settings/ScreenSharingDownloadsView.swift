//
//  ScreenSharingDownloadsView.swift
//  rootshell
//
//  Files left on this device by Screen Sharing's Drag to Download.
//

import SwiftUI
import rootshellVNC

struct ScreenSharingDownloadsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = VNCDownloadStore.shared
    @State private var isExporting = false
    @State private var exportItem: VNCStoredDownload?
    @State private var confirmsClearAll = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "internaldrive")
                    Text("Space Used")
                    Spacer()
                    Text(Self.size(store.totalByteCount))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .themedRow()

                Button(role: .destructive) {
                    confirmsClearAll = true
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(systemName: "trash")
                        Text("Clear All")
                    }
                }
                .disabled(store.downloads.isEmpty)
                .themedRow()
            } footer: {
                Text("Files downloaded with Drag to Download stay in temporary storage until you save or delete them, and the system may remove them when space runs low. Downloads still in progress are not listed and are never cleared.")
            }

            Section {
                if store.downloads.isEmpty {
                    Group {
                        if store.hasLoaded {
                            Text("No Downloads")
                        } else {
                            Text("Loading…")
                        }
                    }
                    .foregroundColor(.secondary)
                    .themedRow()
                } else {
                    ForEach(store.downloads) { download in
                        row(download)
                    }
                }
            } header: {
                Text("Downloads")
            }
        }
        .themedList()
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // The system may have purged temporary files while away.
            if phase == .active {
                Task { await store.refresh() }
            }
        }
        .fileMover(isPresented: $isExporting, file: exportItem?.url) { result in
            if case .success = result, let exportItem {
                store.downloadWasMoved(exportItem)
            }
            Task { await store.refresh() }
        }
        .confirmationDialog(
            "Clear All Downloads?",
            isPresented: $confirmsClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                Task { await store.deleteAll() }
            }
        } message: {
            Text("Deletes every Screen Sharing download stored on this device. Files you already saved elsewhere and the originals on the remote computer are not affected.")
        }
    }

    private func row(_ download: VNCStoredDownload) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: download.isDirectory ? "folder" : "doc")
            VStack(alignment: .leading, spacing: 2) {
                Text(download.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail(download))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                actions(download)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Actions")
        }
        .themedRow()
        .contextMenu { actions(download) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await store.delete(download) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func actions(_ download: VNCStoredDownload) -> some View {
        Button {
            exportItem = download
            isExporting = true
        } label: {
            Label("Save to Files", systemImage: "folder.badge.plus")
        }
        ShareLink(item: download.url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            Task { await store.delete(download) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func detail(_ download: VNCStoredDownload) -> String {
        let size = Self.size(download.byteCount)
        guard let date = download.date else { return size }
        return "\(size) · \(date.formatted(.relative(presentation: .named)))"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
