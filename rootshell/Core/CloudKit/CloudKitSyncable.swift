//
//  CloudKitSyncable.swift
//  rootshell
//
//  Protocol for types that can be synced via CloudKit
//

import Foundation
import CloudKit
import Crypto
import os.log

/// Deterministic CloudKit record name helper
enum CloudKitRecordName {
    static func make(recordType: String, identity: String) -> String {
        let data = Data(identity.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(recordType)_\(hex)"
    }

    static func recordType(from recordName: String) -> String? {
        recordName.split(separator: "_", maxSplits: 1).first.map(String.init)
    }
}

/// Protocol for types that can be converted to/from CKRecord
protocol CloudKitSyncable: SyncableRecord {
    /// CloudKit record type name
    static var recordType: String { get }

    /// Current schema version for this record type
    static var schemaVersion: Int { get }

    /// Convert this record to a CKRecord
    func toCKRecord() -> CKRecord

    /// Deterministic record name for this record
    static func recordName(for record: Self) -> String

    /// Apply the record fields to an existing CKRecord (used for conflict resolution)
    func apply(to record: CKRecord)

    /// Create an instance from a CKRecord
    static func from(_ record: CKRecord) -> Self?
}

extension CloudKitSyncable {
    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(for: self),
            zoneID: CloudKitSyncSettings.zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(to: record)
        return record
    }
}

// MARK: - SSHConnectionHistoryEntry + CloudKitSyncable

extension SSHConnectionHistoryEntry: CloudKitSyncable {
    static var recordType: String { "SSHConnectionHistory" }
    /// 2 added the `extensionData` envelope (see `HistoryExtensionPayload`).
    static var schemaVersion: Int { 2 }

    private static let logger = Logger(subsystem: "com.rootshell", category: "CloudKitHistory")

