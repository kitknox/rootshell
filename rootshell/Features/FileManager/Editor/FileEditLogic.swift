//
//  FileEditLogic.swift
//  rootshell
//
//  Pure rules for remote and local file editing: text/binary classification,
//  content sniffing, encoding and line-ending preservation, indentation
//  detection, SHA-256 digests, and remote conflict fingerprints.
//  No UIKit or network I/O, so it is unit-tested directly.
//

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

/// Embedded terminal editors bundled on iOS, iPadOS, and visionOS.
nonisolated enum FileManagerEmbeddedEditor: String, Codable, CaseIterable, Sendable {
    case vim
    case hx

    var command: String { rawValue }

    var title: String {
        switch self {
        case .vim: "Vim"
        case .hx: "Helix (hx)"
        }
    }

    var shortTitle: String {
        switch self {
        case .vim: "vim"
        case .hx: "hx"
        }
    }
}

/// Whether opening a text file prefers the in-app editor, an external app (macOS),
/// or an embedded terminal editor (Vim / Helix on iOS, iPadOS, and visionOS).
nonisolated enum FileManagerEditorPreference: String, Codable, CaseIterable, Sendable {
    case inApp
    case external
    case vim
    case hx

    var title: String {
        switch self {
        case .inApp:
            String(localized: "In-App Editor", comment: "File manager default editor option")
        case .external:
            String(localized: "External Editor", comment: "File manager default editor option")
        case .vim:
            "Vim"
        case .hx:
            "Helix (hx)"
        }
    }

    /// Options offered in the UI for the current platform.
    static var platformCases: [FileManagerEditorPreference] {
        #if targetEnvironment(macCatalyst)
        [.inApp, .external]
        #else
        [.inApp, .vim, .hx]
        #endif
    }

    /// Maps preferences synced from another platform onto a supported choice on `isMacCatalyst`.
    func resolved(isMacCatalyst: Bool) -> FileManagerEditorPreference {
        if isMacCatalyst {
            return self == .external ? .external : .inApp
        } else {
            switch self {
            case .vim, .hx, .inApp: return self
            case .external: return .inApp
            }
        }
    }

    var embeddedEditor: FileManagerEmbeddedEditor? {
        switch self {
        case .vim: .vim
        case .hx: .hx
        case .inApp, .external: nil
        }
    }
}

