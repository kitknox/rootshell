//
//  FileRowView.swift
//  rootshell
//
//  One listing row. Wide panes add size, date and permission columns.
//

import SwiftUI
import UniformTypeIdentifiers

struct FileRowView: View, Equatable {
    let entry: RFEntry
    let isSelected: Bool
    let isCursor: Bool
    /// The cursor ring only shows while this pane owns the keyboard.
    let showsCursor: Bool
    let showsCheckbox: Bool
    var isExternallyEdited: Bool = false
    let columns: Columns

    enum Columns {
        case compact
        case detailed
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsCheckbox {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .font(.body)
            }
            Image(systemName: Self.symbol(for: entry))
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(entry.isHidden ? .secondary : .primary)
                    if entry.isSymlink {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "Symbolic link", comment: "File manager row accessibility"))
                    }
                    if isExternallyEdited {
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel(String(localized: "Editing externally, auto-uploading on save", comment: "File manager row accessibility"))
                    }
                }
                if columns == .compact, let detail = compactDetail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if columns == .detailed {
                Text(entry.isDirectory ? "—" : Self.sizeText(entry.size))
                    .frame(width: 70, alignment: .trailing)
                Text(entry.modifiedDate.map { Self.dateText($0) } ?? "")
                    .frame(width: 118, alignment: .trailing)
                Text(entry.permissions.map { Self.permissionsText($0) } ?? "")
                    .font(.caption.monospaced())
                    .frame(width: 84, alignment: .trailing)
            }
        }
        .font(columns == .detailed ? .callout : .body)
        .monospacedDigit()
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, columns == .detailed ? 5 : 7)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isCursor && showsCursor && !isSelected {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        if isCursor && showsCursor { return Color.accentColor.opacity(0.10) }
        return .clear
    }

    private var compactDetail: String? {
        if let target = entry.symlinkTarget { return "→ \(target)" }
        guard !entry.isDirectory else { return entry.modifiedDate.map { Self.dateText($0) } }
        let size = Self.sizeText(entry.size)
        return entry.modifiedDate.map { "\(size) · \(Self.dateText($0))" } ?? size
    }

    // MARK: - Formatting

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// `rwxr-xr-x` from mode bits.
    static func permissionsText(_ mode: UInt32) -> String {
        let flags: [(UInt32, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(flags.map { mode & $0.0 != 0 ? $0.1 : "-" })
    }

    static func symbol(for entry: RFEntry) -> String {
        if entry.isDirectory { return entry.isSymlink ? "folder.badge.gearshape" : "folder.fill" }
        if let type = UTType(filenameExtension: entry.fileExtension) {
            if type.conforms(to: .image) && !type.conforms(to: .svg) { return "photo" }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return "film" }
            if type.conforms(to: .audio) { return "waveform" }
            if type.conforms(to: .pdf) { return "doc.richtext" }
            if type.conforms(to: .archive) { return "doc.zipper" }
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .shellScript) {
                return "chevron.left.forwardslash.chevron.right"
            }
            if type.conforms(to: .text) { return "doc.text" }
        }
        switch FileEditorSyntax.detectLanguage(fileName: entry.name) {
        case .cLike, .hashCode, .shell, .dockerfile, .makefile, .sql, .css, .markup, .json:
            return "chevron.left.forwardslash.chevron.right"
        case .yaml, .toml, .dotenv, .ini, .markdown:
            return "doc.text"
        case .plain:
            if FileEditClassification.isKnownTextFile(name: entry.name) { return "doc.text" }
            return entry.isExecutable ? "terminal" : "doc"
        }
    }
}
