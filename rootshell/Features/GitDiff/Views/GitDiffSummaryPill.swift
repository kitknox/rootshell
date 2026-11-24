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
    /// Maximum outer pill width (the HUD clamps to the screen minus its insets).
    var maxWidth: CGFloat? = nil
    let onExpand: () -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    private static let horizontalPadding: CGFloat = 14

    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var palette: GitDiffPalette { GitDiffPalette(isDark: surfaceScheme == .dark) }

    private var innerMaxWidth: CGFloat? {
        maxWidth.map { max(0, $0 - Self.horizontalPadding * 2) }
    }

    var body: some View {
        Button(action: onExpand) {
            GitDiffPillRowLayout(spacing: 8, maxWidth: innerMaxWidth) {
                Image(systemName: GitDiffView.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .layoutValue(key: GitDiffPillSlotKey.self, value: .chrome)
                summary
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .layoutValue(key: GitDiffPillSlotKey.self, value: .chrome)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 8)
            .frame(minHeight: 38)
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
                    .font(.subheadline.monospaced().weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .leading)
                    .clipped()
                    .layoutValue(key: GitDiffPillSlotKey.self, value: .branch)
            }
            if snapshot.isClean {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.addition)
            } else {
                Label {
                    Text(verbatim: "\(snapshot.files.count)")
                } icon: {
                    Image(systemName: "doc")
                }
                .labelStyle(GitDiffPillLabelStyle())
                .font(.subheadline.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .layoutValue(key: GitDiffPillSlotKey.self, value: .secondary)
                GitDiffStatLabel(additions: snapshot.additions, deletions: snapshot.deletions, palette: palette,
                                 isPartial: snapshot.countsIncomplete, allowsShrinking: true)
            }
        } else {
            switch store.phase {
            case .loading, .ready:
                ProgressView().controlSize(.small)
            case .unavailable, .unsupportedPane:
                Text(String(localized: "No repository", comment: "Git diff summary pill: the pane is not in a repository"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                    .clipped()
            case .disconnected, .helperUnavailable, .gitFailed, .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
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

nonisolated private enum GitDiffPillSlot {
    case chrome
    case branch
    case secondary
    case content
}

nonisolated private struct GitDiffPillSlotKey: LayoutValueKey {
    static let defaultValue: GitDiffPillSlot = .content
}

/// Measures the pill at its natural width up to `maxWidth` even when the HUD
/// host probes with `layoutFittingCompressedSize` (proposed width 0). On narrow
/// screens or large Dynamic Type, shortens then omits the branch first, drops
/// the secondary file count if needed, and shrinks the primary stat/status text
/// inside its allocated slot so it never overlaps the expand chevron.
private struct GitDiffPillRowLayout: Layout {
    let spacing: CGFloat
    let maxWidth: CGFloat?

    private static let maxBranchWidth: CGFloat = 180
    private static let minBranchWidth: CGFloat = 48

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let plan = layoutPlan(for: budget(from: proposal), subviews: subviews)
        return CGSize(width: plan.totalWidth, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = layoutPlan(for: bounds.width, subviews: subviews)
        var x = bounds.minX
        var placedAny = false
        for (index, subview) in subviews.enumerated() {
            guard let width = plan.widths[index] else {
                subview.place(at: bounds.origin, proposal: .zero)
                continue
            }
            if placedAny { x += spacing }
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width
            placedAny = true
        }
    }

    private func budget(from proposal: ProposedViewSize) -> CGFloat {
        if let proposed = proposal.width, proposed > 0 {
            return min(proposed, maxWidth ?? .infinity)
        }
        return maxWidth ?? .infinity
    }

    private struct Plan {
        let widths: [CGFloat?]
        let totalWidth: CGFloat
        let height: CGFloat
    }

    private func layoutPlan(for budget: CGFloat, subviews: Subviews) -> Plan {
        guard !subviews.isEmpty else { return Plan(widths: [], totalWidth: 0, height: 0) }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let slots = subviews.map { $0[GitDiffPillSlotKey.self] }

        var widths: [CGFloat?] = Array(repeating: nil, count: subviews.count)
        var chromeIndices: [Int] = []
        var contentIndices: [Int] = []
        var secondaryIndices: [Int] = []
        var branchIndex: Int?
        var chromeWidth: CGFloat = 0
        var contentWidth: CGFloat = 0
        var secondaryWidth: CGFloat = 0

        for index in subviews.indices {
            switch slots[index] {
            case .chrome:
                chromeIndices.append(index)
                chromeWidth += ideal[index].width
                widths[index] = ideal[index].width
            case .content:
                contentIndices.append(index)
                contentWidth += ideal[index].width
                widths[index] = ideal[index].width
            case .secondary:
                secondaryIndices.append(index)
                secondaryWidth += ideal[index].width
            case .branch:
                branchIndex = index
            }
        }

        var includedCount = chromeIndices.count + contentIndices.count
        var usedWidth = chromeWidth + contentWidth + CGFloat(max(0, includedCount - 1)) * spacing

        // Keep the secondary file count when it fits cleanly alongside chrome + primary content.
        var secondaryFits = true
        if !secondaryIndices.isEmpty {
            let addedGaps = CGFloat(secondaryIndices.count - (includedCount == 0 ? 1 : 0)) * spacing
            if usedWidth + secondaryWidth + addedGaps <= budget {
                for index in secondaryIndices { widths[index] = ideal[index].width }
                includedCount += secondaryIndices.count
                usedWidth += secondaryWidth + addedGaps
            } else {
                secondaryFits = false
            }
        }

        // Only show the branch when the file count also fits; shorten it down
        // to `minBranchWidth`, or omit it if room is too tight.
        if secondaryFits, let branchIndex {
            let idealBranch = ideal[branchIndex].width
            let remaining = budget - usedWidth - (includedCount == 0 ? 0 : spacing)
            let minimum = min(idealBranch, Self.minBranchWidth)
            if remaining >= minimum {
                let allocated = min(idealBranch, min(Self.maxBranchWidth, remaining))
                widths[branchIndex] = allocated
                includedCount += 1
                usedWidth += allocated + (includedCount > 1 ? spacing : 0)
            }
        }

        // If even chrome + primary content exceed the budget (extreme Accessibility
        // text sizes on a narrow phone), shrink primary content inside its slot
        // while keeping chrome icons intact.
        var activeIndices = widths.indices.filter { widths[$0] != nil }
        var activeGaps = CGFloat(max(0, activeIndices.count - 1)) * spacing
        var totalWidth = activeIndices.reduce(CGFloat(0)) { $0 + (widths[$1] ?? 0) } + activeGaps
        if totalWidth > budget, budget.isFinite, contentWidth > 0, !contentIndices.isEmpty {
            let availableForContent = max(0, budget - chromeWidth - activeGaps)
            let scale = min(1, availableForContent / contentWidth)
            for index in contentIndices {
                widths[index] = (ideal[index].width * scale).rounded(.down)
            }
            activeIndices = widths.indices.filter { widths[$0] != nil }
            activeGaps = CGFloat(max(0, activeIndices.count - 1)) * spacing
            totalWidth = activeIndices.reduce(CGFloat(0)) { $0 + (widths[$1] ?? 0) } + activeGaps
        }

        let height = activeIndices.reduce(CGFloat(0)) { max($0, ideal[$1].height) }
        return Plan(widths: widths, totalWidth: min(totalWidth, budget), height: height)
    }
}

private struct GitDiffPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption.weight(.semibold))
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
