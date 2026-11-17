//
//  KeyboardToolbarManager.swift
//  rootshell
//
//  Manages keyboard toolbar layout customization and custom keys.
//  Persists configuration to UserDefaults and notifies observers on changes.
//

import Foundation
import SwiftUI
import Observation
import os

@MainActor
@Observable
class KeyboardToolbarManager {
    static let shared = KeyboardToolbarManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KeyboardToolbarManager")

    static let layoutDidChangeNotification = Notification.Name("KeyboardToolbarLayoutDidChange")

    // MARK: - Storage Keys

    /// Device-only marker; stays raw because it never syncs.
    private static let deviceIdiomKey = "keyboardToolbarDeviceIdiom"

    private static let ownedKeys: Set<String> = [
        Settings.KeyboardToolbar.config.name,
        Settings.KeyboardToolbar.customKeys.name,
        Settings.KeyboardToolbar.drawerOpenByDefault.name,
        Settings.KeyboardToolbar.drawerToggleMode.name,
    ]

    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    private(set) var config: ToolbarLayoutConfig {
        didSet {
            guard !isReloading else { return }
            saveConfig()
        }
    }

    private(set) var customKeys: [CustomKey] {
        didSet {
            guard !isReloading else { return }
            saveCustomKeys()
        }
    }

