//
//  FileManagerShortcut.swift
//  rootshell
//
//  The file manager's hardware-keyboard map. Key commands, the hint bar, the
//  shortcut sheet, tooltips and menu glyphs are all generated from this table.
//

import UIKit

enum FileManagerCommand: CaseIterable {
    case moveCursor
    case extendSelection
    case toggleSelection
    case selectAll
    case open
    case openInTerminal
    case parent
    case back
    case forward
    case switchPane
    case goToPath
    case connect
    case refresh
    case toggleHidden
    case edit
    case editExternal
    case quickLook
    case copyToOther
    case moveToOther
    case paste
    case rename
    case newFolder
    case delete
    case info
    case focusQueue
    case cancelJob
    case cancelAllJobs
    case showShortcuts
    case close
}

struct FileManagerShortcut {
    enum Group: CaseIterable {
        case navigate
        case select
        case transfer
        case manage
        case queue

        var title: String {
            switch self {
            case .navigate: String(localized: "Navigate", comment: "File manager shortcut group")
            case .select: String(localized: "Select", comment: "File manager shortcut group")
            case .transfer: String(localized: "Transfer", comment: "File manager shortcut group")
            case .manage: String(localized: "Manage", comment: "File manager shortcut group")
            case .queue: String(localized: "Transfer Queue", comment: "File manager shortcut group")
            }
        }
    }

    /// One way to press the shortcut.
    struct Chord {
        let input: String
        let modifiers: UIKeyModifierFlags

        var glyph: String {
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.alternate) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            return text + Self.keyGlyph(input)
        }

