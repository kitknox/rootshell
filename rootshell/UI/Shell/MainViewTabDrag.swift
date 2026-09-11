//
//  MainViewTabDrag.swift
//  rootshell
//
//  Tab drag state and drag/drop modifier for the tab bar, extracted for
//  build parallelization.
//

import SwiftUI
import Combine
import GhosttyKit
import os
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tab Drag Modifier

#if targetEnvironment(macCatalyst)
/// Shared state for tab drag operations in titlebar mode
/// Uses visual offset approach: doesn't reorder during drag, only on drop
/// Window-aware: only applies visual changes to the window that initiated the drag
@MainActor
final class TabDragState: ObservableObject {
    static let shared = TabDragState()

    /// ID of the window currently dragging (nil if no drag in progress)
    @Published var draggingWindowId: String?
    /// Index of the tab being dragged (in original array order)
    @Published var draggedIndex: Int?
    /// Current drag offset from the starting position
    @Published var dragOffset: CGFloat = 0
    /// Average width of tabs for calculating target position
    var tabWidth: CGFloat = 150

    private init() {}

    func startDrag(windowId: String, index: Int, tabWidth: CGFloat) {
        if self.draggingWindowId != windowId { self.draggingWindowId = windowId }
        if self.draggedIndex != index { self.draggedIndex = index }
        if self.dragOffset != 0 { self.dragOffset = 0 }
        self.tabWidth = tabWidth
    }

    func updateOffset(_ offset: CGFloat) {
        // DragGesture fires per-pixel during drag; @Published would invalidate
        // every TabDragModifier on every tab on every frame. Equality-guard so
        // a non-moving update is a no-op (e.g. pointer hold without movement).
        if self.dragOffset != offset { self.dragOffset = offset }
    }

    func reset() {
        if draggingWindowId != nil { draggingWindowId = nil }
        if draggedIndex != nil { draggedIndex = nil }
        if dragOffset != 0 { dragOffset = 0 }
    }

    /// Calculate target index based on current drag offset
    func targetIndex(tabCount: Int) -> Int {
        guard let draggedIndex = draggedIndex else { return 0 }

        // Calculate how many positions we've moved based on offset
        // Use 60% threshold to make it feel natural
        let threshold = tabWidth * 0.6
        let positions = Int((dragOffset + (dragOffset > 0 ? threshold : -threshold)) / tabWidth)
        let target = draggedIndex + positions

        return max(0, min(tabCount - 1, target))
    }

    /// Get the visual offset for a tab at the given index
    /// Non-dragged tabs shift to make room for the dragged tab
    /// Only returns non-zero for the window that initiated the drag
    func visualOffset(forTabAt index: Int, tabCount: Int, windowId: String) -> CGFloat {
        // Only apply visual offset to the window that's actually dragging
        guard draggingWindowId == windowId else { return 0 }
        guard let draggedIndex = draggedIndex else { return 0 }

        // The dragged tab follows the mouse
        if index == draggedIndex {
            return dragOffset
        }

        // Calculate where the dragged tab would end up
        let target = targetIndex(tabCount: tabCount)

        // Tabs between original and target position need to shift
        if draggedIndex < target {
            // Dragging right: tabs between original+1 and target shift left
            if index > draggedIndex && index <= target {
                return -tabWidth
            }
        } else if draggedIndex > target {
            // Dragging left: tabs between target and original-1 shift right
            if index >= target && index < draggedIndex {
                return tabWidth
            }
        }

        return 0
    }

    /// Check if this window is the one currently dragging
    func isDragging(windowId: String) -> Bool {
        draggingWindowId == windowId
    }

    /// Check if the given index is being dragged in the specified window
    func isDraggedIndex(_ index: Int, windowId: String) -> Bool {
        draggingWindowId == windowId && draggedIndex == index
    }
}
#endif

