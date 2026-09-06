//
//  ConfigOverlayManager.swift
//  rootshell
//
//  Loads the user-facing text config, pins every key it contains to this
//  device with the file's value, watches for edits, and writes UI changes
//  back in place so comments and ordering survive.
//

import Foundation
import UIKit
import os

@MainActor @Observable
final class ConfigOverlayManager {
    static let shared = ConfigOverlayManager(store: .shared, registry: .shared, coordinator: .shared)

    private static let logger = Logger(subsystem: "com.rootshell", category: "ConfigOverlay")

    enum Status: Equatable {
        case notFound
        case active(count: Int)
        case error(String)
    }

    struct BoundEntry: Sendable {
        let key: String
        let configKey: String
        let rawValues: [String]
        let file: URL
        let line: Int
    }

    private(set) var status: Status = .notFound
    private(set) var diagnostics: [ConfigOverlayDiagnostic] = []
    private(set) var lastLoaded: Date?
    /// Setting name -> where the file defines it.
    private(set) var boundEntries: [String: BoundEntry] = [:]
    private(set) var activeURL: URL = ConfigOverlayLocation.canonicalURL
    private(set) var isExternal = false

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let registry: SettingsRegistry
    @ObservationIgnored private let coordinator: SettingsSyncCoordinator
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundToken: NSObjectProtocol?
    @ObservationIgnored private var fileSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var dirSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var lastKnownModification: Date?
    @ObservationIgnored private var securityScopeActive = false
    @ObservationIgnored private var started = false

    // No default arguments: they evaluate nonisolated and cannot touch MainActor singletons.
    init(store: SettingsStore, registry: SettingsRegistry, coordinator: SettingsSyncCoordinator) {
        self.store = store
        self.registry = registry
        self.coordinator = coordinator
    }

    var writeBackEnabled: Bool {
        get { store.get(Settings.System.configOverlayWriteBack) }
        set { store.set(Settings.System.configOverlayWriteBack, newValue) }
    }

