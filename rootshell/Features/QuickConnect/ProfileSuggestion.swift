//
//  ProfileSuggestion.swift
//  rootshell
//
//  Adapter that makes ConnectionProfile conform to QuickConnectSuggestion
//

import Foundation

/// Wrapper that makes ConnectionProfile conform to QuickConnectSuggestion
struct ProfileSuggestion: QuickConnectSuggestion {
    let profile: ConnectionProfile

    var id: UUID { profile.id }
    var sourceType: SuggestionSourceType { .profile }

    /// Display the profile name
    var displayString: String { profile.name }

    /// Complete with the connection string (vnc:// URL for Screen Sharing)
    var completionString: String {
        if profile.connectionProtocol == .local { return profile.name }
        if profile.connectionProtocol == .vnc {
            let config = profile.vncConfig
            let host = config?.host ?? profile.sshConfig.host
            let port = config?.port ?? 5900
            return "vnc://\(host):\(port)"
        }
        let config = profile.sshConfig
        if config.port == 22 {
            return "\(config.username)@\(config.host)"
        } else {
            return "\(config.username)@\(config.host):\(config.port)"
        }
    }

    var detailText: String? {
        var parts: [String] = []

        if profile.connectionProtocol == .local {
            parts.append(profile.displayString)
        }

        // Show protocol if Mosh or Screen Sharing
        if profile.connectionProtocol == .mosh {
            parts.append("Roam")
        } else if profile.connectionProtocol == .vnc {
            parts.append("Screen Sharing")
        }

        // Show folder path if not root
        if !profile.folderPath.isEmpty {
            parts.append(profile.folderPath)
        }

        // Show tags if any
        if !profile.tags.isEmpty {
            let tagList = profile.tags.sorted().prefix(3).joined(separator: ", ")
            if profile.tags.count > 3 {
                parts.append("Tags: \(tagList)...")
            } else {
                parts.append("Tags: \(tagList)")
            }
        }

        // Show jump host indicator
        if profile.sshConfig.usesJumpHost {
            parts.append("via jump host")
        }

        if parts.isEmpty {
            return "Profile"
        }
        return "Profile | " + parts.joined(separator: " | ")
    }

    var sortPriority: Int {
        // Frequently used profiles get higher priority (lower number)
        // Use count first, then recency
        if profile.useCount > 0 {
            return -profile.useCount * 1000
        }
        // If never used, sort by creation date (newer first)
        return Int(-profile.createdAt.timeIntervalSince1970 / 86400)
    }

    func matches(_ searchText: String, mode: MatchingMode) -> Bool {
        let search = searchText.lowercased()

        // Check profile name
        if profile.name.lowercased().contains(search) { return true }

        // Check SSH host
        if profile.sshConfig.host.lowercased().contains(search) { return true }

        // Check SSH username
        if profile.sshConfig.username.lowercased().contains(search) { return true }

        // Check folder path
        if profile.folderPath.lowercased().contains(search) { return true }

        // Check tags
        for tag in profile.tags {
            if tag.lowercased().contains(search) { return true }
        }

        // Check notes
        if let notes = profile.notes, notes.lowercased().contains(search) { return true }

        return false
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ProfileSuggestion, rhs: ProfileSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}
