import Foundation

/// State which the existing screen-dump APIs deliberately do not include.
/// Observes server bytes only; saved screen paints and connection animations
/// must never be interpreted as fresh application negotiation.
nonisolated struct TerminalProtocolState: Codable, Equatable {
    struct Keyboard: Codable, Equatable {
        var flags = Array(repeating: 0, count: 8)
        var index = 0
        mutating func push(_ value: Int) { index = (index + 1) % 8; flags[index] = value & 31 }
        mutating func pop(_ count: Int) {
            if count >= 8 { self = Keyboard(); return }
            for _ in 0..<max(0, count) { flags[index] = 0; index = (index + 7) % 8 }
        }
        func replay() -> String {
            "\u{1b}[<8u" + (1...8).map { "\u{1b}[>\(flags[(index + $0) % 8])u" }.joined()
        }
    }
    var primaryKeyboard = Keyboard()
    var alternateKeyboard = Keyboard()
    var alternate = false
    var modes: [String: Bool] = [:]
    var savedModes: [String: Bool] = [:]
    var margins = "\u{1b}[r"
    var horizontalMargins = ""
    var cursorStyle = "\u{1b}[0 q"
    var modifyOtherKeys = 0
    var charsets: [String: String] = [:]
    var shift = "\u{0f}"
    // SGR operations are compacted by attribute, rather than retaining output.
    var attributes: [Int: String] = [:]
    struct SavedPen: Codable, Equatable {
        let attributes: [Int: String]
        let charsets: [String: String]
        let shift: String
        let origin: Bool
        var serial: UInt64?
        var row: Int?
        var col: Int?
    }
    var cursorSaveSerial: UInt64?
    var primarySavedPen: SavedPen?
    var alternateSavedPen: SavedPen?

    mutating func savePen() {
        cursorSaveSerial = (cursorSaveSerial ?? 0) &+ 1
        let pen = SavedPen(attributes: attributes, charsets: charsets, shift: shift,
                           origin: modes["?6"] ?? false, serial: cursorSaveSerial)
        if alternate { alternateSavedPen = pen } else { primarySavedPen = pen }
    }

    /// Recreate a screen's DECSC slot without relying on the viewport cursor.
    /// Full margins allow saving an absolute position even when it is outside
    /// the currently active scrolling region. settingsReplay restores margins.
    static func savedCursorReplay(_ pen: SavedPen?) -> Data {
        guard let pen, let row = pen.row, let col = pen.col else { return Data() }
        var text = "\u{1b}[?6l\u{1b}[?69l\u{1b}[r\u{1b}[0m\u{1b}(B\u{1b})B\u{1b}*B\u{1b}+B"
        for key in pen.charsets.keys.sorted() { text += pen.charsets[key]! }
        text += pen.shift
        for key in pen.attributes.keys.sorted() { text += "\u{1b}[\(pen.attributes[key]!)m" }
        if pen.origin { text += "\u{1b}[?6h" }
        text += "\u{1b}[\(row);\(col)H\u{1b}7"
        return Data(text.utf8)
    }
    mutating func restorePen() {
        guard let pen = alternate ? alternateSavedPen : primarySavedPen else { return }
        attributes = pen.attributes; charsets = pen.charsets; shift = pen.shift; modes["?6"] = pen.origin
    }
    private static let supportedModes: Set<String> = Set([2, 4, 12, 20].map(String.init)
        + [1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 67, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2033, 2048, 5522].map { "?\($0)" })

    mutating func csi(_ body: String, final: UInt8) {
        let prefix = body.first.map { "?<>=!".contains($0) ? String($0) : "" } ?? ""
        let raw = prefix.isEmpty ? body : String(body.dropFirst())
        let values = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = values.first ?? 0
        if final == 0x75, [">", "<", "="].contains(prefix) {
            var keyboard = alternate ? alternateKeyboard : primaryKeyboard
            if prefix == ">" { keyboard.push(first) }
            if prefix == "<" { keyboard.pop(first == 0 ? 1 : first) }
            if prefix == "=" {
                let action = values.count > 1 ? values[1] : 1
                switch action {
                case 2: keyboard.flags[keyboard.index] |= first & 31
                case 3: keyboard.flags[keyboard.index] &= ~(first & 31)
                default: keyboard.flags[keyboard.index] = first & 31
                }
            }
            if alternate { alternateKeyboard = keyboard } else { primaryKeyboard = keyboard }
            return
        }
        if prefix == ">", final == 0x6d, first == 4 {
            modifyOtherKeys = values.count > 1 ? values[1] : 0
            return
        }
        if [0x68, 0x6c, 0x73, 0x72].contains(final), prefix == "?" || prefix.isEmpty {
            // Plain CSI r and s are margins/cursor operations, not mode saves.
            if prefix.isEmpty, final == 0x72 { margins = "\u{1b}[\(body)r"; return }
            if prefix.isEmpty, final == 0x73 {
                if modes["?69"] == true { horizontalMargins = "\u{1b}[\(body)s" }
                else { savePen() }
                return
            }
            for value in values where value > 0 {
                let key = prefix + String(value)
                guard Self.supportedModes.contains(key) else { continue }
                if final == 0x73 { savedModes[key] = modes[key] ?? Self.defaultMode(key); continue }
                let enabled = final == 0x72 ? (savedModes[key] ?? Self.defaultMode(key)) : final == 0x68
                if prefix == "?", [47, 1047, 1049].contains(value) {
                    if value == 1049, enabled { savePen() }
                    alternate = enabled
                    if value == 1049, !enabled { restorePen() }
                } else if key == "?1048" {
                    if enabled { savePen() } else { restorePen() }
                } else if key != "?1048", key != "?3", key != "?2026" {
                    // These switches change screens, save cursor, resize or
                    // freeze rendering. Replaying them as modes has side effects.
                    modes[key] = enabled
                    if prefix == "?" {
                        for group in [[9, 1000, 1002, 1003], [1005, 1006, 1015, 1016]] where group.contains(value) {
                            for other in group { modes["?\(other)"] = enabled && other == value }
                        }
                    }
                }
            }
            return
        }
        if final == 0x71, body.hasSuffix(" ") { cursorStyle = "\u{1b}[\(body)q" }
        if final == 0x75, prefix.isEmpty { restorePen() }
        if final == 0x6d, prefix.isEmpty { sgr(raw) }
        if final == 0x70, body == "!" {
            // DECSTR preserves screen contents and Kitty negotiation.
            modes = [:]; margins = "\u{1b}[r"; horizontalMargins = ""
            attributes = [:]; charsets = [:]; shift = "\u{0f}"; modifyOtherKeys = 0
        }
    }

    private mutating func sgr(_ raw: String) {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < parts.count {
            let code = Int(parts[i].split(separator: ":", omittingEmptySubsequences: false).first ?? "") ?? 0
            var operation = parts[i]
            if [38, 48, 58].contains(code), !operation.contains(":"), i + 1 < parts.count {
                let length = parts[i + 1] == "2" ? 5 : (parts[i + 1] == "5" ? 3 : 1)
                let end = min(parts.count, i + length)
                operation = parts[i..<end].joined(separator: ";"); i = end - 1
            }
            switch code {
            case 0: attributes = [:]
            case 1, 2: attributes[code] = operation
            case 22: attributes.removeValue(forKey: 1); attributes.removeValue(forKey: 2)
            case 3, 20, 23: attributes[3] = operation
            case 4, 21, 24: attributes[4] = operation
            case 5, 6, 25: attributes[5] = operation
            case 7, 27: attributes[7] = operation
            case 8, 28: attributes[8] = operation
            case 9, 29: attributes[9] = operation
            case 30...39, 90...97: attributes[38] = operation
            case 40...49, 100...107: attributes[48] = operation
            case 58, 59: attributes[58] = operation
            case 53, 55: attributes[53] = operation
            default: break
            }
            i += 1
        }
    }

    static func defaultMode(_ key: String) -> Bool { ["12", "?7", "?25", "?1007", "?1035", "?1036"].contains(key) }

    func settingsReplay() -> Data {
        // RIS supplies configured defaults. Only restore switches actually
        // observed, rather than guessing which modes a full-screen app uses.
        var all = modes
        var text = ""
        let sideEffects: Set<String> = ["?3", "?40", "?47", "?1047", "?1048", "?1049", "?2026"]
        for key in savedModes.keys.sorted() where !sideEffects.contains(key) {
            text += "\u{1b}[\(key)\(savedModes[key]! ? "h" : "l")\u{1b}[\(key)s"
            if all[key] == nil { all[key] = Self.defaultMode(key) }
        }
        // Mouse protocol aliases must be disabled before enabling the selected one.
        for enabled in [false, true] {
            for key in all.keys.sorted() where all[key] == enabled && !sideEffects.contains(key) {
                text += "\u{1b}[\(key)\(enabled ? "h" : "l")"
            }
        }
        text += margins + horizontalMargins
        text += "\u{1b}(B\u{1b})B\u{1b}*B\u{1b}+B"
        for key in charsets.keys.sorted() { text += charsets[key]! }
        text += shift + "\u{1b}[0m"
        for key in attributes.keys.sorted() { text += "\u{1b}[\(attributes[key]!)m" }
        text += "\u{1b}[>4;\(modifyOtherKeys)m" + cursorStyle + "\u{1b}[?2026l"
        return Data(text.utf8)
    }
}

