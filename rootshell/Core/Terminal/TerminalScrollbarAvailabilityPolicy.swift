import CoreGraphics

/// Decides how to handle missing scrollbar samples, viewport-sized scroll
/// documents, and layout-clamped scroll callbacks across platforms.
nonisolated enum TerminalScrollbarAvailabilityPolicy {
    static func preservesExistingDocument(
        isTmuxPane: Bool,
        hasSurface: Bool,
        hasValidSample: Bool
    ) -> Bool {
        isTmuxPane && !hasSurface && hasValidSample
    }

    /// Chooses the scrollbar sample used to size the scroll document during a
    /// layout pass. When a tmux pane's viewer surface is temporarily absent,
    /// fall back to the last observed sample so resizing does not collapse its
    /// scrollback document or discard its saved offset; once a live surface
    /// authoritatively reports empty history, clear `cachedSample` so a later
    /// surface teardown cannot resurrect obsolete scrollback.
    static func resolveLayoutScrollbar<Sample>(
        liveSample: Sample?,
        cachedSample: inout Sample?,
        isTmuxPane: Bool,
        hasSurface: Bool
    ) -> Sample? {
        if let liveSample {
            return liveSample
        }
        if preservesExistingDocument(
            isTmuxPane: isTmuxPane,
            hasSurface: hasSurface,
            hasValidSample: cachedSample != nil
        ) {
            return cachedSample
        }
        cachedSample = nil
        return nil
    }

    /// Model-space vertical offset (in framebuffer pixels) to restore when
    /// the display scale changes while parked in scrollback. Recomputes from
    /// the scrollbar row and sub-cell smooth offset rather than reusing the old
    /// UIKit point offset, which would map to a different row under the new scale.
    static func scaleAdjustedParkedModelOffsetY(
        scrollbar: (total: UInt64, offset: UInt64, len: UInt64),
        cellHeight: CGFloat,
        preservedSmoothOffset: CGFloat
    ) -> CGFloat {
        guard cellHeight > 0 else { return 0 }
        let bottomRow = scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0
        let clampedRow = min(scrollbar.offset, bottomRow)
        let maxSmooth = max(0, cellHeight - CGFloat.ulpOfOne)
        let clampedSmooth = clampedRow < bottomRow
            ? min(max(preservedSmoothOffset, 0), maxSmooth)
            : 0
        return CGFloat(clampedRow) * cellHeight + clampedSmooth
    }

    /// Computes the UIScrollView document height in points. When there is no
    /// scrollback (`scrollbar == nil`, `total <= len`, or unknown cell metrics),
    /// the document matches the viewport so UIKit never exposes a phantom
    /// scrollable range where the indicator moves while terminal text stays put.
    static func documentHeight(
        viewportHeight: CGFloat,
        cellHeight: CGFloat,
        scale: CGFloat,
        scrollbar: (total: UInt64, len: UInt64)?
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        guard cellHeight > 0, let scrollbar, scrollbar.total > scrollbar.len else {
            return viewportHeight
        }
        let effectiveScale = scale > 0 ? scale : 1
        let modelScrollableHeight = CGFloat(scrollbar.total - scrollbar.len) * cellHeight
        return viewportHeight + modelScrollableHeight / effectiveScale
    }

    /// Whether multiplexer scroll-indicator tracking may treat the surface as
    /// on the alternate screen. Direct Mosh reconstructs the framebuffer
    /// without emitting smcup/1049, so Ghostty's alternate-screen flag remains
    /// false even while tmux/zellij renders copy mode.
    static func allowsMultiplexerScrollTrackingOnScreen(
        isMosh: Bool,
        isSurfaceAlternateActive: @autoclosure () -> Bool
    ) -> Bool {
        isMosh || isSurfaceAlternateActive()
    }

    /// Resolves the active screen's scrollbar state from live surface queries.
    /// Alternate screen never has scrollback; empty primary history resets the
    /// range to the current viewport row count so stale history heights clear.
    static func resolvedLiveScrollbar(
        isAlternateScreen: Bool,
        displayScrollbar: (total: UInt64, offset: UInt64, len: UInt64)?,
        surfaceRows: UInt16
    ) -> (total: UInt64, offset: UInt64, len: UInt64)? {
        if !isAlternateScreen, let displayScrollbar, displayScrollbar.total > displayScrollbar.len {
            return displayScrollbar
        }
        guard surfaceRows > 0 else { return nil }
        let rows = UInt64(surfaceRows)
        return (total: rows, offset: 0, len: rows)
    }

    /// Distinguishes programmatic/layout-clamped `scrollViewDidScroll` callbacks
    /// from genuine user scroll activity (finger drag, trackpad, discrete mouse
    /// wheel, or scrollbar gutter interaction).
    static func shouldIgnoreProgrammaticOrClampedScroll(
        isApplyingTerminalSync: Bool,
        isAdjustingLayoutGeometry: Bool,
        isUserInteracting: Bool,
        hasPendingHerdrReturnToLive: Bool,
        isNativeScrollPanActive: Bool,
        hasRecentDirectScrollInput: Bool
    ) -> Bool {
        if isApplyingTerminalSync {
            return true
        }
        if isAdjustingLayoutGeometry && !isUserInteracting {
            return true
        }
        if hasPendingHerdrReturnToLive
            && !isNativeScrollPanActive
            && !isUserInteracting
            && !hasRecentDirectScrollInput {
            return true
        }
        return false
    }

    /// Promotes indirect/non-drag scroll events (such as discrete mouse wheel
    /// ticks on iPadOS or native scrollbar thumb scrubbing) into live scrolling
    /// when UIKit omits `scrollViewWillBeginDragging`.
    static func shouldPromoteNonDragScrollToLive(
        isLiveScrolling: Bool,
        isAdjustingLayoutGeometry: Bool,
        hasRecentDirectScrollInput: Bool,
        isTouchScrollbarDrag: Bool
    ) -> Bool {
        guard !isLiveScrolling, !isAdjustingLayoutGeometry else { return false }
        return hasRecentDirectScrollInput || isTouchScrollbarDrag
    }
}
