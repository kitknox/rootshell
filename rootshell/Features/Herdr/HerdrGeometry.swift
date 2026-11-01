import Foundation
import CoreGraphics
import IOSurface

/// A layout needs a new parser observation, even when it returns to an
/// earlier size. Replies already in the response pipe belong to the old
/// layout and cannot confirm the new one.
nonisolated struct HerdrParserGrid {
    typealias Grid = TerminalGridReports.Grid
    private(set) var confirmed: Grid?
    private(set) var wanted: Grid?
    private var reports = TerminalGridReports()
    private var staleReplies = 0

    var needsProbe: Bool { wanted != nil && confirmed != wanted }
    var pending: Int { reports.pending }

    mutating func invalidate() {
        confirmed = nil
        wanted = nil
        staleReplies = reports.pending
    }

    mutating func request(_ grid: Grid) {
        if wanted != grid {
            invalidate()
            wanted = grid
        }
    }

    mutating func probe() -> Data {
        reports.pending += 1
        return Data("\u{1b}[18t".utf8)
    }

    mutating func consume(_ data: Data) -> (forward: Data, grids: [Grid]) {
        let result = reports.consume(data)
        var latest: Grid?
        for grid in result.grids {
            if staleReplies > 0 {
                staleReplies -= 1
            } else if wanted != nil {
                confirmed = grid
                latest = grid
            }
        }
        // Several replies can arrive in one read. Only the last observation
        // describes the parser now; an earlier matching reply cannot release
        // output if a later reply in the same read reports another size.
        return (result.forward, latest.map { [$0] } ?? [])
    }
}

/// Every acknowledged snapshot request needs a pushed-record deadline,
/// including requests acknowledged before resize recovery is armed.
@MainActor
enum HerdrSnapshotRecordDeadline {
    static func waitForExpiry(
        requestID: UUID,
        pendingRequest: @MainActor () -> UUID?,
        wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(15)) }
    ) async throws -> Bool {
        guard pendingRequest() == requestID else { return false }
        try await wait()
        // Arrival, detach, replacement, or a new stream retires this deadline.
        return pendingRequest() == requestID
    }
}

/// Output lost during a resize is replaced only by a snapshot requested
/// after that resize. A -> B -> A still creates a new recovery.
nonisolated struct HerdrResizeRecovery {
    let grid: TerminalGridReports.Grid
    private(set) var requestID: UUID?

    mutating func requestedSnapshot(_ id: UUID) {
        requestID = id
    }

    func acceptsSnapshot(requestID: UUID?, grid: TerminalGridReports.Grid) -> Bool {
        guard let expected = self.requestID else { return false }
        return requestID == expected && grid == self.grid
    }
}

/// Insertion can create a surface partway through a host layout. Reconcile
/// after that pass, when its cell metrics are available, without scheduling
/// one refresh per pane or retaining a host that has been dismantled.
@MainActor
final class HerdrLayoutRefresh {
    private var pending = false
    private var generation: UInt64 = 0

    func request(_ refresh: @escaping @MainActor () -> Void) {
        guard !pending else { return }
        pending = true
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.pending = false
            refresh()
        }
    }

    func cancel() {
        generation &+= 1
        pending = false
    }
}