        private static func keyGlyph(_ input: String) -> String {
            switch input {
            case UIKeyCommand.inputUpArrow: "↑"
            case UIKeyCommand.inputDownArrow: "↓"
            case UIKeyCommand.inputLeftArrow: "←"
            case UIKeyCommand.inputRightArrow: "→"
            case UIKeyCommand.inputEscape: "esc"
            case UIKeyCommand.inputDelete: "⌫"
            case UIKeyCommand.f2: "F2"
            case UIKeyCommand.f4: "F4"
            case UIKeyCommand.f5: "F5"
            case UIKeyCommand.f6: "F6"
            case "\r": "↩"
            case "\t": "⇥"
            case " ": "Space"
            default: input.uppercased()
            }
        }
    }

    let command: FileManagerCommand
    let title: String
    let group: Group
    let chords: [Chord]
    /// Shown as one badge (e.g. "↑↓") instead of the chord glyphs.
    var displayOverride: String?
    /// Arrows, Tab, Return, Escape, ⌘A and ⌘V are handled by the filter field itself;
    /// everything else becomes a key command.
    var isFieldHandled = false

    var glyph: String {
        displayOverride ?? chords.map(\.glyph).joined(separator: " / ")
    }

    /// "Copy to Other Pane (F5)" for tooltips.
    var helpText: String { "\(title) (\(glyph))" }

    static func shortcut(for command: FileManagerCommand) -> FileManagerShortcut {
        all.first { $0.command == command }!
    }

    static let all: [FileManagerShortcut] = [
        .init(command: .moveCursor, title: String(localized: "Move", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: UIKeyCommand.inputUpArrow, modifiers: []), Chord(input: UIKeyCommand.inputDownArrow, modifiers: [])],
              displayOverride: "↑↓", isFieldHandled: true),
        .init(command: .open, title: String(localized: "Open", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "\r", modifiers: [])], isFieldHandled: true),
        .init(command: .parent, title: String(localized: "Enclosing Folder", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "\t", modifiers: .shift)], isFieldHandled: true),
        .init(command: .switchPane, title: String(localized: "Other Pane", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "\t", modifiers: [])], isFieldHandled: true),
        .init(command: .back, title: String(localized: "Back", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "[", modifiers: .command)]),
        .init(command: .forward, title: String(localized: "Forward", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "]", modifiers: .command)]),
        .init(command: .goToPath, title: String(localized: "Go to Folder", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "g", modifiers: .command)]),
        .init(command: .connect, title: String(localized: "Connect", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "o", modifiers: .command)]),
        .init(command: .refresh, title: String(localized: "Refresh", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "r", modifiers: .command)]),
        .init(command: .toggleHidden, title: String(localized: "Show Hidden Files", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: ".", modifiers: [.command, .shift])]),
        .init(command: .openInTerminal, title: String(localized: "Open in Terminal", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "\r", modifiers: .command)]),

        .init(command: .extendSelection, title: String(localized: "Extend Selection", comment: "File manager shortcut"), group: .select,
              chords: [Chord(input: UIKeyCommand.inputUpArrow, modifiers: .shift), Chord(input: UIKeyCommand.inputDownArrow, modifiers: .shift)],
              displayOverride: "⇧↑↓"),
        .init(command: .toggleSelection, title: String(localized: "Select", comment: "File manager shortcut"), group: .select,
              chords: [Chord(input: " ", modifiers: [])], isFieldHandled: true),
        .init(command: .selectAll, title: String(localized: "Select All", comment: "File manager shortcut"), group: .select,
              chords: [Chord(input: "a", modifiers: .command)], isFieldHandled: true),
        .init(command: .edit, title: String(localized: "Edit", comment: "File manager shortcut"), group: .manage,
              chords: [Chord(input: UIKeyCommand.f4, modifiers: []), Chord(input: "e", modifiers: .command)]),
        .init(command: .editExternal, title: String(localized: "Edit in External Editor", comment: "File manager shortcut"), group: .manage,
              chords: [Chord(input: "e", modifiers: [.command, .alternate])]),
        .init(command: .quickLook, title: String(localized: "Quick Look", comment: "File manager shortcut"), group: .select,
              chords: [Chord(input: "y", modifiers: .command)]),

        .init(command: .copyToOther, title: String(localized: "Copy to Other Pane", comment: "File manager shortcut"), group: .transfer,
              chords: [Chord(input: UIKeyCommand.f5, modifiers: []), Chord(input: "c", modifiers: [.command, .alternate])]),
        .init(command: .moveToOther, title: String(localized: "Move to Other Pane", comment: "File manager shortcut"), group: .transfer,
              chords: [Chord(input: UIKeyCommand.f6, modifiers: []), Chord(input: "x", modifiers: [.command, .alternate])]),
        .init(command: .paste, title: String(localized: "Paste", comment: "File manager shortcut: upload files from the clipboard"), group: .transfer,
              chords: [Chord(input: "v", modifiers: .command)], isFieldHandled: true),

        .init(command: .rename, title: String(localized: "Rename", comment: "File manager shortcut"), group: .manage,
              chords: [Chord(input: UIKeyCommand.f2, modifiers: []), Chord(input: "r", modifiers: [.command, .alternate])]),
        .init(command: .newFolder, title: String(localized: "New Folder", comment: "File manager shortcut"), group: .manage,
              chords: [Chord(input: "n", modifiers: [.command, .shift])]),
        .init(command: .delete, title: String(localized: "Delete", comment: "File manager shortcut"), group: .manage,
              chords: [Chord(input: UIKeyCommand.inputDelete, modifiers: .command)]),
        .init(command: .info, title: String(localized: "Get Info", comment: "File manager shortcut"), group: .manage,
              chords: [Chord(input: "i", modifiers: [.command, .alternate])]),

        .init(command: .focusQueue, title: String(localized: "Focus Queue", comment: "File manager shortcut"), group: .queue,
              chords: [Chord(input: "j", modifiers: .command)]),
        .init(command: .cancelJob, title: String(localized: "Cancel Transfer", comment: "File manager shortcut"), group: .queue,
              chords: [Chord(input: UIKeyCommand.inputDelete, modifiers: [])], isFieldHandled: true),
        .init(command: .cancelAllJobs, title: String(localized: "Cancel All", comment: "File manager shortcut"), group: .queue,
              chords: [Chord(input: UIKeyCommand.inputDelete, modifiers: .command)], isFieldHandled: true),

        .init(command: .showShortcuts, title: String(localized: "All Shortcuts", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: "/", modifiers: .command)]),
        .init(command: .close, title: String(localized: "Close", comment: "File manager shortcut"), group: .navigate,
              chords: [Chord(input: UIKeyCommand.inputEscape, modifiers: [])], isFieldHandled: true),
    ]

    /// Key commands for a focused pane; queue-only rows are wired by the queue list.
    static func paneCommands(handler: @escaping (FileManagerCommand, Chord) -> Void) -> [SidebarSearchExtraCommand] {
        all.filter { !$0.isFieldHandled && $0.group != .queue || $0.command == .focusQueue }
            .flatMap { shortcut in
                shortcut.chords.map { chord in
                    SidebarSearchExtraCommand(input: chord.input, modifiers: chord.modifiers, title: shortcut.title) {
                        handler(shortcut.command, chord)
                    }
                }
            }
    }

    /// Hints for the bar under the panes, most relevant first.
    static func hints(hasSelection: Bool, queueFocused: Bool) -> [FileManagerShortcut] {
        let commands: [FileManagerCommand]
        if queueFocused {
            commands = [.moveCursor, .cancelJob, .cancelAllJobs, .close]
        } else if hasSelection {
            commands = [.copyToOther, .moveToOther, .delete, .rename, .toggleSelection]
        } else {
            commands = [.moveCursor, .open, .switchPane, .toggleSelection, .connect]
        }
        return commands.map { shortcut(for: $0) }
    }
}
