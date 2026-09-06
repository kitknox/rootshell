import Foundation
import Observation

/// Lives on the tab, so a tmux reconcile replacing the split host cannot lose
/// the in-flight guard or its error message.
@MainActor
@Observable
final class PaneMoveState {
    private(set) var requestID: UUID?
    private(set) var errorMessage: String?
    @ObservationIgnored private var clearErrorTask: Task<Void, Never>?

    var isPending: Bool { requestID != nil }

    func begin() -> UUID? {
        guard requestID == nil else { return nil }
        clearErrorTask?.cancel()
        errorMessage = nil
        let id = UUID()
        requestID = id
        return id
    }

    func finish(_ id: UUID, error: String? = nil) {
        guard requestID == id else { return }
        requestID = nil
        errorMessage = error
        guard error != nil else { return }
        clearErrorTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.errorMessage = nil
        }
    }

    deinit { clearErrorTask?.cancel() }
}