/// Geometry for the UIKit Ghostty surfaces used by herdr panes, including
/// Catalyst. Ghostty's iOS/visionOS font backend uses 96 DPI; its configured
/// window padding is in 72-DPI typographic points, not UIKit points.
nonisolated enum HerdrGeometry {
    /// Latch the coordinate system at gesture start. A foreign projection is
    /// presentation only; it must never rewrite the tree used to claim a tab.
    struct DividerDrag {
        let startRatio: Double
        let parentBounds: CGRect
        let isProjected: Bool
        private(set) var ratio: Double

        init(layoutRatio: Double, displayRatio: Double?, parentBounds: CGRect) {
            startRatio = displayRatio ?? layoutRatio
            ratio = startRatio
            isProjected = displayRatio != nil
            self.parentBounds = parentBounds
        }

        mutating func update(ratio: Double) { self.ratio = ratio }

        var localLayoutRatio: Double? { isProjected ? nil : ratio }

        func previewOffset(horizontal: Bool) -> CGFloat {
            CGFloat(ratio - startRatio) * (horizontal ? parentBounds.width : parentBounds.height)
        }
    }

    /// A viewer packs the actual terminal grids in its own point metrics.
    /// Server layout units still determine topology and ownership requests.
    indirect enum ViewingLayout {
        case pane(CGSize)
        case split(horizontal: Bool, size: CGSize, first: ViewingLayout, second: ViewingLayout)

        var size: CGSize {
            switch self {
            case .pane(let size), .split(_, let size, _, _): return size
            }
        }

        static func joining(_ first: Self, _ second: Self, horizontal: Bool, divider: CGFloat) -> Self {
            let size = CGSize(
                width: horizontal ? first.size.width + divider + second.size.width : max(first.size.width, second.size.width),
                height: horizontal ? max(first.size.height, second.size.height) : first.size.height + divider + second.size.height)
            return .split(horizontal: horizontal, size: size, first: first, second: second)
        }

        func frames(at origin: CGPoint, divider: CGFloat) -> (first: CGRect, second: CGRect, divider: CGRect)? {
            guard case let .split(horizontal, size, first, second) = self else { return nil }
            let firstRect = CGRect(origin: origin, size: first.size)
            let dividerRect = CGRect(
                x: origin.x + (horizontal ? first.size.width : 0),
                y: origin.y + (horizontal ? 0 : first.size.height),
                width: horizontal ? divider : size.width,
                height: horizontal ? size.height : divider)
            let secondRect = CGRect(
                origin: CGPoint(x: horizontal ? dividerRect.maxX : origin.x,
                                y: horizontal ? origin.y : dividerRect.maxY), size: second.size)
            return (firstRect, secondRect, dividerRect)
        }
    }

    static func frameMatches(_ contents: Any, width: UInt32, height: UInt32) -> Bool {
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return false }
        let frame = unsafeBitCast(contents as CFTypeRef, to: IOSurfaceRef.self)
        return IOSurfaceGetWidth(frame) == Int(width) && IOSurfaceGetHeight(frame) == Int(height)
    }

    static func padding(_ configured: Int, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 0 }
        // Match Surface.DerivedConfig.scaledPadding: floor each edge in pixels
        // before converting back to the native layout's points.
        let pixels = floor(Float(configured) * (Float(scale) * 96) / 72)
        return CGFloat(pixels) / scale
    }

    static func chrome(
        paddingX: Int, paddingY: Int, scale: CGFloat, bottomInsetPixels: Double, topInsetPixels: Double = 0
    ) -> CGSize {
        guard scale > 0 else { return .zero }
        // Match Surface.setBottomInset/setTopInset's pixel rounding and clamp.
        func inset(_ pixels: Double) -> CGFloat {
            CGFloat(pixels.isFinite ? min(max(pixels.rounded(), 0), 10_000) : 0)
        }
        return CGSize(
            width: padding(paddingX, scale: scale) * 2,
            height: padding(paddingY, scale: scale) * 2 + (inset(topInsetPixels) + inset(bottomInsetPixels)) / scale
        )
    }

    /// Measure each native slot with its own font, independently of the tab's
    /// layout coordinate system and the other panes' fonts.
    static func paneGrid(slot: CGSize, chrome: CGSize, cellPixels: CGSize, scale: CGFloat) -> HerdrControl.PaneTerminalSize? {
        guard scale > 0, cellPixels.width > 0, cellPixels.height > 0,
              slot.width > 0, slot.height > 0 else { return nil }
        return .init(
            // Match PaneRuntime.resize's minimums so advertised grids and
            // snapshots cannot disagree when a heavily zoomed pane is tiny.
            cols: min(65535, max(4, cellBudget(extent: slot.width, chrome: chrome.width, cell: cellPixels.width / scale))),
            rows: min(65535, max(2, cellBudget(extent: slot.height, chrome: chrome.height, cell: cellPixels.height / scale))),
            cell_width_px: Int(cellPixels.width), cell_height_px: Int(cellPixels.height))
    }

    static func cellBudget(extent: CGFloat, chrome: CGFloat, cell: CGFloat) -> Int {
        guard cell > 0 else { return 1 }
        // A pixel divided by a 3x scale can land infinitesimally below the
        // exact cell boundary. Discard only floating-point roundoff.
        return max(1, Int(floor((extent - chrome) / cell + 1e-9)))
    }

    /// Keep the fractional-cell remainder inside the drawable. Only a full
    /// additional cell needs clamping; trimming to the minimum extent exposes
    /// the host behind the terminal, outside Ghostty's effects.
    static func clampedExtent(_ extent: CGFloat, cells: Int, cellPixels: UInt32,
                              chrome: CGFloat, scale: CGFloat, preserveGrid: Bool = false) -> CGFloat {
        guard cells > 0, cellPixels > 0, scale > 0 else { return extent }
        let minimumPixels = CGFloat(cells) * CGFloat(cellPixels) + (chrome * scale).rounded()
        var minimum = minimumPixels / scale
        // Division by a 3x scale must not lose a pixel when set_size truncates.
        if floor(minimum * scale) < minimumPixels { minimum = minimum.nextUp }
        // A raw v2 pane must not shrink ahead of the server while old-grid
        // output is arriving. Its host still negotiates from viewport bounds.
        // Other modes retain their existing sub-point rounding correction.
        let fitted = preserveGrid || minimum <= extent + 1 ? max(extent, minimum) : extent
        let maximum = (minimumPixels + CGFloat(cellPixels) - 1) / scale
        return min(fitted, maximum)
    }

    /// The smallest extent that yields exactly `cells` after Ghostty's
    /// truncating pixel math.
    static func requiredExtent(cells: Int, cellPixels: UInt32, chrome: CGFloat, scale: CGFloat) -> CGFloat {
        guard cells > 0, cellPixels > 0, scale > 0 else { return 0 }
        let minimumPixels = CGFloat(cells) * CGFloat(cellPixels) + (chrome * scale).rounded()
        var minimum = minimumPixels / scale
        if floor(minimum * scale) < minimumPixels { minimum = minimum.nextUp }
        return minimum
    }

    /// The split ratios use a whole-cell rectangle. Its outer panes still own
    /// the remaining pixels out to the viewport edge; internal dividers stay put.
    static func extendingTrailingEdges(_ frame: CGRect, layout: CGRect, viewport: CGRect) -> CGRect {
        var result = frame
        // A layout larger than the viewport (another client's size) keeps
        // its own extent and is clipped, never shrunk.
        if frame.maxX >= layout.maxX {
            result.size.width = max(frame.width, viewport.maxX - frame.minX)
        }
        if frame.maxY >= layout.maxY {
            result.size.height = max(frame.height, viewport.maxY - frame.minY)
        }
        return result
    }
}

