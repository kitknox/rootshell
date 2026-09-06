//
//  TerminalSplitTreeView.swift
//  rootshell
//
//  UIKit-backed renderer for terminal split trees
//

import SwiftUI
import UIKit
import GhosttyKit
import os

struct TerminalSplitTreeView: UIViewRepresentable {
    let tree: SplitTree<SplitPaneView>
    let onResize: (SplitTree<SplitPaneView>.Node, Double) -> Void
    var onMove: ((SplitPaneView, SplitPaneView, PaneDropZone) -> Void)?
    var allowsPaneRearrangement: Bool = true
    /// Whether this tab is the visible one. Only the active tab drives the tmux
    /// client size.
    var isActive: Bool = true
    let focusedPane: SplitPaneView?
    /// Whether this rendered tab is eligible for terminal background effects.
    /// Propagated to terminal leaves so their home-indicator inset follows the
    /// same policy as MainView's shared effect and ocean layout layers.
    var terminalEffectsEnabled: Bool = true
    /// True when the visible focused terminal presents OSC 9;4 progress on the
    /// integrated tab edge instead of as a duplicate straight pane-local bar.
    var routesFocusedProgressToIntegratedEdge: Bool = false

    func makeUIView(context: Context) -> SplitTreeHostingView {
        SplitTreeHostingView()
    }

    func updateUIView(_ uiView: SplitTreeHostingView, context: Context) {
        uiView.dividerColor = UIColor.separator
        uiView.highlightColor = uiView.tintColor ?? UIColor.systemBlue
        uiView.onResize = onResize
        uiView.onMove = onMove
        uiView.allowsPaneRearrangement = allowsPaneRearrangement
        uiView.isActiveTab = isActive
        uiView.terminalEffectsEnabled = terminalEffectsEnabled
        uiView.routesFocusedProgressToIntegratedEdge = routesFocusedProgressToIntegratedEdge
        uiView.update(tree: tree, focusedPane: focusedPane)
    }

    static func dismantleUIView(_ uiView: SplitTreeHostingView, coordinator: ()) {
        uiView.detachAllPanes()
    }
}

// MARK: - Hosting View

final class SplitTreeHostingView: UIView {
    var dividerColor: UIColor = .separator {
        didSet { setNeedsLayout() }
    }

    var highlightColor: UIColor = .systemBlue {
        didSet {
            guard oldValue != highlightColor else { return }
            updateFocusAppearance()
        }
    }

    var minSplitSize: CGFloat = 100
    var onResize: ((SplitTree<SplitPaneView>.Node, Double) -> Void)?
    var onMove: ((SplitPaneView, SplitPaneView, PaneDropZone) -> Void)?
    var allowsPaneRearrangement = true
    private lazy var paneRearrangement = SplitPaneRearrangementController(host: self)

    @discardableResult
    func cancelPaneDrag() -> Bool { paneRearrangement.cancelDrag() }

