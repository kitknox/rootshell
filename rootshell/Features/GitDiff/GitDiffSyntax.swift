//
//  GitDiffSyntax.swift
//  rootshell
//
//  A small per-line tokenizer for diff rows: comments, strings, numbers and
//  keywords. A diff shows lines without their file, so it never tracks
//  state across lines and leaves anything it is unsure of plain.
//

import Foundation

nonisolated enum GitDiffSyntax {

    enum Token: UInt8, Sendable { case plain, keyword, string, comment, number }

    struct Language: Sendable {
        var lineComments: [[Character]]
        var blockComments = false
        var strings: Set<Character>
        var keywords: Set<String>
    }

    static func language(forPath path: String) -> Language? {
        let name = path.split(separator: "/").last.map { $0.lowercased() } ?? ""
        let ext = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last ?? "") : ""
        switch ext {
        case "swift", "kt", "kts", "java", "js", "jsx", "mjs", "cjs", "ts", "tsx", "c", "h", "cc", "cpp", "cxx", "hpp",
             "m", "mm", "cs", "go", "rs", "dart", "scala", "php", "zig", "proto", "gradle", "groovy":
            return cLike
        case "py", "rb", "sh", "bash", "zsh", "fish", "yml", "yaml", "toml", "pl", "r", "tf", "conf", "ini", "cfg",
             "nix", "ex", "exs", "cmake", "mk", "env", "gitignore", "dockerfile":
            return hash
        case "sql", "lua", "hs", "elm", "ada":
            return dash
        case "json", "jsonc", "json5", "xcstrings", "resolved":
            return json
        case "css", "scss", "less":
            return Language(lineComments: [], blockComments: true, strings: ["\"", "'"], keywords: [])
        default:
            switch name {
            case "makefile", "dockerfile", "justfile", "gemfile", "rakefile", "podfile", "brewfile": return hash
            default: return nil
            }
        }
    }

    /// One token per character of `line`.
    static func tokens(_ line: [Character], language: Language) -> [Token] {
        var tokens = [Token](repeating: .plain, count: line.count)
        var index = 0
        // A continuation line of a block comment starts with a star.
        if language.blockComments, let first = line.firstIndex(where: { !$0.isWhitespace }),
           line[first] == "*", first + 1 == line.count || line[first + 1] == " " || line[first + 1] == "/" {
            for position in first..<line.count { tokens[position] = .comment }
            return tokens
        }

        while index < line.count {
            let character = line[index]

            if let comment = language.lineComments.first(where: { matches(line, at: index, $0) }) {
                // `#` inside a word is not a comment (`a#b`, a URL fragment).
                if comment.count > 1 || index == 0 || line[index - 1].isWhitespace {
                    for position in index..<line.count { tokens[position] = .comment }
                    return tokens
                }
            }
            if language.blockComments, matches(line, at: index, ["/", "*"]) {
                var end = index + 2
                while end < line.count, !matches(line, at: end, ["*", "/"]) { end += 1 }
                end = min(line.count, end + 2)
                for position in index..<end { tokens[position] = .comment }
                index = end
                continue
            }
            if language.strings.contains(character), index == 0 || !isWord(line[index - 1]) {
                var end = index + 1
                var closed = false
                while end < line.count {
                    if line[end] == "\\" { end += 2; continue }
                    if line[end] == character { closed = true; break }
                    end += 1
                }
                // A quote that never closes, or runs into a word, is an
                // apostrophe or a lifetime, not a string.
                if closed, end + 1 == line.count || !isWord(line[end + 1]) {
                    for position in index...end { tokens[position] = .string }
                    index = end + 1
                    continue
                }
            }
            if character.isNumber, character.isASCII, index == 0 || !isWord(line[index - 1]) {
                var end = index + 1
                while end < line.count, line[end].isHexDigit || line[end] == "." || line[end] == "_" || line[end] == "x" {
                    end += 1
                }
                for position in index..<end { tokens[position] = .number }
                index = end
                continue
            }
            if isWord(character) {
                var end = index + 1
                while end < line.count, isWord(line[end]) { end += 1 }
                if language.keywords.contains(String(line[index..<end])) {
                    for position in index..<end { tokens[position] = .keyword }
                }
                index = end
                continue
            }
            index += 1
        }
        return tokens
    }

    private static func matches(_ line: [Character], at index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= line.count else { return false }
        for offset in pattern.indices where line[index + offset] != pattern[offset] { return false }
        return true
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    // MARK: - Languages

    private static let cLike = Language(
        lineComments: [["/", "/"]], blockComments: true, strings: ["\"", "'", "`"],
        keywords: [
            "func", "fn", "function", "def", "let", "var", "const", "val", "mut", "static", "final", "class", "struct",
            "enum", "protocol", "interface", "trait", "impl", "extension", "type", "typealias", "namespace", "package",
            "import", "export", "from", "use", "mod", "module", "include", "if", "else", "for", "while", "do", "loop",
            "switch", "case", "default", "match", "break", "continue", "return", "yield", "throw", "throws", "try",
            "catch", "finally", "defer", "guard", "where", "in", "is", "as", "new", "delete", "this", "self", "Self",
            "super", "nil", "null", "undefined", "true", "false", "void", "public", "private", "protected", "internal",
            "fileprivate", "open", "override", "virtual", "abstract", "async", "await", "actor", "nonisolated", "some",
            "any", "inout", "init", "deinit", "extends", "implements", "typeof", "instanceof", "sizeof",
            "unsafe", "pub", "crate", "dyn", "ref", "move", "go", "chan", "goto", "extern",
            "inline", "template", "typename", "using", "operator", "lazy", "weak", "unowned", "mutating",
            "rethrows", "when", "companion", "sealed", "suspend", "fun", "readonly", "declare",
            "int", "long", "short", "char", "float", "double", "bool", "boolean", "unsigned", "signed",
        ])

    private static let hash = Language(
        lineComments: [["#"]], strings: ["\"", "'"],
        keywords: [
            "def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "in", "not", "and", "or",
            "is", "return", "yield", "try", "except", "finally", "raise", "with", "lambda", "pass", "break",
            "continue", "global", "nonlocal", "assert", "async", "await", "None", "True", "False", "self", "end",
            "do", "then", "fi", "done", "case", "esac", "function", "local", "export", "unless", "until", "begin",
            "rescue", "ensure", "module", "require", "nil", "true", "false", "echo", "exit", "set", "unset", "elsif",
            "when", "next", "redo", "retry", "defined", "alias", "source", "readonly", "declare", "match",
        ])

    private static let dash = Language(
        lineComments: [["-", "-"]], strings: ["\"", "'"],
        keywords: [
            "select", "from", "where", "insert", "into", "update", "delete", "create", "alter", "drop", "table",
            "index", "view", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
            "limit", "offset", "values", "set", "and", "or", "not", "null", "as", "distinct", "union", "primary",
            "key", "foreign", "references", "default", "begin", "commit", "rollback", "function", "local", "end",
            "if", "then", "else", "elseif", "for", "while", "do", "return", "nil", "true", "false", "in", "repeat",
            "until", "let", "module", "import", "data", "type", "case", "of", "SELECT", "FROM", "WHERE", "INSERT",
            "INTO", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "JOIN", "ON", "GROUP", "BY",
            "ORDER", "VALUES", "SET", "AND", "OR", "NOT", "NULL", "AS", "LIMIT", "PRIMARY", "KEY", "DEFAULT",
        ])

    private static let json = Language(lineComments: [], strings: ["\""], keywords: ["true", "false", "null"])
}
