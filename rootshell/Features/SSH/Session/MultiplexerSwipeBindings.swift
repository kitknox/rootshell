//
//  MultiplexerSwipeBindings.swift
//  rootshell
//
//  Resolves tmux and zellij swipe bindings from remote discovery data.
//

import Foundation

enum MultiplexerDiscoveryMarkers {
    static func bindingsStart(_ nonce: String) -> String { "::BINDINGS_START_\(nonce)::" }
    static func bindingsEnd(_ nonce: String) -> String { "::BINDINGS_END_\(nonce)::" }
    static func tmuxPrefix(_ nonce: String) -> String { "::TMUX_PREFIX_\(nonce)::" }
    static func tmuxPrefix2(_ nonce: String) -> String { "::TMUX_PREFIX2_\(nonce)::" }
    static func tmuxRootKeys(_ nonce: String) -> String { "::TMUX_ROOT_KEYS_\(nonce)::" }
    static func tmuxPrefixKeys(_ nonce: String) -> String { "::TMUX_PREFIX_KEYS_\(nonce)::" }
    static func zellijConfigPathPrefix(_ nonce: String) -> String { "::CONFIG_PATH_\(nonce):" }
}

struct MultiplexerSwipeBindings: Sendable, Equatable {
    var tmuxNextWindow: [SequenceStep]?
    var tmuxPreviousWindow: [SequenceStep]?
    var tmuxNextSession: [SequenceStep]?
    var tmuxPreviousSession: [SequenceStep]?
    var zellijNextTab: [SequenceStep]?
    var zellijPreviousTab: [SequenceStep]?
    var tmuxDetachClient: [SequenceStep]?
    var zellijDetach: [SequenceStep]?

    init(
        tmuxNextWindow: [SequenceStep]? = nil,
        tmuxPreviousWindow: [SequenceStep]? = nil,
        tmuxNextSession: [SequenceStep]? = nil,
        tmuxPreviousSession: [SequenceStep]? = nil,
        zellijNextTab: [SequenceStep]? = nil,
        zellijPreviousTab: [SequenceStep]? = nil,
        tmuxDetachClient: [SequenceStep]? = nil,
        zellijDetach: [SequenceStep]? = nil
    ) {
        self.tmuxNextWindow = tmuxNextWindow
        self.tmuxPreviousWindow = tmuxPreviousWindow
        self.tmuxNextSession = tmuxNextSession
        self.tmuxPreviousSession = tmuxPreviousSession
        self.zellijNextTab = zellijNextTab
        self.zellijPreviousTab = zellijPreviousTab
        self.tmuxDetachClient = tmuxDetachClient
        self.zellijDetach = zellijDetach
    }

    var hasResolvedBindings: Bool {
        tmuxNextWindow != nil
            || tmuxPreviousWindow != nil
            || tmuxNextSession != nil
            || tmuxPreviousSession != nil
            || zellijNextTab != nil
            || zellijPreviousTab != nil
            || tmuxDetachClient != nil
            || zellijDetach != nil
    }

    func sequence(for preset: SwipeGesturePreset) -> [SequenceStep]? {
        switch preset {
        case .tmuxNextWindow:
            return tmuxNextWindow
        case .tmuxPreviousWindow:
            return tmuxPreviousWindow
        case .tmuxNextSession:
            return tmuxNextSession
        case .tmuxPreviousSession:
            return tmuxPreviousSession
        case .zellijNextTab:
            return zellijNextTab
        case .zellijPreviousTab:
            return zellijPreviousTab
        default:
            return nil
        }
    }

    func merging(_ other: MultiplexerSwipeBindings) -> MultiplexerSwipeBindings {
        MultiplexerSwipeBindings(
            tmuxNextWindow: other.tmuxNextWindow ?? tmuxNextWindow,
            tmuxPreviousWindow: other.tmuxPreviousWindow ?? tmuxPreviousWindow,
            tmuxNextSession: other.tmuxNextSession ?? tmuxNextSession,
            tmuxPreviousSession: other.tmuxPreviousSession ?? tmuxPreviousSession,
            zellijNextTab: other.zellijNextTab ?? zellijNextTab,
            zellijPreviousTab: other.zellijPreviousTab ?? zellijPreviousTab,
            tmuxDetachClient: other.tmuxDetachClient ?? tmuxDetachClient,
            zellijDetach: other.zellijDetach ?? zellijDetach
        )
    }
}

