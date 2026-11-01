//
//  SidebarResizeDivider.swift
//  rootshell
//
//  Shared draggable vertical divider for resizing a docked sidebar column.
//  Used by both the AI Agent sidebar (right edge of the window) and the
//  docked vertical tab sidebar (left edge). Owns the gesture → width
//  transform, clamping, magnetic snap-to-default, snap haptic, and
//  double-tap-to-reset. Lives in Views/Shared (NOT China-gated) so the
//  docked tab sidebar — which ships on China builds — can use it too.
//

import SwiftUI
import UIKit
#if targetEnvironment(macCatalyst)
import AppKit
#endif

/// Which side of the window the resized column lives on. Determines the
/// handle edge and the drag direction that widens the column.
enum SidebarResizeSide {
    /// Column on the LEFT of the window (e.g. the docked tab sidebar). The
    /// handle sits on the column's trailing edge; dragging RIGHT widens it.
    case left
    /// Column on the RIGHT of the window (e.g. the AI Agent sidebar). The
    /// handle sits on the column's leading edge; dragging LEFT widens it.
    case right
}

/// Draggable vertical divider that resizes a sidebar column. Drives the
/// caller's `width` binding live during the drag and persists once on
/// release via `onCommit`. When `defaultWidth` is non-nil the divider
/// magnetically snaps onto it (within `snapThreshold`) and a double-tap /
/// double-click resets the column to it.
struct SidebarResizeDivider: View {
    let side: SidebarResizeSide
    @Binding var width: CGFloat
    @Binding var isDragging: Bool
    let minWidth: CGFloat
    /// Concrete max width for the current layout (caller computes from the
    /// live geometry each render, e.g. `geometry.width * 0.5`).
    let maxWidth: CGFloat
    /// Snap + double-tap-reset target. `nil` disables both.
    let defaultWidth: CGFloat?
    var snapThreshold: CGFloat = 22
    /// Rounded Panes: the divider fills the card gap and shows its line
    /// only on hover or drag.
    var cardGap: CGFloat?
    let backgroundColor: Color
    /// Persist the chosen width. Called on drag end and on reset.
    let onCommit: (CGFloat) -> Void
    /// Keep the column fixed while dragging and commit the preview on release.
    var commitsOnRelease = false

    private let visibleWidth: CGFloat = 1
    private var hitAreaWidth: CGFloat { cardGap ?? 16 }

    @State private var dragStartWidth: CGFloat = 0
    @State private var previewWidth: CGFloat?
    @State private var isInSnapZone = false
    @State private var isHovering = false
    @State private var cursorToken: UUID?
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    @State private var snapHaptic = UISelectionFeedbackGenerator()
    #endif

    var body: some View {
        ZStack {
            // Hit area (invisible) — generous touch/pointer target.
            Rectangle()
                .fill(backgroundColor)
                .frame(width: hitAreaWidth)
                .contentShape(Rectangle())

            // Visible divider line.
            Rectangle()
                .fill(dividerColor)
                .frame(width: commitsOnRelease ? 3 : visibleWidth, height: commitsOnRelease ? 28 : nil)
                .clipShape(Capsule())
        }
        .offset(x: previewOffset)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle().inset(by: commitsOnRelease ? -8 : 0))
        #if targetEnvironment(macCatalyst)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                if cursorToken == nil {
                    cursorToken = UUID()
                }
                if let cursorToken {
                    CatalystCursorCoordinator.shared.ensure(
                        cursorToken,
                        cursor: .resizeLeftRight,
                        priority: .ui
                    )
                }
            } else if !isDragging, let cursorToken {
                CatalystCursorCoordinator.shared.unregister(cursorToken)
                self.cursorToken = nil
            }
        }
        #endif
        .onTapGesture(count: 2) {
            guard let d = defaultWidth else { return }
            let reset = clampedSnapTarget(d)
            width = reset
            onCommit(reset)
        }
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartWidth = width
                        previewWidth = width
                        isInSnapZone = false
                        #if !targetEnvironment(macCatalyst) && !os(visionOS)
                        snapHaptic.prepare()
                        #endif
                        #if targetEnvironment(macCatalyst)
                        if cursorToken == nil {
                            cursorToken = UUID()
                        }
                        if let cursorToken {
                            CatalystCursorCoordinator.shared.ensure(
                                cursorToken,
                                cursor: .resizeLeftRight,
                                priority: .ui
                            )
                        }
                        #endif
                    }
                    apply(translation: value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                    isInSnapZone = false
                    if commitsOnRelease, let previewWidth {
                        width = previewWidth
                        onCommit(previewWidth)
                    } else {
                        onCommit(width)
                    }
                    previewWidth = nil
                    #if targetEnvironment(macCatalyst)
                    if !isHovering, let cursorToken {
                        CatalystCursorCoordinator.shared.unregister(cursorToken)
                        self.cursorToken = nil
                    }
                    #endif
                }
        )
        .onDisappear {
            previewWidth = nil
            isDragging = false
            #if targetEnvironment(macCatalyst)
            if let cursorToken {
                CatalystCursorCoordinator.shared.unregister(cursorToken)
                self.cursorToken = nil
            }
            #endif
        }
    }

    /// Transform a live drag translation into a clamped, snapped width and
    /// publish it, firing a one-shot haptic on entry into the snap zone.
    private func apply(translation: CGFloat) {
        let raw = side == .left ? dragStartWidth + translation : dragStartWidth - translation
        var newWidth = min(max(raw, minWidth), maxWidth)

        var snappedNow = false
        if let d = defaultWidth {
            let target = clampedSnapTarget(d)
            if abs(newWidth - target) <= snapThreshold {
                newWidth = target
                snappedNow = true
            }
        }

        if snappedNow && !isInSnapZone {
            #if !targetEnvironment(macCatalyst) && !os(visionOS)
            snapHaptic.selectionChanged()
            snapHaptic.prepare()
            #endif
        }
        isInSnapZone = snappedNow

        if commitsOnRelease {
            previewWidth = newWidth
        } else {
            width = newWidth
        }
    }

    private var previewOffset: CGFloat {
        guard commitsOnRelease, let previewWidth else { return 0 }
        let delta = previewWidth - width
        return side == .left ? delta : -delta
    }

    /// The default width clamped into the currently-allowed range so snapping
    /// and reset never overshoot a narrow window's max.
    private func clampedSnapTarget(_ d: CGFloat) -> CGFloat {
        min(max(d, minWidth), maxWidth)
    }

    private var dividerColor: Color {
        if isDragging {
            return Color.accentColor
        } else if isHovering || commitsOnRelease {
            return Color(uiColor: .separator).opacity(0.8)
        } else {
            return cardGap == nil ? Color(uiColor: .separator).opacity(0.5) : .clear
        }
    }
}
