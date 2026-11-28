//
//  CustomTheme.swift
//  rootshell
//
//  Data model for user-created custom themes
//

import Foundation
import SwiftUI

struct CustomTheme: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var createdDate: Date
    var modifiedDate: Date

    var background: String          // "#1e1e2e"
    var foreground: String
    var cursorColor: String         // maps to cursor-color
    var cursorText: String          // maps to cursor-text
    var selectionBackground: String // maps to selection-background
    var selectionForeground: String // maps to selection-foreground
    var palette: [String]           // 16 entries, indices 0-15
    var extendedPalette: [Int: String] = [:]  // Palette indices 16-255

    /// Whether the theme has extended palette colors beyond the base 16 ANSI colors
    var hasExtendedPalette: Bool { !extendedPalette.isEmpty }

    init(
        id: UUID,
        name: String,
        createdDate: Date,
        modifiedDate: Date,
        background: String,
        foreground: String,
        cursorColor: String,
        cursorText: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String],
        extendedPalette: [Int: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
        self.extendedPalette = extendedPalette
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        modifiedDate = try container.decode(Date.self, forKey: .modifiedDate)
        background = try container.decode(String.self, forKey: .background)
        foreground = try container.decode(String.self, forKey: .foreground)
        cursorColor = try container.decode(String.self, forKey: .cursorColor)
        cursorText = try container.decode(String.self, forKey: .cursorText)
        selectionBackground = try container.decode(String.self, forKey: .selectionBackground)
        selectionForeground = try container.decode(String.self, forKey: .selectionForeground)
        palette = try container.decode([String].self, forKey: .palette)
        extendedPalette = try container.decodeIfPresent([Int: String].self, forKey: .extendedPalette) ?? [:]
    }

    /// Whether the theme background is light
    var isLight: Bool {
        Color(hex: background)?.luminance ?? 0 > 0.5
    }

    /// Convert to ThemeColors for preview integration.
    /// Resolves Ghostty keyword values (e.g. `cell-foreground`) to concrete hex for UI display.
    var themeColors: ThemeManager.ThemeInfo.ThemeColors {
        let resolvedCursor = Color.resolveKeywordColor(cursorColor, foreground: foreground, background: background)
        return ThemeManager.ThemeInfo.ThemeColors(
            background: background,
            foreground: foreground,
            cursor: resolvedCursor,
            palette: Array(palette.prefix(16))
        )
    }

    /// Generate Ghostty theme file content (key=value format)
    func toGhosttyFileContent() -> String {
        var lines: [String] = []
        lines.append("background = \(background)")
        lines.append("foreground = \(foreground)")
        lines.append("cursor-color = \(cursorColor)")
        lines.append("cursor-text = \(cursorText)")
        lines.append("selection-background = \(selectionBackground)")
        lines.append("selection-foreground = \(selectionForeground)")
        for (index, color) in palette.enumerated() {
            lines.append("palette = \(index)=\(color)")
        }
        for index in extendedPalette.keys.sorted() {
            lines.append("palette = \(index)=\(extendedPalette[index]!)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Default theme with standard Catppuccin Mocha-inspired colors
    static func defaultTheme() -> CustomTheme {
        CustomTheme(
            id: UUID(),
            name: "",
            createdDate: Date(),
            modifiedDate: Date(),
            background: "#1E1E2E",
            foreground: "#CDD6F4",
            cursorColor: "#F5E0DC",
            cursorText: "#1E1E2E",
            selectionBackground: "#585B70",
            selectionForeground: "#CDD6F4",
            palette: [
                "#45475A", // 0  Black
                "#F38BA8", // 1  Red
                "#A6E3A1", // 2  Green
                "#F9E2AF", // 3  Yellow
                "#89B4FA", // 4  Blue
                "#F5C2E7", // 5  Magenta
                "#94E2D5", // 6  Cyan
                "#BAC2DE", // 7  White
                "#585B70", // 8  Bright Black
                "#F38BA8", // 9  Bright Red
                "#A6E3A1", // 10 Bright Green
                "#F9E2AF", // 11 Bright Yellow
                "#89B4FA", // 12 Bright Blue
                "#F5C2E7", // 13 Bright Magenta
                "#94E2D5", // 14 Bright Cyan
                "#A6ADC8", // 15 Bright White
            ]
        )
    }

    /// Create a CustomTheme from parsed Ghostty theme file content
    static func fromGhosttyFileContent(_ content: String, name: String) -> CustomTheme {
        var theme = defaultTheme()
        theme.name = name

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let eqIndex = trimmed.firstIndex(of: "=") else { continue }

            let key = trimmed[trimmed.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eqIndex)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "background":
                theme.background = value
            case "foreground":
                theme.foreground = value
            case "cursor-color":
                theme.cursorColor = value
            case "cursor-text":
                theme.cursorText = value
            case "selection-background":
                theme.selectionBackground = value
            case "selection-foreground":
                theme.selectionForeground = value
            case "palette":
                if let eqIdx = value.firstIndex(of: "=") {
                    let indexStr = value[value.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
                    let hex = value[value.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                    if let index = Int(indexStr), index >= 0, index < 256 {
                        if index < 16 {
                            theme.palette[index] = hex
                        } else {
                            theme.extendedPalette[index] = hex
                        }
                    }
                }
            default:
                break
            }
        }

        return theme
    }
}
