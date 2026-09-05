import UIKit

/// SplitTree represents a tree of views that can be divided.
/// This is adapted from the macOS Ghostty implementation for iOS.
struct SplitTree<ViewType: UIView & Identifiable> {
    /// The root of the tree. This can be nil to indicate the tree is empty.
    let root: Node?

    /// The node that is currently zoomed. A zoomed split is expected to take up the full
    /// size of the view area where the splits are shown.
    let zoomed: Node?

    /// A single node in the tree is either a leaf node (a view) or a split (has a
    /// left/right or top/bottom).
    indirect enum Node: Equatable {
        case leaf(view: ViewType)
        case split(Split)

        struct Split: Equatable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node

            static func == (lhs: Split, rhs: Split) -> Bool {
                return lhs.direction == rhs.direction &&
                       lhs.ratio == rhs.ratio &&
                       lhs.left == rhs.left &&
                       lhs.right == rhs.right
            }
        }

        static func == (lhs: Node, rhs: Node) -> Bool {
            switch (lhs, rhs) {
            case let (.leaf(leftView), .leaf(rightView)):
                // Compare UIView instances by object identity
                return leftView === rightView

            case let (.split(split1), .split(split2)):
                return split1 == split2

            default:
                return false
            }
        }
    }

    enum Direction: Hashable {
        case horizontal // Splits are laid out left and right
        case vertical   // Splits are laid out top and bottom
    }

    /// The path to a specific node in the tree.
    struct Path {
        let path: [Component]

        var isEmpty: Bool { path.isEmpty }

        enum Component {
            case left
            case right
        }
    }

    /// Spatial representation of the split tree.
    struct Spatial {
        let slots: [Slot]

        struct Slot {
            let node: Node
            let bounds: CGRect
        }

        enum Direction {
            case left
            case right
            case up
            case down
        }
    }

    enum SplitError: Error {
        case viewNotFound
        case invalidMove
    }

    enum NewDirection {
        case left
        case right
        case down
        case up
    }

    /// The direction that focus can move from a node.
    enum FocusDirection {
        case previous
        case next
        case spatial(Spatial.Direction)
    }
}

// MARK: - SplitTree Basic Operations

extension SplitTree {
    var isEmpty: Bool {
        root == nil
    }

    var isSplit: Bool {
        if case .split = root { return true } else { return false }
    }

    init() {
        self.init(root: nil, zoomed: nil)
    }

    init(view: ViewType) {
        self.init(root: .leaf(view: view), zoomed: nil)
    }

    /// Checks if the tree contains the specified node.
    func contains(_ node: Node) -> Bool {
        guard let root else { return false }
        return root.path(to: node) != nil
    }

    /// Checks if the tree contains the specified view instance.
    func contains(_ view: ViewType) -> Bool {
        guard let root else { return false }
        return root.contains(view)
    }

