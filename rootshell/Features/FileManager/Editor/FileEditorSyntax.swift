//
//  FileEditorSyntax.swift
//  rootshell
//
//  Lightweight UTF-16 syntax tokenizer for the file manager's in-app editor.
//  Covers common server configs (.env, Dockerfile, nginx/systemd/ini, TOML,
//  YAML, JSON), shell scripts, markup, SQL, and mainstream code languages,
//  including shebang fallback for extensionless files.
//

import Foundation

nonisolated enum FileEditorSyntax {
    enum Token: UInt8, Sendable, Equatable {
        case plain
        case keyword
        case key
        case string
        case comment
        case number
        case variable
        case section
    }

    enum Language: String, Sendable, Equatable, CaseIterable {
        case json
        case yaml
        case toml
        case dotenv
        case ini
        case dockerfile
        case shell
        case makefile
        case markup
        case css
        case sql
        case markdown
        case hashCode
        case cLike
        case plain

        var displayName: String {
            switch self {
            case .json: "JSON"
            case .yaml: "YAML"
            case .toml: "TOML"
            case .dotenv: ".env"
            case .ini: "Config"
            case .dockerfile: "Dockerfile"
            case .shell: "Shell"
            case .makefile: "Makefile"
            case .markup: "Markup"
            case .css: "CSS"
            case .sql: "SQL"
            case .markdown: "Markdown"
            case .hashCode: "Script"
            case .cLike: "Code"
            case .plain: String(localized: "Plain Text", comment: "File editor language badge")
            }
        }
    }

    /// One colored span in UTF-16 code-unit coordinates, ready for `NSRange`.
    struct Span: Equatable, Sendable {
        let location: Int
        let length: Int
        let token: Token
    }

    /// Cap highlighting to keep huge files responsive.
    static let maxHighlightUTF16Length = 256_000

    /// Picks a language from the file name, falling back to content sniffing (shebang / JSON / XML)
    /// for extensionless server files.
    static func detectLanguage(fileName: String, contentPrefix: String = "") -> Language {
        let lower = fileName.lowercased()

        // Exact & prefix server filenames first.
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env") { return .dotenv }
        if lower == "dockerfile" || lower.hasPrefix("dockerfile.")
            || lower == "containerfile" || lower.hasPrefix("containerfile.") {
            return .dockerfile
        }
        if lower == "makefile" || lower == "gnumakefile" || lower == "bsdmakefile" || lower.hasPrefix("makefile.") {
            return .makefile
        }
        if lower == ".bashrc" || lower == ".bash_profile" || lower == ".zshrc" || lower == ".zprofile"
            || lower == ".profile" || lower == "bashrc" || lower == "zshrc" || lower == "profile"
            || lower.hasPrefix(".bash_") || lower.hasPrefix(".zsh_") {
            return .shell
        }
        if lower == ".gitconfig" || lower == "gitconfig" || lower == ".editorconfig"
            || lower == "sshd_config" || lower == "ssh_config" || lower == "nginx.conf"
            || lower == "caddyfile" || lower == "hosts" || lower == "fstab" || lower == "crontab"
            || lower == "sudoers" || lower == "resolv.conf" || lower == "sysctl.conf"
            || lower == "tmux.conf" || lower == ".tmux.conf" || lower == "my.cnf" {
            return .ini
        }
        if lower == "gemfile" || lower == "rakefile" || lower == "podfile" || lower == "brewfile"
            || lower == "vagrantfile" || lower == "fastfile" || lower == "justfile" || lower == "procfile" {
            return .hashCode
        }

        let body = lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
        let ext: String
        if let dot = body.lastIndex(of: "."), dot != body.startIndex {
            ext = String(body[body.index(after: dot)...])
        } else {
            ext = ""
        }

        switch ext {
        case "json", "jsonc", "json5", "jsonl", "ndjson", "xcstrings", "resolved":
            return .json
        case "yml", "yaml":
            return .yaml
        case "toml":
            return .toml
        case "env", "dotenv":
            return .dotenv
        case "ini", "cfg", "cnf", "conf", "properties", "props", "service", "socket",
             "timer", "target", "mount", "automount", "path", "slice", "scope",
             "network", "netdev", "link", "unit", "nginx", "vhost", "haproxy",
             "caddy", "xcconfig", "repo":
            return .ini
        case "dockerfile":
            return .dockerfile
        case "sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh":
            return .shell
        case "mk", "mak":
            return .makefile
        case "xml", "html", "htm", "xhtml", "svg", "plist", "entitlements", "xsl", "xslt", "xsd", "sdef":
            return .markup
        case "css", "scss", "sass", "less":
            return .css
        case "sql", "psql", "mysql", "plsql":
            return .sql
        case "md", "markdown", "mdx":
            return .markdown
        case "py", "pyi", "rb", "pl", "pm", "r", "tf", "tfvars", "hcl", "nix", "ex", "exs",
             "cmake", "jl", "cr", "nim", "awk", "graphql", "gql", "cue", "rego", "prisma":
            return .hashCode
        case "swift", "kt", "kts", "java", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts",
             "c", "h", "cc", "cpp", "cxx", "hh", "hpp", "m", "mm", "cs", "go", "rs", "dart",
             "scala", "php", "zig", "proto", "gradle", "groovy", "sol", "wgsl", "glsl", "metal", "v":
            return .cLike
        default:
            break
        }

        // Content fallback for extensionless files.
        return detectFromContent(contentPrefix)
    }

    private static func detectFromContent(_ prefix: String) -> Language {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }

        if trimmed.hasPrefix("#!") {
            let firstLine = trimmed.prefix(while: { $0 != "\n" && $0 != "\r" }).lowercased()
            if firstLine.contains("sh") || firstLine.contains("zsh") || firstLine.contains("fish") {
                return .shell
            }
            if firstLine.contains("python") || firstLine.contains("ruby") || firstLine.contains("perl") {
                return .hashCode
            }
            if firstLine.contains("node") || firstLine.contains("deno") || firstLine.contains("bun")
                || firstLine.contains("swift") || firstLine.contains("php") {
                return .cLike
            }
            return .shell
        }

        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && trimmed.contains("\":") {
            return .json
        }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!doctype html") || trimmed.hasPrefix("<!DOCTYPE html") {
            return .markup
        }
        return .plain
    }

    /// Produces non-plain UTF-16 spans for `text` in `language`.
    static func highlight(_ text: String, language: Language) -> [Span] {
        guard language != .plain else { return [] }
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty, utf16.count <= maxHighlightUTF16Length else { return [] }

        switch language {
        case .plain:
            return []
        case .json:
            return tokenizeJSON(utf16)
        case .yaml:
            return tokenizeYAML(utf16)
        case .toml:
            return tokenizeTOML(utf16)
        case .dotenv:
            return tokenizeDotEnv(utf16)
        case .ini:
            return tokenizeINI(utf16)
        case .dockerfile:
            return tokenizeDockerfile(utf16)
        case .makefile:
            return tokenizeMakefile(utf16)
        case .markup:
            return tokenizeMarkup(utf16)
        case .markdown:
            return tokenizeMarkdown(utf16)
        case .shell:
            return tokenizeGeneral(utf16, style: .shell)
        case .hashCode:
            return tokenizeGeneral(utf16, style: .hashCode)
        case .cLike:
            return tokenizeGeneral(utf16, style: .cLike)
        case .css:
            return tokenizeGeneral(utf16, style: .css)
        case .sql:
            return tokenizeGeneral(utf16, style: .sql)
        }
    }

    // MARK: - ASCII Constants

    private static let uLF: UInt16 = 0x0A
    private static let uCR: UInt16 = 0x0D
    private static let uSpace: UInt16 = 0x20
    private static let uTab: UInt16 = 0x09
    private static let uQuote: UInt16 = 0x22       // "
    private static let uHash: UInt16 = 0x23        // #
    private static let uDollar: UInt16 = 0x24      // $
    private static let uSingleQuote: UInt16 = 0x27 // '
    private static let uStar: UInt16 = 0x2A        // *
    private static let uDash: UInt16 = 0x2D        // -
    private static let uDot: UInt16 = 0x2E         // .
    private static let uSlash: UInt16 = 0x2F       // /
    private static let uColon: UInt16 = 0x3A       // :
    private static let uSemicolon: UInt16 = 0x3B   // ;
    private static let uLAngle: UInt16 = 0x3C      // <
    private static let uEquals: UInt16 = 0x3D      // =
    private static let uRAngle: UInt16 = 0x3E      // >
    private static let uAt: UInt16 = 0x40          // @
    private static let uLBracket: UInt16 = 0x5B    // [
    private static let uBackslash: UInt16 = 0x5C   // \
    private static let uRBracket: UInt16 = 0x5D    // ]
    private static let uUnderscore: UInt16 = 0x5F  // _
    private static let uBacktick: UInt16 = 0x60    // `
    private static let uLBrace: UInt16 = 0x7B      // {
    private static let uRBrace: UInt16 = 0x7D      // }
    private static let uBang: UInt16 = 0x21        // !

    private static func isSpaceOrTab(_ c: UInt16) -> Bool { c == uSpace || c == uTab }
    private static func isNewline(_ c: UInt16) -> Bool { c == uLF || c == uCR }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isHex(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
    private static func isAlpha(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }
    private static func isWord(_ c: UInt16) -> Bool {
        isAlpha(c) || isDigit(c) || c == uUnderscore
    }
    private static func isKeyChar(_ c: UInt16) -> Bool {
        isWord(c) || c == uDash || c == uDot
    }

    private static func lineEnd(in u: [UInt16], from start: Int) -> Int {
        var i = start
        while i < u.count && !isNewline(u[i]) { i += 1 }
        return i
    }

    private static func nextLineStart(in u: [UInt16], from lineEnd: Int) -> Int {
        var i = lineEnd
        if i < u.count && u[i] == uCR { i += 1 }
        if i < u.count && u[i] == uLF { i += 1 }
        return i
    }

    private static func string(of u: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: u[range], as: UTF16.self)
    }

    private static func scanQuoted(_ u: [UInt16], from start: Int, limit: Int) -> Int {
        let quote = u[start]
        var i = start + 1
        while i < limit {
            if u[i] == uBackslash && i + 1 < limit {
                i += 2
                continue
            }
            if u[i] == quote {
                return i + 1
            }
            i += 1
        }
        return limit
    }

    private static func scanNumber(_ u: [UInt16], from start: Int, limit: Int) -> Int {
        var i = start
        if i < limit && u[i] == uDash { i += 1 }
        guard i < limit && isDigit(u[i]) else { return start }
        while i < limit && (isHex(u[i]) || u[i] == uDot || u[i] == uUnderscore
            || u[i] == 0x78 || u[i] == 0x58 || u[i] == 0x65 || u[i] == 0x45) {
            i += 1
        }
        return i
    }

    private static func scanVariable(_ u: [UInt16], from start: Int, limit: Int) -> Int {
        guard start < limit && u[start] == uDollar else { return start }
        let next = start + 1
        guard next < limit else { return start }
        if u[next] == uLBrace {
            var i = next + 1
            while i < limit && u[i] != uRBrace { i += 1 }
            return i < limit ? i + 1 : limit
        }
        if isWord(u[next]) {
            var i = next + 1
            while i < limit && isWord(u[i]) { i += 1 }
            return i
        }
        return start
    }

    // MARK: - JSON

    private static func tokenizeJSON(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == uSlash && i + 1 < u.count && u[i + 1] == uSlash {
                let end = lineEnd(in: u, from: i)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }
            if c == uSlash && i + 1 < u.count && u[i + 1] == uStar {
                var end = i + 2
                while end + 1 < u.count && !(u[end] == uStar && u[end + 1] == uSlash) { end += 1 }
                end = min(u.count, end + 2)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }
            if c == uQuote {
                let end = scanQuoted(u, from: i, limit: u.count)
                var look = end
                while look < u.count && isSpaceOrTab(u[look]) { look += 1 }
                let token: Token = (look < u.count && u[look] == uColon) ? .key : .string
                spans.append(Span(location: i, length: end - i, token: token))
                i = end
                continue
            }
            if isDigit(c) || (c == uDash && i + 1 < u.count && isDigit(u[i + 1])) {
                let end = scanNumber(u, from: i, limit: u.count)
                spans.append(Span(location: i, length: end - i, token: .number))
                i = end
                continue
            }
            if isAlpha(c) {
                var end = i + 1
                while end < u.count && isAlpha(u[end]) { end += 1 }
                let word = string(of: u, i..<end)
                if word == "true" || word == "false" || word == "null" {
                    spans.append(Span(location: i, length: end - i, token: .keyword))
                }
                i = end
                continue
            }
            i += 1
        }
        return spans
    }

    // MARK: - YAML

    private static func tokenizeYAML(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i < end && u[i] == uHash {
                spans.append(Span(location: i, length: end - i, token: .comment))
                lineStart = nextLineStart(in: u, from: end)
                continue
            }
            // Document separator --- / ...
            if end - i >= 3,
               (u[i] == uDash && u[i + 1] == uDash && u[i + 2] == uDash)
                || (u[i] == uDot && u[i + 1] == uDot && u[i + 2] == uDot) {
                spans.append(Span(location: i, length: 3, token: .section))
                lineStart = nextLineStart(in: u, from: end)
                continue
            }
            // Skip list bullet "- "
            if i + 1 < end && u[i] == uDash && isSpaceOrTab(u[i + 1]) {
                i += 2
                while i < end && isSpaceOrTab(u[i]) { i += 1 }
            }
            // Key before ":"
            if i < end && u[i] != uQuote && u[i] != uSingleQuote {
                var colonPos: Int?
                var scan = i
                while scan < end {
                    if u[scan] == uColon && (scan + 1 == end || isSpaceOrTab(u[scan + 1])) {
                        colonPos = scan
                        break
                    }
                    if u[scan] == uHash && scan > i && isSpaceOrTab(u[scan - 1]) { break }
                    scan += 1
                }
                if let colon = colonPos, colon > i {
                    spans.append(Span(location: i, length: colon - i, token: .key))
                    i = colon + 1
                }
            }
            tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    // MARK: - TOML

    private static func tokenizeTOML(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i < end && u[i] == uHash {
                spans.append(Span(location: i, length: end - i, token: .comment))
            } else if i < end && u[i] == uLBracket {
                var close = i + 1
                while close < end && u[close] != uRBracket { close += 1 }
                while close < end && u[close] == uRBracket { close += 1 }
                spans.append(Span(location: i, length: close - i, token: .section))
                tokenizeValueRest(u, from: close, end: end, hashComment: true, semicolonComment: false, spans: &spans)
            } else if i < end {
                var eq = i
                while eq < end && u[eq] != uEquals && u[eq] != uHash { eq += 1 }
                if eq < end && u[eq] == uEquals {
                    var keyEnd = eq
                    while keyEnd > i && isSpaceOrTab(u[keyEnd - 1]) { keyEnd -= 1 }
                    if keyEnd > i { spans.append(Span(location: i, length: keyEnd - i, token: .key)) }
                    tokenizeValueRest(u, from: eq + 1, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                } else {
                    tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                }
            }
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    // MARK: - .env

    private static func tokenizeDotEnv(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i < end && u[i] == uHash {
                spans.append(Span(location: i, length: end - i, token: .comment))
                lineStart = nextLineStart(in: u, from: end)
                continue
            }
            // Optional leading `export `
            if i + 7 <= end && string(of: u, i..<(i + 6)) == "export" && isSpaceOrTab(u[i + 6]) {
                spans.append(Span(location: i, length: 6, token: .keyword))
                i += 6
                while i < end && isSpaceOrTab(u[i]) { i += 1 }
            }
            var eq = i
            while eq < end && isKeyChar(u[eq]) { eq += 1 }
            var afterKey = eq
            while afterKey < end && isSpaceOrTab(u[afterKey]) { afterKey += 1 }
            if eq > i && afterKey < end && u[afterKey] == uEquals {
                spans.append(Span(location: i, length: eq - i, token: .key))
                var valStart = afterKey + 1
                while valStart < end && isSpaceOrTab(u[valStart]) { valStart += 1 }
                if valStart < end {
                    tokenizeEnvValue(u, from: valStart, end: end, spans: &spans)
                }
            }
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    private static func tokenizeEnvValue(_ u: [UInt16], from start: Int, end: Int, spans: inout [Span]) {
        var i = start
        if u[i] == uQuote || u[i] == uSingleQuote {
            let close = scanQuoted(u, from: i, limit: end)
            spans.append(Span(location: i, length: close - i, token: .string))
            i = close
            while i < end {
                if u[i] == uHash && (i == close || isSpaceOrTab(u[i - 1])) {
                    spans.append(Span(location: i, length: end - i, token: .comment))
                    return
                }
                i += 1
            }
            return
        }
        // Unquoted value: highlight variables and trailing # comments.
        while i < end {
            if u[i] == uHash && i > start && isSpaceOrTab(u[i - 1]) {
                spans.append(Span(location: i, length: end - i, token: .comment))
                return
            }
            if u[i] == uDollar {
                let varEnd = scanVariable(u, from: i, limit: end)
                if varEnd > i {
                    spans.append(Span(location: i, length: varEnd - i, token: .variable))
                    i = varEnd
                    continue
                }
            }
            i += 1
        }
    }

    // MARK: - INI / nginx / systemd / generic .conf

    private static func tokenizeINI(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i < end && (u[i] == uHash || u[i] == uSemicolon) {
                spans.append(Span(location: i, length: end - i, token: .comment))
            } else if i < end && u[i] == uLBracket {
                var close = i + 1
                while close < end && u[close] != uRBracket { close += 1 }
                if close < end { close += 1 }
                spans.append(Span(location: i, length: close - i, token: .section))
            } else if i < end {
                // key = value OR directive value (nginx, sshd_config, Caddyfile)
                var tokenEnd = i
                while tokenEnd < end && isKeyChar(u[tokenEnd]) { tokenEnd += 1 }
                if tokenEnd > i {
                    var after = tokenEnd
                    while after < end && isSpaceOrTab(u[after]) { after += 1 }
                    if after < end && (u[after] == uEquals || u[after] == uColon) {
                        spans.append(Span(location: i, length: tokenEnd - i, token: .key))
                        tokenizeValueRest(u, from: after + 1, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                    } else if after > tokenEnd && after < end && u[after] != uLBrace {
                        spans.append(Span(location: i, length: tokenEnd - i, token: .keyword))
                        tokenizeValueRest(u, from: after, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                    } else if after < end && u[after] == uLBrace {
                        spans.append(Span(location: i, length: tokenEnd - i, token: .section))
                    } else {
                        tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                    }
                } else {
                    tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                }
            }
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    // MARK: - Dockerfile

    private static let dockerInstructions: Set<String> = [
        "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY",
        "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL",
        "HEALTHCHECK", "SHELL",
    ]

    private static func tokenizeDockerfile(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i < end && u[i] == uHash {
                spans.append(Span(location: i, length: end - i, token: .comment))
            } else if i < end {
                var wordEnd = i
                while wordEnd < end && isAlpha(u[wordEnd]) { wordEnd += 1 }
                if wordEnd > i && dockerInstructions.contains(string(of: u, i..<wordEnd).uppercased()) {
                    spans.append(Span(location: i, length: wordEnd - i, token: .keyword))
                    i = wordEnd
                }
                tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
            }
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    // MARK: - Makefile

    private static func tokenizeMakefile(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            let startsWithTab = i < end && u[i] == uTab
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i < end && u[i] == uHash {
                spans.append(Span(location: i, length: end - i, token: .comment))
            } else if !startsWithTab && i < end {
                // Target (`build:`) or variable assignment (`CC := clang`)
                var scan = i
                while scan < end && u[scan] != uColon && u[scan] != uEquals && u[scan] != uHash { scan += 1 }
                if scan < end && u[scan] == uColon && (scan + 1 >= end || u[scan + 1] != uEquals) {
                    spans.append(Span(location: i, length: scan - i, token: .section))
                    tokenizeValueRest(u, from: scan + 1, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                } else if scan < end && (u[scan] == uEquals || (u[scan] == uColon && scan + 1 < end && u[scan + 1] == uEquals)) {
                    var keyEnd = scan
                    while keyEnd > i && (isSpaceOrTab(u[keyEnd - 1]) || u[keyEnd - 1] == 0x3F || u[keyEnd - 1] == 0x2B) {
                        keyEnd -= 1
                    }
                    if keyEnd > i { spans.append(Span(location: i, length: keyEnd - i, token: .key)) }
                    tokenizeValueRest(u, from: scan + 1, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                } else {
                    tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
                }
            } else if i < end {
                tokenizeValueRest(u, from: i, end: end, hashComment: true, semicolonComment: false, spans: &spans)
            }
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    // MARK: - Markup (XML / HTML / plist / SVG)

    private static func tokenizeMarkup(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var i = 0
        while i < u.count {
            if u[i] == uLAngle {
                // Comment <!-- ... -->
                if i + 3 < u.count && u[i + 1] == uBang && u[i + 2] == uDash && u[i + 3] == uDash {
                    var end = i + 4
                    while end + 2 < u.count && !(u[end] == uDash && u[end + 1] == uDash && u[end + 2] == uRAngle) {
                        end += 1
                    }
                    end = min(u.count, end + 3)
                    spans.append(Span(location: i, length: end - i, token: .comment))
                    i = end
                    continue
                }
                // Tag name
                var tagEnd = i + 1
                if tagEnd < u.count && (u[tagEnd] == uSlash || u[tagEnd] == uBang || u[tagEnd] == 0x3F) {
                    tagEnd += 1
                }
                while tagEnd < u.count && (isKeyChar(u[tagEnd]) || u[tagEnd] == uColon) { tagEnd += 1 }
                spans.append(Span(location: i, length: tagEnd - i, token: .section))
                i = tagEnd
                // Attributes until >
                while i < u.count && u[i] != uRAngle {
                    if u[i] == uQuote || u[i] == uSingleQuote {
                        let end = scanQuoted(u, from: i, limit: u.count)
                        spans.append(Span(location: i, length: end - i, token: .string))
                        i = end
                    } else if isAlpha(u[i]) || u[i] == uUnderscore {
                        var attrEnd = i + 1
                        while attrEnd < u.count && (isKeyChar(u[attrEnd]) || u[attrEnd] == uColon) { attrEnd += 1 }
                        spans.append(Span(location: i, length: attrEnd - i, token: .key))
                        i = attrEnd
                    } else {
                        i += 1
                    }
                }
                if i < u.count && u[i] == uRAngle {
                    spans.append(Span(location: i, length: 1, token: .section))
                    i += 1
                }
                continue
            }
            i += 1
        }
        return spans
    }

    // MARK: - Markdown

    private static func tokenizeMarkdown(_ u: [UInt16]) -> [Span] {
        var spans: [Span] = []
        var lineStart = 0
        var inCodeFence = false
        while lineStart < u.count {
            let end = lineEnd(in: u, from: lineStart)
            var i = lineStart
            while i < end && isSpaceOrTab(u[i]) { i += 1 }
            if i + 2 < end && u[i] == uBacktick && u[i + 1] == uBacktick && u[i + 2] == uBacktick {
                inCodeFence.toggle()
                spans.append(Span(location: i, length: end - i, token: .comment))
            } else if inCodeFence {
                spans.append(Span(location: lineStart, length: end - lineStart, token: .string))
            } else if i < end && u[i] == uHash {
                spans.append(Span(location: i, length: end - i, token: .section))
            } else if i < end && u[i] == uRAngle {
                spans.append(Span(location: i, length: end - i, token: .comment))
            } else {
                while i < end {
                    if u[i] == uBacktick {
                        let close = scanQuoted(u, from: i, limit: end)
                        spans.append(Span(location: i, length: close - i, token: .string))
                        i = close
                        continue
                    }
                    i += 1
                }
            }
            lineStart = nextLineStart(in: u, from: end)
        }
        return spans
    }

    // MARK: - General Code (Shell / Hash / C-Like / CSS / SQL)

    private enum GeneralStyle {
        case shell, hashCode, cLike, css, sql
    }

    private static func tokenizeGeneral(_ u: [UInt16], style: GeneralStyle) -> [Span] {
        var spans: [Span] = []
        let keywords: Set<String>
        switch style {
        case .shell: keywords = shellKeywords
        case .hashCode: keywords = hashKeywords
        case .cLike: keywords = cLikeKeywords
        case .css: keywords = []
        case .sql: keywords = sqlKeywords
        }

        var i = 0
        while i < u.count {
            let c = u[i]

            // Line comments
            if (style == .shell || style == .hashCode) && c == uHash
                && (i == 0 || isSpaceOrTab(u[i - 1]) || isNewline(u[i - 1])) {
                let end = lineEnd(in: u, from: i)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }
            if style == .cLike && c == uSlash && i + 1 < u.count && u[i + 1] == uSlash {
                let end = lineEnd(in: u, from: i)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }
            if style == .sql && c == uDash && i + 1 < u.count && u[i + 1] == uDash {
                let end = lineEnd(in: u, from: i)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }

            // Block comments /* ... */
            if (style == .cLike || style == .css || style == .sql)
                && c == uSlash && i + 1 < u.count && u[i + 1] == uStar {
                var end = i + 2
                while end + 1 < u.count && !(u[end] == uStar && u[end + 1] == uSlash) { end += 1 }
                end = min(u.count, end + 2)
                spans.append(Span(location: i, length: end - i, token: .comment))
                i = end
                continue
            }

            // Strings
            if (c == uQuote || c == uSingleQuote || (c == uBacktick && (style == .cLike || style == .shell)))
                && (i == 0 || !isWord(u[i - 1])) {
                let limit = (c == uBacktick) ? u.count : lineEnd(in: u, from: i)
                let end = scanQuoted(u, from: i, limit: limit)
                if end > i + 1 && u[end - 1] == c {
                    spans.append(Span(location: i, length: end - i, token: .string))
                    i = end
                    continue
                }
            }

            // CSS @rules
            if style == .css && c == uAt {
                var end = i + 1
                while end < u.count && (isAlpha(u[end]) || u[end] == uDash) { end += 1 }
                if end > i + 1 {
                    spans.append(Span(location: i, length: end - i, token: .keyword))
                    i = end
                    continue
                }
            }

            // Shell variables
            if style == .shell && c == uDollar {
                let end = scanVariable(u, from: i, limit: u.count)
                if end > i {
                    spans.append(Span(location: i, length: end - i, token: .variable))
                    i = end
                    continue
                }
            }

            // Numbers
            if isDigit(c) && (i == 0 || !isWord(u[i - 1])) {
                let end = scanNumber(u, from: i, limit: u.count)
                spans.append(Span(location: i, length: end - i, token: .number))
                i = end
                continue
            }

            // Identifiers & keywords
            if isAlpha(c) || c == uUnderscore {
                var end = i + 1
                while end < u.count && isWord(u[end]) { end += 1 }
                let word = string(of: u, i..<end)
                if style == .sql {
                    if keywords.contains(word.lowercased()) {
                        spans.append(Span(location: i, length: end - i, token: .keyword))
                    }
                } else if style == .css {
                    var look = end
                    while look < u.count && (u[look] == uDash || isWord(u[look])) { look += 1 }
                    if look < u.count && u[look] == uColon {
                        spans.append(Span(location: i, length: look - i, token: .key))
                        i = look
                        continue
                    }
                } else if keywords.contains(word) {
                    spans.append(Span(location: i, length: end - i, token: .keyword))
                }
                i = end
                continue
            }

            i += 1
        }
        return spans
    }

    // MARK: - Shared Value Scanner (for config values)

    private static func tokenizeValueRest(
        _ u: [UInt16], from start: Int, end: Int,
        hashComment: Bool, semicolonComment: Bool, spans: inout [Span]
    ) {
        var i = start
        while i < end {
            let c = u[i]
            if hashComment && c == uHash && (i == start || isSpaceOrTab(u[i - 1])) {
                spans.append(Span(location: i, length: end - i, token: .comment))
                return
            }
            if semicolonComment && c == uSemicolon && (i == start || isSpaceOrTab(u[i - 1])) {
                spans.append(Span(location: i, length: end - i, token: .comment))
                return
            }
            if c == uQuote || c == uSingleQuote {
                let close = scanQuoted(u, from: i, limit: end)
                spans.append(Span(location: i, length: close - i, token: .string))
                i = close
                continue
            }
            if c == uDollar {
                let varEnd = scanVariable(u, from: i, limit: end)
                if varEnd > i {
                    spans.append(Span(location: i, length: varEnd - i, token: .variable))
                    i = varEnd
                    continue
                }
            }
            if isDigit(c) && (i == start || !isWord(u[i - 1])) {
                let numEnd = scanNumber(u, from: i, limit: end)
                spans.append(Span(location: i, length: numEnd - i, token: .number))
                i = numEnd
                continue
            }
            if isAlpha(c) && (i == start || !isWord(u[i - 1])) {
                var wordEnd = i + 1
                while wordEnd < end && isWord(u[wordEnd]) { wordEnd += 1 }
                let lower = string(of: u, i..<wordEnd).lowercased()
                if configValueKeywords.contains(lower) {
                    spans.append(Span(location: i, length: wordEnd - i, token: .keyword))
                }
                i = wordEnd
                continue
            }
            i += 1
        }
    }

    // MARK: - Keyword Tables

    private static let configValueKeywords: Set<String> = [
        "true", "false", "null", "nil", "yes", "no", "on", "off", "none", "as",
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
        "case", "esac", "function", "return", "exit", "local", "export", "readonly",
        "declare", "unset", "set", "shift", "source", "alias", "eval", "exec", "trap",
        "true", "false", "echo", "printf", "read", "cd", "pwd", "test", "break", "continue",
    ]

    private static let hashKeywords: Set<String> = [
        "def", "class", "import", "from", "as", "if", "elif", "else", "for", "while", "in",
        "not", "and", "or", "is", "return", "yield", "try", "except", "finally", "raise",
        "with", "lambda", "pass", "break", "continue", "global", "nonlocal", "assert",
        "async", "await", "None", "True", "False", "self", "end", "do", "then", "unless",
        "until", "begin", "rescue", "ensure", "module", "require", "nil", "true", "false",
        "elsif", "when", "next", "redo", "retry", "match", "case", "resource", "variable",
        "output", "locals", "provider", "data", "terraform",
    ]

    private static let cLikeKeywords: Set<String> = [
        "func", "fn", "function", "let", "var", "const", "val", "mut", "static", "final",
        "class", "struct", "enum", "protocol", "interface", "trait", "impl", "extension",
        "type", "typealias", "namespace", "package", "import", "export", "from", "use",
        "mod", "module", "include", "if", "else", "for", "while", "do", "loop", "switch",
        "case", "default", "match", "break", "continue", "return", "yield", "throw",
        "throws", "try", "catch", "finally", "defer", "guard", "where", "in", "is", "as",
        "new", "delete", "this", "self", "Self", "super", "nil", "null", "undefined",
        "true", "false", "void", "public", "private", "protected", "internal", "fileprivate",
        "open", "override", "virtual", "abstract", "async", "await", "actor", "nonisolated",
        "some", "any", "inout", "init", "deinit", "extends", "implements", "typeof",
        "instanceof", "sizeof", "unsafe", "pub", "crate", "dyn", "ref", "move", "go",
        "chan", "goto", "extern", "inline", "template", "typename", "using", "operator",
        "lazy", "weak", "unowned", "mutating", "rethrows", "when", "companion", "sealed",
        "suspend", "fun", "int", "long", "short", "char", "float", "double", "bool",
        "boolean", "unsigned", "signed", "string",
    ]

    private static let sqlKeywords: Set<String> = [
        "select", "from", "where", "insert", "into", "update", "delete", "create", "alter",
        "drop", "table", "index", "view", "join", "left", "right", "inner", "outer", "full",
        "cross", "on", "group", "by", "order", "having", "limit", "offset", "values", "set",
        "and", "or", "not", "null", "is", "in", "exists", "as", "distinct", "union", "all",
        "primary", "key", "foreign", "references", "default", "begin", "commit", "rollback",
        "transaction", "case", "when", "then", "else", "end", "asc", "desc", "like", "ilike",
        "between", "true", "false", "with", "returning", "conflict", "nothing", "cascade",
    ]
}
