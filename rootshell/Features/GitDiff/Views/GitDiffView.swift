//
//  GitDiffView.swift
//  rootshell
//
//  The git diff panel content, shared by the sidebar column, the HUD and the
//  iPhone sheet: what changed in the focused pane's repository, as one
//  scrolling list of files with sticky headers.
//

import SwiftUI

extension GitDiffScope {
    var title: String {
        switch self {
        case .uncommitted: String(localized: "Uncommitted", comment: "Git diff comparison: working tree against the last commit")
        case .branch: String(localized: "Branch", comment: "Git diff comparison: everything since the branch left the default branch")
        case .lastCommit: String(localized: "Last Commit", comment: "Git diff comparison: the most recent commit")
        }
    }

    var systemImage: String {
        switch self {
        case .uncommitted: "pencil.line"
        case .branch: "arrow.triangle.branch"
        case .lastCommit: "smallcircle.filled.circle"
        }
    }
}

struct GitDiffView: View {
    enum Style {
        case sidebar
        case overlay
        case full
        case sheet

        var presentation: PanelPresentation? {
            switch self {
            case .sidebar: .sidebar
            case .overlay: .overlay
            case .full: .full
            case .sheet: nil
            }
        }
    }

    /// The glyph the panel, its pill and its toolbar key share.
    static let systemImage = "arrow.triangle.branch"

