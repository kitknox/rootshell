#if !targetEnvironment(macCatalyst)
//
//  PromptFormatEvaluator.swift
//  rootshell
//
//  Evaluates parsed format trees into ANSI strings.
//  Resolves variables, colors, palette lookups, and Powerline arrows.
//

import Foundation
import UIKit

// MARK: - Evaluation Context

struct PromptEvalContext: Sendable {
    let directory: String
    let commandSucceeded: Bool
    let gitInfo: PromptGitInfo?
    let batteryLevel: Float      // 0.0-1.0, -1.0 if unavailable
    let batteryState: UIDevice.BatteryState

    // Network data (cached, may be nil)
    let wifiSSID: String?
    let wifiBand: String?        // "band2_4", "band5", "band6"
    let wifiAPName: String?
    let networkIP: String?
    let networkISP: String?
    let networkCountryFlag: String?
    let networkType: String?
    let connectionType: String?  // "wifi", "cellular", "wired", etc.
}

// MARK: - Powerline Glyphs

private enum PowerlineGlyph {
    static let arrowRight = "\u{E0B0}"   // Transition between segments
    static let roundedLeft = "\u{E0B6}"  // Cap before first segment
    static let roundedRight = "\u{E0B4}" // Cap after last segment
}

// MARK: - Evaluator

struct PromptFormatEvaluator {

    /// Evaluate a format node tree into an ANSI string
    /// Returns the prompt text and the visible width of the second line prefix
    /// - Parameter skipAutoCharacter: When true, skips auto-appending \\r\\n❯ when $character
    ///   is absent. Used for right prompts and transient prompts which are inline/replacement
    ///   formats, not full two-line prompts.
    static func evaluate(
        nodes: [FormatNode],
        config: PromptConfig,
        context: PromptEvalContext,
        skipAutoCharacter: Bool = false
    ) -> PromptStyle.PromptResult {
        var output = ""
        var currentBg: ColorSpec?

        for node in nodes {
            let segment = evaluateNode(node, config: config, context: context, currentBg: &currentBg)
            output += segment
        }

        // Close any remaining segment (if no $character and no line break at end)
        output += closeSegment(currentBg: &currentBg, config: config)

        // Reset at end
        output += PromptStyle.ansiReset

        // Auto-append character only for the main prompt
        if !skipAutoCharacter {
            let hasCharacter = containsVariable(nodes, named: "character")
            if !hasCharacter {
                output += "\r\n"
                let chevronColor = context.commandSucceeded ? "#a6e3a1" : "#f38ba8"
                output += "\u{1b}[1m"  // bold
                output += ansiFromHex(chevronColor, isFg: true)
                output += "❯"
                output += PromptStyle.ansiReset
                output += " "
            }
        }

        // Calculate secondLinePrefix: visible chars on the last line after the last \n
        let secondLinePrefix = calculateSecondLinePrefix(output)

        return PromptStyle.PromptResult(text: output, secondLinePrefix: max(secondLinePrefix, 1))
    }

    // MARK: - Segment Lifecycle

    /// Emit rounded right cap to close the current segment bar, clear currentBg
    private static func closeSegment(currentBg: inout ColorSpec?, config: PromptConfig) -> String {
        guard let prevBg = currentBg else { return "" }
        var output = ""
        output += PromptStyle.ansiReset
        output += resolveColor(prevBg, config: config, isFg: true)
        output += PowerlineGlyph.roundedRight
        output += PromptStyle.ansiReset
        currentBg = nil
        return output
    }

    // MARK: - Node Evaluation

    private static func evaluateNode(
        _ node: FormatNode,
        config: PromptConfig,
        context: PromptEvalContext,
        currentBg: inout ColorSpec?
    ) -> String {
        switch node {
        case .literal(let text):
            return evaluateLiteral(text, config: config, currentBg: &currentBg)

        case .variable(let name):
            return expandVariable(name, config: config, context: context, currentBg: &currentBg)

        case .styledGroup(let children, let style):
            return evaluateStyledGroup(children: children, style: style, config: config, context: context, currentBg: &currentBg)
        }
    }

