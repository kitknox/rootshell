//
//  PhotoBackgroundEffect.swift
//  rootshell
//
//  Photo background effect with opacity presets, CIFilter support, and Ken Burns animation
//

import UIKit
import SwiftUI
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Opacity Presets

enum PhotoOpacityPreset: String, CaseIterable, Codable {
    case subtle  = "subtle"
    case light   = "light"
    case medium  = "medium"
    case bold    = "bold"
    case vivid   = "vivid"
    case custom  = "custom"

    var intensity: Double {
        switch self {
        case .subtle: return 0.10
        case .light:  return 0.20
        case .medium: return 0.35
        case .bold:   return 0.50
        case .vivid:  return 0.70
        case .custom: return 0.35
        }
    }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .light:  return "Light"
        case .medium: return "Medium"
        case .bold:   return "Bold"
        case .vivid:  return "Vivid"
        case .custom: return "Custom"
        }
    }
}

// MARK: - Image Filters

enum PhotoImageFilter: String, CaseIterable, Codable {
    case none    = "none"
    case noir    = "noir"
    case chrome  = "chrome"
    case fade    = "fade"
    case instant = "instant"
    case mono    = "mono"
    case tonal   = "tonal"
    case blur    = "blur"
    case sepia   = "sepia"

    var displayName: String {
        switch self {
        case .none:    return "None"
        case .noir:    return "Noir"
        case .chrome:  return "Chrome"
        case .fade:    return "Fade"
        case .instant: return "Instant"
        case .mono:    return "Mono"
        case .tonal:   return "Tonal"
        case .blur:    return "Blur"
        case .sepia:   return "Sepia"
        }
    }

    var ciFilterName: String? {
        switch self {
        case .none:    return nil
        case .noir:    return "CIPhotoEffectNoir"
        case .chrome:  return "CIPhotoEffectChrome"
        case .fade:    return "CIPhotoEffectFade"
        case .instant: return "CIPhotoEffectInstant"
        case .mono:    return "CIPhotoEffectMono"
        case .tonal:   return "CIPhotoEffectTonal"
        case .blur:    return "CIGaussianBlur"
        case .sepia:   return "CISepiaTone"
        }
    }
}

// MARK: - Stored Photos

/// Metadata for a photo kept in the on-device background history.
struct PhotoBackground: Codable, Identifiable, Hashable {
    let id: String
    let filename: String
    let importedAt: Date
}

private struct PhotoBackgroundStore: Codable {
    var version: Int = 1
    var entries: [String: PhotoBackground] = [:]
}

enum PhotoBackgroundStorageError: LocalizedError {
    case encodingFailed
    case writeFailed(String)
    case deletionFailed(String)
    case deletionCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not process the selected photo."
        case .writeFailed(let detail):
            return "Could not save the selected photo: \(detail)"
        case .deletionFailed(let detail):
            return "Could not delete the photo: \(detail)"
        case .deletionCleanupFailed(let detail):
            return "The photo was removed from history, but its temporary file could not be cleaned up: \(detail)"
        }
    }
}

// MARK: - PhotoBackgroundEffect

final class PhotoBackgroundEffect: TerminalEffect, ObservableObject {

    // MARK: - TerminalEffect Protocol

    let id = "photoBackground"
    let displayName = "Photo"
    let previewIcon = "photo.fill"
    let effectDescription = "Use a photo as terminal background"

