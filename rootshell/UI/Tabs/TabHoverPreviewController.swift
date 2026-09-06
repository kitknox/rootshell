//
//  TabHoverPreviewController.swift
//  rootshell
//
//  Pointer-hover thumbnails for the top tab bar and the vertical tab sidebar.
//  Resting on a tab shows a live, scaled picture of that tab in a floating
//  glass card next to it; moving along the bar slides the card from tab to
//  tab; clicking the card opens the tab exposé, with the card flying into the
//  exposé cell that shows the same tab. Pinching while the card is up resizes
//  it, persisted like the exposé's own pinch zoom.
//
//  One per window (owned by MainView). Pure UIKit below this class so hover
//  churn and the per-frame mirror refresh never invalidate SwiftUI.
//

import UIKit
import SwiftUI
import Observation

/// The live exposé, as seen by the card's hand-off: it follows the reveal
/// into the cell that will show the same tab.
struct TabHoverPreviewExposeHandoff {
    var isActive: () -> Bool
    var isPresented: () -> Bool
    /// 0 hidden … 1 presented.
    var progress: () -> CGFloat
    /// Resting (fully revealed) frame of the tab's preview cell in window
    /// coordinates, plus its corner radius; nil when the tab has no cell.
    var restingPreview: (UUID) -> (frame: CGRect, cornerRadius: CGFloat)?
}

@MainActor
@Observable
final class TabHoverPreviewController: NSObject, UIGestureRecognizerDelegate, PreviewRenderingParticipant {
    /// First show waits; switching between tabs while up is instant.
    static let showDelay: UInt64 = 380_000_000
    /// Grace to cross the gap from the tab into the card (and back).
    static let hideDelay: UInt64 = 140_000_000

    /// The tab whose preview is on screen (nil = none). Observed: the health
    /// popover yields to it.
    private(set) var previewedTabID: UUID?

    let anchors = TabHoverPreviewAnchorRegistry()
    @ObservationIgnored weak var tabsModel: TabsModel?

    // MARK: Host hooks (closures read MainView state live)

    @ObservationIgnored var isEnabled: () -> Bool = { true }
    /// Whether hover alone is enough or a physical modifier must also be held.
    @ObservationIgnored var activation: () -> TabHoverPreviewActivation = { .always }
    /// No exposé, sheet, tab drag or app-tab swipe in flight. Takes the
    /// surface: the floating sidebar is a sheet to a top-bar card but not to
    /// its own rows.
    @ObservationIgnored var canPresent: (TabHoverPreviewSource) -> Bool = { _ in true }
    @ObservationIgnored var reduceMotion: () -> Bool = { false }
    @ObservationIgnored var style: () -> TabHoverPreviewView.Style = { TabHoverPreviewView.Style() }
    /// Title line under the picture.
    @ObservationIgnored var captionProvider: ((TabModel) -> AnyView)?
    /// Wake the tab's renderer so the mirror is live.
    @ObservationIgnored var onWake: ((UUID) -> Void)?
    /// Restore occlusion after the card left (or moved to another tab).
    @ObservationIgnored var onReconcile: (() -> Void)?
    /// Open the exposé with this tab highlighted.
    @ObservationIgnored var onEnterExpose: ((UUID) -> Void)?
    @ObservationIgnored var exposeHandoff: TabHoverPreviewExposeHandoff?
    @ObservationIgnored var onZoomSnapHaptic: (() -> Void)?

    // MARK: Private

    @ObservationIgnored private var card: TabHoverPreviewView?
    @ObservationIgnored private var hoveredTabID: UUID?
    @ObservationIgnored private var hoveredSource: TabHoverPreviewSource = .topBar
    @ObservationIgnored private var hoverBeganAt: CFTimeInterval?
    @ObservationIgnored private var previewedSource: TabHoverPreviewSource = .topBar
    @ObservationIgnored private var pointerInsideCard = false
    @ObservationIgnored private var isHandingOff = false
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var modifierObservationTask: Task<Void, Never>?
    @ObservationIgnored private var settingsObservationTask: Task<Void, Never>?
    @ObservationIgnored private var hardwareModifierFlags: UIKeyModifierFlags = []
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var pinch: UIPinchGestureRecognizer?
    @ObservationIgnored private weak var pinchWindow: UIWindow?
    @ObservationIgnored private var pinchActive = false
    @ObservationIgnored private var pinchAnchorZoom: CGFloat = 1
    @ObservationIgnored private var zoom: CGFloat = 1

