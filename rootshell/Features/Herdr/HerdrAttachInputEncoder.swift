//
//  HerdrAttachInputEncoder.swift
//  rootshell
//

import Foundation

/// Stock herdr reserves Ctrl+B q to detach; Ctrl+B Ctrl+B sends one Ctrl+B.
/// Preserve pane input while leaving complete bracketed pastes untouched.
/// Delimiter tracking does not buffer input, so a lone Escape is never delayed.
nonisolated struct HerdrAttachInputEncoder {
    private static let pasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    private static let pasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]
    private var inPaste = false
    private var matched = 0
    private var sequence: [UInt8] = []

    mutating func encode(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        for byte in data {
            if byte == 0x02 && !inPaste { output.append(byte) }
            output.append(byte)
            if !inPaste, let prefix = observeSequence(byte) { output.append(contentsOf: prefix) }
            let delimiter = inPaste ? Self.pasteEnd : Self.pasteStart
            if byte == delimiter[matched] {
                matched += 1
                if matched == delimiter.count {
                    inPaste.toggle()
                    matched = 0
                    sequence.removeAll(keepingCapacity: true)
                }
            } else {
                matched = byte == delimiter[0] ? 1 : 0
            }
        }
        return output
    }

    /// Modern keyboard protocols can encode Ctrl+B as a CSI sequence. Track
    /// the already-forwarded bytes and append the second prefix only when the
    /// event is complete, preserving immediate Escape and split input writes.
    private mutating func observeSequence(_ byte: UInt8) -> [UInt8]? {
        if byte == 0x1b {
            sequence = [byte]
        } else if sequence == [0x1b], byte == 0x5b {
            sequence.append(byte)
        } else if sequence.count >= 2, (0x20...0x3f).contains(byte), sequence.count < 128 {
            sequence.append(byte)
        } else {
            defer { sequence.removeAll(keepingCapacity: true) }
            guard sequence.count >= 2 else { return nil }
            sequence.append(byte)
            switch String(decoding: sequence, as: UTF8.self) {
            case "\u{1b}[98;5u", "\u{1b}[98;5:1u", "\u{1b}[27;5;98~": return sequence
            default: break // Repeat/release, mouse and other keys pass through.
            }
        }
        return nil
    }
}
