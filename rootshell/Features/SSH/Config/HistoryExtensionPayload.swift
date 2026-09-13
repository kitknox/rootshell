//
//  HistoryExtensionPayload.swift
//  rootshell
//
//  Versioned envelope for connection-history fields that ride the single
//  opaque CloudKit `extensionData` blob instead of per-field schema additions.
//

import Foundation

/// Versioned envelope holding extension fields for `SSHConnectionHistoryEntry`.
///
/// The `SSHConnectionHistory` record type mirrors every field individually, so
/// each new field used to cost a production CloudKit schema deploy. This is the
/// history-side counterpart of `ProfileExtensionPayload`: adding a field here
/// costs nothing once `extensionData` exists on the record type.
///
/// Decoding is tolerant at field level: a payload written by a newer build
/// (unknown fields, undecodable members) must not sink the envelope, and an
/// undecodable envelope must not sink the history entry (callers decode the
/// whole envelope with `try?`).
///
/// Presence alone is not enough. A record that carries an envelope proves only
/// that the writer knew the fields present in the envelope version it stamped,
/// so a nil member means "explicitly cleared" only when the writer's version is
/// at least the version that introduced that member. A build that predates a
/// member re-encodes the envelope without it, and the merge must keep whatever
/// the receiving device already had rather than reading the gap as a clear.
///
/// So: **bump `currentVersion` whenever a member is added, record the
/// introducing version as a constant beside it, and gate that member's merge on
/// it.** `version` is always stamped by the writing build (`apply(to:)` builds a
/// fresh envelope rather than round-tripping a decoded one), never inherited
/// from the record being replaced.
struct HistoryExtensionPayload: Codable, Hashable, Sendable {
    /// Envelope schema version. Bump on every added member.
    static let currentVersion = 4

    /// Envelope version that introduced `multiplexerSessionName`. Writers below
    /// this predate the field, so their nil is a gap, not a clear.
    static let multiplexerSessionNameVersion = 2

    /// Envelope version that introduced `zmxAutoEnable`. Same rule.
    static let zmxAutoEnableVersion = 3

    /// Envelope version that introduced `herdrAutoMode`. Same rule.
    static let herdrAutoModeVersion = 4

    var version: Int

    /// Per-connection `TERM` override. nil means the connection inherits the
    /// global remote default.
    var terminalType: String?

    /// Per-profile multiplexer session name. nil means the connection uses the
    /// global default for whichever multiplexer auto-start selects.
    var multiplexerSessionName: String?

    /// Whether zmx auto-start is on for this connection.
    ///
    /// Deliberately here rather than as a top-level `CKRecord` field, unlike the
    /// `herdrAutoEnable` line sitting right beside it in `CloudKitSyncable`. A
    /// new top-level field is not free: it needs a production CloudKit schema
    /// deploy, which is exactly the cost this envelope was introduced to stop
    /// paying.
    var zmxAutoEnable: Bool?

    /// herdr launch mode (regular vs control). Rides the envelope for the
    /// same reason `zmxAutoEnable` does.
    var herdrAutoMode: HerdrAutoMode?

    init(
        version: Int = HistoryExtensionPayload.currentVersion,
        terminalType: String? = nil,
        multiplexerSessionName: String? = nil,
        zmxAutoEnable: Bool? = nil,
        herdrAutoMode: HerdrAutoMode? = nil
    ) {
        self.version = version
        self.terminalType = terminalType
        self.multiplexerSessionName = multiplexerSessionName
        self.zmxAutoEnable = zmxAutoEnable
        self.herdrAutoMode = herdrAutoMode
    }

    private enum CodingKeys: String, CodingKey {
        case version, terminalType, multiplexerSessionName, zmxAutoEnable, herdrAutoMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing or unreadable version falls back to the oldest envelope, not
        // the current one: an unknown writer must not be credited with knowing
        // members added after v1, or its silence would read as a clear.
        version = ((try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil) ?? 1
        // Field-level tolerance: a bad member must not sink the envelope.
        terminalType = (try? container.decodeIfPresent(String.self, forKey: .terminalType)) ?? nil
        multiplexerSessionName = (try? container.decodeIfPresent(String.self, forKey: .multiplexerSessionName)) ?? nil
        zmxAutoEnable = (try? container.decodeIfPresent(Bool.self, forKey: .zmxAutoEnable)) ?? nil
        herdrAutoMode = (try? container.decodeIfPresent(HerdrAutoMode.self, forKey: .herdrAutoMode)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(terminalType, forKey: .terminalType)
        try container.encodeIfPresent(multiplexerSessionName, forKey: .multiplexerSessionName)
        try container.encodeIfPresent(zmxAutoEnable, forKey: .zmxAutoEnable)
        try container.encodeIfPresent(herdrAutoMode, forKey: .herdrAutoMode)
    }
}