enum TmuxSwipeBindingParser {

    private enum TmuxAction {
        case nextWindow
        case previousWindow
        case nextSession
        case previousSession
        case detachClient
    }

    private struct BindingLine {
        let keyToken: String
        let commandTokens: [String]

        init?(rawLine: String) {
            let tokens = ShellTokenParser.split(rawLine)
            guard !tokens.isEmpty else { return nil }

            let command = tokens[0]
            guard command == "bind-key" || command == "bind" else { return nil }

            var index = 1
            while index < tokens.count {
                let token = tokens[index]
                if !token.hasPrefix("-") || token == "-" {
                    break
                }

                if token == "-T" || token == "-N" {
                    index += 2
                    continue
                }

                if token.contains("T") || token.contains("N") {
                    index += 2
                    continue
                }

                index += 1
            }

            guard index < tokens.count else { return nil }
            keyToken = tokens[index]
            commandTokens = Array(tokens[(index + 1)...])
        }

        func matches(_ action: TmuxAction) -> Bool {
            guard let separatorIndex = commandTokens.firstIndex(where: { $0 == ";" || $0 == "\\;" }) else {
                return matchesCommandTokens(commandTokens, action: action)
            }
            return matchesCommandTokens(Array(commandTokens[..<separatorIndex]), action: action)
        }

        private func matchesCommandTokens(_ tokens: [String], action: TmuxAction) -> Bool {
            guard let command = tokens.first else { return false }
            switch action {
            case .nextWindow:
                return command == "next-window" || command == "next"
            case .previousWindow:
                return command == "previous-window" || command == "prev"
            case .nextSession, .previousSession:
                guard command == "switch-client" || command == "switchc" else { return false }
                let flags = Set(tokens.dropFirst())
                switch action {
                case .nextSession:
                    return flags.contains("-n")
                case .previousSession:
                    return flags.contains("-p")
                default:
                    return false
                }
            case .detachClient:
                guard command == "detach-client" || command == "detach" else { return false }
                return !tokens.dropFirst().contains("-a")
            }
        }
    }

    static func parse(output: String, nonce: String) -> MultiplexerSwipeBindings {
        guard let bindingsBlock = block(
            in: output,
            startMarker: MultiplexerDiscoveryMarkers.bindingsStart(nonce),
            endMarker: MultiplexerDiscoveryMarkers.bindingsEnd(nonce)
        ) else {
            return MultiplexerSwipeBindings()
        }

        var prefixTokens: [String] = []
        var rootLines: [String] = []
        var prefixLines: [String] = []

        enum Section {
            case none
            case prefix
            case prefix2
            case rootKeys
            case prefixKeys
        }

        var section: Section = .none
        for rawLine in bindingsBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            switch line {
            case MultiplexerDiscoveryMarkers.tmuxPrefix(nonce):
                section = .prefix
                continue
            case MultiplexerDiscoveryMarkers.tmuxPrefix2(nonce):
                section = .prefix2
                continue
            case MultiplexerDiscoveryMarkers.tmuxRootKeys(nonce):
                section = .rootKeys
                continue
            case MultiplexerDiscoveryMarkers.tmuxPrefixKeys(nonce):
                section = .prefixKeys
                continue
            default:
                break
            }

            guard !line.isEmpty else { continue }
            switch section {
            case .prefix, .prefix2:
                prefixTokens.append(line)
            case .rootKeys:
                rootLines.append(line)
            case .prefixKeys:
                prefixLines.append(line)
            case .none:
                break
            }
        }

        let rootBindings = rootLines.compactMap { BindingLine(rawLine: $0) }
        let prefixBindings = prefixLines.compactMap { BindingLine(rawLine: $0) }
        let prefixCombos = prefixTokens.compactMap(parseTmuxKeyToken)