/// Incremental VT framing. OSC/DCS payloads are opaque: text inside them must
/// never be mistaken for keyboard negotiation. Buffers have a fixed bound.
nonisolated struct TerminalProtocolParser {
    enum Phase { case ground, escape, escapeIntermediate, csi, charset(UInt8), string(Bool), stringEscape(Bool) }
    var state = TerminalProtocolState()
    private var phase = Phase.ground
    private var token = [UInt8]()
    private var utf8Remaining = 0
    var atBoundary: Bool { if case .ground = phase { return utf8Remaining == 0 }; return false }
    mutating func consume(_ data: Data, onCursorSave: ((Int, TerminalProtocolState) -> Void)? = nil) {
        for (offset, byte) in data.enumerated() {
            let previousSave = state.cursorSaveSerial
            if byte == 0x18 || byte == 0x1a { phase = .ground; token = []; utf8Remaining = 0; continue }
            switch phase {
            case .ground:
                if byte == 0x1b { phase = .escape; utf8Remaining = 0 }
                else if byte == 0x0e { state.shift = "\u{0e}" }
                else if byte == 0x0f { state.shift = "\u{0f}" }
                else if byte >= 0xc2 && byte <= 0xf4 { utf8Remaining = byte < 0xe0 ? 1 : (byte < 0xf0 ? 2 : 3) }
                else if byte >= 0x80 && byte <= 0xbf { utf8Remaining = max(0, utf8Remaining - 1) }
                else { utf8Remaining = 0 }
            case .escape:
                token = []
                switch byte {
                case 0x5b: phase = .csi
                case 0x5d: phase = .string(true)
                case 0x50, 0x58, 0x5e, 0x5f: phase = .string(false)
                case 0x28...0x2b: phase = .charset(byte)
                case 0x63: state = TerminalProtocolState(); phase = .ground
                case 0x37: state.savePen(); phase = .ground
                case 0x38: state.restorePen(); phase = .ground
                case 0x3d: state.modes["?66"] = true; phase = .ground
                case 0x3e: state.modes["?66"] = false; phase = .ground
                case 0x1b: phase = .escape
                case 0x20...0x2f: phase = .escapeIntermediate
                case 0x00...0x1f, 0x7f: break // C0/DEL don't finish an escape.
                default: phase = .ground
                }
            case .escapeIntermediate:
                if byte == 0x1b { phase = .escape }
                else if (0x30...0x7e).contains(byte) { phase = .ground }
            case .csi:
                if byte == 0x1b { phase = .escape; token = [] }
                else if (0x40...0x7e).contains(byte) {
                    if token.count <= 512 { state.csi(String(decoding: token, as: UTF8.self), final: byte) }
                    token = []; phase = .ground
                } else if token.count <= 512 { token.append(byte) }
            case .charset(let slot):
                if byte == 0x1b { phase = .escape }
                else if (0x30...0x7e).contains(byte) {
                    state.charsets[String(slot)] = String(decoding: [0x1b, slot, byte], as: UTF8.self)
                    phase = .ground
                } else if (0x20...0x2f).contains(byte) { phase = .escapeIntermediate }
            case .string(let bell): if byte == 0x07 && bell { phase = .ground } else if byte == 0x1b { phase = .stringEscape(bell) }
            case .stringEscape(let bell): phase = byte == 0x5c ? .ground : (byte == 0x1b ? .stringEscape(bell) : .string(bell))
            }
            if state.cursorSaveSerial != previousSave, state.cursorSaveSerial != nil {
                onCursorSave?(offset + 1, state)
            }
        }
    }
}

