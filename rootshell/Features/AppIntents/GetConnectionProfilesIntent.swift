//
//  GetConnectionProfilesIntent.swift
//  rootshell
//
//  Shortcuts action that returns saved connection profiles, filtered by
//  folder, tag, protocol, or name.
//

import AppIntents

/// Shortcuts action: fetch connection profiles for chaining (e.g. Repeat →
/// Open Connection Profile / Run Command over SSH). All filters are
/// optional and combine with AND.
struct GetConnectionProfilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Connection Profiles"
    static var description: IntentDescription = "Returns saved connection profiles, optionally filtered by folder, tag, protocol, or name."
    static var openAppWhenRun = false

    @Parameter(title: "Folder", optionsProvider: FolderOptionsProvider())
    var folder: String?

    @Parameter(title: "Tag", optionsProvider: TagOptionsProvider())
    var tag: String?

    @Parameter(title: "Protocol")
    var connectionProtocol: ConnectionProtocolAppEnum?

    @Parameter(title: "Name Contains")
    var nameContains: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ConnectionProfileEntity]> {
        var results = ConnectionProfileManager.shared.availableProfiles

        if let folder, !folder.isEmpty {
            results = results.filter { $0.folderPath == folder }
        }
        if let tag, !tag.isEmpty {
            results = results.filter { $0.tags.contains(tag) }
        }
        if let connectionProtocol {
            let wanted = connectionProtocol.connectionProtocol
            results = results.filter { $0.connectionProtocol == wanted }
        }
        if let nameContains {
            let needle = nameContains.trimmingCharacters(in: .whitespacesAndNewlines)
            if !needle.isEmpty {
                results = results.filter { $0.name.localizedCaseInsensitiveContains(needle) }
            }
        }

        return .result(value: results.map { $0.toEntity() })
    }

    struct FolderOptionsProvider: DynamicOptionsProvider {
        func results() async throws -> [String] {
            await MainActor.run {
                Set(ConnectionProfileManager.shared.availableProfiles.map { $0.folderPath })
                    .filter { !$0.isEmpty }
                    .sorted()
            }
        }
    }

    struct TagOptionsProvider: DynamicOptionsProvider {
        func results() async throws -> [String] {
            await MainActor.run {
                Set(ConnectionProfileManager.shared.availableProfiles.flatMap { $0.tags })
                    .sorted()
            }
        }
    }
}
