//
//  KeybindManager.swift
//  rootshell
//
//  Central singleton manager for keyboard shortcuts
//

import Foundation
import Combine
import os

/// Central manager for keyboard shortcut bindings
@MainActor
final class KeybindManager: ObservableObject {
    static let shared = KeybindManager()

    private static let logger = Logger(subsystem: "com.rootshell", category: "KeybindManager")

    // MARK: - Published State

    /// All active keybindings (defaults + external config + user overrides)
    /// Priority: user overrides > external config > defaults
    @Published private(set) var activeBindings: [Keybind] = []

    /// User overrides only (stored in UserDefaults)
    @Published private(set) var userOverrides: [Keybind] = []

    /// Keybindings from external config file
    @Published private(set) var externalConfigBindings: [Keybind] = []

    /// Original filename of the imported config (for UI display)
    @Published private(set) var externalConfigOriginalFileName: String?

    /// Path to the canonical editable config file in ~/.ghostty/
    @Published var externalConfigPath: URL? {
        didSet {
            saveExternalConfigPath()
            if let path = externalConfigPath {
                loadExternalConfig(at: path)
            } else {
                externalConfigBindings = []
                externalConfigClearsDefaults = false
                // Delete local copy when user removes the config
                if FileManager.default.fileExists(atPath: importedKeybindsURL.path) {
                    try? FileManager.default.removeItem(at: importedKeybindsURL)
                }
            }
            reloadBindings()
            applyExternalConfigToGhosttyIfAvailable()
        }
    }

    /// Publisher for keybind changes
    let keybindsDidChange = PassthroughSubject<Void, Never>()

    // MARK: - Private Storage

    private let userDefaultsKey = "keybindOverrides"
    private let externalConfigPathKey = "externalGhosttyConfigPath"
    private let externalConfigFileNameKey = "externalGhosttyConfigPath_originalFilename"
    private var defaultBindings: [Keybind] = []
    // Ghostty config writes consult KeybindManager.shared while building config lines.
    // Avoid triggering live Ghostty reloads until singleton initialization is complete,
    // otherwise externalConfigPath.didSet can recurse back into shared creation.
    private var hasFinishedInitialization = false
    /// When true, external config contained "keybind = clear" — defaults are suppressed
    private var externalConfigClearsDefaults = false

    // MARK: - Initialization

    private init() {
        loadDefaultBindings()
        loadUserOverrides()
        loadExternalConfigPath()
        reloadBindings()
        hasFinishedInitialization = true
    }

    // MARK: - Default Bindings

