//
//  TabWindowTransfer.swift
//  rootshell
//
//  Cross-window tab transfer support. A transfer moves the live TabModel and
//  its TerminalView instances; it must not go through close/restore paths.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

struct TerminalWindowTransferTarget: Identifiable, Hashable {
    let id: String
    let title: String
    let tabCount: Int
}

extension Notification.Name {
    static let tabTransferEmptiedWindow = Notification.Name("com.rootshell.tabTransferEmptiedWindow")
    static let tabTransferDragStateChanged = Notification.Name("com.rootshell.tabTransferDragStateChanged")
}

@MainActor
enum TerminalWindowRegistry {
    private final class WeakModel {
        weak var model: TabsModel?
        var sceneSessionId: String?
        var refreshSelectionAfterMutation: ((Bool) -> Void)?
        var rebindTabCallbacks: ((TabModel) -> Void)?

        init(
            _ model: TabsModel,
            refreshSelectionAfterMutation: ((Bool) -> Void)?,
            rebindTabCallbacks: ((TabModel) -> Void)?
        ) {
            self.model = model
            self.refreshSelectionAfterMutation = refreshSelectionAfterMutation
            self.rebindTabCallbacks = rebindTabCallbacks
        }
    }

    private static var models: [String: WeakModel] = [:]

    static func register(
        _ tabsModel: TabsModel,
        windowId: String,
        refreshSelectionAfterMutation: ((Bool) -> Void)? = nil,
        rebindTabCallbacks: ((TabModel) -> Void)? = nil
    ) {
        models[windowId] = WeakModel(
            tabsModel,
            refreshSelectionAfterMutation: refreshSelectionAfterMutation,
            rebindTabCallbacks: rebindTabCallbacks
        )
    }

    static func updateSceneSessionId(_ sceneSessionId: String?, for windowId: String) {
        guard let weakModel = models[windowId] else { return }
        weakModel.sceneSessionId = sceneSessionId
    }

    static func unregister(windowId: String) {
        models.removeValue(forKey: windowId)
    }

    static func tabsModel(for windowId: String) -> TabsModel? {
        models[windowId]?.model
    }

    static func sceneSessionId(for windowId: String) -> String? {
        models[windowId]?.sceneSessionId
    }

    static func refreshSelectionAfterMutation(in windowId: String, allowFocus: Bool) {
        models[windowId]?.refreshSelectionAfterMutation?(allowFocus)
    }

    static func rebindCallbacks(for tab: TabModel, in windowId: String) {
        models[windowId]?.rebindTabCallbacks?(tab)
    }

    static func targets(excluding sourceWindowId: String) -> [TerminalWindowTransferTarget] {
        models
            .compactMap { windowId, weakModel -> TerminalWindowTransferTarget? in
                guard windowId != sourceWindowId,
                      let model = weakModel.model else { return nil }
                if windowId == ExternalDisplay.windowId {
                    // Only a live session is a target; never on Catalyst.
                    guard TabTransferCoordinator.canOfferExternalDisplayTransfers else { return nil }
                    return TerminalWindowTransferTarget(
                        id: windowId,
                        title: String(localized: "External Display", comment: "Transfer target: the connected external display window"),
                        tabCount: model.tabs.count
                    )
                }
                let title = model.selectedTab?.title
                    ?? model.tabs.first?.title
                    ?? String(localized: "Window", comment: "Fallback app window title")
                return TerminalWindowTransferTarget(
                    id: windowId,
                    title: title,
                    tabCount: model.tabs.count
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}

@MainActor
final class TabTransferCoordinator {
    static let shared = TabTransferCoordinator()

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "TabTransfer")
    nonisolated static let dragUTType = UTType(exportedAs: "com.ghostty.rootshell.tab-transfer")
    nonisolated static let activeDragExpiration: Duration = .seconds(30)

    struct DragPayload: Codable, Hashable {
        let sourceWindowId: String
        let tabID: UUID
    }

    /// Tabs staged for transfer into a window that does not exist yet. A group
    /// or gateway move stages multiple ids; a single-tab move stages one.
    /// `sourceGroupingEnabled` is snapshotted here (not read at claim time) so
    /// the new window can inherit the source's grouped-mode state even after the
    /// source window has been mutated or destroyed by the move.
    private struct PendingNewWindow: Equatable {
        let sourceWindowId: String
        let tabIDs: [UUID]
        let sourceGroupingEnabled: Bool
    }

    private var pendingNewWindow: PendingNewWindow?
    private var activeDragPayload: DragPayload?

    private init() {}

    // MainActor-isolated (inherited from the type): reads the @MainActor
    // `UIDevice.current`. All call sites are MainActor UI code, so keeping this
    // isolated preserves compile-time enforcement rather than a runtime assume.
    static var canOfferWindowTransfers: Bool {
        #if targetEnvironment(macCatalyst) || os(visionOS)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom != .phone
        #endif
    }

    /// External-display transfers bypass the multi-window gate: offered on
    /// iPhone too, whenever a display session is active.
    static var canOfferExternalDisplayTransfers: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return ExternalDisplayManager.shared.isExternalSessionActive
        #endif
    }

    func beginDrag(sourceWindowId: String, tabID: UUID) -> NSItemProvider {
        let payload = DragPayload(sourceWindowId: sourceWindowId, tabID: tabID)
        activeDragPayload = payload
        notifyDragStateChanged()
        scheduleDragExpiration(for: payload)
        let provider = NSItemProvider()
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.dragUTType.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
        }
        provider.suggestedName = tabID.uuidString
        return provider
    }