    override var keyCommands: [UIKeyCommand]? {
        guard paneRearrangement.isDragging else { return super.keyCommands }
        let cancel = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelPaneDragCommand))
        cancel.wantsPriorityOverSystemBehavior = true
        return (super.keyCommands ?? []) + [cancel]
    }

    @objc private func cancelPaneDragCommand(_ command: UIKeyCommand) { cancelPaneDrag() }

    /// Whether this hosting view is rendering the currently-visible tab. Only the
    /// active tab drives the tmux client size (background tabs share the same
    /// gateway and bounds, so letting them push too would be redundant churn).
    var isActiveTab: Bool = false {
        didSet {
            guard isActiveTab != oldValue else { return }
            setNeedsLayout()
            refreshProgressBarRouting()
        }
    }
    var terminalEffectsEnabled: Bool = true {
        didSet {
            guard terminalEffectsEnabled != oldValue else { return }
            updateTerminalEffectsEligibility()
        }
    }
    var routesFocusedProgressToIntegratedEdge: Bool = false {
        didSet {
            guard routesFocusedProgressToIntegratedEdge != oldValue else { return }
            refreshProgressBarRouting()
        }
    }
    /// Visible divider thickness in points. Static so the tmux reconcile
    /// (TmuxController) can use the same value when deriving split ratios.
    static let dividerVisibleThickness: CGFloat = 2
    private let dividerTouchThickness: CGFloat = 24
    private var tree: SplitTree<SplitPaneView>?
    private var focusedPane: SplitPaneView?
    private var needsFocusRestoration = false
    private var focusRestorationGeneration: UInt64 = 0

    private var dividerViews: [SplitDividerHandleView] = []
    private var dividerReuseIndex: Int = 0

    private var borderEligibility: [ObjectIdentifier: Bool] = [:]

    // Map of pane → its attached container: a TerminalScrollView wrapper for
    // terminals, the pane view itself for non-terminal panes.
    private var attachedContainers: [ObjectIdentifier: UIView] = [:]

    // Observer for layout invalidation notifications
    private var layoutInvalidationObserver: NSObjectProtocol?
    private var overlayPreservationEndedObserver: NSObjectProtocol?

    /// Re-pushes the tmux window size once a keyboard show/hide animation
    /// settles. `pushTmuxClientSizeIfNeeded` is gated off during the
    /// animation (interpolated bounds are not real sizes), so this task is
    /// what sends the steady-state size — mirroring TerminalView's
    /// keyboardAnimationTask for the single-pane path.
    private var keyboardAnimationTask: Task<Void, Never>?

    /// Frosted-glass cover for the dead margin when a smaller foreign tmux client
    /// has shrunk this window below the size we requested. nil until first needed;
    /// non-interactive; masked to `bounds − contentRect`. See `updateDeadMarginOverlay`.
    private var deadMarginOverlay: UIVisualEffectView?
    /// The content rect the overlay mask currently reflects, so steady-state
    /// layout passes skip redundant mask rebuilds.
    private var deadMarginContentRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        // Listen for layout invalidation notifications (tab bar toggle, titlebar tabs, AI sidebar)
        layoutInvalidationObserver = NotificationCenter.default.addObserver(
            forName: .terminalLayoutInvalidation,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.forceLayoutUpdate()
        }

        keyboardAnimationTask = Task { @MainActor [weak self] in
            for await animating in KeyboardTracker.shared.keyboardAnimationDidChangeStream() {
                guard let self else { break }
                if !animating {
                    self.pushTmuxClientSizeIfNeeded()
                }
            }
        }

        overlayPreservationEndedObserver = NotificationCenter.default.addObserver(
            forName: .overlayKeyboardPreservationEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.pushTmuxClientSizeIfNeeded()
                }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = layoutInvalidationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = overlayPreservationEndedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        keyboardAnimationTask?.cancel()
    }

    func update(tree: SplitTree<SplitPaneView>, focusedPane: SplitPaneView?) {
        paneRearrangement.update(tree: tree, enabled: isActiveTab && allowsPaneRearrangement && onMove != nil)
        // SwiftUI calls this on every MainView body evaluation. Only a real
        // tree or focus change may relayout every attached pane.
        let treeChanged = self.tree?.root != tree.root || self.tree?.zoomed != tree.zoomed
        let focusChanged = self.focusedPane !== focusedPane
        self.tree = tree
        self.focusedPane = focusedPane
        guard treeChanged || focusChanged else { return }
        needsFocusRestoration = true
        focusRestorationGeneration &+= 1
        updateTerminalEffectsEligibility()
        recomputeBorderEligibility()
        refreshProgressBarRouting()
        setNeedsLayout()
        updateFocusAppearance()
    }

    private func updateTerminalEffectsEligibility() {
        guard let tree else { return }
        for terminal in tree.terminalLeaves {
            terminal.terminalEffectsEnabled = terminalEffectsEnabled
        }
    }

    /// Teardown hook for `TerminalSplitTreeView.dismantleUIView`. The
    /// representable's `.id()` flips on every structural change, so SwiftUI
    /// routinely replaces this host — drop the bookkeeping here or the dying host
    /// keeps yanking panes back out of its replacement on later layout passes.
    /// Only detaches panes still parented here: SwiftUI does not guarantee that
    /// dismantle runs before the new host adopts them, and a pane checked out for
    /// full screen lives under the takeover container.
    func detachAllPanes() {
        needsFocusRestoration = false
        focusRestorationGeneration &+= 1
        paneRearrangement.detach()
        for (_, container) in attachedContainers where container.superview === self {
            (container as? Ghostty.TerminalScrollView)?
                .setProgressBarPresentationSuppressed(false)
        }
        for (_, container) in attachedContainers where container.superview === self {
            container.removeFromSuperview()
        }
        attachedContainers.removeAll()
        borderEligibility.removeAll()
        tree = nil
        focusedPane = nil
    }

    /// Force all terminal views to recalculate their size.
    /// Called when UI layout changes (tab bar toggle, titlebar tabs, AI sidebar) that may not
    /// trigger normal UIKit layout invalidation through the SwiftUI bridge.
    private func forceLayoutUpdate() {
        // Force layout recalculation on self
        setNeedsLayout()
        layoutIfNeeded()

        // Invalidate cached sizes and force layout on all attached panes
        for (_, container) in attachedContainers {
            (container as? Ghostty.TerminalScrollView)?.terminalView.invalidateCachedSize()
            container.setNeedsLayout()
            container.layoutIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dividerReuseIndex = 0

        guard let tree else {
            cleanupTerminalViews(keeping: [])
            hideUnusedDividers(from: dividerReuseIndex)
            updateDeadMarginOverlay(contentRect: nil)
            return
        }

        guard let rootNode = tree.zoomed ?? tree.root else {
            cleanupTerminalViews(keeping: [])
            hideUnusedDividers(from: dividerReuseIndex)
            updateDeadMarginOverlay(contentRect: nil)
            return
        }

        // When a smaller foreign tmux client has shrunk the window below the size
        // we requested, `contentRect` is the real (top-left) content extent and
        // the rest is dead margin. Constrain a MULTI-pane (non-zoomed) layout to
        // it so dividers/panes stay aligned and the dead region collapses to one
        // clean L-shape; a single rendered pane (sole or zoomed) keeps full
        // `bounds` (its content auto-renders top-left, and shrinking its frame
        // would change the size its `updatePTYSize` pushes and break reclaim).
        let contentRect = tmuxDeadMargin()
        let renderingSplit: Bool = {
            if case .split = rootNode { return tree.zoomed == nil }
            return false
        }()
        let layoutRect = (renderingSplit ? contentRect : nil) ?? bounds

        var usedTerminals = Set<ObjectIdentifier>()
        layout(node: rootNode, in: layoutRect, isRoot: rootNode == tree.root, usedTerminals: &usedTerminals)
        cleanupTerminalViews(keeping: usedTerminals)
        hideUnusedDividers(from: dividerReuseIndex)
        // Push from full `bounds` (inside this call), unaffected by `layoutRect`,
        // so tmux reclaims our full size when the foreign client detaches.
        pushTmuxClientSizeIfNeeded()
        // Frost the dead margin (single- AND multi-pane) over `bounds − contentRect`.
        updateDeadMarginOverlay(contentRect: contentRect)
        // Overlay chrome follows actual pane frames, including tmux's dead margin.
        paneRearrangement.update(tree: tree, enabled: isActiveTab && allowsPaneRearrangement && onMove != nil)
        paneRearrangement.layout()
        restoreFocusAfterLayoutIfNeeded()
    }

    /// A structural edit replaces this hosting view. Focus acquired by the
    /// drop handler (or didMoveToWindow during attachment) can be resigned as
    /// UIKit finishes removing the old hierarchy. Reassert it after layout,
    /// from the surviving host, without sending another tmux select command.
    private func restoreFocusAfterLayoutIfNeeded() {
        guard needsFocusRestoration else { return }
        needsFocusRestoration = false
        guard isActiveTab, let pane = focusedPane, pane.isLogicallyFocused else { return }
        let generation = focusRestorationGeneration
        DispatchQueue.main.async { [weak self, weak pane] in
            guard let self, let pane,
                  self.focusRestorationGeneration == generation,
                  self.isActiveTab, self.window?.isKeyWindow == true,
                  self.focusedPane === pane, pane.isLogicallyFocused,
                  !pane.isDetachedForFullScreen,
                  pane.enclosingSplitHost === self,
                  !pane.isFirstResponder else { return }
            _ = pane.focusDidChange(true)
        }
    }

    /// Drive a MULTI-pane tmux window's size from this container's actual bounds.
    /// No single surface spans a split window, so only the layout container knows
    /// the window's size; we measure it ONCE here (not by summing panes, which
    /// rounds per-pane and oscillates) from the container's CURRENT bounds and
    /// push it as a PER-WINDOW size (`refresh-client -C @win:WxH`, via the
    /// controller), which overrides the client-global size so each window keeps
    /// its own geometry.
    ///
    /// Single-pane windows are NOT pushed here: the pane IS the window, and its
    /// own `updatePTYSize` pushes the window size from the pane's post-resize
    /// grid. Reading `pane.surfaceSize` here instead would race the child layout
    /// — on a bounds-only change (rotation, sidebar/tab-bar) the just-assigned
    /// frame has not been laid out yet, so the grid is stale.
    ///
    /// Guarded to the active tab; the controller dedups so this can fire on every
    /// layout pass without a command storm.
    private func pushTmuxClientSizeIfNeeded() {
        // Interpolated bounds during a keyboard show/hide are not real sizes:
        // pushing them sends several stale refresh-client -C sizes per bounce,
        // each of which SIGWINCH-storms the window's apps mid-output. Mirrors
        // TerminalView.sizeDidChange's gate; keyboardAnimationTask re-pushes
        // the steady-state size once the animation ends. Gated here (not at
        // the layoutSubviews call site) so every caller is covered while the
        // dead-margin overlay update keeps running during the animation.
        guard !KeyboardTracker.shared.isKeyboardAnimating else { return }
        // Same rationale as TerminalSurfaceController's overlay gate: the
        // container safe-area shuffle during an overlay round trip wobbles
        // bounds by the home-indicator inset. Window-scoped so another
        // window's overlay never stalls this one. The latch-release observer
        // re-pushes the settled size (deduped by the controller).
        guard !KeyboardTracker.shared.isPreservingKeyboardForOverlay(in: window) else { return }
        guard isActiveTab, let tree else { return }
        guard tree.count >= 2,
              let pane = tree.terminalLeaves.first(where: { $0.isTmuxPane }),
              let binding = pane.tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface),
              let cells = tmuxWindowCells()
        else { return }
        // Pin THIS window's size with its own per-window entry, regardless of any
        // other window's font or size.
        controller.pushWindowSize(windowId: binding.windowId, cols: cells.cols, rows: cells.rows)
        // Keep the GLOBAL client size accurate as a FALLBACK for windows with no
        // per-window entry yet (newly created, or just-reattached before re-visit),
        // so they don't revert to a stale (narrow) size. Only a BASE-font window
        // may set it — its grid IS the base viewport; a font-zoomed window's grid
        // would mis-size base windows that fall back to it.
        if controller.overrideFontSize(forWindowId: binding.windowId) == nil {
            controller.pushGlobalClientSize(cols: cells.cols, rows: cells.rows)
        }
    }

    /// The whole-window tmux client size in cells, measured from THIS container's
    /// live bounds and the panes' invariant cell pixel size. This is the single
    /// source of truth for tmux window sizing — both `pushTmuxClientSizeIfNeeded`
    /// and the divider commit use it. Reading the container bounds (not the
    /// divider's stored geometry or the panes' grids, which lag a window resize)
    /// is what makes it reliable. Returns nil when there is no tmux pane or the
    /// geometry isn't ready.
    private func tmuxWindowCells() -> (cols: UInt16, rows: UInt16)? {
        guard let tree,
              let rootNode = tree.zoomed ?? tree.root,
              let pane = tree.terminalLeaves.first(where: { $0.isTmuxPane }),
              let size = pane.surfaceSize,
              size.cell_width_px > 0, size.cell_height_px > 0,
              bounds.width > 0, bounds.height > 0
        else { return nil }
        // Use the PANE's scale, not this container's contentScaleFactor: a
        // non-drawing container view reports scale 1, but `cell_width_px` was
        // measured at the pane's render scale (2 on Retina). Mixing them computes
        // half the real window size — tmux then lays the window out at half width
        // and the content renders tiny. The pane scale matches cell_*_px.
        let scale = pane.contentScaleFactor > 0 ? pane.contentScaleFactor : pane.traitCollection.displayScale
        guard scale > 0 else { return nil }
        let cellW = CGFloat(size.cell_width_px) / scale
        let cellH = CGFloat(size.cell_height_px) / scale
        // Budget for the layout chrome: every pane renders its grid inset by the
        // window padding on each edge, and every native divider replaces a 1-cell
        // tmux separator. Sizing from raw bounds assumes one borderless pane, so
        // a split's panes collectively needed more space than the container has
        // and the pane above a divider clipped the bottom of its last row.
        // ROOTSHELL-TMUX (id=tmux-split-chrome-budget)
        let chrome = tmuxChrome(node: rootNode, cellW: cellW, cellH: cellH)
        let cols = max(1, Int(((bounds.width - chrome.h) / cellW).rounded(.down)))
        let rows = max(1, Int(((bounds.height - chrome.v) / cellH).rounded(.down)))
        return (cols: UInt16(min(cols, Int(UInt16.max))), rows: UInt16(min(rows, Int(UInt16.max))))
    }

    /// The non-grid space (points) a rendered tmux split tree needs beyond
    /// `cells × cellSize` along each axis: per-pane window-padding insets plus
    /// native dividers, credited for the 1-cell tmux separator each divider
    /// replaces. The window's required extent along an axis is
    /// `windowCells × cell + chrome`, so the cell budget for a given extent is
    /// `(extent − chrome) / cell`. Can be negative on an axis where the divider
    /// credit exceeds the padding (a 2pt divider replaces a full cell row).
    /// ROOTSHELL-TMUX (id=tmux-split-chrome-budget)
    private func tmuxChrome(
        node: SplitTree<SplitPaneView>.Node,
        cellW: CGFloat,
        cellH: CGFloat
    ) -> (h: CGFloat, v: CGFloat) {
        let padX = CGFloat(PaddingManager.shared.effectivePaddingX)
        let padY = CGFloat(PaddingManager.shared.effectivePaddingY)
        func walk(_ node: SplitTree<SplitPaneView>.Node) -> (h: CGFloat, v: CGFloat) {
            switch node {
            case .leaf:
                return (h: padX * 2, v: padY * 2)
            case .split(let split):
                let left = walk(split.left)
                let right = walk(split.right)
                switch split.direction {
                case .horizontal:
                    return (h: left.h + right.h + Self.dividerVisibleThickness - cellW,
                            v: max(left.v, right.v))
                case .vertical:
                    return (h: max(left.h, right.h),
                            v: left.v + right.v + Self.dividerVisibleThickness - cellH)
                }
            }
        }
        return walk(node)
    }

    /// The first tmux pane in this container, its window id, and its live
    /// controller, if any. Both the dead-margin geometry and the divider math
    /// resolve through here, matching the lookup `pushTmuxClientSizeIfNeeded` uses.
    private func tmuxPaneAndController() -> (pane: Ghostty.TerminalView, windowId: Int, controller: TmuxController)? {
        guard let tree,
              let pane = tree.terminalLeaves.first(where: { $0.isTmuxPane }),
              let binding = pane.tmuxPaneBinding,
              let controller = TmuxController.controller(forOwnerSurface: binding.parentSurface)
        else { return nil }
        return (pane, binding.windowId, controller)
    }

    /// The top-left tmux content rect (in this view's points) when a smaller
    /// foreign client has shrunk the window below the size we requested — i.e.
    /// there is a dead margin to frost. nil when content fills the container.
    /// Used both to constrain a multi-pane layout and to mask the glass overlay.
    private func tmuxDeadMargin() -> CGRect? {
        guard let (pane, windowId, controller) = tmuxPaneAndController(),
              controller.isWindowForeignConstrained(windowId: windowId),
              let reported = controller.reportedWindowCells(windowId: windowId),
              let tree,
              let rootNode = tree.zoomed ?? tree.root,
              let size = pane.surfaceSize,
              size.cell_width_px > 0, size.cell_height_px > 0,
              bounds.width > 1, bounds.height > 1
        else { return nil }

        // Use the PANE's render scale (the container reports 1), matching the
        // scale `cell_*_px` was measured at.
        let scale = pane.contentScaleFactor > 0 ? pane.contentScaleFactor : pane.traitCollection.displayScale
        guard scale > 0 else { return nil }
        let cellW = CGFloat(size.cell_width_px) / scale
        let cellH = CGFloat(size.cell_height_px) / scale
        // The grid is pinned top-left with a padding inset on each edge (balance
        // disabled). The rendered extent of `reported` cells is cells + chrome
        // (per-pane padding insets + native dividers), the inverse of the budget
        // `tmuxWindowCells` uses. ROOTSHELL-TMUX (id=tmux-split-chrome-budget)
        let chrome = tmuxChrome(node: rootNode, cellW: cellW, cellH: cellH)
        let contentW = min(bounds.width, CGFloat(reported.cols) * cellW + chrome.h)
        let contentH = min(bounds.height, CGFloat(reported.rows) * cellH + chrome.v)
        // Only annotate when a real pixel margin remains after rounding.
        guard contentW > 1, contentH > 1,
              bounds.width - contentW > 1 || bounds.height - contentH > 1
        else { return nil }
        return CGRect(x: bounds.minX, y: bounds.minY, width: contentW, height: contentH)
    }

    /// Window cell count for divider-resize math. While a foreign client
    /// constrains the window, a drag acts on the REPORTED (smaller) window, not
    /// our full-bounds capacity — otherwise it targets a larger window and tmux
    /// clamps the result. Falls back to the bounds capacity normally.
    private func effectiveTmuxWindowCells() -> (cols: UInt16, rows: UInt16)? {
        if let (_, windowId, controller) = tmuxPaneAndController(),
           controller.isWindowForeignConstrained(windowId: windowId),
           let reported = controller.reportedWindowCells(windowId: windowId) {
            return reported
        }
        return tmuxWindowCells()
    }

    /// Show / update / hide the frosted-glass cover over the dead margin
    /// (`bounds − contentRect`). Called at the end of every layout pass.
    /// Idempotent: rebuilds the even-odd mask only when the geometry changes,
    /// fades in on first appearance, and fades out + removes when the constraint
    /// lifts (tmux reclaimed our full size, `contentRect == nil`).
    private func updateDeadMarginOverlay(contentRect: CGRect?) {
        guard let contentRect else {
            if let overlay = deadMarginOverlay {
                deadMarginOverlay = nil
                deadMarginContentRect = nil
                UIView.animate(withDuration: 0.3, animations: {
                    overlay.alpha = 0
                }, completion: { _ in
                    overlay.removeFromSuperview()
                })
            }
            return
        }

        let overlay: UIVisualEffectView
        let isNew: Bool
        if let existing = deadMarginOverlay {
            overlay = existing
            isNew = false
        } else {
            overlay = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            overlay.isUserInteractionEnabled = false
            overlay.alpha = 0
            addSubview(overlay)
            deadMarginOverlay = overlay
            isNew = true
        }

        // Keep the glass above the panes; dividers call `bringSubviewToFront`
        // during the layout pass, so re-front it each time. It is non-interactive
        // and masked to the margin only, so dividers/panes inside `contentRect`
        // still show through and remain touchable.
        bringSubviewToFront(overlay)

        if isNew || overlay.frame != bounds || deadMarginContentRect != contentRect {
            deadMarginContentRect = contentRect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.frame = bounds
            // Even-odd fill: the margin (inside `bounds`, outside `contentRect`)
            // is enclosed by 1 subpath → shown; `contentRect` by 2 → cut out.
            let outer = CGRect(origin: .zero, size: bounds.size)
            let inner = contentRect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let path = UIBezierPath(rect: outer)
            path.append(UIBezierPath(rect: inner))
            path.usesEvenOddFillRule = true
            let mask = (overlay.layer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.fillRule = .evenOdd
            mask.frame = outer
            mask.path = path.cgPath
            overlay.layer.mask = mask
            CATransaction.commit()
        }

        if isNew {
            UIView.animate(withDuration: 0.15) { overlay.alpha = 1 }
        }
    }

    /// Commit a divider drag to tmux. Runs in the hosting view so it uses the
    /// reliable container size (`tmuxWindowCells`), NOT the divider's stored
    /// `parentBounds` or the panes' `surfaceSize` (both lag a window resize and
    /// produced a ~2x-too-large target that tmux clamped to the edge — the
    /// "jump"). Sets the LEFT/TOP pane to `ratio` of the window cells via a
    /// single-axis `resize-pane`; tmux moves the divider and the reconcile +
    /// wake reflow the panes. For a 2-pane (root) split the window IS the split
    /// region, so this is exact.
    fileprivate func commitDividerToTmux(node: SplitTree<SplitPaneView>.Node, ratio: Double) {
        guard case .split(let split) = node else { return }
        guard let leftView = split.left.leftmostLeaf().asTerminal,
              leftView.isTmuxPane, let cells = effectiveTmuxWindowCells() else { return }
        let horizontal = split.direction == .horizontal
        let axisCells = Int(horizontal ? cells.cols : cells.rows)
        guard axisCells > 1 else { return }
        let target = min(max(Int((Double(axisCells) * ratio).rounded()), 1), axisCells - 1)
        leftView.requestTmuxResizePane(horizontal: horizontal, cells: target)
    }

    private func layout(
        node: SplitTree<SplitPaneView>.Node,
        in bounds: CGRect,
        isRoot: Bool,
        usedTerminals: inout Set<ObjectIdentifier>
    ) {
        switch node {
        case .leaf(let pane):
            let identifier = ObjectIdentifier(pane)
            usedTerminals.insert(identifier)
            borderEligibility[identifier] = !isRoot

            // Pane checked out for a full-screen takeover: keep its container
            // bookkeeping (so exit re-attaches via normal layout) but don't
            // touch its frame or attachment.
            guard !pane.isDetachedForFullScreen else { return }

            attach(pane, frame: bounds.integral)
            applyFocusAppearance(to: pane, showBorder: !isRoot)

        case .split(let split):
            let ratio = CGFloat(split.ratio).clamped(to: 0...1)
            let (leftBounds, rightBounds, dividerFrame) = frames(
                for: bounds,
                ratio: ratio,
                direction: split.direction
            )

            layout(node: split.left, in: leftBounds, isRoot: false, usedTerminals: &usedTerminals)
            layout(node: split.right, in: rightBounds, isRoot: false, usedTerminals: &usedTerminals)
            addDivider(for: node, direction: split.direction, visibleFrame: dividerFrame, parentBounds: bounds)
        }
    }

    /// Read-only frame the given pane occupies (or would occupy) in the
    /// current layout, in this view's coordinates. Used by the full-screen
    /// exit animation to target the pane's slot without forcing a re-attach
    /// mid-flight. nil when the pane isn't in the rendered tree (e.g.
    /// another pane is zoomed).
    func slotFrame(for pane: SplitPaneView) -> CGRect? {
        guard let tree, let rootNode = tree.zoomed ?? tree.root else { return nil }
        let contentRect = tmuxDeadMargin()
        let renderingSplit: Bool = {
            if case .split = rootNode { return tree.zoomed == nil }
            return false
        }()
        let layoutRect = (renderingSplit ? contentRect : nil) ?? bounds
        return slotFrame(for: pane, node: rootNode, in: layoutRect)
    }

    private func slotFrame(for pane: SplitPaneView, node: SplitTree<SplitPaneView>.Node, in bounds: CGRect) -> CGRect? {
        switch node {
        case .leaf(let leaf):
            return leaf === pane ? bounds.integral : nil
        case .split(let split):
            let ratio = CGFloat(split.ratio).clamped(to: 0...1)
            let (leftBounds, rightBounds, _) = frames(for: bounds, ratio: ratio, direction: split.direction)
            return slotFrame(for: pane, node: split.left, in: leftBounds)
                ?? slotFrame(for: pane, node: split.right, in: rightBounds)
        }
    }

    private func attach(_ pane: SplitPaneView, frame: CGRect) {
        let identifier = ObjectIdentifier(pane)

        // Get or create the attached container: terminals get a scroll view
        // wrapper; other panes attach directly.
        let container: UIView
        if let existing = attachedContainers[identifier] {
            container = existing
        } else if let terminalView = pane.asTerminal {
            // Reuse the terminal's live wrapper when it already has one — another
            // hosting view's, or this pane's from before an `.id()` rebuild. A
            // second wrapper reparents the terminal and activates Auto Layout
            // constraints against a different documentView, leaving the first one
            // holding cross-hierarchy constraints.
            if let existingWrapper = terminalView.enclosingTerminalScrollView {
                container = existingWrapper
            } else {
                Ghostty.logger.info("SplitTreeHostingView: Creating TerminalScrollView wrapper for terminal \(terminalView.uuid)")
                container = Ghostty.TerminalScrollView(terminalView: terminalView)
            }
            attachedContainers[identifier] = container
        } else {
            container = pane
            attachedContainers[identifier] = container
        }

        // Attach the container (for terminals, it contains the terminal view)
        if container.superview !== self {
            container.removeFromSuperview()

            // A non-terminal pane may carry a live child view controller. Give
            // it the destination parent before inserting its view hierarchy:
            // UIKit validates containment inside insertSubview, so repairing
            // the parent later from didMoveToWindow is already too late.
            guard pane.prepareForAttachment(to: nearestViewController()) else {
                setNeedsLayout()
                return
            }
            insertSubview(container, at: 0)
            if pane === focusedPane { needsFocusRestoration = true }
        }

        container.frame = frame
        container.setNeedsLayout()
        updateProgressBarRouting(for: identifier, container: container)

        // Mark a tmux pane as container-laid-out now that it has its real frame.
        // sizeDidChange ignores a tmux pane's size until this is set, so the
        // 800x600 placeholder sizeDidChange that fired during insertSubview
        // (didMoveToWindow, above, before this real frame) is dropped instead of
        // sending a tiny resize-pane that reflows scrollback narrow. The pane's
        // own deferred layout (from setNeedsLayout) then fires sizeDidChange at
        // the real frame with this flag set. ROOTSHELL-TMUX
        // (id=tmux-pane-defer-size-until-laid-out)
        if let terminalView = pane.asTerminal, terminalView.isTmuxPane {
            terminalView.tmuxPaneContainerLaidOut = true
        }
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return window?.rootViewController
    }

    private func refreshProgressBarRouting() {
        for (identifier, container) in attachedContainers {
            updateProgressBarRouting(for: identifier, container: container)
        }
    }

    private func updateProgressBarRouting(for identifier: ObjectIdentifier, container: UIView) {
        guard let scrollView = container as? Ghostty.TerminalScrollView else { return }
        let focusedID = focusedPane.map(ObjectIdentifier.init)
        let suppressesLocalBar = routesFocusedProgressToIntegratedEdge
            && isActiveTab
            && focusedID == identifier
        scrollView.setProgressBarPresentationSuppressed(suppressesLocalBar)
    }

    private func frames(
        for bounds: CGRect,
        ratio: CGFloat,
        direction: SplitTree<SplitPaneView>.Direction
    ) -> (CGRect, CGRect, CGRect) {
        switch direction {
        case .horizontal:
            let availableWidth = max(bounds.width - Self.dividerVisibleThickness, 0)
            let leftWidth = (availableWidth * ratio).rounded(.towardZero)
            let rightWidth = availableWidth - leftWidth

            let left = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: leftWidth,
                height: bounds.height
            )

            let divider = CGRect(
                x: left.maxX,
                y: bounds.minY,
                width: Self.dividerVisibleThickness,
                height: bounds.height
            )

            let right = CGRect(
                x: divider.maxX,
                y: bounds.minY,
                width: rightWidth,
                height: bounds.height
            )

            return (left.integral, right.integral, divider.integral)

        case .vertical:
            let availableHeight = max(bounds.height - Self.dividerVisibleThickness, 0)
            let topHeight = (availableHeight * ratio).rounded(.towardZero)
            let bottomHeight = availableHeight - topHeight

            let top = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: topHeight
            )

            let divider = CGRect(
                x: bounds.minX,
                y: top.maxY,
                width: bounds.width,
                height: Self.dividerVisibleThickness
            )

            let bottom = CGRect(
                x: bounds.minX,
                y: divider.maxY,
                width: bounds.width,
                height: bottomHeight
            )

            return (top.integral, bottom.integral, divider.integral)
        }
    }

    private func addDivider(
        for node: SplitTree<SplitPaneView>.Node,
        direction: SplitTree<SplitPaneView>.Direction,
        visibleFrame: CGRect,
        parentBounds: CGRect
    ) {
        let dividerView = dequeueDivider()
        dividerView.configure(
            with: node,
            direction: direction,
            visibleFrame: visibleFrame,
            parentBounds: parentBounds,
            visibleThickness: Self.dividerVisibleThickness,
            touchThickness: dividerTouchThickness,
            minSplitSize: minSplitSize,
            color: dividerColor
        )

        dividerView.onResize = { [weak self] node, ratio in
            self?.onResize?(node, ratio)
        }
        dividerView.onResizeEnd = { [weak self] node, ratio in
            self?.commitDividerToTmux(node: node, ratio: ratio)
        }
        dividerView.onTouchTap = { [weak self] in
            self?.paneRearrangement.revealTouchHandles()
        }

        bringSubviewToFront(dividerView)
    }

    private func dequeueDivider() -> SplitDividerHandleView {
        if dividerReuseIndex < dividerViews.count {
            let view = dividerViews[dividerReuseIndex]
            dividerReuseIndex += 1
            view.isHidden = false
            return view
        }

        let handle = SplitDividerHandleView()
        dividerViews.append(handle)
        dividerReuseIndex += 1
        addSubview(handle)
        return handle
    }

    private func hideUnusedDividers(from index: Int) {
        guard index < dividerViews.count else { return }
        for idx in index..<dividerViews.count {
            dividerViews[idx].isHidden = true
        }
    }

    private func cleanupTerminalViews(keeping identifiers: Set<ObjectIdentifier>) {
        // Clean up attached containers for panes that are no longer in use
        var containersToRemove: [ObjectIdentifier] = []
        for (identifier, container) in attachedContainers {
            if !identifiers.contains(identifier) {
                // Pane left the tree while checked out for full screen (close
                // or transfer mid-takeover): the full-screen controller owns
                // its teardown; drop the bookkeeping without yanking the pane
                // out of the takeover container.
                if let pane = container as? SplitPaneView, pane.isDetachedForFullScreen {
                    borderEligibility.removeValue(forKey: identifier)
                    containersToRemove.append(identifier)
                    continue
                }
                Ghostty.logger.debug("SplitTreeHostingView: Removing container for unused pane")
                (container as? Ghostty.TerminalScrollView)?
                    .setProgressBarPresentationSuppressed(false)
                container.removeFromSuperview()
                borderEligibility.removeValue(forKey: identifier)
                containersToRemove.append(identifier)
            }
        }

        // Remove from dictionary
        for identifier in containersToRemove {
            attachedContainers.removeValue(forKey: identifier)
        }
    }

    private func recomputeBorderEligibility() {
        guard let tree else {
            borderEligibility.removeAll()
            return
        }
        let rootNode = tree.zoomed ?? tree.root
        guard let rootNode else {
            borderEligibility.removeAll()
            return
        }

        var newEligibility: [ObjectIdentifier: Bool] = [:]
        func walk(_ node: SplitTree<SplitPaneView>.Node, isRoot: Bool) {
            switch node {
            case .leaf(let view):
                newEligibility[ObjectIdentifier(view)] = !isRoot
            case .split(let split):
                walk(split.left, isRoot: false)
                walk(split.right, isRoot: false)
            }
        }
        walk(rootNode, isRoot: rootNode == tree.root)
        borderEligibility = newEligibility
    }

    private func applyFocusAppearance(to pane: SplitPaneView, showBorder: Bool) {
        let identifier = ObjectIdentifier(pane)
        let isFocused = pane === focusedPane

        // Apply border to the attached container instead of the pane directly
        guard let container = attachedContainers[identifier] else { return }

        // Checked out for full screen: never paint a focus border around the
        // window-level takeover (for non-terminal panes the container IS the
        // pane); exit re-applies through normal layout.
        if pane.isDetachedForFullScreen {
            container.layer.borderWidth = 0
            container.layer.borderColor = UIColor.clear.cgColor
            return
        }

        let style = SettingsStore.shared.value(Settings.Window.splitFocusBorderStyle)

        if showBorder && isFocused && style != .none {
            container.layer.borderWidth = style.borderWidth
            container.layer.borderColor = resolvedBorderColor().withAlphaComponent(style.opacity).cgColor
        } else {
            container.layer.borderWidth = 0
            container.layer.borderColor = UIColor.clear.cgColor
        }
    }

    private func resolvedBorderColor() -> UIColor {
        let store = SettingsStore.shared
        switch store.value(Settings.Window.splitFocusBorderColor) {
        case .accent:
            return highlightColor
        case .gray:
            return .systemGray
        case .custom:
            // Unset hex falls back to the accent color, matching pre-store behavior.
            if store.isUserSet(Settings.Window.splitFocusBorderCustomColor.name),
               let color = UIColor(hex: store.value(Settings.Window.splitFocusBorderCustomColor)) {
                return color
            }
            return highlightColor
        }
    }

    private func updateFocusAppearance() {
        guard let tree else { return }
        for view in tree {
            let identifier = ObjectIdentifier(view)
            let showBorder = borderEligibility[identifier] ?? false
            applyFocusAppearance(to: view, showBorder: showBorder)
        }
    }
}