    /// Load hard-coded default bindings (mirrors current TerminalViewKeyboard behavior)
    private func loadDefaultBindings() {
        defaultBindings = [
            // Clipboard
            Keybind(key: .c, modifiers: .command, action: .copy_to_clipboard),
            Keybind(key: .v, modifiers: .command, action: .paste_from_clipboard),
            Keybind(key: .c, modifiers: [.command, .shift], action: .toggle_clipboard_manager),

            // Tab Management
            Keybind(key: .t, modifiers: .command, action: .new_local_shell),
            Keybind(key: .s, modifiers: .command, action: .new_tab),
            Keybind(key: .n, modifiers: .command, action: .new_window),
            Keybind(key: .w, modifiers: .command, action: .close_tab),
            Keybind(key: .r, modifiers: [.command, .shift], action: .duplicate_ssh_tab),
            Keybind(key: .leftBrace, modifiers: .command, action: .previous_tab),
            Keybind(key: .rightBrace, modifiers: .command, action: .next_tab),
            Keybind(key: .s, modifiers: [.command, .shift], action: .show_tmux_sessions),
            Keybind(key: .x, modifiers: [.command, .shift], action: .detach_other_clients),

            // Tab Selection
            Keybind(key: .digit1, modifiers: .command, action: .select_tab_1),
            Keybind(key: .digit2, modifiers: .command, action: .select_tab_2),
            Keybind(key: .digit3, modifiers: .command, action: .select_tab_3),
            Keybind(key: .digit4, modifiers: .command, action: .select_tab_4),
            Keybind(key: .digit5, modifiers: .command, action: .select_tab_5),
            Keybind(key: .digit6, modifiers: .command, action: .select_tab_6),
            Keybind(key: .digit7, modifiers: .command, action: .select_tab_7),
            Keybind(key: .digit8, modifiers: .command, action: .select_tab_8),
            Keybind(key: .digit9, modifiers: .command, action: .select_tab_9),

            // Splits
            Keybind(key: .d, modifiers: .command, action: .split_right),
            Keybind(key: .d, modifiers: [.command, .shift], action: .split_down),

            // Split Navigation (Cmd+Alt+Arrow - upstream Ghostty default)
            Keybind(key: .left, modifiers: [.command, .option], action: .navigate_split_left),
            Keybind(key: .right, modifiers: [.command, .option], action: .navigate_split_right),
            Keybind(key: .up, modifiers: [.command, .option], action: .navigate_split_up),
            Keybind(key: .down, modifiers: [.command, .option], action: .navigate_split_down),

            // Split Management
            Keybind(key: .enter, modifiers: [.command, .shift], action: .toggle_split_zoom),
            Keybind(key: .e, modifiers: [.command, .shift], action: .equalize_splits),

            // View
            Keybind(key: .equal, modifiers: .command, action: .increase_font_size),
            Keybind(key: .plus, modifiers: .command, action: .increase_font_size),  // Shift+= on US keyboard
            Keybind(key: .minus, modifiers: .command, action: .decrease_font_size),
            Keybind(key: .digit0, modifiers: .command, action: .reset_font_size),
            Keybind(key: .f, modifiers: .command, action: .start_search),
            Keybind(key: .b, modifiers: [.command, .shift], action: .toggle_tab_bar),
            Keybind(key: .g, modifiers: [.command, .shift], action: .toggle_group_mode),
            Keybind(key: .backslash, modifiers: [.command, .shift], action: .toggle_tab_switcher),
            Keybind(key: .a, modifiers: [.command, .shift], action: .toggle_tab_expose),
            Keybind(key: .leftBracket, modifiers: [.command, .option], action: .previous_group),
            Keybind(key: .rightBracket, modifiers: [.command, .option], action: .next_group),
            Keybind(key: .o, modifiers: [.command, .shift], action: .toggle_transparency),
            Keybind(key: .h, modifiers: [.command, .shift], action: .toggle_titlebar),
            Keybind(key: .r, modifiers: [.command, .control], action: .toggle_auto_redact),
            Keybind(key: .t, modifiers: [.command, .shift], action: .toggle_theme_picker),
            Keybind(key: .l, modifiers: [.command, .shift], action: .toggle_background_effect),
            Keybind(key: .k, modifiers: [.command, .shift], action: .toggle_compose),
            Keybind(key: .f, modifiers: [.command, .shift], action: .toggle_full_screen),
            Keybind(key: .m, modifiers: [.command, .shift], action: .toggle_mouse_capture),
            Keybind(key: .b, modifiers: [.command, .control], action: .brightness_boost),
            Keybind(key: .space, modifiers: [.command, .shift], action: .cycle_input_source),
            Keybind(key: .o, modifiers: .command, action: .focus_external_display),
            Keybind(key: .o, modifiers: [.command, .option], action: .move_tab_to_external_display),

            // Navigation
            Keybind(key: .up, modifiers: .command, action: .scroll_page_up),
            Keybind(key: .down, modifiers: .command, action: .scroll_page_down),
            Keybind(key: .home, modifiers: .command, action: .scroll_to_top),
            Keybind(key: .end, modifiers: .command, action: .scroll_to_bottom),

            // Terminal
            Keybind(key: .a, modifiers: .command, action: .select_all),
            Keybind(key: .k, modifiers: .command, action: .clear_screen),

            // Shell Operations
            Keybind(key: .comma, modifiers: .command, action: .open_settings),
            Keybind(key: .b, modifiers: .command, action: .browse_hosts),
            Keybind(key: .p, modifiers: [.command, .shift], action: .browse_profiles),
            Keybind(key: .i, modifiers: .command, action: .toggle_ai_agent),
            Keybind(key: .v, modifiers: [.command, .shift], action: .toggle_voice_agent),

            // Control Characters (Ctrl+A-Z defaults to terminal control chars)
            Keybind(key: .a, modifiers: .control, action: .ctrl_a),
            Keybind(key: .b, modifiers: .control, action: .ctrl_b),
            Keybind(key: .c, modifiers: .control, action: .ctrl_c),
            Keybind(key: .d, modifiers: .control, action: .ctrl_d),
            Keybind(key: .e, modifiers: .control, action: .ctrl_e),
            Keybind(key: .f, modifiers: .control, action: .ctrl_f),
            Keybind(key: .g, modifiers: .control, action: .ctrl_g),
            Keybind(key: .h, modifiers: .control, action: .ctrl_h),
            Keybind(key: .i, modifiers: .control, action: .ctrl_i),
            Keybind(key: .j, modifiers: .control, action: .ctrl_j),
            Keybind(key: .k, modifiers: .control, action: .ctrl_k),
            Keybind(key: .l, modifiers: .control, action: .ctrl_l),
            Keybind(key: .m, modifiers: .control, action: .ctrl_m),
            Keybind(key: .n, modifiers: .control, action: .ctrl_n),
            Keybind(key: .o, modifiers: .control, action: .ctrl_o),
            Keybind(key: .p, modifiers: .control, action: .ctrl_p),
            Keybind(key: .q, modifiers: .control, action: .ctrl_q),
            Keybind(key: .r, modifiers: .control, action: .ctrl_r),
            Keybind(key: .s, modifiers: .control, action: .ctrl_s),
            Keybind(key: .t, modifiers: .control, action: .ctrl_t),
            Keybind(key: .u, modifiers: .control, action: .ctrl_u),
            Keybind(key: .v, modifiers: .control, action: .ctrl_v),
            Keybind(key: .w, modifiers: .control, action: .ctrl_w),
            Keybind(key: .x, modifiers: .control, action: .ctrl_x),
            Keybind(key: .y, modifiers: .control, action: .ctrl_y),
            Keybind(key: .z, modifiers: .control, action: .ctrl_z),
        ]
    }

