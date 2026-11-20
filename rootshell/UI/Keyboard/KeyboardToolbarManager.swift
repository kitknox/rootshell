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

    private static let ownedKeys = Set<String>([
        Settings.KeyboardToolbar.config.name,
        Settings.KeyboardToolbar.screenSharingConfig.name,
        Settings.KeyboardToolbar.kvmConfig.name,
        Settings.KeyboardToolbar.customKeys.name,
        Settings.KeyboardToolbar.savedLayouts.name,
        Settings.KeyboardToolbar.drawerOpenByDefault.name,
        Settings.KeyboardToolbar.drawerToggleMode.name,
        Settings.KeyboardToolbar.keycaps.name,
        Settings.KeyboardToolbar.style.name,
        Settings.KeyboardToolbar.glassBarWithTerminalKeyboard.name,
        Settings.KeyboardToolbar.glyphColoring.name,
        Settings.KeyboardToolbar.keyColors.name,
        Settings.KeyboardToolbar.minKeyWidthPhone.name,
        Settings.KeyboardToolbar.minKeyWidthPad.name,
        Settings.KeyboardToolbar.minKeyWidthDuoInner.name,
        Settings.KeyboardToolbar.minKeyWidthDuoFront.name,
    ]).union(glyphColorKeys.map(\.name))

    @ObservationIgnored private var isReloading = false

    /// Set while an undoable edit, an undo or a redo changes the toolbar.
    @ObservationIgnored private var isRecordingEdit = false
    /// The toolbar as the undo history last left it; nil with no history.
    @ObservationIgnored private var recordedState: EditSnapshot?
    /// The undo managers holding that history.
    @ObservationIgnored private let historyHolders = NSHashTable<UndoManager>.weakObjects()
    /// Changes whenever the undo history does, which SwiftUI cannot see for itself.
    private(set) var historyRevision = 0

    // MARK: - Observable Properties

    /// The terminal's layout, which every other context shows until it has its own.
    private(set) var config: ToolbarLayoutConfig {
        didSet {
            guard !isReloading, config != oldValue else { return }
            save(config, to: Settings.KeyboardToolbar.layoutKey(for: .terminal))
        }
    }

    /// Layouts split off for Screen Sharing and KVM.
    private(set) var customLayouts: [ToolbarContext: ToolbarLayoutConfig] {
        didSet {
            guard !isReloading else { return }
            for context in Self.secondaryContexts where customLayouts[context] != oldValue[context] {
                // nil clears a context's own layout.
                save(customLayouts[context], to: Settings.KeyboardToolbar.layoutKey(for: context))
            }
        }
    }

    private(set) var customKeys: [CustomKey] {
        didSet {
            guard !isReloading else { return }
            save(customKeys, to: Settings.KeyboardToolbar.customKeys)
        }
    }

    /// Named copies of layouts. A reset leaves them alone.
    private(set) var savedLayouts: [SavedToolbarLayout] {
        didSet {
            guard !isReloading, savedLayouts != oldValue else { return }
            save(savedLayouts.isEmpty ? nil : savedLayouts, to: Settings.KeyboardToolbar.savedLayouts)
        }
    }

    /// Colors set on single built-in keys: `KeyID` raw value to hex RGB.
    /// Raw keys keep a newer build's entries. Custom keys carry their own.
    private(set) var keyColors: [String: String] {
        didSet {
            guard !isReloading, keyColors != oldValue else { return }
            save(keyColors.isEmpty ? nil : keyColors, to: Settings.KeyboardToolbar.keyColors)
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

    /// The docked terminal keyboard drops its own toolbar row for the glass bar.
    var terminalKeyboardUsesGlassBar: Bool {
        didSet {
            guard !isReloading, terminalKeyboardUsesGlassBar != oldValue else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.glassBarWithTerminalKeyboard, terminalKeyboardUsesGlassBar)
            notifyChange()
        }
    }

    /// How every toolbar colors its keys' glyphs.
    var glyphColoring: KeyboardToolbarGlyphColoring {
        didSet {
            guard !isReloading, glyphColoring != oldValue else { return }
            SettingsStore.shared.set(Settings.KeyboardToolbar.glyphColoring, glyphColoring)
            notifyChange()
        }
    }

    // MARK: - Glyph Colors

    /// A key's glyph color as hex: its own, else the toolbar's. nil keeps the
    /// surface's own ink. Every surface resolves colors here.
    func glyphColorHex(for slot: KeySlot) -> String? {
        ownGlyphColorHex(for: slot) ?? glyphColorHex(for: slot.glyphKind)
    }

    /// The color set on this one key, on every toolbar that places it.
    func ownGlyphColorHex(for slot: KeySlot) -> String? {
        switch slot {
        case .builtIn(let id): return keyColors[id.rawValue]
        case .custom(let id): return customKey(for: id)?.colorHex
        }
    }

    /// nil returns the key to the toolbar's colors.
    func setOwnGlyphColor(_ hex: String?, for slot: KeySlot) {
        guard ownGlyphColorHex(for: slot) != hex else { return }
        switch slot {
        case .builtIn(let id):
            keyColors[id.rawValue] = hex
        case .custom(let id):
            guard let index = customKeys.firstIndex(where: { $0.id == id }) else { return }
            customKeys[index].colorHex = hex
        }
        notifyChange()
    }

    var hasOwnGlyphColors: Bool {
        !keyColors.isEmpty || customKeys.contains { $0.colorHex != nil }
    }

    func clearOwnGlyphColors() {
        guard hasOwnGlyphColors else { return }
        keyColors = [:]
        if customKeys.contains(where: { $0.colorHex != nil }) {
            customKeys = customKeys.map { var key = $0; key.colorHex = nil; return key }
        }
        notifyChange()
    }

    func glyphColorHex(for kind: ToolbarGlyphKind) -> String? {
        switch glyphColoring {
        case .standard: return nil
        case .single: return SettingsStore.shared.value(Settings.KeyboardToolbar.glyphColor)
        case .byKind: return SettingsStore.shared.value(kind.colorKey)
        }
    }

    func glyphColor(for slot: KeySlot) -> UIColor? {
        glyphColorHex(for: slot).flatMap { UIColor(hex: $0) }
    }

    func setGlyphColor(_ color: UIColor, for key: SettingKey<String>) {
        let hex = color.hexString
        guard SettingsStore.shared.value(key) != hex else { return }
        SettingsStore.shared.set(key, hex)
        notifyChange()
    }

    /// One Color's color, then each key type's.
    static let glyphColorKeys = [Settings.KeyboardToolbar.glyphColor] + ToolbarGlyphKind.allCases.map(\.colorKey)

    /// Reads the observable setting, so a view that asks redraws when it changes.
    func isGlyphColorChanged(_ key: SettingKey<String>) -> Bool {
        let stored = SettingsStore.shared.box(for: key.name).value.flatMap(String.init(codableValue:))
        return stored.map { $0 != key.defaultValue } ?? false
    }

    func resetGlyphColors(_ keys: [SettingKey<String>]) {
        let changed = keys.filter(isGlyphColorChanged)
        guard !changed.isEmpty else { return }
        changed.forEach { SettingsStore.shared.reset($0) }
        notifyChange()
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
        keyColors = Self.loadKeyColors()
        drawerOpenByDefault = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerOpenByDefault)
        drawerToggleMode = SettingsStore.shared.get(Settings.KeyboardToolbar.drawerToggleMode)
        showsKeycaps = SettingsStore.shared.get(Settings.KeyboardToolbar.keycaps)
        toolbarStyle = SettingsStore.shared.get(Settings.KeyboardToolbar.style)
        terminalKeyboardUsesGlassBar = SettingsStore.shared.get(Settings.KeyboardToolbar.glassBarWithTerminalKeyboard)
        glyphColoring = SettingsStore.shared.get(Settings.KeyboardToolbar.glyphColoring)

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
        if keys.contains(Settings.KeyboardToolbar.keyColors.name) {
            keyColors = Self.loadKeyColors()
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
        if keys.contains(Settings.KeyboardToolbar.glassBarWithTerminalKeyboard.name) {
            terminalKeyboardUsesGlassBar = SettingsStore.shared.get(Settings.KeyboardToolbar.glassBarWithTerminalKeyboard)
        }
        if keys.contains(Settings.KeyboardToolbar.glyphColoring.name) {
            glyphColoring = SettingsStore.shared.get(Settings.KeyboardToolbar.glyphColoring)
        }
        isReloading = false
        notifyChange()
    }

    // MARK: - Layout Mutations

    nonisolated enum ToolbarSection: Hashable, Sendable {
        case pinnedLeading
        case mainRow
        case pinnedTrailing
        case drawer(Int)

        /// A lone drawer row is "Drawer"; more are numbered.
        func title(drawerRows: Int) -> String {
            switch self {
            case .pinnedLeading: return String(localized: "Pinned Left")
            case .mainRow: return String(localized: "Main Row")
            case .pinnedTrailing: return String(localized: "Pinned Right")
            case .drawer(let index):
                return drawerRows == 1 ? String(localized: "Drawer") : String(localized: "Drawer \(index + 1)")
            }
        }
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
        let value = KeyboardToolbarSize.normalizedMinimumKeyWidth(width)
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

    /// The rows a layout has, in display order.
    func sections(in context: ToolbarContext) -> [ToolbarSection] {
        let layout = self.layout(for: context)
        var sections: [ToolbarSection] = []
        if layout.pinnedLeading != nil { sections.append(.pinnedLeading) }
        sections.append(.mainRow)
        if layout.pinnedTrailing != nil { sections.append(.pinnedTrailing) }
        sections += layout.drawerRows.indices.map { ToolbarSection.drawer($0) }
        return sections
    }

    func slots(in section: ToolbarSection, of context: ToolbarContext) -> [KeySlot] {
        let layout = self.layout(for: context)
        switch section {
        case .pinnedLeading: return layout.pinnedLeading ?? []
        case .mainRow: return layout.mainRow
        case .pinnedTrailing: return layout.pinnedTrailing ?? []
        case .drawer(let index): return layout.drawerRows.indices.contains(index) ? layout.drawerRows[index] : []
        }
    }

    /// The row a key is placed in; nil for a hidden or unplaced key.
    func section(holding slot: KeySlot, in context: ToolbarContext) -> ToolbarSection? {
        if let keyID = slot.keyID, layout(for: context).hiddenKeys.contains(keyID) { return nil }
        return sections(in: context).first { slots(in: $0, of: context).contains(slot) }
    }

    /// Puts keys in a row, ahead of `anchor` or at the end. A hidden key comes
    /// back and a placed one moves.
    func placeKeys(_ slots: [KeySlot], in section: ToolbarSection, before anchor: KeySlot? = nil,
                   in context: ToolbarContext) {
        let slots = slots.filter { slot in
            slot != anchor && (slot.customID.map { customKey(for: $0) != nil } ?? true)
        }
        guard !slots.isEmpty else { return }
        update(context) { layout in
            for slot in slots {
                layout.remove(slot)
                if let keyID = slot.keyID { layout.hiddenKeys.remove(keyID) }
            }
            func inserting(into row: [KeySlot]) -> [KeySlot] {
                var row = row
                row.insert(contentsOf: slots, at: anchor.flatMap { row.firstIndex(of: $0) } ?? row.count)
                return row
            }
            switch section {
            case .pinnedLeading where layout.pinnedLeading != nil:
                layout.pinnedLeading = inserting(into: layout.pinnedLeading ?? [])
            case .pinnedTrailing where layout.pinnedTrailing != nil:
                layout.pinnedTrailing = inserting(into: layout.pinnedTrailing ?? [])
            case .pinnedLeading, .pinnedTrailing, .mainRow:
                layout.mainRow = inserting(into: layout.mainRow)
            case .drawer(let index):
                let clamped = max(0, min(layout.drawerRows.count - 1, index))
                layout.drawerRows[clamped] = inserting(into: layout.drawerRows[clamped])
            }
        }
    }

    /// Takes keys off a toolbar: a built-in key is hidden, a custom key keeps
    /// its definition.
    func removeKeys(_ slots: [KeySlot], in context: ToolbarContext) {
        update(context) { layout in
            for slot in slots {
                layout.remove(slot)
                if let keyID = slot.keyID { layout.hiddenKeys.insert(keyID) }
            }
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

    // MARK: - Undo

    /// Everything a toolbar edit can change.
    private struct EditSnapshot: Equatable {
        var config: ToolbarLayoutConfig
        var customLayouts: [ToolbarContext: ToolbarLayoutConfig]
        var customKeys: [CustomKey]
        var keyColors: [String: String]
    }

    /// The parts of that state one edit changed, as they were before it. Undo
    /// puts back only these, so it leaves later and unrelated changes alone.
    private struct EditPatch {
        var config: ToolbarLayoutConfig?
        /// A context's own layout; a nil value is a context that had none.
        var customLayouts: [ToolbarContext: ToolbarLayoutConfig?] = [:]
        var customKeys: [CustomKey]?
        var keyColors: [String: String]?

        var isEmpty: Bool {
            config == nil && customLayouts.isEmpty && customKeys == nil && keyColors == nil
        }
    }

    private var editSnapshot: EditSnapshot {
        EditSnapshot(config: config, customLayouts: customLayouts, customKeys: customKeys, keyColors: keyColors)
    }

    /// What turns the state now back into `before`.
    private func patch(restoring before: EditSnapshot) -> EditPatch {
        var patch = EditPatch()
        if config != before.config { patch.config = before.config }
        for context in Self.secondaryContexts where customLayouts[context] != before.customLayouts[context] {
            patch.customLayouts.updateValue(before.customLayouts[context], forKey: context)
        }
        if customKeys != before.customKeys { patch.customKeys = before.customKeys }
        if keyColors != before.keyColors { patch.keyColors = before.keyColors }
        return patch
    }

    /// Applies a patch and returns the one that reverses it.
    private func apply(_ patch: EditPatch) -> EditPatch {
        let before = editSnapshot
        isRecordingEdit = true
        if let config = patch.config { self.config = config }
        for (context, layout) in patch.customLayouts { customLayouts[context] = layout }
        if let customKeys = patch.customKeys { self.customKeys = customKeys }
        if let keyColors = patch.keyColors { self.keyColors = keyColors }
        notifyChange()
        isRecordingEdit = false
        return self.patch(restoring: before)
    }

    /// Runs an edit and registers its undo, which in turn registers the redo.
    func undoably(_ name: String, with undoManager: UndoManager?, _ edit: () -> Void) {
        let before = editSnapshot
        isRecordingEdit = true
        edit()
        isRecordingEdit = false
        register(patch(restoring: before), named: name, with: undoManager)
    }

    private func register(_ patch: EditPatch, named name: String, with undoManager: UndoManager?) {
        guard !patch.isEmpty else { return }
        // History kept anywhere else was made against a state this edit has replaced.
        retireHistory(except: undoManager)
        recordedState = editSnapshot
        guard let undoManager else { return }
        historyHolders.add(undoManager)
        undoManager.registerUndo(withTarget: self) { [weak undoManager] manager in
            manager.register(manager.apply(patch), named: name, with: undoManager)
        }
        undoManager.setActionName(name)
        historyRevision += 1
    }

    /// Drops undo history the toolbar no longer matches. An undo puts back
    /// whole layouts, so one made before a change from elsewhere would undo
    /// that change too.
    private func retireHistory(except keeper: UndoManager? = nil) {
        for holder in historyHolders.allObjects where holder !== keeper {
            holder.removeAllActions(withTarget: self)
            historyHolders.remove(holder)
        }
        if keeper == nil { recordedState = nil }
        historyRevision += 1
    }

    /// Forgets the history one undo manager holds, when its screen goes away.
    func forgetHistory(in undoManager: UndoManager) {
        undoManager.removeAllActions(withTarget: self)
        historyHolders.remove(undoManager)
        historyRevision += 1
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

    // MARK: - Capacity & Effective Layout

    /// How many standard buttons fit in the main row before runtime additions.
    func mainRowCapacity(availableWidth: CGFloat, sizes: KeyboardSizes, minimumKeyWidth: Double = 0) -> Int {
        KeyboardToolbarOverflow.keysFitting(width: availableWidth,
            keyWidth: max(sizes.button.normalWidth, CGFloat(minimumKeyWidth)), spacing: sizes.toolbar.spacing)
    }

    /// A context's main-row capacity: its minimum key width, less whatever
    /// its pinned keys need back. `omitting` slots take no room. `proposed`
    /// stands in for the layout's pinned keys, to try a layout before it is made.
    func mainRowCapacity(for context: ToolbarContext, availableWidth: CGFloat, reservedMainRowSlots: Int = 0,
                         sizes: KeyboardSizes, omitting omitted: Set<KeySlot> = [],
                         pinned proposed: [KeySlot]? = nil) -> Int {
        let layout = self.layout(for: context)
        let pinned = proposed ?? validSlots((layout.pinnedLeading ?? []) + (layout.pinnedTrailing ?? []), in: layout)
            .filter { !omitted.contains($0) }
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
    /// `omitting` slots are left out entirely, for a row that draws nothing for them.
    func effectiveLayout(for context: ToolbarContext, availableWidth: CGFloat, reservedMainRowSlots: Int = 0,
                         sizes: KeyboardSizes, omitting omitted: Set<KeySlot> = []) -> EffectiveToolbarLayout {
        let layout = self.layout(for: context)
        func slots(_ row: [KeySlot]) -> [KeySlot] {
            validSlots(row, in: layout).filter { !omitted.contains($0) }
        }
        let leading = slots(layout.pinnedLeading ?? [])
        let trailing = slots(layout.pinnedTrailing ?? [])
        let main = slots(layout.mainRow)
        let drawers = layout.drawerRows.map(slots)
        let keepsDrawerToggle = !layout.hiddenKeys.contains(.drawerToggle)
        let capacity = mainRowCapacity(for: context, availableWidth: availableWidth,
                                       reservedMainRowSlots: reservedMainRowSlots, sizes: sizes, omitting: omitted)
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

    /// nil clears the setting.
    private func save<T: Encodable>(_ value: T?, to key: SettingKey<Data?>) {
        do {
            SettingsStore.shared.set(key, try value.map { try JSONEncoder().encode($0) })
        } catch {
            Self.logger.error("Failed to save \(key.name, privacy: .public): \(error.localizedDescription)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from key: SettingKey<Data?>) -> T? {
        guard let data = SettingsStore.shared.get(key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("Failed to load \(key.name, privacy: .public): \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadSavedLayouts() -> [SavedToolbarLayout] {
        load([SavedToolbarLayout].self, from: Settings.KeyboardToolbar.savedLayouts) ?? []
    }

    private static func loadKeyColors() -> [String: String] {
        load([String: String].self, from: Settings.KeyboardToolbar.keyColors) ?? [:]
    }

    private static func loadLayout(for context: ToolbarContext, idiom: UIUserInterfaceIdiom) -> ToolbarLayoutConfig? {
        load(ToolbarLayoutConfig.self, from: Settings.KeyboardToolbar.layoutKey(for: context))
            .map { ToolbarLayoutConfig.migrate($0, idiom: idiom) }
    }

    private static func loadCustomLayouts(idiom: UIUserInterfaceIdiom) -> [ToolbarContext: ToolbarLayoutConfig] {
        var layouts: [ToolbarContext: ToolbarLayoutConfig] = [:]
        for context in secondaryContexts {
            layouts[context] = loadLayout(for: context, idiom: idiom)
        }
        return layouts
    }

    private static func loadCustomKeys() -> [CustomKey] {
        load([CustomKey].self, from: Settings.KeyboardToolbar.customKeys) ?? []
    }

    private func notifyChange() {
        // A change that no undoable edit made: sync, another screen, a reset.
        if !isRecordingEdit, let recordedState, recordedState != editSnapshot { retireHistory() }
        NotificationCenter.default.post(name: Self.layoutDidChangeNotification, object: nil)
    }
}
