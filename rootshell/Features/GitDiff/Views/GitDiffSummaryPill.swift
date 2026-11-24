//
//  GitDiffSummaryPill.swift
//  rootshell
//
//  The git diff overlay collapsed to one line: branch, files changed and
//  lines added and removed. Tapping it opens the full diff.
//

import SwiftUI

struct GitDiffSummaryPill: View {
    let store: GitDiffStore
    let onExpand: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var palette: GitDiffPalette { GitDiffPalette(isDark: surfaceScheme == .dark) }

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: GitDiffView.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                summary
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            // The HUD host measures at its compressed size; nothing here may shrink.
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clipShape(Capsule())
        .gitDiffPillBackground()
        .environment(\.colorScheme, surfaceScheme)
        .contextMenu {
            Button(action: onExpand) {
                Label(String(localized: "Show Diff", comment: "Git diff summary pill action"),
                      systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Button {
                store.refresh()
            } label: {
                Label(String(localized: "Refresh", comment: "Git diff summary pill action"), systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: onClose) {
                Label(String(localized: "Close Git Diff", comment: "Git diff summary pill action"), systemImage: "xmark")
            }
        }
        .help(String(localized: "Show Diff", comment: "Git diff summary pill tooltip"))
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(String(localized: "Shows the full diff", comment: "Accessibility hint"))
    }

    @ViewBuilder
    private var summary: some View {
        if let snapshot = store.snapshot {
            if let head = snapshot.headLabel {
                Text(verbatim: head)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150)
                    .fixedSize()
            }
            if snapshot.isClean {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(palette.addition)
            } else {
                Label {
                    Text(verbatim: "\(snapshot.files.count)")
                } icon: {
                    Image(systemName: "doc")
                }
                .labelStyle(GitDiffPillLabelStyle())
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                GitDiffStatLabel(additions: snapshot.additions, deletions: snapshot.deletions, palette: palette,
                                         isPartial: snapshot.countsIncomplete)
            }
        } else {
            switch store.phase {
            case .loading, .ready:
                ProgressView().controlSize(.small)
            case .unavailable, .unsupportedPane:
                Text(String(localized: "No repository", comment: "Git diff summary pill: the pane is not in a repository"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            case .disconnected, .helperUnavailable, .gitFailed, .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilitySummary: String {
        guard let snapshot = store.snapshot else {
            return String(localized: "Git diff", comment: "Accessibility label for the git diff summary pill")
        }
        if snapshot.isClean {
            return String(localized: "Git diff, no changes", comment: "Accessibility label for the git diff summary pill")
        }
        if snapshot.countsIncomplete {
            return String(
                localized: "Git diff, \(snapshot.files.count) files, at least \(snapshot.additions) lines added and \(snapshot.deletions) lines removed",
                comment: "Accessibility label for the git diff summary pill when some files could not be counted")
        }
        return String(
            localized: "Git diff, \(snapshot.files.count) files, \(snapshot.additions) lines added, \(snapshot.deletions) lines removed",
            comment: "Accessibility label for the git diff summary pill")
    }
}

private struct GitDiffPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 10, weight: .semibold))
            configuration.title
        }
    }
}

private extension View {
    /// Glass in the pill's own shape, as `floatingHUDPanelBackground` does for panels.
    @ViewBuilder
    func gitDiffPillBackground() -> some View {
        #if os(visionOS)
        self.background(.regularMaterial, in: Capsule())
        #else
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
        }
        #endif
    }
}