    func clearDrag() {
        guard activeDragPayload != nil else { return }
        activeDragPayload = nil
        notifyDragStateChanged()
    }

    func isActiveDrag(sourceWindowId: String, tabID: UUID) -> Bool {
        activeDragPayload == DragPayload(sourceWindowId: sourceWindowId, tabID: tabID)
    }

    func canAcceptActiveDrag(in destinationWindowId: String) -> Bool {
        // The external window is not a touch target; use the explicit move actions.
        guard destinationWindowId != ExternalDisplay.windowId else { return false }
        guard let activeDragPayload,
              activeDragPayload.sourceWindowId != destinationWindowId,
              let sourceModel = TerminalWindowRegistry.tabsModel(for: activeDragPayload.sourceWindowId),
              let tab = sourceModel.tab(withID: activeDragPayload.tabID) else {
            return false
        }
        return canTransfer(tab)
    }

    @discardableResult
    func receiveActiveDrag(
        in destinationWindowId: String,
        insertionIndex: Int? = nil,
        groupOverride: TabGroupID? = nil,
        isDestinationWindowFocused: Bool
    ) -> Bool {
        guard let payload = activeDragPayload,
              payload.sourceWindowId != destinationWindowId else { return false }
        defer { clearDrag() }
        return move(
            payload,
            toWindowId: destinationWindowId,
            insertionIndex: insertionIndex,
            groupOverride: groupOverride,
            isDestinationWindowFocused: isDestinationWindowFocused
        )
    }

    @discardableResult
    func move(
        tabID: UUID,
        from sourceWindowId: String,
        to destinationWindowId: String,
        insertionIndex: Int? = nil,
        groupOverride: TabGroupID? = nil,
        isDestinationWindowFocused: Bool
    ) -> Bool {
        move(
            DragPayload(sourceWindowId: sourceWindowId, tabID: tabID),
            toWindowId: destinationWindowId,
            insertionIndex: insertionIndex,
            groupOverride: groupOverride,
            isDestinationWindowFocused: isDestinationWindowFocused
        )
    }

    /// Stage a single tab for a new-window move. Thin wrapper over the
    /// list-based path so existing callers keep working.
    func prepareMoveToNewWindow(tabID: UUID, from sourceWindowId: String) {
        guard let sourceModel = TerminalWindowRegistry.tabsModel(for: sourceWindowId),
              let tab = sourceModel.tab(withID: tabID),
              canTransfer(tab) else { return }
        prepareMoveTabsToNewWindow([tabID], from: sourceWindowId)
    }

    /// Stage a group / gateway (multiple tabs) for a move into a window that
    /// will be created momentarily; `claimPendingTransfer` completes it once
    /// the destination scene comes up.
    func prepareMoveTabsToNewWindow(_ tabIDs: [UUID], from sourceWindowId: String) {
        guard Self.canOfferWindowTransfers,
              let sourceModel = TerminalWindowRegistry.tabsModel(for: sourceWindowId),
              !tabIDs.isEmpty else { return }
        let pending = PendingNewWindow(
            sourceWindowId: sourceWindowId,
            tabIDs: tabIDs,
            sourceGroupingEnabled: sourceModel.isGroupedModeEnabled
        )
        pendingNewWindow = pending
        schedulePendingNewWindowExpiration(for: pending)
    }

