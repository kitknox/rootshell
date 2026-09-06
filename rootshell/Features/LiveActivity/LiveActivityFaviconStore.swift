//
//  LiveActivityFaviconStore.swift
//  rootshell
//
//  Writes favicon PNG images to the app group container so the
//  SessionActivityWidget extension can display ISP and WiFi vendor logos.
//  The main app writes; the widget reads.
//

import Foundation
import os.log

/// Shared favicon store for Live Activity widget icons.
/// Uses the app group container for cross-process access.
nonisolated struct LiveActivityFaviconStore: Sendable {
    private static let logger = Logger(
        subsystem: "com.rootshell", category: "LiveActivityFaviconStore"
    )

    private static let directoryName = "live_activity_favicons"

    /// Well-known favicon slots used by the Live Activity widget.
    enum Slot: String, Sendable {
        case ispFavicon = "isp_favicon.png"
        case wifiFavicon = "wifi_favicon.png"
    }

    private static let appGroupID = AppIdentifiers.defaultAppGroupID

    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    /// Directory URL for writing — creates the directory if needed.
    private static var writeDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        let dir = container.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Directory URL for reading — no side effects.
    private static var readDirectoryURL: URL? {
        guard let container = containerURL else { return nil }
        return container.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Write a favicon PNG to the shared container.
    static func write(slot: Slot, pngData: Data) {
        guard let dir = writeDirectoryURL else {
            logger.error("App group container unavailable for favicon write")
            return
        }
        let fileURL = dir.appendingPathComponent(slot.rawValue)
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            let msg = error.localizedDescription
            logger.error("Failed to write favicon \(slot.rawValue): \(msg)")
        }
    }

    /// Remove a favicon from the shared container.
    static func remove(slot: Slot) {
        guard let dir = readDirectoryURL else { return }
        let fileURL = dir.appendingPathComponent(slot.rawValue)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Read a favicon PNG from the shared container (called by widget).
    static func read(slot: Slot) -> Data? {
        guard let dir = readDirectoryURL else { return nil }
        let fileURL = dir.appendingPathComponent(slot.rawValue)
        return try? Data(contentsOf: fileURL)
    }

    /// Remove all favicons (called on activity end).
    static func removeAll() {
        guard let dir = readDirectoryURL else { return }
        let fm = FileManager.default
        for slot in [Slot.ispFavicon, .wifiFavicon] {
            try? fm.removeItem(at: dir.appendingPathComponent(slot.rawValue))
        }
    }
}
