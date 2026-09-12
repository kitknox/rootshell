// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation
import Observation

@MainActor @Observable
final class HerdrManagementState {
    var workspaces: [HerdrControl.WorkspaceInfo] = []
    var tabs: [HerdrControl.TabInfo] = []
    var panes: [HerdrControl.PaneInfo] = []
    var isActive = false
    var pending = Set<UUID>()
    var error: String?
    var isBusy: Bool { !pending.isEmpty }
}

extension HerdrController {
    func publishManagementState() {
        let ordered = HerdrWorkspaceRules.ordered(Array(workspaces.values))
        // Pane titles can update frequently. Keep the sidebar's workspace
        // grouping observation quiet unless workspace metadata changes.
        if management.workspaces != ordered { management.workspaces = ordered }
        management.tabs = projectedTabOrder().compactMap { tabInfos[$0] }
        management.panes = Array(paneInfos.values)
        management.isActive = isActive && !didEnd
    }

    func showWorkspaceOverview(action: HerdrManagementAction? = nil) {
        NotificationCenter.default.post(name: .showHerdrWorkspaces, object: self,
            userInfo: action.map { ["action": $0] })
    }

    var selectedWorkspaceID: String? {
        tabs.values.first(where: { $0.id == tabsModel.selectedTabID })?.herdrWorkspaceId
            ?? workspaces.values.first(where: \.focused)?.workspace_id
            ?? management.workspaces.first?.workspace_id
    }

    func workspaceDirectory(_ workspaceID: String?) -> String? {
        guard let workspaceID else { return nil }
        let active = tabs.values.first(where: { $0.id == tabsModel.selectedTabID && $0.herdrWorkspaceId == workspaceID })
            ?? workspaces[workspaceID].flatMap { tabs[$0.active_tab_id] }
        if let paneID = active?.focusedTerminal?.herdrPaneBinding?.paneId,
           let path = paneInfos[paneID]?.projectPath { return path }
        return workspaces[workspaceID]?.worktree?.checkout_path
    }

    /// Choose a transport before writing. Never retry on a different route
    /// after a timeout or connection failure: the mutation may have succeeded.
    func managementRequest<P: Encodable, R: Decodable>(
        _ method: String, _ params: P, as: R.Type, legacyArgs: String? = nil
    ) async throws -> R {
        guard isActive, !didEnd else { throw HerdrChannelError.closed }
        let generation = streamGeneration
        let result: R
        do {
            if let channel {
                result = try await channel.request(method, params, as: R.self)
            } else if let endpoint, endpointActive, endpoint.boot != nil, endpoint.methods.contains(method) {
                let data = try JSONEncoder().encode(params)
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let response = try await endpoint.request(method, object)
                result = try HerdrControl.decoder.decode(HerdrControl.Response<R>.self, from: response).result
            } else if let legacyArgs {
                result = try await legacyRequest(args: legacyArgs, as: R.self)
            } else {
                result = try await legacyAPIRequest(method, params, as: R.self)
            }
        } catch {
            guard !Task.isCancelled, !didEnd, generation == streamGeneration else { throw CancellationError() }
            throw error
        }
        guard !Task.isCancelled, !didEnd, generation == streamGeneration else { throw CancellationError() }
        return result
    }

    /// The controller owns duplicate suppression even when two different
    /// surfaces open the same action. A readback is useful after failures too.
    func performManagement(_ operation: () async throws -> Void) async throws {
        guard management.pending.isEmpty else {
            throw HerdrChannelError.remote(code: "operation_pending", message: String(localized: "Another herdr action is still running."))
        }
        let id = UUID()
        let generation = streamGeneration
        management.pending.insert(id)
        managementRevision &+= 1
        defer {
            management.pending.remove(id)
            managementRevision &+= 1
            if !didEnd, generation == streamGeneration {
                legacySnapshotFingerprint = nil
                refreshTopology()
                publishSessionState()
            }
        }
        do {
            try await operation()
            guard generation == streamGeneration, !didEnd, !Task.isCancelled else { throw CancellationError() }
        } catch {
            guard generation == streamGeneration, !didEnd, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }

    func runManagement(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do { try await self.performManagement(operation) }
            catch is CancellationError { }
            catch {
                let message = self.managementFailureDescription(error)
                self.management.error = message
                self.presentTabErrorIfNeeded(title: String(localized: "herdr Action Failed"), message: message)
            }
        }
    }