// MARK: - Divider Handle

private final class SplitDividerHandleView: UIView {
    var onTouchTap: (() -> Void)?
    var onResize: ((SplitTree<SplitPaneView>.Node, Double) -> Void)?
    /// Fired once when the drag finishes (commit point), so a tmux split can push
    /// the final boundary to tmux.
    var onResizeEnd: ((SplitTree<SplitPaneView>.Node, Double) -> Void)?

    private var node: SplitTree<SplitPaneView>.Node?
    private var direction: SplitTree<SplitPaneView>.Direction = .horizontal
    private var parentBounds: CGRect = .zero
    private var minSplitSize: CGFloat = 100
    private var visibleThickness: CGFloat = 2

    private let visibleLine = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true

        visibleLine.isUserInteractionEnabled = false
        addSubview(visibleLine)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        pan.require(toFail: doubleTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTouchTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.require(toFail: doubleTap)
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with node: SplitTree<SplitPaneView>.Node,
        direction: SplitTree<SplitPaneView>.Direction,
        visibleFrame: CGRect,
        parentBounds: CGRect,
        visibleThickness: CGFloat,
        touchThickness: CGFloat,
        minSplitSize: CGFloat,
        color: UIColor
    ) {
        self.node = node
        self.direction = direction
        self.parentBounds = parentBounds
        self.minSplitSize = minSplitSize
        self.visibleThickness = visibleThickness

        let handleFrame: CGRect
        switch direction {
        case .horizontal:
            let width = max(touchThickness, visibleThickness)
            let originX = visibleFrame.midX - width / 2
            handleFrame = CGRect(
                x: originX,
                y: parentBounds.minY,
                width: width,
                height: parentBounds.height
            )

        case .vertical:
            let height = max(touchThickness, visibleThickness)
            let originY = visibleFrame.midY - height / 2
            handleFrame = CGRect(
                x: parentBounds.minX,
                y: originY,
                width: parentBounds.width,
                height: height
            )
        }

        frame = handleFrame.integral
        updateVisibleLine(color: color)
        isHidden = false
    }

