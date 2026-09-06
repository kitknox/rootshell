//
//  ConnectionProfileEntityQuery.swift
//  rootshell
//
//  EntityQuery providing profile lookup for Shortcuts parameter UI.
//

import AppIntents

/// Provides profile lookup for Shortcuts entity parameter resolution. The
/// EnumerableEntityQuery conformance also gives Shortcuts the automatic
/// "Find Connection Profiles" action with sort and filter support.
struct ConnectionProfileEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {

    func allEntities() async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.availableProfiles.map { $0.toEntity() }
        }
    }

    func entities(for identifiers: [UUID]) async -> [ConnectionProfileEntity] {
        await MainActor.run {
            identifiers.compactMap { id in
                guard let profile = ConnectionProfileManager.shared.profile(for: id),
                      !profile.isDeleted else { return nil }
                return profile.toEntity()
            }
        }
    }

    func entities(matching string: String) async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.profiles(matching: string)
                .filter { $0.isAvailableOnCurrentPlatform }
                .map { $0.toEntity() }
        }
    }

    func suggestedEntities() async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.getSuggestions(matching: "", limit: 20)
                .map { $0.toEntity() }
        }
    }
}

/// The SSH command action retains ConnectionProfileEntity IDs for existing
/// shortcuts, but restricts every picker and lookup path to SSH transports.
struct SSHConnectionProfileEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async -> [ConnectionProfileEntity] {
        await MainActor.run {
            identifiers.compactMap { id in
                guard let profile = ConnectionProfileManager.shared.profile(for: id),
                      !profile.isDeleted, profile.isSSHBased else { return nil }
                return profile.toEntity()
            }
        }
    }

    func entities(matching string: String) async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.profiles(matching: string)
                .filter { $0.isSSHBased }
                .map { $0.toEntity() }
        }
    }

    func suggestedEntities() async -> [ConnectionProfileEntity] {
        await MainActor.run {
            ConnectionProfileManager.shared.profiles
                .filter { $0.isSSHBased }
                .map { $0.toEntity() }
        }
    }
}