    let store: GitDiffStore
    let style: Style
    let onClose: () -> Void
    /// Shrinks the panel to its summary pill; nil where there is no pill.
    let onCollapse: (() -> Void)?
    /// Switches between presentations; nil where only one presentation exists.
    let onSwitchPresentation: ((PanelPresentation) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @Setting(Settings.GitDiff.wrapLines) private var wrapLines
    @State private var jumpTarget: String?

    /// A dark terminal theme can run under a light system scheme; colours
    /// must resolve against the panel's own surface.
    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var palette: GitDiffPalette { GitDiffPalette(isDark: surfaceScheme == .dark) }

    private var surface: Color {
        sheetThemeColors?.background ?? Color(uiColor: .systemBackground)
    }

    private var headerSurface: Color {
        sheetThemeColors?.cardFill ?? Color(uiColor: .secondarySystemBackground)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let snapshot = store.snapshot {
                toolbar(snapshot)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Code needs a solid page; the floating HUD's chrome stays glass.
                .background(surface)
        }
        .environment(\.colorScheme, surfaceScheme)
        .background(style == .sheet ? sheetThemeColors?.background.ignoresSafeArea() : nil)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            title
            Spacer(minLength: 4)
            if let onSwitchPresentation, let current = style.presentation {
                PanelPresentationMenu(current: current, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .help(String(localized: "Show Summary Only", comment: "Git diff panel button tooltip"))
                .accessibilityLabel(String(localized: "Show Summary Only", comment: "Git diff panel button"))
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .help(String(localized: "Close", comment: "Git diff close button tooltip"))
            .accessibilityLabel(String(localized: "Close Git Diff", comment: "Git diff close button"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var title: some View {
        if let snapshot = store.snapshot {
            HStack(spacing: 6) {
                Text(verbatim: snapshot.repositoryName)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let head = snapshot.headLabel {
                    Text(verbatim: head)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                if snapshot.ahead > 0 || snapshot.behind > 0 {
                    Text(verbatim: [snapshot.ahead > 0 ? "\u{2191}\(snapshot.ahead)" : nil,
                                    snapshot.behind > 0 ? "\u{2193}\(snapshot.behind)" : nil]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        } else {
            Text(String(localized: "Git Diff", comment: "Git diff panel title"))
                .font(.headline)
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ snapshot: GitDiffSnapshot) -> some View {
        HStack(spacing: 12) {
            GitDiffScopeMenu(scope: store.scope, baseRef: snapshot.baseRef) { store.setScope($0) }
                .equatable()
            if !snapshot.isClean {
                // The file count is the first thing a narrow panel gives up.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(String(localized: "\(snapshot.files.count) files", comment: "Git diff: number of changed files"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        GitDiffStatLabel(additions: snapshot.additions, deletions: snapshot.deletions, palette: palette,
                                         isPartial: snapshot.countsIncomplete)
                    }
                    GitDiffStatLabel(additions: snapshot.additions, deletions: snapshot.deletions, palette: palette,
                                         isPartial: snapshot.countsIncomplete)
                }
            }
            Spacer(minLength: 0)
            if snapshot.files.count > 1 {
                GitDiffFilesMenu(files: snapshot.files) { reveal($0) }
                    .equatable()
            }
            if !snapshot.isClean {
                Button {
                    store.setAllExpanded(store.allCollapsed)
                } label: {
                    Image(systemName: store.allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }
                .help(store.allCollapsed
                    ? String(localized: "Expand All Files", comment: "Git diff toolbar tooltip")
                    : String(localized: "Collapse All Files", comment: "Git diff toolbar tooltip"))
                .accessibilityLabel(store.allCollapsed
                    ? String(localized: "Expand All Files", comment: "Git diff toolbar button")
                    : String(localized: "Collapse All Files", comment: "Git diff toolbar button"))
            }
            GitDiffOptionsMenu(
                wrapLines: wrapLines,
                ignoreWhitespace: store.ignoreWhitespace,
                onWrap: { wrapLines = $0 },
                onIgnoreWhitespace: { store.setIgnoreWhitespace($0) })
                .equatable()
            Button {
                store.refresh()
            } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise").opacity(store.isRefreshing ? 0 : 1)
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            .help(String(localized: "Refresh", comment: "Git diff toolbar tooltip"))
            .accessibilityLabel(String(localized: "Refresh", comment: "Git diff toolbar button"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func reveal(_ id: String) {
        if let file = store.snapshot?.files.first(where: { $0.id == id }), !store.isExpanded(file) {
            store.setExpanded(true, for: file)
        }
        jumpTarget = id
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let snapshot = store.snapshot {
            if snapshot.isClean {
                GitDiffMessage(
                    systemImage: "checkmark.circle",
                    title: String(localized: "No Changes", comment: "Git diff empty state title"),
                    detail: cleanDetail(snapshot))
            } else {
                GitDiffFileList(
                    store: store, snapshot: snapshot, wrap: wrapLines, palette: palette,
                    surface: surface, headerSurface: headerSurface, jumpTarget: $jumpTarget)
            }
        } else {
            switch store.phase {
            case .loading, .ready:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(String(localized: "Reading changes…", comment: "Git diff loading state"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .unavailable(.notARepository(let directory)):
                GitDiffMessage(
                    systemImage: "folder.badge.questionmark",
                    title: String(localized: "Not a Git Repository", comment: "Git diff state title"),
                    detail: directory.isEmpty
                        ? String(localized: "The focused pane is not inside a repository.", comment: "Git diff state detail")
                        : directory)
            case .unavailable(.noDirectory):
                GitDiffMessage(
                    systemImage: "folder.badge.questionmark",
                    title: String(localized: "No Working Directory", comment: "Git diff state title"),
                    detail: String(localized: "This pane has not reported which directory it is in.", comment: "Git diff state detail"))
            case .unavailable(.gitMissing):
                GitDiffMessage(
                    systemImage: "shippingbox",
                    title: String(localized: "Git Is Not Installed", comment: "Git diff state title"),
                    detail: String(localized: "This host has no git on its PATH.", comment: "Git diff state detail"))
            case .unsupportedPane:
                GitDiffMessage(
                    systemImage: "rectangle.slash",
                    title: String(localized: "Not Available Here", comment: "Git diff state title"),
                    detail: String(localized: "Git diff follows local shells and SSH, Mosh and tssh sessions.", comment: "Git diff state detail"))
            case .helperUnavailable:
                GitDiffMessage(
                    systemImage: "bolt.horizontal.circle",
                    title: String(localized: "Helper Not Running", comment: "Git diff state title"),
                    detail: String(localized: "Local shells read git through the rootshell helper.", comment: "Git diff state detail"),
                    onRetry: { store.refresh() })
            case .gitFailed:
                GitDiffMessage(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Git Could Not Read This Repository", comment: "Git diff state title"),
                    detail: String(localized: "Run git status in the pane to see what is wrong.", comment: "Git diff state detail"),
                    onRetry: { store.refresh() })
            case .disconnected:
                GitDiffMessage(
                    systemImage: "wifi.slash",
                    title: String(localized: "Not Connected", comment: "Git diff state title"),
                    detail: String(localized: "Changes appear once this pane's session is connected.", comment: "Git diff state detail"),
                    onRetry: { store.refresh() })
            case .failed:
                GitDiffMessage(
                    systemImage: "exclamationmark.triangle",
                    title: String(localized: "Could Not Read Changes", comment: "Git diff state title"),
                    detail: String(localized: "The host did not return a complete answer.", comment: "Git diff state detail"),
                    onRetry: { store.refresh() })
            }
        }
    }

    private func cleanDetail(_ snapshot: GitDiffSnapshot) -> String {
        switch store.scope {
        case .uncommitted:
            return String(localized: "The working tree matches the last commit.", comment: "Git diff empty state detail")
        case .branch:
            guard let base = snapshot.baseRef else {
                return String(localized: "No default branch was found to compare against.", comment: "Git diff empty state detail")
            }
            return String(localized: "Nothing differs from \(base).", comment: "Git diff empty state detail; the argument is a branch name")
        case .lastCommit:
            return String(localized: "The last commit changed no files.", comment: "Git diff empty state detail")
        }
    }
}

// MARK: - Messages

private struct GitDiffMessage: View {
    let systemImage: String
    let title: String
    let detail: String
    var onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(verbatim: title).font(.headline)
            Text(verbatim: detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .truncationMode(.middle)
            if let onRetry {
                Button(String(localized: "Try Again", comment: "Git diff retry button"), action: onRetry)
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
    }
}

// MARK: - Menus

/// Picks what the panel compares. Equatable, like `PanelPresentationMenu`,
/// so a refresh never rebuilds the menu while it is open.
private struct GitDiffScopeMenu: View, Equatable {
    let scope: GitDiffScope
    let baseRef: String?
    let onSelect: (GitDiffScope) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.baseRef == rhs.baseRef
    }

    var body: some View {
        Menu {
            Picker(
                String(localized: "Compare", comment: "Git diff comparison menu section title"),
                selection: Binding(get: { scope }, set: { onSelect($0) })
            ) {
                ForEach(GitDiffScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage).tag(scope)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        }
        .accessibilityLabel(String(localized: "Compare", comment: "Git diff comparison menu"))
        .accessibilityValue(scope.title)
    }

    private var label: String {
        if scope == .branch, let baseRef {
            return String(localized: "vs \(baseRef)", comment: "Git diff comparison menu label; the argument is the branch compared against")
        }
        return scope.title
    }
}

private struct GitDiffOptionsMenu: View, Equatable {
    let wrapLines: Bool
    let ignoreWhitespace: Bool
    let onWrap: (Bool) -> Void
    let onIgnoreWhitespace: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wrapLines == rhs.wrapLines && lhs.ignoreWhitespace == rhs.ignoreWhitespace
    }

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { wrapLines }, set: { onWrap($0) })) {
                Label(String(localized: "Wrap Lines", comment: "Git diff option"), systemImage: "text.word.spacing")
            }
            Toggle(isOn: Binding(get: { ignoreWhitespace }, set: { onIgnoreWhitespace($0) })) {
                Label(String(localized: "Hide Whitespace Changes", comment: "Git diff option"), systemImage: "space")
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .accessibilityLabel(String(localized: "View Options", comment: "Git diff options menu"))
    }
}

/// Jumps to a file. Shown in every width; the wide layout also lists files beside the diff.
private struct GitDiffFilesMenu: View, Equatable {
    let files: [GitDiffFile]
    let onSelect: (String) -> Void

    /// A menu past this is no faster than scrolling.
    private static let limit = 80

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.files.count == rhs.files.count && zip(lhs.files, rhs.files).allSatisfy {
            $0.id == $1.id && $0.additions == $1.additions && $0.deletions == $1.deletions
        }
    }

    var body: some View {
        Menu {
            ForEach(files.prefix(Self.limit)) { file in
                Button {
                    onSelect(file.id)
                } label: {
                    Text(verbatim: file.path)
                    Text(verbatim: "\(file.status.title)  +\(file.additions ?? 0) \u{2212}\(file.deletions ?? 0)")
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
        }
        .accessibilityLabel(String(localized: "Jump to File", comment: "Git diff files menu"))
    }
}

// MARK: - File list

private struct GitDiffFileList: View {
    let store: GitDiffStore
    let snapshot: GitDiffSnapshot
    let wrap: Bool
    let palette: GitDiffPalette
    let surface: Color
    let headerSurface: Color
    @Binding var jumpTarget: String?

    /// Wide enough to list files beside the diff, as desktop diff views do.
    private static let fileColumnThreshold: CGFloat = 860
    private static let twoNumberThreshold: CGFloat = 520

    var body: some View {
        GeometryReader { geometry in
            let showsColumn = geometry.size.width >= Self.fileColumnThreshold && snapshot.files.count > 1
            let columnWidth = showsColumn ? min(300, (geometry.size.width * 0.27).rounded()) : 0
            HStack(spacing: 0) {
                if showsColumn {
                    fileColumn.frame(width: columnWidth)
                    Divider()
                }
                diff(width: geometry.size.width - columnWidth - (showsColumn ? 1 : 0))
            }
        }
    }

    // MARK: Diff

    private func diff(width: CGFloat) -> some View {
        let fontSize: CGFloat = width < 380 ? 11 : 12
        let characterWidth = GitDiffRowStyle.characterWidth(size: fontSize)
        let twoNumbers = width >= Self.twoNumberThreshold
        // One width for every file keeps unwrapped rows and headers aligned.
        let digits = max(2, String(snapshot.files.reduce(0) { max($0, Self.lastLine(of: $1)) }).count)
        let numberWidth = (CGFloat(digits) * characterWidth).rounded(.up) + 8
        let gutter = (twoNumbers ? numberWidth * 2 : numberWidth) + 6
        let rowWidth: CGFloat? = wrap ? nil : max(
            width,
            gutter + GitDiffRowStyle.markerWidth + 16
                + CGFloat(snapshot.files.reduce(0) { max($0, $1.maxColumns) } + 1) * characterWidth)

        return ScrollViewReader { proxy in
            ScrollView(wrap ? [.vertical] : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    notices(width: rowWidth)
                    ForEach(snapshot.files) { file in
                        let expanded = store.isExpanded(file)
                        Section {
                            if expanded {
                                GitDiffFileBody(file: file, style: GitDiffRowStyle(
                                    fontSize: fontSize, numberWidth: numberWidth, twoNumbers: twoNumbers,
                                    wrap: wrap, palette: palette, path: file.path, rowWidth: rowWidth))
                            }
                        } header: {
                            GitDiffFileHeader(
                                file: file, expanded: expanded, palette: palette, background: headerSurface,
                                width: rowWidth, onToggle: { store.setExpanded(!expanded, for: file) })
                                .equatable()
                                .id(file.id)
                        }
                    }
                }
                .frame(width: rowWidth, alignment: .leading)
            }
            // A panel scroll view over the terminal; UIKit 26 would blur its edges.
            .modifier(ScrollEdgeEffectHiddenModifier())
            .onChange(of: jumpTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
                jumpTarget = nil
            }
        }
    }

    private static func lastLine(of file: GitDiffFile) -> Int {
        guard let hunk = file.hunks.last else { return 0 }
        return max(hunk.oldStart + hunk.oldCount, hunk.newStart + hunk.newCount)
    }

    @ViewBuilder
    private func notices(width: CGFloat?) -> some View {
        if snapshot.files.contains(where: \.isTooLarge) {
            notice(String(localized: "Some files are too large to read. The totals leave them out.",
                          comment: "Git diff notice when a file was over the size limit and went uncounted"), width: width)
        }
        if snapshot.patchTruncated {
            notice(String(localized: "Some diffs are too large to show. Their lines are still counted.",
                          comment: "Git diff notice when the patch hit the size limit"), width: width)
        }
        if snapshot.untrackedTruncated {
            notice(String(localized: "Only the first \(GitDiffProbeCommand.untrackedFileLimit) new files are listed. The totals leave the rest out.",
                          comment: "Git diff notice when there are too many untracked files"), width: width)
        }
    }

    private func notice(_ text: String, width: CGFloat?) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .background(palette.conflicted.opacity(0.10))
    }

    // MARK: File column

    private var fileColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(snapshot.files) { file in
                    Button {
                        if !store.isExpanded(file) { store.setExpanded(true, for: file) }
                        jumpTarget = file.id
                    } label: {
                        HStack(spacing: 7) {
                            GitDiffStatusBadge(status: file.status, palette: palette)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: file.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !file.directory.isEmpty {
                                    Text(verbatim: file.directory)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                            Spacer(minLength: 4)
                            GitDiffStatLabel(file: file, palette: palette, size: 10.5)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .modifier(ScrollEdgeEffectHiddenModifier())
        .background(headerSurface.opacity(0.5))
    }
}

/// A file's rows. Its body is a list, not a stack, so the lazy stack above
/// still creates rows only as they scroll in.
private struct GitDiffFileBody: View {
    let file: GitDiffFile
    let style: GitDiffRowStyle

    var body: some View {
        if file.isBinary {
            note(String(localized: "Binary file", comment: "Git diff: a binary file has no text diff"))
        } else if !file.hasPatch {
            note(String(localized: "This diff is too large to show.", comment: "Git diff: a file's patch was left out"))
        } else if file.hunks.isEmpty {
            note(file.status == .renamed
                ? String(localized: "Renamed without changes", comment: "Git diff: a pure rename")
                : String(localized: "No text changes", comment: "Git diff: an empty file or a mode change"))
        } else {
            ForEach(rows, id: \.self) { row in
                if let line = row.line {
                    GitDiffLineRow(line: file.hunks[row.hunk].lines[line], style: style)
                        .equatable()
                } else {
                    GitDiffHunkHeader(hunk: file.hunks[row.hunk], style: style)
                        .equatable()
                }
            }
            if file.isTruncated {
                note(String(localized: "The rest of this diff is too large to show.",
                            comment: "Git diff: a file's patch was cut off"))
            }
        }
        Color.clear.frame(height: 10)
    }

    /// One entry per hunk header and line. The file is part of the identity:
    /// every file shares one lazy stack, and bare indices would hand one
    /// file's rows to another.
    private struct Row: Hashable {
        let file: String
        let hunk: Int
        /// nil for the hunk's header.
        let line: Int?
    }

    private var rows: [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(file.lineCount + file.hunks.count)
        for (index, hunk) in file.hunks.enumerated() {
            rows.append(Row(file: file.id, hunk: index, line: nil))
            for line in hunk.lines.indices { rows.append(Row(file: file.id, hunk: index, line: line)) }
        }
        return rows
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: style.rowWidth, alignment: .leading)
            .frame(maxWidth: style.rowWidth == nil ? .infinity : nil, alignment: .leading)
    }
}
