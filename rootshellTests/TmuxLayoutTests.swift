import XCTest

@MainActor
final class TmuxLayoutTests: XCTestCase {
    private func pane(_ id: Int, width: Int = 20, height: Int = 24) -> TmuxLayoutNode {
        .pane(paneId: id, width: width, height: height, x: 0, y: 0)
    }

    private func split(_ axis: TmuxLayoutNode.Direction, _ children: [TmuxLayoutNode]) -> TmuxLayoutNode {
        let width = axis == .horizontal ? children.reduce(0) { $0 + $1.width } + children.count - 1 : children.map(\.width).max() ?? 1
        let height = axis == .vertical ? children.reduce(0) { $0 + $1.height } + children.count - 1 : children.map(\.height).max() ?? 1
        return .split(direction: axis, children: children, width: width, height: height, x: 0, y: 0)
    }

    private func columns(width: Int = 20) -> TmuxLayoutNode {
        split(.horizontal, [[1, 10], [7, 13], [11, 12]].map { ids in
            split(.vertical, ids.map { pane($0, width: width) })
        })
    }

    private func pair(width: Int = 20) -> TmuxLayoutNode {
        split(.horizontal, [pane(0, width: width), pane(2, width: width)])
    }

    private var constrained: TmuxLayoutNode {
        split(.horizontal, [pane(0, width: 2, height: 5),
            split(.vertical, [
                split(.horizontal, [1, 2, 3].map { pane($0, width: 1, height: 2) }),
                pane(4, width: 5, height: 2)
            ])
        ])
    }

    private var issue475NestedColumns: TmuxLayoutNode { nestedColumns(equalized: false) }

    private func nestedColumns(equalized: Bool) -> TmuxLayoutNode {
        func column(_ top: Int, _ bottom: Int, width: Int, x: Int) -> TmuxLayoutNode {
            .split(direction: .vertical, children: [
                .pane(paneId: top, width: width, height: 38, x: x, y: 0),
                .pane(paneId: bottom, width: width, height: 38, x: x, y: 39)
            ], width: width, height: 77, x: x, y: 0)
        }
        let middle = column(10, 29, width: equalized ? 69 : 51, x: equalized ? 70 : 105)
        let right = column(26, 30, width: equalized ? 68 : 51, x: equalized ? 140 : 157)
        let nestedRight = TmuxLayoutNode.split(
            direction: .horizontal, children: [middle, right],
            width: equalized ? 138 : 103, height: 77, x: equalized ? 70 : 105, y: 0)
        return .split(direction: .horizontal, children: [
            column(24, 1, width: equalized ? 69 : 104, x: 0), nestedRight
        ], width: 208, height: 77, x: 0, y: 0)
    }

    private func wireLayout(_ node: TmuxLayoutNode) -> String {
        func body(_ node: TmuxLayoutNode) -> String {
            switch node {
            case let .pane(id, width, height, x, y):
                return "\(width)x\(height),\(x),\(y),\(id)"
            case let .split(axis, children, width, height, x, y):
                let brackets = axis == .horizontal ? ("{", "}") : ("[", "]")
                return "\(width)x\(height),\(x),\(y)" + brackets.0
                    + children.map(body).joined(separator: ",") + brackets.1
            }
        }
        let value = body(node)
        var sum: UInt16 = 0
        for byte in value.utf8 { sum = ((sum >> 1) | (sum << 15)) &+ UInt16(byte) }
        let hex = String(sum, radix: 16)
        return String(repeating: "0", count: 4 - hex.count) + hex + "," + value
    }

    private func reply(_ node: TmuxLayoutNode, zoom: Int? = nil, status: String = "off", scrollbars: String = "off",
                       version: String = "3.7c", floating: Int = 0, borderType: String = "") -> String {
        "\(wireLayout(node))|\(zoom == nil ? 0 : 1)|%\(zoom ?? node.paneIDs[0])|\(status)|\(scrollbars)|\(version)"
            + "|\(node.paneIDs.count + floating)|\(borderType)\r\n"
    }

    /// Columns split top/bottom in a 50-row window; bottom pane IDs follow the tops.
    private func gridColumns(_ widths: [Int]) -> TmuxLayoutNode {
        var x = 0
        let columns = widths.enumerated().map { index, width -> TmuxLayoutNode in
            defer { x += width + 1 }
            return .split(direction: .vertical, children: [
                .pane(paneId: index, width: width, height: 25, x: x, y: 0),
                .pane(paneId: index + widths.count, width: width, height: 24, x: x, y: 26)
            ], width: width, height: 50, x: x, y: 0)
        }
        return .split(direction: .horizontal, children: columns, width: x - 1, height: 50, x: 0, y: 0)
    }