/// Decides whether a file should open in the editor, be sniffed first, or go to Quick Look.
nonisolated enum FileEditClassification {
    /// Largest file opened in the in-app text editor (5 MB).
    static let maxInAppEditBytes: Int64 = 5 * 1024 * 1024
    /// Largest remote file downloaded for external-editor auto-upload watching (64 MB).
    static let maxExternalEditBytes: Int64 = 64 * 1024 * 1024
    /// Prefix examined when sniffing extensionless or unknown files.
    static let sniffByteCount = 8192

    enum OpenDecision: Equatable, Sendable {
        case edit
        case sniffThenDecide
        case quickLook
    }

    static func decision(forName name: String, size: Int64) -> OpenDecision {
        guard size >= 0, size <= maxInAppEditBytes else { return .quickLook }
        if isKnownBinary(name: name) { return .quickLook }
        if isKnownTextFile(name: name) { return .edit }
        return .sniffThenDecide
    }

    static func isKnownBinary(name: String) -> Bool {
        let lower = name.lowercased()
        if knownBinaryNames.contains(lower) { return true }
        let ext = fileExtension(of: lower)
        if !ext.isEmpty, knownBinaryExtensions.contains(ext) { return true }
        if !ext.isEmpty, !knownTextExtensions.contains(ext), let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) && !type.conforms(to: .svg) { return true }
            if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio)
                || type.conforms(to: .pdf) || type.conforms(to: .archive)
                || type.conforms(to: .font) || type.conforms(to: .executable)
                || type.conforms(to: .diskImage) {
                return true
            }
        }
        return false
    }

    static func isKnownTextFile(name: String) -> Bool {
        let lower = name.lowercased()
        if knownTextNames.contains(lower) { return true }
        // Common server/project naming patterns: .env, .env.local, Dockerfile.prod, etc.
        if lower == ".env" || lower.hasPrefix(".env.") || lower.hasSuffix(".env") { return true }
        if lower.hasPrefix("dockerfile.") || lower.hasPrefix("containerfile.")
            || lower.hasPrefix("makefile.") || lower.hasPrefix("compose.")
            || lower.hasPrefix("docker-compose.") {
            return true
        }
        if lower.hasPrefix("."), (lower.hasSuffix("rc") || lower.hasSuffix("profile")
            || lower.hasSuffix("ignore") || lower.hasSuffix("config")
            || lower.hasPrefix(".bash_") || lower.hasPrefix(".zsh_")) {
            return true
        }

        let ext = fileExtension(of: lower)
        guard !ext.isEmpty else { return false }
        if knownTextExtensions.contains(ext) { return true }
        if knownBinaryExtensions.contains(ext) { return false }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .text) || type.conforms(to: .sourceCode)
                || type.conforms(to: .script) || type.conforms(to: .shellScript)
                || type.conforms(to: .json) || type.conforms(to: .yaml)
                || type.conforms(to: .xml) || type.conforms(to: .svg) {
                return true
            }
        }
        return false
    }

    /// True when `data` looks like editable plain text rather than binary bytes.
    static func isTextData(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        // Binary Apple property list ("bplist00" etc.) should preview or stay binary.
        if data.starts(with: Data("bplist".utf8)) { return false }

        let sample = data.prefix(sniffByteCount)
        let bytes = Array(sample)

        // UTF-16 with BOM is valid text even though it contains NUL bytes.
        if bytes.count >= 2,
           (bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE) {
            let encoding: String.Encoding = bytes[0] == 0xFE ? .utf16BigEndian : .utf16LittleEndian
            return String(data: data, encoding: encoding) != nil
        }

        // Any NUL byte in non-UTF-16 content indicates binary data.
        if bytes.contains(0x00) { return false }

        // Trim an incomplete trailing UTF-8 scalar if we sliced mid-character.
        let utf8Sample = trimIncompleteTrailingUTF8(bytes)
        let isValidUTF8 = String(bytes: utf8Sample, encoding: .utf8) != nil

        // Reject data with a significant share of non-whitespace control characters.
        var suspiciousControlCount = 0
        for byte in bytes {
            if byte < 0x20 {
                // Allow tab (0x09), LF (0x0A), FF (0x0C), CR (0x0D), ESC (0x1B).
                if byte != 0x09 && byte != 0x0A && byte != 0x0C && byte != 0x0D && byte != 0x1B {
                    suspiciousControlCount += 1
                }
            } else if byte == 0x7F {
                suspiciousControlCount += 1
            }
        }

        let controlRatio = Double(suspiciousControlCount) / Double(bytes.count)
        if isValidUTF8 {
            return controlRatio <= 0.02
        }
        // Fallback for legacy ISO-8859-1 / Windows-1252 configs without NULs.
        return suspiciousControlCount == 0
    }

    private static func fileExtension(of lowercasedName: String) -> String {
        // Leading-dot dotfiles with no second dot (e.g. ".bashrc", ".env") have no extension.
        let body = lowercasedName.hasPrefix(".") ? String(lowercasedName.dropFirst()) : lowercasedName
        guard let dot = body.lastIndex(of: "."), dot != body.startIndex else { return "" }
        return String(body[body.index(after: dot)...])
    }

    private static func trimIncompleteTrailingUTF8(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }
        var end = bytes.count
        var checked = 0
        while end > 0 && checked < 4 {
            let b = bytes[end - 1]
            if b & 0x80 == 0 {
                // ASCII byte; sequence is complete.
                return Array(bytes[..<end])
            }
            if b & 0xC0 == 0xC0 {
                // Leading byte of a multi-byte sequence; verify its expected length.
                let expected: Int
                if b & 0xE0 == 0xC0 { expected = 2 }
                else if b & 0xF0 == 0xE0 { expected = 3 }
                else if b & 0xF8 == 0xF0 { expected = 4 }
                else { return bytes }
                let actual = bytes.count - (end - 1)
                return actual == expected ? bytes : Array(bytes[..<(end - 1)])
            }
            end -= 1
            checked += 1
        }
        return bytes
    }

    private static let knownBinaryNames: Set<String> = [
        ".ds_store", "thumbs.db", "icon\r",
    ]

    private static let knownBinaryExtensions: Set<String> = [
        // Images (excluding svg)
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "ico", "icns",
        "tiff", "tif", "psd", "raw", "cr2", "nef", "dng", "avif", "exr", "jp2",
        // Audio / video
        "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "aif", "wma",
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "ts_video", "mpg", "mpeg",
        // Archives & packages
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "zst", "lz4", "7z", "rar",
        "dmg", "iso", "img", "pkg", "deb", "rpm", "apk", "ipa", "aab", "jar", "war", "ear",
        "whl", "egg", "gem", "nupkg", "cab", "msi", "snap", "appimage",
        // Documents & fonts
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "odt", "ods", "odp", "epub", "mobi", "ttf", "otf", "woff", "woff2", "eot",
        // Databases & compiled artifacts
        "sqlite", "sqlite3", "db", "db-wal", "db-shm", "mdb", "ldb", "parquet", "avro",
        "o", "a", "so", "dylib", "dll", "exe", "bin", "elf", "wasm", "pyc", "pyo",
        "class", "dex", "car", "nib", "scn", "pack", "idx", "p12", "pfx", "jks", "der",
        "mmdb", "lzfse", "br",
    ]

    private static let knownTextNames: Set<String> = [
        "dockerfile", "containerfile", "makefile", "gnumakefile", "bsdmakefile",
        "justfile", "vagrantfile", "jenkinsfile", "procfile", "caddyfile",
        "gemfile", "rakefile", "podfile", "brewfile", "fastfile", "appfile",
        "matchfile", "gymfile", "snapfile", "berksfile", "capfile", "guardfile",
        "thorfile", "puppetfile", "cartfile", "build", "workspace", "cmakelists.txt",
        "meson.build", "readme", "license", "licence", "copying", "notice", "authors",
        "contributors", "changelog", "changes", "news", "todo", "version", "codeowners",
        // Common Linux / Unix / server config files (often extensionless)
        "hosts", "hostname", "fstab", "mtab", "crontab", "passwd", "group", "shadow",
        "gshadow", "sudoers", "sshd_config", "ssh_config", "authorized_keys",
        "authorized_keys2", "known_hosts", "config", "credentials", "rc.local",
        "exports", "motd", "issue", "issue.net", "shells", "nsswitch.conf",
        "resolv.conf", "hosts.allow", "hosts.deny", "modules", "environment",
        "locale", "timezone", "sysctl.conf", "inittab", "protocols", "services",
        "networks", "ethers", "aliases", "mailname", "crontab", "anacrontab",
        "crontab", "profile", "bashrc", "zshrc", "vimrc", "gitconfig", "gitignore",
        "gitattributes", "gitmodules", "dockerignore", "npmignore", "eslintignore",
        "prettierignore", "editorconfig", "htaccess", "htpasswd", "netrc",
        "tmux.conf", "nginx.conf", "httpd.conf", "apache2.conf", "caddy.conf",
        "redis.conf", "mongod.conf", "postgresql.conf", "pg_hba.conf", "my.cnf",
        "haproxy.cfg", "supervisord.conf", "rsyslog.conf", "logrotate.conf",
        "default", "sites-available", "interfaces",
    ]

    private static let knownTextExtensions: Set<String> = [
        // Config / Infra / DevOps / Data
        "conf", "cfg", "cnf", "ini", "toml", "yaml", "yml", "json", "jsonc", "json5",
        "jsonl", "ndjson", "properties", "props", "env", "hcl", "tf", "tfvars", "nomad",
        "service", "socket", "timer", "target", "mount", "automount", "path", "slice",
        "scope", "network", "netdev", "link", "rules", "unit", "nginx", "vhost",
        "haproxy", "caddy", "xcconfig", "entitlements", "pbxproj", "xcstrings",
        "resolved", "lock", "sum", "mod", "work", "list", "sources", "repo", "zone",
        "pam", "cron", "awk", "sed", "jq", "vim", "el", "nix", "dhall", "cue", "rego",
        "graphql", "gql", "proto", "thrift", "avsc", "prisma", "dockerfile", "mk",
        "mak", "cmake", "gradle", "sbt", "cabal", "bazel", "bzl", "star", "gn", "gni",
        "ninja", "dotenv", "example", "sample", "template", "tmpl", "tpl", "j2", "jinja",
        "jinja2", "hbs", "mustache", "liquid", "ejs", "pug",
        // Scripts & source code
        "sh", "bash", "zsh", "fish", "ksh", "csh", "tcsh", "ps1", "psm1", "psd1",
        "bat", "cmd", "py", "pyi", "pyw", "rb", "erb", "rake", "gemspec", "pl", "pm",
        "php", "phtml", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "swift",
        "m", "mm", "c", "h", "cc", "cpp", "cxx", "hh", "hpp", "hxx", "go", "rs", "java",
        "kt", "kts", "scala", "sc", "groovy", "cs", "fs", "fsx", "vb", "dart", "zig",
        "v", "nim", "cr", "ex", "exs", "eex", "heex", "erl", "hrl", "hs", "lhs", "ml",
        "mli", "clj", "cljs", "cljc", "edn", "lisp", "lsp", "scm", "rkt", "lua", "r",
        "rmd", "jl", "sql", "psql", "mysql", "plsql", "vue", "svelte", "astro", "sol",
        "wgsl", "glsl", "hlsl", "metal", "asm", "s",
        // Markup / Web / Text / Certs
        "txt", "text", "md", "markdown", "mdx", "rst", "adoc", "asciidoc", "org", "tex",
        "latex", "bib", "html", "htm", "xhtml", "xml", "xsl", "xslt", "xsd", "svg",
        "css", "scss", "sass", "less", "styl", "csv", "tsv", "log", "out", "err",
        "diff", "patch", "pem", "crt", "cer", "csr", "pub", "asc", "ics", "vcf",
        "rss", "atom", "kml", "gpx", "srt", "vtt", "po", "pot", "strings", "sdef",
    ]
}

