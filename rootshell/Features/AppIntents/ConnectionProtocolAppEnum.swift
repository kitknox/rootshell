//
//  ConnectionProtocolAppEnum.swift
//  rootshell
//
//  Exposes ConnectionProtocol to Shortcuts as an AppEnum.
//

import AppIntents

/// Shortcuts-visible mirror of ConnectionProtocol for filtering profiles.
enum ConnectionProtocolAppEnum: String, AppEnum {
    case local
    case ssh
    case mosh
    case trzsz
    case vnc

    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Connection Protocol")
    }

    /// `appintentsmetadataprocessor` parses this dictionary at build time and
    /// requires an exhaustive literal — it can't evaluate runtime expressions.
    /// English literals match `ConnectionProtocol.displayName`'s switch so
    /// existing `Localizable.xcstrings` translations apply to both call sites.
    nonisolated static var caseDisplayRepresentations: [ConnectionProtocolAppEnum: DisplayRepresentation] {
        [
            .local: "Local Shell",
            .ssh:   "SSH",
            .mosh:  "Roam - mosh compatible",
            .trzsz: "Roam - tssh",
            .vnc:   "Screen Sharing",
        ]
    }

    var connectionProtocol: ConnectionProtocol {
        switch self {
        case .local: return .local
        case .ssh: return .ssh
        case .mosh: return .mosh
        case .trzsz: return .trzsz
        case .vnc: return .vnc
        }
    }
}
