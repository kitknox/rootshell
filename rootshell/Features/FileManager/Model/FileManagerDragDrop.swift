//
//  FileManagerDragDrop.swift
//  rootshell
//
//  Drag and drop for the file manager. Pane-to-pane drags carry the source
//  pane in the model, so they queue a normal transfer. Files dragged out are
//  offered as real files (remote ones download on demand); files dropped in
//  from Files or Finder, or pasted from the clipboard, are staged locally,
//  then copied like any transfer.
//

import UIKit
import UniformTypeIdentifiers

enum FileManagerDragDrop {
    static let acceptedTypes: [UTType] = [.fileURL, .item]

    /// Drop staging under Caches; the providers' own copies vanish when their handler returns.
    static let stagingRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("FileManagerDrops", isDirectory: true)
    }()
}

extension FileManagerModel {
    struct DragPayload {
        let side: FilePaneModel.Side
        let endpoint: FileEndpoint
        let sources: [TransferJob.Source]
        let startedAt = Date()
    }

    func beginDrag(of entries: [RFEntry], from side: FilePaneModel.Side) -> NSItemProvider {
        let pane = pane(side)
        dragPayload = DragPayload(
            side: side,
            endpoint: pane.endpoint,
            sources: entries.map { TransferJob.Source(path: $0.path, isDirectory: $0.isDirectory) }
        )
        guard let first = entries.first else { return NSItemProvider() }

        let provider = NSItemProvider()
        provider.suggestedName = first.name
        if pane.endpoint.isLocal, !first.isDirectory {
            let url = URL(fileURLWithPath: LocalPathResolver.current().resolve(first.path))
            guard let fileProvider = NSItemProvider(contentsOf: url) else { return provider }
            // handleDrop recognizes a pane-to-pane drag by this name.
            fileProvider.suggestedName = first.name
            return fileProvider
        }
        guard !first.isDirectory else { return provider }
        let type = UTType(filenameExtension: first.fileExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    let url = try await FileManagerPreviewCache.localURL(for: first, fs: try await pane.fileSystem(purpose: .transfer))
                    progress.completedUnitCount = 1
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    /// Queues a copy for a drop onto `side` (or into `directory` within it).
    func handleDrop(_ providers: [NSItemProvider], onto side: FilePaneModel.Side, directory: String?) -> Bool {
        // A drag abandoned mid-way leaves a payload behind; only trust it for the drop it names.
        if let payload = dragPayload,
           Date().timeIntervalSince(payload.startedAt) < 600,
           let first = payload.sources.first,
           providers.first?.suggestedName == FileTransferLogic.lastComponent(of: first.path) {
            dragPayload = nil
            let target = directory ?? pane(side).path
            // Dropping a folder into itself, or back onto its own listing, is a no-op.
            guard !(payload.side == side && directory == nil),
                  !payload.sources.contains(where: { $0.isDirectory != false && $0.path.utf8.elementsEqual(target.utf8) }) else { return false }
            activeSide = side
            receive(sources: payload.sources, from: payload.endpoint, into: side, directory: target)
            return true
        }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.item.identifier) }
        guard !fileProviders.isEmpty else { return false }
        stageAndReceive(fileProviders, onto: side, directory: directory, stage: Self.stage)
        return true
    }

    /// Uploads the files among `providers` into `side`; false when none of them is a file,
    /// so a text paste can fall through to the filter field.
    @discardableResult
    func paste(_ providers: [NSItemProvider], into side: FilePaneModel.Side, directory: String?) -> Bool {
        let fileProviders = providers.filter { Self.isPastedFile($0) }
        guard !fileProviders.isEmpty else { return false }
        let pane = pane(side)
        guard !pane.path.isEmpty else { return true }
        if directory == nil, pane.endpoint.storageProvider != nil, FileTransferLogic.normalize(pane.path) == "/" {
            errorMessage = FileManagerActionError.pasteNeedsBucket.localizedDescription
            return true
        }
        stageAndReceive(fileProviders, onto: side, directory: directory, stage: Self.stagePasted)
        return true
    }

    /// Menu paste: reading the clipboard outside a paste action may show the system prompt.
    func pasteFromClipboard(into side: FilePaneModel.Side, directory: String?) {
        activeSide = side
        if !paste(UIPasteboard.general.itemProviders, into: side, directory: directory) {
            errorMessage = FileManagerActionError.nothingToPaste.localizedDescription
        }
    }