// MARK: - Text Document Decoding & Encoding

/// Round-trips text bytes through editing while preserving encoding, UTF-8 BOM, and line endings.
nonisolated struct EditableTextDocument: Equatable, Sendable {
    enum LineEnding: String, CaseIterable, Sendable {
        case lf = "LF"
        case crlf = "CRLF"
    }

    enum Encoding: String, CaseIterable, Sendable {
        case utf8 = "UTF-8"
        case utf8BOM = "UTF-8 BOM"
        case utf16BE = "UTF-16 BE"
        case utf16LE = "UTF-16 LE"
        case isoLatin1 = "ISO-8859-1"
    }

    enum Indentation: Equatable, Sendable {
        case tabs
        case spaces(Int)

        var insertString: String {
            switch self {
            case .tabs: "\t"
            case .spaces(let count): String(repeating: " ", count: count)
            }
        }
    }

    let text: String
    let encoding: Encoding
    let lineEnding: LineEnding

    private static let utf8BOMBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let utf16BEBOMBytes: [UInt8] = [0xFE, 0xFF]
    private static let utf16LEBOMBytes: [UInt8] = [0xFF, 0xFE]

    /// Decodes `data` into editable text with normalized `\n` line endings.
    static func decode(_ data: Data) -> EditableTextDocument? {
        guard !data.starts(with: Data("bplist".utf8)) else { return nil }

        let encoding: Encoding
        let rawString: String

        if data.starts(with: Self.utf8BOMBytes),
           let decoded = String(data: data.dropFirst(3), encoding: .utf8) {
            encoding = .utf8BOM
            rawString = decoded
        } else if data.starts(with: Self.utf16BEBOMBytes),
                  let decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            encoding = .utf16BE
            rawString = decoded
        } else if data.starts(with: Self.utf16LEBOMBytes),
                  let decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            encoding = .utf16LE
            rawString = decoded
        } else if let decoded = String(data: data, encoding: .utf8) {
            encoding = .utf8
            rawString = decoded
        } else if !data.contains(0x00),
                  let decoded = String(data: data, encoding: .isoLatin1) {
            encoding = .isoLatin1
            rawString = decoded
        } else {
            return nil
        }

        let lineEnding: LineEnding = detectLineEnding(in: rawString)
        let normalized = lineEnding == .crlf
            ? rawString.replacingOccurrences(of: "\r\n", with: "\n")
            : rawString

        return EditableTextDocument(text: normalized, encoding: encoding, lineEnding: lineEnding)
    }

    /// Re-encodes edited text (with `\n` newlines) using the original line ending and encoding.
    func encode(_ editedText: String) -> Data {
        let withEndings: String
        switch lineEnding {
        case .lf:
            withEndings = editedText
        case .crlf:
            let normalized = editedText.replacingOccurrences(of: "\r\n", with: "\n")
            withEndings = normalized.replacingOccurrences(of: "\n", with: "\r\n")
        }

        switch encoding {
        case .utf8:
            return Data(withEndings.utf8)
        case .utf8BOM:
            var out = Data(Self.utf8BOMBytes)
            out.append(Data(withEndings.utf8))
            return out
        case .utf16BE:
            var out = Data(Self.utf16BEBOMBytes)
            if let body = withEndings.data(using: .utf16BigEndian) { out.append(body) }
            return out
        case .utf16LE:
            var out = Data(Self.utf16LEBOMBytes)
            if let body = withEndings.data(using: .utf16LittleEndian) { out.append(body) }
            return out
        case .isoLatin1:
            // Upgrade to UTF-8 if the user inserted characters ISO-8859-1 cannot represent.
            return withEndings.data(using: .isoLatin1) ?? Data(withEndings.utf8)
        }
    }

    /// Detects whether the file predominantly uses tabs, 2 spaces, or 4 spaces.
    static func detectIndentation(in text: String, filename: String) -> Indentation {
        let lower = filename.lowercased()
        if lower == "makefile" || lower == "gnumakefile" || lower.hasSuffix(".mk") || lower.hasSuffix(".go") {
            return .tabs
        }
        var tabLines = 0
        var spaceIndents: [Int] = []
        for line in text.split(separator: "\n", maxSplits: 200) {
            guard let first = line.first else { continue }
            if first == "\t" {
                tabLines += 1
            } else if first == " " {
                let count = line.prefix(while: { $0 == " " }).count
                if count > 0, count <= 8, count < line.count {
                    spaceIndents.append(count)
                }
            }
        }
        if tabLines > spaceIndents.count, tabLines > 0 { return .tabs }
        if !spaceIndents.isEmpty {
            let twoSpaceCount = spaceIndents.filter { $0 == 2 }.count
            let fourSpaceCount = spaceIndents.filter { $0 == 4 }.count
            if twoSpaceCount > 0 && twoSpaceCount >= fourSpaceCount { return .spaces(2) }
            if fourSpaceCount > 0 { return .spaces(4) }
        }
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "json", "jsonc", "json5", "yml", "yaml", "html", "htm", "xml", "css", "scss", "js", "jsx", "ts", "tsx", "rb":
            return .spaces(2)
        default:
            return .spaces(4)
        }
    }

    /// Computes a SHA-256 digest for change detection.
    static func contentDigest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func detectLineEnding(in string: String) -> LineEnding {
        var crlfCount = 0
        var lfOnlyCount = 0
        var prevWasCR = false
        for byte in string.utf8.prefix(16_384) {
            if byte == 0x0A {
                if prevWasCR { crlfCount += 1 } else { lfOnlyCount += 1 }
            }
            prevWasCR = (byte == 0x0D)
        }
        return crlfCount > lfOnlyCount ? .crlf : .lf
    }
}

// MARK: - Remote Conflict Detection

