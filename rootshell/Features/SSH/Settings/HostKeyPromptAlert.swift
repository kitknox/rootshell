//
//  HostKeyPromptAlert.swift
//  rootshell
//
//  Alert-continuation host-key prompt for views that open SSH connections
//  outside a terminal (background tunnel starts, WiFi AP scans). Present with
//  `.hostKeyPromptAlerts(prompt)` and pass `prompt.validate` as the
//  connection's onHostKeyValidation callback. Prompts are serialized, so
//  concurrent connections (jump + target, multi-AP scans) queue one alert
//  at a time. Cancellation-safe: a cancelled caller resolves as .reject and
//  releases the queue; an alert dismissed without a button choice rejects.
//

import SwiftUI

@MainActor
@Observable
final class HostKeyPrompt {
    var showNewKeyAlert = false
    var showChangedKeyAlert = false
    private(set) var message = ""
    private var continuation: CheckedContinuation<HostKeyValidationResult, Never>?
    private var currentPromptID: UUID?
    private var isCancelled = false

    func validate(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        if isCancelled { return .reject }
        // Serialize: one alert at a time. A cancelled waiter must not spin
        // (cancelled Task.sleep returns immediately) — bail out strictly.
        while continuation != nil {
            if isCancelled { return .reject }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return .reject
            }
        }
        if isCancelled || Task.isCancelled { return .reject }

        let promptID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                message = request.message
                continuation = cont
                currentPromptID = promptID
                if request.isKeyChanged {
                    showChangedKeyAlert = true
                } else {
                    showNewKeyAlert = true
                }
            }
        } onCancel: {
            // Caller task cancelled (connect timeout, view/task teardown):
            // dismiss our alert and resolve as reject so the queue drains.
            Task { @MainActor in
                self.cancelPrompt(id: promptID)
            }
        }
    }

    func respond(_ result: HostKeyValidationResult) {
        continuation?.resume(returning: result)
        continuation = nil
        currentPromptID = nil
    }

    /// Rejects any active, queued, or future host-key prompts when the owning window tears down.
    func cancelAll() {
        isCancelled = true
        showNewKeyAlert = false
        showChangedKeyAlert = false
        respond(.reject)
    }

    /// Alert flag flipped to false. Button actions run in the same main-queue
    /// drain and clear the continuation first, so this deferred check only
    /// catches dismissals with no choice (view teardown, system dismissal).
    func handleAlertDismissed() {
        Task { @MainActor in
            if continuation != nil, !showNewKeyAlert, !showChangedKeyAlert {
                respond(.reject)
            }
        }
    }

    private func cancelPrompt(id: UUID) {
        guard currentPromptID == id else { return }
        showNewKeyAlert = false
        showChangedKeyAlert = false
        respond(.reject)
    }
}

extension View {
    func hostKeyPromptAlerts(_ prompt: HostKeyPrompt) -> some View {
        modifier(HostKeyPromptAlertsModifier(prompt: prompt))
    }
}

private struct HostKeyPromptAlertsModifier: ViewModifier {
    @Bindable var prompt: HostKeyPrompt

    func body(content: Content) -> some View {
        content
            .alert("New SSH Host", isPresented: $prompt.showNewKeyAlert) {
                Button("Trust & Save") { prompt.respond(.accept) }
                Button("Connect Once") { prompt.respond(.acceptOnce) }
                Button("Cancel", role: .cancel) { prompt.respond(.reject) }
            } message: {
                Text(prompt.message)
            }
            .alert("⚠️ Host Key Changed", isPresented: $prompt.showChangedKeyAlert) {
                Button("Replace & Connect", role: .destructive) { prompt.respond(.accept) }
                Button("Cancel", role: .cancel) { prompt.respond(.reject) }
            } message: {
                Text(prompt.message)
            }
            .onChange(of: prompt.showNewKeyAlert) { _, shown in
                if !shown { prompt.handleAlertDismissed() }
            }
            .onChange(of: prompt.showChangedKeyAlert) { _, shown in
                if !shown { prompt.handleAlertDismissed() }
            }
    }
}