    func cancelPendingMoveToNewWindow(tabID: UUID, from sourceWindowId: String) {
        cancelPendingMoveTabsToNewWindow([tabID], from: sourceWindowId)
    }

    func cancelPendingMoveTabsToNewWindow(_ tabIDs: [UUID], from sourceWindowId: String) {
        if let pending = pendingNewWindow,
           pending.sourceWindowId == sourceWindowId,
           pending.tabIDs == tabIDs {
            pendingNewWindow = nil
        }
    }

    @discardableResult
    func claimPendingTransfer(
        for destinationWindowId: String,
        isDestinationWindowFocused: Bool
    ) -> Bool {
        guard let pending = pendingNewWindow,
              pending.sourceWindowId != destinationWindowId else { return false }
        pendingNewWindow = nil
        let moved = moveTabs(
            pending.tabIDs,
            from: pending.sourceWindowId,
            to: destinationWindowId,
            insertionIndex: 0,
            isDestinationWindowFocused: isDestinationWindowFocused
        )
        // Inherit the source window's grouped-mode state so the moved group/
        // gateway stays grouped in the new window instead of flattening. Only
        // turn it on (source-off leaves the fresh window's default untouched).
        // moveTabs has already set selection + activeGroupID to the landing
        // tab, so the didSet adopts the correct group.
        if moved, pending.sourceGroupingEnabled,
           let destinationModel = TerminalWindowRegistry.tabsModel(for: destinationWindowId) {
            destinationModel.isGroupedModeEnabled = true
        }
        return moved
    }