/// Metadata snapshot of a remote file used to catch concurrent edits before overwriting.
nonisolated struct RemoteFileFingerprint: Codable, Equatable, Sendable {
    enum TimestampPrecision: String, Codable, Sendable, Equatable {
        /// SFTP v3, local stat tv_sec, and HTTP Last-Modified all use 1-second resolution.
        case wholeSecond
        /// Sub-second exact comparison.
        case exact
    }

    let size: UInt64
    let modified: Date?
    let eTag: String?
    let precision: TimestampPrecision

    init(
        size: UInt64,
        modified: Date?,
        eTag: String? = nil,
        precision: TimestampPrecision = .wholeSecond
    ) {
        self.size = size
        self.modified = modified
        self.eTag = eTag
        self.precision = precision
    }

    /// True when `other` represents a different server-side revision than `self`.
    func differs(from other: RemoteFileFingerprint) -> Bool {
        if let lhsTag = eTag, let rhsTag = other.eTag {
            return lhsTag != rhsTag
        }
        if size != other.size { return true }
        switch (modified, other.modified) {
        case (let lhsDate?, let rhsDate?):
            let effective: TimestampPrecision = (precision == .exact && other.precision == .exact) ? .exact : .wholeSecond
            switch effective {
            case .wholeSecond:
                let lhsSec = Int64(lhsDate.timeIntervalSince1970.rounded(.down))
                let rhsSec = Int64(rhsDate.timeIntervalSince1970.rounded(.down))
                return lhsSec != rhsSec
            case .exact:
                return lhsDate != rhsDate
            }
        case (nil, nil):
            return false
        default:
            return true
        }
    }
}

// MARK: - Staging Cleanup Safety

nonisolated enum FileEditStagingPath {
    /// True only when `directory` is a direct child of `stagingRoot`, ensuring
    /// cleanup never deletes an arbitrary user folder if a staged file was moved.
    static func isDirectChild(_ directory: URL, of stagingRoot: URL) -> Bool {
        let dir = directory.standardizedFileURL
        let root = stagingRoot.standardizedFileURL
        guard dir.path != root.path else { return false }
        return dir.deletingLastPathComponent().path == root.path
    }
}

/// Persisted per-staging-folder sync manifest so relaunch cleanup only removes working
/// copies whose last upload was confirmed and whose on-disk bytes remain unchanged.
nonisolated struct StagingFolderManifest: Codable, Equatable, Sendable {
    let folderName: String
    let fileName: String
    let lastSyncedHashHex: String
    let hasPendingUpload: Bool
    let endpointDisplayName: String
    let remotePath: String
}

/// A staged working copy preserved across app relaunch because its edits were never
/// confirmed uploaded (e.g., Rootshell quit during an upload, conflict, or offline edit).
nonisolated struct PreservedUnsyncedEdit: Identifiable, Equatable, Sendable {
    var id: String { folderURL.path }
    let folderURL: URL
    /// Every entry in `folderURL` (including hidden files such as `.env` or Vim `.swp`),
    /// with the primary tracked file first when present so users can export the whole folder
    /// or pick any individual file.
    let files: [URL]
    let fileName: String
    let endpointDisplayName: String?
    let remotePath: String?

    var fileURL: URL? { files.first }
}

nonisolated enum FileEditStagingCleanup {
    static let manifestsDirectoryName = ".manifests"

    static func manifestsDirectory(in stagingRoot: URL) -> URL {
        stagingRoot.appendingPathComponent(manifestsDirectoryName, isDirectory: true)
    }

    static func manifestURL(forFolderName folderName: String, in stagingRoot: URL) -> URL {
        manifestsDirectory(in: stagingRoot).appendingPathComponent("\(folderName).json", isDirectory: false)
    }

    static func hexDigest(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func writeManifest(_ manifest: StagingFolderManifest, in stagingRoot: URL) {
        let dir = manifestsDirectory(in: stagingRoot)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL(forFolderName: manifest.folderName, in: stagingRoot), options: .atomic)
        } catch {
            // Fail-safe: if manifest persistence fails, relaunch cleanup treats the folder
            // as unproven and preserves it rather than risking deleting local edits.
        }
    }

    static func removeManifest(forFolderName folderName: String, in stagingRoot: URL) {
        try? FileManager.default.removeItem(at: manifestURL(forFolderName: folderName, in: stagingRoot))
    }

    /// Returns `true` ONLY after a successful full directory listing (`options: []`, including
    /// hidden files) confirming `directory` is empty or contains solely `expectedFileName`.
    /// Prevents clean-stop or relaunch cleanup from deleting editor swap/backup files (e.g. Vim `.swp`).
    static func directoryContainsOnly(_ expectedFileName: String?, in directory: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        if contents.isEmpty { return true }
        guard let expectedFileName else { return false }
        return contents.count == 1 && contents[0].lastPathComponent == expectedFileName
    }

    /// Scans `stagingRoot` on launch: deletes ONLY session folders after a successful full
    /// directory listing (including hidden files) that accounts for EVERY entry in the folder
    /// and proves no unsynced local changes or editor swap files remain. Preserves every other
    /// folder intact and returns descriptors for the preserved working copies.
    @discardableResult
    static func pruneSyncedFolders(in stagingRoot: URL) -> [PreservedUnsyncedEdit] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        var preservedFolderNames: Set<String> = []
        var preserved: [PreservedUnsyncedEdit] = []

        for entry in entries {
            let folderName = entry.lastPathComponent
            if folderName == manifestsDirectoryName { continue }
            guard FileEditStagingPath.isDirectChild(entry, of: stagingRoot) else { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let manifestPath = manifestURL(forFolderName: folderName, in: stagingRoot)
            let manifest: StagingFolderManifest?
            if let manifestData = try? Data(contentsOf: manifestPath),
               let decoded = try? JSONDecoder().decode(StagingFolderManifest.self, from: manifestData),
               decoded.folderName == folderName {
                manifest = decoded
            } else {
                manifest = nil
            }

            // Require a successful full directory listing (never skipping hidden files like `.env`
            // or Vim `.swp` files, and never treating a listing error as an empty folder).
            guard let folderContents = try? fm.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                preservedFolderNames.insert(folderName)
                preserved.append(PreservedUnsyncedEdit(
                    folderURL: entry,
                    files: [],
                    fileName: manifest?.fileName ?? folderName,
                    endpointDisplayName: manifest?.endpointDisplayName,
                    remotePath: manifest?.remotePath
                ))
                continue
            }

            let sortedContents = folderContents.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            if let manifest {
                var canDelete = false
                if !manifest.hasPendingUpload {
                    if sortedContents.isEmpty {
                        // File was moved out and ZERO files (hidden or visible) remain in the folder.
                        canDelete = true
                    } else if sortedContents.count == 1,
                              sortedContents[0].lastPathComponent == manifest.fileName,
                              let diskData = try? Data(contentsOf: sortedContents[0]) {
                        // Only the tracked file exists in the folder and its bytes match the last confirmed upload.
                        let diskHash = hexDigest(EditableTextDocument.contentDigest(diskData))
                        if diskHash == manifest.lastSyncedHashHex {
                            canDelete = true
                        }
                    }
                }

                if canDelete {
                    try? fm.removeItem(at: entry)
                    try? fm.removeItem(at: manifestPath)
                } else {
                    preservedFolderNames.insert(folderName)
                    let orderedFiles: [URL]
                    if let primaryIdx = sortedContents.firstIndex(where: { $0.lastPathComponent == manifest.fileName }) {
                        var reordered = sortedContents
                        let primary = reordered.remove(at: primaryIdx)
                        reordered.insert(primary, at: 0)
                        orderedFiles = reordered
                    } else {
                        orderedFiles = sortedContents
                    }
                    preserved.append(PreservedUnsyncedEdit(
                        folderURL: entry,
                        files: orderedFiles,
                        fileName: orderedFiles.first?.lastPathComponent ?? manifest.fileName,
                        endpointDisplayName: manifest.endpointDisplayName,
                        remotePath: manifest.remotePath
                    ))
                }
            } else {
                // Missing or unreadable manifest: delete ONLY if the full listing confirmed the folder is truly empty.
                if sortedContents.isEmpty {
                    try? fm.removeItem(at: entry)
                } else {
                    preservedFolderNames.insert(folderName)
                    preserved.append(PreservedUnsyncedEdit(
                        folderURL: entry,
                        files: sortedContents,
                        fileName: sortedContents.first?.lastPathComponent ?? folderName,
                        endpointDisplayName: nil,
                        remotePath: nil
                    ))
                }
            }
        }

        // Clean up orphaned manifests whose staging folders no longer exist.
        let manifestsDir = manifestsDirectory(in: stagingRoot)
        if let manifests = try? fm.contentsOfDirectory(at: manifestsDir, includingPropertiesForKeys: nil, options: []) {
            for manifestFile in manifests where manifestFile.pathExtension == "json" {
                let name = manifestFile.deletingPathExtension().lastPathComponent
                if !preservedFolderNames.contains(name) {
                    try? fm.removeItem(at: manifestFile)
                }
            }
        }

        return preserved.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }
}

