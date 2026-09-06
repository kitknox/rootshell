//
//  ProfileKeyAvailabilityBadge.swift
//  rootshell
//
//  Warning badge overlay for profile rows whose SSH key
//  isn't available on the current device.
//

import SwiftUI

/// Small warning badge shown on profile list rows when the profile's
/// SSH key isn't resolvable on the current device.
struct ProfileKeyAvailabilityBadge: View {
    let profile: ConnectionProfile

    var body: some View {
        if profile.isSSHBased && !ConnectionKeyResolver.isResolvable(config: profile.sshConfig, profileID: profile.id) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolEffect(.wiggle, options: .repeat(2).speed(0.8))
                .font(.caption2)
                .foregroundStyle(.orange)
                .help("SSH key not available on this device")
        }
    }
}