        return MultiplexerSwipeBindings(
            tmuxNextWindow: resolve(action: .nextWindow, rootBindings: rootBindings, prefixBindings: prefixBindings, prefixes: prefixCombos),
            tmuxPreviousWindow: resolve(action: .previousWindow, rootBindings: rootBindings, prefixBindings: prefixBindings, prefixes: prefixCombos),
            tmuxNextSession: resolve(action: .nextSession, rootBindings: rootBindings, prefixBindings: prefixBindings, prefixes: prefixCombos),
            tmuxPreviousSession: resolve(action: .previousSession, rootBindings: rootBindings, prefixBindings: prefixBindings, prefixes: prefixCombos),
            tmuxDetachClient: resolve(action: .detachClient, rootBindings: rootBindings, prefixBindings: prefixBindings, prefixes: prefixCombos)
        )
    }

    private static func resolve(
        action: TmuxAction,
        rootBindings: [BindingLine],
        prefixBindings: [BindingLine],
        prefixes: [SequenceStep.KeyCombo]
    ) -> [SequenceStep]? {
        if let direct = rootBindings.first(where: { $0.matches(action) }),
           let combo = parseTmuxKeyToken(direct.keyToken) {
            return [.keyCombo(combo)]
        }

        guard let prefix = prefixes.first,
              let binding = prefixBindings.first(where: { $0.matches(action) }),
              let combo = parseTmuxKeyToken(binding.keyToken) else {
            return nil
        }

        return [.keyCombo(prefix), .keyCombo(combo)]
    }

    private static func block(in text: String, startMarker: String, endMarker: String) -> String? {
        guard let start = text.range(of: startMarker) else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.range(of: endMarker) else {
            return String(tail)
        }
        return String(tail[..<end.lowerBound])
    }

    private nonisolated static func parseTmuxKeyToken(_ token: String) -> SequenceStep.KeyCombo? {
        var modifiers: Set<SequenceStep.KeyModifier> = []
        var remainder = token

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            if remainder.hasPrefix("C-") {
                modifiers.insert(.ctrl)
                remainder.removeFirst(2)
                didStripPrefix = true
            } else if remainder.hasPrefix("M-") {
                modifiers.insert(.alt)
                remainder.removeFirst(2)
                didStripPrefix = true
            } else if remainder.hasPrefix("S-") {
                modifiers.insert(.shift)
                remainder.removeFirst(2)
                didStripPrefix = true
            }
        }

        if remainder.caseInsensitiveCompare("none") == .orderedSame || remainder.isEmpty {
            return nil
        }

        let lowered = remainder.lowercased()
        let key: SequenceStep.ComboKey?
        switch lowered {
        case "space":
            key = .special(.space)
        case "enter":
            key = .special(.returnKey)
        case "tab":
            key = .special(.tab)
        case "escape", "esc":
            key = .special(.escape)
        case "bspace", "backspace":
            key = .special(.backspace)
        case "delete", "dc":
            key = .special(.delete)
        case "up":
            key = .special(.arrowUp)
        case "down":
            key = .special(.arrowDown)
        case "left":
            key = .special(.arrowLeft)
        case "right":
            key = .special(.arrowRight)
        case "home":
            key = .special(.home)
        case "end":
            key = .special(.end)
        case "pageup":
            key = .special(.pageUp)
        case "pagedown":
            key = .special(.pageDown)
        default:
            if remainder.count == 1, let character = remainder.first {
                if character.isLetter {
                    if character.isUppercase {
                        modifiers.insert(.shift)
                    }
                    key = .letter(normalizedLowercaseCharacter(character))
                } else if character.isNumber {
                    key = .digit(character)
                } else {
                    key = .symbol(character)
                }
            } else {
                key = nil
            }
        }

        guard let key else { return nil }
        return SequenceStep.KeyCombo(modifiers: modifiers, key: key)
    }
}

enum ZellijSwipeBindingParser {

    private enum Mode: String, CaseIterable {
        case normal
        case tab
        case session
    }

    private struct Semantic {
        var entersTabMode = false
        var exitsToNormal = false
        var goesToNextTab = false
        var goesToPreviousTab = false
        var entersSessionMode = false
        var detaches = false

        var isRelevant: Bool {
            entersTabMode || exitsToNormal || goesToNextTab || goesToPreviousTab
                || entersSessionMode || detaches
        }
    }

    private struct Entry {
        let combo: SequenceStep.KeyCombo?
        let semantic: Semantic
    }