    var intensity: Double = 0.35 {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var speed: Double = 1.0 {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var themeColors: EffectThemeColors = .defaults {
        didSet {
            if themeTintEnabled && themeColors != oldValue {
                applyFilter()
            }
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    let configurationDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Photo-Specific Properties

    var opacityPreset: PhotoOpacityPreset = .medium {
        didSet {
            if opacityPreset != .custom {
                intensity = opacityPreset.intensity
            }
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var imageFilter: PhotoImageFilter = .none {
        didSet {
            applyFilter()
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var kenBurnsEnabled: Bool = false {
        didSet {
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var themeTintEnabled: Bool = false {
        didSet {
            applyFilter()
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    var themeTintAmount: Double = 0.6 {
        didSet {
            if themeTintEnabled {
                applyFilter()
            }
            objectWillChange.send()
            configurationDidChange.send()
        }
    }

    private(set) var originalImage: UIImage?
    private(set) var filteredImage: UIImage?

    /// Photos are newest-first so the most recently imported backgrounds stay
    /// within easy reach in Settings.
    private(set) var photos: [PhotoBackground] = []
    private(set) var selectedPhotoID: String?

    var hasPhoto: Bool { selectedPhotoID != nil }

    private lazy var ciContext = CIContext()
    private var store = PhotoBackgroundStore()

    // MARK: - Storage

    private static var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("PhotoBackground", isDirectory: true)
    }

    private static var legacyPhotoFileURL: URL {
        storageDirectory.appendingPathComponent("photo_background.jpg")
    }

    private static var indexURL: URL {
        storageDirectory.appendingPathComponent("photo_index.json")
    }

    private static var thumbnailsDirectory: URL {
        storageDirectory.appendingPathComponent("thumbnails", isDirectory: true)
    }

    private static func thumbnailURL(for id: String) -> URL {
        thumbnailsDirectory.appendingPathComponent("\(id).jpg")
    }

    // MARK: - Initialization

    init() {
        loadPhotoLibrary()
    }

    // MARK: - Photo Management

    func savePhoto(_ image: UIImage) throws {
        let maxDimension: CGFloat
        #if os(visionOS)
        maxDimension = 3840
        #else
        maxDimension = max(
            UIScreen.main.bounds.width * UIScreen.main.scale,
            UIScreen.main.bounds.height * UIScreen.main.scale
        )
        #endif
        let resized = image.resizedToFit(maxDimension: maxDimension)

        let directory = Self.storageDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Self.thumbnailsDirectory, withIntermediateDirectories: true)
        } catch {
            throw PhotoBackgroundStorageError.writeFailed(error.localizedDescription)
        }

        guard let data = resized.jpegData(compressionQuality: 0.85) else {
            throw PhotoBackgroundStorageError.encodingFailed
        }

        let id = UUID().uuidString
        let entry = PhotoBackground(id: id, filename: "\(id).jpg", importedAt: .now)
        let destination = directory.appendingPathComponent(entry.filename)
        let thumbnailDestination = Self.thumbnailURL(for: id)

        let thumbnail = resized.resizedToFit(maxDimension: 240)
        guard let thumbnailData = thumbnail.jpegData(compressionQuality: 0.8) else {
            throw PhotoBackgroundStorageError.encodingFailed
        }

        do {
            try data.write(to: destination, options: .atomic)
            try thumbnailData.write(to: thumbnailDestination, options: .atomic)
            store.entries[id] = entry
            try saveIndex()
        } catch {
            store.entries.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: thumbnailDestination)
            throw PhotoBackgroundStorageError.writeFailed(error.localizedDescription)
        }

        refreshPhotos()
        selectedPhotoID = id
        originalImage = resized
        applyFilter()
        objectWillChange.send()
        configurationDidChange.send()
    }

    /// Compatibility entry point for configurations written before photo
    /// history existed. Initialization performs the actual migration/load.
    func loadStoredPhoto() {
        guard selectedPhotoID == nil else { return }
        selectedPhotoID = photos.first?.id
    }

    func removePhoto() throws {
        guard let selectedPhotoID else { return }
        try removePhoto(id: selectedPhotoID)
    }

    func removePhoto(id: String) throws {
        guard let entry = store.entries[id] else { return }

        var updatedStore = store
        updatedStore.entries.removeValue(forKey: id)

        let transactionID = UUID().uuidString
        let fileManager = FileManager.default
        let sourceFiles = [
            (role: "full", url: Self.storageDirectory.appendingPathComponent(entry.filename)),
            (role: "thumbnail", url: Self.thumbnailURL(for: id))
        ]
        var stagedFiles: [(original: URL, staged: URL)] = []

        do {
            for sourceFile in sourceFiles where fileManager.fileExists(atPath: sourceFile.url.path) {
                let stagedURL = Self.storageDirectory.appendingPathComponent(
                    ".photo-delete-\(transactionID)-\(sourceFile.role)-\(sourceFile.url.lastPathComponent)"
                )
                try fileManager.moveItem(at: sourceFile.url, to: stagedURL)
                stagedFiles.append((sourceFile.url, stagedURL))
            }
            try saveIndex(updatedStore)
        } catch {
            var rollbackFailures: [String] = []
            for file in stagedFiles.reversed() {
                do {
                    try fileManager.moveItem(at: file.staged, to: file.original)
                } catch {
                    rollbackFailures.append(error.localizedDescription)
                }
            }

            var detail = error.localizedDescription
            if !rollbackFailures.isEmpty {
                detail += " Recovery also failed: \(rollbackFailures.joined(separator: "; "))"
            }
            throw PhotoBackgroundStorageError.deletionFailed(detail)
        }

        // The durable index is now committed, so observable state can follow it.
        store = updatedStore
        refreshPhotos()

        if selectedPhotoID == id {
            // Clear the deleted selection before trying replacements. A corrupt
            // candidate must never leave the deleted ID or image visible.
            selectedPhotoID = nil
            originalImage = nil
            filteredImage = nil
            for photo in photos where selectedPhotoID == nil {
                _ = loadPhoto(id: photo.id)
            }
        }

        objectWillChange.send()
        configurationDidChange.send()

        var cleanupFailures: [String] = []
        for file in stagedFiles {
            do {
                try fileManager.removeItem(at: file.staged)
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }
        if !cleanupFailures.isEmpty {
            throw PhotoBackgroundStorageError.deletionCleanupFailed(
                cleanupFailures.joined(separator: "; ")
            )
        }
    }

    func selectPhoto(id: String) {
        guard store.entries[id] != nil else { return }
        if selectedPhotoID == id, originalImage != nil {
            return
        }
        guard loadPhoto(id: id) else { return }
        objectWillChange.send()
        configurationDidChange.send()
    }

    /// Loads a small persisted thumbnail without blocking the main actor. Older
    /// history entries get their thumbnail generated directly from Image I/O,
    /// avoiding a full-resolution UIKit decode.
    func thumbnailData(for photo: PhotoBackground) async -> Data? {
        let sourceURL = Self.storageDirectory.appendingPathComponent(photo.filename)
        let thumbnailURL = Self.thumbnailURL(for: photo.id)
        return await Task.detached(priority: .utility) {
            PhotoBackgroundThumbnailGenerator.loadOrGenerate(
                sourceURL: sourceURL,
                thumbnailURL: thumbnailURL
            )
        }.value
    }

    /// Decode the selected full-resolution image only when the photo effect is
    /// actually about to be displayed.
    func loadSelectedPhotoIfNeeded() {
        guard originalImage == nil else { return }

        let preferredID = selectedPhotoID
        selectedPhotoID = nil
        filteredImage = nil

        if let preferredID, loadPhoto(id: preferredID) {
            return
        }
        for photo in photos where selectedPhotoID == nil {
            _ = loadPhoto(id: photo.id)
        }
    }

    private func loadPhotoLibrary() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: Self.storageDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: Self.thumbnailsDirectory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.indexURL),
           let decoded = try? decoder.decode(PhotoBackgroundStore.self, from: data) {
            store = decoded
        }

        var indexChanged = false
        var missingIDs: [String] = []
        for (id, entry) in store.entries {
            let fileURL = Self.storageDirectory.appendingPathComponent(entry.filename)
            if !fileManager.fileExists(atPath: fileURL.path) {
                missingIDs.append(id)
            }
        }
        for id in missingIDs {
            store.entries.removeValue(forKey: id)
            indexChanged = true
        }

        // Adopt the single image used by older versions without copying it.
        if store.entries.isEmpty,
           fileManager.fileExists(atPath: Self.legacyPhotoFileURL.path) {
            let id = UUID().uuidString
            let attributes = try? fileManager.attributesOfItem(atPath: Self.legacyPhotoFileURL.path)
            let importedAt = attributes?[.modificationDate] as? Date ?? .now
            store.entries[id] = PhotoBackground(
                id: id,
                filename: Self.legacyPhotoFileURL.lastPathComponent,
                importedAt: importedAt
            )
            indexChanged = true
        }

        if indexChanged {
            try? saveIndex()
        }

        refreshPhotos()
        selectedPhotoID = photos.first?.id
    }

    private func refreshPhotos() {
        photos = store.entries.values.sorted { $0.importedAt > $1.importedAt }
    }

    @discardableResult
    private func loadPhoto(id: String) -> Bool {
        guard let entry = store.entries[id] else { return false }
        let fileURL = Self.storageDirectory.appendingPathComponent(entry.filename)
        guard let image = UIImage(contentsOfFile: fileURL.path) else { return false }
        selectedPhotoID = id
        originalImage = image
        applyFilter()
        return true
    }

    private func saveIndex(_ storeToSave: PhotoBackgroundStore? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(storeToSave ?? store)
        try data.write(to: Self.indexURL, options: .atomic)
    }

    // MARK: - Filter Application

    private func applyFilter() {
        guard let original = originalImage else {
            filteredImage = nil
            return
        }

        // Unfiltered photos skip Core Image so launch never initializes Metal here.
        if imageFilter.ciFilterName == nil && !themeTintEnabled {
            filteredImage = original
            return
        }

        guard var ciImage = CIImage(image: original) else {
            filteredImage = original
            return
        }

        let sourceExtent = ciImage.extent

        if let filterName = imageFilter.ciFilterName,
           let filter = CIFilter(name: filterName) {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            if imageFilter == .blur {
                filter.setValue(10.0, forKey: kCIInputRadiusKey)
            }
            if imageFilter == .sepia {
                filter.setValue(0.8, forKey: kCIInputIntensityKey)
            }
            if let output = filter.outputImage {
                ciImage = output
            }
        }

        if themeTintEnabled,
           let tintFilter = ThemePaletteCube.makeFilter(
                themeColors: themeColors,
                amount: themeTintAmount
           ) {
            tintFilter.setValue(ciImage, forKey: kCIInputImageKey)
            if let tinted = tintFilter.outputImage {
                ciImage = tinted
            }
        }

        let cropped = ciImage.cropped(to: sourceExtent)

        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else {
            filteredImage = original
            return
        }

        filteredImage = UIImage(cgImage: cgImage, scale: original.scale, orientation: original.imageOrientation)
    }

    // MARK: - TerminalEffect Methods

    func createEffectView() -> AnyView {
        loadSelectedPhotoIfNeeded()
        return AnyView(PhotoBackgroundView(effect: self))
    }

    func resetToDefaults() {
        intensity = 0.35
        speed = 1.0
        opacityPreset = .medium
        imageFilter = .none
        kenBurnsEnabled = false
        themeTintEnabled = false
        themeTintAmount = 0.6
    }

    func encodeConfiguration() -> [String: Any] {
        var configuration: [String: Any] = [
            "intensity": intensity,
            "speed": speed,
            "opacityPreset": opacityPreset.rawValue,
            "imageFilter": imageFilter.rawValue,
            "kenBurnsEnabled": kenBurnsEnabled,
            "themeTintEnabled": themeTintEnabled,
            "themeTintAmount": themeTintAmount,
            "hasPhoto": hasPhoto
        ]
        if let selectedPhotoID {
            configuration["selectedPhotoID"] = selectedPhotoID
        }
        return configuration
    }

    func decodeConfiguration(_ data: [String: Any]) {
        if let intensity = data["intensity"] as? Double {
            self.intensity = max(0, min(1, intensity))
        }
        if let speed = data["speed"] as? Double {
            self.speed = max(0.25, min(2.0, speed))
        }
        if let presetRaw = data["opacityPreset"] as? String,
           let preset = PhotoOpacityPreset(rawValue: presetRaw) {
            self.opacityPreset = preset
        }
        if let filterRaw = data["imageFilter"] as? String,
           let filter = PhotoImageFilter(rawValue: filterRaw) {
            self.imageFilter = filter
        }
        if let kenBurns = data["kenBurnsEnabled"] as? Bool {
            self.kenBurnsEnabled = kenBurns
        }
        if let tintAmount = data["themeTintAmount"] as? Double {
            self.themeTintAmount = max(0, min(1, tintAmount))
        }
        if let tintEnabled = data["themeTintEnabled"] as? Bool {
            self.themeTintEnabled = tintEnabled
        }
        if let selectedPhotoID = data["selectedPhotoID"] as? String,
           store.entries[selectedPhotoID] != nil {
            if self.selectedPhotoID != selectedPhotoID {
                originalImage = nil
                filteredImage = nil
            }
            self.selectedPhotoID = selectedPhotoID
        } else if data["hasPhoto"] as? Bool == true {
            loadStoredPhoto()
        }
    }
}

// MARK: - Thumbnail Generation

private nonisolated enum PhotoBackgroundThumbnailGenerator {
    static func loadOrGenerate(sourceURL: URL, thumbnailURL: URL) -> Data? {
        if let data = try? Data(contentsOf: thumbnailURL) {
            return data
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let properties = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, thumbnail, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let result = data as Data
        try? FileManager.default.createDirectory(
            at: thumbnailURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? result.write(to: thumbnailURL, options: .atomic)
        return result
    }
}

// MARK: - UIImage Extension

private extension UIImage {
    func resizedToFit(maxDimension: CGFloat) -> UIImage {
        let currentMax = max(size.width, size.height)
        guard currentMax > maxDimension else { return self }

        let scale = maxDimension / currentMax
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
