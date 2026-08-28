//
//  AppCommands.swift
//  rootshell
//
//  SwiftUI Commands for menu bar integration on macOS Catalyst and iPadOS 26+
//  These provide menu visibility while UIKeyCommands handle actual input priority
//
//  All commands use UIApplication.shared.sendAction() to route through the responder
//  chain, ensuring actions are handled by the focused terminal in the key window.
//

import SwiftUI
import UIKit
import Combine

// MARK: - Keyboard Shortcut State

/// Observable object that provides current keyboard shortcuts for menu display
/// This is separate from KeybindManager to avoid the iPadOS 26 issue with
/// @ObservedObject in CommandGroup(replacing:)
@MainActor
final class MenuShortcutState: ObservableObject {
    static let shared = MenuShortcutState()

    @Published var shortcuts: [KeybindAction: KeyboardShortcut] = [:]

    /// Whether a menu bar exists to carry app shortcuts. Both menu rails dispatch
    /// through UIApplication notifications rather than the responder chain, so a
    /// menu item still fires while an overlay owns first responder — and a second
    /// SwiftUI `.keyboardShortcut` for the same chord blanks the item's glyph.
    /// Overlay shortcut catchers are installed only where this is false; before
    /// iPadOS 26 the ⌘-hold HUD is the surface and there is no menu to break.
    nonisolated static var menuRailOwnsShortcuts: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #elseif os(visionOS)
        return false
        #else
        if #available(iOS 26.0, *) { return true }
        return false
        #endif
    }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Build initial shortcuts
        rebuildShortcuts()

        // Listen for keybind changes
        KeybindManager.shared.keybindsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.rebuildShortcuts()
            }
            .store(in: &cancellables)
    }

    private func rebuildShortcuts() {
        var newShortcuts: [KeybindAction: KeyboardShortcut] = [:]

        for binding in KeybindManager.shared.activeBindings {
            // Multi-key sequences (e.g. ctrl+a > t) cannot be represented as
            // menu shortcuts; publishing just the leader chord would fire the
            // action on a bare ctrl+a, hijacking the sequence's first key.
            // KeybindCommandGenerator applies the same exclusion; sequences
            // are handled exclusively by KeySequenceTracker.
            guard !binding.sequence.isSequence,
                  let firstTrigger = binding.sequence.first,
                  let keyEquivalent = firstTrigger.swiftUIKeyEquivalent else {
                continue
            }

            #if targetEnvironment(macCatalyst)
            // The fixed "Send Escape" menu item is the sole owner of ⌘. on
            // Catalyst (the reserved chord only arrives via the menu rail);
            // its handler dispatches a cmd+period binding itself. Publishing
            // the shortcut here too would create a duplicate key equivalent.
            if firstTrigger == .commandPeriod { continue }
            #endif

            let modifiers = firstTrigger.swiftUIEventModifiers
            newShortcuts[binding.action] = KeyboardShortcut(keyEquivalent, modifiers: modifiers)
        }

        shortcuts = newShortcuts
    }
}

// MARK: - Main Commands Structure

struct AppCommands: Commands {
    @ObservedObject var shortcutState = MenuShortcutState.shared

    var body: some Commands {
        // FileCommands and EditCommands use CommandGroup to modify existing system menus
        // These work reliably on all macOS versions
        FileCommands(shortcutState: shortcutState)
        EditCommands(shortcutState: shortcutState)

        // AppViewCommands uses CommandGroup to inject into the system View menu
        // This works reliably on all macOS versions (like File/Edit)
        AppViewCommands(shortcutState: shortcutState)

        // Terminal, Shell, and Tabs menus use CommandMenu to create NEW top-level menus
        // CommandMenu only works reliably on macOS 26+ / iOS 26+
        // On older versions, CatalystAppDelegate.buildMenu(with:) handles these via UIMenuBuilder
        if #available(macCatalyst 26.0, iOS 26.0, *) {
            TerminalCommands(shortcutState: shortcutState)
            ShellCommands(shortcutState: shortcutState)
            WindowCommands(shortcutState: shortcutState)
        }
    }
}

