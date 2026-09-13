// Copyright (c) 2026 Kit Knox / Rootshell LLC
import SwiftUI

struct HerdrManagementAction: Identifiable {
    enum Kind {
        case createWorkspace, renameWorkspace, closeWorkspace, moveWorkspace
        case createWorktree, openWorktree, removeWorktree
        case renameTab, closeTab, renamePane, movePane, swapPane

        var title: String {
            switch self {
            case .createWorkspace: String(localized: "New Workspace")
            case .renameWorkspace: String(localized: "Rename Workspace")
            case .closeWorkspace: String(localized: "Close Workspace")
            case .moveWorkspace: String(localized: "Reorder Workspace")
            case .createWorktree: String(localized: "New Worktree")
            case .openWorktree: String(localized: "Open Worktree")
            case .removeWorktree: String(localized: "Delete Worktree Checkout")
            case .renameTab: String(localized: "Rename Tab")
            case .closeTab: String(localized: "Close Tab")
            case .renamePane: String(localized: "Rename Pane")
            case .movePane: String(localized: "Move Pane")
            case .swapPane: String(localized: "Swap Pane")
            }
        }
        var destructive: Bool {
            self == .closeWorkspace || self == .closeTab || self == .removeWorktree
        }
    }
    let id = UUID()
    let kind: Kind
    let targetID: String?
}

struct HerdrWorkspaceDashboardRequest: Identifiable {
    let id = UUID()
    let controller: HerdrController
    var action: HerdrManagementAction?
}

struct HerdrWorkspaceMenuItems: View {
    let controller: HerdrController
    let workspaceID: String
    var onAction: ((HerdrManagementAction) -> Void)?

    private func action(_ kind: HerdrManagementAction.Kind) {
        let request = HerdrManagementAction(kind: kind, targetID: workspaceID)
        if let onAction { onAction(request) } else { controller.showWorkspaceOverview(action: request) }
    }

    var body: some View {
        Button("Switch to Workspace", systemImage: "arrow.right.circle") {
            controller.runManagement { try await controller.focusWorkspace(workspaceID) }
        }
        Button("New herdr Tab", systemImage: "plus.rectangle.on.rectangle") {
            controller.requestNewTab(workspaceID: workspaceID)
        }
        Button("New Workspace", systemImage: "plus.square.on.square") { action(.createWorkspace) }
        Button("Rename Workspace", systemImage: "pencil") { action(.renameWorkspace) }
        Button("Reorder Workspace", systemImage: "arrow.up.arrow.down") { action(.moveWorkspace) }
        Divider()
        Button("New Worktree", systemImage: "arrow.triangle.branch") { action(.createWorktree) }
        Button("Open Worktree…", systemImage: "folder") { action(.openWorktree) }
        if controller.workspaces[workspaceID]?.worktree?.is_linked_worktree == true {
            Button("Delete Worktree Checkout…", systemImage: "trash", role: .destructive) { action(.removeWorktree) }
        }
        let group = HerdrWorkspaceRules.group(of: workspaceID, in: controller.management.workspaces)
        Button(group.count > 1 ? String(localized: "Close Workspace Group…") : String(localized: "Close Workspace…"),
               systemImage: "xmark.circle", role: .destructive) { action(.closeWorkspace) }
    }
}

