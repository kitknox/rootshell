//
//  GitDiffRows.swift
//  rootshell
//
//  The rows of the diff list: file header, hunk header and code line, plus
//  the colours they share. Rows are Equatable so a refresh that leaves a
//  line alone does not rebuild it.
//

import SwiftUI
import UIKit

/// Diff colours for a light or dark panel surface.
struct GitDiffPalette: Equatable {
    let isDark: Bool

    var addition: Color {
        isDark ? Color(red: 0.25, green: 0.73, blue: 0.31) : Color(red: 0.10, green: 0.50, blue: 0.22)
    }

    var deletion: Color {
        isDark ? Color(red: 0.97, green: 0.32, blue: 0.29) : Color(red: 0.81, green: 0.13, blue: 0.18)
    }

    var modified: Color {
        isDark ? Color(red: 0.47, green: 0.66, blue: 0.95) : Color(red: 0.04, green: 0.41, blue: 0.85)
    }

    var renamed: Color {
        isDark ? Color(red: 0.74, green: 0.55, blue: 0.95) : Color(red: 0.51, green: 0.31, blue: 0.87)
    }

    var conflicted: Color {
        isDark ? Color(red: 0.89, green: 0.70, blue: 0.26) : Color(red: 0.60, green: 0.40, blue: 0.0)
    }

    func accent(_ kind: GitDiffLine.Kind) -> Color? {
        switch kind {
        case .addition: addition
        case .deletion: deletion
        case .context: nil
        }
    }

    func rowTint(_ kind: GitDiffLine.Kind) -> Color {
        accent(kind)?.opacity(isDark ? 0.15 : 0.11) ?? .clear
    }

    /// The gutter reads a step stronger than the row, so numbers stay a column.
    func gutterTint(_ kind: GitDiffLine.Kind) -> Color {
        accent(kind)?.opacity(isDark ? 0.24 : 0.19) ?? Color.primary.opacity(isDark ? 0.035 : 0.025)
    }

    func emphasis(_ kind: GitDiffLine.Kind) -> Color {
        accent(kind)?.opacity(isDark ? 0.42 : 0.30) ?? .clear
    }

    var hunkTint: Color { modified.opacity(isDark ? 0.10 : 0.07) }

    var selection: Color { Color.accentColor.opacity(isDark ? 0.45 : 0.30) }

    func token(_ token: GitDiffSyntax.Token) -> Color? {
        switch token {
        case .plain: nil
        case .keyword: isDark ? Color(red: 0.86, green: 0.55, blue: 0.80) : Color(red: 0.61, green: 0.14, blue: 0.58)
        case .string: isDark ? Color(red: 0.93, green: 0.70, blue: 0.47) : Color(red: 0.72, green: 0.31, blue: 0.05)
        case .comment: isDark ? Color(white: 0.56) : Color(white: 0.45)
        case .number: isDark ? Color(red: 0.50, green: 0.78, blue: 0.93) : Color(red: 0.05, green: 0.42, blue: 0.66)
        }
    }

    func status(_ status: GitDiffFileStatus) -> Color {
        switch status {
        case .added, .untracked: addition
        case .deleted: deletion
        case .modified, .typeChanged: modified
        case .renamed, .copied: renamed
        case .conflicted: conflicted
        }
    }
}

extension GitDiffFileStatus {
    var letter: String {
        switch self {
        case .added: "A"
        case .untracked: "N"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .conflicted: "!"
        }
    }

    var title: String {
        switch self {
        case .added: String(localized: "Added", comment: "Git file status")
        case .untracked: String(localized: "New", comment: "Git file status: untracked file")
        case .modified: String(localized: "Modified", comment: "Git file status")
        case .deleted: String(localized: "Deleted", comment: "Git file status")
        case .renamed: String(localized: "Renamed", comment: "Git file status")
        case .copied: String(localized: "Copied", comment: "Git file status")
        case .typeChanged: String(localized: "Type Changed", comment: "Git file status")
        case .conflicted: String(localized: "Conflicted", comment: "Git file status")
        }
    }
}

/// Everything a line row needs besides its line.
struct GitDiffRowStyle: Equatable {
    var fontSize: CGFloat
    var numberWidth: CGFloat
    /// Old and new numbers side by side; narrow panels show one column.
    var twoNumbers: Bool
    var wrap: Bool
    var palette: GitDiffPalette
    var path: String
    /// The shared row width when lines do not wrap.
    var rowWidth: CGFloat?

    var markerWidth: CGFloat {
        Self.markerWidth(for: fontSize)
    }

    static func markerWidth(for fontSize: CGFloat) -> CGFloat {
        max(16, (fontSize * 1.15).rounded(.up))
    }

    var gutterWidth: CGFloat {
        (twoNumbers ? numberWidth * 2 : numberWidth) + 6
    }

    var font: Font { .system(size: fontSize, design: .monospaced) }

    /// Advance of one monospaced digit at `size`.
    static func characterWidth(size: CGFloat) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }
}

// MARK: - Stat label