/// Strict POSIX file-type classification from SFTP `permissions` (`st_mode`).
/// Servers that omit `permissions` or send zero type bits map to `.unknown` rather than
/// being assumed regular files, preventing overwrites of unconfirmed symlinks or directories.
nonisolated enum SFTPFileType: Equatable, Sendable {
    case regularFile
    case directory
    case symlink
    case other
    case unknown

    init(permissions: UInt32?) {
        guard let mode = permissions else {
            self = .unknown
            return
        }
        switch mode & 0o170000 {
        case 0o100000: self = .regularFile
        case 0o040000: self = .directory
        case 0o120000: self = .symlink
        case 0: self = .unknown
        default: self = .other
        }
    }
}

/// POSIX UID/GID pair verified before committing an SFTP staged replacement so a save
/// never silently changes file ownership (including when the server omits UID/GID on an existing file).
nonisolated struct SFTPOwnership: Equatable, Sendable {
    let uid: UInt32
    let gid: UInt32

    /// Returns `true` only when creating a new file (`replacingExistingFile == false`), or when
    /// replacing an existing file and BOTH `original` and `staged` UID/GID were reported and match.
    static func preservesOwnership(
        replacingExistingFile: Bool,
        original: SFTPOwnership?,
        staged: SFTPOwnership?
    ) -> Bool {
        guard replacingExistingFile else { return true }
        guard let original, let staged else { return false }
        return original == staged
    }
}

/// POSIX permission bits (`st_mode & 0o7777`) verified before committing an SFTP staged
/// replacement so a save can neither silently drop permissions nor undo a concurrent `chmod`.
nonisolated enum SFTPPermissions {
    static let mask: UInt32 = 0o7777

    static func modeBits(from permissions: UInt32?) -> UInt32? {
        permissions.map { $0 & mask }
    }

    /// Returns `true` ONLY when the server explicitly reported permission bits AND all
    /// group/other access bits (`0o077`) are zero. Omitted (`nil`) permissions return `false`
    /// so upload never starts with unverified staging access.
    static func isPrivateStagingMode(_ permissions: UInt32?) -> Bool {
        guard let mode = modeBits(from: permissions) else { return false }
        return (mode & 0o077) == 0
    }

    /// Returns `true` only when creating a new file (`replacingExistingFile == false`), or when
    /// replacing an existing file and BOTH `original` and `staged` permission bits were reported and match.
    static func preservesPermissions(
        replacingExistingFile: Bool,
        original: UInt32?,
        staged: UInt32?
    ) -> Bool {
        guard replacingExistingFile else { return true }
        guard let original, let staged else { return false }
        return (original & mask) == (staged & mask)
    }
}

// MARK: - Recovery Identity & Interrupted SFTP Swap Journal

nonisolated enum FileEditRecoveryKey {
    struct JumpHop: Equatable, Sendable {
        let host: String
        let port: Int
        let username: String
    }

    /// Canonical key matching SSHConfig's account + jump-chain identity (plus sudo scope),
    /// serialized as JSON so special characters in usernames or hosts can never collide.
    static func ssh(
        host: String,
        port: Int,
        username: String,
        isSudo: Bool,
        jumpHops: [JumpHop]
    ) -> String {
        var components: [String] = [
            "ssh",
            isSudo ? "sudo" : "user",
            host.lowercased(),
            String(port),
            username,
        ]
        for hop in jumpHops {
            components.append(hop.host.lowercased())
            components.append(String(hop.port))
            components.append(hop.username)
        }
        guard let data = try? JSONEncoder().encode(components),
              let encoded = String(data: data, encoding: .utf8) else {
            return components.joined(separator: "\u{1F}")
        }
        return encoded
    }
}

/// Tracks an in-progress SFTP backup-and-swap commit so that if the connection
/// drops between `rename(target -> backup)` and `rename(temp -> target)`,
/// reconnecting restores the live file from `backupPath` or flags a conflict
/// without deleting either recoverable copy.
nonisolated struct PendingSFTPSwapRecord: Codable, Equatable, Sendable {
    let endpointKey: String
    let targetPath: String
    let backupPath: String
    let tempPath: String
    /// Verified server-side fingerprint of `tempPath` captured before commit.
    /// Used during recovery to distinguish a completed `rename(temp -> target)`
    /// (that dropped before `remove(backup)`) from a file created by another writer.
    let stagedFingerprint: RemoteFileFingerprint?

    init(
        endpointKey: String,
        targetPath: String,
        backupPath: String,
        tempPath: String,
        stagedFingerprint: RemoteFileFingerprint? = nil
    ) {
        self.endpointKey = endpointKey
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.tempPath = tempPath
        self.stagedFingerprint = stagedFingerprint
    }
}

