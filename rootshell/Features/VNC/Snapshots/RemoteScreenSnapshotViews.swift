//
//  RemoteScreenSnapshotViews.swift
//  rootshell
//
//  Where a saved remote screen is drawn: softened behind a pane that has
//  no live picture yet, and as a thumbnail beside its profile.
//

import SwiftUI

// MARK: - Pane placeholder

/// The last screen seen, until the session draws its own. Softened and
/// dated so it never passes for a live picture.
struct RemoteScreenLastSeenPlaceholder: View {
    let recorder: RemoteScreenSnapshotRecorder

    var body: some View {
        let snapshot = recorder.isLive ? nil : recorder.placeholder
        ZStack {
            if let snapshot {
                RemoteScreenLastSeenImage(snapshot: snapshot)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: snapshot != nil)
    }
}

private struct RemoteScreenLastSeenImage: View {
    let snapshot: RemoteScreenSnapshot

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black

            Image(decorative: snapshot.image, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                // Opaque keeps the picture's edges where the live one will be.
                .blur(radius: 10, opaque: true)
                .saturation(0.85)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Label(Self.caption(for: snapshot.capturedAt), systemImage: "clock.arrow.circlepath")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                // Clear of the home indicator in the full-screen takeover.
                .padding(.bottom, 28)
        }
        .clipped()
    }

    static func caption(for date: Date) -> String {
        guard Date().timeIntervalSince(date) >= 60 else {
            return String(localized: "Last seen moments ago", comment: "Remote screen placeholder caption")
        }
        let relative = date.formatted(.relative(presentation: .named))
        return String(localized: "Last seen \(relative)", comment: "Remote screen placeholder caption; the value is a relative time such as '5 minutes ago'")
    }
}

// MARK: - Profile thumbnail

/// A saved profile's last screen at list-row size. The row adds it only
/// when the store has a snapshot, so the box never sits empty for long.
struct RemoteScreenProfileThumbnail: View {
    let profileID: UUID
    let endpoint: String
    var height: CGFloat = 34

    /// The picture and what it was loaded for. A row is reused as its
    /// profile changes, and a picture of the previous computer must not
    /// show while the next one loads.
    @State private var loaded: (id: LoadID, snapshot: RemoteScreenSnapshot)?

    private static let pixelDimension = 240

    private struct LoadID: Hashable {
        let profileID: UUID
        let stamp: Date?
        let endpoint: String
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let id = LoadID(
            profileID: profileID,
            stamp: RemoteScreenSnapshotStore.shared.capturedAt[profileID],
            endpoint: endpoint)
        ZStack {
            Color.primary.opacity(0.06)
            if let loaded, loaded.id == id {
                Image(decorative: loaded.snapshot.image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: (height * 1.6).rounded(), height: height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: id) {
            // A picture of another computer is stale, if the profile still
            // points where this row said when the read comes back.
            let snapshot = await RemoteScreenSnapshotStore.shared.load(
                profileID: id.profileID,
                endpoint: id.endpoint,
                deletingOtherEndpointIf: {
                    RemoteScreenSnapshotRecorder.savedProfilePoints(id.profileID, at: id.endpoint)
                },
                maxPixelDimension: Self.pixelDimension)
            // A newer load owns the row by now.
            guard !Task.isCancelled else { return }
            loaded = snapshot.map { (id, $0) }
        }
    }
}

/// Context-menu item that deletes a profile's saved screen. Absent when
/// there is nothing saved.
struct ForgetRemoteScreenSnapshotButton: View {
    let profileID: UUID

    var body: some View {
        if RemoteScreenSnapshotStore.shared.capturedAt[profileID] != nil {
            Button(role: .destructive) {
                RemoteScreenSnapshotStore.shared.remove(profileID: profileID)
            } label: {
                Label("Forget Last Screen", systemImage: "eye.slash")
            }
        }
    }
}

// MARK: - Snapshot identity

extension RemoteScreenRoute {
    /// Which computer a saved screen shows, jump route included: the same
    /// private address behind two jump hosts is two machines. Nil while
    /// the jump profile is missing, when the route names no computer.
    var snapshotEndpoint: String? {
        isUnresolved ? nil : passwordKey
    }
}

extension ConnectionProfile {
    /// Where this profile points now. Nil unless it is a Screen Sharing or
    /// KVM profile with a route that resolves.
    var remoteScreenSnapshotEndpoint: String? {
        switch connectionProtocol {
        case .vnc: return vncConfig?.currentRoute.snapshotEndpoint
        case .kvm: return kvmConfig?.currentRoute.snapshotEndpoint
        case .local, .ssh, .mosh, .trzsz: return nil
        }
    }
}

extension RemoteScreenSnapshotRecorder {
    /// A pane outlives edits to its profile: write only for a profile that
    /// still exists and still points at the computer the pane reached.
    static func savedProfilePoints(_ profileID: UUID, at endpoint: String) -> Bool {
        guard let profile = ConnectionProfileManager.shared.profile(for: profileID),
              !profile.isDeleted else { return false }
        return profile.remoteScreenSnapshotEndpoint == endpoint
    }
}
