/// Equalize existing server cells. Most layouts use tmux's native spread
/// operation. Adjacent same-axis splits, and any nesting on tmux 3.8, use
/// planned native resize-pane commands when their boundaries are reachable, or
/// a safe native spread when it can produce equal visible leaves (never on
/// 3.8). Unsupported plans fail before changing panes.
/// Never import a custom layout: it assigns panes by mutable pane-list order.
@MainActor
enum TmuxSplitEqualizer {
    enum Failure: Error {
        case invalidSnapshot
        case layoutChanged
        case didNotConverge
        case unsafeLayout
    }

    private struct Snapshot {
        let layout: String
        let zoomedPaneID: Int?
        let tree: TmuxLayoutNode
        let hasDecorations: Bool
        let version: String
        /// Includes floating panes, which the legacy layout omits.
        let paneCount: Int

        init(_ reply: String) throws {
            let lines = reply.split(whereSeparator: \.isNewline)
            guard lines.count == 1 else { throw Failure.invalidSnapshot }
            let fields = lines[0].split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 8, !fields[0].isEmpty,
                  fields[1] == "0" || fields[1] == "1",
                  fields[2].first == "%", let paneID = Int(fields[2].dropFirst()), paneID >= 0,
                  let paneCount = Int(fields[6]),
                  let tree = TmuxLayoutNode.parseServerLayout(String(fields[0])) else {
                throw Failure.invalidSnapshot
            }
            self.tree = tree
            // Decorations change tmux's leaf minima, and separate borders make
            // resize-pane sizes exclude them. Refuse until those cells are modelled.
            hasDecorations = fields[3] != "off" || (fields[4] != "off" && !fields[4].isEmpty)
                || (fields[7] != "joined" && !fields[7].isEmpty)
            layout = String(fields[0])
            zoomedPaneID = fields[1] == "1" ? paneID : nil
            version = String(fields[5])
            self.paneCount = paneCount
        }
    }

    /// tmux 3.8's -E spreads only leaf panes among siblings (tmux#5776): a
    /// level of nested groups never changes, and a mixed level overflows the
    /// window. 3.8a and next-3.9 builds exist both with and without the fix.
    /// OpenBSD base tmux reports its OS release; June-October 2026 spans 7.9/8.0.
    static func spreadSkipsNestedGroups(version: String) -> Bool {
        version.hasPrefix("3.8")
            || ["next-3.8", "next-3.9", "openbsd-7.9", "openbsd-8.0"].contains(version)
    }

    /// `send` must validate that the window still has the same topology
    /// before each command. Every call contains exactly one command / reply.
    static func run(windowID: Int, layout: TmuxLayoutNode,
                    send: (String) async throws -> String) async throws {
        let paneIDs = layout.paneIDs
        guard paneIDs.count > 1 else { return }
        guard Set(paneIDs).count == paneIDs.count, paneIDs.allSatisfy({ $0 >= 0 }) else {
            throw Failure.layoutChanged
        }
        let snapshotCommand = "display-message -p -t @\(windowID) '#{window_layout}|#{window_zoomed_flag}|#{pane_id}|#{pane-border-status}|#{pane-scrollbars}|#{version}|#{window_panes}|#{pane-border-type}'"
        let original = try Snapshot(await send(snapshotCommand))
        let skipsNestedGroups = Self.spreadSkipsNestedGroups(version: original.version)
        let avoidsNativeSpread = skipsNestedGroups && original.tree.hasNestedSplit
        let plansResizes = original.tree.hasNestedSameAxisSplit || avoidsNativeSpread
        // Keep the -E preflight on 3.8 so it rejects what other versions reject.
        var requiresNativeSafety = !original.tree.hasNestedSameAxisSplit
        func validate(_ snapshot: Snapshot) throws {
            guard snapshot.tree.hasSameTopology(as: layout) else { throw Failure.layoutChanged }
            guard !snapshot.hasDecorations else { throw Failure.unsafeLayout }
            // A floating pane's group still exists on the server but collapses
            // in the legacy layout, hiding nesting that the gate must see.
            if skipsNestedGroups && snapshot.paneCount != snapshot.tree.paneIDs.count {
                throw Failure.unsafeLayout
            }
            if requiresNativeSafety && !snapshot.tree.permitsNativeEqualization {
                throw Failure.unsafeLayout
            }
        }
        // In particular, reject an unsafe zoomed layout before unzooming it.
        try validate(original)

        func restoreZoom() async throws {
            guard let paneID = original.zoomedPaneID else { return }
            let current = try Snapshot(await send(snapshotCommand))
            // Do not toggle off an already zoomed pane (including an intervening
            // zoom from another client). Window-qualified IDs cannot follow a
            // pane that has since moved to another window.
            if current.zoomedPaneID == nil {
                _ = try await send("resize-pane -Z -t @\(windowID).%\(paneID)")
            }
        }

        if plansResizes {
            guard let target = original.tree.equalizationTarget() else {
                throw Failure.unsafeLayout
            }
            if original.tree.leaves == target.leaves { return }
            if let plan = original.tree.resizePlan(to: target) {
                do {
                    var current = original
                    for step in plan {
                        try validate(current)
                        guard current.tree.width == original.tree.width,
                              current.tree.height == original.tree.height,
                              let leaf = current.tree.leaves.first(where: { $0.paneIDs == [step.paneID] }) else {
                            throw Failure.layoutChanged
                        }
                        let horizontal = step.direction == .horizontal
                        if (horizontal ? leaf.width : leaf.height) == step.size { continue }
                        let flag = horizontal ? "-x" : "-y"
                        _ = try await send("resize-pane -t @\(windowID).%\(step.paneID) \(flag) \(step.size)")
                        current = try Snapshot(await send(snapshotCommand))
                    }
                    try validate(current)
                    guard current.tree.leaves == target.leaves else { throw Failure.didNotConverge }
                    try await restoreZoom()
                    return
                } catch {
                    try? await restoreZoom()
                    throw error
                }
            }
            // A leaf resize cannot reach every ancestor boundary. Use -E only
            // if equal immediate children also give the desired visible sizes.
            // Do this preflight before any mutation, including unzooming.
            guard !avoidsNativeSpread, original.tree.nativeEqualizationProducesEqualLeaves else {
                throw Failure.unsafeLayout
            }
            requiresNativeSafety = true
            try validate(original)
        }

        do {
            var previous = original.layout
            var current = original
            var converged = false
            // layout_spread_out spreads the first unequal ancestor of a pane.
            // Visit every leaf, repeating because a later ancestor resize may
            // disturb a previously equalized descendant. Compare authoritative
            // server layouts, not the asynchronously delivered UI reconcile.
            // Refresh after EVERY command: subsequent -E calls must not use
            // stale dimensions when checking recursive subtree minima.
            // Bound the passes in case another client keeps resizing the window.
            for _ in 0..<(2 * layout.depth + 1) {
                for paneID in paneIDs {
                    try validate(current)
                    _ = try await send("select-layout -E -t @\(windowID).%\(paneID)")
                    current = try Snapshot(await send(snapshotCommand))
                }
                try validate(current)
                if current.layout == previous {
                    converged = true
                    break
                }
                previous = current.layout
            }
            // A stable layout is not proof: a tmux that skips cells is stable too.
            guard converged, current.tree.isNativelySpread else { throw Failure.didNotConverge }
        } catch {
            // A failed spread may already have unzoomed the window. Preserve the
            // original error if cleanup also fails or the topology disappeared.
            try? await restoreZoom()
            throw error
        }
        try await restoreZoom()
    }
}