    var shellDisplayPath: String {
        isExternal ? ConfigOverlayLocation.shellDisplayPath(for: activeURL) : ConfigOverlayLocation.canonicalShellPath
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: activeURL.path) }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        migrateLegacyLocationIfNeeded()
        resolveActiveURL()
        reload()
        installWatcher()
        listenTask = Task { [weak self] in
            guard let stream = self?.store.changes() else { return }
            for await change in stream {
                self?.handleStoreChange(change)
            }
        }
        foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfModified() }
        }
    }

    /// An earlier build followed XDG_CONFIG_HOME into Application Support; move that file home.
    private func migrateLegacyLocationIfNeeded() {
        guard let legacy = ConfigOverlayLocation.legacyApplicationSupportURL else { return }
        let canonical = ConfigOverlayLocation.canonicalURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: canonical.path) else { return }
        do {
            try fm.createDirectory(at: canonical.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: canonical)
            Self.logger.info("Moved config file from Application Support to \(canonical.path, privacy: .public)")
        } catch {
            Self.logger.error("Could not move legacy config file: \(error.localizedDescription)")
        }
    }

    private func resolveActiveURL() {
        endSecurityScope()
        let bookmark = store.get(Settings.System.configOverlayBookmark)
        let path = store.get(Settings.System.configOverlayExternalPath)
        if let external = ConfigOverlayLocation.externalURL(bookmark: bookmark, path: path) {
            activeURL = external.url
            isExternal = true
            if external.isStale, let fresh = ConfigOverlayLocation.makeBookmark(for: external.url) {
                store.set(Settings.System.configOverlayBookmark, fresh)
            }
            if external.url.startAccessingSecurityScopedResource() { securityScopeActive = true }
        } else {
            activeURL = ConfigOverlayLocation.canonicalURL
            isExternal = false
        }
    }

    private func endSecurityScope() {
        if securityScopeActive {
            activeURL.stopAccessingSecurityScopedResource()
            securityScopeActive = false
        }
    }

    func setExternalFile(_ url: URL) {
        if ConfigOverlayLocation.supportsDirectExternalPath {
            store.set(Settings.System.configOverlayExternalPath, url.path)
            store.reset(Settings.System.configOverlayBookmark)
        } else if let bookmark = ConfigOverlayLocation.makeBookmark(for: url) {
            store.set(Settings.System.configOverlayBookmark, bookmark)
            store.reset(Settings.System.configOverlayExternalPath)
        } else {
            status = .error(String(localized: "Couldn't keep access to the selected file.", comment: "Config overlay error"))
            return
        }
        resolveActiveURL()
        installWatcher()
        reload()
    }

    func clearExternalFile() {
        store.reset(Settings.System.configOverlayBookmark)
        store.reset(Settings.System.configOverlayExternalPath)
        resolveActiveURL()
        installWatcher()
        reload()
    }

    // MARK: - Loading

    func reloadIfModified() {
        guard let mtime = modificationDate(), mtime != lastKnownModification else { return }
        reload()
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: activeURL.path))?[.modificationDate] as? Date
    }

    func reload() {
        guard fileExists else {
            status = .notFound
            diagnostics = []
            boundEntries = [:]
            lastLoaded = Date()
            coordinator.applyConfigFile(values: [:])
            return
        }
        let loaded: GhosttyConfigLoader.Result
        do {
            loaded = try GhosttyConfigLoader.load(activeURL)
        } catch {
            status = .error(error.localizedDescription)
            diagnostics = [ConfigOverlayDiagnostic(severity: .error, file: activeURL, line: nil, key: nil,
                                                   message: error.localizedDescription)]
            lastKnownModification = modificationDate()
            lastLoaded = Date()
            return
        }

        var diags: [ConfigOverlayDiagnostic] = loaded.warnings.map {
            ConfigOverlayDiagnostic(severity: .warning, file: activeURL, line: nil, key: nil, message: $0)
        }
        // Group raw values per config key, remembering the effective line.
        var grouped: [String: (values: [String], entry: ParsedConfigEntry)] = [:]
        var order: [String] = []
        for entry in loaded.entries {
            if entry.key == "config-file" { continue }
            if entry.key == "keybind" {
                if grouped["keybind"] == nil {
                    diags.append(ConfigOverlayDiagnostic(severity: .info, file: entry.sourceFile, line: entry.lineNumber, key: "keybind",
                                                         message: String(localized: "Keybinds are managed under Keyboard Shortcuts.", comment: "Config overlay note")))
                    grouped["keybind"] = ([], entry)
                }
                continue
            }
            if var existing = grouped[entry.key] {
                existing.values.append(entry.value)
                existing.entry = entry
                grouped[entry.key] = existing
            } else {
                grouped[entry.key] = ([entry.value], entry)
                order.append(entry.key)
            }
        }

        var values: [String: CodableValue?] = [:]
        var bound: [String: BoundEntry] = [:]
        for configKey in order {
            // The global spelling wins regardless of file order, including reset.
            if configKey == "tmux-new-tab-action", grouped["new-tab-action"] != nil { continue }
            guard let item = grouped[configKey] else { continue }
            guard let def = registry.definition(forConfigKey: configKey) else {
                diags.append(ConfigOverlayDiagnostic(severity: .info, file: item.entry.sourceFile, line: item.entry.lineNumber, key: configKey,
                                                     message: String(localized: "Unknown key \(configKey)", comment: "Config overlay note")))
                continue
            }
            if def.valueType != .stringArray, item.values.count > 1 {
                diags.append(ConfigOverlayDiagnostic(severity: .warning, file: item.entry.sourceFile, line: item.entry.lineNumber, key: configKey,
                                                     message: String(localized: "\(configKey) is set more than once; using line \(item.entry.lineNumber)", comment: "Config overlay warning")))
            }
            do {
                let value = try ConfigOverlayCodec.decode(item.values, for: def)
                values[def.name] = value
                bound[def.name] = BoundEntry(key: def.name, configKey: configKey, rawValues: item.values,
                                             file: item.entry.sourceFile, line: item.entry.lineNumber)
            } catch ConfigOverlayCodec.DecodeError.invalid(let reason) {
                diags.append(ConfigOverlayDiagnostic(severity: .warning, file: item.entry.sourceFile, line: item.entry.lineNumber, key: configKey,
                                                     message: reason))
            } catch {
                diags.append(ConfigOverlayDiagnostic(severity: .warning, file: item.entry.sourceFile, line: item.entry.lineNumber, key: configKey,
                                                     message: error.localizedDescription))
            }
        }

        boundEntries = bound
        diagnostics = diags.sorted { ($0.severity, $0.line ?? 0) > ($1.severity, $1.line ?? 0) }
        status = .active(count: bound.count)
        lastKnownModification = modificationDate()
        lastLoaded = Date()
        coordinator.applyConfigFile(values: values)
        Self.logger.info("Config overlay loaded: \(bound.count) keys, \(diags.count) diagnostics")
    }

    // MARK: - Watching

    private func installWatcher() {
        fileSource?.cancel(); fileSource = nil
        dirSource?.cancel(); dirSource = nil
        #if targetEnvironment(macCatalyst)
        let dir = activeURL.deletingLastPathComponent()
        dirSource = makeSource(path: dir.path, mask: [.write, .rename, .delete])
        if fileExists {
            fileSource = makeSource(path: activeURL.path, mask: [.write, .rename, .delete, .extend])
        }
        #endif
    }

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            // Ignore events from our own write-back.
            if let mtime = modificationDate(), mtime == lastKnownModification, fileExists { return }
            reload()
            installWatcher()
        }
    }

    // MARK: - Write-back

    private func handleStoreChange(_ change: SettingsChange) {
        guard change.origin == .local, writeBackEnabled else { return }
        let affected = change.keys.filter { boundEntries[$0] != nil }
        guard !affected.isEmpty else { return }
        var document = loadDocument()
        for key in affected {
            guard let entry = boundEntries[key], let def = registry.definition(for: key) else { continue }
            if let value = store.codableValue(key), let lines = ConfigOverlayCodec.encode(value, for: def) {
                document?.set(configKey: entry.configKey, values: lines)
            } else {
                document?.commentOut(configKey: entry.configKey)
            }
        }
        guard let document else { return }
        writeDocument(document)
    }

    /// Add the key's current value to the file (pinning it here).
    func addToFile(_ key: String) {
        guard let def = registry.definition(for: key), let configKey = def.configKey,
              let value = store.codableValue(key), let lines = ConfigOverlayCodec.encode(value, for: def) else { return }
        var document = loadDocument() ?? ConfigOverlayDocument(text: ConfigFileExporter.preamble + "\n")
        document.set(configKey: configKey, values: lines)
        writeDocument(document)
        reload()
    }

    /// Comment the key out so it rejoins iCloud.
    func removeFromFile(_ key: String) {
        guard let entry = boundEntries[key], var document = loadDocument() else { return }
        document.commentOut(configKey: entry.configKey)
        writeDocument(document)
        reload()
    }

    /// Write a starter file at the canonical location, fully commented so nothing is pinned yet.
    func createTemplate() {
        guard !fileExists else { return }
        let text = ConfigFileExporter.render(includeDefaults: true, liveValues: false)
        writeText(text)
        installWatcher()
        reload()
    }

    private func loadDocument() -> ConfigOverlayDocument? {
        guard let text = try? String(contentsOf: activeURL, encoding: .utf8) else { return nil }
        return ConfigOverlayDocument(text: text)
    }

    private func writeDocument(_ document: ConfigOverlayDocument) {
        writeText(document.text)
    }

    /// In place, non-atomic, so symlinks into dotfile repos survive.
    private func writeText(_ text: String) {
        do {
            try FileManager.default.createDirectory(at: activeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: activeURL, atomically: false, encoding: .utf8)
            lastKnownModification = modificationDate()
        } catch {
            Self.logger.error("Config write failed: \(error.localizedDescription)")
            status = .error(error.localizedDescription)
        }
    }
}