    private struct ModeBindings {
        var order: [String] = []
        var entries: [String: Entry] = [:]

        mutating func clear() {
            order.removeAll(keepingCapacity: false)
            entries.removeAll(keepingCapacity: false)
        }

        mutating func bind(key: String, entry: Entry) {
            if entries[key] == nil {
                order.append(key)
            }
            entries[key] = entry
        }

        mutating func unbind(key: String) {
            entries.removeValue(forKey: key)
        }

        func firstMatchingCombo(where predicate: (Semantic) -> Bool) -> SequenceStep.KeyCombo? {
            for key in order {
                guard let entry = entries[key], entry.combo != nil else { continue }
                if predicate(entry.semantic) {
                    return entry.combo
                }
            }
            return nil
        }

        func matchingCombos(where predicate: (Semantic) -> Bool) -> [SequenceStep.KeyCombo] {
            var combos: [SequenceStep.KeyCombo] = []
            for key in order {
                guard let entry = entries[key], let combo = entry.combo else { continue }
                if predicate(entry.semantic) {
                    combos.append(combo)
                }
            }
            return combos
        }

        func semantic(for combo: SequenceStep.KeyCombo) -> Semantic? {
            entries.values.first(where: { $0.combo == combo })?.semantic
        }
    }

    private struct State {
        var modes: [Mode: ModeBindings] = [:]

        init(loadDefaults: Bool = true) {
            for mode in Mode.allCases {
                modes[mode] = ModeBindings()
            }
            if loadDefaults {
                applyDefaultBindings()
            }
        }

        mutating func applyDefaultBindings() {
            bind(keys: ["Ctrl t"], semantic: Semantic(entersTabMode: true), to: [.normal])
            bind(keys: ["Ctrl t", "Enter", "Esc"], semantic: Semantic(exitsToNormal: true), to: [.tab])
            bind(keys: ["h", "Left", "Up", "k"], semantic: Semantic(goesToPreviousTab: true), to: [.tab])
            bind(keys: ["l", "Right", "Down", "j"], semantic: Semantic(goesToNextTab: true), to: [.tab])
            bind(keys: ["Ctrl o"], semantic: Semantic(entersSessionMode: true), to: [.normal])
            bind(keys: ["d"], semantic: Semantic(detaches: true), to: [.session])
        }

        mutating func clear(_ targetModes: Set<Mode>) {
            for mode in targetModes {
                modes[mode]?.clear()
            }
        }

        mutating func bind(keys: [String], semantic: Semantic, to targetModes: Set<Mode>) {
            for key in keys {
                let normalized = normalizeKey(key)
                let entry = Entry(combo: parseKeyCombo(key), semantic: semantic)
                for mode in targetModes {
                    modes[mode]?.bind(key: normalized, entry: entry)
                }
            }
        }

        mutating func unbind(keys: [String], from targetModes: Set<Mode>) {
            for key in keys {
                let normalized = normalizeKey(key)
                for mode in targetModes {
                    modes[mode]?.unbind(key: normalized)
                }
            }
        }
    }

    static func parse(output: String, nonce: String) -> MultiplexerSwipeBindings {
        var state = State(loadDefaults: true)

        if let configText = extractConfigText(from: output, nonce: nonce),
           let keybinds = extractNamedBlock("keybinds", from: configText) {
            if keybinds.header.lowercased().contains("clear-defaults=true") {
                state = State(loadDefaults: false)
            }
            parseStatements(in: keybinds.body, state: &state, currentModes: nil)
        }

        let nextTab = resolveTabSequence(in: state, next: true)
        let previousTab = resolveTabSequence(in: state, next: false)
        let detach = resolveDetachSequence(in: state)

        return MultiplexerSwipeBindings(
            zellijNextTab: nextTab,
            zellijPreviousTab: previousTab,
            zellijDetach: detach
        )
    }

