/// A node in a tmux window's layout tree, decoded from the opaque
/// `ghostty_tmux_layout_*` accessors. Geometry is in terminal cells.
///
/// `nonisolated`: built by `TmuxReconcileDecoder.decode` on the off-main action
/// callback thread (see that type), so it must NOT pick up the project's default
/// `@MainActor` isolation. A pure value type — safe to construct/read anywhere.
nonisolated indirect enum TmuxLayoutNode: Equatable {
    case pane(paneId: Int, width: Int, height: Int, x: Int, y: Int)
    case split(direction: Direction, children: [TmuxLayoutNode], width: Int, height: Int, x: Int, y: Int)

    enum Direction: Equatable { case horizontal, vertical }

    var width: Int {
        switch self {
        case let .pane(_, w, _, _, _): return w
        case let .split(_, _, w, _, _, _): return w
        }
    }

    var height: Int {
        switch self {
        case let .pane(_, _, h, _, _): return h
        case let .split(_, _, _, h, _, _): return h
        }
    }

    private var x: Int {
        switch self {
        case let .pane(_, _, _, x, _), let .split(_, _, _, _, x, _): return x
        }
    }

    private var y: Int {
        switch self {
        case let .pane(_, _, _, _, y), let .split(_, _, _, _, _, y): return y
        }
    }
}

nonisolated extension TmuxLayoutNode {
    var paneIDs: [Int] {
        switch self {
        case let .pane(id, _, _, _, _): return [id]
        case let .split(_, children, _, _, _, _): return children.flatMap(\.paneIDs)
        }
    }

    var depth: Int {
        switch self {
        case .pane: return 1
        case let .split(_, children, _, _, _, _): return 1 + (children.map(\.depth).max() ?? 0)
        }
    }

    /// Geometry and zoom may change during equalization; pane placement must not.
    func hasSameTopology(as other: TmuxLayoutNode) -> Bool {
        switch (self, other) {
        case let (.pane(a, _, _, _, _), .pane(b, _, _, _, _)):
            return a == b
        case let (.split(a, lhs, _, _, _, _), .split(b, rhs, _, _, _, _)):
            return a == b && lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
                pair.0.hasSameTopology(as: pair.1)
            }
        default:
            return false
        }
    }

    /// Native `select-layout -E` equalizes one tmux tree node at a time. When
    /// adjacent splits use the same axis, every binary node can already be
    /// 50/50 while the visible leaves are not (for example 1/2 + 1/4 + 1/4).
    /// Those layouts need explicit target sizes for their visible leaves.
    var hasNestedSameAxisSplit: Bool {
        switch self {
        case .pane:
            return false
        case let .split(direction, children, _, _, _, _):
            return children.contains { child in
                if case let .split(childDirection, _, _, _, _, _) = child,
                   childDirection == direction {
                    return true
                }
                return child.hasNestedSameAxisSplit
            }
        }
    }

    /// Any nesting starts at the root, so checking its children is enough.
    var hasNestedSplit: Bool {
        guard case let .split(_, children, _, _, _, _) = self else { return false }
        return children.contains { if case .split = $0 { return true } else { return false } }
    }
}

extension TmuxLayoutNode {
    /// tmux 3.6's layout_spread_cell bypasses layout_resize_check. A shrink
    /// below these recursive minima can trap layout_resize_adjust forever.
    /// Dividers cost one cell; additional status lines/scrollbars are excluded.
    var permitsNativeEqualization: Bool {
        permitsNativeEqualization(width: width, height: height)
    }

    private func minimumSize(along direction: Direction) -> Int {
        switch self {
        case .pane: return 1
        case let .split(axis, children, _, _, _, _):
            let sizes = children.map { $0.minimumSize(along: direction) }
            return axis == direction ? sizes.reduce(0, +) + max(0, children.count - 1) : sizes.max() ?? 1
        }
    }

    /// Compute equal-cell target geometry by flattening adjacent same-axis
    /// splits. This is a sizing model only: the server tree is never imported
    /// or flattened, and native resize-pane commands retain pane assignments.
    func equalizedLayout() -> TmuxLayoutNode? {
        switch self {
        case let .pane(_, width, height, x, y),
             let .split(_, _, width, height, x, y):
            return equalizedLayout(width: width, height: height, x: x, y: y)
        }
    }

