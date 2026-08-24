//
//  KeybindAction.swift
//  rootshell
//
//  All bindable actions in Rootshell terminal
//

import Foundation

/// Categories for organizing keybindings in UI
enum KeybindCategory: String, CaseIterable, Identifiable {
    case clipboard = "Clipboard"
    case navigation = "Navigation"
    case tabs = "Tabs"
    case splits = "Splits"
    case view = "View"
    case shell = "Shell"
    case terminal = "Terminal"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clipboard: return String(localized: "Clipboard", comment: "Keybind category: clipboard actions")
        case .navigation: return String(localized: "Navigation", comment: "Keybind category: navigation actions")
        case .tabs: return String(localized: "Tabs", comment: "Keybind category: tab management")
        case .splits: return String(localized: "Splits", comment: "Keybind category: split management")
        case .view: return String(localized: "View", comment: "Keybind category: view options")
        case .shell: return String(localized: "Shell", comment: "Keybind category: shell actions")
        case .terminal: return String(localized: "Terminal", comment: "Keybind category: terminal actions")
        }
    }

    var displayOrder: Int {
        switch self {
        case .clipboard: return 0
        case .tabs: return 1
        case .splits: return 2
        case .navigation: return 3
        case .view: return 4
        case .shell: return 5
        case .terminal: return 6
        }
    }
}

/// All bindable actions in Rootshell
enum KeybindAction: String, CaseIterable, Codable, Identifiable, Hashable {
    var id: String { rawValue }

    // MARK: - Terminal Actions (handled by libghostty)

    /// Copy selected text to clipboard
    case copy_to_clipboard = "copy_to_clipboard"
    /// Paste from clipboard
    case paste_from_clipboard = "paste_from_clipboard"
    /// Scroll terminal up one page
    case scroll_page_up = "scroll_page_up"
    /// Scroll terminal down one page
    case scroll_page_down = "scroll_page_down"
    /// Scroll to top of scrollback
    case scroll_to_top = "scroll_to_top"
    /// Scroll to bottom of terminal
    case scroll_to_bottom = "scroll_to_bottom"
    /// Select all text in terminal
    case select_all = "select_all"
    /// Clear screen and scrollback
    case clear_screen = "clear_screen"
    /// Reset terminal state
    case reset_terminal = "reset"

    // MARK: - App Actions (handled by Swift notifications)

    // Font Size
    /// Increase font size
    case increase_font_size = "increase_font_size"
    /// Decrease font size
    case decrease_font_size = "decrease_font_size"
    /// Reset font size to default
    case reset_font_size = "reset_font_size"

    // Search
    /// Open search/find panel
    case start_search = "start_search"

    // Tab Management
    /// Create new local shell tab
    case new_local_shell = "new_local_shell"
    /// Create new tab (browse hosts)
    case new_tab = "new_tab"
    /// Create new window
    case new_window = "new_window"
    /// Close current tab/split
    case close_tab = "close_tab"
    /// Duplicate current SSH connection in new tab
    case duplicate_ssh_tab = "duplicate_ssh_tab"
    /// Switch to previous tab
    case previous_tab = "previous_tab"
    /// Switch to next tab
    case next_tab = "next_tab"
    /// Open tmux session dashboard for the current tmux tab
    case show_tmux_sessions = "show_tmux_sessions"
    /// Detach all OTHER tmux clients from the current gateway (`detach-client -a`)
    case detach_other_clients = "detach_other_clients"

    // Tab Selection (1-9)
    case select_tab_1 = "select_tab_1"
    case select_tab_2 = "select_tab_2"
    case select_tab_3 = "select_tab_3"
    case select_tab_4 = "select_tab_4"
    case select_tab_5 = "select_tab_5"
    case select_tab_6 = "select_tab_6"
    case select_tab_7 = "select_tab_7"
    case select_tab_8 = "select_tab_8"
    case select_tab_9 = "select_tab_9"

    // Split Management
    /// Split terminal to the right
    case split_right = "split_right"
    /// Split terminal down
    case split_down = "split_down"
    /// Navigate to split on the left
    case navigate_split_left = "navigate_split_left"
    /// Navigate to split on the right
    case navigate_split_right = "navigate_split_right"
    /// Navigate to split above
    case navigate_split_up = "navigate_split_up"
    /// Navigate to split below
    case navigate_split_down = "navigate_split_down"
    /// Toggle zoom on current split
    case toggle_split_zoom = "toggle_split_zoom"
    /// Equalize all split sizes
    case equalize_splits = "equalize_splits"

