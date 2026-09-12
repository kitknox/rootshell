// Copyright (c) 2026 Kit Knox / Rootshell LLC
import Foundation
import UIKit

extension HerdrController {
    /// A single stock client owns the selected tab's projection. Hidden tabs
    /// retain their views, but never compete with this client's geometry.
    func reconcileEndpoint() {
        guard mode == .legacy, !endpointUnsupported, !didEnd else { return }
        let selected = tabs.first { $0.value.id == tabsModel.selectedTabID }?.key
        let active = selected != nil && !legacySuspended && !Ghostty.isAppBackgroundedAtomic
        for view in paneViews.values {
            if view.herdrEndpointPane == nil {
                view.herdrEndpointPane = HerdrEndpointPane(view: view, controller: self)
            }
            if !active || view.herdrPaneBinding?.tabId != selected {
                view.herdrEndpointPane?.cancelInteraction()
            }
        }
        guard let endpoint else {
            guard active, endpointOpening == nil, let gateway,
                  HerdrChannelFactory.canOpen(for: gateway) else { return }
            endpointOpening = Task { [weak self] in
                guard let self else { return }
                defer { self.endpointOpening = nil }
                do {
                    if !self.endpointProbed {
                        let output = try await self.legacyRun(args: "status --json")
                        try Task.checkCancellation()
                        if let start = output.firstIndex(of: UInt8(ascii: "{")),
                           let end = output.lastIndex(of: UInt8(ascii: "}")), start <= end,
                           let status = try JSONSerialization.jsonObject(with: Data(output[start...end])) as? [String: Any],
                           let server = status["server"] as? [String: Any], server["running"] as? Bool == true {
                            let capabilities = server["capabilities"] as? [String: Any]
                            if capabilities?["endpoint_protocol_generation"] as? Int != 1 {
                                self.endpointUnsupported = true
                                for view in self.paneViews.values {
                                    view.herdrEndpointPane?.disconnect()
                                    view.herdrEndpointPane = nil
                                }
                                self.legacyNotice("Native scroll indicators and live selection need vanilla herdr 0.9.0 or newer.")
                                self.legacyReconcileAttaches()
                                return
                            }
                            self.endpointProbed = true
                        }
                    }
                    let pipe = try await HerdrChannelFactory.open(command: SSHConfig.herdrCommandLine(
                        sessionName: self.sessionName, args: "remote-client-bridge", localAttachment: self.localControlAttachment
                    ), on: gateway)
                    if Task.isCancelled || self.didEnd { await pipe.close(); return }
                    let candidate = HerdrEndpointChannel(pipe: pipe)
                    self.endpointMetadata = nil
                    self.endpoint = candidate
                    self.endpointTabID = nil
                    self.endpointSize = nil
                    self.endpointActive = true
                    candidate.onSnapshot = { [weak self, weak candidate] value in
                        guard let self, self.endpoint === candidate else { return }
                        self.applyEndpointSnapshot(value)
                    }
                    candidate.onFrame = { [weak self, weak candidate] frame in
                        guard let self, self.endpoint === candidate else { return }
                        self.applyEndpointFrame(frame)
                    }
                    candidate.onEffect = { [weak self, weak candidate] bytes in
                        guard let self, self.endpoint === candidate,
                              let tabID = self.endpointTabID,
                              let view = self.tabs[tabID]?.focusedTerminal,
                              let terminal = view.herdrPaneBinding?.terminalId else { return }
                        self.paneSessions[terminal]?.outputSink.emit(bytes)
                    }
                    candidate.onClosed = { [weak self, weak candidate] error in
                        guard let self, self.endpoint === candidate else { return }
                        self.endpointMetadata = nil
                        self.legacyTopologyDirty = true
                        for view in self.paneViews.values { view.herdrTitleState.endFallback() }
                        self.endpoint = nil
                        self.endpointTabID = nil
                        self.endpointSize = nil
                        self.endpointLayouts.removeAll()
                        for view in self.paneViews.values { view.herdrEndpointPane?.disconnect() }
                        if let error, !self.didEnd { self.legacyNotice(error.localizedDescription) }
                        // The existing poll retries a lost transport. Never replay
                        // an ambiguous command on the replacement connection.
                    }
                    let size = self.endpointGeometry() ?? .init(cols: 80, rows: 24, cellWidth: 8, cellHeight: 16)
                    self.endpointSize = size
                    try await candidate.start(cols: size.cols, rows: size.rows,
                                              cellWidth: size.cellWidth, cellHeight: size.cellHeight)
                    guard self.endpoint === candidate, !Task.isCancelled else { candidate.close(); return }
                    self.reconcileEndpoint()
                } catch {
                    if !Task.isCancelled, !self.didEnd { self.legacyNotice(error.localizedDescription) }
                }
            }
            return
        }
        guard endpoint.boot != nil else { return }
        synchronizeEndpointTheme()
        endpointActive = active
        endpoint.setSurfaceActive(active) { [weak self, weak endpoint] result in
            guard let self, self.endpoint === endpoint else { return }
            if case .failure(let error) = result, !(error is CancellationError) {
                self.legacyNotice(error.localizedDescription)
            }
        }
        guard active, let selected else { return }
        if endpointTabID != selected {
            endpointTabID = selected
            endpoint.command("tab.focus", ["tab_id": selected], coalescingKey: "focus-tab") { [weak self, weak endpoint] result in
                guard let self, self.endpoint === endpoint else { return }
                if case .failure(let error) = result, !(error is CancellationError) {
                    self.endpointTabID = nil
                    self.legacyNotice(error.localizedDescription)
                }
            }
        }
        if let size = endpointGeometry(), endpointSize != size {
            endpointSize = size
            endpoint.enqueue(HerdrEndpointWire.resize(cols: size.cols, rows: size.rows,
                cellWidth: size.cellWidth, cellHeight: size.cellHeight))
        }
        if let frame = endpoint.latest { applyEndpointFrame(frame) }
    }