// MARK: - File Commands

struct FileCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // Rootshell is not document-based, and macOS's default Save As/Duplicate
        // item owns Cmd+Shift+S. Removing it lets tmux Sessions display and own
        // the user-configurable default shortcut in the Tabs menu.
        CommandGroup(replacing: .saveItem) {
            EmptyView()
        }

        // Replace system "New" items with our custom file commands
        CommandGroup(replacing: .newItem) {
            Button("New Local Shell") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuCreateLocalShell(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .new_local_shell, shortcuts: shortcutState.shortcuts))

            Button("New Tab") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuNewTab(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .new_tab, shortcuts: shortcutState.shortcuts))

            Button("New Window") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuNewWindow(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .new_window, shortcuts: shortcutState.shortcuts))

            Button("Duplicate SSH Tab") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuDuplicateTabWithSSH(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .duplicate_ssh_tab, shortcuts: shortcutState.shortcuts))
        }
    }
}

// MARK: - Dynamic Shortcut Modifier

/// View modifier that applies a keyboard shortcut from the current binding state
struct DynamicShortcut: ViewModifier {
    let action: KeybindAction
    let shortcuts: [KeybindAction: KeyboardShortcut]

    func body(content: Content) -> some View {
        if let shortcut = shortcuts[action] {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

// Note: Close (Cmd-W) is handled by:
// 1. System-provided Close menu item
// 2. UIKeyCommand in TerminalViewKeyboard.swift with wantsPriorityOverSystemBehavior
// 3. pressesBegan fallback for macOS Sequoia compatibility

// MARK: - Edit Commands

struct EditCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // System provides Copy/Paste/Select All via .pasteboard - don't duplicate them
        // Add Clear Screen and Find after system pasteboard items
        CommandGroup(after: .pasteboard) {
            Button("Clear Screen") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuClearScreen(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .clear_screen, shortcuts: shortcutState.shortcuts))

            Divider()

            Button("Find") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.findInTerminal(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .start_search, shortcuts: shortcutState.shortcuts))
        }
    }
}

// MARK: - View Commands (injected into system View menu)

struct AppViewCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // Inject view/appearance items into the system View menu after toolbar items
        CommandGroup(after: .toolbar) {
            // Font size section
            Button("Increase Font Size") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.increaseFontSize(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .increase_font_size, shortcuts: shortcutState.shortcuts))

            Button("Decrease Font Size") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.decreaseFontSize(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .decrease_font_size, shortcuts: shortcutState.shortcuts))

            Button("Reset Font Size") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.resetFontSizeToDefault(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .reset_font_size, shortcuts: shortcutState.shortcuts))

            Divider()

            // View toggles
            Button("Toggle Top Tab Bar") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleTabBar(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_tab_bar, shortcuts: shortcutState.shortcuts))

            Button("Toggle Group Mode") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleGroupMode(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_group_mode, shortcuts: shortcutState.shortcuts))

            Button("Toggle Background Effect") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleBackgroundEffect(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_background_effect, shortcuts: shortcutState.shortcuts))

            Button("Toggle Theme Picker") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleThemePicker(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_theme_picker, shortcuts: shortcutState.shortcuts))

            Button("Clipboard Manager") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleClipboardManager(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_clipboard_manager, shortcuts: shortcutState.shortcuts))

            Button("Brightness Boost") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuBrightnessBoost(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .brightness_boost, shortcuts: shortcutState.shortcuts))

            // Checked menu item: the toggle binds straight to the global
            // manager (redaction is app-wide, not per-window) so the
            // checkmark tracks state from any entry point.
            Toggle("Auto-Redact", isOn: Binding(
                get: { RedactionManager.shared.isEnabled },
                set: { _ in RedactionManager.shared.toggle() }
            ))
            .modifier(DynamicShortcut(action: .toggle_auto_redact, shortcuts: shortcutState.shortcuts))

            Divider()

            Button("Switch Keyboard Language") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuCycleInputSource(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .cycle_input_source, shortcuts: shortcutState.shortcuts))

            #if targetEnvironment(macCatalyst)
            Button("Toggle Transparency") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleTransparency(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_transparency, shortcuts: shortcutState.shortcuts))

            Button("Toggle Title Bar") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleTitleBar(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_titlebar, shortcuts: shortcutState.shortcuts))
            #endif

            #if !targetEnvironment(macCatalyst)
            // iPad only — macOS system provides "Enter Full Screen" in View menu
            Button("Toggle Full Screen") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleFullScreen(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_full_screen, shortcuts: shortcutState.shortcuts))
            #endif
        }
    }
}

