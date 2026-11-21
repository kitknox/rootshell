//
//  RemoteScreenSnapshotCodec.swift
//  rootshell
//
//  The on-disk form of a saved remote screen: a JPEG and where it came from,
//  sealed with AES-256-GCM. Pure, so the test target can compile it.
//

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One saved screen and the connection it belongs to.
nonisolated struct RemoteScreenSnapshotRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = RemoteScreenSnapshotRecord.currentVersion
    /// The route-aware identity of the computer shown. A profile edited to
    /// point at another computer must not show the old one's screen.
    var endpoint: String
    var capturedAt: Date
    var jpeg: Data
}

nonisolated enum RemoteScreenSnapshotCodec {
    enum CodecError: Error, Equatable {
        case unsupportedVersion(Int)
        case sealFailed
    }

    /// Long edge of a stored snapshot. Enough for a softened full-pane
    /// placeholder; small enough that a file stays a few hundred kilobytes.
    static let maxPixelDimension = 1600
    static let jpegQuality: CGFloat = 0.72

    // MARK: Sealing

    /// `profileID` is authenticated with the ciphertext, so a file renamed to
    /// another profile's name does not open.
    static func seal(
        _ record: RemoteScreenSnapshotRecord,
        profileID: UUID,
        using key: SymmetricKey
    ) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(record)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(profileID))
        guard let combined = box.combined else { throw CodecError.sealFailed }
        return combined
    }

    static func open(
        _ sealed: Data,
        profileID: UUID,
        using key: SymmetricKey
    ) throws -> RemoteScreenSnapshotRecord {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData(profileID))
        let record = try PropertyListDecoder().decode(RemoteScreenSnapshotRecord.self, from: plaintext)
        guard record.version == RemoteScreenSnapshotRecord.currentVersion else {
            throw CodecError.unsupportedVersion(record.version)
        }
        return record
    }

    private static func associatedData(_ profileID: UUID) -> Data {
        Data("rootshell.remote-screen-snapshot.\(profileID.uuidString)".utf8)
    }

    // MARK: Images

    /// Fits `width` x `height` inside `maxDimension` without upscaling.
    static func scaledSize(width: Int, height: Int, maxDimension: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxDimension > 0 else { return (0, 0) }
        let longEdge = max(width, height)
        guard longEdge > maxDimension else { return (width, height) }
        let scale = Double(maxDimension) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static func encodeJPEG(_ image: CGImage, quality: CGFloat = jpegQuality) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decodes straight to `maxPixelDimension` when given, so a list
    /// thumbnail never inflates the full picture.
    static func decodeImage(_ jpeg: Data, maxPixelDimension: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        guard let maxPixelDimension else {
            return CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
        ] as CFDictionary)
    }

    /// A sleeping or curtained display decodes as a black frame, which is
    /// worse than keeping the previous snapshot.
    static func isBlank(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        return (pixels.max() ?? 0) < 8
    }
}
