//
//  SettingsRegistry.swift
//  rootshell
//
//  Single source of truth for every UserDefaults key the app owns: type,
//  default, sync policy, pin group, and text-config name. Unregistered keys
//  never sync; the Debug screen lists them so they get registered.
//

import Foundation
import os

/// Namespace for setting declarations. Areas add `nonisolated extension Settings { enum Cursor { ... } }`.
nonisolated enum Settings {}

nonisolated final class SettingsRegistry: Sendable {
    static let shared = SettingsRegistry(areas: Settings.allAreas)

    private static let logger = Logger(subsystem: "com.rootshell", category: "SettingsRegistry")

    /// A key family whose full names are composed at runtime (`ai.temperature.<providerID>`).
    struct PrefixRule: Sendable {
        let prefix: String
        let valueType: CodableValue.ValueType
        let policy: SyncPolicy
        let group: SettingGroup
        let title: String

        func definition(for key: String) -> AnySettingDefinition {
            .dynamic(key, valueType: valueType, policy: policy, group: group, title: title)
        }
    }

    let definitions: [String: AnySettingDefinition]
    let prefixRules: [PrefixRule]
    /// Explicitly registered syncable names; prefixed keys are resolved via `isSyncable(_:)`.
    let syncableKeys: Set<String>
    private let byGroup: [SettingGroup: [AnySettingDefinition]]
    private let byConfigKey: [String: AnySettingDefinition]

    init(areas: [[AnySettingDefinition]], prefixRules: [PrefixRule] = Settings.System.prefixRules) {
        var defs: [String: AnySettingDefinition] = [:]
        var groups: [SettingGroup: [AnySettingDefinition]] = [:]
        var configKeys: [String: AnySettingDefinition] = [:]
        for def in areas.joined() {
            if defs[def.name] != nil {
                Self.logger.fault("Duplicate setting registration: \(def.name, privacy: .public)")
                assertionFailure("Duplicate setting registration: \(def.name)")
            }
            defs[def.name] = def
            groups[def.group, default: []].append(def)
            if let ck = def.configKey { configKeys[ck] = def }
        }
        definitions = defs
        byGroup = groups
        byConfigKey = configKeys
        self.prefixRules = prefixRules
        syncableKeys = Set(defs.values.filter(\.isSyncable).map(\.name))
    }

    /// Lookup by text-config name (`font-size`, `tab-bar-hidden`).
    func definition(forConfigKey configKey: String) -> AnySettingDefinition? {
        byConfigKey[configKey == "tmux-new-tab-action" ? "new-tab-action" : configKey]
    }

    /// Keys the text config overlay can carry, ordered by group then name.
    var configEditableDefinitions: [AnySettingDefinition] {
        definitions.values
            .filter { $0.configKey != nil && $0.isSyncable && $0.valueType != .data }
            .sorted { ($0.group.rawValue, $0.name) < ($1.group.rawValue, $1.name) }
    }

    func prefixRule(for key: String) -> PrefixRule? {
        prefixRules.first { key.hasPrefix($0.prefix) && key.count > $0.prefix.count }
    }

    /// Explicit definition, or one synthesized from a prefix rule.
    func definition(for key: String) -> AnySettingDefinition? {
        definitions[key] ?? prefixRule(for: key)?.definition(for: key)
    }

    func isRegistered(_ key: String) -> Bool {
        definitions[key] != nil || prefixRule(for: key) != nil
    }

    func isSyncable(_ key: String) -> Bool {
        if syncableKeys.contains(key) { return true }
        if let rule = prefixRule(for: key) { return rule.policy != .deviceOnly }
        return false
    }

    func keys(in group: SettingGroup) -> [AnySettingDefinition] {
        byGroup[group] ?? []
    }

    var groupsInUse: [SettingGroup] {
        SettingGroup.allCases.filter { byGroup[$0]?.isEmpty == false }
    }

    /// Prefixes for Apple and framework keys that appear in the app's defaults domain.
    static let systemKeyPrefixes = [
        "com.apple.", "Apple", "NS", "AK", "INNext", "PK", "WebKit", "Metal",
        "CK", "CloudKit", "SU",
    ]

    /// Keys present in the persisted domain that the registry does not know.
    @MainActor
    func unregisteredKeys() -> [(key: String, typeDescription: String)] {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return [] }
        return domain
            .filter { key, _ in
                !isRegistered(key) && !Self.systemKeyPrefixes.contains { key.hasPrefix($0) }
            }
            .map { key, value in (key, Self.describe(value)) }
            .sorted { $0.key < $1.key }
    }

    /// Registered keys whose stored object does not decode as the declared type.
    @MainActor
    func typeMismatches() -> [(key: String, expected: CodableValue.ValueType, actual: String)] {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = UserDefaults.standard.persistentDomain(forName: bundleID) else { return [] }
        var out: [(String, CodableValue.ValueType, String)] = []
        for (key, raw) in domain {
            guard let def = definitions[key], let expected = def.valueType else { continue }
            if def.read(raw) == nil {
                out.append((key, expected, Self.describe(raw)))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let n as NSNumber:
            // CFBoolean is an NSNumber subclass; report it distinctly.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "Bool(\(n.boolValue))" }
            return "Number(\(n))"
        case let s as String: return "String(\(s.prefix(40)))"
        case let d as Data: return "Data(\(d.count) bytes)"
        case let a as [Any]: return "Array(\(a.count))"
        case let d as [String: Any]: return "Dictionary(\(d.count))"
        case let d as Date: return "Date(\(d))"
        default: return String(describing: type(of: value))
        }
    }

    // MARK: - Invariants

    /// Volatile defaults registered before protected data is available
    /// (UserDefaultsMigration) must agree with the registry, or sync would
    /// treat a registered default as a user choice.
    static let registeredVolatileDefaults: [String: CodableValue] = [
        "scrollModeEnabled": .bool(true),
        "lineScrollbackEnabled": .bool(false),
        "rubberBandScrollbackEnabled": .bool(true),
    ]

    /// Returns human-readable violations; empty when the registry is consistent.
    func invariantViolations() -> [String] {
        var problems: [String] = []
        for (key, expected) in Self.registeredVolatileDefaults {
            guard let def = definitions[key] else {
                problems.append("Volatile default \(key) is not registered")
                continue
            }
            if def.defaultCodable != expected {
                problems.append("Registry default for \(key) differs from registered volatile default")
            }
        }
        var configKeys: [String: String] = [:]
        for def in definitions.values {
            guard let ck = def.configKey else { continue }
            if let other = configKeys[ck] {
                problems.append("configKey \(ck) used by both \(other) and \(def.name)")
            }
            configKeys[ck] = def.name
            if def.policy == .deviceOnly {
                problems.append("Device-only key \(def.name) must not have a configKey")
            }
            if def.valueType == .data {
                problems.append("Data blob \(def.name) must not have a configKey")
            }
        }
        return problems.sorted()
    }

    func assertInvariants() {
        #if DEBUG
        let problems = invariantViolations()
        if !problems.isEmpty {
            for p in problems { Self.logger.fault("\(p, privacy: .public)") }
            assertionFailure(problems.joined(separator: "\n"))
        }
        #endif
    }
}