    private static func resolveTabSequence(in state: State, next: Bool) -> [SequenceStep]? {
        let normalBindings = state.modes[.normal] ?? ModeBindings()
        let tabBindings = state.modes[.tab] ?? ModeBindings()

        let direct = normalBindings.firstMatchingCombo { semantic in
            next ? semantic.goesToNextTab : semantic.goesToPreviousTab
        }
        if let direct {
            return [.keyCombo(direct)]
        }

        guard let enterTab = normalBindings.firstMatchingCombo(where: { $0.entersTabMode }),
              let action = tabBindings.firstMatchingCombo(where: { next ? $0.goesToNextTab : $0.goesToPreviousTab }) else {
            return nil
        }

        var steps: [SequenceStep] = [.keyCombo(enterTab), .keyCombo(action)]
        let actionExits = tabBindings.semantic(for: action)?.exitsToNormal ?? false
        if !actionExits,
           let exit = preferredExitCombo(in: tabBindings) {
            steps.append(.keyCombo(exit))
        }
        return steps
    }

    private static func resolveDetachSequence(in state: State) -> [SequenceStep]? {
        let normalBindings = state.modes[.normal] ?? ModeBindings()
        let sessionBindings = state.modes[.session] ?? ModeBindings()

        if let direct = normalBindings.firstMatchingCombo(where: { $0.detaches }) {
            return [.keyCombo(direct)]
        }

        guard let enterSession = normalBindings.firstMatchingCombo(where: { $0.entersSessionMode }),
              let action = sessionBindings.firstMatchingCombo(where: { $0.detaches }) else {
            return nil
        }
        return [.keyCombo(enterSession), .keyCombo(action)]
    }

    private static func preferredExitCombo(in bindings: ModeBindings) -> SequenceStep.KeyCombo? {
        let allExits = bindings.matchingCombos(where: { $0.exitsToNormal })
        if let escape = allExits.first(where: isPlainEscape) {
            return escape
        }
        return allExits.first
    }

    private static func extractConfigText(from output: String, nonce: String) -> String? {
        guard let bindingsBlock = block(
            in: output,
            startMarker: MultiplexerDiscoveryMarkers.bindingsStart(nonce),
            endMarker: MultiplexerDiscoveryMarkers.bindingsEnd(nonce)
        ) else {
            return nil
        }

        let configPrefix = MultiplexerDiscoveryMarkers.zellijConfigPathPrefix(nonce)
        guard let configMarker = bindingsBlock.range(of: configPrefix) else {
            return nil
        }
        let tail = bindingsBlock[configMarker.upperBound...]
        guard let markerEnd = tail.range(of: "::\n") ?? tail.range(of: "::\r\n") else {
            return nil
        }
        return String(tail[markerEnd.upperBound...])
    }

    private static func block(in text: String, startMarker: String, endMarker: String) -> String? {
        guard let start = text.range(of: startMarker) else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.range(of: endMarker) else {
            return String(tail)
        }
        return String(tail[..<end.lowerBound])
    }

    private static func extractNamedBlock(_ name: String, from text: String) -> (header: String, body: String)? {
        var scanner = KDLScanner(text: text)
        while let item = scanner.nextItem() {
            guard item.identifier == name else { continue }
            return (item.header, item.body)
        }
        return nil
    }

    private static func parseStatements(in text: String, state: inout State, currentModes: Set<Mode>?) {
        var scanner = KDLScanner(text: text)
        while let item = scanner.nextItem() {
            switch item.identifier.lowercased() {
            case "bind":
                guard let currentModes else { continue }
                let keys = quotedStrings(in: item.header)
                let semantic = semantic(from: item.body)
                state.bind(keys: keys, semantic: semantic, to: currentModes)
            case "unbind":
                guard let currentModes else { continue }
                let keys = quotedStrings(in: item.header)
                state.unbind(keys: keys, from: currentModes)
            default:
                let targetModes = targetModes(for: item.identifier, header: item.header)
                guard !targetModes.isEmpty else { continue }
                if item.header.lowercased().contains("clear-defaults=true") {
                    state.clear(targetModes)
                }
                parseStatements(in: item.body, state: &state, currentModes: targetModes)
            }
        }
    }

    private static func targetModes(for identifier: String, header: String) -> Set<Mode> {
        switch identifier.lowercased() {
        case Mode.normal.rawValue:
            return [.normal]
        case Mode.tab.rawValue:
            return [.tab]
        case Mode.session.rawValue:
            return [.session]
        case "shared":
            return Set(Mode.allCases)
        case "shared_except":
            let excluded = Set(quotedStrings(in: header).compactMap { Mode(rawValue: $0.lowercased()) })
            return Set(Mode.allCases).subtracting(excluded)
        case "shared_among":
            return Set(quotedStrings(in: header).compactMap { Mode(rawValue: $0.lowercased()) })
        default:
            return []
        }
    }