    static func recordName(for record: SSHConnectionHistoryEntry) -> String {
        CloudKitRecordName.make(recordType: recordType, identity: record.connectionIdentity)
    }

    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(for: self),
            zoneID: CloudKitSyncSettings.zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(to: record)
        return record
    }

    func apply(to record: CKRecord) {
        record["entryID"] = id.uuidString
        record["username"] = username
        record["host"] = host
        record["port"] = Int64(port)
        record["lastUsed"] = lastUsed
        record["modifiedAt"] = modifiedAt
        record["isDeleted"] = isDeleted ? 1 : 0
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["deviceID"] = CloudKitSyncSettings.deviceID

        // Auth type as JSON
        if let authData = try? JSONEncoder().encode(authType),
           let authString = String(data: authData, encoding: .utf8) {
            record["authType"] = authString
        }

        // Optional fields
        record["cachedIP"] = cachedIP
        record["jumpHost"] = jumpHost
        record["jumpPort"] = jumpPort.map { Int64($0) }
        record["jumpUsername"] = jumpUsername
        record["hssShorthand"] = hssShorthand

        // Jump auth type as JSON
        if let jumpAuthType = jumpAuthType,
           let jumpAuthData = try? JSONEncoder().encode(jumpAuthType),
           let jumpAuthString = String(data: jumpAuthData, encoding: .utf8) {
            record["jumpAuthType"] = jumpAuthString
        }

        // Agent config as JSON data
        if let agentConfig = agentConfig,
           let agentData = try? JSONEncoder().encode(agentConfig) {
            record["agentConfig"] = agentData
        }

        // GPG agent config as JSON data — separate key from SSH agent
        // forwarding so the two evolve independently. Older records
        // without this field decode as nil and the apply path leaves
        // GPG forwarding off.
        if let gpgAgentConfig = gpgAgentConfig,
           let gpgData = try? JSONEncoder().encode(gpgAgentConfig) {
            record["gpgAgentConfig"] = gpgData
        }

        // Port forward config as JSON data
        if let portForwardConfig = portForwardConfig,
           let pfData = try? JSONEncoder().encode(portForwardConfig) {
            record["portForwardConfig"] = pfData
        }

        // tmux auto-enable
        if let tmuxAutoEnable = tmuxAutoEnable {
            record["tmuxAutoEnable"] = tmuxAutoEnable ? 1 : 0
        }

        // tmux launch mode (regular vs control/-CC), stored as the enum
        // rawValue. Additive field — older records and older app versions
        // simply omit/ignore it.
        if let tmuxAutoMode = tmuxAutoMode {
            record["tmuxAutoMode"] = tmuxAutoMode.rawValue
        }

        // herdr auto-enable. Additive field — older records and older app
        // versions simply omit/ignore it.
        if let herdrAutoEnable = herdrAutoEnable {
            record["herdrAutoEnable"] = herdrAutoEnable ? 1 : 0
        }

        // Launch command
        record["launchCommand"] = launchCommand
        record["launchCommandMode"] = launchCommandMode?.rawValue

        // Extension envelope. Always written, never omitted when empty: it
        // carries this build's `currentVersion`, which is what tells a receiving
        // device which members the writer knew. A nil member means the user
        // cleared it only when the stamped version is at least the version that
        // introduced that member.
        // zmxAutoEnable rides the envelope rather than getting its own record
        // field like `herdrAutoEnable` above. That inconsistency is deliberate:
        // a new top-level field costs a production CloudKit schema deploy, which
        // an outside contributor cannot perform, and the envelope exists
        // precisely so later fields do not.
        let envelope = HistoryExtensionPayload(terminalType: terminalType,
                                               multiplexerSessionName: multiplexerSessionName,
                                               zmxAutoEnable: zmxAutoEnable)
        if let envelopeData = try? JSONEncoder().encode(envelope) {
            record["extensionData"] = envelopeData
        } else {
            record["extensionData"] = nil as Data?
        }

        // Connection protocol
        if let connectionProtocol = connectionProtocol {
            record["connectionProtocol"] = connectionProtocol.rawValue
        }
    }

    static func from(_ record: CKRecord) -> SSHConnectionHistoryEntry? {
        guard let entryIDString = record["entryID"] as? String,
              let entryID = UUID(uuidString: entryIDString),
              let username = record["username"] as? String,
              let host = record["host"] as? String,
              let portInt64 = record["port"] as? Int64 else {
            return nil
        }

        let port = Int(portInt64)

        // Auth type from JSON
        var authType: SSHAuthType = .password
        if let authString = record["authType"] as? String,
           let authData = authString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SSHAuthType.self, from: authData) {
            authType = decoded
        }

        let lastUsed = record["lastUsed"] as? Date ?? Date()
        let fieldModifiedAt = record["modifiedAt"] as? Date ?? lastUsed
        let modifiedAt = record.modificationDate ?? fieldModifiedAt
        let isDeleted = (record["isDeleted"] as? Int64 ?? 0) == 1

        // Optional fields
        let cachedIP = record["cachedIP"] as? String
        let jumpHost = record["jumpHost"] as? String
        let jumpPort = (record["jumpPort"] as? Int64).map { Int($0) }
        let jumpUsername = record["jumpUsername"] as? String
        let hssShorthand = record["hssShorthand"] as? String

        // Jump auth type from JSON
        var jumpAuthType: SSHAuthType?
        if let jumpAuthString = record["jumpAuthType"] as? String,
           let jumpAuthData = jumpAuthString.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SSHAuthType.self, from: jumpAuthData) {
            jumpAuthType = decoded
        }

        // Agent config from JSON data
        var agentConfig: SSHAgentConfig?
        if let agentData = record["agentConfig"] as? Data {
            agentConfig = try? JSONDecoder().decode(SSHAgentConfig.self, from: agentData)
        }

        // GPG agent config from JSON data — nil for older records
        // without the field.
        var gpgAgentConfig: GPGAgentConfig?
        if let gpgData = record["gpgAgentConfig"] as? Data {
            gpgAgentConfig = try? JSONDecoder().decode(GPGAgentConfig.self, from: gpgData)
        }

        // Port forward config from JSON data
        var portForwardConfig: PortForwardConfig?
        if let pfData = record["portForwardConfig"] as? Data {
            portForwardConfig = try? JSONDecoder().decode(PortForwardConfig.self, from: pfData)
        }

        // tmux auto-enable
        let tmuxAutoEnable: Bool? = (record["tmuxAutoEnable"] as? Int64).map { $0 == 1 }

        // tmux launch mode (nil for older records → applied as regular)
        let tmuxAutoMode = (record["tmuxAutoMode"] as? String).flatMap { TmuxAutoMode(rawValue: $0) }

        // herdr auto-enable
        let herdrAutoEnable: Bool? = (record["herdrAutoEnable"] as? Int64).map { $0 == 1 }

        // Launch command
        let launchCommand = record["launchCommand"] as? String
        let launchCommandModeRaw = record["launchCommandMode"] as? String
        let launchCommandMode = launchCommandModeRaw.flatMap { SSHConfig.LaunchCommandMode(rawValue: $0) }

        // Extension envelope (absent on records from devices that predate it).
        // A malformed envelope is treated as absent rather than sinking the
        // whole history entry.
        var extensionPayload: HistoryExtensionPayload?
        if let envelopeData = record["extensionData"] as? Data {
            extensionPayload = try? JSONDecoder().decode(HistoryExtensionPayload.self, from: envelopeData)
            if extensionPayload == nil {
                logger.error("Failed to decode extension payload for history entry '\(host)'")
            }
        }

        // Connection protocol
        let connectionProtocolRaw = record["connectionProtocol"] as? String
        let connectionProtocol = connectionProtocolRaw.flatMap { ConnectionProtocol(rawValue: $0) }

        var entry = SSHConnectionHistoryEntry(
            id: entryID,
            username: username,
            host: host,
            port: port,
            authType: authType,
            connectionProtocol: connectionProtocol,
            jumpHost: jumpHost,
            jumpPort: jumpPort,
            jumpUsername: jumpUsername,
            jumpAuthType: jumpAuthType,
            lastUsed: lastUsed,
            cachedIP: cachedIP,
            hssShorthand: hssShorthand,
            agentConfig: agentConfig,
            gpgAgentConfig: gpgAgentConfig,
            portForwardConfig: portForwardConfig,
            tmuxAutoEnable: tmuxAutoEnable,
            tmuxAutoMode: tmuxAutoMode,
            herdrAutoEnable: herdrAutoEnable,
            zmxAutoEnable: extensionPayload?.zmxAutoEnable,
            launchCommand: launchCommand,
            launchCommandMode: launchCommandMode,
            terminalType: extensionPayload?.terminalType,
            multiplexerSessionName: extensionPayload?.multiplexerSessionName,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted
        )
        // Records the envelope's presence and the version the writer stamped,
        // so the merge can distinguish a cleared override from a writer that
        // predates the envelope (nil version) or predates an individual member
        // added in a later version.
        entry.syncCarriedExtensions = extensionPayload != nil
        entry.syncEnvelopeVersion = extensionPayload?.version
        return entry
    }
}