/// `+128 −34`, as the panel, the pill and each file header show it.
struct GitDiffStatLabel: View {
    let additions: Int?
    let deletions: Int?
    let palette: GitDiffPalette
    var textStyle: Font.TextStyle = .subheadline
    /// Some changes could not be counted, so these are at least this much.
    var isPartial = false
    /// When true, scales down to fit a narrow container instead of overflowing.
    var allowsShrinking = false

    init(
        additions: Int?,
        deletions: Int?,
        palette: GitDiffPalette,
        textStyle: Font.TextStyle = .subheadline,
        isPartial: Bool = false,
        allowsShrinking: Bool = false
    ) {
        self.additions = additions
        self.deletions = deletions
        self.palette = palette
        self.textStyle = textStyle
        self.isPartial = isPartial
        self.allowsShrinking = allowsShrinking
    }

    /// One file's counts, without the side that cannot apply: a new file
    /// has nothing removed, a deleted one nothing added, a pure rename neither.
    init(file: GitDiffFile, palette: GitDiffPalette, textStyle: Font.TextStyle = .subheadline) {
        let unchanged = file.additions == 0 && file.deletions == 0
        let isNew = file.status == .added || file.status == .untracked
        self.init(
            additions: file.status == .deleted || unchanged ? nil : file.additions,
            deletions: isNew || unchanged ? nil : file.deletions,
            palette: palette, textStyle: textStyle)
    }

    var body: some View {
        HStack(spacing: 5) {
            if isPartial {
                Text(verbatim: "\u{2265}").foregroundStyle(.secondary)
            }
            if let additions {
                Text(verbatim: "+\(GitDiffFormat.compact(additions))").foregroundStyle(palette.addition)
            }
            if let deletions {
                Text(verbatim: "\u{2212}\(GitDiffFormat.compact(deletions))").foregroundStyle(palette.deletion)
            }
        }
        .font(.system(textStyle, design: .monospaced, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(allowsShrinking ? 0.5 : 1)
        .allowsTightening(allowsShrinking)
        .fixedSize(horizontal: !allowsShrinking, vertical: true)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPartial
            ? String(
                localized: "At least \(additions ?? 0) lines added and \(deletions ?? 0) lines removed",
                comment: "Accessibility label for a diff's line counts when some files could not be counted")
            : String(
                localized: "\(additions ?? 0) lines added, \(deletions ?? 0) lines removed",
                comment: "Accessibility label for a diff's added and removed line counts"))
    }
}

struct GitDiffStatusBadge: View {
    let status: GitDiffFileStatus
    let palette: GitDiffPalette

    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 22