    /// Move a set of tabs — an entire group, or a whole tmux gateway (the
    /// gateway tab plus all its window tabs) — to another window as one atomic
    /// unit. Runs synchronously on the main actor, so no tmux reconcile can
    /// interleave (reconciles apply only via `Task { @MainActor }` hops, which
    /// cannot preempt this function). The group re-forms in the destination
    /// because each tab's group identity is recomputed from its own state.
    @discardableResult
    func moveTabs(
        _ tabIDs: [UUID],
        from sourceWindowId: String,
        to destinationWindowId: String,
        insertionIndex requestedIndex: Int? = nil,
        isDestinationWindowFocused: Bool
    ) -> Bool {
        guard sourceWindowId != destinationWindowId,
              let sourceModel = TerminalWindowRegistry.tabsModel(for: sourceWindowId),
              let destinationModel = TerminalWindowRegistry.tabsModel(for: destinationWindowId) else {
            Self.logger.warning("Rejected batch transfer: missing source/destination")
            return false
        }

        // Collect candidates in SOURCE display order, then keep those eligible
        // to travel together (see `movableMembers`). The UI only offers a
        // group/gateway move when the WHOLE batch is movable
        // (`canTransferEntireBatch`); this filter is defense-in-depth for the
        // programmatic and new-window-claim paths, and for state that changed
        // between menu build and invocation.
        let requested = Set(tabIDs)
        let candidates = sourceModel.tabs.filter { requested.contains($0.id) }
        let movable = movableMembers(among: candidates)
        // Execution-time all-or-nothing guard: EVERY requested member must still
        // be present AND movable. State can change between menu construction and
        // invocation (e.g. a tmux reconcile turning a window into a placeholder,
        // or a window closing), and a group/gateway move must never silently move
        // only part of what the user asked for. The UI gate
        // (`canTransferEntireBatch`) normally guarantees this; this is the
        // authoritative check on the mutation path.
        guard candidates.count == requested.count, movable.count == candidates.count else {
            let movableCount = movable.count
            let requestedCount = requested.count
            Self.logger.warning("Rejected batch transfer: batch no longer fully movable (\(movableCount)/\(requestedCount))")
            return false
        }
        let movingIDs = Set(movable.map(\.id))

        // Snapshot each member's effective group BEFORE removal so an
        // override-formed group (or a gateway child the user moved into another
        // group) can be reconstructed in the destination instead of splitting.
        let sourceGroups: [UUID: TabGroupID] = Dictionary(
            uniqueKeysWithValues: movable.compactMap { tab in
                sourceModel.effectiveGroupID(for: tab).map { (tab.id, $0) }
            }
        )

        // 1. Remove all from source in one pass; repair selection once.
        sourceModel.tabs.removeAll { movingIDs.contains($0.id) }
        for id in movingIDs {
            sourceModel.tabGroupOverrides.removeValue(forKey: id)
        }
        sourceModel.repairSelectionIfNeeded()
        let shouldCloseSourceWindow = sourceModel.tabs.isEmpty
        if !shouldCloseSourceWindow {
            TerminalWindowRegistry.refreshSelectionAfterMutation(in: sourceWindowId, allowFocus: true)
        }

        // 2. Retarget every moved tab (placeholders: near no-op) + rebind callbacks.
        for tab in movable {
            tab.retargetWindow(to: destinationWindowId, isWindowFocused: isDestinationWindowFocused)
            TerminalWindowRegistry.rebindCallbacks(for: tab, in: destinationWindowId)
        }

        // 3. Insert contiguously, preserving order.
        let destinationIndex: Int
        if let requestedIndex {
            destinationIndex = max(0, min(requestedIndex, destinationModel.tabs.count))
        } else if let selected = destinationModel.selectedTabID,
                  let selectedIndex = destinationModel.index(of: selected) {
            destinationIndex = min(selectedIndex + 1, destinationModel.tabs.count)
        } else {
            destinationIndex = destinationModel.tabs.count
        }
        destinationModel.tabs.insert(contentsOf: movable, at: destinationIndex)
        // Restore grouping: re-apply an override wherever a member's automatic
        // group in the destination differs from the group it occupied at the
        // source, so the group stays intact instead of splitting on arrival.
        // `setGroupOverride` no-ops when that group isn't valid in the
        // destination; clear any stale carryover first.
        for tab in movable {
            if destinationModel.tabGroupOverrides[tab.id] != nil {
                destinationModel.clearGroupOverride(for: tab.id)
            }
            guard let sourceGroup = sourceGroups[tab.id] else { continue }
            if destinationModel.effectiveGroupID(for: tab) != sourceGroup {
                destinationModel.setGroupOverride(for: tab.id, to: sourceGroup)
            }
        }

        // 4. Land on the gateway if present, else the first non-hidden member;
        //    never auto-select a hidden tmux window tab.
        let landing = movable.first(where: { $0.isTmuxGateway && !$0.isHiddenTmuxWindow })
            ?? movable.first(where: { !$0.isHiddenTmuxWindow })
            ?? movable[0]
        destinationModel.selectedTabID = landing.id
        destinationModel.displayedTabID = landing.id
        destinationModel.pendingScrollToTabID = landing.id
        if let group = destinationModel.effectiveGroupID(for: landing) {
            destinationModel.activeGroupID = group
        }
        TerminalWindowRegistry.refreshSelectionAfterMutation(
            in: destinationWindowId,
            allowFocus: isDestinationWindowFocused
        )

        // 5. tmux host tracking: re-point the gateway FIRST (updates baseWindowId
        //    + weakTabsModel to the destination model, which now contains the
        //    gateway), THEN stamp each window tab's explicit host.
        for tab in movable where tab.isTmuxGateway {
            for terminal in tab.splitTree.terminalLeaves where terminal.tmuxController != nil {
                terminal.tmuxController?.noteGatewayMoved(toAppWindowId: destinationWindowId)
            }
        }
        for tab in movable where tab.isTmuxWindow {
            if let windowId = tab.tmuxWindowId {
                TmuxController.noteWindowTabMoved(tab, tmuxWindowId: windowId, toAppWindowId: destinationWindowId)
            }
        }

        // 6. Destroy the emptied source scene once.
        if shouldCloseSourceWindow {
            closeEmptiedSourceWindow(sourceWindowId)
        }

        let count = movable.count
        Self.logger.info("Moved \(count) tabs from \(sourceWindowId) to \(destinationWindowId)")
        return true
    }