    var drawerOpenByDefault: Bool {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.drawerOpenByDefault, drawerOpenByDefault)
        }
    }

    /// How the "…" button steps through multiple drawer rows (stack vs cycle).
    var drawerToggleMode: DrawerToggleMode {
        didSet {
            guard !isReloading else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.drawerToggleMode, drawerToggleMode)
            Self.logger.info("Toolbar user action: drawer mode changed to \(self.drawerToggleMode.rawValue, privacy: .public)")
        }
    }

    // MARK: - Computed Properties

    var isCustomized: Bool {
        let defaults = ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
        return config != defaults || !customKeys.isEmpty
    }

    private var currentIdiom: UIUserInterfaceIdiom {
        UIDevice.current.userInterfaceIdiom
    }

    // MARK: - Initialization

    private init() {
        let idiom = UIDevice.current.userInterfaceIdiom
        config = Self.loadConfig(idiom: idiom)
        customKeys = Self.loadCustomKeys()
        drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)

        // Check if device idiom changed (e.g. restored backup from different device)
        let savedIdiom = UserDefaults.standard.string(forKey: Self.deviceIdiomKey)
        let currentIdiomString = idiom == .pad ? "pad" : "phone"
        if let savedIdiom, savedIdiom != currentIdiomString {
            // Reset to defaults for this device
            config = ToolbarLayoutConfig.defaultConfig(for: idiom)
        }
        UserDefaults.standard.set(currentIdiomString, forKey: Self.deviceIdiomKey)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
    }

    /// Re-reads externally applied values without writing them back.
    func reload(keys: Set<String>) {
        isReloading = true
        if keys.contains(Settings.KeyboardToolbar.config.name) {
            config = Self.loadConfig(idiom: currentIdiom)
        }
        if keys.contains(Settings.KeyboardToolbar.customKeys.name) {
            customKeys = Self.loadCustomKeys()
        }
        if keys.contains(Settings.KeyboardToolbar.drawerOpenByDefault.name) {
            drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        }
        if keys.contains(Settings.KeyboardToolbar.drawerToggleMode.name) {
            drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)
        }
        isReloading = false
        notifyChange()
    }

    // MARK: - Layout Mutations

    enum ToolbarSection: Equatable, Sendable {
        case leftPinned
        case mainRow
        case rightPinned
        case drawer(Int)

        var logName: String {
            switch self {
            case .leftPinned: "left pinned"
            case .mainRow: "primary"
            case .rightPinned: "right pinned"
            case .drawer(let index): "drawer \(index + 1)"
            }
        }
    }

    /// Maximum number of configurable drawer rows.
    static let maxDrawerRows = 5

    /// Number of configured drawer rows (1...maxDrawerRows).
    var drawerRowCount: Int { config.drawerRows.count }

    /// Grow or shrink the number of drawer rows. Growing appends empty rows;
    /// shrinking merges the removed rows' keys into the last remaining row so
    /// nothing is destroyed.
    func setDrawerRowCount(_ count: Int) {
        let target = max(1, min(Self.maxDrawerRows, count))
        guard target != config.drawerRows.count else { return }
        var rows = config.drawerRows
        if target > rows.count {
            rows.append(contentsOf: Array(repeating: [], count: target - rows.count))
        } else {
            let overflow = rows[target...].flatMap { $0 }
            rows = Array(rows.prefix(target))
            rows[target - 1].append(contentsOf: overflow)
        }
        var updated = config
        updated.drawerRows = rows
        config = updated
        Self.logger.info("Toolbar user action: drawer row count set to \(target, privacy: .public)")
        notifyChange()
    }

    /// Replaces all rows in a single mutation. Used by the UIKit drag editor,
    /// which computes the complete new ordering (across all sections) from its
    /// diffable snapshot. One assignment → one save → one change notification.
    ///
    /// The editor only ever shows valid slots (hidden/deleted keys are already
    /// removed from all rows by hideKey/deleteCustomKey), so assigning the
    /// snapshot's contents directly preserves the invariant that the rows hold
    /// only valid slots.
    func setLayout(leftPinned newLeft: [KeySlot], mainRow newMain: [KeySlot],
                   rightPinned newRight: [KeySlot], drawerRows newDrawers: [[KeySlot]]) {
        let drawers = newDrawers.isEmpty ? [[]] : newDrawers
        let orderedSections = [newLeft, newMain, newRight] + drawers
        var seen = Set<KeySlot>()
        let uniqueSections = orderedSections.map { row in
            row.filter { seen.insert($0).inserted }
        }
        let left = uniqueSections[0]
        let main = uniqueSections[1]
        let right = uniqueSections[2]
        let uniqueDrawers = Array(uniqueSections.dropFirst(3))
        guard config.leftPinned != left || config.mainRow != main
                || config.rightPinned != right || config.drawerRows != uniqueDrawers else { return }
        var updated = config
        updated.leftPinned = left
        updated.mainRow = main
        updated.rightPinned = right
        updated.drawerRows = uniqueDrawers
        config = updated
        Self.logger.info("Toolbar user action: saved key sections and drawer rows")
        notifyChange()
    }

    func setAppearance(_ appearance: ToolbarAppearance) {
        guard config.appearance != appearance else { return }
        var updated = config
        updated.appearance = appearance
        config = updated
        Self.logger.info("Toolbar user action: appearance changed to \(appearance.rawValue, privacy: .public)")
        notifyChange()
    }

    func setScrollScope(_ scope: ToolbarScrollScope) {
        guard config.scrollScope != scope else { return }
        var updated = config
        updated.scrollScope = scope
        config = updated
        Self.logger.info("Toolbar user action: scroll scope changed to \(scope.rawValue, privacy: .public)")
        notifyChange()
    }

    func setScrollBehavior(_ behavior: ToolbarScrollBehavior) {
        guard config.scrollBehavior != behavior else { return }
        var updated = config
        updated.scrollBehavior = behavior
        config = updated
        Self.logger.info("Toolbar user action: scroll behavior changed to \(behavior.rawValue, privacy: .public)")
        notifyChange()
    }

    func setDrawerScrollBehavior(_ behavior: ToolbarScrollBehavior) {
        guard config.drawerScrollBehavior != behavior else { return }
        var updated = config
        updated.drawerScrollBehavior = behavior
        config = updated
        Self.logger.info("Toolbar user action: drawer scroll behavior changed to \(behavior.rawValue, privacy: .public)")
        notifyChange()
    }

    func moveKeyToSection(_ slot: KeySlot, from: ToolbarSection, to: ToolbarSection) {
        guard from != to else { return }

        updateLayout(action: "move \(String(describing: slot)) from \(from.logName) to \(to.logName)") { layout in
            layout.leftPinned.removeAll { $0 == slot }
            layout.mainRow.removeAll { $0 == slot }
            layout.rightPinned.removeAll { $0 == slot }
            for i in layout.drawerRows.indices {
                layout.drawerRows[i].removeAll { $0 == slot }
            }
            switch to {
            case .leftPinned:
                layout.leftPinned.append(slot)
            case .mainRow:
                layout.mainRow.append(slot)
            case .rightPinned:
                layout.rightPinned.append(slot)
            case .drawer(let index):
                let clamped = max(0, min(layout.drawerRows.count - 1, index))
                layout.drawerRows[clamped].insert(slot, at: 0)
            }
        }
    }

    func hideKey(_ keyID: KeyID) {
        updateLayout(action: "hide \(keyID.rawValue)") { layout in
            layout.leftPinned.removeAll { $0 == .builtIn(keyID) }
            layout.mainRow.removeAll { $0 == .builtIn(keyID) }
            layout.rightPinned.removeAll { $0 == .builtIn(keyID) }
            for i in layout.drawerRows.indices {
                layout.drawerRows[i].removeAll { $0 == .builtIn(keyID) }
            }
            layout.hiddenKeys.insert(keyID)
        }
    }

    func unhideKey(_ keyID: KeyID) {
        updateLayout(action: "restore \(keyID.rawValue)") { layout in
            layout.hiddenKeys.remove(keyID)
            layout.drawerRows[0].append(.builtIn(keyID))
        }
    }

    func resetToDefaults() {
        config = ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
        Self.logger.info("Toolbar user action: reset layout to defaults")
        // Remove custom keys from layout but keep their definitions
        customKeys = []
        notifyChange()
    }

    // MARK: - Custom Key CRUD

    func createCustomKey(_ key: CustomKey) {
        customKeys.append(key)
        // Add to the first drawer row by default
        config.drawerRows[0].append(.custom(key.id))
        notifyChange()
    }

    func updateCustomKey(_ key: CustomKey) {
        if let index = customKeys.firstIndex(where: { $0.id == key.id }) {
            customKeys[index] = key
        }
        notifyChange()
    }

    func deleteCustomKey(id: UUID) {
        customKeys.removeAll { $0.id == id }
        updateLayout(action: "delete custom key \(id.uuidString)") { layout in
            layout.leftPinned.removeAll { $0 == .custom(id) }
            layout.mainRow.removeAll { $0 == .custom(id) }
            layout.rightPinned.removeAll { $0 == .custom(id) }
            for i in layout.drawerRows.indices {
                layout.drawerRows[i].removeAll { $0 == .custom(id) }
            }
        }
        notifyChange()
    }

    func customKey(for id: UUID) -> CustomKey? {
        customKeys.first { $0.id == id }
    }

    /// Custom keys whose UUID isn't placed in the main row or any drawer row.
    var unplacedCustomKeys: [CustomKey] {
        let placedIDs = Set(
            (config.leftPinned + config.mainRow + config.rightPinned + config.drawerRows.flatMap { $0 }).compactMap { slot -> UUID? in
                if case .custom(let uuid) = slot { return uuid }
                return nil
            }
        )
        return customKeys.filter { !placedIDs.contains($0.id) }
    }

    /// Removes a custom key from layout without deleting its definition.
    func removeCustomKeyFromLayout(id: UUID) {
        let slot = KeySlot.custom(id)
        updateLayout(action: "remove custom key \(id.uuidString) from toolbar") { layout in
            layout.leftPinned.removeAll { $0 == slot }
            layout.mainRow.removeAll { $0 == slot }
            layout.rightPinned.removeAll { $0 == slot }
            for i in layout.drawerRows.indices {
                layout.drawerRows[i].removeAll { $0 == slot }
            }
        }
    }

    /// Adds a custom key slot to the specified section if the definition exists
    /// and the key isn't already placed in any row.
    func addCustomKeyToLayout(id: UUID, section: ToolbarSection) {
        guard customKey(for: id) != nil else { return }
        let slot = KeySlot.custom(id)
        guard !config.leftPinned.contains(slot),
              !config.mainRow.contains(slot),
              !config.rightPinned.contains(slot),
              !config.drawerRows.contains(where: { $0.contains(slot) }) else { return }
        updateLayout(action: "add custom key \(id.uuidString) to \(section.logName)") { layout in
            switch section {
            case .leftPinned:
                layout.leftPinned.append(slot)
            case .mainRow:
                layout.mainRow.append(slot)
            case .rightPinned:
                layout.rightPinned.append(slot)
            case .drawer(let index):
                let clamped = max(0, min(layout.drawerRows.count - 1, index))
                layout.drawerRows[clamped].append(slot)
            }
        }
    }

    // MARK: - Capacity & Effective Layout

    /// How many standard buttons fit in the main row before runtime additions.
    func mainRowCapacity(availableWidth: CGFloat, sizes: KeyboardSizes) -> Int {
        let buttonWidth = sizes.button.normalWidth + sizes.toolbar.spacing
        guard buttonWidth > 0 else { return 0 }
        return max(1, Int((availableWidth + sizes.toolbar.spacing) / buttonWidth))
    }

    /// Main row and drawers must share the same capacity and reservation. A
    /// displaced key leads the first drawer, ahead of its configured contents.
    func effectiveLayout(availableWidth: CGFloat, reservedMainRowSlots: Int = 0,
                         sizes: KeyboardSizes, scrollsMainRow: Bool = false) -> (left: [KeySlot], main: [KeySlot], right: [KeySlot], drawers: [[KeySlot]]) {
        let left = validSlots(config.leftPinned)
        let right = validSlots(config.rightPinned)
        let pinned = Set(left + right)
        let main = validSlots(config.mainRow).filter { !pinned.contains($0) }
        let drawers = config.drawerRows.map { validSlots($0).filter { !pinned.contains($0) } }
        let drawerToggle = KeySlot.builtIn(.drawerToggle)
        var layout = KeyboardToolbarOverflow.layout(
            main: main,
            drawers: drawers,
            capacity: scrollsMainRow ? main.count + reservedMainRowSlots + 1 : mainRowCapacity(availableWidth: availableWidth, sizes: sizes),
            reservedSlots: reservedMainRowSlots,
            drawerToggle: drawerToggle,
            keepsDrawerToggleVisible: !config.hiddenKeys.contains(.drawerToggle) && !pinned.contains(drawerToggle))
        if pinned.contains(drawerToggle) {
            layout.main.removeAll { $0 == drawerToggle }
            layout.drawers = layout.drawers.map { $0.filter { $0 != drawerToggle } }
        }
        return (left, layout.main, right, layout.drawers)
    }

    private func updateLayout(action: String, _ update: (inout ToolbarLayoutConfig) -> Void) {
        var updated = config
        update(&updated)
        guard updated != config else { return }
        config = updated
        Self.logger.info("Toolbar user action: \(action, privacy: .public)")
        notifyChange()
    }

    /// Filter out slots that reference deleted custom keys or hidden or unavailable built-in keys
    private func validSlots(_ slots: [KeySlot]) -> [KeySlot] {
        let customIDs = Set(customKeys.map(\.id))
        return slots.filter { slot in
            switch slot {
            case .builtIn(let keyID):
                return keyID.isAvailable && !config.hiddenKeys.contains(keyID)
            case .custom(let uuid):
                return customIDs.contains(uuid)
            }
        }
    }

    // MARK: - Persistence

    private func saveConfig() {
        do {
            let data = try JSONEncoder().encode(config)
            SettingsStore.shared.set(Settings.KeyboardToolbar.config, data)
        } catch {
            Self.logger.error("Failed to save toolbar config: \(error.localizedDescription)")
        }
    }

    private func saveCustomKeys() {
        do {
            let data = try JSONEncoder().encode(customKeys)
            SettingsStore.shared.set(Settings.KeyboardToolbar.customKeys, data)
        } catch {
            Self.logger.error("Failed to save custom keys: \(error.localizedDescription)")
        }
    }

    private static func loadConfig(idiom: UIUserInterfaceIdiom) -> ToolbarLayoutConfig {
        guard let data = SettingsStore.shared.get(Settings.KeyboardToolbar.config) else {
            return ToolbarLayoutConfig.defaultConfig(for: idiom)
        }
        do {
            var config = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)
            if config.version < ToolbarLayoutConfig.currentVersion {
                config = ToolbarLayoutConfig.migrate(config, idiom: idiom)
            }
            return config
        } catch {
            logger.error("Failed to load toolbar config: \(error.localizedDescription)")
            return ToolbarLayoutConfig.defaultConfig(for: idiom)
        }
    }

    private static func loadCustomKeys() -> [CustomKey] {
        guard let data = SettingsStore.shared.get(Settings.KeyboardToolbar.customKeys) else { return [] }
        do {
            return try JSONDecoder().decode([CustomKey].self, from: data)
        } catch {
            logger.error("Failed to load custom keys: \(error.localizedDescription)")
            return []
        }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: nil)
    }
}
