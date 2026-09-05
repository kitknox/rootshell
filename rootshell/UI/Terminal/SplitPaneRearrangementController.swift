import UIKit

/// A tab-local gesture, not a system drag payload: terminal text/file drops and
/// tab transfers keep their own interactions, and a pane cannot escape its tab.
@MainActor
final class SplitPaneRearrangementController: NSObject, UIGestureRecognizerDelegate {
    private weak var host: SplitTreeHostingView?
    private var tree = SplitTree<SplitPaneView>()
    private var handles: [UUID: PaneGrabHandleView] = [:]
    private var frames: [UUID: CGRect] = [:]
    private var enabled = false
    private var touchHandlesVisible = false
    private var hoveredPaneID: UUID?
    private var source: SplitPaneView?
    private var target: (pane: SplitPaneView, zone: PaneDropZone)?
    private let preview = UIView()
    private var hideTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?

    var isDragging: Bool { source != nil }

    init(host: SplitTreeHostingView) {
        self.host = host
        super.init()
        preview.isUserInteractionEnabled = false
        preview.layer.cornerRadius = 4
        preview.isHidden = true
        host.addSubview(preview)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.cancelsTouchesInView = false
        hover.delegate = self
        host.addGestureRecognizer(hover)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: UIWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? UIWindow,
                      window === self.host?.window else { return }
                self.reset()
            }
        }
    }

    deinit {
        hideTask?.cancel()
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    /// Called before a model update as well as after layout. Any changed
    /// topology invalidates the gesture's destination, including remote tmux edits.
    func update(tree: SplitTree<SplitPaneView>, enabled: Bool) {
        let canMove = enabled && tree.isSplit && tree.zoomed == nil
            && !tree.contains(where: { $0.isDetachedForFullScreen })
        let eligibilityChanged = self.enabled != canMove
        if self.tree.root != tree.root || self.tree.zoomed != tree.zoomed || !canMove {
            reset()
        }
        self.tree = tree
        self.enabled = canMove
        if eligibilityChanged { host?.setNeedsLayout() }
        if !canMove { refreshHandles() }
    }

    func layout() {
        guard let host else { return }
        var nextFrames: [UUID: CGRect] = [:]
        for pane in tree {
            if let frame = host.slotFrame(for: pane) { nextFrames[pane.uuid] = frame }
        }
        if frames != nextFrames, isDragging { reset() }
        frames = nextFrames

        for id in Array(handles.keys) where nextFrames[id] == nil {
            handles.removeValue(forKey: id)?.removeFromSuperview()
        }
        if enabled {
            for pane in tree where handles[pane.uuid] == nil {
                let handle = PaneGrabHandleView(paneID: pane.uuid)
                handle.onPressChanged = { [weak self] pressed in
                    guard let self, self.touchHandlesVisible else { return }
                    if pressed { self.hideTask?.cancel() }
                    else if !self.isDragging { self.scheduleHide() }
                }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                pan.maximumNumberOfTouches = 1
                handle.addGestureRecognizer(pan)
                host.addSubview(handle)
                handles[pane.uuid] = handle
            }
        }
        refreshHandles()
        host.bringSubviewToFront(preview)
    }

    func revealTouchHandles() {
        guard enabled, !isDragging else { return }
        touchHandlesVisible = true
        refreshHandles()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled, let self, !self.isDragging else { return }
            self.touchHandlesVisible = false
            self.refreshHandles()
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Observing the reveal band must not suppress terminal mouse tracking.
        gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer
    }

    /// Returns true only when Escape belongs to an active pane drag.
    @discardableResult
    func cancelDrag() -> Bool {
        guard isDragging else { return false }
        reset()
        // Cancel the recognizer too: its eventual finger/mouse release must
        // never commit a gesture that Escape already cancelled.
        for handle in handles.values {
            for recognizer in handle.gestureRecognizers ?? [] {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        }
        return true
    }

    func reset() {
        hideTask?.cancel()
        hideTask = nil
        source = nil
        target = nil
        touchHandlesVisible = false
        hoveredPaneID = nil
        preview.isHidden = true
        refreshHandles()
    }

    func detach() {
        reset()
        enabled = false
        tree = SplitTree()
        frames.removeAll()
        for handle in handles.values { handle.removeFromSuperview() }
        handles.removeAll()
        preview.removeFromSuperview()
    }

    private func refreshHandles() {
        guard let host else { return }
        for (id, handle) in handles {
            let pane = tree.first(where: { $0.uuid == id })
            let hasDestination = pane.map { source in
                tree.contains(where: { PaneMoveEligibility.allows(source, $0) })
            } ?? false
            let visible = enabled && hasDestination &&
                (touchHandlesVisible || hoveredPaneID == id || source?.uuid == id)
            handle.isHidden = !visible
            guard let frame = frames[id] else { continue }
            let width = min(80, frame.width)
            let height = min(touchHandlesVisible ? 44 : 16, frame.height)
            handle.frame = CGRect(x: frame.midX - width / 2, y: frame.minY, width: width, height: height)
            handle.tintColor = host.highlightColor
            if visible { host.bringSubviewToFront(handle) }
        }
    }

    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        guard enabled, !isDragging, let host else { return }
        hoveredPaneID = nil
        if recognizer.state == .began || recognizer.state == .changed {
            let point = recognizer.location(in: host)
            for (id, frame) in frames where frame.contains(point) {
                if point.y <= frame.minY + max(16, frame.height * 0.2) { hoveredPaneID = id }
                break
            }
        }
        refreshHandles()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }
        switch recognizer.state {
        case .began:
            guard enabled, let handle = recognizer.view as? PaneGrabHandleView,
                  let pane = tree.first(where: { $0.uuid == handle.paneID }),
                  tree.contains(where: { PaneMoveEligibility.allows(pane, $0) }) else { return }
            source = pane
            hideTask?.cancel()
            hideTask = nil
            refreshHandles()
            updateTarget(at: recognizer.location(in: host))
        case .changed:
            guard isDragging else { return }
            updateTarget(at: recognizer.location(in: host))
        case .ended:
            guard let source else { return }
            updateTarget(at: recognizer.location(in: host))
            let destination = target
            reset()
            if let destination {
                host.onMove?(source, destination.pane, destination.zone)
            }
        case .cancelled, .failed:
            reset()
        default: break
        }
    }

    private func updateTarget(at point: CGPoint) {
        target = nil
        preview.isHidden = true
        guard let source, let host, host.bounds.contains(point) else { return }
        for pane in tree {
            guard PaneMoveEligibility.allows(source, pane),
                  let frame = frames[pane.uuid],
                  let zone = PaneDropZone.calculate(at: point, in: frame) else { continue }
            target = (pane, zone)
            preview.frame = zone.previewFrame(in: frame)
            preview.backgroundColor = host.highlightColor.withAlphaComponent(0.3)
            preview.isHidden = false
            host.bringSubviewToFront(preview)
            break
        }
    }
}

private final class PaneGrabHandleView: UIView {
    let paneID: UUID
    var onPressChanged: ((Bool) -> Void)?
    private let symbol = UIImageView(image: UIImage(systemName: "ellipsis"))

    init(paneID: UUID) {
        self.paneID = paneID
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Move pane")
        accessibilityHint = String(localized: "Drag to an edge of another pane in this tab.")
        accessibilityTraits = [.button, .allowsDirectInteraction]
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        symbol.isUserInteractionEnabled = false
        symbol.contentMode = .center
        symbol.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.85)
        symbol.layer.cornerRadius = 5
        symbol.clipsToBounds = true
        addSubview(symbol)
        #if !os(visionOS)
        addInteraction(UIPointerInteraction(delegate: nil))
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        symbol.frame = CGRect(x: (bounds.width - 28) / 2, y: 1, width: 28, height: 12)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPressChanged?(true)
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPressChanged?(false)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        onPressChanged?(false)
        super.touchesCancelled(touches, with: event)
    }
}