nonisolated struct TerminalRestorationSnapshot: Codable {
    let version: Int
    let replay: Data
    let protocolState: TerminalProtocolState
    init(primary: Data, alternate: Data?, state: TerminalProtocolState) {
        version = 1; protocolState = state
        var bytes = Data("\u{1b}c".utf8) + primary + Data(state.primaryKeyboard.replay().utf8)
        bytes += TerminalProtocolState.savedCursorReplay(state.primarySavedPen)
        if state.alternate, let alternate {
            // 1049h would overwrite the primary DECSC slot just restored.
            bytes += Data("\u{1b}[?47h\u{1b}[?6l\u{1b}[?69l\u{1b}[r\u{1b}[0m".utf8)
                + alternate + Data(state.alternateKeyboard.replay().utf8)
            bytes += TerminalProtocolState.savedCursorReplay(state.alternateSavedPen)
        }
        bytes += state.settingsReplay()
        // Restoring margins/origin mode homes the cursor. Reapply the dumped
        // cursor using coordinates relative to the restored origin, without
        // DECRC (which would overwrite the pen, charset and origin mode).
        let viewport = String(decoding: state.alternate ? (alternate ?? primary) : primary, as: UTF8.self)
        if let start = viewport.range(of: "\u{1b}[", options: .backwards), viewport.hasSuffix("H") {
            let position = viewport[start.upperBound...].dropLast().split(separator: ";").compactMap { Int($0) }
            if position.count == 2 {
                let top = min(65535, max(1, Int(state.margins.dropFirst(2).dropLast().split(separator: ";").first ?? "1") ?? 1))
                let left = min(65535, max(1, Int(state.horizontalMargins.dropFirst(2).dropLast().split(separator: ";").first ?? "1") ?? 1))
                let origin = state.modes["?6"] == true
                let row = max(1, position[0] - (origin ? top - 1 : 0))
                let col = max(1, position[1] - (origin && state.modes["?69"] == true ? left - 1 : 0))
                bytes += Data("\u{1b}[\(row);\(col)H".utf8)
            }
        }
        replay = bytes
    }
}

