//
//  MuxTabPreviewView.swift
//  rootshell
//
//  The exposé cell picture of one multiplexer tab (herdr tab, tmux window,
//  zellij tab): its pane layout reproduced from cell rects, each pane an
//  offscreen Ghostty preview surface fed the latest frame from the feed.
//  Surfaces are sized to the pane's real column/row count and scaled into
//  the cell, so wrapping matches the source; a frame is written only when
//  its revision changes, atomically, so nothing ever flickers.
//

import UIKit

@MainActor
final class MuxTabPreviewView: UIView {
    weak var feed: MultiplexerExposeFeed?
    var tab: MuxTab? {
        didSet {
            guard tab != oldValue else { return }
            if tab == nil { removeAll() } else { setNeedsLayout() }
        }
    }

    private final class PanePreview {
        let container = UIView()
        var surface: Ghostty.TmuxPreviewView?
        var placeholder: CALayer?
        var writtenRevision: String?
        /// Grid the written frame was laid out for. A resize reflows and can
        /// clear what was already painted, and an unchanged revision would
        /// never redraw it, so the frame is rewritten whenever this changes.
        var writtenGrid: String?
        var surfaceSize: CGSize = .zero
        /// Cells added on top of the pane's own grid so the surface really
        /// holds it; grown when the surface reports a grid that is too small.
        var slackColumns: CGFloat = 2
        var slackRows: CGFloat = 2
        /// A reported grid must stay unchanged until Ghostty's terminal
        /// mailbox has had time to apply the resize. `ghostty_surface_set_size`
        /// publishes the new grid immediately, but the mailbox lags behind;
        /// writing sooner can parse a 144-column frame at the old (roughly
        /// half-width) grid, wrapping and scrolling it before the new size
        /// lands. This matches `TmuxPreviewContainer`'s established delay.
        var settledGrid: String?
        var readyAfter: CFTimeInterval = 0
    }