    // Shell Operations
    /// Open settings
    case open_settings = "open_settings"
    /// Open host browser
    case browse_hosts = "browse_hosts"
    /// Open profiles browser
    case browse_profiles = "browse_profiles"
    /// Toggle AI agent panel
    case toggle_ai_agent = "toggle_ai_agent"
    /// Toggle voice agent mode
    case toggle_voice_agent = "toggle_voice_agent"
    /// Toggle tab bar visibility
    case toggle_tab_bar = "toggle_tab_bar"
    /// Toggle grouped mode (scope tabs/top tab bar to the active group) in the vertical sidebar
    case toggle_group_mode = "toggle_group_mode"
    /// Toggle tab switcher panel
    case toggle_tab_switcher = "toggle_tab_switcher"
    /// Toggle the tab exposé (live previews of the current scope)
    case toggle_tab_expose = "toggle_tab_expose"
    /// Switch to the previous / next tab group (or project) while grouped
    case previous_group = "previous_group"
    case next_group = "next_group"
    /// Toggle window transparency (Mac Catalyst only)
    case toggle_transparency = "toggle_transparency"
    /// Toggle the macOS window title bar (Mac Catalyst only)
    case toggle_titlebar = "toggle_titlebar"
    /// Toggle auto-redact (mask sensitive strings on screen)
    case toggle_auto_redact = "toggle_auto_redact"
    /// Toggle theme picker overlay
    case toggle_theme_picker = "toggle_theme_picker"
    /// Toggle clipboard manager overlay
    case toggle_clipboard_manager = "toggle_clipboard_manager"
    /// Toggle background effect on/off
    case toggle_background_effect = "toggle_background_effect"
    /// Toggle compose text overlay
    case toggle_compose = "toggle_compose"
    /// Toggle full screen mode
    case toggle_full_screen = "toggle_full_screen"
    /// Toggle mouse capture override (force-disable mouse reporting)
    case toggle_mouse_capture = "toggle_mouse_capture"
    /// Toggle the HDR brightness-boost HUD
    case brightness_boost = "brightness_boost"
    /// Cycle to the next system keyboard/input source (Ctrl+Space-style)
    case cycle_input_source = "cycle_input_source"
    /// Toggle input focus between the device and an external display
    case focus_external_display = "focus_external_display"
    /// Move the current tab to/from an external display
    case move_tab_to_external_display = "move_tab_to_external_display"

    // Terminal Control Characters (Ctrl+A-Z)
    case ctrl_a = "ctrl_a"
    case ctrl_b = "ctrl_b"
    case ctrl_c = "ctrl_c"
    case ctrl_d = "ctrl_d"
    case ctrl_e = "ctrl_e"
    case ctrl_f = "ctrl_f"
    case ctrl_g = "ctrl_g"
    case ctrl_h = "ctrl_h"
    case ctrl_i = "ctrl_i"
    case ctrl_j = "ctrl_j"
    case ctrl_k = "ctrl_k"
    case ctrl_l = "ctrl_l"
    case ctrl_m = "ctrl_m"
    case ctrl_n = "ctrl_n"
    case ctrl_o = "ctrl_o"
    case ctrl_p = "ctrl_p"
    case ctrl_q = "ctrl_q"
    case ctrl_r = "ctrl_r"
    case ctrl_s = "ctrl_s"
    case ctrl_t = "ctrl_t"
    case ctrl_u = "ctrl_u"
    case ctrl_v = "ctrl_v"
    case ctrl_w = "ctrl_w"
    case ctrl_x = "ctrl_x"
    case ctrl_y = "ctrl_y"
    case ctrl_z = "ctrl_z"

    // Send data actions (desktop Ghostty compatible)
    /// Send arbitrary text/bytes to terminal (uses escape sequence encoding)
    case send_text = "text"
    /// Send ESC sequence to terminal (prepends ESC byte)
    case send_esc = "esc"
    /// Send CSI sequence to terminal (prepends ESC [)
    case send_csi = "csi"

    // Special
    /// Explicitly unbind this action (no shortcut)
    case unbind = "unbind"

    // MARK: - Properties