    // MARK: - Binding Lookup

    /// Get the action for a given sequence
    func action(for sequence: KeySequence) -> KeybindAction? {
        activeBindings.first { $0.sequence == sequence }?.action
    }

    /// Get the action for a single trigger
    func action(for trigger: KeyTrigger) -> KeybindAction? {
        action(for: KeySequence(trigger: trigger))
    }

    /// Get the sequence for a given action
    func sequence(for action: KeybindAction) -> KeySequence? {
        activeBindings.first { $0.action == action }?.sequence
    }

    /// Get all bindings for a category
    func bindings(for category: KeybindCategory) -> [Keybind] {
        activeBindings.filter { $0.action.category == category }
    }

    /// Get bindings that start with a specific trigger (for sequence matching)
    func bindingsStartingWith(trigger: KeyTrigger) -> [Keybind] {
        activeBindings.filter { $0.sequence.matchesPrefix(trigger) }
    }

    /// Check if a trigger is a sequence prefix (has bindings that start with it)
    func isSequencePrefix(_ trigger: KeyTrigger) -> Bool {
        activeBindings.contains { keybind in
            keybind.sequence.isSequence && keybind.sequence.matchesPrefix(trigger)
        }
    }

    /// Get the keybind for a specific action
    func keybind(for action: KeybindAction) -> Keybind? {
        activeBindings.first { $0.action == action }
    }

    /// Get the keybind for a given sequence (includes action parameter)
    func keybind(for sequence: KeySequence) -> Keybind? {
        activeBindings.first { $0.sequence == sequence }
    }

    /// Get the keybind for a single trigger (includes action parameter)
    func keybind(for trigger: KeyTrigger) -> Keybind? {
        keybind(for: KeySequence(trigger: trigger))
    }

    // MARK: - User Overrides