/// One tab's geometry negotiation. Visibility is deliberately absent: a
/// hosted background tab can prepare exactly like the selected tab.
nonisolated struct HerdrTabGeometryState {
    struct Size: Equatable, Sendable {
        let cols: Int
        let rows: Int
        let cellWidth: Int
        let cellHeight: Int
        var panes: [String: HerdrControl.PaneTerminalSize] = [:]
    }

    struct Request: Equatable, Sendable {
        let id = UUID()
        let size: Size
        let claim: Bool
    }

    /// Who sizes this tab on the server, as far as the last layout said.
    enum Ownership: Equatable, Sendable {
        /// Protocol 1 server, or no layout seen yet: behave as the sole client.
        case unknown
        case none
        case mine
        case other(connectionId: UInt64?, kind: String?)
    }

    private(set) var desired: Size?
    private(set) var confirmed: Size?
    private(set) var inFlight: Request?
    private(set) var hasRequested = false
    private(set) var ownership: Ownership = .unknown
    private var claimPending = false

    var isConfirmed: Bool {
        desired != nil && desired == confirmed && inFlight == nil && !claimPending
    }

    /// The user asked for this tab and the request has not gone out yet.
    /// One-shot: `beginRequest` consumes it, so a push re-gates on the next pass.
    var hasPendingClaim: Bool { claimPending }

    /// Whether the legacy protocol may push a size (it cannot store without
    /// claiming). Shared-mode requests carry their own one-shot claim flag.
    var mayClaim: Bool {
        if case .other = ownership { return false }
        return true
    }

    var isOwnedElsewhere: Bool { !mayClaim }

    mutating func update(_ size: Size) {
        desired = size
    }

    mutating func requestClaim() {
        claimPending = true
        invalidate()
    }

    mutating func beginRequest(claim: Bool = false) -> Request? {
        guard let desired, !isConfirmed || claim, inFlight == nil else { return nil }
        // The server applies claim:false sizes from its current owner. Never
        // infer a fresh claim from .mine: that observation may already be stale.
        let initialClaim = !hasRequested && (ownership == .unknown || ownership == .none)
        let request = Request(size: desired, claim: claim || claimPending || initialClaim)
        claimPending = false
        inFlight = request
        hasRequested = true
        return request
    }

    /// Forget what the server confirmed: the next push resends our size.
    /// Used when the user takes a tab back on a single-owner server, where
    /// no ownership signal exists to do it for us.
    mutating func invalidate() {
        confirmed = nil
        inFlight = nil
    }

    /// The server laid the tab out at our desired size on its own (a hand-off
    /// applied the stored size): nothing to send.
    mutating func noteServerApplied(_ size: Size) {
        guard desired == size, inFlight == nil else { return }
        confirmed = size
        hasRequested = true
    }

    /// Returns true when ownership changed. Gaining the tab (or losing it)
    /// invalidates the last confirmation so the next push carries the right
    /// claim flag; a request in flight can no longer confirm anything.
    @discardableResult
    mutating func setOwnership(_ new: Ownership) -> Bool {
        guard ownership != new else { return false }
        let wasOwnedElsewhere = isOwnedElsewhere
        ownership = new
        if isOwnedElsewhere != wasOwnedElsewhere {
            confirmed = nil
            inFlight = nil
        }
        return true
    }

    /// An old stream/tab's completion cannot confirm a new request, even
    /// if its dimensions happen to match. A newer desired size stays pending.
    @discardableResult
    mutating func finish(_ request: Request, succeeded: Bool) -> Bool {
        guard inFlight == request else { return false }
        inFlight = nil
        confirmed = succeeded ? request.size : nil
        return true
    }
}