// MARK: - Terminal Commands

struct TerminalCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        CommandMenu("Terminal") {
            // Split creation
            Button("Split Right") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSplitRight(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .split_right, shortcuts: shortcutState.shortcuts))

            Button("Split Down") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSplitDown(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .split_down, shortcuts: shortcutState.shortcuts))

            Divider()

            // Focus Split submenu
            Menu("Focus Split") {
                Button("Left") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitLeft(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_left, shortcuts: shortcutState.shortcuts))

                Button("Right") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitRight(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_right, shortcuts: shortcutState.shortcuts))

                Button("Up") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitUp(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_up, shortcuts: shortcutState.shortcuts))

                Button("Down") {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuNavigateSplitDown(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
                .modifier(DynamicShortcut(action: .navigate_split_down, shortcuts: shortcutState.shortcuts))
            }

            Divider()

            // Split management
            Button("Toggle Split Zoom") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleSplitZoom(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_split_zoom, shortcuts: shortcutState.shortcuts))

            Button("Equalize Splits") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuEqualizeSplits(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .equalize_splits, shortcuts: shortcutState.shortcuts))

            Divider()

            // Scroll commands
            Button("Scroll Page Up") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollPageUp(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_page_up, shortcuts: shortcutState.shortcuts))

            Button("Scroll Page Down") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollPageDown(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_page_down, shortcuts: shortcutState.shortcuts))

            Button("Scroll to Top") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollToTop(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_to_top, shortcuts: shortcutState.shortcuts))

            Button("Scroll to Bottom") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuScrollToBottom(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .scroll_to_bottom, shortcuts: shortcutState.shortcuts))

            Divider()

            Button("Toggle Compose") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleCompose(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_compose, shortcuts: shortcutState.shortcuts))

            Button("Toggle Mouse Capture") {
                if !UIApplication.shared.sendAction(
                    NSSelectorFromString("toggleVNCKeyboardCapture:"),
                    to: nil, from: nil, for: nil
                ) {
                    UIApplication.shared.sendAction(
                        #selector(Ghostty.TerminalView.menuToggleMouseCapture(_:)),
                        to: nil, from: nil, for: nil
                    )
                }
            }
            .modifier(DynamicShortcut(action: .toggle_mouse_capture, shortcuts: shortcutState.shortcuts))

            #if targetEnvironment(macCatalyst)
            Divider()

            // Cmd+Period never reaches responder UIKeyCommands or press events
            // on Catalyst — a menu key equivalent (like Xcode's ⌘. Stop item)
            // is the one rail that receives AND consumes the reserved chord.
            // Fixed shortcut: MenuShortcutState excludes cmd+period so this
            // item stays its sole owner; the handler dispatches a cmd+period
            // keybind first and falls back to sending Escape.
            Button("Send Escape") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSystemCancel(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .keyboardShortcut(".", modifiers: .command)
            #endif
        }
    }
}

// MARK: - Shell Commands

struct ShellCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        CommandMenu("Shell") {
            Button("Browse Hosts") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuBrowseHosts(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .browse_hosts, shortcuts: shortcutState.shortcuts))

            Button("Browse Profiles") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuBrowseProfiles(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .browse_profiles, shortcuts: shortcutState.shortcuts))

            #if !CHINA_BUILD
            Divider()

            Button("AI Agent") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleAIAgent(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_ai_agent, shortcuts: shortcutState.shortcuts))

            Button("Voice Agent") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuToggleVoiceAgent(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .toggle_voice_agent, shortcuts: shortcutState.shortcuts))
            #endif
        }

        // Handle system Settings menu item (Cmd+,)
        // The system provides "Settings..." automatically, we just need to handle the action
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                UIApplication.shared.menuOpenSettings(
                    VNCReservedKeyboardShortcut.openSettings.notificationSender
                )
            }
            .modifier(DynamicShortcut(action: .open_settings, shortcuts: shortcutState.shortcuts))
        }
    }
}