/// Handles tab dragging with platform-specific behavior
/// Tab drag modifier using standard SwiftUI onDrag/onDrop
/// Window background dragging is disabled via movableByWindowBackground when titlebar tabs are enabled,
/// allowing SwiftUI drag gestures to work without interference
struct TabDragModifier: ViewModifier {
    let tab: TerminalTab
    let index: Int
    let windowId: String
    /// `TabsModel` is `@Observable`; reads inside `body` track per-property
    /// dependencies. We previously plumbed four `@Binding`s through here —
    /// `terminals`, `draggingTab`, `selectedTabIndex`, `tabBarVersion` — each
    /// one a write into `MainView`'s `@State` that invalidated all of its
    /// body. Now everything routes through this reference.
    let tabsModel: TabsModel
    let tabFrames: [UUID: CGRect]
    let usesTitlebarTabs: Bool

#if targetEnvironment(macCatalyst)
    @ObservedObject private var dragState = TabDragState.shared
#endif

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        if usesTitlebarTabs {
            let dragIndex = renderedDragIndex ?? index
            let tabCount = max(renderedTabCount, 1)
            content
                .zIndex(dragState.isDraggedIndex(dragIndex, windowId: windowId) ? 1 : 0)
                .offset(x: dragState.visualOffset(forTabAt: dragIndex, tabCount: tabCount, windowId: windowId))
                // Spring must match the one in `makeTitlebarDragGesture`'s
                // .onEnded `withAnimation`. `.animation(value:)` overrides
                // ambient withAnimation for the value it's tracking, so
                // mismatched curves cause layout interpolation and offset
                // decay to desync at drop — for one frame the displaced
                // edge tab renders at "new layout + old offset" and visibly
                // jumps the wrong direction before settling.
                .animation(.snappy(duration: 0.28, extraBounce: 0.0), value: dragState.dragOffset)
                .gesture(makeTitlebarDragGesture())
        } else {
            standardDragDrop(content)
        }
#else
        standardDragDrop(content)
#endif
    }

#if targetEnvironment(macCatalyst)
    private var dragOrderedTabs: [TabModel] {
        tabsModel.navigationTabs
    }

    private var renderedDragIndex: Int? {
        dragOrderedTabs.firstIndex(where: { $0.id == tab.id })
    }

    private var renderedTabCount: Int {
        dragOrderedTabs.count
    }

    private func makeTitlebarDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard let dragIndex = renderedDragIndex else { return }

                // Start drag if not already dragging (for this window)
                if !dragState.isDragging(windowId: windowId) {
                    let tabWidth = tabFrames[tab.id]?.width ?? 150
                    dragState.startDrag(windowId: windowId, index: dragIndex, tabWidth: tabWidth)
                    tabsModel.draggingTabID = tab.id
                }

                // Only process events for the tab that started the drag in this window
                guard dragState.isDraggedIndex(dragIndex, windowId: windowId) else { return }

                dragState.updateOffset(value.translation.width)
            }
            .onEnded { _ in
                let orderedTabs = dragOrderedTabs
                guard let dragIndex = orderedTabs.firstIndex(where: { $0.id == tab.id }) else {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
                        dragState.reset()
                    }
                    tabsModel.draggingTabID = nil
                    return
                }

                // Only process end for the tab that started the drag in this window
                guard dragState.isDraggedIndex(dragIndex, windowId: windowId) else { return }

                // Commit the reorder.
                //
                // The layout change AND the offset reset must be animated by
                // the SAME transaction. Without `withAnimation`, the array
                // reorder snaps layout positions instantly while the per-tab
                // .interactiveSpring on `dragOffset` is still mid-flight
                // returning offsets to 0. For one frame the displaced tabs
                // get rendered at "new layout + old offset" (e.g., the tab
                // that was visually at position 1 via offset = +tabWidth
                // ends up at NEW position 1 + tabWidth = position 2), which
                // reads as the edge tab "jumping" before settling. Wrap
                // both reorder and reset so layout interpolation and offset
                // decay run together.
                let target = dragState.targetIndex(tabCount: orderedTabs.count)
                if target != dragIndex,
                   orderedTabs.indices.contains(target),
                   tabsModel.index(of: tab.id) != nil {
                    let selectedID = tabsModel.selectedTabID

                    let didMove = withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
                        let moved = tabsModel.moveTabInActiveOrder(
                            movingID: tab.id,
                            toTargetID: orderedTabs[target].id
                        )
                        dragState.reset()
                        return moved
                    }

                    // Selection is ID-keyed, so it follows the moved tab automatically;
                    // re-assert it to make sure it survives any external observers.
                    if let selectedID, tabsModel.tabs.contains(where: { $0.id == selectedID }) {
                        tabsModel.selectedTabID = selectedID
                    }

                    // Commit a multiplexer tab's reorder to the server
                    // (user gesture, never reconcile-driven).
                    if didMove, !tabsModel.isProjectGroupingActive {
                        TmuxController.syncWindowOrderAfterUserMove(of: tab, in: tabsModel.tabs)
                        HerdrController.syncTabOrderAfterUserMove(of: tab, in: tabsModel)
                    }
                } else {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.0)) {
                        dragState.reset()
                    }
                }
                tabsModel.draggingTabID = nil
            }
    }
#endif

    @ViewBuilder
    private func standardDragDrop(_ content: Content) -> some View {
        content
            .onDrag {
                tabsModel.draggingTabID = tab.id
                return TabTransferCoordinator.shared.beginDrag(sourceWindowId: windowId, tabID: tab.id)
            }
            .onDrop(of: [TabTransferCoordinator.dragUTType, .text], delegate: MainView.TabDropDelegate(
                item: tab,
                tabsModel: tabsModel
            ))
    }

}