    /// Insert a new view at the given view point by creating a split in the given direction.
    func insert(view: ViewType, at: ViewType, direction: NewDirection) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }
        return .init(
            root: try root.insert(view: view, at: at, direction: direction),
            zoomed: nil)
    }

    /// Relocate a live leaf without ever publishing a tree missing that leaf.
    /// Removing first also collapses its old parent before splitting the target.
    func moving(view: ViewType, to destination: ViewType, direction: NewDirection) throws -> Self {
        guard view !== destination, zoomed == nil else { throw SplitError.invalidMove }
        guard contains(view), contains(destination), let source = root?.node(view: view) else {
            throw SplitError.viewNotFound
        }
        return try remove(source).insert(view: view, at: destination, direction: direction)
    }

    /// Find a node containing a view with the specified ID.
    func find(id: ViewType.ID) -> Node? {
        guard let root else { return nil }
        return root.find(id: id)
    }

    /// Remove a node from the tree.
    func remove(_ target: Node) -> Self {
        guard let root else { return self }

        if root == target {
            return .init(root: nil, zoomed: nil)
        }

        let newRoot = root.remove(target)
        let newZoomed = (zoomed == target) ? nil : zoomed

        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Replace a node in the tree with a new node.
    func replace(node: Node, with newNode: Node) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }

        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }

        let newRoot = try root.replaceNode(at: path, with: newNode)
        let newZoomed = (zoomed == node) ? newNode : zoomed

        return .init(root: newRoot, zoomed: newZoomed)
    }

    /// Find the next view to focus based on the current focused node and direction.
    func focusTarget(for direction: FocusDirection, from currentNode: Node) -> ViewType? {
        guard let root else { return nil }

        switch direction {
        case .previous:
            let allLeaves = root.leaves()
            let currentView = currentNode.leftmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                return nil
            }
            let index = allLeaves.indexWrapping(before: currentIndex)
            return allLeaves[index]

        case .next:
            let allLeaves = root.leaves()
            let currentView = currentNode.rightmostLeaf()
            guard let currentIndex = allLeaves.firstIndex(where: { $0 === currentView }) else {
                return nil
            }
            let index = allLeaves.indexWrapping(after: currentIndex)
            return allLeaves[index]

        case .spatial(let spatialDirection):
            let spatial = root.spatial()
            let nodes = spatial.slots(in: spatialDirection, from: currentNode)

            if nodes.isEmpty {
                return nil
            }

            let bestNode = nodes.first(where: {
                if case .leaf = $0.node { return true } else { return false }
            }) ?? nodes[0]

            switch bestNode.node {
            case .leaf(let view):
                return view

            case .split:
                return switch spatialDirection {
                case .up, .left: bestNode.node.leftmostLeaf()
                case .down, .right: bestNode.node.rightmostLeaf()
                }
            }
        }
    }

    /// Equalize all splits in the tree.
    func equalize() -> Self {
        guard let root else { return self }
        let newRoot = root.equalize()
        return .init(root: newRoot, zoomed: zoomed)
    }

    /// Resize a node in the tree by the given pixel amount.
    func resize(node: Node, by pixels: UInt16, in direction: Spatial.Direction, with bounds: CGRect) throws -> Self {
        guard let root else { throw SplitError.viewNotFound }

        guard let path = root.path(to: node) else {
            throw SplitError.viewNotFound
        }

        let targetSplitDirection: Direction = switch direction {
        case .up, .down: .vertical
        case .left, .right: .horizontal
        }

        var splitPath: Path?
        var splitNode: Node?

        for i in stride(from: path.path.count - 1, through: 0, by: -1) {
            let parentPath = Path(path: Array(path.path.prefix(i)))
            if let parent = root.node(at: parentPath), case .split(let split) = parent {
                if split.direction == targetSplitDirection {
                    splitPath = parentPath
                    splitNode = parent
                    break
                }
            }
        }

        guard let splitPath = splitPath,
              let splitNode = splitNode,
              case .split(let split) = splitNode else {
            throw SplitError.viewNotFound
        }

        let spatial = root.spatial(within: bounds.size)
        guard let splitSlot = spatial.slots.first(where: { $0.node == splitNode }) else {
            throw SplitError.viewNotFound
        }

        let pixelOffset = Double(pixels)
        let newRatio: Double

        switch (split.direction, direction) {
        case (.horizontal, .left):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio - (pixelOffset / splitSlot.bounds.width)))
        case (.horizontal, .right):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio + (pixelOffset / splitSlot.bounds.width)))
        case (.vertical, .up):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio - (pixelOffset / splitSlot.bounds.height)))
        case (.vertical, .down):
            newRatio = Swift.max(0.1, Swift.min(0.9, split.ratio + (pixelOffset / splitSlot.bounds.height)))
        default:
            throw SplitError.viewNotFound
        }

        let newSplit = Node.Split(
            direction: split.direction,
            ratio: newRatio,
            left: split.left,
            right: split.right
        )

        let newRoot = try root.replaceNode(at: splitPath, with: .split(newSplit))
        return .init(root: newRoot, zoomed: nil)
    }

    /// Toggle the zoom state of a node.
    func toggleZoom(for node: Node) -> Self {
        if zoomed == node {
            return .init(root: root, zoomed: nil)
        } else {
            return .init(root: root, zoomed: node)
        }
    }
}

// MARK: - SplitTree.Node Operations

extension SplitTree.Node {
    /// Find a node containing a view with the specified ID.
    func find(id: ViewType.ID) -> SplitTree.Node? {
        switch self {
        case .leaf(let view):
            return view.id == id ? self : nil

        case .split(let split):
            if let found = split.left.find(id: id) {
                return found
            }
            return split.right.find(id: id)
        }
    }

    /// Returns the node in the tree that contains the given view.
    func node(view: ViewType) -> SplitTree.Node? {
        switch self {
        case .leaf(let v):
            return v === view ? self : nil

        case .split(let split):
            if let result = split.left.node(view: view) {
                return result
            } else if let result = split.right.node(view: view) {
                return result
            }
            return nil
        }
    }

