import Foundation

nonisolated extension TerminalTouchKeyboardModel {
    /// Letter-page arrangements. Raw values are persisted. Every layout keeps all
    /// 26 ASCII letters for shell commands; the number and symbol pages are shared.
    enum Layout: String, CaseIterable, Sendable {
        case us, german, french, spanish, portuguese
        case swedishFinnish = "swedish-finnish"
        case danish, norwegian, turkish

        var displayName: String {
            switch self {
            case .us: String(localized: "English (US)", comment: "Terminal keyboard layout")
            case .german: String(localized: "German (QWERTZ)", comment: "Terminal keyboard layout")
            case .french: String(localized: "French (AZERTY)", comment: "Terminal keyboard layout")
            case .spanish: String(localized: "Spanish", comment: "Terminal keyboard layout")
            case .portuguese: String(localized: "Portuguese", comment: "Terminal keyboard layout")
            case .swedishFinnish: String(localized: "Swedish & Finnish", comment: "Terminal keyboard layout")
            case .danish: String(localized: "Danish", comment: "Terminal keyboard layout")
            case .norwegian: String(localized: "Norwegian", comment: "Terminal keyboard layout")
            case .turkish: String(localized: "Turkish (Q)", comment: "Terminal keyboard layout")
            }
        }

        /// The three typing rows; the third sits between Shift and Delete.
        var letterRows: [String] {
            switch self {
            case .us: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
            case .german: ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"]
            case .french: ["azertyuiop", "qsdfghjklm", "wxcvbn'"]
            case .spanish: ["qwertyuiop", "asdfghjklñ", "zxcvbnm"]
            // ç sits right of L, as on both physical Portuguese layouts.
            case .portuguese: ["qwertyuiop", "asdfghjklç", "zxcvbnm"]
            case .swedishFinnish: ["qwertyuiopå", "asdfghjklöä", "zxcvbnm"]
            case .danish: ["qwertyuiopå", "asdfghjklæø", "zxcvbnm"]
            case .norwegian: ["qwertyuiopå", "asdfghjkløæ", "zxcvbnm"]
            case .turkish: ["qwertyuıopğü", "asdfghjklşi", "zxcvbnmöç"]
            }
        }

        /// Letter prediction, suggestions, and writing assistance are English only.
        var usesEnglishTextModels: Bool { self == .us }

        private var locale: Locale? { self == .turkish ? Locale(identifier: "tr") : nil }

        /// This language's letters lead its long-press lists, in this order.
        private var nativeLetters: String {
            switch self {
            case .us: ""
            case .german: "äöüß"
            case .french: "éèêàâçëîïôœùûüÿæ"
            case .spanish: "áéíóúñü"
            case .portuguese: "áàâãçéêíóôõú"
            case .swedishFinnish: "åäö"
            case .danish, .norwegian: "æøå"
            case .turkish: "çğıöşü"
            }
        }

        /// One character in, one out: ß becomes ẞ, never "SS".
        func shifted(_ text: String) -> String {
            let upper = locale.map { text.uppercased(with: $0) } ?? text.uppercased()
            if upper.count == text.count { return upper }
            return text == "ß" ? "ẞ" : text
        }

        /// Text payload for a Shift chord. Non-letters stay nil and keep US key semantics.
        func shiftedLetter(_ text: String) -> Character? {
            guard text.count == 1, text.first?.isLetter == true else { return nil }
            return shifted(text).first
        }

        func variants(for text: String) -> String? {
            guard let all = Self.variants[text] else { return nil }
            return nativeLetters.filter { all.contains($0) } + all.filter { !nativeLetters.contains($0) }
        }

        private static let variants: [String: String] = [
            "a": "àáâäæãåāą", "c": "çćč", "d": "ďđ", "e": "èéêëēėęě", "g": "ğ", "i": "ìíîïīįı",
            "l": "łľĺ", "n": "ñńň", "o": "òóôöõøœōő", "r": "řŕ", "s": "ßśšş", "t": "ťţ",
            "u": "ùúûüūůű", "y": "ÿý", "z": "žźż",
            "$": "€£¥₩₹¢", "-": "–—•", "?": "¿", "!": "¡", "'": "’‘‚", "\"": "“”„«»",
            ".": "…", "0": "°", "&": "§", "%": "‰"
        ]
    }
}
