//
//  ProgramCatalog.swift
//  rootshell
//
//  Normalized command name → display identity and logo for shells and
//  ordinary programs. Code rather than manifest data for the same reason as
//  `AgentBrandMark.assetNames`: an unknown name must degrade to no mark,
//  never to a missing-asset box.
//

import Foundation

nonisolated enum ProgramCatalog {
    enum Kind: Sendable {
        case shell
        case program
        /// Hosts other programs for a whole session, so it never gets a Running card.
        case multiplexer
    }

    struct Entry: Equatable, Sendable {
        let id: String
        let displayName: String
        let mark: BrandMark?
        let kind: Kind
    }

    /// Shells without a usable logo share the terminal glyph, so a prompt
    /// still reads as a shell.
    private static let genericShellMark = BrandMark.symbol("terminal")

    private static let entries: [Entry] = [
        Entry(id: "bash", displayName: "bash", mark: .asset("BashLogo"), kind: .shell),
        Entry(id: "zsh", displayName: "zsh", mark: .template("ZshLogo"), kind: .shell),
        Entry(id: "fish", displayName: "fish", mark: .asset("FishLogo"), kind: .shell),
        Entry(id: "nushell", displayName: "Nushell", mark: .asset("NushellLogo"), kind: .shell),
        Entry(id: "elvish", displayName: "Elvish", mark: .asset("ElvishLogo"), kind: .shell),
        Entry(id: "xonsh", displayName: "xonsh", mark: .asset("XonshLogo"), kind: .shell),
        Entry(id: "sh", displayName: "sh", mark: genericShellMark, kind: .shell),
        Entry(id: "dash", displayName: "dash", mark: genericShellMark, kind: .shell),
        Entry(id: "ash", displayName: "ash", mark: genericShellMark, kind: .shell),
        Entry(id: "ksh", displayName: "ksh", mark: genericShellMark, kind: .shell),
        Entry(id: "tcsh", displayName: "tcsh", mark: genericShellMark, kind: .shell),
        Entry(id: "csh", displayName: "csh", mark: genericShellMark, kind: .shell),
        Entry(id: "yash", displayName: "yash", mark: genericShellMark, kind: .shell),
        Entry(id: "pwsh", displayName: "PowerShell", mark: genericShellMark, kind: .shell),
        Entry(id: "vim", displayName: "Vim", mark: .asset("VimLogo"), kind: .program),
        Entry(id: "neovim", displayName: "Neovim", mark: .asset("NeovimLogo"), kind: .program),
        Entry(id: "helix", displayName: "Helix", mark: .asset("HelixLogo"), kind: .program),
        Entry(id: "emacs", displayName: "Emacs", mark: .asset("EmacsLogo"), kind: .program),
        Entry(id: "nano", displayName: "nano", mark: editorMark, kind: .program),
        Entry(id: "micro", displayName: "micro", mark: editorMark, kind: .program),
        Entry(id: "htop", displayName: "htop", mark: .asset("HtopLogo"), kind: .program),
        Entry(id: "btop", displayName: "btop", mark: .asset("BtopLogo"), kind: .program),
        Entry(id: "top", displayName: "top", mark: monitorMark, kind: .program),
        Entry(id: "bottom", displayName: "bottom", mark: monitorMark, kind: .program),
        Entry(id: "glances", displayName: "Glances", mark: monitorMark, kind: .program),
        Entry(id: "nvtop", displayName: "nvtop", mark: monitorMark, kind: .program),
        Entry(id: "man", displayName: "man", mark: readerMark, kind: .program),
        Entry(id: "less", displayName: "less", mark: readerMark, kind: .program),
        Entry(id: "more", displayName: "more", mark: readerMark, kind: .program),
        Entry(id: "tail", displayName: "tail", mark: .asset("TailLogo"), kind: .program),
        Entry(id: "ssh", displayName: "ssh", mark: remoteMark, kind: .program),
        Entry(id: "mosh", displayName: "mosh", mark: remoteMark, kind: .program),
        Entry(id: "yazi", displayName: "Yazi", mark: filesMark, kind: .program),
        Entry(id: "ranger", displayName: "ranger", mark: filesMark, kind: .program),
        Entry(id: "nnn", displayName: "nnn", mark: filesMark, kind: .program),
        Entry(id: "lf", displayName: "lf", mark: filesMark, kind: .program),
        Entry(id: "mc", displayName: "Midnight Commander", mark: filesMark, kind: .program),
        Entry(id: "git", displayName: "Git", mark: .template("GitLogo"), kind: .program),
        Entry(id: "python", displayName: "Python", mark: .asset("PythonLogo"), kind: .program),
        Entry(id: "ruby", displayName: "Ruby", mark: .asset("RubyLogo"), kind: .program),
        Entry(id: "node", displayName: "Node.js", mark: .asset("NodeLogo"), kind: .program),
        Entry(id: "cargo", displayName: "Cargo", mark: .asset("CargoLogo"), kind: .program),
        Entry(id: "rustc", displayName: "rustc", mark: .asset("CargoLogo"), kind: .program),
        Entry(id: "rustup", displayName: "rustup", mark: .asset("CargoLogo"), kind: .program),
        Entry(id: "deno", displayName: "Deno", mark: .asset("DenoLogo"), kind: .program),
        Entry(id: "brew", displayName: "Homebrew", mark: .asset("HomebrewLogo"), kind: .program),
        Entry(id: "tmux", displayName: "tmux", mark: .asset("TmuxLogo"), kind: .multiplexer),
        Entry(id: "zellij", displayName: "Zellij", mark: multiplexerMark, kind: .multiplexer),
        Entry(id: "screen", displayName: "screen", mark: multiplexerMark, kind: .multiplexer),
        Entry(id: "herdr", displayName: "herdr", mark: multiplexerMark, kind: .multiplexer),
        Entry(id: "zmx", displayName: "zmx", mark: multiplexerMark, kind: .multiplexer),
    ]

    /// Category glyphs for programs without a usable logo of their own.
    private static let editorMark = BrandMark.symbol("square.and.pencil")
    private static let monitorMark = BrandMark.symbol("gauge.with.dots.needle.67percent")
    private static let readerMark = BrandMark.symbol("book.closed")
    private static let remoteMark = BrandMark.symbol("network")
    private static let filesMark = BrandMark.symbol("folder")
    private static let multiplexerMark = BrandMark.symbol("rectangle.split.3x1")

    /// Any other program in the foreground.
    static let runningProgramMark = BrandMark.symbol("play.circle")

    /// Command names that differ from the entry id.
    private static let aliases: [String: String] = [
        "nu": "nushell",
        "mksh": "ksh",
        "oksh": "ksh",
        "loksh": "ksh",
        "ksh93": "ksh",
        "powershell": "pwsh",
        "vi": "vim",
        "view": "vim",
        "vimdiff": "vim",
        "nvim": "neovim",
        "hx": "helix",
        "emacsclient": "emacs",
        "btm": "bottom",
        "gtail": "tail",
        "tssh": "ssh",
        "mosh-client": "mosh",
        "ya": "yazi",
        "ipython": "python",
        "bpython": "python",
        "irb": "ruby",
        "nodejs": "node",
        "npm": "node",
        "npx": "node",
    ]

    private static let byID: [String: Entry] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.id, $0) })

    /// Entry for a normalized command name (`ProgramNameNormalizer`).
    static func entry(for name: String) -> Entry? {
        byID[aliases[name] ?? name]
    }

    /// Entry for a catalog id, as stored in a Running card's `agentID`.
    static func entry(forID id: String) -> Entry? {
        byID[id]
    }
}
