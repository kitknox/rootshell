//
//  AgentInboxView.swift
//  rootshell
//
//  The inbox panel content, shared by the sidebar column, the HUD and the
//  iPhone sheet. Rows are grouped by what has to happen, not by which agent
//  spoke. This is the only place besides the terminal that shows message text.
//

import SwiftUI

/// Open requests from outside a window: the island's deep link and a cold
/// launch that arrives before any `MainView` is listening.
@MainActor
@Observable
final class AgentInboxRouter {
    static let shared = AgentInboxRouter()

    /// Set until a window opens the inbox.
    var pendingOpen = false
    /// Flashed once so the row the person came for is findable.
    var highlightedID: String?

    func requestOpen(highlighting id: String? = nil) {
        highlightedID = id
        pendingOpen = true
    }
}

struct AgentInboxView: View {
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

    let style: Style
    let onClose: () -> Void
    /// Switches between presentations; nil where only one presentation exists.
    let onSwitchPresentation: ((PanelPresentation) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var store = AgentInboxStore.shared
    @State private var filter: Filter = .all
    @State private var highlight: String?
    @State private var flashTask: Task<Void, Never>?
    /// The row whose pane is no longer open, briefly.
    @State private var unreachableID: String?
    /// The row being resolved while a control-mode client reconnects.
    @State private var resolvingID: String?
    @State private var unreachableTask: Task<Void, Never>?
    /// Drives the relative timestamps.
    @State private var now = Date()

    enum Filter: String, CaseIterable, Identifiable {
        case all, needsYou, failed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "All Messages", comment: "Inbox filter")
            case .needsYou: String(localized: "Needs You", comment: "Inbox filter")
            case .failed: String(localized: "Failed Runs", comment: "Inbox filter")
            }
        }
    }

    private var sections: [AgentInboxSection] {
        switch filter {
        case .all: [.needsYou, .failed, .working, .done, .archived]
        case .needsYou: [.needsYou]
        case .failed: [.failed]
        }
    }

    /// A dark terminal theme can run under a light system scheme; semantic
    /// colours must resolve against the panel's own surface.
    private var surfaceScheme: ColorScheme {
        guard let theme = sheetThemeColors else { return colorScheme }
        return theme.isDarkSurface ? .dark : .light
    }

    private var cardFill: Color {
        sheetThemeColors?.cardFill ?? Color(uiColor: .secondarySystemGroupedBackground)
    }

    private var cardStroke: Color {
        sheetThemeColors?.cardStroke ?? Color(uiColor: .separator).opacity(0.5)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .environment(\.colorScheme, surfaceScheme)
        .background(style == .sheet ? sheetThemeColors?.background.ignoresSafeArea() : nil)
        .task {
            while !Task.isCancelled {
                now = Date()
                store.sweepExpired(now: now)
                try? await Task.sleep(for: .seconds(20))
            }
        }
        .onAppear {
            flash(AgentInboxRouter.shared.highlightedID)
            AgentInboxRouter.shared.highlightedID = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray").foregroundStyle(Color.accentColor)
            Text(String(localized: "Agent Inbox", comment: "Inbox title"))
                .font(.headline)
            Spacer(minLength: 4)
            if let onSwitchPresentation, let current = style.presentation {
                PanelPresentationMenu(current: current, onSwitch: onSwitchPresentation)
                    .equatable()
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .help(String(localized: "Close (esc)", comment: "Agent inbox close button tooltip"))
            .accessibilityLabel(String(localized: "Close Agent Inbox", comment: "Agent inbox close button"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List

    /// A native list: rows scroll only vertically, and archive is the
    /// system swipe action rather than a long-press lift.
    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            AgentInboxFilterBar(filter: $filter)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            if store.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Agent Messages", comment: "Inbox empty state title"),
                    systemImage: "tray",
                    description: Text(String(localized: "Hook messages from your agents land here.", comment: "Inbox empty state detail"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections, id: \.self) { section in
                        let rows = store.rows(in: section)
                        if !rows.isEmpty {
                            Section {
                                ForEach(rows) { row in
                                    rowView(row)
                                }
                            } header: {
                                AgentInboxSectionHeader(section: section, count: rows.count)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func rowView(_ row: AgentInboxRow) -> some View {
        let canArchive = row.section != .working && row.section != .archived
        return AgentInboxRowView(
            row: row,
            now: now,
            highlighted: highlight == row.id,
            unreachable: unreachableID == row.id,
            resolving: resolvingID == row.id,
            onOpen: { open(row) }
        )
        .listRowBackground(cardFill)
        .listRowSeparatorTint(cardStroke)
        .listRowInsets(EdgeInsets())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canArchive {
                Button { store.archive(row.id) } label: {
                    Label(String(localized: "Archive Message", comment: "Inbox row action"), systemImage: "archivebox")
                }
                .tint(.indigo)
            }
        }
        .contextMenu {
            if canArchive {
                Button { store.archive(row.id) } label: {
                    Label(String(localized: "Archive Message", comment: "Inbox row action"), systemImage: "archivebox")
                }
            }
        }
    }

    // MARK: - Actions

    /// Opening a row is the action: its pane opens and it moves to the
    /// archive. The docked column stays up beside the terminal; anything
    /// covering the terminal closes first. A pane that is gone says so instead
    /// of landing somewhere else.
    private func open(_ row: AgentInboxRow) {
        // An in-progress row is presence, not a message.
        guard row.section != .working, resolvingID == nil else { return }
        resolvingID = row.id
        Task { @MainActor in
            defer { resolvingID = nil }
            guard let target = await PushNotificationRouter.resolveInboxRowWhenReady(row) else {
                showUnreachable(row.id)
                return
            }
            store.archive(row.id)
            guard style != .sidebar else {
                PushNotificationRouter.navigate(to: target)
                return
            }
            onClose()
            // The sheet must finish dismissing, or the tab switch happens behind it.
            if style == .sheet { try? await Task.sleep(for: .milliseconds(350)) }
            PushNotificationRouter.navigate(to: PushNotificationRouter.resolveInboxRow(row) ?? target)
        }
    }

    private func showUnreachable(_ id: String) {
        unreachableID = id
        unreachableTask?.cancel()
        unreachableTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            unreachableID = nil
        }
    }

    private func flash(_ id: String?) {
        guard let id else { return }
        highlight = id
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            highlight = nil
        }
    }
}

private struct AgentInboxSectionHeader: View {
    let section: AgentInboxSection
    let count: Int

    var body: some View {
        HStack {
            Text(section.title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

private struct AgentInboxRowView: View {
    let row: AgentInboxRow
    let now: Date
    let highlighted: Bool
    let unreachable: Bool
    let resolving: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                AgentInboxGlyph(agent: row.agent)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.summary ?? AgentInboxGlyph.displayName(for: row.agent))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Hooks fire on several hosts at once; two rows can
                    // otherwise look identical.
                    if let host = row.host {
                        HStack(spacing: 5) {
                            AgentInboxHostChip(host: host)
                            if let tab = row.tab {
                                Text(tab)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.top, 1)
                    } else if let tab = row.tab {
                        Text(tab)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if unreachable {
                        Text(String(localized: "This pane is no longer open.", comment: "Inbox row: its pane cannot be found"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    if resolving {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(AgentInboxTime.short(row.receivedAt, now: now))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        AgentInboxStatusDot(status: row.status)
                        if let label = archivedStatusLabel {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(highlighted ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    /// The archive keeps the status the event had when it was moved there.
    private var archivedStatusLabel: String? {
        guard row.isArchived else { return nil }
        switch row.status {
        case .blocked: return String(localized: "Needs You", comment: "Archived row status")
        case .failed: return String(localized: "Failed Runs", comment: "Archived row status")
        case .done: return String(localized: "Finished", comment: "Archived row status")
        case .other: return String(localized: "In Progress", comment: "Archived row status")
        }
    }
}

/// The agent's mark, drawn like the sidebar and tab bar draw it.
struct AgentInboxGlyph: View {
    let agent: String

    var body: some View {
        let id = AgentInboxAgentID.manifestID(for: agent)
        if AgentBrandMark.mark(for: id) != nil {
            AgentBrandMark(agentID: id, size: 18)
                .frame(width: 22, height: 22)
        } else {
            AgentBrandMark(mark: .symbol("terminal"), size: 16)
                .frame(width: 22, height: 22)
        }
    }

    /// Product names are proper nouns and are not localized.
    static func displayName(for agent: String) -> String {
        switch AgentInboxAgentID.manifestID(for: agent) {
        case "claude": "Claude"
        case "codex": "Codex"
        case "pi": "Pi"
        case "omp": "oh-my-pi"
        case "dsh": "DeepSeek"
        case "hermes": "Hermes"
        default: agent
        }
    }
}

struct AgentInboxStatusDot: View {
    let status: AgentInboxStatus

    var body: some View {
        Group {
            if status == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .strokeBorder(color, lineWidth: status == .other ? 1.5 : 0)
                    .background(Circle().fill(status == .other ? .clear : color))
                    .frame(width: 11, height: 11)
            }
        }
        .frame(width: 15, height: 15)
    }

    private var color: Color {
        switch status {
        case .blocked: .orange
        case .done: .green
        case .failed: .red
        case .other: .green
        }
    }
}

/// Compact elapsed time; `Text(_, style: .relative)` reads like a stopwatch.
enum AgentInboxTime {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:
            return String(localized: "Just Now", comment: "Inbox relative time")
        case ..<3600:
            return String(format: String(localized: "%lld min ago", comment: "Inbox relative time"), Int(seconds / 60))
        case ..<86_400:
            return String(format: String(localized: "%lld hr ago", comment: "Inbox relative time"), Int(seconds / 3600))
        default:
            return String(format: String(localized: "%lld d ago", comment: "Inbox relative time"), Int(seconds / 86_400))
        }
    }
}

private struct AgentInboxFilterBar: View {
    @Binding var filter: AgentInboxView.Filter
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sheetThemeColors) private var sheetThemeColors

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentInboxView.Filter.allCases) { item in
                let selected = item == filter
                Button {
                    withAnimation(.snappy(duration: 0.18)) { filter = item }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selected ? selectedFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(sheetThemeColors?.controlFill ?? (colorScheme == .dark ? Color.white.opacity(0.06) : Color(uiColor: .secondarySystemGroupedBackground)))
        )
    }

    private var selectedFill: Color {
        sheetThemeColors?.selectedControlFill ?? (colorScheme == .dark ? Color.white.opacity(0.14) : Color(uiColor: .systemBackground))
    }
}

/// The machine a message came from.
struct AgentInboxHostChip: View {
    let host: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "server.rack")
                .font(.system(size: 8, weight: .semibold))
            Text(host)
                .font(.caption2.weight(.medium))
                .monospaced()
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05))
        )
        .accessibilityLabel(Text(String(localized: "Host", comment: "Inbox row host label") + " " + host))
    }
}