    private func stageAndReceive(
        _ providers: [NSItemProvider],
        onto side: FilePaneModel.Side,
        directory: String?,
        stage: @escaping @MainActor (NSItemProvider, URL) async -> String?
    ) {
        // Staging can be slow; navigating meanwhile must not redirect the copy.
        let pane = pane(side)
        guard let target = directory ?? (pane.path.isEmpty ? nil : pane.path) else { return }
        let endpoint = pane.endpoint
        let staging = FileManagerDragDrop.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        Task {
            var staged: [String] = []
            for provider in providers {
                if let path = await stage(provider, staging) { staged.append(path) }
            }
            if staged.count < providers.count {
                errorMessage = FileManagerActionError.unreadableItems(providers.count - staged.count, of: providers.count).localizedDescription
            }
            guard !staged.isEmpty else { return }
            activeSide = side
            receive(paths: staged, from: .local, into: side, directory: target, destination: endpoint)
        }
    }

    /// A copied file has a file URL or a name. Unnamed items count only without a plain-text
    /// form, since copied rich text can carry a PDF or image preview.
    private static func isPastedFile(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) || provider.suggestedName != nil {
            return true
        }
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        guard !types.contains(where: { $0.conforms(to: .plainText) }) else { return false }
        return provider.canLoadObject(ofClass: UIImage.self) || types.contains {
            $0.conforms(to: .image) || $0.conforms(to: .pdf) || $0.conforms(to: .audiovisualContent)
        }
    }

    /// Stages a clipboard item: the file a copied URL points at, else its best data
    /// representation, else an image object (Catalyst's unnamed com.apple.uikit.image).
    private static func stagePasted(_ provider: NSItemProvider, into folder: URL) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let path = await stageFileURL(provider, into: folder) {
            return path
        }
        if let type = pastedContentType(provider),
           let path = await stageRepresentation(provider, type: type, into: folder) {
            return path
        }
        if provider.canLoadObject(ofClass: UIImage.self) {
            return await stageImageObject(provider, into: folder)
        }
        return nil
    }

    private static func stageFileURL(_ provider: NSItemProvider, into folder: URL) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                continuation.resume(returning: place(into: folder, named: url.lastPathComponent) {
                    try FileManager.default.copyItem(at: url, to: $0)
                })
            }
        }
    }

    /// The document over its previews: the type its name implies, then PDF, then an image.
    private static func pastedContentType(_ provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let named = provider.suggestedName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        return types.first { type in named.map { type.conforms(to: $0) } ?? false }
            ?? types.first { $0.conforms(to: .pdf) }
            ?? types.first { $0.conforms(to: .image) }
            ?? types.first { !$0.conforms(to: .text) && !$0.conforms(to: .url) }
            ?? (provider.suggestedName != nil ? types.first : nil)
    }

    private static func stageRepresentation(_ provider: NSItemProvider, type: UTType, into folder: URL) async -> String? {
        let name = pastedFileName(provider.suggestedName, type: type)
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: place(into: folder, named: name) {
                    try FileManager.default.copyItem(at: url, to: $0)
                })
            }
        }
    }

    private static func stageImageObject(_ provider: NSItemProvider, into folder: URL) async -> String? {
        let name = pastedFileName(provider.suggestedName, type: .png)
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { image, _ in
                guard let data = (image as? UIImage)?.pngData() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: place(into: folder, named: name) { try data.write(to: $0) })
            }
        }
    }

    /// `suggested` (or a timestamp) with an extension that matches the bytes in `type`.
    private nonisolated static func pastedFileName(_ suggested: String?, type: UTType) -> String {
        let name = suggested ?? {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return "paste-\(formatter.string(from: Date()))"
        }()
        guard let ext = type.preferredFilenameExtension else { return name }
        let current = (name as NSString).pathExtension
        guard !current.isEmpty, let named = UTType(filenameExtension: current), !named.isDynamic else {
            return "\(name).\(ext)"
        }
        if type.conforms(to: named) { return name }
        return "\((name as NSString).deletingPathExtension).\(ext)"
    }

    /// Writes into `folder`, adding " 2", " 3"… when the name is taken by an earlier item.
    private nonisolated static func place(into folder: URL, named name: String, write: (URL) throws -> Void) -> String? {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var destination = folder.appendingPathComponent(name)
            var index = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                let candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
                destination = folder.appendingPathComponent(candidate)
                index += 1
            }
            try write(destination)
            return destination.path
        } catch {
            return nil
        }
    }

    /// Copies a dropped file or folder into `folder` while the provider still grants access.
    private static func stage(_ provider: NSItemProvider, into folder: URL) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let destination = folder.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination.path)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
