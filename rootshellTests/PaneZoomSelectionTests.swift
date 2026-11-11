import XCTest

final class PaneZoomSelectionTests: XCTestCase {
    func testSwapExcludesSourceAndKeepsDisplayOrder() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [42, 7, 91], excludingPaneID: 7))
        XCTAssertEqual(selection.paneIDs, [42, 91])
        XCTAssertEqual(selection.labels, ["1", "2"])
        XCTAssertEqual(selection.consume("2"), .selected(91))
    }

    func testPaneCycleForwardRunsUnzoomedThroughEachPaneAndBack() {
        var zoomed: Int?
        var visited: [Int?] = []
        for _ in 0..<4 {
            zoomed = PaneZoomCycle.target(zoomedIndex: zoomed, count: 3, forward: true)
            visited.append(zoomed)
        }
        XCTAssertEqual(visited, [0, 1, 2, nil])
    }

    func testPaneCycleBackwardStartsAtLastPane() {
        var zoomed: Int?
        var visited: [Int?] = []
        for _ in 0..<4 {
            zoomed = PaneZoomCycle.target(zoomedIndex: zoomed, count: 3, forward: false)
            visited.append(zoomed)
        }
        XCTAssertEqual(visited, [2, 1, 0, nil])
    }

    func testPaneCycleTreatsUnknownZoomAsUnzoomed() {
        XCTAssertEqual(PaneZoomCycle.target(zoomedIndex: 5, count: 2, forward: true), 0)
        XCTAssertEqual(PaneZoomCycle.target(zoomedIndex: -1, count: 2, forward: false), 1)
        XCTAssertNil(PaneZoomCycle.target(zoomedIndex: nil, count: 0, forward: true))
    }

    func testTwoPaneSwapHasOneSelectableTarget() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [42, 7], excludingPaneID: 42))
        XCTAssertEqual(selection.labels, ["1"])
        XCTAssertEqual(selection.consume("1"), .selected(7))
    }

    func testMissingSwapSourceIsRejected() {
        XCTAssertNil(PaneZoomSelection(paneIDs: [42, 7], excludingPaneID: 91))
    }

    func testSwapUsesSameCancellationRulesIncludingEscape() throws {
        for input in ["\u{1b}", "x", "0", "2", "\r", "\t", "12"] {
            var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [42, 7], excludingPaneID: 42))
            XCTAssertEqual(selection.consume(input), .cancelled)
            XCTAssertEqual(selection.consume("1"), .cancelled)
        }
        var modified = try XCTUnwrap(PaneZoomSelection(paneIDs: [42, 7], excludingPaneID: 42))
        XCTAssertEqual(modified.consume("1", modified: true), .cancelled)
    }

    func testSwapPaddingUsesTargetCountNotTotalPaneCount() throws {
        let nine = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(0..<10), excludingPaneID: 3))
        XCTAssertEqual(nine.labels, (1...9).map(String.init))
        var ten = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(0..<11), excludingPaneID: 3))
        XCTAssertEqual(ten.labels.first, "01")
        XCTAssertEqual(ten.consume("1"), .pending)
        XCTAssertEqual(ten.consume("0"), .selected(10))
    }

    func testSwapCommandPreservesFocusZoomAndScopesBothTargets() throws {
        XCTAssertEqual(try TmuxPaneZoomCommand.swapCommand(windowID: 4, sourcePaneID: 17, targetPaneID: 29),
                       "swap-pane -d -Z -s @4.%17 -t @4.%29")
        for (window, source, target) in [(-1, 1, 2), (0, -1, 2), (0, 1, -1), (0, 1, 1)] {
            XCTAssertThrowsError(try TmuxPaneZoomCommand.swapCommand(windowID: window, sourcePaneID: source, targetPaneID: target))
        }
    }

    func testRejectsSinglePaneAndDuplicateIDs() {
        for ids in [[], [1], [1, 1]] {
            XCTAssertNil(PaneZoomSelection(paneIDs: ids))
        }
    }

    func testLabelsSelectStableIDsInDisplayOrder() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [42, 7, 91]))
        XCTAssertEqual(selection.labels, ["1", "2", "3"])
        XCTAssertEqual(selection.consume("2"), .selected(7))
    }

    func testStringPaneIDsAreOpaqueAndKeepDisplayOrder() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: ["workspace:tab:p9", "workspace:tab:p2"]))
        XCTAssertEqual(selection.labels, ["1", "2"])
        XCTAssertEqual(selection.consume("2"), .selected("workspace:tab:p2"))
        XCTAssertNil(PaneZoomSelection(paneIDs: ["same", "same"]))
    }

    func testViewIDsRemainFrozenWhenSourceOrderChanges() throws {
        var ids = (0..<12).map { _ in UUID() }
        let selected = ids[10]
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: ids))
        ids.reverse()
        XCTAssertEqual(selection.consume("1"), .pending)
        XCTAssertEqual(selection.consume("1"), .selected(selected))
    }

    func testTenPanesUseUnambiguousPaddedLabels() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(20..<30)))
        XCTAssertEqual(selection.labels.first, "01")
        XCTAssertEqual(selection.labels.last, "10")
        XCTAssertEqual(selection.consume("1"), .pending)
        XCTAssertEqual(selection.consume("0"), .selected(29))
    }

    func testLeadingZeroSelectsFirstPane() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(20..<30)))
        XCTAssertEqual(selection.consume("0"), .pending)
        XCTAssertEqual(selection.consume("1"), .selected(20))
    }

    func testHundredPanesRemainUnambiguous() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(0..<100)))
        XCTAssertEqual(selection.labels.first, "001")
        XCTAssertEqual(selection.consume("1"), .pending)
        XCTAssertEqual(selection.consume("0"), .pending)
        XCTAssertEqual(selection.consume("0"), .selected(99))
    }

    func testOtherInputCancelsIncludingPasteAndModifiedDigits() throws {
        for input in ["", "a", "\u{1b}", "\r", "\t", "٣", "１２", "12", "0", "9"] {
            var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
            XCTAssertEqual(selection.consume(input), .cancelled, input)
        }
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
        XCTAssertEqual(selection.consume("1", modified: true), .cancelled)
    }

    func testInvalidPrefixCancelsImmediately() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: Array(0..<12)))
        XCTAssertEqual(selection.consume("2"), .cancelled)
    }

    func testFinishedSelectionCannotChange() throws {
        var selection = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
        XCTAssertEqual(selection.consume("1"), .selected(8))
        XCTAssertEqual(selection.consume("2"), .selected(8))
        var cancelled = try XCTUnwrap(PaneZoomSelection(paneIDs: [8, 9]))
        XCTAssertEqual(cancelled.consume("x"), .cancelled)
        XCTAssertEqual(cancelled.consume("1"), .cancelled)
    }

    @MainActor
    func testZoomQueriesServerAndScopesEveryTarget() async throws {
        for alreadyZoomed in [false, true] {
            var commands: [String] = []
            try await TmuxPaneZoomCommand.zoom(windowID: 4, paneID: 17) { command in
                commands.append(command)
                return command.hasPrefix("display-message") ? (alreadyZoomed ? "1\n" : "0\n") : ""
            }
            var expected = ["select-pane -Z -t @4.%17", "display-message -p -t @4.%17 '#{window_zoomed_flag}'"]
            if !alreadyZoomed { expected.append("resize-pane -Z -t @4.%17") }
            XCTAssertEqual(commands, expected)
        }
    }

    @MainActor
    func testMalformedReplyDoesNotToggleZoom() async {
        var commands: [String] = []
        do {
            try await TmuxPaneZoomCommand.zoom(windowID: 4, paneID: 17) { command in
                commands.append(command)
                return "bad reply"
            }
            XCTFail("Must reject malformed zoom state")
        } catch { }
        XCTAssertEqual(commands.count, 2)
    }

    @MainActor
    func testInvalidTargetSendsNothing() async {
        for (window, pane) in [(-1, 17), (4, -1)] {
            do {
                try await TmuxPaneZoomCommand.zoom(windowID: window, paneID: pane) { _ in
                    XCTFail("Invalid target must not send a command")
                    return ""
                }
                XCTFail("Must reject invalid target")
            } catch { }
        }
    }
}
