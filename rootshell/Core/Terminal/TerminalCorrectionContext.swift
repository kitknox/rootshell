import Foundation

/// The UIKit document is not a terminal screen. Only its explicitly attributed
/// suffix may be rewritten by direct keyboard assistance. Dictation and IME
/// retain their separate document responsibilities. Eligibility ends at explicit
/// input boundaries or suffix truncation, never merely because typing pauses.
nonisolated struct TerminalCorrectionContext {
    enum Mutation {
        case text(String, eligible: Bool)
        case backspace(eligible: Bool)
        case legacyDocument(String)
        case correction(Replacement)
        case reset
        case invalidate
    }

    struct Replacement {
        let payload: Data
        let document: String
        let eligibleUTF16Count: Int
        let generation: UInt64
        let documentGeneration: UInt64
    }

    private(set) var document = ""
    private(set) var generation: UInt64 = 0
    private(set) var documentGeneration: UInt64 = 0
    private(set) var eligibleUTF16Count = 0

    static func range(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count,
              range.length <= text.utf16.count - range.location,
              let result = Range(range, in: text),
              (result.lowerBound == text.endIndex || text.indices.contains(result.lowerBound)),
              (result.upperBound == text.endIndex || text.indices.contains(result.upperBound)) else { return nil }
        return result
    }

    static func isPrintable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return true
            case .format:
                // Joiners and emoji tag sequences participate in legitimate
                // graphemes. Other invisible formatting controls are unsafe.
                return scalar.value != 0x200C && scalar.value != 0x200D
                    && !(0xE0020...0xE007F).contains(scalar.value)
            default:
                return false
            }
        }
    }

    @discardableResult
    mutating func apply(_ mutation: Mutation) -> Bool {
        switch mutation {
        case .correction(let replacement):
            return commit(replacement)
        case .invalidate:
            invalidate()
        case .reset:
            document = ""
            documentGeneration &+= 1
            invalidate()
        case .legacyDocument(let text):
            document = text
            documentGeneration &+= 1
            invalidate()
        case .text(let text, let eligible):
            if text == "\r" || text == "\n" {
                document = ""
                documentGeneration &+= 1
                invalidate()
            } else {
                let previousCount = document.utf16.count
                document += text
                if eligible && Self.isPrintable(text) {
                    eligibleUTF16Count += document.utf16.count - previousCount
                } else {
                    invalidate()
                }
            }
        case .backspace(let eligible):
            if let last = document.last {
                let removed = String(last).utf16.count
                document.removeLast()
                documentGeneration &+= 1
                if eligible, removed <= eligibleUTF16Count {
                    eligibleUTF16Count -= removed
                    generation &+= 1
                } else {
                    invalidate()
                }
            } else {
                invalidate()
            }
        }
        boundDocument()
        return true
    }

    private mutating func invalidate() {
        guard eligibleUTF16Count > 0 else { return }
        eligibleUTF16Count = 0
        generation &+= 1
    }

    private mutating func boundDocument() {
        if document.utf16.count > 4096 {
            document = Self.suffix(document, maxUTF16: 2048)
            generation &+= 1
            documentGeneration &+= 1
        }
        let bounded = Self.suffix(document, maxUTF16: min(128, eligibleUTF16Count)).utf16.count
        if bounded != eligibleUTF16Count { generation &+= 1 }
        eligibleUTF16Count = bounded
    }

    private static func suffix(_ text: String, maxUTF16: Int) -> String {
        var start = text.endIndex
        var count = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let units = text[previous..<start].utf16.count
            guard count + units <= maxUTF16 else { break }
            start = previous
            count += units
        }
        return String(text[start...])
    }

    func replacement(in range: NSRange, with text: String, generation expected: UInt64,
                     dictation: Bool = false) -> Replacement? {
        guard expected == generation,
              let indices = Self.range(range, in: document) else { return nil }
        let erased = String(document[indices.lowerBound...])
        let replay = text + document[indices.upperBound...]
        if !dictation {
            guard eligibleUTF16Count > 0,
                  range.location >= document.utf16.count - eligibleUTF16Count,
                  erased.count + replay.count <= 64,
                  // Remote editors disagree on scalar-vs-grapheme deletion.
                  // Only rewrite a suffix where both counts agree. Inserting
                  // complex graphemes is fine; erasing them is not portable.
                  erased.allSatisfy({ $0.unicodeScalars.count == 1 }),
                  Self.isPrintable(erased), Self.isPrintable(replay) else { return nil }
        }
        var payload = Data(repeating: 0x7F, count: erased.count)
        payload.append(contentsOf: (dictation ? replay.replacingOccurrences(of: "\n", with: "\r") : replay).utf8)
        let updated = String(document[..<indices.lowerBound]) + replay
        return Replacement(payload: payload, document: updated,
                           eligibleUTF16Count: dictation ? 0 : eligibleUTF16Count - erased.utf16.count + replay.utf16.count,
                           generation: generation, documentGeneration: documentGeneration)
    }

    @discardableResult
    mutating func commit(_ replacement: Replacement) -> Bool {
        guard replacement.generation == generation,
              replacement.documentGeneration == documentGeneration else { return false }
        document = replacement.document
        documentGeneration &+= 1
        eligibleUTF16Count = replacement.eligibleUTF16Count
        generation &+= 1
        boundDocument()
        return true
    }
}
