//
//  TabPreviewMirrorView.swift
//  rootshell
//
//  A live, scaled picture of one tab's panes without touching the panes:
//  every terminal pane's renderer layer holds the current frame's IOSurface
//  in `contents`, so a mirror CALayer assigned the same `contents` shows the
//  live pixels at no extra GPU cost. Resizing the real TerminalView would
//  SIGWINCH the shell; mirroring never changes any pane's frame.
//

import UIKit

@MainActor
final class TabPreviewMirrorView: UIView {
    weak var tab: TabModel? {
        didSet { if tab !== oldValue { rebuild() } }
    }

    private final class PaneMirror {
        let layer = CALayer()
        var vncSnapshot: UIView?
        var lastVNCSnapshotAt: CFTimeInterval = 0
        var placeholder: CALayer?
    }

    private var mirrors: [ObjectIdentifier: PaneMirror] = [:]
    /// Shown where a pane has no frame yet (fresh surface, VNC without a snapshot).
    private let placeholderSymbol = "terminal"

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

    /// Refresh geometry and contents. Cheap when nothing changed: called every
    /// display-link tick while the exposé is visible.
    func sync() {
        guard let tab, let host = tab.splitTree.first?.enclosingSplitHost else {
            removeAllMirrors()
            return
        }
        let hostSize = host.bounds.size
        guard hostSize.width > 0, hostSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scaleX = bounds.width / hostSize.width
        let scaleY = bounds.height / hostSize.height

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var seen: Set<ObjectIdentifier> = []
        for pane in tab.splitTree {
            let key = ObjectIdentifier(pane)
            seen.insert(key)
            let mirror = mirrors[key] ?? makeMirror(for: key)

            // Where the pane's picture actually sits inside the tab, in host coords.
            let sourceRect: CGRect
            if let terminal = pane.asTerminal, let source = terminal.rendererLayer {
                sourceRect = source.convert(source.bounds, to: host.layer)
                if let contents = source.contents {
                    // Re-assign every tick even when it's the same IOSurface:
                    // the renderer draws into it in place, and CA only
                    // re-reads the pixels when `contents` is set (the core's
                    // own layer does the same per frame).
                    mirror.layer.contents = contents
                    if mirror.layer.contentsScale != source.contentsScale {
                        mirror.layer.contentsScale = source.contentsScale
                    }
                    if mirror.layer.isGeometryFlipped != source.isGeometryFlipped {
                        mirror.layer.isGeometryFlipped = source.isGeometryFlipped
                    }
                    mirror.placeholder?.removeFromSuperlayer()
                    mirror.placeholder = nil
                }
                mirror.layer.backgroundColor = terminal.backgroundColor?.cgColor ?? backgroundColor?.cgColor
            } else {
                sourceRect = pane.convert(pane.bounds, to: host)
                refreshVNCSnapshot(for: pane, mirror: mirror)
            }

            let frame = CGRect(
                x: sourceRect.minX * scaleX,
                y: sourceRect.minY * scaleY,
                width: sourceRect.width * scaleX,
                height: sourceRect.height * scaleY
            )
            mirror.layer.frame = frame
            mirror.vncSnapshot?.frame = frame
            if mirror.layer.contents == nil, mirror.vncSnapshot == nil {
                ensurePlaceholder(mirror, in: frame)
            }
            mirror.placeholder?.position = CGPoint(x: frame.midX, y: frame.midY)
        }

        for key in Array(mirrors.keys) where !seen.contains(key) {
            guard let mirror = mirrors.removeValue(forKey: key) else { continue }
            removeMirror(mirror)
        }
    }

    private func makeMirror(for key: ObjectIdentifier) -> PaneMirror {
        let mirror = PaneMirror()
        // `.resize` maps the source layer's bounds (exactly the IOSurface) onto
        // the scaled mirror frame; the source itself uses top-left gravity.
        mirror.layer.contentsGravity = .resize
        mirror.layer.minificationFilter = .trilinear
        mirror.layer.masksToBounds = true
        layer.addSublayer(mirror.layer)
        mirrors[key] = mirror
        return mirror
    }

    private func ensurePlaceholder(_ mirror: PaneMirror, in frame: CGRect) {
        guard mirror.placeholder == nil else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .light)
        guard let image = UIImage(systemName: placeholderSymbol, withConfiguration: config)?
            .withTintColor(.white.withAlphaComponent(0.3), renderingMode: .alwaysOriginal) else { return }
        let symbol = CALayer()
        symbol.contents = image.cgImage
        symbol.contentsGravity = .resizeAspect
        symbol.bounds = CGRect(origin: .zero, size: image.size)
        symbol.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.addSublayer(symbol)
        mirror.placeholder = symbol
    }

    /// VNC panes have no shared surface; take a cheap snapshot at ~2 Hz.
    private func refreshVNCSnapshot(for pane: SplitPaneView, mirror: PaneMirror) {
        let now = CACurrentMediaTime()
        guard now - mirror.lastVNCSnapshotAt > 0.5 else { return }
        mirror.lastVNCSnapshotAt = now
        guard let snapshot = pane.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.isUserInteractionEnabled = false
        snapshot.contentMode = .scaleToFill
        mirror.vncSnapshot?.removeFromSuperview()
        mirror.vncSnapshot = snapshot
        addSubview(snapshot)
        mirror.placeholder?.removeFromSuperlayer()
        mirror.placeholder = nil
    }

    private func rebuild() {
        removeAllMirrors()
        setNeedsLayout()
    }

    /// Drop every reference to the source frame immediately. Removing a layer
    /// from the hierarchy is not sufficient: Core Animation can keep the
    /// IOSurface assigned to `contents` alive after the preview disappears.
    func releaseContents() {
        tab = nil
        removeAllMirrors()
    }

    private func removeMirror(_ mirror: PaneMirror) {
        mirror.layer.contents = nil
        mirror.layer.removeFromSuperlayer()
        mirror.vncSnapshot?.removeFromSuperview()
        mirror.vncSnapshot = nil
        mirror.placeholder?.contents = nil
        mirror.placeholder?.removeFromSuperlayer()
        mirror.placeholder = nil
    }

    private func removeAllMirrors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for mirror in mirrors.values {
            removeMirror(mirror)
        }
        mirrors.removeAll()
    }
}