    /// Put the flattened sizing model back into the server's original tree so
    /// we can plan changes to ancestor boundaries before resizing descendants.
    func equalizationTarget() -> TmuxLayoutNode? {
        guard let equalized = equalizedLayout() else { return nil }
        let geometry = Dictionary(uniqueKeysWithValues: equalized.leaves.map { ($0.paneIDs[0], $0) })
        return replacingLeafGeometry(geometry)
    }

    private func replacingLeafGeometry(_ geometry: [Int: TmuxLayoutNode]) -> TmuxLayoutNode? {
        switch self {
        case let .pane(id, _, _, _, _): return geometry[id]
        case let .split(direction, children, _, _, _, _):
            let resized = children.compactMap { $0.replacingLeafGeometry(geometry) }
            guard resized.count == children.count, let first = resized.first else { return nil }
            let width = direction == .horizontal
                ? resized.reduce(0) { $0 + $1.width } + resized.count - 1 : first.width
            let height = direction == .vertical
                ? resized.reduce(0) { $0 + $1.height } + resized.count - 1 : first.height
            return .split(direction: direction, children: resized, width: width, height: height,
                          x: first.x, y: first.y)
        }
    }

    struct PaneResize: Equatable {
        let paneID: Int
        let direction: Direction
        let size: Int
    }

    /// resize-pane stops at the nearest ancestor of the requested axis. A pane
    /// behind another split of that axis cannot move this node's boundaries.
    private func exposedPane(along direction: Direction) -> Int? {
        switch self {
        case let .pane(id, _, _, _, _): return id
        case let .split(axis, children, _, _, _, _):
            guard axis != direction else { return nil }
            return children.lazy.compactMap { $0.exposedPane(along: direction) }.first
        }
    }

    /// Plan left/top boundaries first, then recurse. The last child can move
    /// the preceding boundary; other children can only move their next one.
    /// Reject the whole plan if a boundary that needs to move has no directly
    /// addressable pane. An ancestor resize can disturb descendant boundaries,
    /// even when they currently match their targets.
    func resizePlan(to target: TmuxLayoutNode) -> [PaneResize]? {
        guard hasSameTopology(as: target) else { return nil }
        return resizePlan(to: target, resizingHorizontal: false, resizingVertical: false)
    }

    private func resizePlan(to target: TmuxLayoutNode, resizingHorizontal: Bool,
                            resizingVertical: Bool) -> [PaneResize]? {
        guard case let .split(direction, children, _, _, _, _) = self,
              case let .split(_, targets, _, _, _, _) = target else { return [] }
        let horizontal = direction == .horizontal
        let resizedByAncestor = horizontal ? resizingHorizontal : resizingVertical
        // An ancestor may redistribute cells within this node. Otherwise we
        // know each child's size and can project the effects of earlier steps.
        var sizes: [Int?] = children.map { child in
            resizedByAncestor ? nil : (horizontal ? child.width : child.height)
        }
        var resizedChildren = Array(repeating: resizedByAncestor, count: children.count)
        var plan: [PaneResize] = []
        for index in 0..<(children.count - 1) {
            let targetSize = horizontal ? targets[index].width : targets[index].height
            // Earlier boundaries are already fixed, so a matching child size
            // means this boundary is correct, even if later siblings differ.
            if sizes[index] == targetSize { continue }
            let anchor: Int
            let paneID: Int
            if let id = children[index].exposedPane(along: direction) {
                anchor = index
                paneID = id
            } else if index == children.count - 2,
                      let id = children[index + 1].exposedPane(along: direction) {
                anchor = index + 1
                paneID = id
            } else {
                return nil
            }
            plan.append(PaneResize(paneID: paneID, direction: direction,
                                   size: direction == .horizontal ? targets[anchor].width : targets[anchor].height))
            resizedChildren[index] = true
            if let size = sizes[index] {
                let change = targetSize - size
                if change < 0 {
                    // tmux shrinking gives the released cells to the next
                    // sibling. The target minimum keeps earlier siblings safe.
                    sizes[index + 1] = sizes[index + 1].map { $0 - change }
                    resizedChildren[index + 1] = true
                } else {
                    // Growing consumes space from following siblings in order,
                    // stopping at each subtree's minimum. Feasible targets do
                    // not require borrowing from the already fixed prefix.
                    var remaining = change
                    for donor in (index + 1)..<children.count {
                        guard let donorSize = sizes[donor] else { return nil }
                        let available = donorSize - children[donor].minimumSize(along: direction)
                        let taken = min(remaining, available)
                        if taken > 0 {
                            sizes[donor] = donorSize - taken
                            resizedChildren[donor] = true
                            remaining -= taken
                        }
                        if remaining == 0 { break }
                    }
                    guard remaining == 0 else { return nil }
                }
            } else {
                // Unknown ancestor redistribution requires planning subsequent
                // boundaries conservatively, but cannot disturb a fixed prefix.
                for sibling in (index + 1)..<children.count {
                    sizes[sibling] = nil
                    resizedChildren[sibling] = true
                }
            }
            sizes[index] = targetSize
        }
        for (index, child) in children.enumerated() {
            guard let childPlan = child.resizePlan(
                to: targets[index],
                resizingHorizontal: horizontal ? resizedChildren[index] : resizingHorizontal,
                resizingVertical: horizontal ? resizingVertical : resizedChildren[index]
            ) else { return nil }
            plan.append(contentsOf: childPlan)
        }
        return plan
    }