    private func move(
        _ payload: DragPayload,
        toWindowId destinationWindowId: String,
        insertionIndex requestedIndex: Int?,
        groupOverride: TabGroupID?,
        isDestinationWindowFocused: Bool
    ) -> Bool {
        guard payload.sourceWindowId != destinationWindowId,
              let sourceModel = TerminalWindowRegistry.tabsModel(for: payload.sourceWindowId),
              let destinationModel = TerminalWindowRegistry.tabsModel(for: destinationWindowId),
              let sourceIndex = sourceModel.index(of: payload.tabID) else {
            Self.logger.warning("Rejected tab transfer: missing source/destination/tab")
            return false
        }

        let tab = sourceModel.tabs[sourceIndex]
        guard canTransfer(tab) else {
            Self.logger.warning("Rejected tab transfer: tab is hidden or awaiting tmux reconcile")
            return false
        }
        sourceModel.tabs.remove(at: sourceIndex)
        sourceModel.tabGroupOverrides.removeValue(forKey: tab.id)
        sourceModel.repairSelectionIfNeeded()
        let shouldCloseSourceWindow = sourceModel.tabs.isEmpty
        if !shouldCloseSourceWindow {
            TerminalWindowRegistry.refreshSelectionAfterMutation(in: payload.sourceWindowId, allowFocus: true)
        }

        tab.retargetWindow(to: destinationWindowId, isWindowFocused: isDestinationWindowFocused)
        TerminalWindowRegistry.rebindCallbacks(for: tab, in: destinationWindowId)

        let destinationIndex: Int
        if let requestedIndex {
            destinationIndex = max(0, min(requestedIndex, destinationModel.tabs.count))
        } else if let selected = destinationModel.selectedTabID,
                  let selectedIndex = destinationModel.index(of: selected) {
            destinationIndex = min(selectedIndex + 1, destinationModel.tabs.count)
        } else {
            destinationIndex = destinationModel.tabs.count
        }

        destinationModel.tabs.insert(tab, at: destinationIndex)
        if let groupOverride {
            destinationModel.setGroupOverride(for: tab.id, to: groupOverride)
        } else if destinationModel.tabGroupOverrides[tab.id] != nil {
            destinationModel.clearGroupOverride(for: tab.id)
        }
        destinationModel.selectedTabID = tab.id
        destinationModel.displayedTabID = tab.id
        destinationModel.pendingScrollToTabID = tab.id
        TerminalWindowRegistry.refreshSelectionAfterMutation(
            in: destinationWindowId,
            allowFocus: isDestinationWindowFocused
        )

        if tab.isTmuxWindow, let windowId = tab.tmuxWindowId {
            TmuxController.noteWindowTabMoved(tab, tmuxWindowId: windowId, toAppWindowId: destinationWindowId)
        }
        if tab.isTmuxGateway {
            for terminal in tab.splitTree.terminalLeaves where terminal.tmuxController != nil {
                terminal.tmuxController?.noteGatewayMoved(toAppWindowId: destinationWindowId)
            }
        }

        if shouldCloseSourceWindow {
            closeEmptiedSourceWindow(payload.sourceWindowId)
        }

        Self.logger.info("Moved tab \(tab.id.uuidString) from \(payload.sourceWindowId) to \(destinationWindowId)")
        return true
    }

    private func closeEmptiedSourceWindow(_ sourceWindowId: String) {
        // The external window stays alive (empty state) when emptied; only
        // device scenes count toward "one of several".
        guard sourceWindowId != "visor",
              sourceWindowId != ExternalDisplay.windowId,
              let sceneSessionId = TerminalWindowRegistry.sceneSessionId(for: sourceWindowId),
              let scene = UIApplication.shared.deviceWindowScenes
                  .first(where: { $0.session.persistentIdentifier == sceneSessionId }),
              UIApplication.shared.deviceWindowScenes.count > 1 else {
            return
        }

        NotificationCenter.default.post(
            name: .tabTransferEmptiedWindow,
            object: nil,
            userInfo: ["windowId": sourceWindowId]
        )

        let options = UIWindowSceneDestructionRequestOptions()
        options.windowDismissalAnimation = .standard
        UIApplication.shared.requestSceneSessionDestruction(scene.session, options: options)
    }

    private func notifyDragStateChanged() {
        NotificationCenter.default.post(name: .tabTransferDragStateChanged, object: nil)
    }

