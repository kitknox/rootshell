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
//  Two geometry sources: `.tabHost` (Tab Exposé) scales the tab's split host
//  into this view's bounds; `.workspace` (external display control mode)
//  maps pane frames from a workspace root by a fixed zoom, optionally under
//  a periodic chrome snapshot and with VNC panes fed by a live video layer.
//

import AVFoundation
import UIKit
import rootshellVNC

@MainActor
final class TabPreviewMirrorView: UIView {
    /// Where pane geometry comes from and how it maps into this view.
    enum Source {
        /// Scale the tab's split host bounds to fit this view (Tab Exposé).
        case tabHost
        /// Pane frames in `root` coordinates times `zoom`; IOSurfaces are
        /// presented at `screenScale` so the composite is pixel-exact.
        case workspace(root: UIView, zoom: CGFloat, screenScale: CGFloat)
    }

    /// How VNC panes (no shared IOSurface) are pictured.
    enum VNCMode {
        /// Cheap ~2 Hz `snapshotView` of the pane.
        case snapshot
        /// Live `AVSampleBufferDisplayLayer` from the session's renderer.
        case videoLayer
    }

    weak var tab: TabModel? {
        didSet { if tab !== oldValue { rebuild() } }
    }

    var source: Source {
        didSet { setNeedsLayout() }
    }
    let vncMode: VNCMode

    private final class PaneMirror {
        let layer = CALayer()
        var vncSnapshot: UIView?
        var lastVNCSnapshotAt: CFTimeInterval = 0
        var placeholder: CALayer?
        /// `.videoLayer` mode only; ended on reap.
        var videoLayer: AVSampleBufferDisplayLayer?
        weak var videoPane: VNCPaneView?
    }

    private var mirrors: [ObjectIdentifier: PaneMirror] = [:]
    /// Shown where a pane has no frame yet (fresh surface, VNC without a snapshot).
    private let placeholderSymbol = "terminal"
    /// Bottom-most layer holding the chrome snapshot; pane mirrors sit above.
    private var chromeLayer: CALayer?

    init(source: Source = .tabHost, vncMode: VNCMode = .snapshot) {
        self.source = source
        self.vncMode = vncMode
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        chromeLayer?.frame = bounds
        sync()
    }

    /// Replace the chrome picture drawn beneath the pane mirrors (nil clears).
    func setChromeImage(_ image: UIImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let image else {
            chromeLayer?.removeFromSuperlayer()
            chromeLayer = nil
            return
        }
        let chrome: CALayer
        if let chromeLayer {
            chrome = chromeLayer
        } else {
            chrome = CALayer()
            chrome.contentsGravity = .resize
            layer.insertSublayer(chrome, at: 0)
            chromeLayer = chrome
        }
        chrome.frame = bounds
        chrome.contents = image.cgImage
    }