/// The same lock orders observation, pipe enqueue, parser acknowledgements and
/// capture. A screen dump is only valid after the last byte reached Ghostty.
nonisolated final class TerminalProtocolObserver: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var parser = TerminalProtocolParser()
    private var fence = HerdrParserFence()
    private var revisions: [Int: UInt64] = [:]
    private var revision: UInt64 = 0
    private var parsedRevision: UInt64?
    private var enqueueLatest: ((Data) -> Void)?
    private var epoch: UInt64 = 0
    private struct CursorQuery {
        let epoch: UInt64
        let alternate: Bool
        let serial: UInt64
        let top: Int
        let left: Int
    }
    private var cursorQueries: [Int: CursorQuery] = [:]
    private var awaitingCursor: [CursorQuery] = []
    private var cursorReply = Data()

    init(state: TerminalProtocolState? = nil) { if let state { parser.state = state } }

    /// Wrap only remote output; a local shell can share enqueue with prompts
    /// and spinners without interpreting those as application negotiation.
    func makeOutputSink(enqueue: @escaping @Sendable (Data) -> Void) -> @Sendable (Data) -> Void {
        { [self] data in write(data, enqueue: enqueue) }
    }

    func reset(state: TerminalProtocolState?) {
        lock.lock(); defer { lock.unlock() }
        parser = TerminalProtocolParser()
        if let state { parser.state = state }
        revision &+= 1; parsedRevision = nil; revisions = [:]; enqueueLatest = nil
        epoch &+= 1
        // Keep issued fence IDs and partial response framing. A late reply
        // from the previous session must not acknowledge this session's bytes.
    }

    func write(_ data: Data, enqueue: @escaping (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        enqueueLatest = enqueue
        revision &+= 1
        var saves: [(Int, TerminalProtocolState)] = []
        parser.consume(data) { saves.append(($0, $1)) }
        var bytes = saves.isEmpty ? data : Data()
        var offset = 0
        for (end, state) in saves {
            bytes.append(contentsOf: data.dropFirst(offset).prefix(end - offset)); offset = end
            if let serial = state.cursorSaveSerial, let marker = fence.issue() {
                let alternate = state.alternateSavedPen?.serial == serial
                let origin = state.modes["?6"] == true
                let top = min(65535, max(1, Int(state.margins.dropFirst(2).dropLast().split(separator: ";").first ?? "1") ?? 1))
                let left = min(65535, max(1, Int(state.horizontalMargins.dropFirst(2).dropLast().split(separator: ";").first ?? "1") ?? 1))
                cursorQueries[marker.id] = CursorQuery(epoch: epoch, alternate: alternate, serial: serial,
                    top: origin ? max(1, top) : 1,
                    left: origin && state.modes["?69"] == true ? max(1, left) : 1)
                // Tag the following CPR in the same ordered response pipe.
                // The query does not move the cursor or alter the saved slot.
                bytes += marker.bytes + Data("\u{1b}[6n".utf8)
            }
        }
        if !saves.isEmpty { bytes.append(contentsOf: data.dropFirst(offset)) }
        if parser.atBoundary, revisions.count < 64, let marker = fence.issue() {
            revisions[marker.id] = revision; bytes += marker.bytes
        }
        enqueue(bytes)
    }

    func consumeResponses(_ data: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        var forward = Data()
        // Only save-cursor queries need byte-level ordering between a marker
        // and the CPR it tags. Ordinary output keeps the bulk fast path.
        let chunks = cursorQueries.isEmpty && awaitingCursor.isEmpty && cursorReply.isEmpty
            ? [data] : data.map { Data([$0]) }
        for chunk in chunks {
            let result = fence.consume(chunk)
            for id in result.acknowledged {
                if let query = cursorQueries.removeValue(forKey: id) { awaitingCursor.append(query) }
                if let value = revisions.removeValue(forKey: id) { parsedRevision = max(parsedRevision ?? 0, value) }
            }
            if awaitingCursor.isEmpty && cursorReply.isEmpty { forward += result.forward }
            else { for byte in result.forward { consumeCursorReply(byte, forward: &forward) } }
        }
        // A burst can exceed the bounded in-flight probe window. Fence the
        // final bytes once older replies drain, even if output has stopped.
        if revisions.isEmpty, parsedRevision != revision, parser.atBoundary,
           let marker = fence.issue(), let enqueueLatest {
            revisions[marker.id] = revision
            enqueueLatest(marker.bytes)
        } else if parsedRevision == revision { enqueueLatest = nil }
        return forward
    }

    private func consumeCursorReply(_ byte: UInt8, forward: inout Data) {
        guard !awaitingCursor.isEmpty else { forward.append(byte); return }
        if cursorReply.isEmpty {
            if byte == 0x1b { cursorReply.append(byte) } else { forward.append(byte) }
            return
        }
        if byte == 0x1b {
            forward += cursorReply; cursorReply = Data([byte]); return
        }
        cursorReply.append(byte)
        if cursorReply.count == 2, byte == 0x5b { return }
        if cursorReply.count > 2, ((0x30...0x39).contains(byte) || byte == 0x3b), cursorReply.count < 64 { return }
        if byte == 0x52, cursorReply.starts(with: [0x1b, 0x5b]) {
            let values = String(decoding: cursorReply.dropFirst(2).dropLast(), as: UTF8.self)
                .split(separator: ";").compactMap { Int($0) }
            if values.count == 2, values.allSatisfy({ $0 > 0 && $0 <= 65535 }) {
                let query = awaitingCursor.removeFirst()
                var pen = query.alternate ? parser.state.alternateSavedPen : parser.state.primarySavedPen
                if query.epoch == epoch, pen?.serial == query.serial {
                    pen?.row = values[0] + query.top - 1
                    pen?.col = values[1] + query.left - 1
                    if query.alternate { parser.state.alternateSavedPen = pen }
                    else { parser.state.primarySavedPen = pen }
                }
                cursorReply = Data(); return
            }
        }
        forward += cursorReply; cursorReply = Data()
    }

    func capture<T>(_ body: (TerminalProtocolState) -> T?) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard parsedRevision == revision, parser.atBoundary else { return nil }
        for pen in [parser.state.primarySavedPen, parser.state.alternateSavedPen].compactMap({ $0 }) {
            guard pen.serial == nil || (pen.row != nil && pen.col != nil) else { return nil }
        }
        return body(parser.state)
    }
}