    private func nestedGroups(_ widths: [[Int]]) -> TmuxLayoutNode {
        var id = 0
        var x = 0
        let groups = widths.map { widths -> TmuxLayoutNode in
            let start = x
            let panes = widths.map { width -> TmuxLayoutNode in
                defer { id += 1; x += width + 1 }
                return .pane(paneId: id, width: width, height: 24, x: x, y: 0)
            }
            if panes.count == 1 { return panes[0] }
            return .split(direction: .horizontal, children: panes,
                          width: x - start - 1, height: 24, x: start, y: 0)
        }
        return .split(direction: .horizontal, children: groups, width: x - 1, height: 24, x: 0, y: 0)
    }

    private func transposed(_ node: TmuxLayoutNode) -> TmuxLayoutNode {
        switch node {
        case let .pane(id, w, h, x, y):
            return .pane(paneId: id, width: h, height: w, x: y, y: x)
        case let .split(axis, children, w, h, x, y):
            return .split(direction: axis == .horizontal ? .vertical : .horizontal,
                          children: children.map(transposed), width: h, height: w, x: y, y: x)
        }
    }

    func testNestedGroupsUseNativeSpreadWhenLeafResizesCannotReachRoot() async throws {
        let columns = nestedGroups([[75, 75], [25, 25]])
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            XCTAssertTrue(target.hasSameTopology(as: original))
            XCTAssertEqual(target.leaves, original.equalizedLayout()?.leaves)
            XCTAssertNil(original.resizePlan(to: target))
            XCTAssertTrue(original.nativeEqualizationProducesEqualLeaves)
            var current = original
            var spreads = 0
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                if command.hasPrefix("display-message") { return self.reply(current) }
                XCTAssertTrue(command.hasPrefix("select-layout -E -t @1.%"))
                spreads += 1
                current = target
                return ""
            }
            XCTAssertGreaterThan(spreads, 0)
            XCTAssertEqual(current, target)
        }
    }

    func testUnequalNestedGroupsAreRejectedBeforeMutatingOrUnzooming() async throws {
        let columns = nestedGroups([[75, 75], [16, 16, 17]])
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            XCTAssertNil(original.resizePlan(to: target))
            XCTAssertFalse(original.nativeEqualizationProducesEqualLeaves)
            for zoom in [nil, 0] as [Int?] {
                var commands: [String] = []
                do {
                    try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                        commands.append(command)
                        return self.reply(original, zoom: zoom)
                    }
                    XCTFail("Unreachable targets must fail preflight")
                } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                    XCTAssertEqual(commands.count, 1)
                    XCTAssertTrue(commands[0].hasPrefix("display-message"))
                }
            }
        }
    }

    func testResizePlanUsesLastChildToReachBoundaryBeforeNestedGroup() throws {
        let left = TmuxLayoutNode.split(direction: .horizontal, children: [
            .pane(paneId: 0, width: 25, height: 24, x: 0, y: 0),
            .pane(paneId: 1, width: 25, height: 24, x: 26, y: 0)
        ], width: 51, height: 24, x: 0, y: 0)
        let columns = TmuxLayoutNode.split(direction: .horizontal, children: [
            left, .pane(paneId: 2, width: 101, height: 24, x: 52, y: 0)
        ], width: 153, height: 24, x: 0, y: 0)
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            let plan = try XCTUnwrap(original.resizePlan(to: target))
            XCTAssertEqual(plan.map(\.paneID), [2, 0])
            XCTAssertEqual(plan.map(\.size), [50, 51])
            XCTAssertEqual(plan.map(\.direction), Array(repeating: original == columns ? .horizontal : .vertical, count: 2))
        }
    }

    func testNativeFallbackAllowsRoundingCellsInDifferentGroups() {
        let original = nestedGroups([[25, 25], [8, 8]])
        // 69 columns: native -E yields 17/16/17/16, while the flattened
        // sizing model chooses 17/17/16/16. Both are valid equalization.
        XCTAssertEqual(original.width, 69)
        XCTAssertTrue(original.nativeEqualizationProducesEqualLeaves)
        XCTAssertTrue(transposed(original).nativeEqualizationProducesEqualLeaves)
    }

    func testUnreachableBoundaryCanStayPutWhenItsGroupsAlreadyHaveTargetSizes() throws {
        let columns = nestedGroups([[60, 20], [60, 30, 28]])
        // The 81/120 group widths are already correct for five columns in 202
        // cells. Only the dividers inside those groups need to move.
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            XCTAssertFalse(original.nativeEqualizationProducesEqualLeaves)
            let plan = try XCTUnwrap(original.resizePlan(to: target))
            XCTAssertEqual(plan.map(\.paneID), [0, 2, 3])
            XCTAssertEqual(plan.map(\.size), [40, 40, 39])
        }
    }

    func testCorrectUnreachableBoundaryDoesNotBlockUnrelatedResize() async throws {
        let columns = nestedGroups([[50, 50], [80], [20]])
        XCTAssertEqual(columns.width, 203)
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            let direction: TmuxLayoutNode.Direction = original == columns ? .horizontal : .vertical
            XCTAssertEqual(original.resizePlan(to: target), [
                TmuxLayoutNode.PaneResize(paneID: 2, direction: direction, size: 50)
            ])
            var current = original
            var resizes = 0
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                if command.hasPrefix("display-message") { return self.reply(current) }
                let flag = direction == .horizontal ? "-x" : "-y"
                XCTAssertEqual(command, "resize-pane -t @1.%2 \(flag) 50")
                resizes += 1
                current = target
                return ""
            }
            XCTAssertEqual(resizes, 1)
            XCTAssertEqual(current.leaves, target.leaves)
        }
    }

    func testEarlierShrinkCanPutAnUnreachableBoundaryAtItsTarget() throws {
        let columns = nestedGroups([[80], [35, 35], [20], [80]])
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            // Shrinking pane 0 gives 30 cells to the nested group, making its
            // width 101. Its outer boundary then needs no command. Pane 3 can
            // grow into pane 4 without touching that group again.
            let plan = try XCTUnwrap(original.resizePlan(to: target))
            XCTAssertEqual(plan.map(\.paneID), [0, 3, 1])
            XCTAssertEqual(plan.map(\.size), [50, 50, 50])
        }
    }

    func testEarlierGrowthInvalidatesAnOtherwiseCorrectUnreachableBoundary() async throws {
        let columns = nestedGroups([[20], [50, 50], [80], [50]])
        for original in [columns, transposed(columns)] {
            let target = try XCTUnwrap(original.equalizationTarget())
            // Growing pane 0 takes 30 cells from the initially correct nested
            // group. Its next boundary is not addressable, so reject the whole
            // plan before issuing the otherwise reachable first resize.
            XCTAssertNil(original.resizePlan(to: target))
            XCTAssertFalse(original.nativeEqualizationProducesEqualLeaves)
            var commands: [String] = []
            do {
                try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                    commands.append(command)
                    return self.reply(original, zoom: 0)
                }
                XCTFail("Expected preflight to account for the first resize")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                XCTAssertEqual(commands.count, 1)
                XCTAssertTrue(commands[0].hasPrefix("display-message"))
            }
        }
    }

    func testAlreadyEqualNestedGroupsNeedNoMutation() async throws {
        let original = nestedGroups([[50, 50], [50, 50]])
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
            commands.append(command)
            return self.reply(original, zoom: 0)
        }
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].hasPrefix("display-message"))
    }

    func testTopologyAllowsGeometryChangesButRejectsMovedOrReplacedPanes() {
        let original = pair()
        XCTAssertTrue(original.hasSameTopology(as: pair(width: 60)))
        XCTAssertFalse(original.hasSameTopology(as: split(.horizontal, [pane(2), pane(0)])))
        XCTAssertFalse(original.hasSameTopology(as: split(.horizontal, [pane(0), pane(8)])))
        XCTAssertFalse(original.hasSameTopology(as: split(.vertical, [pane(0), pane(2)])))
        XCTAssertFalse(original.hasSameTopology(as: pane(0)))
    }

    func testServerLayoutParserRejectsUncheckedGeometry() {
        XCTAssertEqual(TmuxLayoutNode.parseServerLayout("b25d,80x24,0,0,0"), pane(0, width: 80, height: 24))
        XCTAssertNil(TmuxLayoutNode.parseServerLayout("0000,80x24,0,0,0"))
        XCTAssertNil(TmuxLayoutNode.parseServerLayout("unknown-format"))
        XCTAssertEqual(TmuxLayoutNode.parseServerLayout(wireLayout(constrained)), constrained)
        XCTAssertNil(TmuxLayoutNode.parseServerLayout(wireLayout(split(.horizontal, [pane(0), pane(0)]))))
        let malformed = TmuxLayoutNode.split(direction: .horizontal, children: [pane(0), pane(2)], width: 2, height: 24, x: 0, y: 0)
        XCTAssertNil(TmuxLayoutNode.parseServerLayout(wireLayout(malformed)))
    }

    func testIssue475NestedColumnsFlattenToEqualLeafWidths() throws {
        let original = issue475NestedColumns
        XCTAssertTrue(original.hasNestedSameAxisSplit)
        let equalized = try XCTUnwrap(original.equalizedLayout())
        XCTAssertEqual(equalized.paneIDs, [24, 1, 10, 29, 26, 30])
        guard case let .split(.horizontal, columns, width, height, x, y) = equalized else {
            return XCTFail("Expected flattened horizontal root")
        }
        XCTAssertEqual(width, 208)
        XCTAssertEqual(height, 77)
        XCTAssertEqual(x, 0)
        XCTAssertEqual(y, 0)
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns.map(\.width), [69, 69, 68])
        XCTAssertEqual(TmuxLayoutNode.parseServerLayout(equalized.serverLayoutString), equalized)
    }

    func testIssue475NestedColumnsResizeWithoutImportingLayout() async throws {
        let original = issue475NestedColumns
        let equalized = try XCTUnwrap(original.equalizedLayout())
        var current = original
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
            commands.append(command)
            if command.hasPrefix("display-message") { return self.reply(current) }
            if command.hasPrefix("resize-pane -t @1.%24 -x 69") {
                current = self.nestedColumns(equalized: true)
            } else { XCTFail("Unexpected command: \(command)") }
            return ""
        }
        XCTAssertEqual(current.leaves, equalized.leaves)
        XCTAssertTrue(current.hasSameTopology(as: original))
        XCTAssertEqual(commands.filter { $0.hasPrefix("resize-pane") }.count, 1)
        XCTAssertFalse(commands.contains { $0.hasPrefix("select-layout") })
    }

    func testNestedResizeStopsWhenTopologyChangesWithSamePaneOrder() async throws {
        let original = issue475NestedColumns
        let changed = try XCTUnwrap(original.equalizedLayout())
        var current = original
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                commands.append(command)
                if command.hasPrefix("display-message") { return self.reply(current) }
                if command.hasPrefix("resize-pane") {
                    current = changed
                    return ""
                }
                XCTFail("Unexpected command: \(command)")
                return ""
            }
            XCTFail("Expected topology mismatch")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
            XCTAssertEqual(commands.filter { $0.hasPrefix("resize-pane") }.count, 1)
            XCTAssertFalse(commands.contains { $0.hasPrefix("select-layout") })
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPerpendicularGroupRetainsMinimumWidth() async {
        XCTAssertEqual(constrained.width, 8)
        XCTAssertFalse(constrained.permitsNativeEqualization)
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: constrained) { command in
                commands.append(command)
                return self.reply(self.constrained, zoom: 0)
            }
            XCTFail("Root spreading would shrink the five-column subtree to three")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue(commands[0].hasPrefix("display-message"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSafetyIncludesAncestorShrinkAndBothAxes() {
        let deep = split(.vertical, [constrained, pane(5, width: 8, height: 5)])
        XCTAssertFalse(deep.permitsNativeEqualization)
        func transpose(_ node: TmuxLayoutNode) -> TmuxLayoutNode {
            switch node {
            case let .pane(id, w, h, _, _): return pane(id, width: h, height: w)
            case let .split(axis, children, _, _, _, _):
                return split(axis == .horizontal ? .vertical : .horizontal, children.map(transpose))
            }
        }
        XCTAssertFalse(transpose(constrained).permitsNativeEqualization)
        XCTAssertTrue(columns().permitsNativeEqualization)
    }

    func testSixPaneLayoutWaitsForServerGeometryToSettle() async throws {
        var spreads = 0
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 4, layout: columns()) { command in
            commands.append(command)
            if command.hasPrefix("display-message") {
                return self.reply(self.columns(width: 20 + min((spreads + 5) / 6, 2)))
            }
            spreads += 1
            return ""
        }
        XCTAssertEqual(spreads, 18)
        XCTAssertEqual(commands.filter { $0.hasPrefix("select-layout") }, Array(repeating: [1, 10, 7, 13, 11, 12].map {
            "select-layout -E -t @4.%\($0)"
        }, count: 3).flatMap { $0 })
        XCTAssertTrue(commands.allSatisfy { !$0.contains(";") && !$0.contains("\n") })
        XCTAssertEqual(commands.filter { $0.hasPrefix("display-message") }.count, spreads + 1)
    }

    func testZoomedPaneZeroIsRestoredWithItsOwnCommandAfterConvergence() async throws {
        var commands: [String] = []
        try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
            commands.append(command)
            return command.hasPrefix("display-message") ? self.reply(self.pair(), zoom: commands.count == 1 ? 0 : nil) : ""
        }
        XCTAssertEqual(commands.last, "resize-pane -Z -t @9.%0")
        XCTAssertEqual(commands.filter { $0.hasPrefix("resize-pane") }.count, 1)
        XCTAssertTrue(commands.allSatisfy { !$0.contains(";") && !$0.contains("\n") })
    }

    func testExistingZoomIsNotToggledOffDuringRestoration() async throws {
        var reads = 0
        try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
            XCTAssertFalse(command.hasPrefix("resize-pane"))
            guard command.hasPrefix("display-message") else { return "" }
            reads += 1
            return self.reply(self.pair(), zoom: reads == 1 ? 0 : (reads == 4 ? 2 : nil))
        }
        XCTAssertEqual(reads, 4)
    }

    func testFailureStopsSpreadingAndRestoresZoom() async {
        var reads = 0
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { command in
                commands.append(command)
                if command.hasPrefix("display-message") {
                    reads += 1
                    return self.reply(self.pair(), zoom: reads == 1 ? 0 : nil)
                }
                if command.hasPrefix("select-layout") { throw TmuxSplitEqualizer.Failure.layoutChanged }
                return ""
            }
            XCTFail("Expected failure")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
            XCTAssertEqual(commands.filter { $0.hasPrefix("select-layout") }.count, 1)
            XCTAssertEqual(commands.last, "resize-pane -Z -t @9.%0")
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testServerGeometryIsRecheckedBeforeEverySpread() async {
        let roomy = TmuxLayoutNode.split(direction: .horizontal,
            children: [pane(0, width: 6, height: 5), split(.vertical, [
                split(.horizontal, [1, 2, 3].map { pane($0, width: 2, height: 2) }),
                pane(4, width: 8, height: 2)
            ])], width: 15, height: 5, x: 0, y: 0)
        XCTAssertTrue(roomy.permitsNativeEqualization)
        var spreads = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: roomy) { command in
                if command.hasPrefix("display-message") { return self.reply(spreads == 0 ? roomy : self.constrained) }
                spreads += 1
                return ""
            }
            XCTFail("Must stop when the server layout becomes constrained")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            XCTAssertEqual(spreads, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDecorationsFailClosedInsteadOfUndercountingMinimumCells() async {
        for (status, scrollbars, borderType) in [("top", "off", ""), ("off", "on", ""),
                                                 ("off", "off", "separate"), ("off", "off", "separate-active")] {
            var calls = 0
            do {
                try await TmuxSplitEqualizer.run(windowID: 0, layout: pair()) { _ in
                    calls += 1
                    return self.reply(self.pair(), status: status, scrollbars: scrollbars, borderType: borderType)
                }
                XCTFail("Decoration minima must not be ignored")
            } catch TmuxSplitEqualizer.Failure.unsafeLayout {
                XCTAssertEqual(calls, 1)
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testInvalidSnapshotDoesNotMutateServer() async {
        var calls = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: pair()) { _ in calls += 1; return "malformed" }
            XCTFail("Expected invalid snapshot")
        } catch TmuxSplitEqualizer.Failure.invalidSnapshot {
            XCTAssertEqual(calls, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testConcurrentResizesCannotLoopForever() async {
        var reads = 0
        let layout = pair()
        do {
            try await TmuxSplitEqualizer.run(windowID: 9, layout: layout) { command in
                guard command.hasPrefix("display-message") else { return "" }
                reads += 1
                return self.reply(self.pair(width: 20 + reads))
            }
            XCTFail("Expected bounded failure")
        } catch TmuxSplitEqualizer.Failure.didNotConverge {
            XCTAssertEqual(reads, 1 + layout.paneIDs.count * (2 * layout.depth + 1))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTmux38AndAmbiguousDevelopmentBuildsMatchTheSpreadBug() {
        for version in ["3.8", "3.8-rc", "3.8-rc2", "3.8-rc3", "3.8a", "next-3.8", "next-3.9",
                        "openbsd-7.9", "openbsd-8.0"] {
            XCTAssertTrue(TmuxSplitEqualizer.spreadSkipsNestedGroups(version: version), version)
        }
        for version in ["3.7c", "3.9", "next-3.10", "openbsd-7.8", "openbsd-8.1", ""] {
            XCTAssertFalse(TmuxSplitEqualizer.spreadSkipsNestedGroups(version: version), version)
        }
    }

    func testTmux38NestedLayoutResizesInsteadOfSpreading() async throws {
        let original = gridColumns([101, 50, 50])
        let equalized = gridColumns([67, 67, 67])
        for version in ["3.8", "3.7c"] {
            var current = original
            var commands: [String] = []
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                commands.append(command)
                if command.hasPrefix("display-message") { return self.reply(current, version: version) }
                current = equalized
                return ""
            }
            XCTAssertEqual(current.leaves, equalized.leaves)
            let spreads = commands.filter { $0.hasPrefix("select-layout") }
            if version == "3.8" {
                XCTAssertTrue(spreads.isEmpty)
                XCTAssertEqual(commands.filter { $0.hasPrefix("resize-pane") }, ["resize-pane -t @1.%0 -x 67"])
            } else {
                XCTAssertFalse(spreads.isEmpty)
            }
        }
    }

    func testTmux38RejectsUnplannableNestedLayoutWithoutSpreading() async {
        let original = nestedGroups([[75, 75], [25, 25]])
        XCTAssertTrue(original.nativeEqualizationProducesEqualLeaves)
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                commands.append(command)
                return self.reply(original, version: "3.8")
            }
            XCTFail("tmux 3.8 must not receive -E for nested groups")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue(commands[0].hasPrefix("display-message"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTmux38RejectsFloatingPaneThatCanHideNesting() async {
        let flat = split(.horizontal, [pane(0, width: 120), pane(1, width: 31), pane(2, width: 50)])
        var commands: [String] = []
        do {
            try await TmuxSplitEqualizer.run(windowID: 1, layout: flat) { command in
                commands.append(command)
                return self.reply(flat, version: "3.8", floating: 1)
            }
            XCTFail("The legacy layout cannot show what a floating pane collapsed")
        } catch TmuxSplitEqualizer.Failure.unsafeLayout {
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue(commands[0].hasPrefix("display-message"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testStableButUnequalSpreadIsNotReportedAsSuccess() async {
        let original = gridColumns([101, 50, 50])
        var spreads = 0
        do {
            try await TmuxSplitEqualizer.run(windowID: 1, layout: original) { command in
                if command.hasPrefix("display-message") { return self.reply(original) }
                spreads += 1
                return ""
            }
            XCTFail("An unchanged, unequal layout must not count as equalized")
        } catch TmuxSplitEqualizer.Failure.didNotConverge {
            XCTAssertEqual(spreads, original.paneIDs.count)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testTmux35RemainderOnLastSiblingCountsAsEqualized() async throws {
        // 82 cells: tmux 3.5a's -E settles at 26/26/28, all remainder last.
        let settled = split(.horizontal, [pane(0, width: 26), pane(1, width: 26), pane(2, width: 28)])
        XCTAssertEqual(settled.width, 82)
        var spreads = 0
        try await TmuxSplitEqualizer.run(windowID: 1, layout: settled) { command in
            if command.hasPrefix("display-message") { return self.reply(settled, version: "3.5a") }
            spreads += 1
            return ""
        }
        XCTAssertEqual(spreads, settled.paneIDs.count)
    }

    func testSinglePaneNeedsNoCommands() async throws {
        try await TmuxSplitEqualizer.run(windowID: 0, layout: pane(0)) { _ in
            XCTFail("A single pane is already equalized")
            return ""
        }
    }

    func testDuplicatePaneIDsAreRejectedBeforeSending() async {
        do {
            try await TmuxSplitEqualizer.run(windowID: 0, layout: split(.horizontal, [pane(0), pane(0)])) { _ in
                XCTFail("Malformed topology must not reach the server")
                return ""
            }
            XCTFail("Expected malformed topology to fail")
        } catch TmuxSplitEqualizer.Failure.layoutChanged {
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