    /// Model -E on the original tree, then check the visible (flattened)
    /// groups. Accept different placements of rounding cells, but not unequal
    /// proportions such as two columns beside a nested group of three.
    var nativeEqualizationProducesEqualLeaves: Bool {
        equalizedLayout(width: width, height: height, x: x, y: y,
                        flattenSameAxis: false)?.hasEqualVisibleSplits == true
    }

    /// What any tmux -E leaves behind: before 3.6 the last child took the
    /// whole remainder, so direct siblings differ by less than their count.
    var isNativelySpread: Bool {
        guard case let .split(direction, children, _, _, _, _) = self else { return true }
        let sizes = children.map { direction == .horizontal ? $0.width : $0.height }
        guard let smallest = sizes.min(), let largest = sizes.max(),
              largest - smallest < children.count else { return false }
        return children.allSatisfy(\.isNativelySpread)
    }

    private var hasEqualVisibleSplits: Bool {
        guard case let .split(direction, _, _, _, _, _) = self else { return true }
        let children = flattenedChildren(along: direction)
        let sizes = children.map { direction == .horizontal ? $0.width : $0.height }
        guard let smallest = sizes.min(), let largest = sizes.max(), largest - smallest <= 1 else {
            return false
        }
        return children.allSatisfy(\.hasEqualVisibleSplits)
    }

    var leaves: [TmuxLayoutNode] {
        switch self {
        case .pane: return [self]
        case let .split(_, children, _, _, _, _): return children.flatMap(\.leaves)
        }
    }

    var serverLayoutString: String {
        let body = serverLayoutBody
        var checksum: UInt16 = 0
        for byte in body.utf8 {
            checksum = (checksum >> 1) | (checksum << 15)
            checksum = checksum &+ UInt16(byte)
        }
        let hex = String(checksum, radix: 16)
        return String(repeating: "0", count: 4 - hex.count) + hex + "," + body
    }

    private var serverLayoutBody: String {
        switch self {
        case let .pane(id, width, height, x, y):
            return "\(width)x\(height),\(x),\(y),\(id)"
        case let .split(direction, children, width, height, x, y):
            let brackets = direction == .horizontal ? ("{", "}") : ("[", "]")
            return "\(width)x\(height),\(x),\(y)" + brackets.0
                + children.map(\.serverLayoutBody).joined(separator: ",") + brackets.1
        }
    }

    private func flattenedChildren(along direction: Direction) -> [TmuxLayoutNode] {
        if case let .split(axis, children, _, _, _, _) = self, axis == direction {
            return children.flatMap { $0.flattenedChildren(along: direction) }
        }
        return [self]
    }