    /// Checks if this node or any of its children contain the specified view instance.
    func contains(_ view: ViewType) -> Bool {
        return node(view: view) != nil
    }

    /// Returns the path to a given node in the tree.
    func path(to node: Self) -> SplitTree.Path? {
        var components: [SplitTree.Path.Component] = []

        func search(_ current: Self) -> Bool {
            if current == node {
                return true
            }

            switch current {
            case .leaf:
                return false

            case .split(let split):
                components.append(.left)
                if search(split.left) {
                    return true
                }
                components.removeLast()

                components.append(.right)
                if search(split.right) {
                    return true
                }
                components.removeLast()

                return false
            }
        }

        return search(self) ? SplitTree.Path(path: components) : nil
    }

    /// Returns the node at the given path from this node as root.
    func node(at path: SplitTree.Path) -> SplitTree.Node? {
        if path.isEmpty {
            return self
        }

        guard case .split(let split) = self else {
            return nil
        }

        let component = path.path[0]
        let remainingPath = SplitTree.Path(path: Array(path.path.dropFirst()))

        switch component {
        case .left:
            return split.left.node(at: remainingPath)
        case .right:
            return split.right.node(at: remainingPath)
        }
    }

    /// Insert a new view into the split tree.
    func insert(view: ViewType, at: ViewType, direction: SplitTree.NewDirection) throws -> Self {
        guard let path = path(to: .leaf(view: at)) else {
            throw SplitTree.SplitError.viewNotFound
        }

        let splitDirection: SplitTree.Direction
        let newViewOnLeft: Bool

        switch direction {
        case .left:
            splitDirection = .horizontal
            newViewOnLeft = true
        case .right:
            splitDirection = .horizontal
            newViewOnLeft = false
        case .up:
            splitDirection = .vertical
            newViewOnLeft = true
        case .down:
            splitDirection = .vertical
            newViewOnLeft = false
        }

        let newNode: SplitTree.Node = .leaf(view: view)
        let existingNode: SplitTree.Node = .leaf(view: at)
        let newSplit: SplitTree.Node = .split(.init(
            direction: splitDirection,
            ratio: 0.5,
            left: newViewOnLeft ? newNode : existingNode,
            right: newViewOnLeft ? existingNode : newNode
        ))

        return try replaceNode(at: path, with: newSplit)
    }

    /// Replace a node at the given path.
    func replaceNode(at path: SplitTree.Path, with newNode: Self) throws -> Self {
        if path.isEmpty {
            return newNode
        }

        func replaceInner(current: SplitTree.Node, pathOffset: Int) throws -> SplitTree.Node {
            if pathOffset >= path.path.count {
                return newNode
            }

            guard case .split(let split) = current else {
                throw SplitTree.SplitError.viewNotFound
            }

            let component = path.path[pathOffset]
            switch component {
            case .left:
                return .split(.init(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: try replaceInner(current: split.left, pathOffset: pathOffset + 1),
                    right: split.right
                ))
            case .right:
                return .split(.init(
                    direction: split.direction,
                    ratio: split.ratio,
                    left: split.left,
                    right: try replaceInner(current: split.right, pathOffset: pathOffset + 1)
                ))
            }
        }

        return try replaceInner(current: self, pathOffset: 0)
    }

    /// Remove a node from the tree.
    func remove(_ target: SplitTree.Node) -> SplitTree.Node? {
        if self == target {
            return nil
        }

        switch self {
        case .leaf:
            return self

        case .split(let split):
            let newLeft = split.left.remove(target)
            let newRight = split.right.remove(target)

            if newLeft == nil && newRight == nil {
                return nil
            } else if newLeft == nil {
                return newRight
            } else if newRight == nil {
                return newLeft
            }

            return .split(.init(
                direction: split.direction,
                ratio: split.ratio,
                left: newLeft!,
                right: newRight!
            ))
        }
    }