    func managementFailureDescription(_ error: Error) -> String {
        if let channelError = error as? HerdrChannelError {
            switch channelError {
            case .remote, .unsupportedServer, .herdrMissing: return error.localizedDescription
            case .closed, .timedOut, .malformed: break
            }
        }
        return error.localizedDescription + "\n" + String(localized: "The action may have completed. Refresh and check herdr state before trying again.")
    }

    func refreshManagementSnapshot() async throws {
        let orderRevision = tabReorderRevision
        let revision = managementRevision
        let snapshot = try await managementRequest("session.snapshot", HerdrControl.EmptyParams(),
            as: HerdrControl.SessionSnapshotResult.self, legacyArgs: "api snapshot").snapshot
        guard orderRevision == tabReorderRevision, revision == managementRevision else { refreshTopology(); return }
        applySnapshot(snapshot)
    }

    /// Once the mutation is acknowledged, a failed readback must not leave its
    /// confirmation open to submit the same destructive action a second time.
    private func refreshAfterManagement() async throws {
        do { try await refreshManagementSnapshot() }
        catch is CancellationError { throw CancellationError() }
        catch {
            management.error = String(localized: "The action completed, but refreshing herdr state failed. Refresh the workspace overview to see the current state.") + "\n" + error.localizedDescription
        }
    }

    func focusWorkspace(_ id: String) async throws {
        let selection = tabsModel.selectionRevision
        let result = try await managementRequest("workspace.focus", HerdrControl.WorkspaceTarget(workspace_id: id),
            as: HerdrControl.WorkspaceResult.self, legacyArgs: "workspace focus \(LoginShellCommand.singleQuoted(id))")
        workspaces[id] = result.workspace
        if tabsModel.selectionRevision == selection { selectManagementTab(result.workspace.active_tab_id) }
        publishSessionState()
    }

    func selectManagementTab(_ id: String) {
        guard let tab = tabs[id] else { refreshTopology(); return }
        tabsModel.selectedTabID = tab.id
        tabsModel.pendingScrollToTabID = tab.id
        showPanesIfSelected(in: tab)
        if mode == .legacy { reconcileEndpoint() }
        if let pane = tab.focusedTerminal { requestSelectPane(pane) }
    }

    /// Explicit pane selection is user intent, even when its tab was already
    /// selected. Reconcile the endpoint before focusing a newly visible pane.
    func selectManagementPane(_ id: String) {
        guard let info = paneInfos[id], let tab = tabs[info.tab_id],
              let view = paneViews[info.terminal_id] else { refreshTopology(); return }
        selectTab(containingPane: id, focusPane: false)
        if mode == .legacy { reconcileEndpoint() }
        focusPane(view, in: tab)
        requestSelectPane(view)
    }

    func acceptManagedCreation(_ created: HerdrControl.TabCreatedResult, selectionRevision: UInt64) {
        if let workspace = created.workspace { workspaces[workspace.workspace_id] = workspace }
        ensureTab(created.tab)
        paneDidAppear(created.root_pane)
        if mode == .raw, let tab = tabs[created.tab.tab_id], tab.splitTree.isEmpty,
           let view = paneViews[created.root_pane.terminal_id] {
            tab.splitTree = SplitTree(root: .leaf(view: view), zoomed: nil)
        }
        reorderTabs()
        refreshWorkspaceGroups()
        if tabsModel.selectionRevision == selectionRevision {
            selectManagementTab(created.tab.tab_id)
        }
        autoHideGatewayIfWanted()
    }

    func createWorkspace(label: String?, cwd: String?) async throws {
        let selection = tabsModel.selectionRevision
        var args = "workspace create --no-focus"
        if let label { args += " --label \(LoginShellCommand.singleQuoted(label))" }
        if let cwd { args += " --cwd \(LoginShellCommand.singleQuoted(cwd))" }
        let result = try await managementRequest("workspace.create",
            HerdrControl.WorkspaceCreateParams(focus: false, label: label, cwd: cwd),
            as: HerdrControl.TabCreatedResult.self, legacyArgs: args)
        acceptManagedCreation(result, selectionRevision: selection)
    }