/// Pure decision logic for reconciling an interrupted SFTP backup-and-swap record.
/// Preserves both copies and reports a conflict whenever target existence alone cannot
/// prove that our staged replacement was installed.
nonisolated enum SFTPRecoveryPlanner {
    enum TargetState: Equatable, Sendable {
        case missing
        case regularFile(RemoteFileFingerprint)
        /// Directory, symlink, device, or incomplete stat attributes.
        case other
    }

    enum Action: Equatable, Sendable {
        /// Target is missing while backup exists: rename backup back to target, clean up temp, clear journal.
        case restoreBackup
        /// Backup is absent (swap never moved original, or already cleaned up backup): clean leftover temp if present, clear journal.
        case clearOnly(removeTemp: Bool)
        /// Temp was consumed and target is a regular file whose server-side size & mtime match `stagedFingerprint`:
        /// remove the now-redundant backup and clear journal.
        case finalizeInstalledEdit
        /// Both target and backup exist, and we cannot establish that target is our installed staged edit
        /// (e.g., another process created target while original was at backup, or target changed afterwards).
        /// Preserve BOTH target and backup (and temp if present), retain journal, and report conflict.
        case conflict(hasStagedCopy: Bool)
    }

    static func decide(
        target: TargetState,
        backupExists: Bool,
        tempExists: Bool,
        stagedFingerprint: RemoteFileFingerprint?
    ) -> Action {
        guard backupExists else {
            return .clearOnly(removeTemp: tempExists)
        }
        if target == .missing {
            return .restoreBackup
        }
        if case .regularFile(let current) = target,
           !tempExists,
           let expected = stagedFingerprint,
           expected.modified != nil,
           !current.differs(from: expected) {
            return .finalizeInstalledEdit
        }
        return .conflict(hasStagedCopy: tempExists)
    }
}

/// Serializes recovery and SFTP swap commits per `(endpointKey, targetPath)` so a concurrent
/// reader or reconnect sweep can never race against an active save's staged temp file or journal.
actor SFTPPathOperationGate {
    static let shared = SFTPPathOperationGate()

    private nonisolated struct Key: Hashable, Sendable {
        let endpointKey: String
        let targetPath: String
    }

    private var locked: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated func withLock<T>(
        endpointKey: String,
        targetPath: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let key = Key(endpointKey: endpointKey, targetPath: targetPath)
        await acquire(key)
        do {
            let result = try await body()
            await release(key)
            return result
        } catch {
            await release(key)
            throw error
        }
    }

    private func acquire(_ key: Key) async {
        while locked.contains(key) {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
        }
        locked.insert(key)
    }

    private func release(_ key: Key) {
        locked.remove(key)
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty {
                waiters.removeValue(forKey: key)
            } else {
                waiters[key] = queue
            }
            next.resume()
        }
    }
}

actor RemoteSaveRecoveryStore {
    static let shared = RemoteSaveRecoveryStore(fileURL: defaultFileURL())

    private let fileURL: URL
    private var records: [PendingSFTPSwapRecord]
    private var loaded = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.records = []
    }

    /// Persists `entry` atomically to disk before returning. Throws if the journal
    /// cannot be loaded or written so callers never proceed with an unpersisted swap.
    func record(_ entry: PendingSFTPSwapRecord) throws {
        try loadIfNeededStrict()
        var updated = records
        updated.removeAll { $0.endpointKey == entry.endpointKey && $0.targetPath == entry.targetPath }
        updated.append(entry)
        try persist(updated)
        records = updated
    }

    func record(forEndpointKey endpointKey: String, targetPath: String) -> PendingSFTPSwapRecord? {
        loadIfNeededBestEffort()
        return records.first { $0.endpointKey == endpointKey && $0.targetPath == targetPath }
    }

    /// Strict check confirming whether any pending swap record for `endpointKey` references
    /// `tempPath`. Throws if the swap journal exists on disk but cannot be loaded or decoded,
    /// so orphaned-temp cleanup never deletes a file when the swap journal is unreadable.
    func referencesTempPathStrict(endpointKey: String, tempPath: String) throws -> Bool {
        try loadIfNeededStrict()
        return records.contains { $0.endpointKey == endpointKey && $0.tempPath == tempPath }
    }

    func allRecords(forEndpointKey endpointKey: String) -> [PendingSFTPSwapRecord] {
        loadIfNeededBestEffort()
        return records.filter { $0.endpointKey == endpointKey }
    }

    func clear(endpointKey: String, targetPath: String) {
        loadIfNeededBestEffort()
        var updated = records
        updated.removeAll { $0.endpointKey == endpointKey && $0.targetPath == targetPath }
        guard updated.count != records.count else { return }
        records = updated
        try? persist(updated)
    }

    private func loadIfNeededStrict() throws {
        guard !loaded else { return }
        records = try LocalJournalFileIO.loadRecords(from: fileURL)
        loaded = true
    }

    private func loadIfNeededBestEffort() {
        guard !loaded else { return }
        if let decoded: [PendingSFTPSwapRecord] = try? LocalJournalFileIO.loadRecords(from: fileURL) {
            records = decoded
            loaded = true
        }
    }

    private func persist(_ items: [PendingSFTPSwapRecord]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FileManagerEditRecovery.json", isDirectory: false)
    }
}

/// Shared journal reader that reads the file directly without calling `fileExists`,
/// treating ONLY confirmed missing-file errors (`ENOENT` / `NSFileReadNoSuchFileError`)
/// as an empty journal so inaccessible directories are never cached as empty.
private nonisolated enum LocalJournalFileIO {
    static func isNotFound(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError) {
            return true
        }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, isNotFound(underlying) {
            return true
        }
        return false
    }

    static func loadRecords<T: Decodable>(from fileURL: URL) throws -> [T] {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            if isNotFound(error) {
                return []
            }
            throw error
        }
    }
}

/// Tracks an uncommitted SFTP staged temporary file independently of the swap journal so
/// if a save fails or disconnects (e.g. during recovery or upload) and immediate removal
/// fails, a future reconnect retries deleting the orphaned temporary file.
nonisolated struct PendingSFTPTempRecord: Codable, Equatable, Sendable {
    let endpointKey: String
    let targetPath: String
    let tempPath: String
}