/// An activation is an edge, never a standing claim on a shared tab. Kept
/// separate from layout negotiation so remote ownership changes cannot
/// manufacture another activation.
nonisolated struct HerdrActivation {
    private(set) var tabID: String?
    private(set) var generation = UUID()
    private(set) var needsClaim = false
    private(set) var pendingPanes: Set<String> = []
    /// Panes the user took back within this activation. The handoff that
    /// answers our claim can arrive after they scrolled, and must not re-arm
    /// a jump they already cancelled.
    private(set) var cancelledPanes: Set<String> = []
    private var needsActivationEdge = true

    @discardableResult
    mutating func select(_ tabID: String?, panes: Set<String>) -> Bool {
        guard tabID != self.tabID || needsActivationEdge else { return false }
        self.tabID = tabID
        generation = UUID()
        needsClaim = tabID != nil
        pendingPanes = tabID == nil ? [] : panes
        cancelledPanes.removeAll()
        // A gateway can be selected before its recovered terminal exists.
        needsActivationEdge = tabID == nil
        return tabID != nil
    }

    mutating func suspend() {
        generation = UUID()
        needsActivationEdge = true
        needsClaim = false
        pendingPanes.removeAll()
        cancelledPanes.removeAll()
    }

    /// Expect these panes to return to live output on a tab that is already
    /// ours: the server hands a tab over on interaction, so a keystroke can
    /// bring a resize with no activation edge. Never claims.
    mutating func expectReturnToLive(tabID: String, panes: Set<String>) {
        if self.tabID != tabID {
            self.tabID = tabID
            generation = UUID()
            needsClaim = false
            pendingPanes = []
            cancelledPanes.removeAll()
        }
        pendingPanes.formUnion(panes.subtracting(cancelledPanes))
    }

    /// The user scrolled or selected in this pane: it keeps the position it
    /// has, for this activation and for any handoff that answers it.
    mutating func cancelPane(_ terminalID: String) {
        guard pendingPanes.contains(terminalID) || tabID != nil else { return }
        pendingPanes.remove(terminalID)
        cancelledPanes.insert(terminalID)
    }

    /// The user typed here: new intent, not the activation they scrolled
    /// away from, so a handoff it earns may arm the jump again.
    mutating func renewAfterInput(_ terminalID: String) {
        cancelledPanes.remove(terminalID)
    }

    mutating func claimed(generation: UUID) {
        guard self.generation == generation else { return }
        needsClaim = false
    }

    mutating func finishPane(_ terminalID: String) {
        pendingPanes.remove(terminalID)
    }
}