    private func equalizedLayout(width: Int, height: Int, x: Int, y: Int,
                                 flattenSameAxis: Bool = true) -> TmuxLayoutNode? {
        guard width >= minimumSize(along: .horizontal),
              height >= minimumSize(along: .vertical) else { return nil }
        switch self {
        case let .pane(id, _, _, _, _):
            return .pane(paneId: id, width: width, height: height, x: x, y: y)
        case let .split(direction, originalChildren, _, _, _, _):
            let children = flattenSameAxis ? flattenedChildren(along: direction) : originalChildren
            guard children.count >= 2 else { return nil }
            let horizontal = direction == .horizontal
            var remaining = (horizontal ? width : height) - children.count + 1
            var pending = Array(children.indices)
            var sizes = Array(repeating: 0, count: children.count)

            // Reserve recursive minima first, then share every remaining cell.
            // This keeps perpendicular subtrees valid in cramped windows.
            while !pending.isEmpty {
                let share = remaining / pending.count
                let constrained = pending.filter {
                    children[$0].minimumSize(along: direction) > share
                }
                if constrained.isEmpty {
                    for (offset, index) in pending.enumerated() {
                        sizes[index] = share + (offset < remaining % pending.count ? 1 : 0)
                    }
                    break
                }
                for index in constrained {
                    sizes[index] = children[index].minimumSize(along: direction)
                    remaining -= sizes[index]
                }
                guard remaining >= 0 else { return nil }
                pending.removeAll { constrained.contains($0) }
            }

            var cursor = horizontal ? x : y
            var equalizedChildren: [TmuxLayoutNode] = []
            for (index, child) in children.enumerated() {
                guard let equalized = child.equalizedLayout(
                    width: horizontal ? sizes[index] : width,
                    height: horizontal ? height : sizes[index],
                    x: horizontal ? cursor : x,
                    y: horizontal ? y : cursor,
                    flattenSameAxis: flattenSameAxis
                ) else { return nil }
                equalizedChildren.append(equalized)
                cursor += sizes[index] + 1
            }
            return .split(direction: direction, children: equalizedChildren,
                          width: width, height: height, x: x, y: y)
        }
    }

    private func permitsNativeEqualization(width: Int, height: Int) -> Bool {
        guard width >= minimumSize(along: .horizontal),
              height >= minimumSize(along: .vertical) else { return false }
        guard case let .split(direction, children, _, _, _, _) = self else { return true }
        guard children.count >= 2 else { return false }
        let horizontal = direction == .horizontal
        let available = (horizontal ? width : height) - children.count + 1
        guard available >= children.count else { return false }
        for (index, child) in children.enumerated() {
            let share = available / children.count + (index < available % children.count ? 1 : 0)
            // Check descendants at the smaller of their current and eventual
            // size: -E may reach them before OR after spreading an ancestor.
            guard child.permitsNativeEqualization(
                width: min(child.width, horizontal ? share : width),
                height: min(child.height, horizontal ? height : share)
            ) else { return false }
        }
        return true
    }

    /// Parse the legacy window_layout emitted to control clients (including
    /// while zoomed). Unknown formats fail closed; never spread an unchecked tree.
    static func parseServerLayout(_ value: String) -> TmuxLayoutNode? {
        let bytes = Array(value.utf8)
        guard bytes.count > 5, bytes.count <= 131_072, bytes[4] == 44,
              let expected = UInt16(String(decoding: bytes.prefix(4), as: UTF8.self), radix: 16) else { return nil }
        var checksum: UInt16 = 0
        for byte in bytes.dropFirst(5) {
            checksum = (checksum >> 1) | (checksum << 15)
            checksum = checksum &+ UInt16(byte)
        }
        guard checksum == expected else { return nil }
        var parser = ServerLayoutParser(bytes: bytes)
        guard let node = parser.node(depth: 0), parser.index == bytes.count,
              Set(node.paneIDs).count == node.paneIDs.count else { return nil }
        return node
    }
}

private nonisolated struct ServerLayoutParser {
    let bytes: [UInt8]
    var index = 5
    var nodes = 0

    mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func number() -> Int? {
        let start = index
        while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
        guard index > start, index - start <= 10 else { return nil }
        return Int(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func node(depth: Int) -> TmuxLayoutNode? {
        nodes += 1
        guard depth < 64, nodes <= 2048,
              let width = number(), width > 0, consume(120),
              let height = number(), height > 0, consume(44),
              let x = number(), consume(44), let y = number() else { return nil }
        if consume(44) {
            guard let id = number() else { return nil }
            return .pane(paneId: id, width: width, height: height, x: x, y: y)
        }
        let direction: TmuxLayoutNode.Direction
        let close: UInt8
        if consume(123) { direction = .horizontal; close = 125 }
        else if consume(91) { direction = .vertical; close = 93 }
        else { return nil }
        var children: [TmuxLayoutNode] = []
        repeat {
            guard let child = node(depth: depth + 1) else { return nil }
            children.append(child)
        } while consume(44)
        guard consume(close), children.count >= 2 else { return nil }
        // Reject inconsistent geometry instead of trusting it for the safety check.
        let extent = children.reduce(0) { $0 + (direction == .horizontal ? $1.width : $1.height) } + children.count - 1
        guard extent == (direction == .horizontal ? width : height),
              children.allSatisfy({ direction == .horizontal ? $0.height == height : $0.width == width }) else { return nil }
        return .split(direction: direction, children: children, width: width, height: height, x: x, y: y)
    }
}
