// Copyright (c) 2026 Kit Knox / Rootshell LLC
import SwiftUI

struct HerdrManagementActionView: View {
    let controller: HerdrController
    let action: HerdrManagementAction
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory = ""
    @State private var branch = ""
    @State private var base = ""
    @State private var path = ""
    @State private var destination = ""
    @State private var destinationKind = "new_tab"
    @State private var split = "right"
    @State private var closeGroup = false
    @State private var trust = false
    @State private var needsTrust = false
    @State private var needsForce = false
    @State private var force = false
    @State private var errorMessage: String?
    @State private var worktrees: [HerdrControl.WorktreeInfo] = []
    @State private var query = ""
    @State private var pending = false
    @State private var initialized = false
    @State private var task: Task<Void, Never>?

    private var id: String { action.targetID ?? "" }
    private var state: HerdrManagementState { controller.management }
    private var workspace: HerdrControl.WorkspaceInfo? { state.workspaces.first { $0.workspace_id == id } }
    private var pane: HerdrControl.PaneInfo? { state.panes.first { $0.pane_id == id } }
    private var affectedWorkspaces: [HerdrControl.WorkspaceInfo] {
        closeGroup ? HerdrWorkspaceRules.group(of: id, in: state.workspaces) : workspace.map { [$0] } ?? []
    }
    private var workspaceDestinations: [HerdrControl.WorkspaceInfo] {
        let members = Set(HerdrWorkspaceRules.group(of: id, in: state.workspaces).map(\.workspace_id))
        if let tree = workspace?.worktree, tree.is_linked_worktree {
            return state.workspaces.filter {
                $0.workspace_id != id && $0.worktree?.repo_key == tree.repo_key && $0.worktree?.is_linked_worktree == true
            }
        }
        return HerdrWorkspaceRules.groups(state.workspaces).compactMap(\.first).filter { !members.contains($0.workspace_id) }
    }
    private var destinationTabs: [HerdrControl.TabInfo] { state.tabs.filter { $0.tab_id != pane?.tab_id } }
    private var swapTargets: [HerdrControl.PaneInfo] {
        state.panes.filter { $0.tab_id == pane?.tab_id && $0.pane_id != id }.sorted { $0.pane_id < $1.pane_id }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).textSelection(.enabled).themedRow() }
                }
                fields
                if needsTrust {
                    Section {
                        Toggle("Trust this repository for this action", isOn: $trust).themedRow()
                    } footer: {
                        Text("Herdr will trust this repository’s resolved path for this request. Your Git configuration is unchanged.")
                    }
                }
                if needsForce {
                    Section {
                        Toggle("Delete uncommitted changes in this checkout", isOn: $force).themedRow()
                    } footer: {
                        Text("Git refused to remove the dirty checkout. Forced deletion permanently removes its uncommitted files.")
                    }
                }
            }
            .themedList()
            .autocorrectionDisabled()
            #if !os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .navigationTitle(action.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(pending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if pending { ProgressView() }
                    else {
                        Button(action.kind == .openWorktree && worktrees.isEmpty ? String(localized: "Load Worktrees") : action.kind.title,
                               role: action.kind.destructive ? .destructive : nil) { submit() }
                            .disabled(!canSubmit || !state.isActive || state.isBusy)
                    }
                }
            }
        }
        .interactiveDismissDisabled(pending)
        .onAppear(perform: seed)
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private var fields: some View {
        switch action.kind {
        case .createWorkspace:
            Section("Workspace") {
                TextField("Name (optional)", text: $name).themedRow()
                TextField("Remote directory (optional)", text: $directory).themedRow()
            }
            Section { Text("Creates a workspace with its first tab and shell on the connected host.").foregroundStyle(.secondary).themedRow() }
        case .renameWorkspace, .renameTab, .renamePane:
            Section { TextField("Name", text: $name).themedRow() }
            if action.kind == .renamePane {
                Section { Text("Leave blank to restore live agent and program titles.").foregroundStyle(.secondary).themedRow() }
            }
        case .closeWorkspace:
            Section("Workspaces to close") {
                ForEach(affectedWorkspaces, id: \.workspace_id) { workspace in
                    let tabs = state.tabs.filter { $0.workspace_id == workspace.workspace_id }.count
                    let panes = state.panes.filter { $0.workspace_id == workspace.workspace_id }.count
                    LabeledContent(workspace.label, value: "\(tabs) tabs · \(panes) panes").themedRow()
                }
            }
            Section { Text("Closes these shells and panes. Git worktree checkouts and branches remain on the host.").foregroundStyle(.secondary).themedRow() }
        case .closeTab:
            Section {
                Text(state.tabs.first { $0.tab_id == id }?.label ?? id).font(.headline).themedRow()
                Text("Closes this tab and all of its panes.").foregroundStyle(.secondary).themedRow()
            }
        case .moveWorkspace:
            Section {
                Picker("Place before", selection: $destination) {
                    ForEach(workspaceDestinations, id: \.workspace_id) { workspace in
                        Text(workspace.label).tag(workspace.workspace_id)
                    }
                    Text(workspace?.worktree?.is_linked_worktree == true ? "End of repository group" : "End of workspace list").tag("")
                }
                .themedRow()
            }
            if HerdrWorkspaceRules.group(of: id, in: state.workspaces).count > 1 {
                Section { Text("The repository workspace and its linked workspaces move together.").foregroundStyle(.secondary).themedRow() }
            }
        case .createWorktree:
            Section("Worktree") {
                Text(workspace?.label ?? id).font(.headline).themedRow()
                TextField("Branch", text: $branch).themedRow()
                TextField("Base ref (default: HEAD)", text: $base).themedRow()
                TextField("Absolute checkout path (optional)", text: $path).themedRow()
                TextField("Workspace name (optional)", text: $name).themedRow()
            }
            Section { Text("Herdr uses an existing local branch or creates one from the base ref. Leave the path blank to use the host’s worktree directory.").foregroundStyle(.secondary).themedRow() }
        case .openWorktree:
            Section {
                TextField("Search worktrees", text: $query).themedRow()
                ForEach(worktrees.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }) { tree in
                    Button {
                        path = tree.path
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(tree.branch ?? tree.label)
                                Text(tree.path).font(.caption).foregroundStyle(.secondary)
                                if tree.open_workspace_id != nil { Text("Already open").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if path == tree.path { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(tree.is_bare || tree.is_prunable)
                    .themedRow()
                }
                if worktrees.isEmpty { Text("Load the repository’s existing worktrees, then choose a checkout.").foregroundStyle(.secondary).themedRow() }
                else {
                    Button("Reload Worktrees") { submit(loadWorktrees: true) }
                        .disabled(pending || !state.isActive || state.isBusy)
                        .themedRow()
                }
            }
        case .removeWorktree:
            Section {
                Text(workspace?.label ?? id).font(.headline).themedRow()
                if let path = workspace?.worktree?.checkout_path { Text(path).textSelection(.enabled).themedRow() }
                Text("Deletes this linked checkout from disk and closes its workspace. The Git branch is kept.").foregroundStyle(.secondary).themedRow()
            }
        case .movePane:
            Section {
                Picker("Destination", selection: $destinationKind) {
                    Text("New tab").tag("new_tab")
                    Text("Existing tab").tag("tab")
                    Text("New workspace").tag("new_workspace")
                }
                .themedRow()
                if destinationKind == "new_tab" {
                    Picker("Workspace", selection: $destination) {
                        ForEach(state.workspaces, id: \.workspace_id) { Text($0.label).tag($0.workspace_id) }
                    }
                    .themedRow()
                } else if destinationKind == "tab" {
                    Picker("Tab", selection: $destination) {
                        ForEach(destinationTabs, id: \.tab_id) { tab in
                            Text((state.workspaces.first { $0.workspace_id == tab.workspace_id }?.label ?? tab.workspace_id) + " · " + tab.label).tag(tab.tab_id)
                        }
                    }
                    .themedRow()
                    Picker("Split", selection: $split) {
                        Text("Right").tag("right")
                        Text("Down").tag("down")
                    }
                    .themedRow()
                }
            }
            .onChange(of: destinationKind) { _, kind in
                destination = kind == "tab" ? destinationTabs.first?.tab_id ?? "" : pane?.workspace_id ?? ""
            }
            Section { Text("The terminal process keeps running. Herdr closes the source tab or workspace if it becomes empty.").foregroundStyle(.secondary).themedRow() }
        case .swapPane:
            Section {
                Picker("Swap with", selection: $destination) {
                    ForEach(swapTargets, id: \.pane_id) { pane in
                        Text(pane.label ?? pane.title ?? pane.terminal_title ?? pane.pane_id).tag(pane.pane_id)
                    }
                }
                .themedRow()
                if swapTargets.isEmpty { Text("No other panes in this tab.").foregroundStyle(.secondary).themedRow() }
            }
        }
    }

    private var canSubmit: Bool {
        if needsTrust && !trust { return false }
        if needsForce && !force { return false }
        switch action.kind {
        case .renameWorkspace, .renameTab: return cleaned(name) != nil
        case .createWorktree: return cleaned(branch) != nil
        case .openWorktree: return worktrees.isEmpty || !path.isEmpty
        case .swapPane: return swapTargets.contains { $0.pane_id == destination }
        case .movePane:
            return destinationKind == "new_workspace" || (destinationKind == "tab"
                ? destinationTabs.contains { $0.tab_id == destination }
                : state.workspaces.contains { $0.workspace_id == destination })
        default: return true
        }
    }

    private func seed() {
        guard !initialized else { return }
        initialized = true
        switch action.kind {
        case .createWorkspace: directory = controller.workspaceDirectory(action.targetID) ?? ""
        case .renameWorkspace: name = workspace?.label ?? ""
        case .renameTab: name = controller.tabNames.name(for: id) ?? controller.tabInfos[id]?.label ?? ""
        case .renamePane: name = pane?.label ?? ""
        case .closeWorkspace: closeGroup = HerdrWorkspaceRules.group(of: id, in: state.workspaces).count > 1
        case .movePane: destination = pane?.workspace_id ?? ""
        case .swapPane: destination = swapTargets.first?.pane_id ?? ""
        default: break
        }
    }

    private func cleaned(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func submit(loadWorktrees: Bool = false) {
        guard !pending, state.isActive, !state.isBusy,
              loadWorktrees || canSubmit else { return }
        pending = true
        errorMessage = nil
        task = Task {
            defer { pending = false }
            do {
                if action.kind == .openWorktree, loadWorktrees || worktrees.isEmpty {
                    worktrees = try await controller.listWorktrees(id, trust: trust)
                    if !worktrees.contains(where: { $0.path == path }) { path = "" }
                    if worktrees.isEmpty { errorMessage = String(localized: "No worktrees were found in this repository.") }
                    return
                }
                try await controller.performManagement { try await execute() }
                guard !Task.isCancelled else { return }
                dismiss()
            } catch is CancellationError {
                if !Task.isCancelled {
                    errorMessage = String(localized: "The herdr connection changed during this action. Refresh and check its state before trying again.")
                }
            }
            catch {
                guard !Task.isCancelled else { return }
                errorMessage = controller.managementFailureDescription(error)
                if case HerdrChannelError.remote(let code, _) = error {
                    if code == "dirty_worktree_requires_force" { needsForce = true }
                    if code == "workspace_group_close_required" {
                        closeGroup = true
                        errorMessage = String(localized: "This repository has linked workspaces. Review the group above, then confirm closure again.")
                    }
                }
                let description = error.localizedDescription.lowercased()
                needsTrust = needsTrust || description.contains("dubious ownership") || description.contains("safe.directory")
            }
        }
    }

    private func execute() async throws {
        switch action.kind {
        case .createWorkspace: try await controller.createWorkspace(label: cleaned(name), cwd: cleaned(directory))
        case .renameWorkspace: try await controller.renameWorkspace(id, label: name.trimmingCharacters(in: .whitespacesAndNewlines))
        case .closeWorkspace: try await controller.closeWorkspace(id, group: closeGroup)
        case .moveWorkspace:
            var before = cleaned(destination)
            if before == nil, let tree = workspace?.worktree, tree.is_linked_worktree {
                let groups = HerdrWorkspaceRules.groups(state.workspaces)
                if let index = groups.firstIndex(where: { $0.contains { $0.workspace_id == id } }), index + 1 < groups.count {
                    before = groups[index + 1].first?.workspace_id
                }
            }
            try await controller.moveWorkspace(id, before: before)
        case .createWorktree:
            try await controller.createWorktree(.init(workspace_id: id, branch: branch.trimmingCharacters(in: .whitespacesAndNewlines),
                base: cleaned(base), path: cleaned(path), label: cleaned(name), trust_repository: trust))
        case .openWorktree: try await controller.openWorktree(.init(workspace_id: id, path: path, trust_repository: trust))
        case .removeWorktree: try await controller.removeWorktree(.init(workspace_id: id, force: force, trust_repository: trust))
        case .renameTab: try await controller.renameManagedTab(id, label: name.trimmingCharacters(in: .whitespacesAndNewlines))
        case .closeTab:
            let _: HerdrControl.OKResult = try await controller.managementRequest("tab.close", HerdrControl.TabTarget(tab_id: id),
                as: HerdrControl.OKResult.self, legacyArgs: "tab close \(LoginShellCommand.singleQuoted(id))")
        case .renamePane: try await controller.renamePane(id, label: cleaned(name))
        case .swapPane: try await controller.swapPanes(id, destination)
        case .movePane:
            try await controller.movePane(id, destination: .init(type: destinationKind,
                tab_id: destinationKind == "tab" ? destination : nil,
                workspace_id: destinationKind == "new_tab" ? destination : nil,
                split: destinationKind == "tab" ? split : nil))
        }
    }
}
