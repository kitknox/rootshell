//
//  KeyboardLayout.swift
//  rootshell
//
//  Defines keyboard toolbar layouts for different devices
//

import UIKit

// MARK: - Key Definition

enum KeyDefinition {
    // Modifiers
    case esc
    case ctrl
    case alt
    case shift
    case cmd

    // Special keys
    case tab
    case arrows  // Arrow cluster (4 keys)

    // Symbols with dual values (primary, secondary)
    case symbol(String, String)

    // Individual symbol keys
    case tilde, underscore, pipe, leftBrace, rightBrace
    case questionMark, equals, doubleQuote, colon
    case hash, percent, asterisk
    case leftParen, rightParen
    case atSign, dollar, ampersand
    case caret, backtick, backslash
    case leftBracket, rightBracket
    case lessThan, greaterThan
    case slash, dash, singleQuote, semicolon

    // Single text key
    case text(String)

    // Action buttons
    case dismiss
    case tabSwitcher

    // Drawer toggles (iPhone only)
    case arrowDrawerToggle
    case extraKeysDrawerToggle

    // Compose text overlay
    case compose

    // Toolbar settings
    case toolbarSettings

    // Paste from clipboard
    case paste

    // Voice agent toggle
    case voiceAgent

    // App action buttons
    case toggleFullScreen
    case toggleTabBar
    case newConnection
    case appSettings
    case toggleMouseCapture
    case aiAgent
    case brightnessBoost
    case clipboardManager
    case externalDisplay

    var keyValue: String {
        switch self {
        case .esc: return "Esc"
        case .ctrl: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        case .cmd: return "Cmd"
        case .tab: return "\t"
        case .arrows: return "arrows"
        case .symbol(let primary, _): return primary
        case .tilde: return "~"
        case .underscore: return "_"
        case .pipe: return "|"
        case .leftBrace: return "{"
        case .rightBrace: return "}"
        case .questionMark: return "?"
        case .equals: return "="
        case .doubleQuote: return "\""
        case .colon: return ":"
        case .hash: return "#"
        case .percent: return "%"
        case .asterisk: return "*"
        case .leftParen: return "("
        case .rightParen: return ")"
        case .atSign: return "@"
        case .dollar: return "$"
        case .ampersand: return "&"
        case .caret: return "^"
        case .backtick: return "`"
        case .backslash: return "\\"
        case .leftBracket: return "["
        case .rightBracket: return "]"
        case .lessThan: return "<"
        case .greaterThan: return ">"
        case .slash: return "/"
        case .dash: return "-"
        case .singleQuote: return "'"
        case .semicolon: return ";"
        case .text(let value): return value
        case .dismiss: return "__dismiss__"
        case .tabSwitcher: return "__tabswitcher__"
        case .arrowDrawerToggle: return "__arrowDrawer__"
        case .extraKeysDrawerToggle: return "__extraDrawer__"
        case .compose: return "__compose__"
        case .toolbarSettings: return "__toolbarSettings__"
        case .paste: return "__paste__"
        case .voiceAgent: return "__voiceAgent__"
        case .toggleFullScreen: return "__toggleFullScreen__"
        case .toggleTabBar: return "__toggleTabBar__"
        case .newConnection: return "__newConnection__"
        case .appSettings: return "__appSettings__"
        case .toggleMouseCapture: return "__toggleMouseCapture__"
        case .aiAgent: return "__aiAgent__"
        case .brightnessBoost: return "__brightnessBoost__"
        case .clipboardManager: return "__clipboardManager__"
        case .externalDisplay: return "__externalDisplay__"
        }
    }

    var isModifier: Bool {
        switch self {
        case .esc, .ctrl, .alt, .shift, .cmd:
            return true
        default:
            return false
        }
    }

    var modifier: KeyModifiers? {
        switch self {
        case .ctrl: return .control
        case .alt: return .alt
        case .shift: return .shift
        case .cmd: return .command
        default: return nil
        }
    }
}

// MARK: - Keyboard Layout

struct KeyboardLayout {
    let leftSection: [KeyDefinition]
    let middleSection: [KeyDefinition]
    let rightSection: [KeyDefinition]

    // MARK: - Device-Specific Layouts

    static func layout(for device: UIUserInterfaceIdiom) -> KeyboardLayout {
        switch device {
        case .pad:
            return iPadLayout()
        case .phone:
            return iPhoneLayout()
        default:
            return iPhoneLayout()
        }
    }

    // MARK: - iPad Layout

    private static func iPadLayout() -> KeyboardLayout {
        return KeyboardLayout(
            leftSection: [
                .dismiss,
                .tabSwitcher,
                .esc,
                .ctrl,
                .alt,
                .shift,
                .compose
            ],
            middleSection: [
                .tab,
                .symbol("`", "~"),
                .symbol("^", "_"),
                .symbol("\\", "|"),
                .symbol("[", "{"),
                .symbol("]", "}"),
                .symbol("<", ">"),
                .symbol("/", "?"),
                .symbol("-", "="),
                .symbol("'", "\""),
                .symbol(";", ":"),
                .symbol("(", ")"),
                .symbol("@", "#"),
                .symbol("$", "%"),
                .symbol("&", "*")
            ],
            rightSection: [
                .arrows,
                .cmd
            ]
        )
    }

    // MARK: - iPhone Layout

    private static func iPhoneLayout() -> KeyboardLayout {
        return KeyboardLayout(
            leftSection: [
                .dismiss,
                .tabSwitcher,
                .esc,
                .ctrl,
                .compose,
                .shift
            ],
            middleSection: [
                .tab,
                .arrowDrawerToggle,
                .extraKeysDrawerToggle
            ],
            rightSection: []
        )
    }
}
