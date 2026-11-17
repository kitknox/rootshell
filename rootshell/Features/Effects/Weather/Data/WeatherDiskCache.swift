// WeatherDiskCache.swift
// rootshell

#if !CHINA_BUILD
import Foundation

nonisolated struct WeatherDiskState: Codable, Equatable, Sendable {
    var snapshot: WeatherSnapshot?
    var policy = WeatherFetchPolicy()
    var sources = WeatherSourceState()
    /// The last resolved device coordinate, so a relaunch draws the right sky.
    var deviceCoordinate: WeatherCoordinate?
    /// The coordinate and provider the policy's schedule belongs to.
    var policyCoordinate: WeatherCoordinate?
    var policyProvider: WeatherProviderID?
}

/// Library/Caches/LiveWeather/state.json: device-local, never backed up.
/// Loads synchronously so the first frame has data; saves are debounced.
actor WeatherDiskCache {
    static let shared = WeatherDiskCache()

    private var pending: WeatherDiskState?
    private var saveTask: Task<Void, Never>?

    nonisolated static var fileURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("LiveWeather", isDirectory: true).appendingPathComponent("state.json")
    }

    nonisolated static func load() -> WeatherDiskState? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WeatherDiskState.self, from: data)
    }

    func save(_ state: WeatherDiskState) {
        pending = state
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        guard let state = pending, let url = Self.fileURL else { return }
        pending = nil
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