    /// Get the leftmost leaf in this subtree.
    func leftmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.left.leftmostLeaf()
        }
    }

    /// Get the rightmost leaf in this subtree.
    func rightmostLeaf() -> ViewType {
        switch self {
        case .leaf(let view):
            return view
        case .split(let split):
            return split.right.rightmostLeaf()
        }
    }

    /// Equalize this node and all its children.
    func equalize() -> SplitTree.Node {
        let (equalizedNode, _) = equalizeWithWeight()
        return equalizedNode
    }

    private func equalizeWithWeight() -> (node: SplitTree.Node, weight: Int) {
        switch self {
        case .leaf:
            return (self, 1)

        case .split(let split):
            let leftWeight = split.left.weightForDirection(split.direction)
            let rightWeight = split.right.weightForDirection(split.direction)

            let totalWeight = leftWeight + rightWeight
            let newRatio = Double(leftWeight) / Double(totalWeight)

            let (leftNode, _) = split.left.equalizeWithWeight()
            let (rightNode, _) = split.right.equalizeWithWeight()

            let newSplit = SplitTree.Node.Split(
                direction: split.direction,
                ratio: newRatio,
                left: leftNode,
                right: rightNode
            )

            return (.split(newSplit), totalWeight)
        }
    }

    private func weightForDirection(_ direction: SplitTree.Direction) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            if split.direction == direction {
                return split.left.weightForDirection(direction) + split.right.weightForDirection(direction)
            } else {
                return 1
            }
        }
    }

    /// Returns all leaf views in this subtree.
    func leaves() -> [ViewType] {
        switch self {
        case .leaf(let view):
            return [view]

        case .split(let split):
            return split.left.leaves() + split.right.leaves()
        }
    }

    /// Find the neighbor node of a given node in the tree.
    /// This is useful for determining where to move focus when a node is removed.
    func findNeighbor(of target: SplitTree.Node) -> SplitTree.Node? {
        switch self {
        case .leaf:
            return nil

        case .split(let split):
            if split.left == target {
                return split.right
            } else if split.right == target {
                return split.left
            }

            if let found = split.left.findNeighbor(of: target) {
                return found
            }
            return split.right.findNeighbor(of: target)
        }
    }
}

// MARK: - Spatial Navigation

extension SplitTree.Node {
    /// Returns the spatial representation of this node.
    func spatial(within bounds: CGSize? = nil) -> SplitTree.Spatial {
        let width: Double
        let height: Double

        if let bounds {
            width = bounds.width
            height = bounds.height
        } else {
            let (w, h) = self.dimensions()
            width = Double(w)
            height = Double(h)
        }

        let slots = spatialSlots(in: CGRect(x: 0, y: 0, width: width, height: height))
        return SplitTree.Spatial(slots: slots)
    }

    private func dimensions() -> (width: UInt, height: UInt) {
        switch self {
        case .leaf:
            return (1, 1)

        case .split(let split):
            let leftDimensions = split.left.dimensions()
            let rightDimensions = split.right.dimensions()

            switch split.direction {
            case .horizontal:
                return (
                    width: leftDimensions.width + rightDimensions.width,
                    height: Swift.max(leftDimensions.height, rightDimensions.height)
                )

            case .vertical:
                return (
                    width: Swift.max(leftDimensions.width, rightDimensions.width),
                    height: leftDimensions.height + rightDimensions.height
                )
            }
        }
    }

    private func spatialSlots(in bounds: CGRect) -> [SplitTree.Spatial.Slot] {
        switch self {
        case .leaf:
            return [.init(node: self, bounds: bounds)]

        case .split(let split):
            let leftBounds: CGRect
            let rightBounds: CGRect

            switch split.direction {
            case .horizontal:
                let splitX = bounds.minX + bounds.width * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width * split.ratio,
                    height: bounds.height
                )
                rightBounds = CGRect(
                    x: splitX,
                    y: bounds.minY,
                    width: bounds.width * (1 - split.ratio),
                    height: bounds.height
                )

            case .vertical:
                let splitY = bounds.minY + bounds.height * split.ratio
                leftBounds = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * split.ratio
                )
                rightBounds = CGRect(
                    x: bounds.minX,
                    y: splitY,
                    width: bounds.width,
                    height: bounds.height * (1 - split.ratio)
                )
            }

            var slots: [SplitTree.Spatial.Slot] = [.init(node: self, bounds: bounds)]
            slots += split.left.spatialSlots(in: leftBounds)
            slots += split.right.spatialSlots(in: rightBounds)

            return slots
        }
    }
}

// MARK: - Spatial Helpers

extension SplitTree.Spatial {
    /// Returns all slots in the specified direction relative to the reference node.
    func slots(in direction: Direction, from referenceNode: SplitTree.Node) -> [Slot] {
        guard let refSlot = slots.first(where: { $0.node == referenceNode }) else { return [] }

        func distance(from rect1: CGRect, to rect2: CGRect) -> Double {
            let dx = rect2.minX - rect1.minX
            let dy = rect2.minY - rect1.minY
            return sqrt(dx * dx + dy * dy)
        }

        let result = switch direction {
        case .left:
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxX <= refSlot.bounds.minX
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }

        case .right:
            slots.filter {
                $0.node != referenceNode && $0.bounds.minX >= refSlot.bounds.maxX
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }

        case .up:
            slots.filter {
                $0.node != referenceNode && $0.bounds.maxY <= refSlot.bounds.minY
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }

        case .down:
            slots.filter {
                $0.node != referenceNode && $0.bounds.minY >= refSlot.bounds.maxY
            }.sorted {
                distance(from: refSlot.bounds, to: $0.bounds) < distance(from: refSlot.bounds, to: $1.bounds)
            }
        }

