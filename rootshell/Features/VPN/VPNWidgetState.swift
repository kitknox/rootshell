//
//  VPNWidgetState.swift
//  rootshell
//
//  Lightweight Codable struct written to the app group by the main app,
//  read by the widget extension to display VPN status and available profiles.
//

import Foundation
import os.log

nonisolated struct VPNWidgetState: Codable, Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "VPNWidgetState")
    private static let activeStatuses: Set<String> = ["connecting", "reconnecting", "connected", "disconnecting"]
    private static let downgradeProtectionWindow: TimeInterval = 30

    var status: String              // "disconnected", "connecting", "connected", "disconnecting", "reconnecting"
    var profileID: UUID?
    var profileName: String?
    var host: String?
    var connectedSince: Date?
    var lastUpdated: Date

    static let fileName = "vpn_widget_state.json"

    private static let appGroupID = AppIdentifiers.defaultAppGroupID

    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }

    static func write(_ state: VPNWidgetState) {
        guard let containerURL else {
            logger.error("App group container unavailable for VPNWidgetState write")
            return
        }

        let resolvedState = mergeIncomingState(state)
        let fileURL = containerURL.appendingPathComponent(fileName)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(resolvedState)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            let msg = error.localizedDescription
            logger.error("Failed to write VPNWidgetState: \(msg)")
        }
    }

    static func read() -> VPNWidgetState? {
        guard let containerURL else { return nil }

        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(VPNWidgetState.self, from: data)
    }

    private static func mergeIncomingState(_ incomingState: VPNWidgetState) -> VPNWidgetState {
        guard let existingState = read() else {
            return incomingState
        }

        var mergedState = incomingState
        if mergedState.profileID == nil {
            mergedState.profileID = existingState.profileID
        }
        if mergedState.profileName == nil {
            mergedState.profileName = existingState.profileName
        }
        if mergedState.host == nil {
            mergedState.host = existingState.host
        }
        if mergedState.connectedSince == nil, mergedState.status == "connected" {
            mergedState.connectedSince = existingState.connectedSince
        }

        guard mergedState.profileID == existingState.profileID else {
            return mergedState
        }

        let writeAge = incomingState.lastUpdated.timeIntervalSince(existingState.lastUpdated)
        let recentlyUpdated = writeAge >= 0 && writeAge <= downgradeProtectionWindow
        if recentlyUpdated,
           existingState.status == "connected",
           mergedState.status == "connecting" || mergedState.status == "reconnecting" {
            mergedState.status = "connected"
            mergedState.connectedSince = existingState.connectedSince ?? mergedState.connectedSince
            mergedState.lastUpdated = existingState.lastUpdated
        } else if recentlyUpdated,
                  existingState.status == "disconnected",
                  mergedState.status == "disconnecting" {
            mergedState.status = "disconnected"
            mergedState.connectedSince = nil
            mergedState.lastUpdated = existingState.lastUpdated
        } else if activeStatuses.contains(existingState.status),
                  !activeStatuses.contains(mergedState.status),
                  recentlyUpdated,
                  mergedState.status == "disconnected" {
            mergedState.profileID = existingState.profileID
            mergedState.profileName = existingState.profileName
            mergedState.host = existingState.host
        }

        return mergedState
    }
}