    private var previews: [String: PanePreview] = [:]
    /// Used while the surface has not reported its real cell size yet.
    private static let fallbackCellSize = CGSize(width: 8, height: 16)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        sync()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen the surfaces go; they come back on the next sync.
        if window == nil { removeAll() }
    }

    /// Pane ids this view is showing (for the feed's visible set).
    var paneIDs: Set<String> {
        Set(tab?.panes.filter(\.isPreviewable).map(\.id) ?? [])
    }

    /// Refresh geometry and frames; cheap when nothing changed (per display tick).
    func sync() {
        guard let tab, tab.cols > 0, tab.rows > 0, bounds.width > 0, bounds.height > 0, window != nil else { return }
        let cw = bounds.width / CGFloat(tab.cols)
        let ch = bounds.height / CGFloat(tab.rows)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var seen: Set<String> = []
        for pane in tab.panes {
            seen.insert(pane.id)
            let preview = previews[pane.id] ?? makePreview(for: pane.id)
            let rect = pane.rect
            let frame = CGRect(
                x: CGFloat(rect.x) * cw, y: CGFloat(rect.y) * ch,
                width: CGFloat(rect.width) * cw, height: CGFloat(rect.height) * ch
            )
            preview.container.frame = frame
            bringSubviewToFront(preview.container)
            guard pane.isPreviewable, rect.width > 0, rect.height > 0 else {
                preview.surface?.cleanup()
                preview.surface?.removeFromSuperview()
                preview.surface = nil
                ensurePlaceholder(preview)
                continue
            }
            let surface = preview.surface ?? makeSurface(preview)
            guard let surface else {
                ensurePlaceholder(preview)
                continue
            }
            // The pane's own grid plus slack, so no captured row wraps here.
            let cell = surface.cellSize ?? Self.fallbackCellSize
            // A grid smaller than the source wraps every row; grow and retry.
            if let grid = surface.gridSize, preview.surfaceSize != .zero {
                if grid.columns < rect.width {
                    preview.slackColumns += CGFloat(rect.width - grid.columns) + 1
                }
                if grid.rows < rect.height {
                    preview.slackRows += CGFloat(rect.height - grid.rows) + 1
                }
            }
            // Ghostty insets the grid by the window padding, so the surface
            // needs room for it on top of the cells it must hold.
            let padX = CGFloat(PaddingManager.shared.effectivePaddingX)
            let padY = CGFloat(PaddingManager.shared.effectivePaddingY)
            let virtual = CGSize(
                width: (CGFloat(rect.width) + preview.slackColumns) * cell.width + padX * 2,
                height: (CGFloat(rect.height) + preview.slackRows) * cell.height + padY * 2
            )
            let resized = abs(preview.surfaceSize.width - virtual.width) > 0.5
                || abs(preview.surfaceSize.height - virtual.height) > 0.5
            let isZmx = feed?.type == .zmx
            if resized {
                preview.surfaceSize = virtual
                surface.bounds = CGRect(origin: .zero, size: virtual)
                surface.setNeedsLayout()
                surface.layoutIfNeeded()
                // The old frame was laid out for the old grid: draw it again.
                preview.writtenRevision = nil
                preview.writtenGrid = nil
                if isZmx {
                    preview.settledGrid = nil
                    preview.readyAfter = CACurrentMediaTime() + 0.15
                }
            }
            // Map the pane's own cells onto the cell, ignoring slack AND the
            // padding: the grid starts at (padX, padY), so scaling from the
            // surface's origin would push its last row past the bottom edge.
            // Padding balance is off app-wide, so the leading inset is exact
            // and any sub-cell remainder sits on the trailing edges.
            let sx = frame.width / max(CGFloat(rect.width) * cell.width, 1)
            let sy = frame.height / max(CGFloat(rect.height) * cell.height, 1)
            if isZmx {
                // Separate zmx sessions may have different aspect ratios.
                let fit = min(sx, sy)
                let insetX = (frame.width - CGFloat(rect.width) * cell.width * fit) / 2
                let insetY = (frame.height - CGFloat(rect.height) * cell.height * fit) / 2
                surface.transform = CGAffineTransform(
                    translationX: insetX - padX * fit, y: insetY - padY * fit
                ).scaledBy(x: fit, y: fit)
            } else {
                surface.transform = CGAffineTransform(translationX: -padX * sx, y: -padY * sy)
                    .scaledBy(x: sx, y: sy)
            }

            // Write only into a grid that can hold the capture unwrapped.
            let grid = surface.gridSize
            let fits = grid.map { $0.columns >= rect.width && $0.rows >= rect.height } ?? false
            let gridKey = grid.map { "\($0.columns)x\($0.rows)" }
            let gridIsSettled = !isZmx || (!resized
                && CACurrentMediaTime() >= preview.readyAfter
                && gridKey != nil
                && preview.settledGrid == gridKey)
            if isZmx, !resized, preview.settledGrid != gridKey {
                preview.settledGrid = gridKey
            }
            if gridIsSettled, fits, let latest = feed?.frame(for: pane.id),
               latest.revision != preview.writtenRevision || gridKey != preview.writtenGrid {
                surface.writeFrame(latest.ansi, cursor: latest.cursor.map { ($0.x, $0.y, $0.visible) })
                preview.writtenRevision = latest.revision
                preview.writtenGrid = gridKey
                preview.placeholder?.removeFromSuperlayer()
                preview.placeholder = nil
            } else if preview.writtenRevision == nil {
                ensurePlaceholder(preview)
            }
            // A frame larger than the pipe finishes over the next few ticks.
            surface.flushPendingWrites()
        }

        for (id, preview) in previews where !seen.contains(id) {
            preview.surface?.cleanup()
            preview.container.removeFromSuperview()
            previews[id] = nil
        }
    }

    private func makePreview(for id: String) -> PanePreview {
        let preview = PanePreview()
        preview.container.clipsToBounds = true
        preview.container.isUserInteractionEnabled = false
        preview.container.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        preview.container.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        addSubview(preview.container)
        previews[id] = preview
        return preview
    }

    private func makeSurface(_ preview: PanePreview) -> Ghostty.TmuxPreviewView? {
        guard let app = feed?.ghosttyApp else { return nil }
        let surface = Ghostty.TmuxPreviewView(ghosttyApp: app)
        surface.layer.anchorPoint = .zero
        surface.layer.position = .zero
        preview.container.addSubview(surface)
        preview.surface = surface
        preview.writtenRevision = nil
        preview.surfaceSize = .zero
        return surface
    }

    private func ensurePlaceholder(_ preview: PanePreview) {
        let bounds = preview.container.bounds
        if let placeholder = preview.placeholder {
            placeholder.position = CGPoint(x: bounds.midX, y: bounds.midY)
            return
        }
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .light)
        guard let image = UIImage(systemName: "terminal", withConfiguration: config)?
            .withTintColor(.white.withAlphaComponent(0.3), renderingMode: .alwaysOriginal) else { return }
        let symbol = CALayer()
        symbol.contents = image.cgImage
        symbol.contentsGravity = .resizeAspect
        symbol.bounds = CGRect(origin: .zero, size: image.size)
        symbol.position = CGPoint(x: bounds.midX, y: bounds.midY)
        preview.container.layer.addSublayer(symbol)
        preview.placeholder = symbol
    }

    /// Dispose the offscreen Ghostty surfaces even if the model was already
    /// cleared before this view left its window.
    func releaseResources() {
        tab = nil
        feed = nil
        removeAll()
    }

    private func removeAll() {
        for preview in previews.values {
            preview.surface?.cleanup()
            preview.container.removeFromSuperview()
        }
        previews.removeAll()
    }
}
