//
//  ConnectionProfileEntity.swift
//  rootshell
//
//  AppEntity wrapper exposing ConnectionProfile to Shortcuts.
//

import AppIntents

/// Shortcuts-visible entity representing a saved connection profile.
struct ConnectionProfileEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(
            name: "Connection Profile",
            numericFormat: "\(placeholder: .int) connection profiles"
        )
    }

    static var defaultQuery = ConnectionProfileEntityQuery()

    var id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Host")
    var host: String

    @Property(title: "Username")
    var username: String

    @Property(title: "Folder")
    var folderPath: String

    @Property(title: "Protocol")
    var connectionProtocol: String

    @Property(title: "Tags")
    var tags: [String]

    init(id: UUID, name: String, host: String, username: String, folderPath: String, connectionProtocol: String, tags: [String]) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.folderPath = folderPath
        self.connectionProtocol = connectionProtocol
        self.tags = tags
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String
        if username.isEmpty || host.isEmpty {
            subtitle = host
        } else {
            subtitle = "\(username)@\(host)"
        }

        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitle)",
            image: .init(systemName: "terminal")
        )
    }
}

extension ConnectionProfile {
    /// Converts this profile into a Shortcuts-compatible entity.
    func toEntity() -> ConnectionProfileEntity {
        ConnectionProfileEntity(
            id: id,
            name: name,
            host: connectionProtocol == .local ? displayString : sshConfig.host,
            username: sshConfig.username,
            folderPath: folderPath,
            connectionProtocol: connectionProtocol.displayName,
            tags: tags.sorted()
        )
    }
}
