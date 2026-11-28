//
//  GeoProvider.swift
//  rootshell
//
//  Configurable geo provider with persistent cache.
//

import Foundation
import Observation
import OSLog

// MARK: - Provider Type

enum GeoProviderType: String, Codable, CaseIterable, Sendable {
    case ipinfo = "ipinfo"
    case internetdata = "internetdata"
    case mmdb = "mmdb"
    case dns = "dns"
    case disabled = "disabled"

    static var availableCases: [GeoProviderType] {
        allCases.filter(\.isAvailable)
    }

    static var defaultProvider: GeoProviderType {
        IPInfoLiteClient.isConfigured ? .ipinfo : .dns
    }

    static func availableProvider(for rawValue: String?) -> GeoProviderType {
        let provider = rawValue.flatMap(GeoProviderType.init(rawValue:)) ?? defaultProvider
        return provider.isAvailable ? provider : defaultProvider
    }

    private var isAvailable: Bool {
        self != .ipinfo || IPInfoLiteClient.isConfigured
    }

    var displayName: String {
        switch self {
        case .ipinfo: "IPInfo Lite"
        case .internetdata: "InternetData"
        case .mmdb: "Local MMDB"
        case .dns: "DNS (Team Cymru)"
        case .disabled: "Disabled"
        }
    }

    var subtitle: String {
        switch self {
        case .ipinfo: "ASN, AS name, country, continent"
        case .internetdata: "ASN, AS name, network, country, continent"
        case .mmdb: "Local ASN/country MMDB data"
        case .dns: "ASN, CIDR, country code"
        case .disabled: "No third-party geo lookups"
        }
    }
}

// MARK: - GeoResolver

@MainActor
@Observable
final class GeoResolver {
    static let shared = GeoResolver()

    private nonisolated static let logger = Logger(subsystem: "com.kk2.rootshell", category: "geo-resolver")

    var providerType: GeoProviderType {
        didSet {
            if !isReloading { SettingsStore.shared.set(Settings.Privacy.geoProviderType, providerType) }
        }
    }

    /// True while `reload(keys:)` re-assigns `providerType` from the store.
    @ObservationIgnored private var isReloading = false

    private let cache = GeoCache()
    private(set) var cacheEntryCount: Int = 0
    /// Bumped once a cache clear (including any MMDB change) completes, so
    /// in-memory copies of earlier results can be dropped.
    private(set) var cacheGeneration = 0

    private init() {
        // Unset resolves to the dynamic `defaultProvider`, not the registry default, so presence is checked raw
        let key = Settings.Privacy.geoProviderType
        let stored = UserDefaults.standard.object(forKey: key.name) == nil ? "" : SettingsStore.shared.get(key).rawValue
        let provider = GeoProviderType.availableProvider(for: stored)
        self.providerType = provider
        if stored != provider.rawValue {
            SettingsStore.shared.set(key, provider)
        }

        SettingsRefreshHub.shared.register(keys: [key.name]) { [weak self] keys in
            self?.reload(keys: keys)
        }
        // Cache size is loaded asynchronously — first read fires a background
        // task that updates the @Observable property when ready. Avoids the
        // synchronous file read that GeoCache used to do during init.
        Task { [weak self] in
            guard let self else { return }
            self.cacheEntryCount = await self.cache.count
        }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        guard keys.contains(Settings.Privacy.geoProviderType.name) else { return }
        isReloading = true
        defer { isReloading = false }
        let stored = SettingsStore.shared.get(Settings.Privacy.geoProviderType)
        providerType = GeoProviderType.availableProvider(for: stored.rawValue)
    }