actor RemoteStagedTempStore {
    static let shared = RemoteStagedTempStore(fileURL: defaultFileURL())

    private nonisolated struct ActiveKey: Hashable, Sendable {
        let endpointKey: String
        let tempPath: String
    }

    private let fileURL: URL
    private var records: [PendingSFTPTempRecord] = []
    private var activeInProcess: Set<ActiveKey> = []
    private var loaded = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Durably records `entry` on disk and marks it active in this process so reconnect
    /// sweeps never delete an actively uploading temporary file.
    func trackActive(_ entry: PendingSFTPTempRecord) throws {
        try loadIfNeededStrict()
        var updated = records
        updated.removeAll { $0.endpointKey == entry.endpointKey && $0.tempPath == entry.tempPath }
        updated.append(entry)
        try persist(updated)
        records = updated
        activeInProcess.insert(ActiveKey(endpointKey: entry.endpointKey, tempPath: entry.tempPath))
    }

    /// Removes `tempPath` from both active tracking and persistent storage once it has been
    /// installed, confirmed removed, or handed off to `RemoteSaveRecoveryStore`.
    func markCompleted(endpointKey: String, tempPath: String) {
        loadIfNeededBestEffort()
        activeInProcess.remove(ActiveKey(endpointKey: endpointKey, tempPath: tempPath))
        var updated = records
        updated.removeAll { $0.endpointKey == endpointKey && $0.tempPath == tempPath }
        guard updated.count != records.count else { return }
        records = updated
        try? persist(updated)
    }

    /// Clears the in-process active mark while retaining the persisted record on disk so
    /// future reconnects retry deleting `tempPath`.
    func releaseActiveKeepingRecord(endpointKey: String, tempPath: String) {
        activeInProcess.remove(ActiveKey(endpointKey: endpointKey, tempPath: tempPath))
    }

    /// Returns persisted temp records for `endpointKey` that are NOT currently active in this process.
    func orphanedRecords(forEndpointKey endpointKey: String) -> [PendingSFTPTempRecord] {
        loadIfNeededBestEffort()
        return records.filter {
            $0.endpointKey == endpointKey
                && !activeInProcess.contains(ActiveKey(endpointKey: $0.endpointKey, tempPath: $0.tempPath))
        }
    }

    func isOrphaned(endpointKey: String, tempPath: String) -> Bool {
        loadIfNeededBestEffort()
        let key = ActiveKey(endpointKey: endpointKey, tempPath: tempPath)
        guard !activeInProcess.contains(key) else { return false }
        return records.contains { $0.endpointKey == endpointKey && $0.tempPath == tempPath }
    }

    private func loadIfNeededStrict() throws {
        guard !loaded else { return }
        records = try LocalJournalFileIO.loadRecords(from: fileURL)
        loaded = true
    }

    private func loadIfNeededBestEffort() {
        guard !loaded else { return }
        if let decoded: [PendingSFTPTempRecord] = try? LocalJournalFileIO.loadRecords(from: fileURL) {
            records = decoded
            loaded = true
        }
    }

    private func persist(_ items: [PendingSFTPTempRecord]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FileManagerEditStagedTemps.json", isDirectory: false)
    }
}

// MARK: - Byte-exact Remote Path Identity

/// Byte-exact UTF-8 path matching for active remote edit sessions and in-flight
/// opens so canonically equivalent keys (such as NFC vs NFD on S3/Ceph) never
/// reuse each other's working copy or upload to the wrong object.
nonisolated enum RemoteEditPathIdentity {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func key(endpointKey: String, path: String) -> String {
        let hex = Data(path.utf8).map { String(format: "%02x", $0) }.joined()
        return "\(endpointKey)|\(hex)"
    }
}

// MARK: - JSON Formatting

nonisolated enum FileEditJSONFormatter {
    enum FormatError: LocalizedError {
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .invalidJSON(let reason):
                String(localized: "Invalid JSON: \(reason)", comment: "File editor JSON format error")
            }
        }
    }

    /// Validates and pretty-prints JSON text with 2-space indentation.
    static func prettyPrint(_ text: String) throws -> String {
        let data = Data(text.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw FormatError.invalidJSON(error.localizedDescription)
        }
        let formatted = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        var result = String(decoding: formatted, as: UTF8.self)
        if !result.hasSuffix("\n") { result.append("\n") }
        return result
    }
}

// MARK: - Line Index (O(log L) UTF-16 Line & Column Lookup)