// MARK: - KnownHost + CloudKitSyncable

extension KnownHost: CloudKitSyncable {
    static var recordType: String { "KnownHost" }
    static var schemaVersion: Int { 1 }

    static func recordName(for record: KnownHost) -> String {
        CloudKitRecordName.make(recordType: recordType, identity: record.legacyId)
    }

    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(for: self),
            zoneID: CloudKitSyncSettings.zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(to: record)
        return record
    }

    func apply(to record: CKRecord) {
        record["hostID"] = id.uuidString
        record["legacyId"] = legacyId
        record["hostname"] = hostname
        record["port"] = Int64(port)
        record["publicKeyData"] = publicKeyData
        record["keyType"] = keyType
        record["fingerprint"] = fingerprint
        record["firstSeen"] = firstSeen
        record["lastSeen"] = lastSeen
        record["modifiedAt"] = modifiedAt
        record["isDeleted"] = isDeleted ? 1 : 0
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["deviceID"] = CloudKitSyncSettings.deviceID
    }

    static func from(_ record: CKRecord) -> KnownHost? {
        guard let hostIDString = record["hostID"] as? String,
              let hostID = UUID(uuidString: hostIDString),
              let hostname = record["hostname"] as? String,
              let portInt64 = record["port"] as? Int64,
              let publicKeyData = record["publicKeyData"] as? String,
              let keyType = record["keyType"] as? String,
              let fingerprint = record["fingerprint"] as? String else {
            return nil
        }

        let port = Int(portInt64)
        let firstSeen = record["firstSeen"] as? Date ?? Date()
        let lastSeen = record["lastSeen"] as? Date ?? firstSeen
        let fieldModifiedAt = record["modifiedAt"] as? Date ?? lastSeen
        let modifiedAt = record.modificationDate ?? fieldModifiedAt
        let isDeleted = (record["isDeleted"] as? Int64 ?? 0) == 1

        return KnownHost(
            id: hostID,
            hostname: hostname,
            port: port,
            publicKeyData: publicKeyData,
            keyType: keyType,
            fingerprint: fingerprint,
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted
        )
    }
}