    private func scheduleDragExpiration(for payload: DragPayload) {
        Task { @MainActor in
            try? await Task.sleep(for: Self.activeDragExpiration)
            if activeDragPayload == payload {
                clearDrag()
            }
        }
    }

    func canTransfer(_ tab: TabModel) -> Bool {
        !tab.isHiddenTmuxWindow
            && !tab.awaitingTmuxReconcile
    }

    /// A tmux family member that may move under the relaxed (hidden /
    /// awaiting-reconcile) gate — ONLY when its gateway travels in the same
    /// batch (`gatewayOwnersInBatch`). The gateway move re-points `baseWindowId`,
    /// so the child stays co-located and tmux adoption (`ensureWindow`) still
    /// finds it. Moving such a child without its gateway — especially a paneless
    /// placeholder, which `noteWindowTabMoved` cannot stamp a per-window host
    /// for — would orphan it from future adoption, so those are excluded.
    func canTransferAsGroupMember(_ tab: TabModel, gatewayOwnersInBatch: Set<UUID>) -> Bool {
        // The (possibly hidden) gateway head of a family travelling in this batch.
        if tab.isTmuxGateway, let owner = TmuxTabBadgeResolver.ownerID(for: tab) {
            return gatewayOwnersInBatch.contains(owner)
        }
        // A hidden / placeholder tmux child stays co-located with its gateway.
        if let owner = tab.owningGatewayTerminalUUID {
            return gatewayOwnersInBatch.contains(owner)
        }
        return false
    }

    /// The subset of `candidates` (a slice of one window's tabs, in display
    /// order) that may travel together: each must pass the strict
    /// `canTransfer`, or the relaxed tmux-family gate when its gateway is also
    /// in the batch. Shared by `moveTabs` and `canTransferEntireBatch` so the
    /// offered action and the executed action apply identical rules.
    private func movableMembers(among candidates: [TabModel]) -> [TabModel] {
        // Gateways present in THIS batch, by owner uuid. The hidden /
        // awaiting-reconcile gate may be relaxed ONLY for a tmux family whose
        // gateway travels in the same batch — then `noteGatewayMoved` re-points
        // `baseWindowId` and adoption stays coherent. A child moved without its
        // gateway (especially a paneless placeholder, which `noteWindowTabMoved`
        // cannot stamp a per-window host for) would be orphaned, so it must
        // clear the strict `canTransfer` gate instead.
        let gatewayOwnersInBatch = Set(
            candidates.compactMap { $0.isTmuxGateway ? TmuxTabBadgeResolver.ownerID(for: $0) : nil }
        )
        return candidates.filter {
            canTransfer($0) || canTransferAsGroupMember($0, gatewayOwnersInBatch: gatewayOwnersInBatch)
        }
    }

    /// True only when EVERY tab in `tabIDs` (resolved in `windowId`) is movable
    /// under the batch rules. The group/gateway "Move to Window" UI gates on
    /// this so the offered action is always a COMPLETE move — never a silent
    /// partial one. A regular group that contains a tmux child bound to a
    /// gateway that would stay behind is therefore not offered the move.
    func canTransferEntireBatch(_ tabIDs: [UUID], in windowId: String) -> Bool {
        guard !tabIDs.isEmpty,
              let model = TerminalWindowRegistry.tabsModel(for: windowId) else { return false }
        let ids = Set(tabIDs)
        let candidates = model.tabs.filter { ids.contains($0.id) }
        return candidates.count == ids.count
            && movableMembers(among: candidates).count == candidates.count
    }

    private func schedulePendingNewWindowExpiration(for pending: PendingNewWindow) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if pendingNewWindow == pending {
                pendingNewWindow = nil
            }
        }
    }
}

struct WindowTabTransferDropDelegate: DropDelegate {
    let windowId: String
    let insertionIndex: @MainActor () -> Int?
    let groupOverride: @MainActor () -> TabGroupID?
    let isWindowFocused: @MainActor () -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    @MainActor
    func performDrop(info: DropInfo) -> Bool {
        TabTransferCoordinator.shared.receiveActiveDrag(
            in: windowId,
            insertionIndex: insertionIndex(),
            groupOverride: groupOverride(),
            isDestinationWindowFocused: isWindowFocused()
        )
    }
}
