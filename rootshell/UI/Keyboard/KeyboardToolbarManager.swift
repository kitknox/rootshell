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

/// A toolbar layout as it fits one width, with unavailable keys left out.
struct EffectiveToolbarLayout {
    var main: [KeySlot]
    var drawers: [[KeySlot]]
    /// Keys at each end of `main` that belong to a pinned group.
    var leadingCount = 0
    var trailingCount = 0
    /// Set when the main row scrolls: how many keys it shows at once. The
    /// keys between the pinned ends then scroll and nothing overflows.
    var visibleKeys: Int?
}

@MainActor
@Observable
class KeyboardToolbarManager {
    static let shared = KeyboardToolbarManager()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "KeyboardToolbarManager")

    static let layoutDidChangeNotification = Notification.Name("KeyboardToolbarLayoutDidChange")

    // MARK: - Storage Keys

    /// Device-only marker; stays raw because it never syncs.
    private static let deviceIdiomKey = "keyboardToolbarDeviceIdiom"

    /// Contexts whose layout is optional and follows the terminal's until split off.
    static let secondaryContexts: [ToolbarContext] = [.screenSharing, .kvm]

    private static let ownedKeys: Set<String> = [
        Settings.KeyboardToolbar.config.name,
        Settings.KeyboardToolbar.screenSharingConfig.name,
        Settings.KeyboardToolbar.kvmConfig.name,
        Settings.KeyboardToolbar.customKeys.name,
        Settings.KeyboardToolbar.savedLayouts.name,
        Settings.KeyboardToolbar.drawerOpenByDefault.name,
        Settings.KeyboardToolbar.drawerToggleMode.name,
        Settings.KeyboardToolbar.keycaps.name,
        Settings.KeyboardToolbar.style.name,
        Settings.KeyboardToolbar.minKeyWidthPhone.name,
        Settings.KeyboardToolbar.minKeyWidthPad.name,
        Settings.KeyboardToolbar.minKeyWidthDuoInner.name,
        Settings.KeyboardToolbar.minKeyWidthDuoFront.name,
    ]

    @ObservationIgnored private var isReloading = false

    // MARK: - Observable Properties

    /// The terminal's layout, which every other context shows until it has its own.
    private(set) var config: ToolbarLayoutConfig {
        didSet {
            guard !isReloading, config != oldValue else { return }
            save(config, for: .terminal)
        }
    }

    /// Layouts split off for Screen Sharing and KVM.
    private(set) var customLayouts: [ToolbarContext: ToolbarLayoutConfig] {
        didSet {
            guard !isReloading else { return }
            for context in Self.secondaryContexts where customLayouts[context] != oldValue[context] {
                save(customLayouts[context], for: context)
            }
        }
    }

    private(set) var customKeys: [CustomKey] {
        didSet {
            guard !isReloading else { return }
            saveCustomKeys()
        }
    }

    /// Named copies of layouts. A reset leaves them alone.
    private(set) var savedLayouts: [SavedToolbarLayout] {
        didSet {
            guard !isReloading, savedLayouts != oldValue else { return }
            saveSavedLayouts()
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
        }
    }

    /// Draws each key on the system keyboard's toolbar as a keycap.
    var showsKeycaps: Bool {
        didSet {
            guard !isReloading, showsKeycaps != oldValue else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.keycaps, showsKeycaps)
            notifyChange()
        }
    }

    /// How the system keyboard's toolbar is drawn.
    var toolbarStyle: KeyboardToolbarStyle {
        didSet {
            guard !isReloading, toolbarStyle != oldValue else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.style, toolbarStyle)
            notifyChange()
        }
    }

    // MARK: - Layouts

    /// The layout a context shows: its own, or the terminal's.
    func layout(for context: ToolbarContext) -> ToolbarLayoutConfig {
        customLayouts[context] ?? config
    }

    func hasOwnLayout(_ context: ToolbarContext) -> Bool {
        context == .terminal || customLayouts[context] != nil
    }

    /// Gives a context its own layout, starting as a copy of the one it shows now.
    func splitLayout(for context: ToolbarContext) {
        guard context != .terminal, customLayouts[context] == nil else { return }
        customLayouts[context] = layout(for: context)
        notifyChange()
    }

    // MARK: - Copies and Saved Layouts

    /// The toolbars worth copying into `context`: each other layout once, and
    /// never the one `context` already owns.
    func copySources(for context: ToolbarContext) -> [ToolbarContext] {
        ToolbarContext.allCases.filter { source in
            guard source != context else { return false }
            // One that follows the terminal is the terminal's layout again.
            return source == .terminal || hasOwnLayout(source)
        }
    }

    /// Replaces a toolbar's layout with a copy of another's. One that followed
    /// the terminal gets a layout of its own.
    func copyLayout(from source: ToolbarContext, to context: ToolbarContext) {
        guard source != context else { return }
        replaceLayout(of: context, with: layout(for: source))
    }

    private func replaceLayout(of context: ToolbarContext, with layout: ToolbarLayoutConfig) {
        var layout = layout
        if layout.drawerRows.isEmpty { layout.drawerRows = [[]] }
        if context == .terminal {
            config = layout
        } else {
            customLayouts[context] = layout
        }
        notifyChange()
    }

    /// "Terminal 1", "Terminal 2": the first such name not taken.
    func suggestedSaveName(for context: ToolbarContext) -> String {
        let taken = Set(savedLayouts.map(\.name))
        var number = 1
        while taken.contains("\(context.displayName) \(number)") { number += 1 }
        return "\(context.displayName) \(number)"
    }

    /// Saves the layout a toolbar shows now. A blank name takes the suggested one.
    @discardableResult
    func saveLayout(of context: ToolbarContext, named name: String) -> SavedToolbarLayout {
        let layout = self.layout(for: context)
        let placed = Set(layout.placedSlots.compactMap(\.customID))
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedToolbarLayout(
            name: trimmed.isEmpty ? suggestedSaveName(for: context) : trimmed,
            sourceName: context.rawValue, date: Date(), layout: layout,
            customKeys: customKeys.filter { placed.contains($0.id) })
        savedLayouts.append(saved)
        return saved
    }

    /// Puts a saved layout on a toolbar, any toolbar, along with custom keys
    /// it places that were deleted since.
    func restore(_ saved: SavedToolbarLayout, to context: ToolbarContext) {
        let known = Set(customKeys.map(\.id))
        let missing = saved.customKeys.filter { !known.contains($0.id) }
        if !missing.isEmpty { customKeys.append(contentsOf: missing) }
        replaceLayout(of: context, with: ToolbarLayoutConfig.migrate(saved.layout, idiom: currentIdiom))
    }

    func renameSavedLayout(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = savedLayouts.firstIndex(where: { $0.id == id }) else { return }
        savedLayouts[index].name = trimmed
    }

    func deleteSavedLayout(id: UUID) {
        savedLayouts.removeAll { $0.id == id }
    }

    /// Drops a context's own layout so it shows the terminal's again.
    func removeOwnLayout(for context: ToolbarContext) {
        guard context != .terminal, customLayouts[context] != nil else { return }
        customLayouts[context] = nil
        notifyChange()
    }

    /// True once anything differs from a fresh install.
    var isCustomized: Bool {
        config != ToolbarLayoutConfig.defaultConfig(for: currentIdiom) || !customLayouts.isEmpty || !customKeys.isEmpty
    }

    func isCustomized(_ context: ToolbarContext) -> Bool {
        context == .terminal
            ? config != ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
            : customLayouts[context] != nil
    }

    private var currentIdiom: UIUserInterfaceIdiom {
        UIDevice.current.userInterfaceIdiom
    }

    // MARK: - Initialization

    private init() {
        let idiom = UIDevice.current.userInterfaceIdiom
        config = Self.loadLayout(for: .terminal, idiom: idiom) ?? ToolbarLayoutConfig.defaultConfig(for: idiom)
        customLayouts = Self.loadCustomLayouts(idiom: idiom)
        customKeys = Self.loadCustomKeys()
        savedLayouts = Self.loadSavedLayouts()
        drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)
        showsKeycaps = SettingsStore.shared.get(Settings.KeyboardToolbar.keycaps)
        toolbarStyle = SettingsStore.shared.get(Settings.KeyboardToolbar.style)

        // Check if device idiom changed (e.g. restored backup from different device)
        let savedIdiom = UserDefaults.standard.string(forKey: Self.deviceIdiomKey)
        let currentIdiomString = idiom == .pad ? "pad" : "phone"
        if let savedIdiom, savedIdiom != currentIdiomString {
            // Reset to defaults for this device
            config = ToolbarLayoutConfig.defaultConfig(for: idiom)
            customLayouts = [:]
        }
        UserDefaults.standard.set(currentIdiomString, forKey: Self.deviceIdiomKey)

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }
        // The minimum key width is per display, so moving between a Duo's displays refits the row.
        NotificationCenter.default.addObserver(forName: .duoDisplayDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notifyChange() }
        }
    }

    /// Re-reads externally applied values without writing them back.
    func reload(keys: Set<String>) {
        isReloading = true
        if keys.contains(Settings.KeyboardToolbar.config.name) {
            config = Self.loadLayout(for: .terminal, idiom: currentIdiom)
                ?? ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
        }
        for context in Self.secondaryContexts where keys.contains(Settings.KeyboardToolbar.layoutKey(for: context).name) {
            customLayouts[context] = Self.loadLayout(for: context, idiom: currentIdiom)
        }
        if keys.contains(Settings.KeyboardToolbar.customKeys.name) {
            customKeys = Self.loadCustomKeys()
        }
        if keys.contains(Settings.KeyboardToolbar.savedLayouts.name) {
            savedLayouts = Self.loadSavedLayouts()
        }
        if keys.contains(Settings.KeyboardToolbar.drawerOpenByDefault.name) {
            drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        }
        if keys.contains(Settings.KeyboardToolbar.drawerToggleMode.name) {
            drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)
        }
        if keys.contains(Settings.KeyboardToolbar.keycaps.name) {
            showsKeycaps = SettingsStore.shared.get(Settings.KeyboardToolbar.keycaps)
        }
        if keys.contains(Settings.KeyboardToolbar.style.name) {
            toolbarStyle = SettingsStore.shared.get(Settings.KeyboardToolbar.style)
        }
        isReloading = false
        notifyChange()
    }

    // MARK: - Layout Mutations

    enum ToolbarSection: Equatable, Sendable {
        case pinnedLeading
        case mainRow
        case pinnedTrailing
        case drawer(Int)
    }

    /// The optional groups a layout can turn on.
    enum PinnedGroup: Sendable {
        case leading
        case trailing
    }

    /// Maximum number of configurable drawer rows.
    static let maxDrawerRows = 5

    /// One change, one save, one notification. A context that still follows
    /// the terminal has nothing of its own to change.
    private func update(_ context: ToolbarContext, _ change: (inout ToolbarLayoutConfig) -> Void) {
        guard hasOwnLayout(context) else { return }
        var updated = layout(for: context)
        change(&updated)
        if updated.drawerRows.isEmpty { updated.drawerRows = [[]] }
        guard updated != layout(for: context) else { return }
        if context == .terminal {
            config = updated
        } else {
            customLayouts[context] = updated
        }
        notifyChange()
    }

    /// Number of configured drawer rows (1...maxDrawerRows).
    func drawerRowCount(in context: ToolbarContext) -> Int {
        layout(for: context).drawerRows.count
    }

    /// Grow or shrink the number of drawer rows. Growing appends empty rows;
    /// shrinking merges the removed rows' keys into the last remaining row so
    /// nothing is destroyed.
    func setDrawerRowCount(_ count: Int, in context: ToolbarContext) {
        let target = max(1, min(Self.maxDrawerRows, count))
        update(context) { layout in
            guard target != layout.drawerRows.count else { return }
            if target > layout.drawerRows.count {
                layout.drawerRows.append(contentsOf: Array(repeating: [], count: target - layout.drawerRows.count))
            } else {
                let overflow = layout.drawerRows[target...].flatMap { $0 }
                layout.drawerRows = Array(layout.drawerRows.prefix(target))
                layout.drawerRows[target - 1].append(contentsOf: overflow)
            }
        }
    }

    func setDrawerMatchesMainRow(_ matches: Bool, in context: ToolbarContext) {
        update(context) { $0.drawerMatchesMainRow = matches }
    }

    func setMainRowScrolls(_ scrolls: Bool, in context: ToolbarContext) {
        update(context) { $0.mainRowScrolls = scrolls }
    }

    func setScrollingModifierSwipes(_ swipes: Bool, in context: ToolbarContext) {
        update(context) { $0.scrollingModifierSwipes = swipes }
    }

    /// A display's minimum key width, in points. The low end of the range,
    /// or anything under it, leaves the width to the toolbar.
    func setMinimumKeyWidth(_ width: Double, for key: SettingKey<Double>) {
        let range = KeyboardToolbarSize.minimumKeyWidthRange
        let value = width > range.lowerBound ? min(width, range.upperBound) : 0
        guard SettingsStore.shared.value(key) != value else { return }
        SettingsStore.shared.set(key, value)
        notifyChange()
    }

    func isPinnedGroupOn(_ group: PinnedGroup, in context: ToolbarContext) -> Bool {
        let layout = self.layout(for: context)
        return (group == .leading ? layout.pinnedLeading : layout.pinnedTrailing) != nil
    }

    /// Turning a group off returns its keys to the matching end of the main row.
    func setPinnedGroup(_ group: PinnedGroup, on: Bool, in context: ToolbarContext) {
        update(context) { layout in
            switch group {
            case .leading:
                if on {
                    layout.pinnedLeading = layout.pinnedLeading ?? []
                } else {
                    layout.mainRow.insert(contentsOf: layout.pinnedLeading ?? [], at: 0)
                    layout.pinnedLeading = nil
                }
            case .trailing:
                if on {
                    layout.pinnedTrailing = layout.pinnedTrailing ?? []
                } else {
                    layout.mainRow.append(contentsOf: layout.pinnedTrailing ?? [])
                    layout.pinnedTrailing = nil
                }
            }
        }
    }

    /// Replaces every row in a single mutation. Used by the UIKit drag editor,
    /// which computes the complete new ordering from its diffable snapshot.
    /// A nil pinned group leaves that group as it is.
    func setLayout(pinnedLeading: [KeySlot]? = nil, mainRow: [KeySlot], pinnedTrailing: [KeySlot]? = nil,
                   drawerRows: [[KeySlot]], in context: ToolbarContext) {
        update(context) { layout in
            if let pinnedLeading, layout.pinnedLeading != nil { layout.pinnedLeading = pinnedLeading }
            if let pinnedTrailing, layout.pinnedTrailing != nil { layout.pinnedTrailing = pinnedTrailing }
            layout.mainRow = mainRow
            layout.drawerRows = drawerRows
        }
    }

    /// Moves a key to the end of the main row or a pinned group, or to the
    /// front of a drawer row.
    func moveKey(_ slot: KeySlot, to section: ToolbarSection, in context: ToolbarContext) {
        update(context) { layout in
            layout.remove(slot)
            switch section {
            case .pinnedLeading where layout.pinnedLeading != nil:
                layout.pinnedLeading?.append(slot)
            case .pinnedTrailing where layout.pinnedTrailing != nil:
                layout.pinnedTrailing?.append(slot)
            case .pinnedLeading, .pinnedTrailing, .mainRow:
                layout.mainRow.append(slot)
            case .drawer(let index):
                let clamped = max(0, min(layout.drawerRows.count - 1, index))
                layout.drawerRows[clamped].insert(slot, at: 0)
            }
        }
    }

    /// Moves a key to the start or end of the row that already holds it.
    func moveKey(_ slot: KeySlot, toStart: Bool, in context: ToolbarContext) {
        update(context) { layout in
            func reposition(_ row: [KeySlot]) -> [KeySlot]? {
                guard row.contains(slot) else { return nil }
                let rest = row.filter { $0 != slot }
                return toStart ? [slot] + rest : rest + [slot]
            }
            if let row = layout.pinnedLeading.flatMap(reposition) {
                layout.pinnedLeading = row
            } else if let row = reposition(layout.mainRow) {
                layout.mainRow = row
            } else if let row = layout.pinnedTrailing.flatMap(reposition) {
                layout.pinnedTrailing = row
            } else if let index = layout.drawerRows.firstIndex(where: { $0.contains(slot) }),
                      let row = reposition(layout.drawerRows[index]) {
                layout.drawerRows[index] = row
            }
        }
    }

    func hideKey(_ keyID: KeyID, in context: ToolbarContext) {
        update(context) { layout in
            layout.remove(.builtIn(keyID))
            layout.hiddenKeys.insert(keyID)
        }
    }

    func unhideKey(_ keyID: KeyID, in context: ToolbarContext) {
        update(context) { layout in
            guard layout.hiddenKeys.remove(keyID) != nil else { return }
            // Add back to the first drawer row by default
            layout.drawerRows[0].append(.builtIn(keyID))
        }
    }

    /// Restores the terminal's default layout. Custom key definitions stay.
    func resetLayout(for context: ToolbarContext) {
        if context == .terminal {
            update(.terminal) { $0 = ToolbarLayoutConfig.defaultConfig(for: currentIdiom) }
        } else {
            removeOwnLayout(for: context)
        }
    }

    /// Back to a fresh install: default terminal layout, no layouts of their
    /// own for the other contexts, and no custom keys.
    func resetToDefaults() {
        config = ToolbarLayoutConfig.defaultConfig(for: currentIdiom)
        customLayouts = [:]
        customKeys = []
        notifyChange()
    }

    // MARK: - Custom Key CRUD

    /// Custom keys are one shared set; each layout places them itself. A new
    /// key starts in the first drawer row of the layout it was made for.
    func createCustomKey(_ key: CustomKey, in context: ToolbarContext) {
        customKeys.append(key)
        let owner = hasOwnLayout(context) ? context : .terminal
        update(owner) { $0.drawerRows[0].append(.custom(key.id)) }
    }

    func updateCustomKey(_ key: CustomKey) {
        if let index = customKeys.firstIndex(where: { $0.id == key.id }) {
            customKeys[index] = key
        }
        notifyChange()
    }

    func deleteCustomKey(id: UUID) {
        customKeys.removeAll { $0.id == id }
        for context in ToolbarContext.allCases {
            update(context) { $0.remove(.custom(id)) }
        }
        notifyChange()
    }

    func customKey(for id: UUID) -> CustomKey? {
        customKeys.first { $0.id == id }
    }

    /// Custom keys a layout places nowhere.
    func unplacedCustomKeys(in context: ToolbarContext) -> [CustomKey] {
        let placedIDs = Set(layout(for: context).placedSlots.compactMap(\.customID))
        return customKeys.filter { !placedIDs.contains($0.id) }
    }

    /// Removes a custom key from a layout without deleting its definition.
    func removeCustomKeyFromLayout(id: UUID, in context: ToolbarContext) {
        update(context) { $0.remove(.custom(id)) }
    }

    /// Adds a custom key slot to the specified section if the definition exists
    /// and the key isn't already placed in any row.
    func addCustomKeyToLayout(id: UUID, section: ToolbarSection, in context: ToolbarContext) {
        guard customKey(for: id) != nil else { return }
        let slot = KeySlot.custom(id)
        update(context) { layout in
            guard !layout.placedSlots.contains(slot) else { return }
            switch section {
            case .pinnedLeading where layout.pinnedLeading != nil:
                layout.pinnedLeading?.append(slot)
            case .pinnedTrailing where layout.pinnedTrailing != nil:
                layout.pinnedTrailing?.append(slot)
            case .pinnedLeading, .pinnedTrailing, .mainRow:
                layout.mainRow.append(slot)
            case .drawer(let index):
                let clamped = max(0, min(layout.drawerRows.count - 1, index))
                layout.drawerRows[clamped].append(slot)
            }
        }
    }

    // MARK: - Capacity & Effective Layout

    /// How many standard buttons fit in the main row before runtime additions.
    func mainRowCapacity(availableWidth: CGFloat, sizes: KeyboardSizes, minimumKeyWidth: Double = 0) -> Int {
        let buttonWidth = max(sizes.button.normalWidth, CGFloat(minimumKeyWidth)) + sizes.toolbar.spacing
        guard buttonWidth > 0 else { return 0 }
        return max(1, Int((availableWidth + sizes.toolbar.spacing) / buttonWidth))
    }

    /// A context's main-row capacity: its minimum key width, less whatever
    /// its pinned keys need back.
    func mainRowCapacity(for context: ToolbarContext, availableWidth: CGFloat, reservedMainRowSlots: Int = 0,
                         sizes: KeyboardSizes) -> Int {
        let layout = self.layout(for: context)
        let pinned = validSlots((layout.pinnedLeading ?? []) + (layout.pinnedTrailing ?? []), in: layout)
        return KeyboardToolbarOverflow.capacity(
            usual: mainRowCapacity(availableWidth: availableWidth, sizes: sizes),
            widened: mainRowCapacity(availableWidth: availableWidth, sizes: sizes,
                                     minimumKeyWidth: KeyboardToolbarSize.currentMinimumKeyWidth),
            pinned: pinned.count, reservedSlots: reservedMainRowSlots,
            drawerToggle: !layout.hiddenKeys.contains(.drawerToggle) && !pinned.contains(.builtIn(.drawerToggle)),
            scrolls: layout.mainRowScrolls)
    }

    /// Main row and drawers must share the same capacity and reservation. A
    /// displaced key leads the first drawer, ahead of its configured contents.
    func effectiveLayout(for context: ToolbarContext, availableWidth: CGFloat, reservedMainRowSlots: Int = 0,
                         sizes: KeyboardSizes) -> EffectiveToolbarLayout {
        let layout = self.layout(for: context)
        let leading = validSlots(layout.pinnedLeading ?? [], in: layout)
        let trailing = validSlots(layout.pinnedTrailing ?? [], in: layout)
        let main = validSlots(layout.mainRow, in: layout)
        let drawers = layout.drawerRows.map { validSlots($0, in: layout) }
        let keepsDrawerToggle = !layout.hiddenKeys.contains(.drawerToggle)
        let capacity = mainRowCapacity(for: context, availableWidth: availableWidth,
                                       reservedMainRowSlots: reservedMainRowSlots, sizes: sizes)
        if layout.mainRowScrolls, let scrolling = KeyboardToolbarOverflow.scrollingLayout(
            leading: leading, main: main, trailing: trailing, drawers: drawers, capacity: capacity,
            reservedSlots: reservedMainRowSlots, drawerToggle: .builtIn(.drawerToggle),
            keepsDrawerToggleVisible: keepsDrawerToggle) {
            return EffectiveToolbarLayout(
                main: scrolling.leading + scrolling.middle + scrolling.trailing, drawers: scrolling.drawers,
                leadingCount: scrolling.leading.count, trailingCount: scrolling.trailing.count,
                visibleKeys: capacity)
        }
        let fitted = KeyboardToolbarOverflow.layout(
            leading: leading,
            main: main,
            trailing: trailing,
            drawers: drawers,
            capacity: capacity,
            reservedSlots: reservedMainRowSlots,
            drawerToggle: .builtIn(.drawerToggle),
            keepsDrawerToggleVisible: keepsDrawerToggle)
        return EffectiveToolbarLayout(
            main: fitted.main, drawers: fitted.drawers,
            leadingCount: fitted.main.prefix { leading.contains($0) }.count,
            trailingCount: fitted.main.reversed().prefix { trailing.contains($0) }.count)
    }

    /// Filter out slots that reference deleted custom keys or hidden or unavailable built-in keys
    func validSlots(_ slots: [KeySlot], in layout: ToolbarLayoutConfig) -> [KeySlot] {
        let customIDs = Set(customKeys.map(\.id))
        return slots.filter { slot in
            switch slot {
            case .builtIn(let keyID):
                return keyID.isAvailable && !layout.hiddenKeys.contains(keyID)
            case .custom(let uuid):
                return customIDs.contains(uuid)
            }
        }
    }

    // MARK: - Persistence

    /// nil clears a context's own layout.
    private func save(_ layout: ToolbarLayoutConfig?, for context: ToolbarContext) {
        do {
            let data = try layout.map { try JSONEncoder().encode($0) }
            SettingsStore.shared.set(Settings.KeyboardToolbar.layoutKey(for: context), data)
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

    private func saveSavedLayouts() {
        do {
            let data = savedLayouts.isEmpty ? nil : try JSONEncoder().encode(savedLayouts)
            SettingsStore.shared.set(Settings.KeyboardToolbar.savedLayouts, data)
        } catch {
            Self.logger.error("Failed to save saved toolbar layouts: \(error.localizedDescription)")
        }
    }

    private static func loadSavedLayouts() -> [SavedToolbarLayout] {
        guard let data = SettingsStore.shared.get(Settings.KeyboardToolbar.savedLayouts) else { return [] }
        do {
            return try JSONDecoder().decode([SavedToolbarLayout].self, from: data)
        } catch {
            logger.error("Failed to load saved toolbar layouts: \(error.localizedDescription)")
            return []
        }
    }

    private static func loadLayout(for context: ToolbarContext, idiom: UIUserInterfaceIdiom) -> ToolbarLayoutConfig? {
        guard let data = SettingsStore.shared.get(Settings.KeyboardToolbar.layoutKey(for: context)) else { return nil }
        do {
            var config = try JSONDecoder().decode(ToolbarLayoutConfig.self, from: data)
            if config.version < ToolbarLayoutConfig.currentVersion {
                config = ToolbarLayoutConfig.migrate(config, idiom: idiom)
            }
            return config
        } catch {
            logger.error("Failed to load toolbar config: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadCustomLayouts(idiom: UIUserInterfaceIdiom) -> [ToolbarContext: ToolbarLayoutConfig] {
        var layouts: [ToolbarContext: ToolbarLayoutConfig] = [:]
        for context in secondaryContexts {
            layouts[context] = loadLayout(for: context, idiom: idiom)
        }
        return layouts
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