/// Tracks the UTF-16 starting offset of every logical line (`lineStarts[0] == 0`).
/// Rebuilt on document load and updated incrementally on edits so scrolling and
/// cursor movement never bridge or rescan the full text buffer.
nonisolated struct EditorLineIndex: Equatable, Sendable {
    /// UTF-16 code-unit offset of the first character of each 0-based line.
    /// Always non-empty (`[0]` for an empty document).
    private(set) var lineStarts: [Int]
    /// Total UTF-16 code-unit length of the indexed text.
    private(set) var utf16Length: Int

    var lineCount: Int { lineStarts.count }
    var endsWithNewline: Bool { utf16Length > 0 && lineStarts.last == utf16Length }

    init() {
        self.lineStarts = [0]
        self.utf16Length = 0
    }

    init(text: String) {
        var starts: [Int] = [0]
        var utf16Offset = 0

        let indexedFast = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            starts.reserveCapacity(max(16, bytes.count / 40))
            let count = bytes.count
            var i = 0
            while i < count {
                let byte = bytes[i]
                if byte < 0x80 {
                    utf16Offset += 1
                    if byte == 0x0A {
                        starts.append(utf16Offset)
                    } else if byte == 0x0D && (i + 1 >= count || bytes[i + 1] != 0x0A) {
                        starts.append(utf16Offset)
                    }
                } else if byte == 0xE2 && i + 2 < count && bytes[i + 1] == 0x80 && bytes[i + 2] == 0xA9 {
                    // Unicode paragraph separator (U+2029), treated by TextKit as a paragraph break.
                    utf16Offset += 1
                    starts.append(utf16Offset)
                    i += 3
                    continue
                } else if byte >= 0xF0 {
                    utf16Offset += 2
                } else if byte >= 0xC0 {
                    utf16Offset += 1
                }
                i += 1
            }
            return true
        } ?? false

        if !indexedFast {
            var prevWasCR = false
            for unit in text.utf16 {
                if prevWasCR && unit != 0x0A {
                    starts.append(utf16Offset)
                }
                utf16Offset += 1
                if unit == 0x0A || unit == 0x2029 {
                    starts.append(utf16Offset)
                    prevWasCR = false
                } else {
                    prevWasCR = (unit == 0x0D)
                }
            }
            if prevWasCR {
                starts.append(utf16Offset)
            }
        }

        self.lineStarts = starts
        self.utf16Length = utf16Offset
    }

    init(nsString: NSString) {
        let totalLength = nsString.length
        var starts: [Int] = [0]
        starts.reserveCapacity(max(16, totalLength / 40))

        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var offset = 0
        var prevWasCR = false
        while offset < totalLength {
            let count = min(chunkSize, totalLength - offset)
            nsString.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for i in 0..<count {
                let unit = buffer[i]
                if prevWasCR && unit != 0x0A {
                    starts.append(offset + i)
                }
                if unit == 0x0A || unit == 0x2029 {
                    starts.append(offset + i + 1)
                    prevWasCR = false
                } else {
                    prevWasCR = (unit == 0x0D)
                }
            }
            offset += count
        }
        if prevWasCR {
            starts.append(totalLength)
        }

        self.lineStarts = starts
        self.utf16Length = totalLength
    }

    /// Incrementally updates `lineStarts` after an `NSTextStorage` edit.
    /// `editedRange` is the post-edit range in `nsString`; `changeInLength` is `newLength - oldLength`.
    mutating func applyEdit(editedRange: NSRange, changeInLength: Int, in nsString: NSString) {
        let newTotalLength = nsString.length
        let oldEditedLength = editedRange.length - changeInLength
        guard editedRange.location >= 0,
              oldEditedLength >= 0,
              NSMaxRange(editedRange) <= newTotalLength,
              !(editedRange.location == 0 && editedRange.length == newTotalLength) else {
            self = EditorLineIndex(nsString: nsString)
            return
        }

        let editStart = editedRange.location
        let oldEnd = editStart + oldEditedLength
        let newEnd = NSMaxRange(editedRange)

        // Include 1 character before editStart so a preceding CR that gains or loses a following LF
        // is re-evaluated cleanly alongside the edited slice.
        let scanStart = max(0, editStart - 1)

        // Old line starts produced by breaks in [scanStart, oldEnd) lie in (scanStart, oldEnd].
        let firstRemoved = firstIndexGreaterThan(scanStart)
        let afterRemoved = firstIndexGreaterThan(oldEnd, startingAt: firstRemoved)

        // Scan only [scanStart, newEnd) for LF, U+2029, and standalone CR breaks.
        var insertedStarts: [Int] = []
        let scanLength = newEnd - scanStart
        if scanLength > 0 {
            let chunkSize = min(4096, scanLength)
            var buffer = [unichar](repeating: 0, count: chunkSize)
            var offset = scanStart
            var prevWasCR = false
            while offset < newEnd {
                let count = min(chunkSize, newEnd - offset)
                nsString.getCharacters(&buffer, range: NSRange(location: offset, length: count))
                for i in 0..<count {
                    let unit = buffer[i]
                    if prevWasCR && unit != 0x0A {
                        insertedStarts.append(offset + i)
                    }
                    if unit == 0x0A || unit == 0x2029 {
                        insertedStarts.append(offset + i + 1)
                        prevWasCR = false
                    } else {
                        prevWasCR = (unit == 0x0D)
                    }
                }
                offset += count
            }
            if prevWasCR && (newEnd == newTotalLength || nsString.character(at: newEnd) != 0x0A) {
                insertedStarts.append(newEnd)
            }
        }

        if changeInLength != 0 && afterRemoved < lineStarts.count {
            for i in afterRemoved..<lineStarts.count {
                lineStarts[i] += changeInLength
            }
        }

        if firstRemoved != afterRemoved || !insertedStarts.isEmpty {
            lineStarts.replaceSubrange(firstRemoved..<afterRemoved, with: insertedStarts)
        }

        utf16Length = newTotalLength
    }

    /// 1-based line number containing `utf16Offset`.
    func lineNumber(forUTF16Offset utf16Offset: Int) -> Int {
        lineIndex(forUTF16Offset: utf16Offset) + 1
    }

    /// 1-based line and column (in UTF-16 code units) for `utf16Offset`.
    func lineAndColumn(forUTF16Offset utf16Offset: Int) -> (line: Int, column: Int) {
        let clamped = max(0, min(utf16Offset, utf16Length))
        let idx = lineIndex(forUTF16Offset: clamped)
        return (line: idx + 1, column: (clamped - lineStarts[idx]) + 1)
    }

    /// 0-based index into `lineStarts` for the line containing `utf16Offset`.
    private func lineIndex(forUTF16Offset utf16Offset: Int) -> Int {
        let clamped = max(0, min(utf16Offset, utf16Length))
        var lo = 0
        var hi = lineStarts.count - 1
        while lo < hi {
            let mid = lo + (hi - lo + 1) / 2
            if lineStarts[mid] <= clamped {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// Smallest index >= `startingAt` (and >= 1) whose value is strictly greater than `target`.
    private func firstIndexGreaterThan(_ target: Int, startingAt start: Int = 1) -> Int {
        var lo = max(1, start)
        var hi = lineStarts.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if lineStarts[mid] <= target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}

#if canImport(UIKit)
// MARK: - Visible Gutter Line Layout (Shared with Tests)

struct EditorVisibleGutterLine: Equatable {
    let lineNumber: Int
    let minY: CGFloat
    let height: CGFloat
}

@MainActor
enum EditorGutterLayout {
    /// Computes the visible logical line numbers and their container-relative Y bounds for a
    /// TextKit 1 `UITextView`. During active drag/deceleration (`allowLayout == false`), uses
    /// `glyphRange(forBoundingRectWithoutAdditionalLayout:in:)` so scrolling never triggers layout.
    /// After a programmatic jump or when scrolling settles (`allowLayout == true`), ensures layout
    /// for the visible query rect so noncontiguous documents never leave the gutter blank.
    static func visibleLines(
        in textView: UITextView,
        lineIndex: EditorLineIndex,
        editorLineHeight: CGFloat,
        overscan: CGFloat = 48,
        allowLayout: Bool
    ) -> [EditorVisibleGutterLine] {
        let totalLength = textView.textStorage.length
        if totalLength == 0 || lineIndex.utf16Length == 0 {
            return [EditorVisibleGutterLine(lineNumber: 1, minY: 0, height: editorLineHeight)]
        }

        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        let insetTop = textView.textContainerInset.top
        let offsetY = textView.contentOffset.y

        let visibleMinY = offsetY - insetTop - overscan
        let visibleMaxY = offsetY + textView.bounds.height - insetTop + overscan
        let queryMinY = max(0, visibleMinY)
        let queryHeight = max(1, visibleMaxY - queryMinY)
        // Line fragments always begin at x = 0 in textContainer coordinates.
        let queryRect = CGRect(
            x: 0,
            y: queryMinY,
            width: max(1, textView.bounds.width),
            height: queryHeight
        )

        if allowLayout {
            layoutManager.ensureLayout(forBoundingRect: queryRect, in: textContainer)
        }
        let visibleGlyphRange = allowLayout
            ? layoutManager.glyphRange(forBoundingRect: queryRect, in: textContainer)
            : layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: queryRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var result: [EditorVisibleGutterLine] = []

        if visibleGlyphRange.length > 0 {
            let firstLineIdx = max(0, lineIndex.lineNumber(forUTF16Offset: visibleCharRange.location) - 1)
            let maxChar = NSMaxRange(visibleCharRange)
            let totalGlyphs = layoutManager.numberOfGlyphs

            for idx in firstLineIdx..<lineIndex.lineCount {
                let charStart = lineIndex.lineStarts[idx]
                if charStart >= totalLength { break }
                if charStart > maxChar { break }

                let glyphIndex = layoutManager.glyphIndexForCharacter(at: charStart)
                guard glyphIndex < totalGlyphs else { break }

                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: nil,
                    withoutAdditionalLayout: !allowLayout
                )
                guard lineRect.height > 0 else { continue }
                if lineRect.minY > visibleMaxY { break }
                guard lineRect.maxY >= visibleMinY else { continue }

                result.append(EditorVisibleGutterLine(
                    lineNumber: idx + 1,
                    minY: lineRect.minY,
                    height: lineRect.height
                ))
            }
        }

        // Trailing empty line after a final line break (LF, CR, CRLF, or U+2029).
        if lineIndex.endsWithNewline {
            let extraRect = layoutManager.extraLineFragmentRect
            if extraRect.height > 0,
               extraRect.maxY >= visibleMinY,
               extraRect.minY <= visibleMaxY {
                result.append(EditorVisibleGutterLine(
                    lineNumber: lineIndex.lineCount,
                    minY: extraRect.minY,
                    height: extraRect.height
                ))
            }
        }

        return result
    }
}
#endif