    var isShowing: Bool { previewedTabID != nil }

    override init() {
        super.init()
        PreviewRenderingLifecycle.register(self)
    }

    func suspendPreviewRendering() {
        showTask?.cancel()
        showTask = nil
        hideTask?.cancel()
        hideTask = nil
        pinchActive = false
        stopDisplayLink()
        card?.suspendAnimations()
    }

    func dismissPreviewForBackground() {
        hoveredTabID = nil
        hoverBeganAt = nil
        hide(animated: false)
    }

    func preparePreviewForActivation() {
        card?.finishPendingDismissal()
    }

    func resumePreviewRendering() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        card?.resumeAnimations()
        // Suspension cancels both timers. Reconcile their intent even if no
        // new pointer/modifier event arrives after temporary inactivity.
        // scheduleShow preserves the original hover start time; scheduleHide
        // gives the pointer the normal grace period to return to the card.
        reevaluateActivation()
        if hoveredTabID == nil, !pointerInsideCard { scheduleHide() }
        if isShowing { startDisplayLink() }
    }

    deinit {
        showTask?.cancel()
        hideTask?.cancel()
        modifierObservationTask?.cancel()
        settingsObservationTask?.cancel()
        displayLink?.invalidate()
    }

    // MARK: - Zoom persistence

    static let zoomRange: ClosedRange<CGFloat> = 0.5...2.5

    static func clampZoom(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    static func storedZoom() -> CGFloat {
        clampZoom(CGFloat(SettingsStore.shared.value(Settings.Tabs.hoverPreviewZoom)))
    }

    static func storeZoom(_ zoom: CGFloat) {
        SettingsStore.shared.set(Settings.Tabs.hoverPreviewZoom, Double(clampZoom(zoom)))
    }

    // MARK: - Hover input

    /// Observe both inputs to the activation predicate. Idempotent because
    /// MainView's host can appear more than once during its lifetime.
    func startObservingActivationInputs() {
        if modifierObservationTask == nil {
            let stream = KeyboardTracker.shared.hardwareModifierStateDidChangeStream()
            modifierObservationTask = Task { @MainActor [weak self] in
                for await flags in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.hardwareModifiersChanged(flags)
                }
            }
        }

        if settingsObservationTask == nil {
            let changes = SettingsStore.shared.changes()
            settingsObservationTask = Task { @MainActor [weak self] in
                for await change in changes {
                    guard !Task.isCancelled, let self else { return }
                    if change.keys.contains(Settings.Tabs.hoverPreviews.name)
                        || change.keys.contains(Settings.Tabs.hoverPreviewActivation.name) {
                        self.reevaluateActivation()
                    }
                }
            }
        }
    }

    /// A tab button / sidebar row's pointer hover changed.
    func handleHover(tabID: UUID, source: TabHoverPreviewSource, isHovered: Bool) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard !isHandingOff else { return }
        if isHovered {
            hideTask?.cancel()
            hideTask = nil
            if hoveredTabID != tabID || hoveredSource != source {
                hoverBeganAt = CACurrentMediaTime()
            }
            hoveredTabID = tabID
            hoveredSource = source
            if previewedTabID == tabID, previewedSource == source {
                showTask?.cancel()
                showTask = nil
                return
            }
            showTask?.cancel()
            guard activationIsSatisfied else {
                showTask = nil
                if previewedTabID != nil { hide(animated: true) }
                return
            }
            if previewedTabID != nil {
                // Already up: slide to the neighbor without a delay.
                showTask = nil
                present(tabID, source: source)
                return
            }
            scheduleShow(tabID: tabID, source: source)
        } else {
            guard hoveredTabID == tabID, hoveredSource == source else { return }
            hoveredTabID = nil
            hoverBeganAt = nil
            showTask?.cancel()
            showTask = nil
            scheduleHide()
        }
    }

    private var activationIsSatisfied: Bool {
        activation().isSatisfied(by: hardwareModifierFlags)
    }

    private func hardwareModifiersChanged(_ flags: UIKeyModifierFlags) {
        let wasSatisfied = activationIsSatisfied
        hardwareModifierFlags = flags
        guard wasSatisfied != activationIsSatisfied else { return }
        reevaluateActivation()
    }

    private func reevaluateActivation() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard !isHandingOff else { return }
        guard isEnabled(), activationIsSatisfied else {
            showTask?.cancel()
            showTask = nil
            if previewedTabID != nil { hide(animated: true) }
            return
        }

        guard previewedTabID == nil, let tabID = hoveredTabID else { return }
        scheduleShow(tabID: tabID, source: hoveredSource)
    }

    private func scheduleShow(tabID: UUID, source: TabHoverPreviewSource) {
        showTask?.cancel()
        showTask = nil
        guard !Ghostty.isSecureDrawProhibitedAtomic,
              isEnabled(), canPresent(source), activationIsSatisfied else { return }
        let elapsed = hoverBeganAt.map { max(0, CACurrentMediaTime() - $0) } ?? 0
        let delay = max(0, Double(Self.showDelay) / 1_000_000_000 - elapsed)
        if delay == 0 {
            present(tabID, source: source)
            return
        }
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.showTask = nil
            guard self.hoveredTabID == tabID, self.hoveredSource == source,
                  self.activationIsSatisfied else { return }
            self.present(tabID, source: source)
        }
    }

    /// The pointer entered / left the card itself.
    fileprivate func cardHoverChanged(inside: Bool) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        pointerInsideCard = inside
        if inside {
            hideTask?.cancel()
            hideTask = nil
        } else if hoveredTabID == nil {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard previewedTabID != nil, !pinchActive, !isHandingOff else { return }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.hideDelay)
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            guard self.hoveredTabID == nil, !self.pointerInsideCard, !self.pinchActive else { return }
            self.hide(animated: true)
        }
    }

    // MARK: - Presentation

    private func present(_ tabID: UUID, source: TabHoverPreviewSource) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard isEnabled(), activationIsSatisfied, canPresent(source),
              let tabsModel, let tab = tabsModel.tab(withID: tabID),
              tabsModel.selectedTabID != tabID,
              let anchor = anchors.windowFrame(for: tabID, source: source) else {
            if previewedTabID != nil, !isHandingOff { hide(animated: true) }
            return
        }
        let previous = previewedTabID
        if previous == nil { zoom = Self.storedZoom() }
        if previous != tabID { onWake?(tabID) }
        previewedTabID = tabID
        previewedSource = source
        // The old tab's renderer goes back to sleep now that the card left it.
        if let previous, previous != tabID { onReconcile?() }

        let card = card ?? makeCard()
        card.present(
            tab: tab,
            caption: captionProvider?(tab),
            anchor: anchor.frame,
            edge: source == .topBar ? .below : .trailing,
            in: anchor.window,
            style: style(),
            zoom: zoom,
            // A hidden tmux window must go through the sidebar's unhide, not
            // a plain select: the exposé won't list it, so no click-through.
            canEnterExpose: !tab.isHiddenTmuxWindow,
            animated: !reduceMotion()
        )
        installPinch(on: anchor.window)
        startDisplayLink()
    }

    func hide(animated: Bool) {
        showTask?.cancel()
        showTask = nil
        hideTask?.cancel()
        hideTask = nil
        guard previewedTabID != nil else { return }
        previewedTabID = nil
        pointerInsideCard = false
        isHandingOff = false
        pinchActive = false
        stopDisplayLink()
        if !Ghostty.isSecureDrawProhibitedAtomic { pinch?.isEnabled = false }
        card?.dismiss(animated: animated && !reduceMotion())
        onReconcile?()
    }

    private func makeCard() -> TabHoverPreviewView {
        let card = TabHoverPreviewView()
        card.onTap = { [weak self] in self?.enterExpose() }
        card.onHoverChange = { [weak self] inside in self?.cardHoverChanged(inside: inside) }
        self.card = card
        return card
    }

    // MARK: - Exposé hand-off

    /// Click on the card: open the exposé and fly the picture into its cell.
    func enterExpose() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard let id = previewedTabID, let card, !isHandingOff, card.canEnterExpose else { return }
        showTask?.cancel()
        showTask = nil
        hideTask?.cancel()
        hideTask = nil
        onEnterExpose?(id)
        guard let handoff = exposeHandoff, handoff.isActive(), !reduceMotion() else {
            hide(animated: true)
            return
        }
        isHandingOff = true
        pinchActive = false
        pinch?.isEnabled = false
        card.beginHandoff()
        stepHandoff()
    }

    private func stepHandoff() {
        guard isHandingOff, let id = previewedTabID, let card, let handoff = exposeHandoff,
              handoff.isActive() else {
            hide(animated: true)
            return
        }
        let p = min(max(handoff.progress(), 0), 1)
        let target = handoff.restingPreview(id)
        card.applyHandoff(progress: p, target: target?.frame, cornerRadius: target?.cornerRadius)
        if handoff.isPresented() || p >= 0.995 {
            // The cell beneath shows the same pixels; the fade is invisible.
            hide(animated: true)
        }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy(owner: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func tick(now: CFTimeInterval) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else {
            suspendPreviewRendering()
            return
        }
        guard let id = previewedTabID, let card else {
            stopDisplayLink()
            return
        }
        if isHandingOff {
            card.sync()
            stepHandoff()
            return
        }
        // Anything that makes the card wrong takes it down: the tab got
        // selected or closed, a sheet / exposé / drag started, the setting
        // flipped, or the anchor left the screen.
        guard isEnabled(), activationIsSatisfied, canPresent(previewedSource),
              let tabsModel, tabsModel.selectedTabID != id,
              tabsModel.tab(withID: id) != nil,
              let anchor = anchors.windowFrame(for: id, source: previewedSource),
              anchor.window === card.window,
              // The floating sidebar slides off screen with its rows still mounted.
              anchor.frame.intersects(anchor.window.bounds) else {
            hide(animated: true)
            return
        }
        card.updateAnchor(anchor.frame)
        card.step(now: now)
        card.sync()
    }

    private final class DisplayLinkProxy: NSObject {
        weak var owner: TabHoverPreviewController?
        init(owner: TabHoverPreviewController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.tick(now: link.timestamp) }
        }
    }

    // MARK: - Pinch to resize

    /// Window-level so a trackpad pinch counts whether the pointer rests on
    /// the tab or on the card.
    private func installPinch(on window: UIWindow) {
        if pinchWindow !== window {
            if let pinch { pinch.view?.removeGestureRecognizer(pinch) }
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
            pinch = recognizer
            pinchWindow = window
        }
        pinch?.isEnabled = true
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard !Ghostty.isSecureDrawProhibitedAtomic else { return }
        guard let card, previewedTabID != nil, !isHandingOff else { return }
        switch recognizer.state {
        case .began:
            pinchActive = true
            pinchAnchorZoom = zoom
            hideTask?.cancel()
            hideTask = nil
            card.showZoomReadout(zoom)
        case .changed:
            guard pinchActive else { return }
            zoom = Self.clampZoom(pinchAnchorZoom * recognizer.scale)
            card.setZoom(zoom, animated: false)
            card.showZoomReadout(zoom)
        case .ended, .cancelled, .failed:
            guard pinchActive else { return }
            pinchActive = false
            // Magnet on the default size so it is easy to get back to.
            if abs(zoom - 1) < 0.08, zoom != 1 {
                zoom = 1
                card.setZoom(zoom, animated: !reduceMotion())
                onZoomSnapHaptic?()
            }
            Self.storeZoom(zoom)
            card.showZoomReadout(zoom)
            card.hideZoomReadout(after: 1.0)
            if hoveredTabID == nil, !pointerInsideCard { scheduleHide() }
        default:
            break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pinch, let card, let id = previewedTabID, !isHandingOff,
              let window = pinchWindow else { return false }
        // Only a pinch over the card or its tab; the terminal's font pinch is
        // untouched elsewhere.
        var zone = card.frame
        if let anchor = anchors.windowFrame(for: id, source: previewedSource)?.frame {
            zone = zone.union(anchor)
        }
        return zone.insetBy(dx: -24, dy: -24).contains(gestureRecognizer.location(in: window))
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private extension TabHoverPreviewActivation {
    func isSatisfied(by flags: UIKeyModifierFlags) -> Bool {
        switch self {
        case .always: return true
        case .shift: return flags == .shift
        case .command: return flags == .command
        case .option: return flags == .alternate
        case .control: return flags == .control
        }
    }
}