// MARK: - ConnectionProfile + CloudKitSyncable

extension ConnectionProfile: CloudKitSyncable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "CloudKitProfile")

    static var recordType: String { "ConnectionProfile" }
    static var schemaVersion: Int { 1 }

    static func recordName(for record: ConnectionProfile) -> String {
        // Use UUID as identity since profiles don't have a logical identity like history entries
        CloudKitRecordName.make(recordType: recordType, identity: record.id.uuidString)
    }

    func toCKRecord() -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: Self.recordName(for: self),
            zoneID: CloudKitSyncSettings.zoneID
        )
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        apply(to: record)
        return record
    }

    func apply(to record: CKRecord) {
        record["profileID"] = id.uuidString
        record["name"] = name
        record["notes"] = notes
        record["iconName"] = iconName
        record["colorTag"] = colorTag?.rawValue
        record["folderPath"] = folderPath
        record["tags"] = tags.isEmpty ? nil : Array(tags) as [String]
        record["modifiedAt"] = modifiedAt
        record["isDeleted"] = isDeleted ? 1 : 0
        record["createdAt"] = createdAt
        record["lastUsedAt"] = lastUsedAt
        record["useCount"] = Int64(useCount)
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["deviceID"] = CloudKitSyncSettings.deviceID

        // SSH config as JSON data. VNC and local records deliberately OMIT the blob:
        // old builds decode unknown protocols as `?? .ssh`, and a placeholder
        // sshConfig would materialize there as a corrupt SSH profile. The
        // missing blob instead trips their existing guard and the record is
        // skipped - skip, not break.
        if !isSSHBased {
            record["sshConfig"] = nil as Data?
        } else if let sshData = try? JSONEncoder().encode(sshConfig) {
            record["sshConfig"] = sshData
        }

        // Keep appearance out of the legacy envelope: old clients reconstruct
        // that envelope and erase unknown fields. Theme revisions ride a
        // separate ProfileThemeRecord using the same existing CloudKit schema.
        var connectionPayload = extensionPayload
        connectionPayload?.themeName = nil
        connectionPayload?.themeModifiedAt = nil
        if let connectionPayload, !connectionPayload.isEmpty,
           let envelopeData = try? JSONEncoder().encode(connectionPayload) {
            record["extensionData"] = envelopeData
        } else {
            record["extensionData"] = nil as Data?
        }

        // Connection protocol
        record["connectionProtocol"] = connectionProtocol.rawValue

        // Transport mode
        record["trzszTransportMode"] = trzszTransportMode.rawValue

        // TSSH advanced settings (always write to clear old values when reset to nil)
        record["trzszMTU"] = trzszMTU.map { $0 as CKRecordValue }
        record["trzszPortMin"] = trzszPortMin.map { $0 as CKRecordValue }
        record["trzszPortMax"] = trzszPortMax.map { $0 as CKRecordValue }
        record["trzszServerPath"] = trzszServerPath.map { $0 as CKRecordValue }

        // VPN configuration
        record["vpnEnabled"] = vpnEnabled ? 1 : 0
        record["vpnDNSServers"] = vpnDNSServers.isEmpty ? nil : vpnDNSServers as [String]
        record["vpnExcludedRoutes"] = vpnExcludedRoutes.isEmpty ? nil : vpnExcludedRoutes as [String]
        record["vpnBlockQUIC"] = vpnBlockQUIC ? 1 : 0
    }

    static func from(_ record: CKRecord) -> ConnectionProfile? {
        guard let profileIDString = record["profileID"] as? String,
              let profileID = UUID(uuidString: profileIDString),
              let name = record["name"] as? String else {
            logger.warning("ConnectionProfile missing required fields: profileID or name")
            return nil
        }

        // Connection protocol - parsed BEFORE the sshConfig guard because VNC
        // records omit the sshConfig blob by design. Default to SSH for
        // backward compatibility.
        let connectionProtocolRaw = record["connectionProtocol"] as? String
        let connectionProtocol = connectionProtocolRaw.flatMap { ConnectionProtocol(rawValue: $0) } ?? .ssh

        // Extension envelope (VNC config etc.). Tolerant: a missing or
        // undecodable envelope must not sink the record.
        var extensionPayload: ProfileExtensionPayload?
        if let envelopeData = record["extensionData"] as? Data {
            extensionPayload = try? JSONDecoder().decode(ProfileExtensionPayload.self, from: envelopeData)
            if extensionPayload == nil {
                logger.error("Failed to decode extension payload for profile '\(name)'")
            }
        }

        // SSH config from JSON data with error logging
        var sshConfig: SSHConfig?
        if let sshData = record["sshConfig"] as? Data {
            do {
                sshConfig = try JSONDecoder().decode(SSHConfig.self, from: sshData)
            } catch {
                logger.error("Failed to decode SSHConfig for profile '\(name)': \(error)")
                if let jsonString = String(data: sshData, encoding: .utf8) {
                    logger.debug("Raw sshConfig JSON: \(jsonString)")
                }
            }
        } else if connectionProtocol != .vnc && connectionProtocol != .local {
            logger.warning("ConnectionProfile '\(name)' missing sshConfig data")
        }

        let validSSHConfig: SSHConfig
        if let sshConfig {
            validSSHConfig = sshConfig
        } else if connectionProtocol == .local {
            validSSHConfig = ConnectionProfile.localPlaceholderSSHConfig()
        } else if connectionProtocol == .vnc {
            // VNC records omit sshConfig; synthesize the placeholder from the
            // envelope (or empty when the envelope is missing/undecodable -
            // the profile still materializes, it just can't connect).
            if extensionPayload?.vncConfig == nil {
                logger.warning("VNC profile '\(name)' has no decodable envelope - materializing with placeholder")
            }
            validSSHConfig = ConnectionProfile.vncPlaceholderSSHConfig(for: extensionPayload?.vncConfig)
        } else {
            return nil
        }

        let notes = record["notes"] as? String
        let iconName = record["iconName"] as? String
        let colorTagRaw = record["colorTag"] as? String
        let colorTag = colorTagRaw.flatMap { ProfileColorTag(rawValue: $0) }
        let folderPath = record["folderPath"] as? String ?? ""
        let tagsArray = record["tags"] as? [String] ?? []
        let tags = Set(tagsArray)

        let createdAt = record["createdAt"] as? Date ?? Date()
        let fieldModifiedAt = record["modifiedAt"] as? Date ?? createdAt
        let modifiedAt = record.modificationDate ?? fieldModifiedAt
        let isDeleted = (record["isDeleted"] as? Int64 ?? 0) == 1
        let lastUsedAt = record["lastUsedAt"] as? Date
        let useCount = Int(record["useCount"] as? Int64 ?? 0)

        // Transport mode - default to .default for backward compatibility
        let trzszTransportModeRaw = record["trzszTransportMode"] as? String
        let trzszTransportMode = trzszTransportModeRaw.flatMap { ProfileTransportMode(rawValue: $0) } ?? .default

        // TSSH advanced settings
        let trzszMTU = record["trzszMTU"] as? Int
        let trzszPortMin = record["trzszPortMin"] as? Int
        let trzszPortMax = record["trzszPortMax"] as? Int
        let trzszServerPath = record["trzszServerPath"] as? String

        // VPN configuration
        let vpnEnabled = (record["vpnEnabled"] as? Int64 ?? 0) == 1
        let vpnDNSServers = record["vpnDNSServers"] as? [String] ?? []
        let vpnExcludedRoutes = record["vpnExcludedRoutes"] as? [String] ?? []
        let vpnBlockQUIC = (record["vpnBlockQUIC"] as? Int64 ?? 0) == 1

        return ConnectionProfile(
            id: profileID,
            name: name,
            sshConfig: validSSHConfig,
            connectionProtocol: connectionProtocol,
            trzszTransportMode: trzszTransportMode,
            trzszMTU: trzszMTU,
            trzszPortMin: trzszPortMin,
            trzszPortMax: trzszPortMax,
            trzszServerPath: trzszServerPath,
            notes: notes,
            iconName: iconName,
            colorTag: colorTag,
            folderPath: folderPath,
            tags: tags,
            vpnEnabled: vpnEnabled,
            vpnDNSServers: vpnDNSServers,
            vpnExcludedRoutes: vpnExcludedRoutes,
            vpnBlockQUIC: vpnBlockQUIC,
            modifiedAt: modifiedAt,
            isDeleted: isDeleted,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            extensionPayload: extensionPayload
        )
    }
}

