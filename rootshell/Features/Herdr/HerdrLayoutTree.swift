//
//  HerdrLayoutTree.swift
//  rootshell
//
//  Turns herdr's flat pane rectangles into the binary split tree rootshell
//  renders. herdr layouts are guillotine partitions, so a cut that separates
//  every pane cleanly always exists; the search prefers vertical cuts so
//  side-by-side panes fold the way tmux's do.
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation

nonisolated enum HerdrLayoutTree {

    indirect enum Node: Equatable {
        case pane(paneId: String, rect: HerdrControl.Rect)
        /// `horizontal` means the children sit side by side.
        case split(horizontal: Bool, first: Node, second: Node)

        var firstPaneId: String? {
            switch self {
            case .pane(let id, _): return id
            case .split(_, let first, _): return first.firstPaneId
            }
        }

        var paneIds: [String] {
            switch self {
            case .pane(let id, _): return [id]
            case .split(_, let first, let second): return first.paneIds + second.paneIds
            }
        }

        /// Cells spanned along one axis, including the gap between children.
        func extent(horizontal: Bool) -> Int {
            switch self {
            case .pane(_, let rect):
                return horizontal ? rect.width : rect.height
            case .split(let splitHorizontal, let first, let second):
                let a = first.extent(horizontal: horizontal)
                let b = second.extent(horizontal: horizontal)
                return splitHorizontal == horizontal ? a + b : max(a, b)
            }
        }
    }

    static func build(_ layout: HerdrControl.LayoutSnapshot) -> Node? {
        partition(layout.panes)
    }

    private static func partition(_ panes: [HerdrControl.LayoutPane]) -> Node? {
        guard let first = panes.first else { return nil }
        if panes.count == 1 {
            return .pane(paneId: first.pane_id, rect: first.rect)
        }
        if let (left, right) = cut(panes, horizontal: true) ?? cut(panes, horizontal: false) {
            let horizontal = left[0].rect.y == right[0].rect.y || sameRows(left, right)
            guard let a = partition(left), let b = partition(right) else { return nil }
            return .split(horizontal: horizontal, first: a, second: b)
        }
        // Not a clean partition (should not happen); keep the panes in a row.
        let sorted = panes.sorted { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }
        guard let a = partition([sorted[0]]), let b = partition(Array(sorted.dropFirst())) else { return nil }
        return .split(horizontal: true, first: a, second: b)
    }

    private static func sameRows(_ left: [HerdrControl.LayoutPane], _ right: [HerdrControl.LayoutPane]) -> Bool {
        let leftMaxX = left.map { $0.rect.x + $0.rect.width }.max() ?? 0
        let rightMinX = right.map(\.rect.x).min() ?? 0
        return leftMaxX <= rightMinX
    }

    /// Finds the first cut line along which every pane lies wholly on one
    /// side. `horizontal` looks for a vertical line separating left and
    /// right; otherwise a horizontal line separating top and bottom.
    private static func cut(
        _ panes: [HerdrControl.LayoutPane],
        horizontal: Bool
    ) -> ([HerdrControl.LayoutPane], [HerdrControl.LayoutPane])? {
        let starts = Set(panes.map { horizontal ? $0.rect.x : $0.rect.y })
        let minStart = starts.min() ?? 0
        for candidate in starts.sorted() where candidate > minStart {
            let before = panes.filter { pane in
                let end = horizontal ? pane.rect.x + pane.rect.width : pane.rect.y + pane.rect.height
                return end <= candidate
            }
            let after = panes.filter { pane in
                (horizontal ? pane.rect.x : pane.rect.y) >= candidate
            }
            if !before.isEmpty, !after.isEmpty, before.count + after.count == panes.count {
                return (before, after)
            }
        }
        return nil
    }
}