    /// Whether this action is handled by libghostty (terminal) vs Swift (app)
    var isTerminalAction: Bool {
        switch self {
        case .copy_to_clipboard, .paste_from_clipboard,
             .scroll_page_up, .scroll_page_down,
             .scroll_to_top, .scroll_to_bottom,
             .select_all, .clear_screen, .reset_terminal:
            return true
        case .ctrl_a, .ctrl_b, .ctrl_c, .ctrl_d, .ctrl_e, .ctrl_f, .ctrl_g,
             .ctrl_h, .ctrl_i, .ctrl_j, .ctrl_k, .ctrl_l, .ctrl_m, .ctrl_n,
             .ctrl_o, .ctrl_p, .ctrl_q, .ctrl_r, .ctrl_s, .ctrl_t, .ctrl_u,
             .ctrl_v, .ctrl_w, .ctrl_x, .ctrl_y, .ctrl_z:
            return true
        case .send_text, .send_esc, .send_csi:
            return true
        default:
            return false
        }
    }

    /// Whether this action is a control character (Ctrl+A-Z)
    var isControlCharacter: Bool {
        switch self {
        case .ctrl_a, .ctrl_b, .ctrl_c, .ctrl_d, .ctrl_e, .ctrl_f, .ctrl_g,
             .ctrl_h, .ctrl_i, .ctrl_j, .ctrl_k, .ctrl_l, .ctrl_m, .ctrl_n,
             .ctrl_o, .ctrl_p, .ctrl_q, .ctrl_r, .ctrl_s, .ctrl_t, .ctrl_u,
             .ctrl_v, .ctrl_w, .ctrl_x, .ctrl_y, .ctrl_z:
            return true
        default:
            return false
        }
    }

    /// The control character byte (1-26) for Ctrl+A-Z actions
    var controlCharacterByte: UInt8? {
        switch self {
        case .ctrl_a: return 1
        case .ctrl_b: return 2
        case .ctrl_c: return 3
        case .ctrl_d: return 4
        case .ctrl_e: return 5
        case .ctrl_f: return 6
        case .ctrl_g: return 7
        case .ctrl_h: return 8
        case .ctrl_i: return 9
        case .ctrl_j: return 10
        case .ctrl_k: return 11
        case .ctrl_l: return 12
        case .ctrl_m: return 13
        case .ctrl_n: return 14
        case .ctrl_o: return 15
        case .ctrl_p: return 16
        case .ctrl_q: return 17
        case .ctrl_r: return 18
        case .ctrl_s: return 19
        case .ctrl_t: return 20
        case .ctrl_u: return 21
        case .ctrl_v: return 22
        case .ctrl_w: return 23
        case .ctrl_x: return 24
        case .ctrl_y: return 25
        case .ctrl_z: return 26
        default: return nil
        }
    }