// MARK: - ProfileThemeRecord + CloudKitSyncable

extension ProfileThemeRecord: CloudKitSyncable {
    // Reuse the deployed record type and fields; no CloudKit schema additions.
    static var recordType: String { ConnectionProfile.recordType }
    static var schemaVersion: Int { 1 }

    static func recordName(for record: ProfileThemeRecord) -> String {
        CloudKitRecordName.make(recordType: "ConnectionProfileTheme", identity: record.id.uuidString)
    }

    func apply(to record: CKRecord) {
        // Missing profileID is intentional: every older profile decoder rejects
        // this record before reading the envelope. Its ID is in the opaque data.
        record["profileID"] = nil as String?
        record["name"] = nil as String?
        var wireRecord = self
        wireRecord.syncedRevision = nil
        record["extensionData"] = try? JSONEncoder().encode(wireRecord)
        record["modifiedAt"] = modifiedAt
        record["schemaVersion"] = Int64(Self.schemaVersion)
        record["isDeleted"] = isDeleted ? 1 : 0
    }

    static func from(_ record: CKRecord) -> ProfileThemeRecord? {
        guard record.recordType == recordType,
              let data = record["extensionData"] as? Data,
              var theme = try? JSONDecoder().decode(Self.self, from: data),
              record.recordID.recordName == recordName(for: theme) else { return nil }
        theme.syncedRevision = theme.modifiedAt
        // Use the theme revision, not server modificationDate: an unrelated
        // profile edit or an offline retry must never become a new theme edit.
        return theme
    }
}