struct HerdrWorkspaceDashboardView: View {
    let request: HerdrWorkspaceDashboardRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetThemeColors) private var sheetThemeColors
    @State private var query = ""
    @State private var searching = false
    @State private var expanded = Set<String>()
    @State private var highlightedID: String?
    @State private var action: HerdrManagementAction?

    private var controller: HerdrController { request.controller }
    private var state: HerdrManagementState { controller.management }
    private var visibleWorkspaces: [HerdrControl.WorkspaceInfo] {
        HerdrWorkspaceRules.groups(state.workspaces).flatMap { $0 }.filter { workspace in
            query.isEmpty || workspace.label.localizedCaseInsensitiveContains(query)
                || workspace.worktree?.repo_name.localizedCaseInsensitiveContains(query) == true
                || state.tabs.contains { $0.workspace_id == workspace.workspace_id && $0.label.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let error = state.error {
                        Section {
                            Text(error).foregroundStyle(.red).textSelection(.enabled).themedRow()
                            Button("Dismiss Error") { state.error = nil }.themedRow()
                        }
                    }
                    if !state.isActive {
                        Section { Label("Waiting for herdr connection", systemImage: "wifi.exclamationmark").themedRow() }
                    }
                    ForEach(visibleWorkspaces, id: \.workspace_id) { workspace in
                        Section {
                            workspaceRow(workspace)
                                .id(workspace.workspace_id)
                            if expanded.contains(workspace.workspace_id) {
                                let tabs = state.tabs.filter { $0.workspace_id == workspace.workspace_id }
                                ForEach(tabs, id: \.tab_id) { tab in
                                    tabRow(tab)
                                        .themedRow()
                                }
                            }
                        } header: {
                            if let tree = workspace.worktree {
                                Text(tree.repo_name + (tree.is_linked_worktree ? " · " + String(localized: "Worktree") : ""))
                            }
                        }
                    }
                    if visibleWorkspaces.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "No Workspaces" : "No Matching Workspaces",
                            systemImage: "square.grid.2x2", description: Text("Create a workspace to start a shell."))
                            .themedRow()
                    }
                }
                .themedList()
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .searchable(text: $query, isPresented: $searching, prompt: "Workspaces and tabs")
            .navigationTitle("herdr Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    Button("New Workspace", systemImage: "plus") {
                        action = .init(kind: .createWorkspace, targetID: controller.selectedWorkspaceID)
                    }
                    .disabled(!state.isActive || state.isBusy)
                }
            }
            .refreshable { await refreshNow() }
            .background {
                HerdrOverviewKeyCommands(isActive: !searching && action == nil,
                    move: moveHighlight, select: activateHighlighted,
                    expand: {
                        guard let id = highlightedID else { return }
                        if !expanded.insert(id).inserted { expanded.remove(id) }
                    }, close: { dismiss() })
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .sheet(item: $action) { action in
            HerdrManagementActionView(controller: controller, action: action)
                .themedSubSheet(sheetThemeColors)
        }
        .task {
            controller.publishManagementState()
            highlightedID = controller.selectedWorkspaceID
            if let initial = request.action { action = initial }
            await refreshNow()
        }
    }

    private func workspaceRow(_ workspace: HerdrControl.WorkspaceInfo) -> some View {
        HStack {
            Button {
                if !expanded.insert(workspace.workspace_id).inserted { expanded.remove(workspace.workspace_id) }
            } label: {
                Image(systemName: expanded.contains(workspace.workspace_id) ? "chevron.down" : "chevron.right")
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expanded.contains(workspace.workspace_id) ? "Collapse workspace" : "Expand workspace")
            Button {
                highlightedID = workspace.workspace_id
                activateHighlighted()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.label).font(.headline)
                    let tabs = state.tabs.filter { $0.workspace_id == workspace.workspace_id }.count
                    let panes = state.panes.filter { $0.workspace_id == workspace.workspace_id }.count
                    Text("\(tabs) tabs · \(panes) panes · \(workspace.agent_status)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let path = workspace.worktree?.checkout_path {
                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            Menu {
                HerdrWorkspaceMenuItems(controller: controller, workspaceID: workspace.workspace_id,
                    onAction: { action = $0 })
            } label: { Image(systemName: "ellipsis.circle").frame(width: 36, height: 36) }
            .accessibilityLabel("Workspace actions")
        }
        .disabled(!state.isActive || state.isBusy)
        .listRowBackground(highlightedID == workspace.workspace_id
            ? (sheetThemeColors?.accentColor ?? Color.accentColor).opacity(0.18)
            : sheetThemeColors?.rowBackground)
    }

    private func tabRow(_ tab: HerdrControl.TabInfo) -> some View {
        DisclosureGroup {
            let panes = state.panes.filter { $0.tab_id == tab.tab_id }.sorted { $0.pane_id < $1.pane_id }
            ForEach(panes, id: \.pane_id) { pane in
                HStack {
                    Button(pane.label ?? pane.title ?? pane.terminal_title ?? pane.pane_id) {
                        controller.selectManagementPane(pane.pane_id)
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!state.isActive || state.isBusy)
                    Spacer()
                    Menu("Pane Actions", systemImage: "ellipsis.circle") {
                        Button("Rename Pane") { action = .init(kind: .renamePane, targetID: pane.pane_id) }
                        Button("Move Pane") { action = .init(kind: .movePane, targetID: pane.pane_id) }
                        Button("Swap Pane") { action = .init(kind: .swapPane, targetID: pane.pane_id) }
                            .disabled(panes.count < 2)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!state.isActive || state.isBusy)
                }
            }
            // Bound preview work to visible expanded rows. Each row captures
            // one focused pane once; it never polls or attaches a live client.
            if state.tabs.prefix(8).contains(where: { $0.tab_id == tab.tab_id }),
               let pane = panes.first(where: \.focused) ?? panes.first {
                HerdrWorkspacePreview(controller: controller, paneID: pane.pane_id)
            }
        } label: {
            HStack {
                Button(controller.tabs[tab.tab_id]?.title ?? tab.label) {
                    controller.selectManagementTab(tab.tab_id)
                    dismiss()
                }
                .buttonStyle(.borderless)
                .disabled(!state.isActive)
                Spacer()
                Menu("Tab Actions", systemImage: "ellipsis.circle") {
                    Button("Rename Tab") { action = .init(kind: .renameTab, targetID: tab.tab_id) }
                    Button("Close Tab…", role: .destructive) { action = .init(kind: .closeTab, targetID: tab.tab_id) }
                }
                .labelStyle(.iconOnly)
                .disabled(!state.isActive || state.isBusy)
            }
        }
    }

    private func moveHighlight(_ delta: Int) {
        let ids = visibleWorkspaces.map(\.workspace_id)
        guard !ids.isEmpty else { return }
        let current = highlightedID.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        highlightedID = ids[max(0, min(ids.count - 1, current + delta))]
    }
    private func activateHighlighted() {
        guard let id = highlightedID, state.isActive, !state.isBusy, action == nil else { return }
        Task {
            do {
                try await controller.performManagement { try await controller.focusWorkspace(id) }
                dismiss()
            } catch { state.error = error.localizedDescription }
        }
    }
    private func refresh() { Task { await refreshNow() } }
    private func refreshNow() async {
        guard state.isActive, !state.isBusy else { return }
        do { try await controller.refreshManagementSnapshot() }
        catch is CancellationError { }
        catch { state.error = error.localizedDescription }
    }
}

private struct HerdrWorkspacePreview: View {
    let controller: HerdrController
    let paneID: String
    @State private var content: String?
    @State private var failed = false

    var body: some View {
        Group {
            if let content {
                GeometryReader { geometry in
                    TmuxPreviewContainer(content: content, previewSize: .init(width: geometry.size.width / 0.5, height: 240))
                        .frame(width: geometry.size.width / 0.5, height: 240)
                        .scaleEffect(0.5, anchor: .topLeading)
                }
                .frame(height: 120).clipped().accessibilityLabel("Focused pane preview")
            } else if failed { Text("Preview unavailable").font(.caption).foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .task(id: paneID) {
            do {
                let data = try await controller.legacyRun(args: "pane read \(LoginShellCommand.singleQuoted(paneID)) --source visible --raw")
                guard !Task.isCancelled else { return }
                content = String(decoding: data, as: UTF8.self)
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