    private static func semantic(from actionBlock: String) -> Semantic {
        let compact = actionBlock.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()

        return Semantic(
            entersTabMode: compact.contains("switchtomode\"tab\""),
            exitsToNormal: compact.contains("switchtomode\"normal\""),
            goesToNextTab: compact.contains("gotonexttab"),
            goesToPreviousTab: compact.contains("gotoprevioustab"),
            entersSessionMode: compact.contains("switchtomode\"session\""),
            detaches: compact.contains("detach")
        )
    }

    private static func normalizeKey(_ raw: String) -> String {
        if let combo = parseKeyCombo(raw) {
            let modifiers = SequenceStep.KeyModifier.allCases
                .filter { combo.modifiers.contains($0) }
                .map(\.rawValue)
                .joined(separator: "+")
            let key: String
            switch combo.key {
            case .letter(let character):
                key = "letter:\(character)"
            case .digit(let character):
                key = "digit:\(character)"
            case .symbol(let character):
                key = "symbol:\(character)"
            case .special(let special):
                key = "special:\(special.rawValue)"
            }
            return modifiers.isEmpty ? key : "\(modifiers)|\(key)"
        }

        return raw
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func parseKeyCombo(_ raw: String) -> SequenceStep.KeyCombo? {
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        var modifiers: Set<SequenceStep.KeyModifier> = []
        var keyToken: String?

        for token in tokens {
            switch token.lowercased() {
            case "ctrl", "control":
                modifiers.insert(.ctrl)
            case "alt", "option":
                modifiers.insert(.alt)
            case "shift":
                modifiers.insert(.shift)
            default:
                keyToken = token
            }
        }

        guard let keyToken else { return nil }
        let lowered = keyToken.lowercased()
        let key: SequenceStep.ComboKey?
        switch lowered {
        case "esc", "escape":
            key = .special(.escape)
        case "enter", "return":
            key = .special(.returnKey)
        case "tab":
            key = .special(.tab)
        case "space":
            key = .special(.space)
        case "backspace":
            key = .special(.backspace)
        case "delete":
            key = .special(.delete)
        case "left":
            key = .special(.arrowLeft)
        case "right":
            key = .special(.arrowRight)
        case "up":
            key = .special(.arrowUp)
        case "down":
            key = .special(.arrowDown)
        case "home":
            key = .special(.home)
        case "end":
            key = .special(.end)
        case "pageup":
            key = .special(.pageUp)
        case "pagedown":
            key = .special(.pageDown)
        default:
            if keyToken.count == 1, let character = keyToken.first {
                if character.isLetter {
                    if character.isUppercase {
                        modifiers.insert(.shift)
                    }
                    key = .letter(normalizedLowercaseCharacter(character))
                } else if character.isNumber {
                    key = .digit(character)
                } else {
                    key = .symbol(character)
                }
            } else {
                key = nil
            }
        }

        guard let key else { return nil }
        return SequenceStep.KeyCombo(modifiers: modifiers, key: key)
    }

    private static func quotedStrings(in text: String) -> [String] {
        var results: [String] = []
        var scanner = text.startIndex

        while scanner < text.endIndex {
            if text[scanner] == "\"" {
                let start = text.index(after: scanner)
                var index = start
                var escaped = false
                while index < text.endIndex {
                    let character = text[index]
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        results.append(String(text[start..<index]))
                        scanner = text.index(after: index)
                        break
                    }
                    index = text.index(after: index)
                }
                if index == text.endIndex {
                    break
                }
                continue
            }
            scanner = text.index(after: scanner)
        }

        return results
    }
}

private nonisolated func normalizedLowercaseCharacter(_ character: Character) -> Character {
    character.lowercased().first.map(Character.init) ?? character
}

private func isPlainEscape(_ combo: SequenceStep.KeyCombo) -> Bool {
    combo.modifiers.isEmpty && combo.key == .special(.escape)
}

private enum ShellTokenParser {
    static func split(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                escaped = true
                continue
            }