// MARK: - Window Commands

struct WindowCommands: Commands {
    @ObservedObject var shortcutState: MenuShortcutState

    var body: some Commands {
        // Use "Tabs" menu to avoid conflict with system Window menu
        CommandMenu("Tabs") {
            Button("Toggle Vertical Tab Bar") {
                UIApplication.shared.menuToggleTabSwitcher(
                    VNCReservedKeyboardShortcut.toggleTabSwitcher.notificationSender
                )
            }
            .modifier(DynamicShortcut(action: .toggle_tab_switcher, shortcuts: shortcutState.shortcuts))

            Button("Tab Exposé") {
                // Posts the window-scoped notification directly so it works
                // with no terminal in the responder chain (VNC pane focused).
                UIApplication.shared.menuToggleTabExpose(nil)
            }
            .modifier(DynamicShortcut(action: .toggle_tab_expose, shortcuts: shortcutState.shortcuts))

            Button("Previous Tab") {
                UIApplication.shared.menuPreviousTab(
                    VNCReservedKeyboardShortcut.previousTab.notificationSender
                )
            }
            .modifier(DynamicShortcut(action: .previous_tab, shortcuts: shortcutState.shortcuts))

            Button("Next Tab") {
                UIApplication.shared.menuNextTab(
                    VNCReservedKeyboardShortcut.nextTab.notificationSender
                )
            }
            .modifier(DynamicShortcut(action: .next_tab, shortcuts: shortcutState.shortcuts))

            // ⌘⌥[ / ⌘⌥]: Option composes a different character, so before 26 a
            // prioritized UIKeyCommand owns these (KeybindAction.needsSystemPriority).
            // From 26 the menu owns them, which is what shows the glyph.
            Button("Previous Group") {
                UIApplication.shared.menuPreviousGroup(nil)
            }
            .modifier(DynamicShortcut(action: .previous_group, shortcuts: shortcutState.shortcuts))

            Button("Next Group") {
                UIApplication.shared.menuNextGroup(nil)
            }
            .modifier(DynamicShortcut(action: .next_group, shortcuts: shortcutState.shortcuts))

            Button("tmux Sessions") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuShowTmuxSessions(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .show_tmux_sessions, shortcuts: shortcutState.shortcuts))

            Button("Detach Other Clients") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuDetachOtherClients(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .detach_other_clients, shortcuts: shortcutState.shortcuts))

            Divider()

            // Tab selection (1-9) - individual buttons for sendAction compatibility
            Button("Tab 1") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab1(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_1, shortcuts: shortcutState.shortcuts))

            Button("Tab 2") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab2(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_2, shortcuts: shortcutState.shortcuts))

            Button("Tab 3") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab3(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_3, shortcuts: shortcutState.shortcuts))

            Button("Tab 4") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab4(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_4, shortcuts: shortcutState.shortcuts))

            Button("Tab 5") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab5(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_5, shortcuts: shortcutState.shortcuts))

            Button("Tab 6") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab6(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_6, shortcuts: shortcutState.shortcuts))

            Button("Tab 7") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab7(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_7, shortcuts: shortcutState.shortcuts))

            Button("Tab 8") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab8(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_8, shortcuts: shortcutState.shortcuts))

            Button("Tab 9") {
                UIApplication.shared.sendAction(
                    #selector(Ghostty.TerminalView.menuSelectTab9(_:)),
                    to: nil, from: nil, for: nil
                )
            }
            .modifier(DynamicShortcut(action: .select_tab_9, shortcuts: shortcutState.shortcuts))
        }
    }
}