    /// Handle literal text, including newline processing
    private static func evaluateLiteral(_ text: String, config: PromptConfig, currentBg: inout ColorSpec?) -> String {
        // If no newlines, pass through
        guard text.contains("\n") || text.contains("\r") else {
            return text
        }

        // Split at newlines, close segment before each line break
        var output = ""
        var remaining = text[text.startIndex...]

        while let newlineIdx = remaining.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            // Text before newline
            let before = remaining[remaining.startIndex..<newlineIdx]
            output += String(before)

            // Close active segment before line break
            output += closeSegment(currentBg: &currentBg, config: config)

            // Emit \r\n (normalize bare \n and \r\n)
            output += "\r\n"

            // Skip past the newline sequence (\r\n or bare \n or bare \r)
            var afterIdx = remaining.index(after: newlineIdx)
            if remaining[newlineIdx] == "\r" && afterIdx < remaining.endIndex && remaining[afterIdx] == "\n" {
                afterIdx = remaining.index(after: afterIdx)
            }
            remaining = remaining[afterIdx...]
        }

        // Remaining text after last newline
        output += String(remaining)
        return output
    }

    private static func evaluateStyledGroup(
        children: [FormatNode],
        style: PromptStyleSpec,
        config: PromptConfig,
        context: PromptEvalContext,
        currentBg: inout ColorSpec?
    ) -> String {
        // Evaluate children to check if group is empty
        var childOutput = ""
        var childBg = currentBg
        for child in children {
            childOutput += evaluateNode(child, config: config, context: context, currentBg: &childBg)
        }

        // If children produced no visible text, collapse the group
        let visibleContent = PromptStyle.stripANSI(childOutput)
        if visibleContent.trimmingCharacters(in: .whitespaces).isEmpty {
            return ""
        }

        var output = ""

        if let newBg = style.bg {
            if let prevBg = currentBg {
                if newBg != prevBg {
                    // Transition arrow between segments: prev bg as fg, new bg as bg
                    output += resolveColor(prevBg, config: config, isFg: true)
                    output += resolveColor(newBg, config: config, isFg: false)
                    output += PowerlineGlyph.arrowRight
                }
                // Same bg → no transition needed
            } else {
                // First segment: emit rounded left cap
                output += resolveColor(newBg, config: config, isFg: true)
                output += PowerlineGlyph.roundedLeft
            }
        }

        // Apply style
        output += applyStyle(style, config: config)

        // Render children
        output += childOutput

        // Update current bg
        if let newBg = style.bg {
            currentBg = newBg
        }

        return output
    }

    // MARK: - Variable Expansion

    private static func expandVariable(
        _ name: String,
        config: PromptConfig,
        context: PromptEvalContext,
        currentBg: inout ColorSpec?
    ) -> String {
        switch name {
        case "username":
            guard !config.username.disabled else { return "" }
            return expandModuleFormat(config.username.format, config: config, context: context, currentBg: &currentBg) {
                expandUsernameVar($0)
            }

        case "directory":
            guard !config.directory.disabled else { return "" }
            return expandModuleFormat(config.directory.format, config: config, context: context, currentBg: &currentBg) {
                expandDirectoryVar($0, config: config, context: context)
            }

        case "git_branch":
            guard !config.gitBranch.disabled, context.gitInfo != nil else { return "" }
            return expandModuleFormat(config.gitBranch.format, config: config, context: context, currentBg: &currentBg) {
                expandGitBranchVar($0, config: config, context: context)
            }

        case "git_status":
            guard !config.gitStatus.disabled, let git = context.gitInfo, git.staged > 0 else { return "" }
            return expandModuleFormat(config.gitStatus.format, config: config, context: context, currentBg: &currentBg) {
                expandGitStatusVar($0, config: config, context: context)
            }

        case "time":
            guard !config.time.disabled else { return "" }
            return expandModuleFormat(config.time.format, config: config, context: context, currentBg: &currentBg) {
                expandTimeVar($0, config: config)
            }

        case "battery":
            guard !config.battery.disabled else { return "" }
            guard context.batteryLevel >= 0 else { return "" }
            let pct = Int(context.batteryLevel * 100)
            guard pct <= config.battery.displayThreshold else { return "" }
            return expandModuleFormat(config.battery.format, config: config, context: context, currentBg: &currentBg) {
                expandBatteryVar($0, config: config, context: context)
            }

        case "character":
            return expandCharacter(config: config, context: context, currentBg: &currentBg)

        case "line_break":
            guard !config.lineBreak.disabled else { return "" }
            // Close active segment before line break
            var output = closeSegment(currentBg: &currentBg, config: config)
            output += "\r\n"
            return output

        case "wifi":
            guard !config.wifi.disabled, context.wifiSSID != nil else { return "" }
            return expandModuleFormat(config.wifi.format, config: config, context: context, currentBg: &currentBg) {
                expandWiFiVar($0, config: config, context: context)
            }

        case "network":
            guard !config.network.disabled else { return "" }
            guard context.networkISP != nil || context.networkCountryFlag != nil else { return "" }
            return expandModuleFormat(config.network.format, config: config, context: context, currentBg: &currentBg) {
                expandNetworkVar($0, config: config, context: context)
            }

        case "connection_type":
            guard !config.connectionType.disabled, context.connectionType != nil else { return "" }
            return expandModuleFormat(config.connectionType.format, config: config, context: context, currentBg: &currentBg) {
                expandConnectionTypeVar($0, config: config, context: context)
            }

        default:
            return ""  // Unknown variable — silently collapse
        }
    }

    /// Expand a module's format string, using a resolver for inner variables
    private static func expandModuleFormat(
        _ format: String,
        config: PromptConfig,
        context: PromptEvalContext,
        currentBg: inout ColorSpec?,
        resolver: (String) -> String?
    ) -> String {
        // Parse the module's format string
        guard let nodes = try? PromptFormatParser.parse(format) else { return "" }

        // Resolve variables in the parsed nodes
        let resolved = resolveModuleNodes(nodes, resolver: resolver)

        // Evaluate the resolved nodes
        var output = ""
        for node in resolved {
            output += evaluateNode(node, config: config, context: context, currentBg: &currentBg)
        }
        return output
    }

    /// Resolve variables in module format nodes using a resolver closure
    private static func resolveModuleNodes(_ nodes: [FormatNode], resolver: (String) -> String?) -> [FormatNode] {
        nodes.map { node in
            switch node {
            case .variable(let name):
                if let resolved = resolver(name) {
                    return .literal(resolved)
                }
                return .literal("")

            case .styledGroup(let children, let style):
                return .styledGroup(children: resolveModuleNodes(children, resolver: resolver), style: style)

            case .literal:
                return node
            }
        }
    }

    // MARK: - Module Variable Resolvers

    private static func expandUsernameVar(_ name: String) -> String? {
        switch name {
        case "user": return PromptStyle.promptUsername()
        default: return nil
        }
    }

    private static func expandDirectoryVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        switch name {
        case "path":
            return PromptStyle.promptShortenedPath(
                directory: context.directory,
                truncationLength: config.directory.truncationLength,
                truncationSymbol: config.directory.truncationSymbol
            )
        default: return nil
        }
    }

    private static func expandGitBranchVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        guard let git = context.gitInfo else { return nil }
        switch name {
        case "symbol": return config.gitBranch.symbol
        case "branch":
            var branch = git.branchName
            if config.gitBranch.truncationLength > 0 && branch.count > config.gitBranch.truncationLength {
                branch = String(branch.prefix(config.gitBranch.truncationLength)) + "…"
            }
            return branch
        case "status":
            return git.formattedSummary()
        default: return nil
        }
    }

    private static func expandGitStatusVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        guard let git = context.gitInfo else { return nil }
        switch name {
        case "staged":
            return git.staged > 0 ? "\(config.gitStatus.staged)\(git.staged)" : ""
        case "all_status":
            return git.formattedSummary()
        default: return nil
        }
    }

    private static func expandTimeVar(_ name: String, config: PromptConfig) -> String? {
        switch name {
        case "time":
            if let fmt = config.time.timeFormat {
                let formatter = DateFormatter()
                formatter.dateFormat = fmt
                return formatter.string(from: PromptStyle.promptDate)
            }
            return PromptStyle.promptCurrentTime()
        default: return nil
        }
    }

    private static func expandBatteryVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        switch name {
        case "symbol":
            switch context.batteryState {
            case .charging: return config.battery.chargingSymbol
            case .full: return config.battery.fullSymbol
            default: return config.battery.dischargingSymbol
            }
        case "percentage":
            return "\(Int(context.batteryLevel * 100))%"
        default: return nil
        }
    }

    private static func expandWiFiVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        switch name {
        case "ssid": return context.wifiSSID
        case "band_icon":
            guard let band = context.wifiBand else { return nil }
            switch band {
            case "band2_4": return config.wifi.bandIcon2_4
            case "band5": return config.wifi.bandIcon5
            case "band6": return config.wifi.bandIcon6
            default: return nil
            }
        case "ap_name": return context.wifiAPName
        default: return nil
        }
    }

    private static func expandNetworkVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        switch name {
        case "ip":
            return config.network.showIP ? context.networkIP : nil
        case "isp": return context.networkISP
        case "country_flag": return context.networkCountryFlag
        case "type": return context.networkType
        default: return nil
        }
    }

    private static func expandConnectionTypeVar(_ name: String, config: PromptConfig, context: PromptEvalContext) -> String? {
        switch name {
        case "type": return context.connectionType
        case "symbol":
            switch context.connectionType {
            case "wifi": return config.connectionType.wifiSymbol
            case "cellular": return config.connectionType.cellularSymbol
            case "wired": return config.connectionType.wiredSymbol
            default: return config.connectionType.wifiSymbol
            }
        default: return nil
        }
    }

    // MARK: - Character Module

    private static func expandCharacter(
        config: PromptConfig,
        context: PromptEvalContext,
        currentBg: inout ColorSpec?
    ) -> String {
        // Close current segment with rounded right cap if active
        var output = closeSegment(currentBg: &currentBg, config: config)

        // No \r\n here — the format string's \n (handled by evaluateLiteral)
        // already provides the line break before $character.

        // Render the appropriate symbol
        let symbolFormat = context.commandSucceeded ? config.character.successSymbol : config.character.errorSymbol
        if let nodes = try? PromptFormatParser.parse(symbolFormat) {
            for node in nodes {
                output += evaluateNode(node, config: config, context: context, currentBg: &currentBg)
            }
        } else {
            // Fallback if symbol format is unparseable
            let color = context.commandSucceeded ? "#a6e3a1" : "#f38ba8"
            output += "\u{1b}[1m"  // bold
            output += ansiFromHex(color, isFg: true)
            output += "❯"
        }
        output += PromptStyle.ansiReset
        output += " "

        return output
    }

    // MARK: - Color Resolution

    private static func resolveColor(_ color: ColorSpec, config: PromptConfig, isFg: Bool) -> String {
        switch color {
        case .hex(let hex):
            return ansiFromHex(hex, isFg: isFg)

        case .named(let name):
            return ansiFromName(name, isFg: isFg)

        case .palette(let name):
            // Look up in active palette first
            if let paletteName = config.activePalette,
               let palette = config.palettes[paletteName],
               let hex = palette[name] {
                return ansiFromHex(hex, isFg: isFg)
            }
            // Try as direct hex
            if name.hasPrefix("#") {
                return ansiFromHex(name, isFg: isFg)
            }
            // Fall back to ANSI named color
            return ansiFromName(name, isFg: isFg)
        }
    }

    static func ansiFromHex(_ hex: String, isFg: Bool) -> String {
        guard let (r, g, b) = parseHex(hex) else { return "" }
        let code = isFg ? 38 : 48
        return "\u{1b}[\(code);2;\(r);\(g);\(b)m"
    }

    private static func parseHex(_ hex: String) -> (Int, Int, Int)? {
        var h = hex
        if h.hasPrefix("#") { h = String(h.dropFirst()) }

        // Handle 3-char hex (#RGB → #RRGGBB)
        if h.count == 3 {
            let chars = Array(h)
            h = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
        }

        guard h.count == 6, let val = UInt32(h, radix: 16) else { return nil }
        return (Int((val >> 16) & 0xFF), Int((val >> 8) & 0xFF), Int(val & 0xFF))
    }

    private static func ansiFromName(_ name: String, isFg: Bool) -> String {
        let base = isFg ? 30 : 40
        let bright = isFg ? 90 : 100

        switch name.lowercased() {
        case "black": return "\u{1b}[\(base)m"
        case "red": return "\u{1b}[\(base + 1)m"
        case "green": return "\u{1b}[\(base + 2)m"
        case "yellow": return "\u{1b}[\(base + 3)m"
        case "blue": return "\u{1b}[\(base + 4)m"
        case "magenta": return "\u{1b}[\(base + 5)m"
        case "cyan": return "\u{1b}[\(base + 6)m"
        case "white": return "\u{1b}[\(base + 7)m"
        case "bright-black": return "\u{1b}[\(bright)m"
        case "bright-red": return "\u{1b}[\(bright + 1)m"
        case "bright-green": return "\u{1b}[\(bright + 2)m"
        case "bright-yellow": return "\u{1b}[\(bright + 3)m"
        case "bright-blue": return "\u{1b}[\(bright + 4)m"
        case "bright-magenta": return "\u{1b}[\(bright + 5)m"
        case "bright-cyan": return "\u{1b}[\(bright + 6)m"
        case "bright-white": return "\u{1b}[\(bright + 7)m"
        default: return ""
        }
    }

    // MARK: - Style Application

    private static func applyStyle(_ style: PromptStyleSpec, config: PromptConfig) -> String {
        var codes: [String] = []

        if style.bold { codes.append("\u{1b}[1m") }
        if style.dimmed { codes.append("\u{1b}[2m") }
        if style.italic { codes.append("\u{1b}[3m") }
        if style.underline { codes.append("\u{1b}[4m") }

        if let fg = style.fg {
            codes.append(resolveColor(fg, config: config, isFg: true))
        }
        if let bg = style.bg {
            codes.append(resolveColor(bg, config: config, isFg: false))
        }

        return codes.joined()
    }

    // MARK: - Helpers

    private static func containsVariable(_ nodes: [FormatNode], named name: String) -> Bool {
        for node in nodes {
            switch node {
            case .variable(let n):
                if n == name { return true }
            case .styledGroup(let children, _):
                if containsVariable(children, named: name) { return true }
            case .literal:
                break
            }
        }
        return false
    }

    private static func calculateSecondLinePrefix(_ text: String) -> Int {
        // Find last line break using UTF-8 search to avoid Swift's grapheme clustering
        // (Swift treats \r\n as a single Character, so Character-based search for \n fails)
        let stripped = PromptStyle.stripANSI(text)
        let utf8 = Array(stripped.utf8)
        let lf: UInt8 = 0x0A  // \n

        // Find last \n in UTF-8 bytes
        if let lastLF = utf8.lastIndex(of: lf) {
            let afterLF = lastLF + 1
            if afterLF < utf8.count {
                let lastLineBytes = Array(utf8[afterLF...])
                // Convert back to string to measure it in display cells
                if let lastLine = String(bytes: lastLineBytes, encoding: .utf8) {
                    return DisplayWidth.width(of: lastLine)
                }
            }
            return 0  // \n is the last byte
        }
        // No line break — entire text is one line
        return DisplayWidth.width(of: stripped)
    }
}

#endif