            if let currentQuote = quote {
                if character == currentQuote {
                    self.finish(token: &current, into: &tokens)
                } else {
                    current.append(character)
                }
                if character == currentQuote {
                    quote = nil
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                self.finish(token: &current, into: &tokens)
                continue
            }

            current.append(character)
        }

        finish(token: &current, into: &tokens)
        return tokens
    }

    private static func finish(token: inout String, into tokens: inout [String]) {
        guard !token.isEmpty else { return }
        tokens.append(token)
        token.removeAll(keepingCapacity: true)
    }
}

private struct KDLScanner {
    struct Item {
        let identifier: String
        let header: String
        let body: String
    }

    let text: String
    var index: String.Index

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func nextItem() -> Item? {
        while true {
            skipWhitespaceAndComments()
            guard index < text.endIndex else { return nil }
            guard let identifier = readIdentifier() else {
                advance()
                continue
            }
            skipWhitespaceAndComments()
            let headerStart = index
            let parseResult = parseHeaderAndBody(startingAt: headerStart)
            return Item(identifier: identifier, header: parseResult.header, body: parseResult.body)
        }
    }

    private mutating func skipWhitespaceAndComments() {
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                advance()
                continue
            }

            if character == "/", text.index(after: index) < text.endIndex, text[text.index(after: index)] == "/" {
                while index < text.endIndex, text[index] != "\n" {
                    advance()
                }
                continue
            }
            break
        }
    }

    private mutating func readIdentifier() -> String? {
        guard index < text.endIndex else { return nil }
        guard text[index].isLetter || text[index] == "_" else { return nil }

        let start = index
        advance()
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber || character == "_" || character == "-" {
                advance()
            } else {
                break
            }
        }
        return String(text[start..<index])
    }

    private mutating func parseHeaderAndBody(startingAt headerStart: String.Index) -> (header: String, body: String) {
        var probe = index
        var quote: Character?
        var escaped = false

        while probe < text.endIndex {
            let character = text[probe]

            if escaped {
                escaped = false
                probe = text.index(after: probe)
                continue
            }

            if character == "\\" {
                escaped = true
                probe = text.index(after: probe)
                continue
            }

            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
                probe = text.index(after: probe)
                continue
            }

            if character == "\"" {
                quote = character
                probe = text.index(after: probe)
                continue
            }

            if character == "/", text.index(after: probe) < text.endIndex, text[text.index(after: probe)] == "/" {
                while probe < text.endIndex, text[probe] != "\n" {
                    probe = text.index(after: probe)
                }
                continue
            }

            if character == "{" {
                let header = String(text[headerStart..<probe])
                var nestedScanner = self
                nestedScanner.index = probe
                let body = nestedScanner.readBalancedBlock()
                self.index = nestedScanner.index
                return (header, body)
            }

            if character == "\n" || character == ";" {
                let header = String(text[headerStart..<probe])
                self.index = text.index(after: probe)
                return (header, "")
            }

            probe = text.index(after: probe)
        }

        self.index = text.endIndex
        return (String(text[headerStart...]), "")
    }

    private mutating func readBalancedBlock() -> String {
        guard index < text.endIndex, text[index] == "{" else { return "" }

        let start = text.index(after: index)
        var probe = start
        var depth = 1
        var quote: Character?
        var escaped = false

        while probe < text.endIndex {
            let character = text[probe]

            if escaped {
                escaped = false
                probe = text.index(after: probe)
                continue
            }

            if character == "\\" {
                escaped = true
                probe = text.index(after: probe)
                continue
            }

            if let currentQuote = quote {
                if character == currentQuote {
                    quote = nil
                }
                probe = text.index(after: probe)
                continue
            }

            if character == "\"" {
                quote = character
                probe = text.index(after: probe)
                continue
            }

            if character == "/", text.index(after: probe) < text.endIndex, text[text.index(after: probe)] == "/" {
                while probe < text.endIndex, text[probe] != "\n" {
                    probe = text.index(after: probe)
                }
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let body = String(text[start..<probe])
                    index = text.index(after: probe)
                    return body
                }
            }

            probe = text.index(after: probe)
        }

        index = text.endIndex
        return String(text[start...])
    }

    private mutating func advance() {
        index = text.index(after: index)
    }
}