    func renameWorkspace(_ id: String, label: String) async throws {
        let result = try await managementRequest("workspace.rename",
            HerdrControl.WorkspaceRenameParams(workspace_id: id, label: label),
            as: HerdrControl.WorkspaceResult.self,
            legacyArgs: "workspace rename \(LoginShellCommand.singleQuoted(id)) \(LoginShellCommand.singleQuoted(label))")
        workspaces[id] = result.workspace
        refreshWorkspaceGroups()
    }

    func closeWorkspace(_ id: String, group: Bool) async throws {
        let _: HerdrControl.OKResult = try await managementRequest("workspace.close",
            HerdrControl.WorkspaceCloseParams(workspace_id: id, close_group: group), as: HerdrControl.OKResult.self,
            legacyArgs: "workspace close \(LoginShellCommand.singleQuoted(id))" + (group ? " --group" : ""))
        try await refreshAfterManagement()
    }

    func moveWorkspace(_ id: String, before target: String?) async throws {
        // Resolve indices from a fresh list; workspace numbers are positions,
        // whereas stable tab numbers must never be used as insertion indices.
        let listed = try await managementRequest("workspace.list", HerdrControl.EmptyParams(),
            as: HerdrControl.WorkspaceListResult.self, legacyArgs: "workspace list").workspaces
        let members = HerdrWorkspaceRules.group(of: id, in: listed).map(\.workspace_id)
        guard !members.isEmpty, !members.contains(target ?? "") else { return }
        if let target, !listed.contains(where: { $0.workspace_id == target }) {
            throw HerdrChannelError.remote(code: "workspace_not_found", message: String(localized: "The destination workspace was closed."))
        }
        let result: HerdrControl.WorkspaceListResult
        if members.count > 1 {
            result = try await managementRequest("workspace.move_block",
                HerdrControl.WorkspaceMoveBlockParams(workspace_ids: members, before_workspace_id: target),
                as: HerdrControl.WorkspaceListResult.self)
        } else {
            let index = target.flatMap { target in listed.firstIndex(where: { $0.workspace_id == target }) } ?? listed.count
            result = try await managementRequest("workspace.move",
                HerdrControl.WorkspaceMoveParams(workspace_id: id, insert_index: index),
                as: HerdrControl.WorkspaceListResult.self)
        }
        workspaces = Dictionary(result.workspaces.map { ($0.workspace_id, $0) }, uniquingKeysWith: { _, last in last })
        reorderTabs()
        refreshWorkspaceGroups()
    }

    func listWorktrees(_ id: String, trust: Bool) async throws -> [HerdrControl.WorktreeInfo] {
        try await managementRequest("worktree.list", HerdrControl.WorktreeListParams(workspace_id: id, trust_repository: trust),
            as: HerdrControl.WorktreeListResult.self,
            legacyArgs: "worktree list --workspace \(LoginShellCommand.singleQuoted(id))" + (trust ? " --trust-repository" : "")).worktrees
    }

    func createWorktree(_ params: HerdrControl.WorktreeCreateParams) async throws {
        let selection = tabsModel.selectionRevision
        var args = "worktree create --workspace \(LoginShellCommand.singleQuoted(params.workspace_id)) --branch \(LoginShellCommand.singleQuoted(params.branch)) --no-focus"
        for (flag, value) in [("--base", params.base), ("--path", params.path), ("--label", params.label)] {
            if let value { args += " \(flag) \(LoginShellCommand.singleQuoted(value))" }
        }
        if params.trust_repository { args += " --trust-repository" }
        let result = try await managementRequest("worktree.create", params, as: HerdrControl.TabCreatedResult.self, legacyArgs: args)
        acceptManagedCreation(result, selectionRevision: selection)
    }

    func openWorktree(_ params: HerdrControl.WorktreeOpenParams) async throws {
        let selection = tabsModel.selectionRevision
        let result = try await managementRequest("worktree.open", params, as: HerdrControl.TabCreatedResult.self,
            legacyArgs: "worktree open --workspace \(LoginShellCommand.singleQuoted(params.workspace_id)) --path \(LoginShellCommand.singleQuoted(params.path)) --no-focus" + (params.trust_repository ? " --trust-repository" : ""))
        acceptManagedCreation(result, selectionRevision: selection)
    }