        return result
    }
}

// MARK: - Collection Support

extension SplitTree: Sequence {
    func makeIterator() -> [ViewType].Iterator {
        return root?.leaves().makeIterator() ?? [].makeIterator()
    }
}

extension SplitTree: Collection {
    typealias Index = Int
    typealias Element = ViewType

    var startIndex: Int { 0 }
    var endIndex: Int { root?.leaves().count ?? 0 }

    subscript(position: Int) -> ViewType {
        precondition(position >= 0 && position < endIndex, "Index out of bounds")
        let leaves = root?.leaves() ?? []
        return leaves[position]
    }

    func index(after i: Int) -> Int {
        precondition(i < endIndex, "Cannot increment index beyond endIndex")
        return i + 1
    }
}

// MARK: - Structural Identity

extension SplitTree.Node {
    /// Returns a hashable representation that captures this node's structural identity.
    var structuralIdentity: StructuralIdentity {
        StructuralIdentity(self)
    }

    /// Hashable representation of a node's structural identity.
    struct StructuralIdentity: Hashable {
        private let node: SplitTree.Node

        init(_ node: SplitTree.Node) {
            self.node = node
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.node.isStructurallyEqual(to: rhs.node)
        }

        func hash(into hasher: inout Hasher) {
            node.hashStructure(into: &hasher)
        }
    }

    /// Checks whether this node is structurally equal to another node.
    fileprivate func isStructurallyEqual(to other: Self) -> Bool {
        switch (self, other) {
        case let (.leaf(lhsView), .leaf(rhsView)):
            return lhsView === rhsView

        case let (.split(lhsSplit), .split(rhsSplit)):
            return lhsSplit.direction == rhsSplit.direction &&
                   lhsSplit.left.isStructurallyEqual(to: rhsSplit.left) &&
                   lhsSplit.right.isStructurallyEqual(to: rhsSplit.right)

        default:
            return false
        }
    }

    /// Hash keys for structural identity hashing.
    private enum HashKey: UInt8 {
        case leaf = 0
        case split = 1
    }

    /// Hashes the structure of this node, excluding split ratios.
    fileprivate func hashStructure(into hasher: inout Hasher) {
        switch self {
        case .leaf(let view):
            hasher.combine(HashKey.leaf)
            hasher.combine(ObjectIdentifier(view))

        case .split(let split):
            hasher.combine(HashKey.split)
            hasher.combine(split.direction)
            split.left.hashStructure(into: &hasher)
            split.right.hashStructure(into: &hasher)
        }
    }
}

extension SplitTree {
    /// Returns a hashable representation that captures this tree's structural identity.
    var structuralIdentity: StructuralIdentity {
        StructuralIdentity(self)
    }

    /// Hashable representation of a SplitTree's structural identity.
    struct StructuralIdentity: Hashable {
        private let root: Node?
        private let zoomed: Node?

        init(_ tree: SplitTree) {
            self.root = tree.root
            self.zoomed = tree.zoomed
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            areNodesStructurallyEqual(lhs.root, rhs.root) &&
            areNodesStructurallyEqual(lhs.zoomed, rhs.zoomed)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(0)
            if let root {
                root.hashStructure(into: &hasher)
            }

            hasher.combine(1)
            if let zoomed {
                zoomed.hashStructure(into: &hasher)
            }
        }

        private static func areNodesStructurallyEqual(_ lhs: Node?, _ rhs: Node?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case let (lhs?, rhs?):
                return lhs.isStructurallyEqual(to: rhs)
            default:
                return false
            }
        }
    }
}

// MARK: - Array Extension for Wrapping

extension Array {
    func indexWrapping(before index: Index) -> Index {
        if index == startIndex {
            return isEmpty ? startIndex : indices.last!
        }
        return self.index(before: index)
    }

    func indexWrapping(after index: Index) -> Index {
        let nextIndex = self.index(after: index)
        return nextIndex == endIndex ? startIndex : nextIndex
    }
}
