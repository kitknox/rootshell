import Foundation

nonisolated extension TerminalTouchKeyboardModel {
    /// Letter-page arrangements. Raw values are persisted. Every layout keeps all
    /// 26 ASCII letters for shell commands; the number and symbol pages are shared.
    enum Layout: String, CaseIterable, Sendable {
        case us
        case englishQWERTZ = "english-qwertz"
        case croatian, danish, dutch, estonian, finnish, french, german, hungarian
        case italian, latvian, lithuanian, norwegian, polish
        case brazilianPortuguese = "portuguese-brazil"
        case portuguese = "portuguese-portugal"
        case romanian, slovenian, spanish, swedish, turkish

        var displayName: String {
            switch self {
            case .us: String(localized: "English (US)", comment: "Terminal keyboard layout")
            case .englishQWERTZ: String(localized: "English (QWERTZ)", comment: "Terminal keyboard layout")
            case .croatian: String(localized: "Croatian (QWERTZ)", comment: "Terminal keyboard layout")
            case .danish: String(localized: "Danish", comment: "Terminal keyboard layout")
            case .dutch: String(localized: "Dutch", comment: "Terminal keyboard layout")
            case .estonian: String(localized: "Estonian", comment: "Terminal keyboard layout")
            case .finnish: String(localized: "Finnish", comment: "Terminal keyboard layout")
            case .french: String(localized: "French (AZERTY)", comment: "Terminal keyboard layout")
            case .german: String(localized: "German (QWERTZ)", comment: "Terminal keyboard layout")
            case .hungarian: String(localized: "Hungarian (QWERTZ)", comment: "Terminal keyboard layout")
            case .italian: String(localized: "Italian", comment: "Terminal keyboard layout")
            case .latvian: String(localized: "Latvian", comment: "Terminal keyboard layout")
            case .lithuanian: String(localized: "Lithuanian", comment: "Terminal keyboard layout")
            case .norwegian: String(localized: "Norwegian", comment: "Terminal keyboard layout")
            case .polish: String(localized: "Polish", comment: "Terminal keyboard layout")
            case .brazilianPortuguese: String(localized: "Portuguese (Brazil)", comment: "Terminal keyboard layout")
            case .portuguese: String(localized: "Portuguese (Portugal)", comment: "Terminal keyboard layout")
            case .romanian: String(localized: "Romanian", comment: "Terminal keyboard layout")
            case .slovenian: String(localized: "Slovenian (QWERTZ)", comment: "Terminal keyboard layout")
            case .spanish: String(localized: "Spanish", comment: "Terminal keyboard layout")
            case .swedish: String(localized: "Swedish", comment: "Terminal keyboard layout")
            case .turkish: String(localized: "Turkish (Q)", comment: "Terminal keyboard layout")
            }
        }

        /// The three typing rows; the third sits between Shift and Delete.
        var letterRows: [String] {
            switch self {
            case .us, .dutch, .estonian, .italian, .latvian, .lithuanian, .polish,
                 .brazilianPortuguese, .portuguese, .romanian:
                ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
            case .englishQWERTZ, .croatian, .hungarian, .slovenian: ["qwertzuiop", "asdfghjkl", "yxcvbnm"]
            case .german: ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"]
            case .french: ["azertyuiop", "qsdfghjklm", "wxcvbn'"]
            case .spanish: ["qwertyuiop", "asdfghjklñ", "zxcvbnm"]
            case .swedish, .finnish: ["qwertyuiopå", "asdfghjklöä", "zxcvbnm"]
            case .danish: ["qwertyuiopå", "asdfghjklæø", "zxcvbnm"]
            case .norwegian: ["qwertyuiopå", "asdfghjkløæ", "zxcvbnm"]
            case .turkish: ["qwertyuıopğü", "asdfghjklşi", "zxcvbnmöç"]
            }
        }

        /// Letter prediction, suggestions, and writing assistance are English only.
        var usesEnglishTextModels: Bool { self == .us || self == .englishQWERTZ }

        /// The language code tagged on Space ("DE", "FR"); US English shows none.
        var spaceBadge: String? {
            self == .us ? nil : languageIdentifier.prefix(2).uppercased()
        }

        private var languageIdentifier: String {
            switch self {
            case .us, .englishQWERTZ: "en"
            case .croatian: "hr"
            case .danish: "da"
            case .dutch: "nl"
            case .estonian: "et"
            case .finnish: "fi"
            case .french: "fr"
            case .german: "de"
            case .hungarian: "hu"
            case .italian: "it"
            case .latvian: "lv"
            case .lithuanian: "lt"
            case .norwegian: "nb"
            case .polish: "pl"
            case .brazilianPortuguese: "pt_BR"
            case .portuguese: "pt_PT"
            case .romanian: "ro"
            case .slovenian: "sl"
            case .spanish: "es"
            case .swedish: "sv"
            case .turkish: "tr"
            }
        }

        private var locale: Locale? { self == .turkish ? Locale(identifier: "tr") : nil }

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

        /// Apple's long-press list for this language, base key included, in Apple's order.
        func variants(for text: String, shifted isShifted: Bool) -> [String]? {
            let table = Self.tables[self == .englishQWERTZ ? .us : self] ?? [:]
            let list: [String]
            if isShifted, let upper = table[shifted(text)] {
                list = upper.split(separator: " ").map(String.init)
            } else if let lower = table[text] ?? Self.common[text] {
                list = lower.split(separator: " ").map { isShifted ? shifted(String($0)) : String($0) }
            } else { return nil }
            var seen = Set<String>()
            return list.filter { seen.insert($0).inserted }
        }

        // Transcribed from the iOS 26.5 keyboard data (Keyboard-default.plist and
        // each language's Keyboard-<lang>.plist). Capitals are listed only where
        // Apple's order differs from the lowercase list.
        private static let common: [String: String] = [
            "!": "¡ !", "\"": "” “ „ » « \"", "$": "$ € £ ¥ ₩ ₽", "%": "‰ %", "&": "§ &", "'": "’ ‘ ` '",
            "-": "– — • -", ".": "… .", "/": "\\ /", "0": "° 0", "?": "¿ ?"
        ]
        private static let tables: [Layout: [String: String]] = [
            .us: [
                "$": "$ ¢", "I": "I Ì Í Î Ï Ǐ Ĩ Ī İ Į", "S": "S ẞ Ś Š Ş Ș", "a": "a à á â ä ǎ æ ã å ā ă ą",
                "c": "c ç ć č ċ", "d": "d ď ð", "e": "e è é ê ë ě ẽ ē ė ę", "g": "g ğ ġ", "h": "h ħ",
                "i": "i ì í î ï ǐ ĩ ī ı į", "k": "k ķ", "l": "l ł ļ ľ", "n": "n ñ ń ņ ň", "o": "o ò ó ô ö ǒ œ ø õ ō ő",
                "r": "r ř", "s": "s ß ş ș ś š", "t": "t ț ť þ", "u": "u ù ú û ü ǔ ũ ū ű ů ų", "w": "w ŵ",
                "y": "y ý ŷ ÿ", "z": "z ź ž ż"
            ],
            .croatian: [
                "S": "Š S Ś", "c": "č ć c ç", "d": "đ d", "s": "š s ß ś", "z": "ž z ź ż"
            ],
            .danish: [
                "\"": "“ „ ” « » \"", "S": "S Ś Š", "a": "æ å á a ä à â ã ā", "d": "ð d", "e": "é e ë", "i": "í i ï",
                "l": "l ł", "n": "n ñ ń", "o": "ø ó o ô ò õ œ ō ö", "s": "s ß ś š", "u": "ú u ü û ù ū", "y": "ý y ÿ",
                "æ": "æ ä", "ø": "ö ø"
            ],
            .dutch: [
                "a": "á ä â a à æ ã å ā", "c": "c ç", "e": "é ë ê e è ę ė ē", "i": "í ï i ì î į ī", "j": "j́ j",
                "n": "n ñ ń", "o": "ó ö ô o ò õ œ ø ō", "u": "ú ü û u ù ū"
            ],
            .estonian: [
                "S": "Š S Ś", "a": "ä a à á â æ ã å ā", "o": "õ ö o ô ò ó œ ø ō", "s": "š s ß ś", "u": "ü u û ù ú ū",
                "z": "ž z ź ż"
            ],
            .finnish: [
                "S": "Š S Ś Ŝ Ṣ Ș", "a": "ä å æ a à á â ã ā ạ", "c": "c ç č ĉ", "d": "d đ ð ḓ ď",
                "e": "e é è ë ê ẽ ē ẹ ė ǝ", "g": "g ǥ ǧ ģ", "i": "í i ì ï î ĩ ī ị", "k": "k ǩ ḵ ķ", "l": "l ł",
                "n": "n ñ ň ṋ ṉ ŋ", "o": "ö ø o ô ò ó õ ō ọ ȯ ő œ", "s": "š s ß ś ŝ ṣ ș", "t": "t ŧ ț ṱ ṯ þ",
                "u": "u ü ú ù û ũ ū ụ ů", "y": "y ÿ ý ỳ ŷ ỹ ȳ ẙ ẏ ɏ", "z": "ž z ź ż ʒ ǯ", "ä": "ä æ", "ö": "ö ø"
            ],
            .french: [
                "\"": "» « ” “ „ \"", ".": ". ·", "a": "à â ª a æ á ä ã å ā", "c": "ç c ć č", "e": "é è ê ë e ę ė ē",
                "i": "î ï i ì í į ī", "n": "n ñ ń", "o": "ô œ º o ö ò ó õ ø ō", "u": "û ù u ü ú ū", "y": "y ÿ"
            ],
            .german: [
                "\"": "„ “ ” « » \"", "'": "‚ ‹ › ‘ '", "-": "–", "a": "ä a à á â æ ã å ā", "c": "c ç ć č",
                "e": "é e è ê ë ė", "i": "i î ï í ī ì", "n": "n ñ ń", "o": "ö o ô ò ó õ œ ø ō", "s": "ß s ś š",
                "u": "ü u û ù ú ū", "y": "y ÿ"
            ],
            .hungarian: [
                "a": "á a à â ä æ ã å ā", "e": "é e è ê ë ę ė ē", "i": "í i î ï ì į ī", "o": "ö ő ó o ô ò õ œ ø ō",
                "u": "ú ü ű u û ù ū"
            ],
            .italian: [
                "0": "0º 0ª 0", "1": "1º 1ª 1", "2": "2º 2ª 2", "3": "3º 3ª 3", "4": "4º 4ª 4", "5": "5º 5ª 5",
                "6": "6º 6ª 6", "7": "7º 7ª 7", "8": "8º 8ª 8", "9": "9º 9ª 9", "S": "S Ś Š",
                "a": "à a á ª â ä æ ã å ā", "c": "c ç ć č", "e": "è é e ə ê ë ę ė ē", "i": "ì i í î ï į ī",
                "o": "ò ó o º ô ö õ œ ø ō", "s": "ß s ś š", "u": "ù u ú û ü ū"
            ],
            .latvian: [
                "S": "Š S Ś", "a": "ā a à á â ä æ ã å", "c": "č c ç ć", "e": "ē e è é ê ë ę ė", "g": "ģ g",
                "i": "ī i î ï ì í į", "k": "ķ k", "l": "ļ l ł", "n": "ņ n ñ ń", "r": "r ŗ", "s": "š s ß ś",
                "u": "ū u û ü ù ú", "z": "ž z ź ż"
            ],
            .lithuanian: [
                "S": "Š S Ś", "a": "ą a à á â ä æ ã å ā", "c": "č c ç ć", "e": "ė ę e è é ê ë ē", "i": "į i î ï ì í ī",
                "s": "š s ß ś", "u": "ų ū u û ü ù ú", "z": "ž z ź ż"
            ],
            .norwegian: [
                "\"": "« » “ ” „ \"", "a": "æ å à a ä á â ã ā ạ", "c": "c č ç ĉ", "d": "d đ ð ḓ ď",
                "e": "é e è ê ë ę ė ẹ ē ẽ ǝ", "g": "g ǥ ǧ ģ", "i": "i ï í ì î ĩ ī ị", "k": "k ǩ ḵ ķ", "l": "l ł",
                "n": "n ñ ň ṋ ṉ ŋ", "o": "ø ô ò ó o ö õ œ ō ȯ ọ ő œ", "s": "s š ŝ ṣ ș", "t": "t ŧ ț ṱ ṯ þ",
                "u": "ü u û ù ú ū ũ ů ụ", "y": "y ÿ ý ỳ ŷ ỹ ȳ ẙ ẏ ɏ", "z": "z ž ʒ ǯ", "æ": "æ ä", "ø": "ø ö", "•": "° •"
            ],
            .polish: [
                "S": "Ś S Š", "a": "ą a à á â ä æ ã å ā", "c": "ć c ç č", "e": "ę e è é ê ë ė ē", "l": "ł l",
                "n": "ń n ñ", "o": "ó o ô ö ò õ œ ø ō", "s": "ś s ß š", "z": "ż ź z ž"
            ],
            .brazilianPortuguese: [
                "1": "1º 1ª 1", "2": "2º 2ª 2", "3": "3º 3ª 3", "4": "4º 4ª 4", "5": "5º 5ª 5", "6": "6º 6ª 6",
                "7": "7º 7ª 7", "8": "8º 8ª 8", "9": "9º 9ª 9", "a": "á ã à â a ª ä å æ", "c": "ç c",
                "e": "é ê e è ę ė ē ë", "i": "í i î ì ï į ī", "n": "n ñ", "o": "ó õ ô o ò º ö œ ø ō", "u": "ú u ü ù û ū"
            ],
            .portuguese: [
                "1": "1.º 1.ª 1", "2": "2.º 2.ª 2", "3": "3.º 3.ª 3", "4": "4.º 4.ª 4", "5": "5.º 5.ª 5",
                "6": "6.º 6.ª 6", "7": "7.º 7.ª 7", "8": "8.º 8.ª 8", "9": "9.º 9.ª 9", "a": "á ã à â a ª ä å æ",
                "c": "ç c č ć", "e": "é ê e è ę ė ē ë", "i": "í i î ì ï į ī", "n": "n ñ", "o": "ó õ ô o ò º ö œ ø ō",
                "u": "ú u ü ù û ū"
            ],
            .romanian: [
                "\"": "„ ” » « “ \"", "S": "Ș S Ś Š", "a": "ă â a à á ä æ ã å ā", "i": "î i ï ì í į ī",
                "s": "ș s ß ś š", "t": "ț t"
            ],
            .slovenian: [
                "S": "Š S Ś", "a": "á a à â ä æ å ā", "c": "č ć c ç", "d": "đ ď d", "e": "é ě e è ê ë ē",
                "i": "í i î ï ì ī", "l": "ľ ĺ l", "n": "ň n ñ", "o": "ó o ô ö ò ø ō", "r": "ř ŕ r", "s": "š s ß ś",
                "t": "ť t", "u": "ú u û ü ù ū", "y": "ý y ÿ", "z": "ž z ź ż"
            ],
            .spanish: [
                "0": "0º 0ª 0", "1": "1º 1ª 1", "2": "2º 2ª 2", "3": "3º 3ª 3", "4": "4º 4ª 4", "5": "5º 5ª 5",
                "6": "6º 6ª 6", "7": "7º 7ª 7", "8": "8º 8ª 8", "9": "9º 9ª 9", "a": "á a ª à ä â ã å ą æ ā",
                "c": "c ç ć č", "d": "d đ", "e": "é e è ë ê ę ė ē", "i": "í i ï ì î į ī", "n": "n ñ ń",
                "o": "ó o º ò ö ô õ ø œ ō", "s": "s š", "u": "ú ü u ù û ū"
            ],
            .swedish: [
                "S": "S Ś Š Ŝ Ṣ Ș", "a": "ä å a á à â ã ā ạ æ", "c": "c ç č ĉ", "d": "d đ ð ḓ ď",
                "e": "é e ë è ê ẽ ē ę ė ẹ ǝ", "g": "g ǥ ǧ ģ", "i": "i ï í ì î ĩ ī ị", "k": "k ǩ ḵ ķ", "l": "l ł",
                "n": "n ñ ň ṋ ṉ ŋ", "o": "ö œ o ó ò ô õ ō ø ȯ ọ ő", "s": "ß s ś š ŝ ṣ ș", "t": "t ŧ ț ṱ ṯ þ",
                "u": "ü u ú ù û ũ ū ů ụ", "y": "y ÿ ý ỳ ŷ ỹ ȳ ẙ ẏ ɏ", "z": "z ž ʒ ǯ", "ä": "æ ä", "ö": "ø ö"
            ],
            .turkish: [
                "S": "Ş S Ś Š", "a": "a â", "c": "ç c ć č", "g": "ğ g", "i": "ı i î ï ì í į ī",
                "o": "ö o ô œ ò ó õ ø ō", "s": "ş s ß ś š", "u": "ü u û ù ú ū", "İ": "I İ Î Ï Ì Í Į"
            ],
        ]
    }
}