    var body: some View {
        Text(verbatim: status.letter)
            .font(.system(.footnote, design: .rounded, weight: .bold))
            .foregroundStyle(palette.status(status))
            .frame(width: size, height: size)
            .background(palette.status(status).opacity(palette.isDark ? 0.20 : 0.14),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel(status.title)
    }
}

// MARK: - File header

struct GitDiffFileHeader: View, Equatable {
    let file: GitDiffFile
    let expanded: Bool
    let palette: GitDiffPalette
    let background: Color
    let width: CGFloat?
    let onToggle: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.expanded == rhs.expanded && lhs.palette == rhs.palette && lhs.width == rhs.width
            && lhs.background == rhs.background
            && lhs.file.path == rhs.file.path && lhs.file.oldPath == rhs.file.oldPath
            && lhs.file.status == rhs.file.status && lhs.file.additions == rhs.file.additions
            && lhs.file.deletions == rhs.file.deletions && lhs.file.isBinary == rhs.file.isBinary
            && lhs.file.isTooLarge == rhs.file.isTooLarge
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14)
                GitDiffStatusBadge(status: file.status, palette: palette)
                name
                Spacer(minLength: 6)
                if file.isBinary || file.isTooLarge {
                    Text(file.isTooLarge
                        ? String(localized: "Too Large", comment: "Git diff file header tag for a file over the size limit")
                        : String(localized: "Binary", comment: "Git diff file header tag for a binary file"))
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    GitDiffStatLabel(file: file, palette: palette, textStyle: .subheadline)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(background)
            // Not Divider: inside a button label it turns vertical.
            .overlay(alignment: .top) { rule }
            .overlay(alignment: .bottom) { rule }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                UIPasteboard.general.string = file.path
            } label: {
                Label(String(localized: "Copy Path", comment: "Git diff file action"), systemImage: "doc.on.doc")
            }
        }
        .accessibilityLabel("\(file.status.title), \(file.path)")
        .accessibilityHint(expanded
            ? String(localized: "Collapses this file", comment: "Accessibility hint")
            : String(localized: "Expands this file", comment: "Accessibility hint"))
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
    }

    /// The file name leads; the directory follows dimmed and gives way first.
    private var name: some View {
        HStack(spacing: 6) {
            Text(verbatim: file.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let oldPath = file.oldPath {
                Text(verbatim: "\u{2190} \(oldPath)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if !file.directory.isEmpty {
                Text(verbatim: file.directory)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }
}

// MARK: - Hunk header

struct GitDiffHunkHeader: View, Equatable {
    let hunk: GitDiffHunk
    let style: GitDiffRowStyle

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.style == rhs.style && lhs.hunk.oldStart == rhs.hunk.oldStart && lhs.hunk.newStart == rhs.hunk.newStart
            && lhs.hunk.oldCount == rhs.hunk.oldCount && lhs.hunk.newCount == rhs.hunk.newCount
            && lhs.hunk.context == rhs.hunk.context
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "@@ \u{2212}\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@")
                .foregroundStyle(.tertiary)
            if !hunk.context.isEmpty {
                Text(verbatim: hunk.context).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: max(12, style.fontSize - 1), design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minHeight: (style.fontSize * 1.8).rounded())
        .frame(width: style.rowWidth, alignment: .leading)
        .frame(maxWidth: style.rowWidth == nil ? .infinity : nil, alignment: .leading)
        .background(style.palette.hunkTint)
    }
}

// MARK: - Line

struct GitDiffLineRow: View, Equatable {
    let line: GitDiffLine
    let style: GitDiffRowStyle
    var selection: GitDiffLineSelection?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            numbers
            Text(verbatim: marker)
                .foregroundStyle(style.palette.accent(line.kind) ?? .clear)
                .frame(width: style.markerWidth)
            Text(GitDiffLineText.attributed(line, style: style, selection: selection))
                .frame(maxWidth: style.wrap ? .infinity : nil, alignment: .leading)
                .fixedSize(horizontal: !style.wrap, vertical: true)
                .padding(.trailing, 8)
        }
        .font(style.font)
        .padding(.vertical, 1.5)
        .frame(width: style.rowWidth, alignment: .leading)
        .background(alignment: .leading) {
            style.palette.gutterTint(line.kind).frame(width: style.gutterWidth)
        }
        // A bare colour, so the tint runs under a display's safe-area edge.
        .background(style.palette.rowTint(line.kind))
        // No context menu: its long press belongs to text selection.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAction(named: Text(String(localized: "Copy Line", comment: "Git diff line action"))) {
            UIPasteboard.general.string = line.text
        }
    }

    private var marker: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "\u{2212}"
        case .context: " "
        }
    }

    @ViewBuilder
    private var numbers: some View {
        HStack(spacing: 0) {
            if style.twoNumbers {
                number(line.oldNumber)
                number(line.newNumber)
            } else {
                number(line.newNumber ?? line.oldNumber)
            }
        }
        .padding(.trailing, 6)
    }

    private func number(_ value: Int?) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .foregroundStyle(line.kind == .context ? HierarchicalShapeStyle.tertiary : .secondary)
            .lineLimit(1)
            .frame(width: style.numberWidth, alignment: .trailing)
    }

    private var accessibilityText: String {
        switch line.kind {
        case .addition: String(localized: "Added: \(line.text)", comment: "Accessibility label for an added diff line")
        case .deletion: String(localized: "Removed: \(line.text)", comment: "Accessibility label for a removed diff line")
        case .context: line.text
        }
    }
}

/// Builds a line's styled text: syntax colours, the changed-span highlight, then the selection.
enum GitDiffLineText {
    static func attributed(_ line: GitDiffLine, style: GitDiffRowStyle,
                           selection: GitDiffLineSelection? = nil) -> AttributedString {
        let characters = Array(line.text)
        // A selected line break reads as one selected space past the text.
        let lineEnd: AttributedString = {
            var space = AttributedString(" ")
            space.backgroundColor = style.palette.selection
            return space
        }()
        guard !characters.isEmpty else {
            return selection?.includesLineEnd == true ? lineEnd : AttributedString(" ")
        }
        let tokens = GitDiffSyntax.language(forPath: style.path).map { GitDiffSyntax.tokens(characters, language: $0) }
        let emphasis = line.emphasis.map { $0.clamped(to: 0..<characters.count) }
        let selected = selection.map { $0.range.clamped(to: 0..<characters.count) }
        let highlight = style.palette.emphasis(line.kind)

        var result = AttributedString()
        var start = 0
        while start < characters.count {
            let token = tokens?[start] ?? .plain
            let emphasized = emphasis?.contains(start) ?? false
            let isSelected = selected?.contains(start) ?? false
            var end = start + 1
            while end < characters.count, (tokens?[end] ?? .plain) == token,
                  (emphasis?.contains(end) ?? false) == emphasized,
                  (selected?.contains(end) ?? false) == isSelected {
                end += 1
            }
            var run = AttributedString(String(characters[start..<end]))
            if let color = style.palette.token(token) { run.foregroundColor = color }
            if isSelected {
                run.backgroundColor = style.palette.selection
            } else if emphasized {
                run.backgroundColor = highlight
            }
            result.append(run)
            start = end
        }
        if selection?.includesLineEnd == true { result.append(lineEnd) }
        if line.noNewlineAtEnd {
            var mark = AttributedString(" \u{29B8}")
            mark.foregroundColor = style.palette.token(.comment)
            result.append(mark)
        }
        return result
    }
}
