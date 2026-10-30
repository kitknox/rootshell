//
//  HerdrExposeAdapter.swift
//  rootshell
//
//  herdr: `herdr api snapshot` for the tree + layouts, `pane read --raw` for
//  colored content. PaneInfo.revision only moves on title/metadata changes,
//  not output, so frames are hashed client-side like tmux's.
//

import Foundation

nonisolated struct HerdrExposeAdapter: MultiplexerExposeAdapter {
    let type = MultiplexerType.herdr
    var localAttachment: LocalMultiplexerAttachment? = nil
    /// Native control previews use the very same invocation as their endpoint.
    /// Raw sessions retain their inherited socket/session environment.
    var commandPrefix: String? = nil
    var includesAllWorkspaces = false
    var validatesCaptures = false

    private func captureSuccess(_ nonce: String) -> String { "::MX_CAPTURE_OK_\(nonce)::" }

    /// `hx` runs herdr against the bound session; nil means the default one.
    private func prelude(session: String?) -> String {
        if let commandPrefix = commandPrefix ?? localAttachment?.command(arguments: []) {
            let executable = localAttachment?.launchExecutable ?? "herdr"
            return "hx() { \(commandPrefix) \"$@\" 2>/dev/null; }; command -v \(MuxScript.dq(executable)) >/dev/null 2>&1 || echo \(MuxScript.dq(MuxScript.unsupportedMarker))"
        }
        let env = session.map { "HERDR_SESSION=\(MuxScript.dq($0)) " } ?? ""
        return "hx() { \(env)herdr \"$@\" 2>/dev/null; }; command -v herdr >/dev/null 2>&1 || echo \(MuxScript.dq(MuxScript.unsupportedMarker))"
    }

    func resolveSessionScript(nonce: String) -> String {
        // The default session is always addressable; nothing to resolve.
        MuxScript.wrap("echo \(MuxScript.dq(MuxScript.topology(nonce))); echo default", nonce: nonce)
    }

    func tickScript(session: String?, request: MuxTickRequest, nonce: String) -> String {
        var body = prelude(session: session)
        body += "; echo \(MuxScript.dq(MuxScript.topology(nonce))); hx api snapshot; echo"
        for paneID in request.fetch {
            body += "; \(MuxScript.paneMarker(nonce: nonce, id: paneID))"
            body += "; hx pane read \(MuxScript.dq(paneID)) --source visible --raw"
            if validatesCaptures {
                body += "; _rs_preview_status=$?; echo; if [ \"$_rs_preview_status\" = 0 ]; then echo \(MuxScript.dq(captureSuccess(nonce))); fi"
            }
            body += "; echo"
        }
        return MuxScript.wrap(body, nonce: nonce)
    }

    func parseTick(output: String, session _: String?, nonce: String) -> MuxTickResult? {
        let sections = MuxScript.sections(of: output, nonce: nonce)
        guard sections.found, !sections.unsupported else { return nil }
        guard let root = MuxScript.json(sections.topology) as? [String: Any] else { return nil }
        // CLI prints the whole response: {"id":..,"result":{"type":"session_snapshot","snapshot":{..}}}
        let snap = root.mxDict("result")?.mxDict("snapshot") ?? root.mxDict("snapshot") ?? root
        guard snap["tabs"] != nil else { return nil }

        let focusedWorkspace = snap.mxString("focused_workspace_id")
        let focusedTab = snap.mxString("focused_tab_id")
        let workspaces = Self.muxWorkspaces(from: Self.decodeWorkspaceInfos(snap.mxArray("workspaces")))
        let layoutsByTab = Dictionary(
            snap.mxArray("layouts").compactMap { layout -> (String, [String: Any])? in
                guard let id = layout.mxString("tab_id") else { return nil }
                return (id, layout)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let panesByID = Dictionary(
            snap.mxArray("panes").compactMap { pane -> (String, [String: Any])? in
                guard let id = pane.mxString("pane_id") else { return nil }
                return (id, pane)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Raw sessions use the focused workspace. Native fallback previews
        // may span several workspaces; both preserve snapshot display order.
        // `number` is a stable public tab number, unchanged by tab.move.
        let infos = snap.mxArray("tabs")
            .filter { includesAllWorkspaces || focusedWorkspace == nil || $0.mxString("workspace_id") == focusedWorkspace }
        var tabs: [MuxTab] = []
        for info in infos {
            guard let tabID = info.mxString("tab_id") else { continue }
            let layout = layoutsByTab[tabID]
            let area = layout?.mxDict("area")
            let cols = cell(area, "width")
            let rows = cell(area, "height")
            let originX = cell(area, "x")
            let originY = cell(area, "y")
            var panes: [MuxPane] = []
            for entry in layout?.mxArray("panes") ?? [] {
                guard let paneID = entry.mxString("pane_id"), let rect = entry.mxDict("rect") else { continue }
                let pane = panesByID[paneID]
                if validatesCaptures, pane?.mxString("tab_id") != tabID { continue }
                panes.append(MuxPane(
                    id: paneID,
                    rect: MuxCellRect(
                        x: cell(rect, "x") - originX,
                        y: cell(rect, "y") - originY,
                        width: cell(rect, "width"),
                        height: cell(rect, "height")
                    ),
                    isActive: entry.mxBool("focused"),
                    isPreviewable: true,
                    title: pane?.mxString("title") ?? pane?.mxString("terminal_title_stripped"),
                    workingDirectory: Self.absoluteDirectory(pane?.mxString("foreground_cwd"))
                        ?? Self.absoluteDirectory(pane?.mxString("cwd"))
                ))
            }
            let status = info.mxString("agent_status")?.lowercased()
            let badge = status.flatMap { ["idle", "unknown", "none", ""].contains($0) ? nil : $0 }
            tabs.append(MuxTab(
                id: tabID,
                index: tabs.count,
                title: info.mxString("label") ?? tabID,
                isActive: tabID == focusedTab,
                cols: cols,
                rows: rows,
                panes: panes,
                badge: badge,
                workspaceID: info.mxString("workspace_id")
            ))
        }
        var frames: [String: MuxPaneFrame] = [:]
        for section in sections.panes {
            var ansi = section.body
            if validatesCaptures {
                let suffix = "\n" + captureSuccess(nonce)
                guard let marker = ansi.range(of: suffix, options: .backwards),
                      ansi[marker.upperBound...].allSatisfy({ $0 == "\n" || $0 == "\r" }) else { continue }
                ansi = String(ansi[..<marker.lowerBound])
            }
            frames[section.id] = MuxPaneFrame(
                ansi: ansi,
                cursor: nil,
                revision: MuxExposeIdentity.contentRevision(ansi)
            )
        }
        let activeTab = focusedTab ?? tabs.first(where: \.isActive)?.id
        return MuxTickResult(
            snapshot: MuxExposeSnapshot(tabs: tabs, activeTabID: activeTab, workspaces: workspaces),
            frames: frames,
            unchanged: [],
            truncated: sections.truncated,
            paneIdentities: panesByID.compactMapValues { $0.mxString("terminal_id") }
        )
    }

    private static func decodeWorkspaceInfos(_ values: [[String: Any]]) -> [HerdrControl.WorkspaceInfo] {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return [] }
        return (try? JSONDecoder().decode([HerdrControl.WorkspaceInfo].self, from: data)) ?? []
    }

    private static func muxWorkspaces(from infos: [HerdrControl.WorkspaceInfo]) -> [MuxWorkspace] {
        let ordered = HerdrWorkspaceRules.ordered(infos)
        let parents: [String: String] = Dictionary(
            HerdrWorkspaceRules.groups(ordered).flatMap { group -> [(String, String)] in
                guard let parentID = group.first?.workspace_id else { return [] }
                return group.dropFirst().map { ($0.workspace_id, parentID) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ordered.map { workspace in
            MuxWorkspace(
                id: workspace.workspace_id,
                title: workspace.label,
                parentID: parents[workspace.workspace_id]
            )
        }
    }

    private static func absoluteDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }

    /// herdr cells are u16, as `HerdrControlProtocol.Rect` enforces; bounding
    /// them keeps origin-relative subtraction from overflowing on a hostile reply.
    private func cell(_ dict: [String: Any]?, _ key: String) -> Int {
        dict?.mxInt(key).flatMap { UInt16(exactly: $0) }.map(Int.init) ?? 0
    }

    func focusScript(session: String?, tabID: String) -> String {
        let nonce = "focus"
        return MuxScript.wrap("\(prelude(session: session)); hx tab focus \(MuxScript.dq(tabID))", nonce: nonce)
    }

}