    private func updateVisibleLine(color: UIColor) {
        visibleLine.backgroundColor = color
        switch direction {
        case .horizontal:
            visibleLine.frame = CGRect(
                x: (bounds.width - visibleThickness) / 2,
                y: 0,
                width: visibleThickness,
                height: bounds.height
            )

        case .vertical:
            visibleLine.frame = CGRect(
                x: 0,
                y: (bounds.height - visibleThickness) / 2,
                width: bounds.width,
                height: visibleThickness
            )
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let node else { return }
        guard let superview = superview else { return }

        let location = recognizer.location(in: superview)
        let ratio = ratio(for: location)
        onResize?(node, ratio)

        switch recognizer.state {
        case .ended, .cancelled, .failed:
            onResizeEnd?(node, ratio)
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let node else { return }
        NotificationCenter.default.post(name: .equalizeSplits, object: node.leftmostLeaf())
    }

    @objc private func handleTouchTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { onTouchTap?() }
    }

    private func ratio(for point: CGPoint) -> Double {
        switch direction {
        case .horizontal:
            return ratio(
                value: point.x - parentBounds.minX,
                total: parentBounds.width
            )
        case .vertical:
            return ratio(
                value: point.y - parentBounds.minY,
                total: parentBounds.height
            )
        }
    }

    private func ratio(value: CGFloat, total: CGFloat) -> Double {
        guard total > 0 else { return 0.5 }
        var fraction = value / total
        let minFraction = min(minSplitSize / total, 0.5)
        fraction = min(max(fraction, minFraction), 1 - minFraction)
        return Double(fraction)
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let createSplit = Notification.Name("com.rootshell.createSplit")
    static let navigateSplit = Notification.Name("com.rootshell.navigateSplit")
    static let sshHealthMonitoringToggled = Notification.Name("com.rootshell.sshHealthMonitoringToggled")
    static let sshHealthProbeIntervalChanged = Notification.Name("com.rootshell.sshHealthProbeIntervalChanged")
    static let closeSplit = Notification.Name("com.rootshell.closeSplit")
    static let toggleSplitZoom = Notification.Name("com.rootshell.toggleSplitZoom")
    static let equalizeSplits = Notification.Name("com.rootshell.equalizeSplits")
    static let focusSplit = Notification.Name("com.rootshell.focusSplit")
    static let resizeSplit = Notification.Name("com.rootshell.resizeSplit")
    static let newTab = Notification.Name("com.rootshell.newTab")
    static let newWindow = Notification.Name("com.rootshell.newWindow")
    static let previousTab = Notification.Name("com.rootshell.previousTab")
    static let nextTab = Notification.Name("com.rootshell.nextTab")
    static let appTabSwipeBegan = Notification.Name("com.rootshell.appTabSwipeBegan")
    static let appTabSwipeChanged = Notification.Name("com.rootshell.appTabSwipeChanged")
    static let appTabSwipeEnded = Notification.Name("com.rootshell.appTabSwipeEnded")
    static let selectTab = Notification.Name("com.rootshell.selectTab")
    static let increaseFontSize = Notification.Name("com.rootshell.increaseFontSize")
    static let decreaseFontSize = Notification.Name("com.rootshell.decreaseFontSize")
    static let resetFontSize = Notification.Name("com.rootshell.resetFontSize")
    static let startSearch = Notification.Name("com.rootshell.startSearch")
    static let openSettings = Notification.Name("com.rootshell.openSettings")
    static let duplicateTabWithSSH = Notification.Name("com.rootshell.duplicateTabWithSSH")
    static let createLocalShell = Notification.Name("com.rootshell.createLocalShell")
    static let browseHosts = Notification.Name("com.rootshell.browseHosts")
    static let browseProfiles = Notification.Name("com.rootshell.browseProfiles")
    static let ghosttyDidUpdateScrollbar = Notification.Name("com.rootshell.didUpdateScrollbar")
    static let ghosttySelectionScrollIndicatorActivity = Notification.Name("com.rootshell.selectionScrollIndicatorActivity")
    static let ghosttyDidReceiveInput = Notification.Name("com.rootshell.didReceiveInput")
    static let ghosttySessionDidChange = Notification.Name("com.rootshell.sessionDidChange")
    static let ghosttyEmbeddedMoshSessionDidChange = Notification.Name("com.rootshell.embeddedMoshSessionDidChange")
    static let ghosttyEmbeddedTrzszSessionDidChange = Notification.Name("com.rootshell.embeddedTrzszSessionDidChange")
    static let ghosttyAttachmentUploadStateChanged = Notification.Name("com.rootshell.attachmentUploadStateChanged")
    static let ghosttySearchStateChanged = Notification.Name("com.rootshell.searchStateChanged")
    static let bellTriggered = Notification.Name("com.rootshell.bellTriggered")
    static let toggleAIAgent = Notification.Name("com.rootshell.toggleAIAgent")
    static let toggleVoiceAgent = Notification.Name("com.rootshell.toggleVoiceAgent")
    static let toggleTabBar = Notification.Name("com.rootshell.toggleTabBar")
    static let toggleGroupMode = Notification.Name("com.rootshell.toggleGroupMode")
    static let toggleTransparency = Notification.Name("com.rootshell.toggleTransparency")
    static let toggleTitleBar = Notification.Name("com.rootshell.toggleTitleBar")
    static let toggleAutoRedact = Notification.Name("com.rootshell.toggleAutoRedact")
    static let toggleThemePicker = Notification.Name("com.rootshell.toggleThemePicker")
    static let toggleClipboardManager = Notification.Name("com.rootshell.toggleClipboardManager")
    static let toggleBackgroundEffect = Notification.Name("com.rootshell.toggleBackgroundEffect")
    static let toggleBrightnessBoostHUD = Notification.Name("com.rootshell.toggleBrightnessBoostHUD")
    static let terminalLayoutInvalidation = Notification.Name("com.rootshell.terminalLayoutInvalidation")
    static let terminalBottomInsetInvalidated = Notification.Name("com.rootshell.terminalBottomInsetInvalidated")
    static let touchModeChanged = Notification.Name("com.rootshell.touchModeChanged")
    static let keyboardToolbarHardwareSettingChanged = Notification.Name("com.rootshell.keyboardToolbarHardwareSettingChanged")
    static let showTabSwitcher = Notification.Name("com.rootshell.showTabSwitcher")
    static let toggleTabExpose = Notification.Name("com.rootshell.toggleTabExpose")
    static let previousGroup = Notification.Name("com.rootshell.previousGroup")
    static let nextGroup = Notification.Name("com.rootshell.nextGroup")
    static let tabSwitcherVisibilityChanged = Notification.Name("com.rootshell.tabSwitcherVisibilityChanged")
    static let ghosttyComposeStateChanged = Notification.Name("com.rootshell.composeStateChanged")
    static let toggleFullScreen = Notification.Name("com.rootshell.toggleFullScreen")
    static let showTmuxSessions = Notification.Name("com.rootshell.showTmuxSessions")
    static let detachOtherClients = Notification.Name("com.rootshell.detachOtherClients")
    static let showToolbarSettings = Notification.Name("com.rootshell.showToolbarSettings")
    static let forceASCIIKeyboardChanged = Notification.Name("com.rootshell.forceASCIIKeyboardChanged")
    static let ghosttySessionDiscoveryChanged = Notification.Name("com.rootshell.sessionDiscoveryChanged")
}
