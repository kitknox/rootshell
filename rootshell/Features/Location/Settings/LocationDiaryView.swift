import SwiftUI
import CoreLocation

struct LocationDiaryView: View {
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @ObservedObject var manager = LocationDiaryManager.shared

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Location Diary Mode")
                        .font(.headline)

                    Text("Continuously tracks location to keep SSH and Screen Sharing connections and long-running local tasks alive in the background. Shows locations from the last 5 minutes.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .themedRow()
            }

            Section("Status") {
                HStack {
                    Text("Tracking")
                    Spacer()
                    Text(manager.isEnabled ? String(localized: "Active", comment: "Location tracking status: active") : String(localized: "Inactive", comment: "Location tracking status: inactive"))
                        .foregroundColor(manager.isEnabled ? .green : .secondary)
                }
                .themedRow()

                if manager.isEnabled {
                    HStack {
                        Text("Authorization")
                        Spacer()
                        Text(authorizationStatusText)
                            .foregroundColor(authorizationColor)
                    }
                    .themedRow()

                    if let currentLocation = manager.currentLocation {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current Location")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(currentLocation)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                        .themedRow()
                    }
                }
            }

            if manager.isEnabled {
                Section("Location History (Last 5 Minutes)") {
                    if manager.entries.isEmpty {
                        Text("No locations recorded yet")
                            .foregroundColor(.secondary)
                            .italic()
                            .themedRow()
                    } else {
                        ForEach(manager.entries.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.formattedTimestamp)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if entry.retryCount > 0 {
                                        Text("Retry \(entry.retryCount)")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }

                                switch entry.addressState {
                                case .resolved(let address):
                                    Text(address)
                                        .font(.body)

                                case .resolving:
                                    HStack(spacing: 4) {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                        Text("Resolving address...")
                                            .font(.body)
                                            .foregroundColor(.secondary)
                                            .italic()
                                    }

                                case .failed:
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.formattedCoordinateString)
                                            .font(.body)
                                        Text("Address unavailable")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                            .italic()
                                    }
                                }

                                Text(entry.coordinateString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .themedRow()
                        }
                    }
                }
            }

            if manager.mode == .off || manager.authorizationStatus == .notDetermined {
                Section {
                    Button("Enable Location Tracking") {
                        if manager.authorizationStatus == .notDetermined {
                            manager.requestPermission()
                        }
                        // Default to auto mode when enabling from this view
                        if manager.mode == .off {
                            manager.mode = .autoForRemote
                        }
                    }
                    .themedRow()
                }
            }
        }
        .themedList()
        .navigationTitle("Location Diary")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var authorizationStatusText: String {
        switch manager.authorizationStatus {
        case .notDetermined:
            return String(localized: "Not Requested", comment: "Location Diary authorization status")
        case .restricted:
            return String(localized: "Restricted", comment: "Location Diary authorization status")
        case .denied:
            return String(localized: "Denied", comment: "Location Diary authorization status")
        #if !os(visionOS)
        case .authorizedAlways:
            return String(localized: "Always", comment: "Location Diary authorization status")
        #endif
        case .authorizedWhenInUse:
            return String(localized: "When In Use", comment: "Location Diary authorization status")
        @unknown default:
            return String(localized: "Unknown", comment: "Location Diary authorization status")
        }
    }

    private var authorizationColor: Color {
        switch manager.authorizationStatus {
        #if os(visionOS)
        case .authorizedWhenInUse:
            return .green
        #else
        case .authorizedAlways, .authorizedWhenInUse:
            return .green
        #endif
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .orange
        @unknown default:
            return .secondary
        }
    }
}
