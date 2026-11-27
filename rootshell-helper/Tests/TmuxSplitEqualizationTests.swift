import Darwin
import Foundation
import XCTest

/// Real protocol/geometry coverage lives in the native macOS XCTest target,
/// where Process is available. No user's tmux server or configuration is used.
@MainActor
final class TmuxSplitEqualizationTests: XCTestCase {
    func testSwapPickerPreservesSourceFocusZoomAndReplyAlignment() throws {
        for zoomed in [false, true] {
            let server = try Server()
            defer { server.stop() }
            try server.cli(["split-window", "-h", "-t", "%0"])
            try server.cli(["split-window", "-h", "-t", "%1"])
            let control = try server.attach()
            defer { control.stop() }
            try control.command("select-pane -t @0.%0")
            let original = try control.command("display-message -p -t @0 '#{window_layout}'")
            if zoomed { try control.command("resize-pane -Z -t @0.%0") }
            let swap = try TmuxPaneZoomCommand.swapCommand(windowID: 0, sourcePaneID: 0, targetPaneID: 2)
            try control.command(swap)
            let changed = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
                control.command("display-message -p -t @0 '#{window_layout}'")))
            XCTAssertEqual(changed.paneIDs, [2, 1, 0])
            XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}:#{pane_id}'"),
                           "\(zoomed ? 1 : 0):%0")
            XCTAssertEqual(try control.command("display-message -p swap-reply-marker"), "swap-reply-marker")
            try control.command(swap)
            XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_layout}'"), original)
        }
    }

    func testSwapPickerCannotFollowEitherPaneToAnotherWindow() throws {
        for movedPane in [0, 2] {
            let server = try Server()
            defer { server.stop() }
            try server.cli(["split-window", "-h", "-t", "%0"])
            try server.cli(["split-window", "-h", "-t", "%1"])
            try server.cli(["new-window", "-d"])
            try server.cli(["join-pane", "-s", "@0.%\(movedPane)", "-t", "@1"])
            let control = try server.attach()
            defer { control.stop() }
            let before = try control.command("list-windows -F '#{window_id}:#{window_layout}'")
            let command = try TmuxPaneZoomCommand.swapCommand(windowID: 0, sourcePaneID: 0, targetPaneID: 2)
            XCTAssertThrowsError(try control.command(command))
            XCTAssertEqual(try control.command("list-windows -F '#{window_id}:#{window_layout}'"), before)
            XCTAssertEqual(try control.command("display-message -p stale-swap-reply-marker"), "stale-swap-reply-marker")
        }
    }

    func testPanePickerSelectsAndEnsuresZoomWithoutShiftingControlReplies() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        let control = try server.attach()
        defer { control.stop() }
        let layout = try control.command("display-message -p -t @0 '#{window_layout}'")
        // Initially unzoomed, then a different zoomed pane, then the same pane.
        for paneID in [0, 2, 2, 1] {
            try await TmuxPaneZoomCommand.zoom(windowID: 0, paneID: paneID) { command in
                try control.command(command)
            }
            XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}:#{pane_id}'"), "1:%\(paneID)")
            XCTAssertEqual(try control.command("display-message -p picker-reply-marker"), "picker-reply-marker")
        }
        try control.command("resize-pane -Z -t @0.%1")
        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_layout}'"), layout)
        try server.cli(["new-window", "-d"])
        // A stable ID moved to a different window must not be followed there.
        try server.cli(["join-pane", "-s", "@0.%2", "-t", "@1"])
        do {
            try await TmuxPaneZoomCommand.zoom(windowID: 0, paneID: 2) { try control.command($0) }
            XCTFail("A moved pane must not be followed into another window")
        } catch { /* tmux rejects the window-qualified stale target */ }
        XCTAssertEqual(try control.command("display-message -p -t @1 '#{window_zoomed_flag}'"), "0")
    }

    private func pane(_ id: Int) -> TmuxLayoutNode {
        .pane(paneId: id, width: 1, height: 1, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        .split(direction: axis, children: children, width: 203, height: 69, x: 0, y: 0)
    }

    func testIssue475SixPanesGeometryAndZoomRoundTripOverControlMode() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        for id in 0...2 { try server.cli(["split-window", "-v", "-t", "%\(id)"]) }
        let control = try server.attach()
        defer { control.stop() }
        try control.command("resize-pane -t %3 -y 10")
        try control.command("resize-pane -t %4 -y 20")
        let layout = split(.horizontal, [
            split(.vertical, [pane(0), pane(3)]),
            split(.vertical, [pane(1), pane(4)]),
            split(.vertical, [pane(2), pane(5)])
        ])
        let expected = [
            "%0 0 0 67 34", "%3 0 35 67 34",
            "%1 68 0 67 34", "%4 68 35 67 34",
            "%2 136 0 67 34", "%5 136 35 67 34"
        ].sorted()
        XCTAssertNotEqual(try geometry(control), expected)
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try geometry(control), expected)
        // A shifted control reply FIFO would consume an empty resize reply here.
        XCTAssertEqual(try control.command("display-message -p reply-after-equalize"), "reply-after-equalize")
        let equalized = try control.command("display-message -p -t @0 '#{window_layout}'")
        try control.command("resize-pane -Z -t %0")
        try control.command("resize-pane -Z -t %0")
        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_layout}'"), equalized)
        XCTAssertEqual(try geometry(control), expected)

        // Exercise the previously broken two-command path while pane %0 is zoomed.
        try control.command("resize-pane -t %0 -x 90")
        try control.command("resize-pane -Z -t %0")
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}:#{pane_id}'"), "1:%0")
        XCTAssertEqual(try control.command("display-message -p reply-after-zoom"), "reply-after-zoom")
        try control.command("resize-pane -Z -t %0")
        XCTAssertEqual(try geometry(control), expected)
    }

    /// tmux 3.8's -E spreads the two plain columns over the whole window here.
    func testMixedNestedAndPlainColumnsBecomeThirds() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        try server.cli(["split-window", "-v", "-t", "%0"])
        let control = try server.attach()
        defer { control.stop() }
        try control.command("resize-pane -t %0 -x 120")
        let layout = split(.horizontal, [split(.vertical, [pane(0), pane(3)]), pane(1), pane(2)])
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try geometry(control), [
            "%0 0 0 67 34", "%3 0 35 67 34", "%1 68 0 67 69", "%2 136 0 67 69"
        ].sorted())
        XCTAssertEqual(try control.command("display-message -p mixed-replies-aligned"), "mixed-replies-aligned")
    }

    /// The control-mode layout drops a floating pane and collapses its column,
    /// while the server still spreads that column as a group.
    func testFloatingPaneHidingNestedColumnIsRejectedOnAffectedTmux() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        try server.cli(["split-window", "-v", "-t", "%0"])
        let control = try server.attach()
        defer { control.stop() }
        let version = try control.command("display-message -p '#{version}'")
        guard TmuxSplitEqualizer.spreadSkipsNestedGroups(version: version) else {
            throw XCTSkip("tmux \(version) spreads nested groups correctly")
        }
        try control.command("resize-pane -t %0 -x 120")
        try control.command("break-pane -W -s %3")
        let before = try geometry(control)
        let layout = split(.horizontal, [pane(0), pane(1), pane(2)])
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
            XCTFail("Expected the hidden nested column to be rejected")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {}
        XCTAssertEqual(try geometry(control), before)
        XCTAssertEqual(try control.command("display-message -p floating-replies-aligned"), "floating-replies-aligned")
    }

    func testIssue475NestedSameAxisColumnsBecomeThirds() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        for id in 0...2 { try server.cli(["split-window", "-v", "-t", "%\(id)"]) }
        let control = try server.attach()
        defer { control.stop() }

        func column(_ top: Int, _ bottom: Int, width: Int, x: Int) -> TmuxLayoutNode {
            .split(direction: .vertical, children: [
                .pane(paneId: top, width: width, height: 34, x: x, y: 0),
                .pane(paneId: bottom, width: width, height: 34, x: x, y: 35)
            ], width: width, height: 69, x: x, y: 0)
        }
        let middle = column(1, 4, width: 50, x: 102)
        let right = column(2, 5, width: 50, x: 153)
        let nestedRight = TmuxLayoutNode.split(
            direction: .horizontal, children: [middle, right],
            width: 101, height: 69, x: 102, y: 0)
        let nested = TmuxLayoutNode.split(direction: .horizontal, children: [
            column(0, 3, width: 101, x: 0), nestedRight
        ], width: 203, height: 69, x: 0, y: 0)

        try control.command("select-layout -t @0 '\(nested.serverLayoutString)'")
        XCTAssertEqual(try geometry(control), [
            "%0 0 0 101 34", "%3 0 35 101 34",
            "%1 102 0 50 34", "%4 102 35 50 34",
            "%2 153 0 50 34", "%5 153 35 50 34"
        ].sorted())

        try await TmuxSplitEqualizer.run(windowID: 0, layout: nested) { try control.command($0) }
        XCTAssertEqual(try geometry(control), [
            "%0 0 0 67 34", "%3 0 35 67 34",
            "%1 68 0 67 34", "%4 68 35 67 34",
            "%2 136 0 67 34", "%5 136 35 67 34"
        ].sorted())
        let resized = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
            control.command("display-message -p -t @0 '#{window_layout}'")))
        XCTAssertTrue(resized.hasSameTopology(as: nested))
        XCTAssertEqual(try control.command("display-message -p nested-replies-aligned"), "nested-replies-aligned")

        // The native path must preserve zoom as well as the server topology.
        try control.command("select-layout -t @0 '\(nested.serverLayoutString)'")
        try control.command("resize-pane -Z -t %0")
        try await TmuxSplitEqualizer.run(windowID: 0, layout: nested) { try control.command($0) }
        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}:#{pane_id}'"), "1:%0")
        try control.command("resize-pane -Z -t %0")
        XCTAssertEqual(try geometry(control), resized.leaves.map { leaf in
            guard case let .pane(id, w, h, x, y) = leaf else { return "" }
            return "%\(id) \(x) \(y) \(w) \(h)"
        }.sorted())

        // Another client swaps panes after the snapshot but before a resize.
        // Resizing by pane ID must not import the old assignment over the swap.
        try control.command("select-layout -t @0 '\(nested.serverLayoutString)'")
        var swappedOrder: [Int]?
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: nested) { command in
                if command.hasPrefix("resize-pane"), swappedOrder == nil {
                    try server.cli(["swap-pane", "-s", "%0", "-t", "%2"])
                    // tmux 3.8 gives CLI clients the JSON layout; control clients keep the legacy one.
                    swappedOrder = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
                        control.command("display-message -p -t @0 '#{window_layout}'"))).paneIDs
                }
                return try control.command(command)
            }
            XCTFail("Expected topology change after the other client's swap")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
            let actual = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
                control.command("display-message -p -t @0 '#{window_layout}'")))
            XCTAssertEqual(actual.paneIDs, try XCTUnwrap(swappedOrder))
            XCTAssertEqual(try control.command("display-message -p race-replies-aligned"), "race-replies-aligned")
        }
    }

    private func nestedGroups(_ sizes: [[Int]], vertical: Bool) -> TmuxLayoutNode {
        var cursor = 0
        var id = 0
        let axis: TmuxLayoutNode.Direction = vertical ? .vertical : .horizontal
        func node(_ children: [TmuxLayoutNode], start: Int, size: Int) -> TmuxLayoutNode {
            .split(direction: axis, children: children,
                   width: vertical ? 69 : size, height: vertical ? size : 69,
                   x: vertical ? 0 : start, y: vertical ? start : 0)
        }
        let groups = sizes.map { sizes -> TmuxLayoutNode in
            let start = cursor
            let panes = sizes.map { size -> TmuxLayoutNode in
                defer { cursor += size + 1; id += 1 }
                return .pane(paneId: id, width: vertical ? 69 : size, height: vertical ? size : 69,
                             x: vertical ? 0 : cursor, y: vertical ? cursor : 0)
            }
            return panes.count == 1 ? panes[0] : node(panes, start: start, size: cursor - start - 1)
        }
        return node(groups, start: 0, size: cursor - 1)
    }

    func testNestedAncestorBoundariesAndRoundingOverControlMode() async throws {
        for vertical in [false, true] {
            // Both groups nested; rounding across groups; only the last child
            // can move the root boundary; an unreachable root already sized
            // correctly; an unchanged boundary beside a resize; a boundary
            // brought to its target by an earlier shrink.
            for sizes in [[[75, 75], [25, 25]], [[25, 25], [8, 8]], [[40, 10], [151]],
                          [[60, 20], [60, 30, 28]], [[50, 50], [80], [20]],
                          [[80], [35, 35], [20], [80]]] {
                let original = nestedGroups(sizes, vertical: vertical)
                let server = try Server()
                defer { server.stop() }
                for id in 0..<(original.paneIDs.count - 1) {
                    try server.cli(["split-window", "-h", "-t", "%\(id)"])
                }
                let control = try server.attach()
                defer { control.stop() }
                try control.command("refresh-client -C \(original.width),\(original.height)")
                let target = try XCTUnwrap(original.equalizationTarget())
                // Without a resize plan these need -E, which a buggy tmux never gets.
                let version = try control.command("display-message -p '#{version}'")
                let rejected = original.resizePlan(to: target) == nil
                    && TmuxSplitEqualizer.spreadSkipsNestedGroups(version: version)
                for zoomed in [false, true] {
                    try control.command("select-layout -t @0 '\(original.serverLayoutString)'")
                    if zoomed { try control.command("resize-pane -Z -t %0") }
                    if rejected {
                        do {
                            try await TmuxSplitEqualizer.run(windowID: 0, layout: original) { try control.command($0) }
                            XCTFail("Expected \(sizes) to be rejected without -E")
                        } catch TmuxSplitEqualizer.Failure.unsafeLayout {}
                    } else {
                        try await TmuxSplitEqualizer.run(windowID: 0, layout: original) { try control.command($0) }
                    }
                    XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}'"), zoomed ? "1" : "0")
                    if zoomed { try control.command("resize-pane -Z -t %0") }
                    if rejected {
                        XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_layout}'"),
                                       original.serverLayoutString)
                        XCTAssertEqual(try control.command("display-message -p rejected-replies-aligned"), "rejected-replies-aligned")
                        continue
                    }
                    let actual = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
                        control.command("display-message -p -t @0 '#{window_layout}'")))
                    XCTAssertTrue(actual.hasSameTopology(as: original))
                    XCTAssertEqual(actual.width, original.width)
                    XCTAssertEqual(actual.height, original.height)
                    let dimensions = actual.leaves.map { vertical ? $0.height : $0.width }.sorted()
                    XCTAssertEqual(dimensions, target.leaves.map { vertical ? $0.height : $0.width }.sorted())
                    XCTAssertEqual(try control.command("display-message -p ancestor-replies-aligned"), "ancestor-replies-aligned")
                }
            }
        }
    }

    func testUnreachableNestedGroupsLeaveServerGeometryAndZoomUntouched() async throws {
        for vertical in [false, true] {
            let original = nestedGroups([[75, 75], [16, 16, 17]], vertical: vertical)
            let server = try Server()
            defer { server.stop() }
            for id in 0..<(original.paneIDs.count - 1) {
                try server.cli(["split-window", "-h", "-t", "%\(id)"])
            }
            let control = try server.attach()
            defer { control.stop() }
            try control.command("refresh-client -C \(original.width),\(original.height)")
            try control.command("select-layout -t @0 '\(original.serverLayoutString)'")
            try control.command("resize-pane -Z -t %0")
            do {
                try await TmuxSplitEqualizer.run(windowID: 0, layout: original) { try control.command($0) }
                XCTFail("Expected unreachable target to fail preflight")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_layout}'"), original.serverLayoutString)
                XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}:#{pane_id}'"), "1:%0")
                XCTAssertEqual(try control.command("display-message -p preflight-replies-aligned"), "preflight-replies-aligned")
            }
        }
    }

    func testFullWidthJoinedPaneKeepsItsPosition() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["new-window", "-d", "-t", "equalize"])
        // On tmux 3.6, this produces traversal [0, 1, 2] but pane-list [0, 2, 1].
        try server.cli(["join-pane", "-f", "-v", "-s", "%2", "-t", "%0"])
        let control = try server.attach()
        defer { control.stop() }
        let layout = split(.vertical, [split(.horizontal, [pane(0), pane(1)]), pane(2)])
        try control.command("resize-pane -t %2 -y 10")
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        XCTAssertEqual(try geometry(control), [
            "%0 0 0 101 34", "%1 102 0 101 34", "%2 0 35 203 34"
        ])
        XCTAssertEqual(try control.command("display-message -p still-aligned"), "still-aligned")
    }

    func testVerticalRoundingUsesServerCellSizes() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-v", "-t", "%0"])
        try server.cli(["split-window", "-v", "-t", "%1"])
        let control = try server.attach()
        defer { control.stop() }
        try control.command("refresh-client -C 10,12")
        let layout = split(.vertical, [pane(0), pane(1), pane(2)])
        try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { try control.command($0) }
        let rows = try geometry(control).map { $0.split(separator: " ").map(String.init) }
        XCTAssertEqual(rows.map { $0[0] }, ["%0", "%1", "%2"])
        XCTAssertEqual(rows.map { $0[3] }, ["10", "10", "10"])
        // One rounding cell, with two rows reserved for the tmux dividers.
        // tmux versions may assign that rounding cell to different children.
        XCTAssertEqual(rows.compactMap { Int($0[4]) }.sorted(), [3, 3, 4])
        XCTAssertEqual(rows.compactMap { Int($0[4]) }.reduce(0, +) + 2, 12)
    }

    func testConstrainedNestedLayoutDoesNotIssueSpreadOrHangServer() async throws {
        let server = try Server()
        defer { server.stop() }
        try server.cli(["split-window", "-h", "-t", "%0"])
        try server.cli(["split-window", "-v", "-t", "%1"])
        try server.cli(["split-window", "-h", "-t", "%1"])
        try server.cli(["split-window", "-h", "-t", "%3"])
        let control = try server.attach()
        defer { control.stop() }
        try control.command("refresh-client -C 8,5")
        try control.command("resize-pane -t %0 -x 2")
        let original = try geometry(control)
        XCTAssertEqual(original, [
            "%0 0 0 2 5", "%1 3 0 1 2", "%2 3 3 5 2",
            "%3 5 0 1 2", "%4 7 0 1 2"
        ])
        // Deliberately stale, roomy model dimensions: the preflight must use
        // the current server tree, not geometry from the last UI reconcile.
        let layout = split(.horizontal, [pane(0),
            split(.vertical, [split(.horizontal, [pane(1), pane(3), pane(4)]), pane(2)])
        ])
        for zoomed in [false, true] {
            if zoomed { try control.command("resize-pane -Z -t %0") }
            var spreads = 0
            do {
                try await TmuxSplitEqualizer.run(windowID: 0, layout: layout) { command in
                    if command.hasPrefix("select-layout") {
                        spreads += 1
                        // Never actually send a known server-hanging command,
                        // even if this regression reappears on tmux 3.6a.
                        throw NSError(domain: "UnsafeTmuxSpread", code: 1)
                    }
                    return try control.command(command)
                }
                XCTFail("Expected constrained layout rejection")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                XCTAssertEqual(spreads, 0)
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(try control.command("display-message -p server-responsive"), "server-responsive")
            XCTAssertEqual(try control.command("display-message -p -t @0 '#{window_zoomed_flag}'"), zoomed ? "1" : "0")
            if zoomed { try control.command("resize-pane -Z -t %0") }
            XCTAssertEqual(try geometry(control), original)
        }
    }

    private func geometry(_ control: ControlClient) throws -> [String] {
        try control.command("list-panes -t @0 -F '#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}'")
            .split(separator: "\n").map(String.init).sorted()
    }

    func testInnerDividerDragInThreeColumnsAndRowsPreservesOuterPane() throws {
        for horizontal in [true, false] {
            let server = try Server()
            defer { server.stop() }
            let flag = horizontal ? "-h" : "-v"
            try server.cli(["split-window", flag, "-t", "%0"])
            try server.cli(["split-window", flag, "-t", "%1"])
            let control = try server.attach()
            defer { control.stop() }
            let before = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
                control.command("display-message -p -t @0 '#{window_layout}'")))
            let target = try XCTUnwrap(TmuxDividerResize.target(in: before, horizontal: horizontal,
                                       leftPaneIDs: [1], rightPaneIDs: [2], delta: 3))
            try control.command("resize-pane -t @0.%\(target.paneID) \(horizontal ? "-x" : "-y") \(target.size)")
            let after = try XCTUnwrap(TmuxLayoutNode.parseServerLayout(
                control.command("display-message -p -t @0 '#{window_layout}'")))
            guard case let .split(_, beforeChildren, _, _, _, _) = before,
                  case let .split(_, afterChildren, _, _, _, _) = after else {
                return XCTFail("Expected three server siblings")
            }
            XCTAssertEqual(beforeChildren[0], afterChildren[0])
            XCTAssertTrue(before.hasSameTopology(as: after))
            XCTAssertEqual(horizontal ? afterChildren[1].width : afterChildren[1].height, target.size)
            XCTAssertEqual(horizontal ? afterChildren[2].width : afterChildren[2].height,
                           (horizontal ? beforeChildren[2].width : beforeChildren[2].height) - 3)
            XCTAssertEqual(try control.command("display-message -p divider-replies-aligned"), "divider-replies-aligned")
        }
    }

    @MainActor
    private final class Server {
        let executable: String
        let directory: String
        var socket: String { directory + "/socket" }

        init() throws {
            guard let executable = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: FileManager.default.isExecutableFile(atPath:)) else {
                throw XCTSkip("tmux is not installed")
            }
            self.executable = executable
            directory = "/tmp/rs-equalize-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                try cli(["-f", "/dev/null", "new-session", "-d", "-s", "equalize", "-x", "203", "-y", "69", "/bin/sh"])
                try cli(["set-option", "-g", "status", "off"])
                try cli(["set-option", "-g", "aggressive-resize", "off"])
                // Keep later new-window fixtures on tmux's normal sizing path.
                try cli(["set-option", "-w", "-t", "@0", "window-size", "manual"])
                try cli(["resize-window", "-t", "@0", "-x", "203", "-y", "69"])
            } catch {
                stop()
                throw error
            }
        }

        @discardableResult
        func cli(_ arguments: [String]) throws -> String {
            try XCTUnwrap(LocalMultiplexerRecovery.run(executable, ["-S", socket] + arguments,
                environment: [:], deadline: Date().addingTimeInterval(5)), "tmux \(arguments)")
        }

        func attach() throws -> ControlClient {
            let client = try ControlClient(executable: executable, socket: socket)
            do {
                try client.command("refresh-client -C 203,69")
                try client.command("set-option -w -t @0 window-size latest")
                return client
            } catch {
                client.stop()
                throw error
            }
        }

        func stop() {
            try? cli(["kill-server"])
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    /// Like Ghostty's user-query queue, consume exactly one client reply per
    /// command. Subsequent marker queries make surplus/misaligned replies fail.
    @MainActor
    private final class ControlClient {
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var buffered = Data()

        init(executable: String, socket: String) throws {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-S", socket, "-C", "attach-session", "-t", "equalize"]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "TMUX")
            environment.removeValue(forKey: "TMUX_PANE")
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            input.fileHandleForReading.closeFile()
            output.fileHandleForWriting.closeFile()
            let fd = output.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            // The initial attach comes from argv, so its block lacks the flag
            // tmux sets on subsequent commands read from the control pipe.
            do { _ = try reply(acceptAttach: true) } catch { stop(); throw error }
        }

        @discardableResult
        func command(_ command: String) throws -> String {
            try input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
            return try reply()
        }

        private func reply(acceptAttach: Bool = false) throws -> String {
            let deadline = Date().addingTimeInterval(5)
            var block: [String] = []
            var inReply = false
            while Date() < deadline {
                let line = try readLine(deadline: deadline)
                if line.hasPrefix("%begin ") {
                    // Flags bit 0 distinguishes our commands from server hooks.
                    let isClientReply = line.split(separator: " ").last.flatMap { Int($0) }.map { $0 & 1 != 0 } ?? false
                    inReply = acceptAttach || isClientReply
                    block = []
                } else if inReply && line.hasPrefix("%end ") {
                    return block.joined(separator: "\n")
                } else if inReply && line.hasPrefix("%error ") {
                    throw NSError(domain: "TmuxControlTest", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: block.joined(separator: "\n")])
                } else if inReply {
                    block.append(line)
                }
            }
            throw NSError(domain: "TmuxControlTest", code: 2)
        }

        private func readLine(deadline: Date) throws -> String {
            let fd = output.fileHandleForReading.fileDescriptor
            while Date() < deadline {
                if let newline = buffered.firstIndex(of: 10) {
                    let line = String(decoding: buffered[..<newline], as: UTF8.self)
                    buffered.removeSubrange(...newline)
                    return line
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&descriptor, 1, 50) < 0, errno != EINTR { break }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { buffered.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { break }
                else if errno != EAGAIN && errno != EINTR { break }
            }
            throw NSError(domain: "TmuxControlTest", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Timed out or lost tmux control connection"])
        }

        func stop() {
            input.fileHandleForWriting.closeFile()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            output.fileHandleForReading.closeFile()
        }
    }
}
