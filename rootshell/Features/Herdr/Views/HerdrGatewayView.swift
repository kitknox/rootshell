// Copyright (c) 2026 Kit Knox / Rootshell LLC

import SwiftUI

/// Covers only the gateway pane, leaving any unrelated splits usable.
struct HerdrGatewayView: View {
    let sessionName: String
    let hasSnapshot: Bool
    let isActive: Bool
    let isCreating: Bool
    let errorMessage: String?
    let newTab: () -> Void
    let retryConnection: () -> Void
    let detach: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "h.square")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(sessionName)
                    .font(.headline)
                if isCreating {
                    ProgressView("Creating herdr tab…")
                } else if isActive {
                    Text("No herdr tabs")
                        .font(.title3)
                    Text("Open a tab to start a shell in this session.")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(hasSnapshot ? "Reconnecting to herdr…" : "Connecting to herdr…")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(action: newTab) {
                    Label("New herdr Tab", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isActive || isCreating)
                if !isActive {
                    Button("Retry Connection", action: retryConnection)
                        .buttonStyle(.bordered)
                }
                Button("Detach from herdr", action: detach)
                    .buttonStyle(.bordered)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}