    /// Set a user override for an action
    func setOverride(sequence: KeySequence, action: KeybindAction) {
        Self.logger.info("Setting override: \(sequence.ghosttyFormat) -> \(action.rawValue)")

        if action == .unbind {
            // Unbind is special: multiple actions can be unbound simultaneously.
            // Only remove duplicate unbinds for the same sequence. Keep non-unbind
            // overrides (e.g., custom remaps) — reloadBindings() processes them in
            // order, so the later unbind suppresses the earlier remap.
            userOverrides.removeAll { $0.action == .unbind && $0.sequence == sequence }
        } else {
            // Normal action: one key per action, remove old override for this action
            userOverrides.removeAll { $0.action == action }
            // Also remove any stale unbind override targeting this action
            userOverrides.removeAll {
                $0.action == .unbind && $0.actionParameter == action.rawValue
            }
        }

        // Add new override
        let override = Keybind(
            sequence: sequence,
            action: action,
            isUserOverride: true,
            source: .userOverride
        )
        userOverrides.append(override)

        saveUserOverrides()
        reloadBindings()
    }

    /// Set a user override from a single trigger
    func setOverride(trigger: KeyTrigger, action: KeybindAction) {
        setOverride(sequence: KeySequence(trigger: trigger), action: action)
    }

    /// Explicitly unbind an action (removes its shortcut entirely)
    func unbindAction(_ actionToUnbind: KeybindAction) {
        Self.logger.info("Unbinding action: \(actionToUnbind.rawValue)")

        // Remove any existing unbind override for this action
        userOverrides.removeAll {
            $0.action == .unbind && $0.actionParameter == actionToUnbind.rawValue
        }

        // Find current sequence so reloadBindings() can suppress it
        guard let currentBinding = keybind(for: actionToUnbind) else { return }

        let override = Keybind(
            sequence: currentBinding.sequence,
            action: .unbind,
            actionParameter: actionToUnbind.rawValue,
            isUserOverride: true,
            source: .userOverride
        )
        userOverrides.append(override)

        saveUserOverrides()
        reloadBindings()
    }

    /// Check if an action was explicitly unbound by the user
    func isActionUnbound(_ action: KeybindAction) -> Bool {
        userOverrides.contains {
            $0.action == .unbind && $0.actionParameter == action.rawValue
        }
    }

    /// Remove user override for an action (restore default)
    func removeOverride(for action: KeybindAction) {
        Self.logger.info("Removing override for: \(action.rawValue)")
        userOverrides.removeAll { $0.action == action }
        // Also remove any unbind override targeting this action
        userOverrides.removeAll {
            $0.action == .unbind && $0.actionParameter == action.rawValue
        }
        saveUserOverrides()
        reloadBindings()
    }

    /// Check if action has a user override
    func hasOverride(for action: KeybindAction) -> Bool {
        userOverrides.contains { $0.action == action }
    }

    /// Reset all user overrides to defaults
    func resetAllOverrides() {
        Self.logger.info("Resetting all overrides")
        userOverrides.removeAll()
        saveUserOverrides()
        reloadBindings()
    }

    /// Re-reads user overrides from UserDefaults and rebuilds bindings.
    /// Call after restoring overrides from a backup.
    func reloadOverrides() {
        loadUserOverrides()
        reloadBindings()
    }

    // MARK: - External Config