    /// Category for grouping in UI
    var category: KeybindCategory {
        switch self {
        case .copy_to_clipboard, .paste_from_clipboard, .toggle_clipboard_manager:
            return .clipboard

        case .scroll_page_up, .scroll_page_down, .scroll_to_top, .scroll_to_bottom:
            return .navigation

        case .new_local_shell, .new_tab, .new_window, .close_tab, .duplicate_ssh_tab,
             .previous_tab, .next_tab, .show_tmux_sessions, .detach_other_clients, .toggle_tab_switcher,
             .toggle_tab_expose, .previous_group, .next_group, .select_tab_1, .select_tab_2, .select_tab_3, .select_tab_4, .select_tab_5,
             .select_tab_6, .select_tab_7, .select_tab_8, .select_tab_9,
             .move_tab_to_external_display:
            return .tabs

        case .split_right, .split_down,
             .navigate_split_left, .navigate_split_right, .navigate_split_up, .navigate_split_down,
             .toggle_split_zoom, .equalize_splits:
            return .splits

        case .increase_font_size, .decrease_font_size, .reset_font_size, .start_search,
             .toggle_tab_bar, .toggle_group_mode, .toggle_transparency, .toggle_titlebar, .toggle_theme_picker, .toggle_background_effect,
             .toggle_compose, .toggle_full_screen, .toggle_mouse_capture, .cycle_input_source, .brightness_boost,
             .toggle_auto_redact, .focus_external_display:
            return .view

        case .open_settings, .browse_hosts, .browse_profiles, .toggle_ai_agent, .toggle_voice_agent:
            return .shell

        case .select_all, .clear_screen, .reset_terminal,
             .send_text, .send_esc, .send_csi,
             .ctrl_a, .ctrl_b, .ctrl_c, .ctrl_d, .ctrl_e, .ctrl_f, .ctrl_g,
             .ctrl_h, .ctrl_i, .ctrl_j, .ctrl_k, .ctrl_l, .ctrl_m, .ctrl_n,
             .ctrl_o, .ctrl_p, .ctrl_q, .ctrl_r, .ctrl_s, .ctrl_t, .ctrl_u,
             .ctrl_v, .ctrl_w, .ctrl_x, .ctrl_y, .ctrl_z:
            return .terminal

        case .unbind:
            return .shell
        }
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .copy_to_clipboard: return String(localized: "Copy", comment: "Keybind action: copy to clipboard")
        case .paste_from_clipboard: return String(localized: "Paste", comment: "Keybind action: paste from clipboard")
        case .scroll_page_up: return String(localized: "Scroll Page Up", comment: "Keybind action")
        case .scroll_page_down: return String(localized: "Scroll Page Down", comment: "Keybind action")
        case .scroll_to_top: return String(localized: "Scroll to Top", comment: "Keybind action")
        case .scroll_to_bottom: return String(localized: "Scroll to Bottom", comment: "Keybind action")
        case .select_all: return String(localized: "Select All", comment: "Keybind action")
        case .clear_screen: return String(localized: "Clear Screen", comment: "Keybind action")
        case .reset_terminal: return String(localized: "Reset Terminal", comment: "Keybind action")

        case .increase_font_size: return String(localized: "Increase Font Size", comment: "Keybind action")
        case .decrease_font_size: return String(localized: "Decrease Font Size", comment: "Keybind action")
        case .reset_font_size: return String(localized: "Reset Font Size", comment: "Keybind action")
        case .start_search: return String(localized: "Find", comment: "Keybind action: open search")

        case .new_local_shell: return String(localized: "New Local Shell", comment: "Keybind action")
        case .new_tab: return String(localized: "New Tab", comment: "Keybind action")
        case .new_window: return String(localized: "New Window", comment: "Keybind action")
        case .close_tab: return String(localized: "Close Tab", comment: "Keybind action")
        case .duplicate_ssh_tab: return String(localized: "Duplicate SSH Tab", comment: "Keybind action")
        case .previous_tab: return String(localized: "Previous Tab", comment: "Keybind action")
        case .next_tab: return String(localized: "Next Tab", comment: "Keybind action")
        case .show_tmux_sessions: return String(localized: "tmux Sessions", comment: "Keybind action")
        case .detach_other_clients: return String(localized: "Detach Other Clients", comment: "Keybind action")

        case .select_tab_1: return String(localized: "Select Tab 1", comment: "Keybind action")
        case .select_tab_2: return String(localized: "Select Tab 2", comment: "Keybind action")
        case .select_tab_3: return String(localized: "Select Tab 3", comment: "Keybind action")
        case .select_tab_4: return String(localized: "Select Tab 4", comment: "Keybind action")
        case .select_tab_5: return String(localized: "Select Tab 5", comment: "Keybind action")
        case .select_tab_6: return String(localized: "Select Tab 6", comment: "Keybind action")
        case .select_tab_7: return String(localized: "Select Tab 7", comment: "Keybind action")
        case .select_tab_8: return String(localized: "Select Tab 8", comment: "Keybind action")
        case .select_tab_9: return String(localized: "Select Tab 9", comment: "Keybind action")

        case .split_right: return String(localized: "Split Right", comment: "Keybind action")
        case .split_down: return String(localized: "Split Down", comment: "Keybind action")
        case .navigate_split_left: return String(localized: "Focus Split Left", comment: "Keybind action")
        case .navigate_split_right: return String(localized: "Focus Split Right", comment: "Keybind action")
        case .navigate_split_up: return String(localized: "Focus Split Up", comment: "Keybind action")
        case .navigate_split_down: return String(localized: "Focus Split Down", comment: "Keybind action")
        case .toggle_split_zoom: return String(localized: "Toggle Split Zoom", comment: "Keybind action")
        case .equalize_splits: return String(localized: "Equalize Splits", comment: "Keybind action")

        case .open_settings: return String(localized: "Settings", comment: "Keybind action: open settings")
        case .browse_hosts: return String(localized: "Browse Hosts", comment: "Keybind action")
        case .browse_profiles: return String(localized: "Browse Profiles", comment: "Keybind action")
        case .toggle_ai_agent: return String(localized: "Toggle AI Agent", comment: "Keybind action")
        case .toggle_voice_agent: return String(localized: "Toggle Voice Agent", comment: "Keybind action")
        case .toggle_tab_bar: return String(localized: "Toggle Top Tab Bar", comment: "Keybind action")
        case .toggle_group_mode: return String(localized: "Toggle Group Mode", comment: "Keybind action")
        case .toggle_tab_switcher: return String(localized: "Toggle Vertical Tab Bar", comment: "Keybind action")
        case .toggle_tab_expose: return String(localized: "Toggle Tab Exposé", comment: "Keybind action")
        case .previous_group: return String(localized: "Previous Group", comment: "Keybind action")
        case .next_group: return String(localized: "Next Group", comment: "Keybind action")
        case .toggle_transparency: return String(localized: "Toggle Transparency", comment: "Keybind action")
        case .toggle_titlebar: return String(localized: "Toggle Title Bar", comment: "Keybind action")
        case .toggle_auto_redact: return String(localized: "Toggle Auto-Redact", comment: "Keybind action")
        case .toggle_theme_picker: return String(localized: "Toggle Theme Picker", comment: "Keybind action")
        case .toggle_clipboard_manager: return String(localized: "Toggle Clipboard Manager", comment: "Keybind action")
        case .toggle_background_effect: return String(localized: "Toggle Background Effect", comment: "Keybind action")
        case .toggle_compose: return String(localized: "Toggle Compose", comment: "Keybind action")
        case .toggle_full_screen: return String(localized: "Toggle Full Screen", comment: "Keybind action")
        case .toggle_mouse_capture: return String(localized: "Toggle Mouse Capture", comment: "Keybind action")
        case .brightness_boost: return String(localized: "Brightness Boost", comment: "Keybind action: toggle HDR brightness boost HUD")
        case .cycle_input_source: return String(localized: "Switch Keyboard Language", comment: "Keybind action: cycle to next system keyboard/input source")
        case .focus_external_display: return String(localized: "Focus External Display", comment: "Keybind action: toggle input focus between device and external display")
        case .move_tab_to_external_display: return String(localized: "Move Tab to External Display", comment: "Keybind action: move the current tab to/from the external display")

        // Control characters: technical abbreviations, not localized
        case .ctrl_a: return "Ctrl+A (SOH)"
        case .ctrl_b: return "Ctrl+B (STX)"
        case .ctrl_c: return "Ctrl+C (Interrupt)"
        case .ctrl_d: return "Ctrl+D (EOF)"
        case .ctrl_e: return "Ctrl+E (ENQ)"
        case .ctrl_f: return "Ctrl+F (ACK)"
        case .ctrl_g: return "Ctrl+G (Bell)"
        case .ctrl_h: return "Ctrl+H (Backspace)"
        case .ctrl_i: return "Ctrl+I (Tab)"
        case .ctrl_j: return "Ctrl+J (Newline)"
        case .ctrl_k: return "Ctrl+K (Kill Line)"
        case .ctrl_l: return "Ctrl+L (Clear)"
        case .ctrl_m: return "Ctrl+M (Return)"
        case .ctrl_n: return "Ctrl+N (Next)"
        case .ctrl_o: return "Ctrl+O (SI)"
        case .ctrl_p: return "Ctrl+P (Previous)"
        case .ctrl_q: return "Ctrl+Q (Resume)"
        case .ctrl_r: return "Ctrl+R (Reverse Search)"
        case .ctrl_s: return "Ctrl+S (Suspend)"
        case .ctrl_t: return "Ctrl+T (Transpose)"
        case .ctrl_u: return "Ctrl+U (Kill to Start)"
        case .ctrl_v: return "Ctrl+V (Literal)"
        case .ctrl_w: return "Ctrl+W (Kill Word)"
        case .ctrl_x: return "Ctrl+X (Cancel)"
        case .ctrl_y: return "Ctrl+Y (Yank)"
        case .ctrl_z: return "Ctrl+Z (Suspend)"

        case .send_text: return String(localized: "Send Text", comment: "Keybind action: send text to terminal")
        case .send_esc: return String(localized: "Send ESC Sequence", comment: "Keybind action: send ESC sequence")
        case .send_csi: return String(localized: "Send CSI Sequence", comment: "Keybind action: send CSI sequence")

        case .unbind: return String(localized: "Unbind", comment: "Keybind action: remove binding")
        }
    }

    /// Notification name for app actions (nil for terminal actions)
    var notificationName: Notification.Name? {
        switch self {
        case .increase_font_size: return .increaseFontSize
        case .decrease_font_size: return .decreaseFontSize
        case .reset_font_size: return .resetFontSize
        case .start_search: return .startSearch

        case .new_local_shell: return .createLocalShell
        case .new_tab: return .newTab
        case .new_window: return .newWindow
        case .close_tab: return .closeSplit
        case .duplicate_ssh_tab: return .duplicateTabWithSSH
        case .previous_tab: return .previousTab
        case .next_tab: return .nextTab
        case .show_tmux_sessions: return .showTmuxSessions
        case .detach_other_clients: return .detachOtherClients
        case .select_tab_1, .select_tab_2, .select_tab_3, .select_tab_4, .select_tab_5,
             .select_tab_6, .select_tab_7, .select_tab_8, .select_tab_9:
            return .selectTab

        case .split_right, .split_down: return .createSplit
        case .navigate_split_left, .navigate_split_right, .navigate_split_up, .navigate_split_down:
            return .navigateSplit
        case .toggle_split_zoom: return .toggleSplitZoom
        case .equalize_splits: return .equalizeSplits

        case .open_settings: return .openSettings
        case .browse_hosts: return .browseHosts
        case .browse_profiles: return .browseProfiles
        case .toggle_ai_agent: return .toggleAIAgent
        case .toggle_voice_agent: return .toggleVoiceAgent
        case .toggle_tab_bar: return .toggleTabBar
        case .toggle_group_mode: return .toggleGroupMode
        case .toggle_tab_switcher: return .showTabSwitcher
        case .toggle_tab_expose: return .toggleTabExpose
        case .previous_group: return .previousGroup
        case .next_group: return .nextGroup
        case .toggle_transparency: return .toggleTransparency
        case .toggle_titlebar: return .toggleTitleBar
        case .toggle_auto_redact: return .toggleAutoRedact
        case .toggle_theme_picker: return .toggleThemePicker
        case .toggle_clipboard_manager: return .toggleClipboardManager
        case .toggle_background_effect: return .toggleBackgroundEffect
        case .toggle_full_screen: return .toggleFullScreen
        case .focus_external_display: return .toggleExternalDisplayFocus
        case .move_tab_to_external_display: return .moveTabToExternalDisplay

        // toggle_compose and toggle_mouse_capture are handled directly in executeKeybindAction (not via notification)
        case .toggle_compose: return nil
        case .toggle_mouse_capture: return nil

        default:
            return nil
        }
    }

    /// Ghostty binding action string for terminal actions
    var ghosttyActionString: String? {
        switch self {
        case .copy_to_clipboard: return "copy_to_clipboard"
        case .paste_from_clipboard: return "paste_from_clipboard"
        case .scroll_page_up: return "scroll_page_up"
        case .scroll_page_down: return "scroll_page_down"
        case .scroll_to_top: return "scroll_to_top"
        case .scroll_to_bottom: return "scroll_to_bottom"
        case .select_all: return "select_all"
        case .clear_screen: return "clear_screen"
        case .reset_terminal: return "reset"
        default:
            return nil
        }
    }

    /// Tab index for select_tab actions (1-9)
    var tabIndex: Int? {
        switch self {
        case .select_tab_1: return 1
        case .select_tab_2: return 2
        case .select_tab_3: return 3
        case .select_tab_4: return 4
        case .select_tab_5: return 5
        case .select_tab_6: return 6
        case .select_tab_7: return 7
        case .select_tab_8: return 8
        case .select_tab_9: return 9
        default: return nil
        }
    }

    /// Split direction for split actions
    var splitDirection: String? {
        switch self {
        case .split_right: return "right"
        case .split_down: return "down"
        case .navigate_split_left: return "left"
        case .navigate_split_right: return "right"
        case .navigate_split_up: return "up"
        case .navigate_split_down: return "down"
        default: return nil
        }
    }

    /// Whether this action is parameterized (many bindings can share the same action with different params).
    /// Parameterized actions skip action-based dedup in KeybindManager.reloadBindings().
    var isParameterized: Bool {
        switch self {
        case .send_text, .send_esc, .send_csi:
            return true
        default:
            return false
        }
    }

    /// Whether this action needs wantsPriorityOverSystemBehavior
    var needsSystemPriority: Bool {
        switch self {
        case .close_tab, .new_tab, .new_window, .new_local_shell, .start_search, .toggle_compose,
             .send_text, .send_esc, .send_csi,
             // ⌘⌥[ / ⌘⌥]: Option composes a different character, so the menu
             // key-equivalent path can't claim the press before the terminal
             // encodes it as Alt-[; a prioritized UIKeyCommand must own it.
             .previous_group, .next_group, .focus_external_display:
            return true
        default:
            return false
        }
    }

    /// Actions that should be shown in the UI for customization
    static var customizableActions: [KeybindAction] {
        allCases.filter { action in
            switch action {
            case .unbind, .send_text, .send_esc, .send_csi:
                return false
            default:
                return !action.isControlCharacter
            }
        }
    }

    /// Control character actions only
    static var controlCharacterActions: [KeybindAction] {
        allCases.filter { $0.isControlCharacter }
    }

    /// Whether this action has a keyboard shortcut in SwiftUI Commands on iOS 26+
    /// These actions don't need UIKeyCommands UNLESS the user has customized them.
    /// When customized, KeybindCommandGenerator creates UIKeyCommands with
    /// wantsPriorityOverSystemBehavior to intercept before SwiftUI Commands.
    var isHandledBySwiftUICommands: Bool {
        switch self {
        // FileCommands actions - have keyboard shortcuts in SwiftUI Commands
        case .new_local_shell, .new_tab, .new_window, .duplicate_ssh_tab:
            return true

        // close_tab is handled by system Close menu item
        case .close_tab:
            return true

        // Menu bar actions WITH keyboard shortcuts in SwiftUI Commands (AppCommands.swift)
        case .previous_tab, .next_tab, .select_tab_1, .select_tab_2, .select_tab_3,
             .select_tab_4, .select_tab_5, .select_tab_6, .select_tab_7, .select_tab_8,
             .select_tab_9, .split_right, .split_down, .navigate_split_left,
             .navigate_split_right, .navigate_split_up, .navigate_split_down,
             .toggle_split_zoom, .equalize_splits, .open_settings, .browse_hosts,
             .browse_profiles, .toggle_ai_agent, .toggle_voice_agent, .toggle_tab_bar, .toggle_group_mode, .toggle_transparency,
             .toggle_titlebar, .toggle_auto_redact,
             .toggle_background_effect, .toggle_tab_switcher, .toggle_tab_expose, .show_tmux_sessions,
             .detach_other_clients,
             .increase_font_size, .decrease_font_size,
             .reset_font_size, .start_search:
            return true

        // Clipboard and terminal actions now have menu entries in AppCommands.swift
        case .copy_to_clipboard, .paste_from_clipboard, .toggle_clipboard_manager,
             .scroll_page_up, .scroll_page_down, .scroll_to_top, .scroll_to_bottom,
             .clear_screen, .select_all, .toggle_theme_picker, .toggle_compose,
             .toggle_full_screen, .toggle_mouse_capture, .cycle_input_source,
             .brightness_boost:
            return true

        // These actions don't have menu entries, or (group navigation) have
        // menu entries but keep the shortcut on a prioritized UIKeyCommand.
        case .reset_terminal, .send_text, .send_esc, .send_csi, .previous_group, .next_group,
             .focus_external_display, .move_tab_to_external_display:
            return false

        // Control characters are handled separately
        case .ctrl_a, .ctrl_b, .ctrl_c, .ctrl_d, .ctrl_e, .ctrl_f, .ctrl_g,
             .ctrl_h, .ctrl_i, .ctrl_j, .ctrl_k, .ctrl_l, .ctrl_m, .ctrl_n,
             .ctrl_o, .ctrl_p, .ctrl_q, .ctrl_r, .ctrl_s, .ctrl_t, .ctrl_u,
             .ctrl_v, .ctrl_w, .ctrl_x, .ctrl_y, .ctrl_z:
            return false

        case .unbind:
            return false
        }
    }
}