    func resolve(ip: String) async -> GeoInfo? {
        let provider = providerType
        guard provider != .disabled else { return nil }

        // Check cache
        if let cached = await cache.lookup(ip: ip, provider: provider) {
            return cached
        }

        // Resolve (IPInfo and InternetData fall back to DNS on failure)
        let result: GeoInfo?
        switch provider {
        case .ipinfo:
            if let ipinfoResult = await resolveViaIPInfo(ip: ip) {
                result = ipinfoResult
            } else {
                result = await resolveViaDNS(ip: ip)
            }
        case .internetdata:
            if let internetDataResult = await resolveViaInternetData(ip: ip) {
                result = internetDataResult
            } else {
                result = await resolveViaDNS(ip: ip)
            }
        case .mmdb:
            result = await resolveViaMMDB(ip: ip)
        case .dns:
            result = await resolveViaDNS(ip: ip)
        case .disabled:
            return nil
        }

        // Store in cache keyed by the configured provider (not the result's provider,
        // which may differ when IPInfo or InternetData falls back to DNS)
        if let result {
            await cache.store(ip: ip, info: result, provider: provider)
            cacheEntryCount = await cache.count
        }

        return result
    }

    func clearCache() {
        Task { [weak self] in
            guard let self else { return }
            await self.cache.clear()
            self.cacheEntryCount = 0
            self.cacheGeneration += 1
        }
    }

    // MARK: - Provider Implementations

    private nonisolated func resolveViaIPInfo(ip: String) async -> GeoInfo? {
        do {
            return try await IPInfoLiteClient.resolve(ip: ip)
        } catch {
            Self.logger.warning("IPInfo lookup failed for \(ip): \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated func resolveViaInternetData(ip: String) async -> GeoInfo? {
        do {
            return try await InternetDataClient.resolve(ip: ip)
        } catch {
            Self.logger.warning("InternetData lookup failed for \(ip): \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated func resolveViaDNS(ip: String) async -> GeoInfo? {
        // ASNResolver.resolveSync blocks, so dispatch to background with 3s timeout
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let semaphore = DispatchSemaphore(value: 0)
                var result: GeoInfo?

                DispatchQueue.global(qos: .utility).async {
                    result = ASNResolver.resolveSync(ip: ip)
                    semaphore.signal()
                }

                if semaphore.wait(timeout: .now() + 3) == .timedOut {
                    Self.logger.warning("DNS ASN lookup timed out for \(ip)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func resolveViaMMDB(ip: String) async -> GeoInfo? {
        await MMDBDatabaseManager.shared.resolve(ip: ip)
    }
}

// MARK: - GeoCache

actor GeoCache {
    private struct Entry: Codable {
        let info: GeoInfo
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var dirty = false
    private var pendingSave: Task<Void, Never>?

    private static let maxEntries = 500
    private static let ttl: TimeInterval = 7 * 24 * 3600 // 7 days

    private nonisolated var cacheFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("geo_cache.json")
    }

    var count: Int {
        ensureLoaded()
        return entries.count
    }

    func lookup(ip: String, provider: GeoProviderType) -> GeoInfo? {
        ensureLoaded()
        let key = "\(provider.rawValue):\(ip)"
        guard let entry = entries[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > Self.ttl {
            entries.removeValue(forKey: key)
            scheduleSave()
            return nil
        }
        return entry.info
    }

    func store(ip: String, info: GeoInfo, provider: GeoProviderType) {
        ensureLoaded()
        let key = "\(provider.rawValue):\(ip)"
        entries[key] = Entry(info: info, timestamp: Date())
        evictIfNeeded()
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        dirty = true
        saveNow()
    }

    // MARK: - Persistence

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheFileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }
        // Filter expired entries on load
        let now = Date()
        entries = decoded.filter { now.timeIntervalSince($0.value.timestamp) <= Self.ttl }
    }

    private func evictIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let sorted = entries.sorted { $0.value.timestamp < $1.value.timestamp }
        let toRemove = entries.count - Self.maxEntries
        for i in 0..<toRemove {
            entries.removeValue(forKey: sorted[i].key)
        }
    }

    private func scheduleSave() {
        dirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func saveNow() {
        guard dirty else { return }
        dirty = false
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheFileURL, options: .atomic)
    }
}