    private func endpointGeometry() -> HerdrTabGeometryState.Size? {
        guard let tab = tabs.values.first(where: { $0.id == tabsModel.selectedTabID }),
              let view = tab.splitTree.terminalLeaves.first(where: { $0.enclosingSplitHost?.hasLaidOutHerdrPane($0) == true }),
              !view.suppressPTYSizeUpdates, !KeyboardTracker.shared.isKeyboardAnimating,
              let size = view.enclosingSplitHost?.herdrWindowGeometry() else { return nil }
        var gutterX = 2, gutterY = 2
        if let id = tab.herdrTabId, let layout = endpointLayouts[id], let tree = HerdrLayoutTree.build(layout) {
            gutterX = max(0, layout.area.width - tree.extent(horizontal: true))
            gutterY = max(0, layout.area.height - tree.extent(horizontal: false))
        }
        return .init(cols: min(65535, max(4, size.cols + gutterX)),
                     rows: min(65535, max(2, size.rows + gutterY)),
                     cellWidth: max(1, size.cellWidth), cellHeight: max(1, size.cellHeight))
    }

    private func applyEndpointFrame(_ frame: HerdrEndpointSurface.Frame) {
        guard endpointActive, let tabID = endpointTabID, let tab = tabs[tabID],
              tab.id == tabsModel.selectedTabID, !frame.panes.isEmpty,
              frame.panes.allSatisfy({ paneInfos[$0.id]?.tab_id == tabID }) else { return }
        let panes = frame.panes.map { pane in
            HerdrControl.LayoutPane(pane_id: pane.id, focused: pane.focused, rect: .init(
                x: pane.inner.x, y: pane.inner.y, width: pane.inner.width, height: pane.inner.height))
        }
        let focused = frame.panes.first(where: \.focused)?.id ?? frame.panes[0].id
        let layout = HerdrControl.LayoutSnapshot(workspace_id: tabInfos[tabID]?.workspace_id ?? "",
            tab_id: tabID, zoomed: frame.panes.count == 1 && paneInfos.values.filter { $0.tab_id == tabID }.count > 1,
            area: .init(x: 0, y: 0, width: frame.grid.width, height: frame.grid.height),
            focused_pane_id: focused, panes: panes, splits: frame.splits.map { split in
                let horizontal = split.direction == 0
                let extent = horizontal ? split.area.width : split.area.height
                let origin = horizontal ? split.area.x : split.area.y
                return .init(id: split.path.map { $0 ? "1" : "0" }.joined(), direction: horizontal ? "right" : "down",
                    ratio: Double(split.position - origin) / Double(max(1, extent)),
                    rect: .init(x: split.area.x, y: split.area.y, width: split.area.width, height: split.area.height))
            })
        if endpointLayouts[tabID] != layout {
            endpointLayouts[tabID] = layout
            applyLayout(layout)
        }
        for pane in frame.panes {
            guard let terminal = paneInfos[pane.id]?.terminal_id, let view = paneViews[terminal] else { continue }
            if view.herdrEndpointPane == nil { view.herdrEndpointPane = HerdrEndpointPane(view: view, controller: self) }
            view.herdrEndpointPane?.receive(frame: frame, pane: pane)
        }
    }
}