    func removeWorktree(_ params: HerdrControl.WorktreeRemoveParams) async throws {
        let _: HerdrControl.OKResult = try await managementRequest("worktree.remove", params, as: HerdrControl.OKResult.self,
            legacyArgs: "worktree remove --workspace \(LoginShellCommand.singleQuoted(params.workspace_id))" + (params.force ? " --force" : "") + (params.trust_repository ? " --trust-repository" : ""))
        try await refreshAfterManagement()
    }

    func renameManagedTab(_ id: String, label: String) async throws {
        let result = try await managementRequest("tab.rename", HerdrControl.TabRenameParams(tab_id: id, label: label),
            as: HerdrControl.TabResult.self,
            legacyArgs: "tab rename \(LoginShellCommand.singleQuoted(id)) \(LoginShellCommand.singleQuoted(label))")
        tabNames.renamed(id, label: result.tab.label)
        tabDidRename(tabId: id, label: result.tab.label)
    }

    func renamePane(_ id: String, label: String?) async throws {
        let result = try await managementRequest("pane.rename", HerdrControl.PaneRenameParams(pane_id: id, label: label),
            as: HerdrControl.PaneResult.self,
            legacyArgs: "pane rename \(LoginShellCommand.singleQuoted(id)) " + (label.map(LoginShellCommand.singleQuoted) ?? "--clear"))
        // A bound pane's name now belongs to herdr, superseding an older
        // rootshell-only override made before native pane management existed.
        paneViews[result.pane.terminal_id]?.userOverrideTitle = nil
        paneDidUpdate(result.pane)
    }

    func swapPanes(_ source: String, _ target: String) async throws {
        let result = try await managementRequest("pane.swap",
            HerdrControl.PaneSwapParams(source_pane_id: source, target_pane_id: target),
            as: HerdrControl.PaneSwapResult.self,
            legacyArgs: "pane swap --source-pane \(LoginShellCommand.singleQuoted(source)) --target-pane \(LoginShellCommand.singleQuoted(target))")
        if !result.swap.changed {
            throw HerdrChannelError.remote(code: result.swap.reason ?? "pane_swap_failed", message: String(localized: "These panes can no longer be swapped. Refresh and choose panes in the same tab."))
        }
        try await refreshAfterManagement()
    }

    func movePane(_ id: String, destination: HerdrControl.PaneMoveParams.Destination) async throws {
        guard let terminalID = paneInfos[id]?.terminal_id else {
            throw HerdrChannelError.remote(code: "pane_not_found", message: String(localized: "This pane is no longer available."))
        }
        let moveID = UUID()
        pendingPaneMoveTerminals[moveID] = terminalID
        paneMoveSelectionRevision = tabsModel.selectionRevision
        defer {
            pendingPaneMoveTerminals.removeValue(forKey: moveID)
            paneMoveSelectionRevision = nil
        }
        var args = "pane move \(LoginShellCommand.singleQuoted(id)) --no-focus"
        if let tab = destination.tab_id {
            args += " --tab \(LoginShellCommand.singleQuoted(tab)) --split \(destination.split ?? "right")"
        } else if destination.type == "new_tab" {
            args += " --new-tab"
            if let workspace = destination.workspace_id { args += " --workspace \(LoginShellCommand.singleQuoted(workspace))" }
        } else { args += " --new-workspace" }
        let moved = try await managementRequest("pane.move", HerdrControl.PaneMoveParams(pane_id: id, destination: destination),
            as: HerdrControl.PaneMoveResult.self, legacyArgs: args).move_result
        guard moved.changed else {
            throw HerdrChannelError.remote(code: moved.reason ?? "pane_move_failed", message: String(localized: "The pane could not be moved. Unzoom the source and destination tabs, then try again."))
        }
        if let workspace = moved.created_workspace { workspaces[workspace.workspace_id] = workspace }
        if let tab = moved.created_tab { ensureTab(tab) }
        paneDidMove(.init(pane: moved.pane, previous_pane_id: moved.previous_pane_id,
            previous_tab_id: moved.previous_tab_id, previous_workspace_id: moved.previous_workspace_id))
        try await refreshAfterManagement()
        if tabsModel.selectionRevision == paneMoveSelectionRevision { selectManagementPane(moved.pane.pane_id) }
    }
}