    /// Refresh geometry and contents. Cheap when nothing changed: called every
    /// display-link tick while the mirror is visible.
    func sync() {
        guard let tab else {
            removeAllMirrors()
            return
        }
        // Maps a pane rect (in host/root coords) into this view.
        let mapRect: (CGRect) -> CGRect
        let reference: UIView
        let contentsScale: CGFloat?
        switch source {
        case .tabHost:
            guard let host = tab.splitTree.first?.enclosingSplitHost else {
                removeAllMirrors()
                return
            }
            let hostSize = host.bounds.size
            guard hostSize.width > 0, hostSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            let scaleX = bounds.width / hostSize.width
            let scaleY = bounds.height / hostSize.height
            reference = host
            contentsScale = nil
            mapRect = { r in
                CGRect(x: r.minX * scaleX, y: r.minY * scaleY, width: r.width * scaleX, height: r.height * scaleY)
            }
        case let .workspace(root, zoom, screenScale):
            reference = root
            contentsScale = screenScale
            mapRect = { r in
                CGRect(x: r.minX * zoom, y: r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var seen: Set<ObjectIdentifier> = []
        for pane in tab.splitTree {
            if case .workspace = source, pane.window == nil { continue }
            let key = ObjectIdentifier(pane)
            seen.insert(key)
            let mirror = mirrors[key] ?? makeMirror(for: pane, key: key)

            // Where the pane's picture actually sits, in reference coords.
            let sourceRect: CGRect
            if let terminal = pane.asTerminal, let sourceLayer = terminal.rendererLayer {
                sourceRect = sourceLayer.convert(sourceLayer.bounds, to: reference.layer)
                if let contents = sourceLayer.contents {
                    // Re-assign every tick even when it's the same IOSurface:
                    // the renderer draws into it in place, and CA only
                    // re-reads the pixels when `contents` is set (the core's
                    // own layer does the same per frame).
                    mirror.layer.contents = contents
                    let wantedScale = contentsScale ?? sourceLayer.contentsScale
                    if mirror.layer.contentsScale != wantedScale {
                        mirror.layer.contentsScale = wantedScale
                    }
                    if mirror.layer.isGeometryFlipped != sourceLayer.isGeometryFlipped {
                        mirror.layer.isGeometryFlipped = sourceLayer.isGeometryFlipped
                    }
                    mirror.placeholder?.removeFromSuperlayer()
                    mirror.placeholder = nil
                }
                mirror.layer.backgroundColor = terminal.backgroundColor?.cgColor ?? backgroundColor?.cgColor
            } else {
                sourceRect = pane.convert(pane.bounds, to: reference)
                if mirror.videoLayer == nil {
                    refreshVNCSnapshot(for: pane, mirror: mirror)
                }
            }

            let frame = mapRect(sourceRect)
            mirror.layer.frame = frame
            mirror.vncSnapshot?.frame = frame
            if let videoLayer = mirror.videoLayer, let session = mirror.videoPane?.session {
                layoutVideoLayer(videoLayer, in: mirror.layer.bounds, session: session)
            }
            if mirror.layer.contents == nil, mirror.vncSnapshot == nil, mirror.videoLayer == nil {
                ensurePlaceholder(mirror, in: frame)
            }
            mirror.placeholder?.position = CGPoint(x: frame.midX, y: frame.midY)
        }

        for (key, mirror) in mirrors where !seen.contains(key) {
            tearDown(mirror)
            mirrors[key] = nil
        }
    }

    private func makeMirror(for pane: SplitPaneView, key: ObjectIdentifier) -> PaneMirror {
        let mirror = PaneMirror()
        // `.resize` maps the source layer's bounds (exactly the IOSurface) onto
        // the scaled mirror frame; the source itself uses top-left gravity.
        mirror.layer.contentsGravity = .resize
        mirror.layer.minificationFilter = .trilinear
        mirror.layer.masksToBounds = true
        if case .videoLayer = vncMode, let vncPane = pane as? VNCPaneView {
            let videoLayer = vncPane.session.videoBandRenderer.beginMirroring()
            mirror.layer.backgroundColor = UIColor.black.cgColor
            mirror.layer.addSublayer(videoLayer)
            mirror.videoLayer = videoLayer
            mirror.videoPane = vncPane
        }
        layer.addSublayer(mirror.layer)
        mirrors[key] = mirror
        return mirror
    }

    /// Aspect-fit the remote framebuffer inside the pane mirror, matching
    /// the primary view's own presentation.
    private func layoutVideoLayer(_ videoLayer: CALayer, in bounds: CGRect, session: VNCSession) {
        let native = session.presentedFramebufferSize
        guard native.width > 0, native.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = min(bounds.width / native.width, bounds.height / native.height)
        let size = CGSize(width: native.width * scale, height: native.height * scale)
        let frame = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        if videoLayer.frame != frame {
            videoLayer.frame = frame
        }
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

    private func tearDown(_ mirror: PaneMirror) {
        if mirror.videoLayer != nil {
            mirror.videoPane?.session.videoBandRenderer.endMirroring()
            mirror.videoLayer?.removeFromSuperlayer()
            mirror.videoLayer = nil
        }
        mirror.layer.removeFromSuperlayer()
        mirror.vncSnapshot?.removeFromSuperview()
        mirror.placeholder?.removeFromSuperlayer()
    }

    /// Drops every pane mirror (and ends any VNC video mirroring).
    func removeAllMirrors() {
        for mirror in mirrors.values {
            tearDown(mirror)
        }
        mirrors.removeAll()
    }
}