    /// Local destination for imported config files
    private var importedKeybindsURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent("imported_keybinds.conf")
    }

    /// Shell-visible path for the imported config file.
    var externalConfigShellPath: String {
        "~/.ghostty/imported_keybinds.conf"
    }

    var externalConfigSymlinkDestination: String? {
        guard let path = externalConfigPath else { return nil }

        do {
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { return nil }
            return try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
        } catch {
            return nil
        }
    }

    func externalConfigContents() throws -> String {
        let path = externalConfigPath ?? importedKeybindsURL
        return try String(contentsOf: path, encoding: .utf8)
    }

    func saveExternalConfigContents(_ content: String) throws {
        let ghosttyDir = importedKeybindsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)

        // Write in place so an existing symlink at the canonical path keeps pointing
        // to its target instead of being replaced by a regular file.
        try content.write(to: importedKeybindsURL, atomically: false, encoding: .utf8)

        if externalConfigOriginalFileName == nil {
            let fallbackName = importedKeybindsURL.lastPathComponent
            externalConfigOriginalFileName = fallbackName
            UserDefaults.standard.set(fallbackName, forKey: externalConfigFileNameKey)
        }
    }

    /// Import an external ghostty config file by copying it to the app's Documents directory.
    /// After import, the app always edits and reloads the canonical ~/.ghostty copy.
    func importExternalConfig(from pickerURL: URL) {
        Self.logger.info("Importing external config from: \(pickerURL.path)")

        guard pickerURL.startAccessingSecurityScopedResource() else {
            Self.logger.error("Cannot access selected file")
            return
        }
        defer { pickerURL.stopAccessingSecurityScopedResource() }

        do {
            let content = try String(contentsOf: pickerURL, encoding: .utf8)
            importExternalConfig(content: content, originalFilename: pickerURL.lastPathComponent)
        } catch {
            Self.logger.error("Failed to import external config: \(error.localizedDescription)")
        }
    }

    /// Import an external ghostty config from raw text plus a display filename.
    /// Used by the migration importer, which resolves `config-file = …` includes
    /// itself and hands the flattened keybind text in here so include-sourced
    /// keybinds don't get silently dropped.
    func importExternalConfig(content: String, originalFilename: String) {
        do {
            try saveExternalConfigContents(content)

            externalConfigOriginalFileName = originalFilename
            UserDefaults.standard.set(originalFilename, forKey: externalConfigFileNameKey)

            // Set path to the canonical copy — triggers didSet which calls save + load.
            externalConfigPath = importedKeybindsURL
        } catch {
            Self.logger.error("Failed to save imported config contents: \(error.localizedDescription)")
        }
    }

    /// Load keybinds from external ghostty config file
    private func loadExternalConfig(at path: URL) {
        Self.logger.info("Loading external config from: \(path.path)")

        do {
            let content = try String(contentsOf: path, encoding: .utf8)
            externalConfigBindings = parseGhosttyConfig(content)
            Self.logger.info("Loaded \(self.externalConfigBindings.count) keybinds from external config")
        } catch {
            Self.logger.error("Failed to load external config: \(error.localizedDescription)")
            externalConfigBindings = []
            externalConfigClearsDefaults = false
        }
    }

    /// Parse ghostty config format keybinds
    private func parseGhosttyConfig(_ content: String) -> [Keybind] {
        var bindings: [Keybind] = []
        externalConfigClearsDefaults = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip comments and empty lines
            guard !trimmed.isEmpty && !trimmed.hasPrefix("#") else { continue }

            // Only process keybind lines
            guard trimmed.lowercased().hasPrefix("keybind") else { continue }

            // Handle special "keybind = clear" directive
            // Extract content after "keybind" prefix, stripping "=" and whitespace
            var directive = trimmed.lowercased().dropFirst("keybind".count)
                .trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("=") {
                directive = String(directive.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if directive == "clear" {
                // Clear all previous bindings including defaults —
                // reloadBindings() checks externalConfigClearsDefaults
                Self.logger.info("External config: clearing all keybinds (including defaults)")
                externalConfigClearsDefaults = true
                bindings.removeAll()
                continue
            }

            if let keybind = Keybind(ghosttyLine: trimmed, source: .externalConfig) {
                bindings.append(keybind)
            }
        }

        return bindings
    }

    /// Reload external config (for manual refresh)
    func reloadExternalConfig() {
        guard let path = externalConfigPath else { return }
        loadExternalConfig(at: path)
        reloadBindings()
        applyExternalConfigToGhosttyIfAvailable()
    }

    private func applyExternalConfigToGhosttyIfAvailable() {
        guard hasFinishedInitialization else { return }
        Ghostty.App.shared?.applyKeybindConfig()
    }

    // MARK: - Config File Sync

    /// Get terminal keybind config lines for inclusion in ghostty config file
    /// Returns lines in ghostty format: "keybind = cmd+c=copy_to_clipboard"
    func terminalKeybindConfigLines() -> [String] {
        // Check if any terminal-relevant changes exist (external config or user overrides).
        // When there are none, return empty so libghostty uses its own built-in defaults.
        let hasTerminalOverrides = userOverrides.contains { override in
            override.action.isTerminalAction
            || (override.action == .unbind && {
                guard let raw = override.actionParameter,
                      let target = KeybindAction(rawValue: raw) else { return false }
                return target.isTerminalAction
            }())
        }
        let hasExternalTerminal = externalConfigBindings.contains { $0.action.isTerminalAction }

        guard hasTerminalOverrides || hasExternalTerminal || externalConfigClearsDefaults else {
            return []
        }

        // Clear libghostty's defaults, then emit the fully-resolved terminal bindings
        // from activeBindings. This mirrors the exact precedence order that
        // reloadBindings() computed (defaults → external config → user overrides).
        var lines: [String] = ["keybind = clear"]

        for binding in activeBindings {
            guard binding.action.isTerminalAction && !binding.action.isControlCharacter else {
                continue
            }
            lines.append(binding.ghosttyFormat)
        }

        return lines
    }

    /// Write terminal action keybinds to ghostty config file
    func syncToGhosttyConfig() {
        guard let configDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("ghostty") else {
            Self.logger.error("Failed to get config directory")
            return
        }

        let keybindsFile = configDir.appendingPathComponent("keybinds")

        let configLines = terminalKeybindConfigLines()

        guard !configLines.isEmpty else {
            // Remove file if no overrides
            try? FileManager.default.removeItem(at: keybindsFile)
            return
        }

        var content = "# Rootshell keybind overrides\n"
        content += "# Auto-generated - edit via app settings\n\n"

        for line in configLines {
            content += "\(line)\n"
        }

        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            try content.write(to: keybindsFile, atomically: true, encoding: .utf8)
            Self.logger.info("Synced keybinds to ghostty config")
        } catch {
            Self.logger.error("Failed to sync keybinds: \(error.localizedDescription)")
        }
    }

    // MARK: - Reload

    /// Reload active bindings from all sources
    private func reloadBindings() {
        // Start with defaults (unless external config used "keybind = clear")
        var bindings = externalConfigClearsDefaults ? [Keybind]() : defaultBindings

        // Apply external config overrides (middle priority)
        for extBinding in externalConfigBindings {
            // Remove any existing binding for this sequence
            bindings.removeAll { $0.sequence == extBinding.sequence }
            // Remove any existing binding for this action (but not parameterized actions
            // like send_text where many bindings share the same action with different params)
            if !extBinding.action.isParameterized {
                bindings.removeAll { $0.action == extBinding.action }
            }
            bindings.append(extBinding)
        }

        // Apply user overrides (highest priority)
        for override in userOverrides {
            // Remove any existing binding for this action (skip parameterized)
            if !override.action.isParameterized {
                bindings.removeAll { $0.action == override.action }
            }
            // Remove any existing binding for this sequence (handle conflicts)
            bindings.removeAll { $0.sequence == override.sequence }

            if override.action != .unbind {
                bindings.append(override)
            }
        }

        // Sort by category and name for consistent ordering
        activeBindings = bindings.sorted { binding1, binding2 in
            if binding1.action.category.displayOrder != binding2.action.category.displayOrder {
                return binding1.action.category.displayOrder < binding2.action.category.displayOrder
            }
            return binding1.action.displayName < binding2.action.displayName
        }

        syncToGhosttyConfig()
        keybindsDidChange.send()

        Self.logger.info("Reloaded \(self.activeBindings.count) active bindings")
    }

    // MARK: - Persistence

    private func saveUserOverrides() {
        do {
            let data = try JSONEncoder().encode(userOverrides)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            Self.logger.error("Failed to save user overrides: \(error.localizedDescription)")
        }
    }

    private func loadUserOverrides() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return
        }

        do {
            userOverrides = try JSONDecoder().decode([Keybind].self, from: data)
            Self.logger.info("Loaded \(self.userOverrides.count) user overrides")
        } catch {
            Self.logger.error("Failed to load user overrides: \(error.localizedDescription)")
            userOverrides = []
        }
    }

    private func saveExternalConfigPath() {
        if let path = externalConfigPath {
            UserDefaults.standard.set(path.path, forKey: externalConfigPathKey)
            // Ensure in-memory filename is populated (e.g., after backup restore)
            if externalConfigOriginalFileName == nil {
                externalConfigOriginalFileName = UserDefaults.standard.string(forKey: externalConfigFileNameKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: externalConfigPathKey)
            UserDefaults.standard.removeObject(forKey: externalConfigFileNameKey)
            externalConfigOriginalFileName = nil
        }
    }

    private func loadExternalConfigPath() {
        // Load original filename for display
        externalConfigOriginalFileName = UserDefaults.standard.string(forKey: externalConfigFileNameKey)

        // Migration: if we have a bookmark but no local copy, try to migrate
        if UserDefaults.standard.data(forKey: "\(externalConfigPathKey)_bookmark") != nil,
           !FileManager.default.fileExists(atPath: importedKeybindsURL.path) {
            migrateFromBookmark()
            return
        }

        // The imported config always lives at a fixed location relative to the
        // Documents directory. Do NOT rely on the absolute path stored in
        // UserDefaults: iOS app container UUIDs can change between launches
        // (after iCloud restores, app updates, OS migrations), which would
        // invalidate any cached absolute path and cause the imported config to
        // appear "missing" even though the file is still present at the
        // dynamically-resolved Documents location.
        let canonical = importedKeybindsURL
        if FileManager.default.fileExists(atPath: canonical.path) {
            // Setting `externalConfigPath` triggers `didSet`, which loads the
            // file, reloads bindings, and updates the stored path to match the
            // current container UUID.
            externalConfigPath = canonical
        } else if UserDefaults.standard.string(forKey: externalConfigPathKey) != nil {
            Self.logger.warning("Imported keybind config missing at canonical location: \(canonical.path)")
            UserDefaults.standard.removeObject(forKey: externalConfigPathKey)
            UserDefaults.standard.removeObject(forKey: externalConfigFileNameKey)
            externalConfigOriginalFileName = nil
        }
    }

    /// Migrate from the old security-scoped bookmark to a local file copy.
    private func migrateFromBookmark() {
        Self.logger.info("Migrating external config from bookmark to local copy")

        guard let bookmarkData = UserDefaults.standard.data(forKey: "\(externalConfigPathKey)_bookmark") else {
            return
        }

        do {
            var isStale = false
            #if targetEnvironment(macCatalyst)
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #else
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let content = try String(contentsOf: url, encoding: .utf8)

            let ghosttyDir = importedKeybindsURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: ghosttyDir, withIntermediateDirectories: true)
            try content.write(to: importedKeybindsURL, atomically: true, encoding: .utf8)

            if externalConfigOriginalFileName == nil {
                let originalName = url.lastPathComponent
                externalConfigOriginalFileName = originalName
                UserDefaults.standard.set(originalName, forKey: externalConfigFileNameKey)
            }

            UserDefaults.standard.set(importedKeybindsURL.path, forKey: externalConfigPathKey)
            UserDefaults.standard.removeObject(forKey: "\(externalConfigPathKey)_bookmark")

            externalConfigPath = importedKeybindsURL
            loadExternalConfig(at: importedKeybindsURL)

            Self.logger.info("Successfully migrated external config to local copy")
        } catch {
            Self.logger.error("Migration from bookmark failed: \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: "\(externalConfigPathKey)_bookmark")
        }
    }

    // MARK: - Conflict Detection

    /// Check if a sequence would conflict with existing bindings
    func conflicts(for sequence: KeySequence, excluding action: KeybindAction? = nil) -> [Keybind] {
        activeBindings.filter { binding in
            // Skip the action we're checking for
            if let excludedAction = action, binding.action == excludedAction {
                return false
            }

            // Check for exact match or prefix conflict
            return binding.sequence == sequence || binding.sequence.conflictsWith(sequence)
        }
    }
}
