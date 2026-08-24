//
//  ExternalMirrorController.swift
//  rootshell
//
//  Live mirror shown ON the external screen while control mode moves the
//  real external hierarchy onto the device. A workspace-mode
//  TabPreviewMirrorView composites three layers so the external display
//  looks like the normal external window:
//  - chrome: ~3 Hz snapshot of the whole content view (tab bar, sidebar).
//  - terminal panes: zero-copy overlays sharing the renderer IOSurfaces,
//    synced per display-link tick.
//  - VNC panes: a second AVSampleBufferDisplayLayer fed by the session.
//

#if !targetEnvironment(macCatalyst)
import UIKit

@MainActor
final class ExternalMirrorController {
    private weak var externalWindow: ExternalWindow?
    private weak var contentRoot: UIView?
    private var mirrorView: TabPreviewMirrorView?
    private var displayLink: CADisplayLink?
    private var ticksSinceChromeSnapshot = ExternalMirrorController.chromeSnapshotInterval

    /// Chrome snapshot cadence in display-link ticks (~3 Hz at 60 fps).
    private static let chromeSnapshotInterval = 20
    /// Snapshot raster scale: chrome legibility without 4K-sized captures.
    private static let chromeSnapshotScale: CGFloat = 2

    init() {}

    func start(externalWindow: ExternalWindow, contentRoot: UIView, zoomFactor: CGFloat, screen: UIScreen) {
        stop()
        self.externalWindow = externalWindow
        self.contentRoot = contentRoot

        let view = TabPreviewMirrorView(
            source: .workspace(root: contentRoot, zoom: zoomFactor, screenScale: screen.scale),
            vncMode: .videoLayer
        )
        view.backgroundColor = .black
        view.frame = externalWindow.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        externalWindow.addSubview(view)
        mirrorView = view
        ticksSinceChromeSnapshot = Self.chromeSnapshotInterval

        // The external screen's own link: its refresh may differ from the device's.
        let proxy = DisplayLinkProxy(owner: self)
        let link = screen.displayLink(withTarget: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            ?? CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        // Ends any VNC video mirroring before the view goes away.
        mirrorView?.removeAllMirrors()
        mirrorView?.removeFromSuperview()
        mirrorView = nil
        externalWindow = nil
        contentRoot = nil
    }

    func noteZoomFactorChanged(_ zoom: CGFloat) {
        guard let mirrorView, case let .workspace(root, _, screenScale) = mirrorView.source else { return }
        mirrorView.source = .workspace(root: root, zoom: zoom, screenScale: screenScale)
        ticksSinceChromeSnapshot = Self.chromeSnapshotInterval
    }

    fileprivate func tick() {
        guard let mirrorView, let externalWindow, let contentRoot, contentRoot.window != nil else { return }
        let tab = TerminalWindowRegistry.tabsModel(for: ExternalDisplay.windowId)?.selectedTab
        if mirrorView.tab !== tab {
            mirrorView.tab = tab
        }
        if mirrorView.frame != externalWindow.bounds {
            mirrorView.frame = externalWindow.bounds
        }
        updateChromeSnapshotIfDue(contentRoot: contentRoot, into: mirrorView)
        mirrorView.sync()
    }

    /// Chrome (tab bar, sidebar, backgrounds) mirrors via periodic snapshots
    /// of the content view rendering on the device; the full-rate pane
    /// overlays cover the fast-changing regions.
    private func updateChromeSnapshotIfDue(contentRoot: UIView, into mirrorView: TabPreviewMirrorView) {
        ticksSinceChromeSnapshot += 1
        guard ticksSinceChromeSnapshot >= Self.chromeSnapshotInterval else { return }
        ticksSinceChromeSnapshot = 0
        guard contentRoot.bounds.width > 0, contentRoot.bounds.height > 0 else { return }

        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.chromeSnapshotScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: contentRoot.bounds, format: format)
        let image = renderer.image { _ in
            contentRoot.drawHierarchy(in: contentRoot.bounds, afterScreenUpdates: false)
        }
        mirrorView.setChromeImage(image)
    }

    /// Weak-target display link trampoline (precedent: TabExposeView.DisplayLinkProxy).
    private final class DisplayLinkProxy: NSObject {
        weak var owner: ExternalMirrorController?
        init(owner: ExternalMirrorController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick() }
        }
    }
}
#endif
