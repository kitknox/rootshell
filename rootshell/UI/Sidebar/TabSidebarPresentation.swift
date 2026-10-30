//
//  TabSidebarPresentation.swift
//  rootshell
//
//  Presents an edge sidebar:
//  - iPhone and iPad: a UIKit-hosted panel sits beside the visually shifted
//    terminal view. Catalyst keeps its edge overlay. Deliberately
//    NOT a fullScreenCover: covers share UIKit's one-presentation slot with
//    the settings panel, and a present-while-dismissing race wedges the
//    binding true with no presenter mounted — the toggle then appears dead
//    and first-responder restoration (gated on isAnySheetPresented) never
//    runs. The connection sidebar hit the same class of deadlock and moved
//    to this overlay; the tab sidebar follows it.
//  - visionOS: standard .sheet()
//

import os
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    /// Header swipe-down progress (userInfo "offset": CGFloat). The overlay
    /// controller translates the whole hosting view — applying a SwiftUI
    /// `.offset` to the content moved only the content (the panel chrome
    /// stayed put) and fed the moving view back into local-space gesture
    /// math, which read as jitter.
    static let tabSidebarDismissDragChanged = Notification.Name("com.rootshell.tabSidebarDismissDragChanged")
    /// Swipe-down released below the dismiss threshold: spring back.
    static let tabSidebarDismissDragCancelled = Notification.Name("com.rootshell.tabSidebarDismissDragCancelled")

    /// Left-edge swipe-to-open started (iPad). The overlay mounts at its hidden
    /// transform and sits still — the drag notifications below drive it in,
    /// instead of the auto-spring that a tap/shortcut open uses.
    static let tabSidebarBeginInteractiveOpen = Notification.Name("com.rootshell.tabSidebarBeginInteractiveOpen")
    /// Edge-swipe-open progress (userInfo "progress": CGFloat 0…1).
    static let tabSidebarOpenDragChanged = Notification.Name("com.rootshell.tabSidebarOpenDragChanged")
    /// Edge-swipe released past the open threshold: spring the rest of the way in.
    static let tabSidebarOpenDragCommit = Notification.Name("com.rootshell.tabSidebarOpenDragCommit")
    /// Edge-swipe released below the open threshold: settle back hidden.
    static let tabSidebarOpenDragCancel = Notification.Name("com.rootshell.tabSidebarOpenDragCancel")
}

struct TabSidebarModifier<SidebarContent: View>: ViewModifier {
    var edge: SidePanelEdge = .leading
    var preventDismissal = false
    @Binding var showSidebar: Bool

    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    @ViewBuilder let sidebarContent: () -> SidebarContent

    func body(content: Content) -> some View {
        #if os(visionOS)
        content
            .sheet(isPresented: $showSidebar) {
                sidebarContent()
                    .themedSheet(themeColors: themeColors, accentColor: accentColor, colorScheme: colorScheme)
            }
        #else
        // iPhone uses the same in-hierarchy overlay as iPad/Catalyst (the
        // 420pt panel clamps to the screen width, so it is effectively the
        // full-screen presentation the phone wants). A .sheet was tried for
        // the phone and rejected: a presented sheet cannot blur the
        // presenting view, so the translucent (liquid glass) mode read as
        // opaque there — materials only sample live SIBLING content, which
        // an overlay has and a presentation does not.
        content
            .overlay {
                TabSidebarUIKitOverlay(
                    edge: edge,
                    preventDismissal: preventDismissal,
                    showSidebar: $showSidebar,
                    themeColors: themeColors,
                    accentColor: accentColor,
                    colorScheme: colorScheme,
                    sidebarContent: sidebarContent
                )
                .ignoresSafeArea()
                .ignoresSafeArea(.keyboard)
            }
        #endif
    }
}

#if !os(visionOS)

private func terminalWindowContent(in window: UIWindow) -> UIView? {
    guard var content = window.rootViewController?.viewIfLoaded else { return nil }
    while let parent = content.superview, parent !== window {
        content = parent
    }
    return content.superview === window ? content : nil
}

private func placeSidebarOverlay(_ overlay: UIView, in window: UIWindow) {
    if var modal = window.rootViewController?.presentedViewController?.viewIfLoaded {
        while let parent = modal.superview, parent !== window {
            modal = parent
        }
        if modal.superview === window {
            window.insertSubview(overlay, belowSubview: modal)
            return
        }
    }
    window.addSubview(overlay)
}

// MARK: - UIKit Overlay

private struct TabSidebarUIKitOverlay<SidebarContent: View>: UIViewControllerRepresentable {
    var edge: SidePanelEdge
    var preventDismissal: Bool
    @Binding var showSidebar: Bool
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    @ViewBuilder var sidebarContent: () -> SidebarContent

    /// Glass look: the panel fills with a material instead of the opaque
    /// theme background. The backdrop sits BEHIND the panel too, so it must
    /// dim far less or the blurred terminal reads as black.
    @Setting(Settings.Sidebar.translucent) private var tabSidebarTranslucent

    private func makeOnCloseAction() -> () -> Void {
        let showSidebar = $showSidebar
        return {
            showSidebar.wrappedValue = false
        }
    }

#if !targetEnvironment(macCatalyst)
    private var resolvedRevealBackgroundColor: UIColor {
        let color = UIColor(themeColors?.background ?? Color(uiColor: .systemBackground))
        guard let colorScheme else { return color }
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }
#endif

    func makeUIViewController(context: Context) -> TabSidebarOverlayInstallerViewController {
        let overlayController = TabSidebarOverlayViewController()
        // Slide in from this edge. Compact width keeps a peek of the terminal.
        // Only a leading panel clears the top-leading window controls.
        overlayController.edge = edge
        overlayController.allowPhoneBottom = false
#if targetEnvironment(macCatalyst)
        overlayController.compactPeek = 48
#else
        overlayController.compactPeek = 0
#endif
        overlayController.clearsWindowControls = edge == .leading
        overlayController.resignFirstResponderOnDismiss = true
        // NOTE: do NOT set escapeDismisses here. The tab sidebar's search field
        // (SidebarSearchField) auto-focuses on open and owns first responder so
        // it can drive Up/Down tab navigation (pressesBegan) and two-stage
        // Escape (its own UIKeyCommand). Making this VC grab first responder for
        // an ESC key command would steal it from that field and break arrow-key
        // tab navigation. Settings is different — it has no auto-focusing field,
        // so it opts into escapeDismisses for its ESC.
        overlayController.onClose = makeOnCloseAction()
        return TabSidebarOverlayInstallerViewController(overlayController: overlayController)
    }

    func updateUIViewController(_ installer: TabSidebarOverlayInstallerViewController, context: Context) {
        let onClose = makeOnCloseAction()
        let controller = installer.overlayController
        controller.onClose = onClose
#if !targetEnvironment(macCatalyst)
        controller.updateRevealBackgroundColor(resolvedRevealBackgroundColor)
#endif

#if targetEnvironment(macCatalyst)
        let backdropAlpha: CGFloat = tabSidebarTranslucent ? 0.12 : (themeColors != nil ? 0.4 : 0.5)
#else
        let backdropAlpha: CGFloat = 0
#endif

        controller.update(
            isPresented: showSidebar,
            contentID: 0,
            preventDismissal: preventDismissal,
            backdropAlpha: backdropAlpha,
            panelWidth: 420,
            rootView: AnyView(TabSidebarPanelView(
                edge: edge,
                themeColors: themeColors,
                accentColor: accentColor,
                colorScheme: colorScheme,
                onClose: onClose,
                sidebarContent: sidebarContent
            ))
        )
        installer.installIfNeeded()
    }

    static func dismantleUIViewController(
        _ installer: TabSidebarOverlayInstallerViewController,
        coordinator: Void
    ) {
        installer.detachOverlay()
    }
}

/// The representable remains in MainView's hierarchy. Its panel is installed
/// beside the transformed root view so UIKit hit testing follows the reveal.
private final class TabSidebarOverlayInstallerViewController: UIViewController {
    let overlayController: TabSidebarOverlayViewController
    private weak var installedWindow: UIWindow?

    init(overlayController: TabSidebarOverlayViewController) {
        self.overlayController = overlayController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installIfNeeded()
        overlayController.updateWindowControlsClearance()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        overlayController.updateWindowControlsClearance()
    }

    func installIfNeeded() {
        guard let window = viewIfLoaded?.window else { return }
        // This installer remains in the original SwiftUI hierarchy and retains
        // its corner-adapted safe area. The visible overlay view is installed
        // directly on UIWindow so it can sit above full-screen VNC, but that
        // reparenting otherwise loses Catalyst's traffic-light clearance.
        overlayController.windowControlsClearanceSourceView = view
        let rootView = terminalWindowContent(in: window)
#if !targetEnvironment(macCatalyst)
        guard rootView != nil else { return }
#endif
        if installedWindow === window, overlayController.view.superview === window {
            updateOverlayFrame(in: window)
            installOverlay(in: window)
            return
        }

        detachOverlay()
        updateOverlayFrame(in: window)
        overlayController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        installedWindow = window
        installOverlay(in: window)
        overlayController.installCloseGesture(on: window)
    }

    private func updateOverlayFrame(in window: UIWindow) {
        #if targetEnvironment(macCatalyst)
        overlayController.view.frame = window.bounds
        #else
        // Duo reserves a status column beside the app. Keep the whole panel
        // inside it so NavigationStack and its parent share the same width.
        overlayController.view.frame = window.bounds.inset(by: UIEdgeInsets(
            top: 0, left: window.safeAreaInsets.left,
            bottom: 0, right: window.safeAreaInsets.right
        ))
        #endif
    }

    private func installOverlay(in window: UIWindow) {
        // The root keeps its full hit-test bounds during a render-only reveal.
        placeSidebarOverlay(overlayController.view, in: window)
    }

    func detachOverlay() {
        overlayController.detachFromWindow(installedWindow)
        guard overlayController.view.superview != nil else {
            installedWindow = nil
            return
        }
        overlayController.view.removeFromSuperview()
        installedWindow = nil
    }
}

final class TabSidebarOverlayViewController: SidePanelOverlayViewController, UIGestureRecognizerDelegate {
    /// True while a left-edge swipe is interactively dragging the panel in.
    /// Suppresses the auto-spring in `applyPresentationChange`.
    private var interactiveOpenActive = false
    private var visibleProgress: CGFloat = 0
    private var transformGeneration = 0
    private var lastTerminalBounds: CGRect = .zero
    var revealBackgroundColor: UIColor?
    /// Drag the open panel back off its edge. The recognizer sits on the
    /// overlay, not the panel, so the panel transform does not move the
    /// gesture's coordinate space.
    private var closePanGesture: UIPanGestureRecognizer?
    private var outsideTapGesture: UITapGestureRecognizer?

    override func viewDidLoad() {
        // The shared core mounts the backdrop + hosting view, wires the
        // backdrop tap, and applies the hidden state. Layer this panel's
        // interactive gestures on top.
        super.viewDidLoad()

        #if !targetEnvironment(macCatalyst)
        // Hidden drawers must not paint into the window's reserved side bands.
        view.clipsToBounds = true
        #endif

        // Keep the recognizer installed through resizes; its delegate gates
        // side dismissal on the current width class.
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handleClosePan(_:)))
        closePan.delegate = self
        closePan.maximumNumberOfTouches = 1
#if targetEnvironment(macCatalyst)
        view.addGestureRecognizer(closePan)
#endif
        self.closePanGesture = closePan
        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(handleOutsideTap))
        outsideTap.delegate = self
        self.outsideTapGesture = outsideTap
#if targetEnvironment(macCatalyst)
        view.addGestureRecognizer(outsideTap)
#endif

        // Header swipe-down: translate the WHOLE panel (chrome + content)
        // at the UIKit layer, like the present/dismiss animations do.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissDragChanged(_:)),
            name: .tabSidebarDismissDragChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissDragCancelled),
            name: .tabSidebarDismissDragCancelled,
            object: nil
        )

        // Left-edge swipe-to-open: the window-level edge pan drives these.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBeginInteractiveOpen),
            name: .tabSidebarBeginInteractiveOpen,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenDragChanged(_:)),
            name: .tabSidebarOpenDragChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenDragCommit(_:)),
            name: .tabSidebarOpenDragCommit,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenDragCancel(_:)),
            name: .tabSidebarOpenDragCancel,
            object: nil
        )
    }

    /// During an interactive (edge-swipe) open the transform and backdrop are
    /// driven frame-by-frame by the drag notifications; suppress the core's
    /// auto-spring so flipping the binding true at gesture-begin does not fight
    /// the finger. Commit/cancel finishes the animation.
    override func applyPresentationChange(_ isPresented: Bool) {
        if isPresented {
            placeBesideTerminal()
            if !interactiveOpenActive { transformGeneration += 1 }
        }
        if interactiveOpenActive {
            view.isUserInteractionEnabled = false
            return
        }
        super.applyPresentationChange(isPresented)
    }

    override var effectiveWidth: CGFloat {
#if targetEnvironment(macCatalyst)
        super.effectiveWidth
#else
        let width = view.bounds.width
        return min(panelWidth, max(0, width * 0.72))
#endif
    }

    override func animatePresentationChange(_ isPresented: Bool) {
#if targetEnvironment(macCatalyst)
        super.animatePresentationChange(isPresented)
#else
        let window = view.window
        let animationOwner = transformOwner
        let duration = isPresented ? 0.4 : (hostingController.view.transform != .identity ? 0.4 : 0.25)
        let rootState = window.flatMap { window in
            terminalWindowContent(in: window).map { state(for: window, rootView: $0) }
        }
        if isPresented, rootState != nil {
            rootState?.owners.insert(transformOwner)
        }

        super.animatePresentationChange(isPresented)
        guard rootState != nil else { return }

        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: isPresented ? 0.86 : 1,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, isPresented ? .curveEaseOut : .curveEaseIn]
        ) {
            self.setTerminalViewProgress(isPresented ? 1 : 0, animated: true)
        } completion: { _ in
            if !isPresented { self.releaseTerminalTransform(owner: animationOwner, from: window) }
        }
#endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
#if !targetEnvironment(macCatalyst)
        if let window = view.window,
           let rootView = terminalWindowContent(in: window),
           rootView.bounds != lastTerminalBounds {
            lastTerminalBounds = rootView.bounds
            if visibleProgress > 0 { setTerminalViewProgress(visibleProgress) }
        }
#endif
    }

    @objc
    private func handleDismissDragChanged(_ note: Notification) {
        guard currentPresented,
              let offset = note.userInfo?["offset"] as? CGFloat else { return }
        hostingController.view.transform = CGAffineTransform(translationX: 0, y: max(0, offset))
    }

    @objc
    private func handleDismissDragCancelled() {
        guard currentPresented else { return }
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.hostingController.view.transform = .identity
        }
    }

    // MARK: - Interactive edge-swipe open

    /// The edge-swipe notifications are posted with the originating window as
    /// `object`; ignore posts meant for a different scene's overlay.
    private func isForThisWindow(_ note: Notification) -> Bool {
        guard let noteWindow = note.object as? UIWindow else { return true }
        return noteWindow === view.window
    }

    /// A drag with no edge is the leading drawer. Each overlay ignores the other edge.
    private func matchesEdge(_ note: Notification) -> Bool {
        guard isForThisWindow(note) else { return false }
        guard let raw = note.userInfo?["edge"] as? String else { return edge == .leading }
        switch edge {
        case .leading: return raw == "leading"
        case .trailing: return raw == "trailing"
        }
    }

    @objc
    private func handleBeginInteractiveOpen(_ note: Notification) {
        guard matchesEdge(note) else { return }
        placeBesideTerminal()
        interactiveOpenActive = true
        transformGeneration += 1
        visibleProgress = 0
        // Sit fully hidden; the drag notifications drive the panel in. Content
        // is (re)populated by `update(isPresented:)` when the coordinator flips
        // the binding true immediately after this post.
        hostingController.view.transform = panelTransform(progress: 0)
        backdropView.alpha = 0
        setTerminalViewProgress(0)
        // Visual-only during the drag — the window edge-pan owns the finger.
        view.isUserInteractionEnabled = false
    }

    private func placeBesideTerminal() {
        guard let window = view.window, view.superview === window,
              let rootView = terminalWindowContent(in: window),
              rootView.superview === window else { return }
        placeSidebarOverlay(view, in: window)
    }

    @objc
    private func handleOpenDragChanged(_ note: Notification) {
        guard interactiveOpenActive, matchesEdge(note),
              let progress = note.userInfo?["progress"] as? CGFloat else { return }
        let p = max(0, min(1, progress))
        visibleProgress = p
        hostingController.view.transform = panelTransform(progress: p)
        backdropView.alpha = p
        setTerminalViewProgress(p)
    }

    @objc
    private func handleOpenDragCommit(_ note: Notification) {
        guard interactiveOpenActive, matchesEdge(note) else { return }
        interactiveOpenActive = false
        currentPresented = true
        view.isUserInteractionEnabled = true
#if !targetEnvironment(macCatalyst)
        let rootState = view.window.flatMap { window in
            terminalWindowContent(in: window).map { state(for: window, rootView: $0) }
        }
        rootState?.owners.insert(transformOwner)
#endif
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.visibleProgress = 1
            self.hostingController.view.transform = .identity
            self.backdropView.alpha = 1
            self.setTerminalViewProgress(1, animated: true)
        }
    }

    @objc
    private func handleOpenDragCancel(_ note: Notification) {
        guard interactiveOpenActive, matchesEdge(note) else { return }
        interactiveOpenActive = false
        // Settle currentPresented false BEFORE the coordinator's binding write
        // lands, so the resulting update(isPresented:false) early-returns
        // instead of animating to hidden a second time.
        currentPresented = false
        let animationOwner = transformOwner
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseIn]
        ) {
            self.visibleProgress = 0
            self.hostingController.view.transform = self.hiddenTransform
            self.backdropView.alpha = 0
            self.setTerminalViewProgress(0, animated: true)
        } completion: { _ in
            self.releaseTerminalTransform(owner: animationOwner, from: self.view.window)
            if !self.currentPresented {
                self.view.isUserInteractionEnabled = false
            }
        }
    }

    // MARK: - Swipe-to-close

    @objc
    private func handleClosePan(_ gesture: UIPanGestureRecognizer) {
        guard currentPresented, !interactiveOpenActive else { return }
        let translation = gesture.translation(in: view)
        let width = effectiveWidth
        guard width > 0 else { return }

        switch gesture.state {
        case .began:
            Ghostty.logger.info("Edge sidebar close drag begin edge=\(self.edge == .leading ? "leading" : "trailing", privacy: .public)")

        case .changed:
            let progress = max(0, min(1, closingDistance(translation.x) / width))
            visibleProgress = 1 - progress
            hostingController.view.transform = panelTransform(progress: 1 - progress)
            backdropView.alpha = 1 - progress
            setTerminalViewProgress(1 - progress)

        case .ended:
            let velocity = gesture.velocity(in: view)
            let shouldDismiss = closingDistance(translation.x) > width / 3 || closingDistance(velocity.x) > 800
            if shouldDismiss {
                let edgeName = edge == .leading ? "leading" : "trailing"
                Ghostty.logger.info("Edge sidebar drag close edge=\(edgeName, privacy: .public)")
                // Hand off to the canonical dismiss (binding → update →
                // animatePresentationChange) which slides the panel the rest
                // of the way from its current position (.beginFromCurrentState).
                onClose?()
            } else {
                springPanelBackToOpen()
            }

        case .cancelled, .failed:
            springPanelBackToOpen()

        default:
            break
        }
    }

    private func springPanelBackToOpen() {
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.visibleProgress = 1
            self.hostingController.view.transform = .identity
            self.backdropView.alpha = 1
            self.setTerminalViewProgress(1, animated: true)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Positive when the drag moves the panel back off its edge.
    private func closingDistance(_ x: CGFloat) -> CGFloat {
        edge == .leading ? -x : x
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let insideHostedPanel = touch.view?.isDescendant(of: hostingController.view) == true
        if gestureRecognizer === closePanGesture {
            Ghostty.logger.debug("Edge sidebar close touch edge=\(self.edge == .leading ? "leading" : "trailing", privacy: .public) insidePanel=\(insideHostedPanel) point=\(String(describing: touch.location(in: touch.window)), privacy: .public)")
            return !insideHostedPanel
        }
        if gestureRecognizer === outsideTapGesture {
            return currentPresented && !insideHostedPanel
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === outsideTapGesture { return currentPresented && !interactiveOpenActive }
        guard gestureRecognizer === closePanGesture,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        // Claim only a clearly horizontal closing drag so the tab list's
        // vertical scroll, taps, and drag-to-reorder stay untouched.
        guard currentPresented, !interactiveOpenActive else { return false }
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        let horizontalIntent = abs(translation.x) > abs(translation.y)
            || abs(velocity.x) > abs(velocity.y)
        let closing = closingDistance(translation.x) > 0 || closingDistance(velocity.x) > 0
        return horizontalIntent && closing
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
#if !targetEnvironment(macCatalyst)
        guard currentPresented, !interactiveOpenActive,
              gestureRecognizer === closePanGesture || gestureRecognizer === outsideTapGesture,
              let window = view.window,
              let terminalContent = terminalWindowContent(in: window),
              let otherView = otherGestureRecognizer.view else { return false }
        return otherView === terminalContent || otherView.isDescendant(of: terminalContent)
#else
        return false
#endif
    }

    @objc
    private func handleOutsideTap() {
        guard currentPresented else { return }
        Ghostty.logger.info("Edge sidebar backdrop tap close edge=\(self.edge == .leading ? "leading" : "trailing", privacy: .public)")
        onClose?()
    }

    func installCloseGesture(on window: UIWindow) {
#if !targetEnvironment(macCatalyst)
        if let closePanGesture, closePanGesture.view !== window {
            closePanGesture.view?.removeGestureRecognizer(closePanGesture)
            window.addGestureRecognizer(closePanGesture)
        }
        if let outsideTapGesture, outsideTapGesture.view !== window {
            outsideTapGesture.view?.removeGestureRecognizer(outsideTapGesture)
            window.addGestureRecognizer(outsideTapGesture)
        }
        // An initially open drawer can be presented before its window attaches.
        if currentPresented, !interactiveOpenActive, visibleProgress == 0 {
            setTerminalViewProgress(1)
        }
#endif
    }

    func detachFromWindow(_ window: UIWindow?) {
#if !targetEnvironment(macCatalyst)
        guard let window else { return }
        if let closePanGesture, closePanGesture.view === window {
            window.removeGestureRecognizer(closePanGesture)
        }
        if let outsideTapGesture, outsideTapGesture.view === window {
            window.removeGestureRecognizer(outsideTapGesture)
        }
        releaseTerminalTransforms(from: window)
#endif
    }

    private struct TransformOwner: Hashable {
        let controller: ObjectIdentifier
        let generation: Int
    }

    private var transformOwner: TransformOwner {
        TransformOwner(controller: ObjectIdentifier(self), generation: transformGeneration)
    }

    override var hiddenTransform: CGAffineTransform {
#if targetEnvironment(macCatalyst)
        super.hiddenTransform
#else
        CGAffineTransform(translationX: edge == .leading ? -effectiveWidth : effectiveWidth, y: 0)
#endif
    }

#if !targetEnvironment(macCatalyst)
    @MainActor
    private final class WindowTransformState {
        struct ChildLayerState {
            weak var layer: CALayer?
            let cornerRadius: CGFloat
            let masksToBounds: Bool

            init(_ layer: CALayer) {
                self.layer = layer
                cornerRadius = layer.cornerRadius
                masksToBounds = layer.masksToBounds
            }
        }

        struct ViewState {
            weak var view: UIView?
            let sublayerTransform: CATransform3D
            let backgroundColor: UIColor?
            var childLayers: [ChildLayerState]

            init(_ view: UIView) {
                self.view = view
                sublayerTransform = view.layer.sublayerTransform
                backgroundColor = view.backgroundColor
                childLayers = view.subviews.map { ChildLayerState($0.layer) }
            }

            mutating func captureNewChildLayers() {
                guard let view else { return }
                for childView in view.subviews {
                    let alreadyCaptured = childLayers.contains { saved in
                        guard let layer = saved.layer else { return false }
                        return layer === childView.layer
                    }
                    if !alreadyCaptured {
                        childLayers.append(ChildLayerState(childView.layer))
                    }
                }
            }

            func apply(
                transform: CGAffineTransform,
                progress: CGFloat,
                backgroundColor: UIColor?,
                disableActions: Bool
            ) {
                guard let view else { return }
                if disableActions {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                }
                view.layer.sublayerTransform = CATransform3DConcat(
                    sublayerTransform,
                    CATransform3DMakeAffineTransform(transform)
                )
                if let backgroundColor {
                    view.backgroundColor = backgroundColor
                }
                for saved in childLayers {
                    saved.layer?.cornerRadius = 18 * progress
                    saved.layer?.masksToBounds = true
                }
                if disableActions {
                    CATransaction.commit()
                }
            }

            func restore(disableActions: Bool = true) {
                guard let view else { return }
                if disableActions {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                }
                view.layer.sublayerTransform = sublayerTransform
                view.backgroundColor = backgroundColor
                for saved in childLayers {
                    saved.layer?.cornerRadius = saved.cornerRadius
                    saved.layer?.masksToBounds = saved.masksToBounds
                }
                if disableActions {
                    CATransaction.commit()
                }
            }
        }

        var originalBounds: CGRect
        var appliedTransform = CGAffineTransform.identity
        var visibleProgress: CGFloat = 0
        var revealBackgroundColor: UIColor?
        var views: [ViewState]
        var owners = Set<TransformOwner>()

        init(rootView: UIView) {
            originalBounds = rootView.bounds
            let fullScreenViews = rootView.window?.subviews.filter { $0 is PaneFullScreenContainerView } ?? []
            views = ([rootView] + fullScreenViews).map(ViewState.init)
        }

        func restore(disableActions: Bool = true) {
            for saved in views {
                saved.restore(disableActions: disableActions)
            }
            appliedTransform = .identity
            visibleProgress = 0
            revealBackgroundColor = nil
        }
    }

    @MainActor
    private enum WindowTransformStates {
        static var values: [ObjectIdentifier: WindowTransformState] = [:]
    }

    static func includeWindowContent(_ content: UIView, in window: UIWindow) {
        guard let state = WindowTransformStates.values[ObjectIdentifier(window)],
              terminalWindowContent(in: window) != nil,
              !state.views.contains(where: { $0.view === content }) else { return }
        var contentState = WindowTransformState.ViewState(content)
        contentState.captureNewChildLayers()
        contentState.apply(
            transform: state.appliedTransform,
            progress: state.visibleProgress,
            backgroundColor: state.revealBackgroundColor,
            disableActions: true
        )
        state.views.append(contentState)
    }

    private func state(for window: UIWindow, rootView: UIView) -> WindowTransformState {
        let key = ObjectIdentifier(window)
        if let state = WindowTransformStates.values[key] { return state }
        let state = WindowTransformState(rootView: rootView)
        WindowTransformStates.values[key] = state
        return state
    }
#endif

    func updateRevealBackgroundColor(_ color: UIColor) {
        revealBackgroundColor = color
        if visibleProgress > 0 { setTerminalViewProgress(visibleProgress) }
    }

    private func setTerminalViewProgress(_ rawProgress: CGFloat, animated: Bool = false) {
#if !targetEnvironment(macCatalyst)
        guard let window = view.window,
              let rootView = terminalWindowContent(in: window) else { return }
        let progress = min(1, max(0, rawProgress))
        visibleProgress = progress
        guard progress > 0 || WindowTransformStates.values[ObjectIdentifier(window)] != nil else { return }
        let state = state(for: window, rootView: rootView)
        state.originalBounds = rootView.bounds
        state.revealBackgroundColor = revealBackgroundColor
        if progress > 0 { state.owners.insert(transformOwner) }

        let width = state.originalBounds.width
        if progress == 0 {
            state.restore(disableActions: !animated)
        } else {
            let scale = 1 - 0.12 * progress
            let edgeInset = edge == .leading ? window.safeAreaInsets.left : window.safeAreaInsets.right
            let translation = max(0, (effectiveWidth + edgeInset) * progress - width * (1 - scale) / 2)
            let signedTranslation = edge == .leading ? translation : -translation
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: signedTranslation, ty: 0
            )
            state.appliedTransform = transform
            state.visibleProgress = progress
            for index in state.views.indices {
                state.views[index].captureNewChildLayers()
                state.views[index].apply(
                    transform: transform,
                    progress: progress,
                    backgroundColor: state.revealBackgroundColor,
                    disableActions: !animated
                )
            }
        }
        let originalSublayerTransform = state.views.first { $0.view === rootView }?.sublayerTransform
        Ghostty.logger.debug(
            "Edge sidebar terminal view edge=\(self.edge == .leading ? "leading" : "trailing", privacy: .public) progress=\(progress, privacy: .public) window=\(String(describing: ObjectIdentifier(window)), privacy: .public) originalBounds=\(String(describing: state.originalBounds), privacy: .public) originalSublayerTransform=\(String(describing: originalSublayerTransform), privacy: .public) sublayerTransform=\(String(describing: rootView.layer.sublayerTransform), privacy: .public) viewTransform=\(String(describing: rootView.transform), privacy: .public)"
        )
#endif
    }

    private func releaseTerminalTransform(owner: TransformOwner, from window: UIWindow?) {
#if !targetEnvironment(macCatalyst)
        guard let window,
              terminalWindowContent(in: window) != nil,
              let state = WindowTransformStates.values[ObjectIdentifier(window)] else { return }
        state.owners.remove(owner)
        guard state.owners.isEmpty else { return }
        state.restore()
        WindowTransformStates.values.removeValue(forKey: ObjectIdentifier(window))
        visibleProgress = 0
#endif
    }

    private func releaseTerminalTransforms(from window: UIWindow) {
#if !targetEnvironment(macCatalyst)
        guard terminalWindowContent(in: window) != nil,
              let state = WindowTransformStates.values[ObjectIdentifier(window)] else { return }
        state.owners = state.owners.filter { $0.controller != ObjectIdentifier(self) }
        guard state.owners.isEmpty else { return }
        state.restore()
        WindowTransformStates.values.removeValue(forKey: ObjectIdentifier(window))
#endif
    }
}

// MARK: - Panel View

private struct TabSidebarPanelView<SidebarContent: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let edge: SidePanelEdge
    let themeColors: SheetThemeColors?
    let accentColor: Color?
    let colorScheme: ColorScheme?
    let onClose: () -> Void
    @ViewBuilder var sidebarContent: () -> SidebarContent

    // Matches the settings panel's width so the left/right panels read as a
    // symmetric pair.
    private let sidebarMaxWidth: CGFloat = 420
    private let sidebarCornerRadius: CGFloat = 20
    private let sidebarVerticalContentPadding: CGFloat = 6

    /// Liquid-glass look (Settings > Appearance > Window > Tab Bar): a
    /// material panel with a light theme tint, so the terminal shows
    /// through behind the tab list.
    @Setting(Settings.Sidebar.translucent) private var tabSidebarTranslucent

    @Setting(Settings.Window.hideTitleBar) private var hideWindowTitleBar

    /// With the title bar hidden the OS may still report a top safe-area
    /// inset for chrome that isn't there, leaving a gap above the panel;
    /// extend to the top edge like the main content does.
    private var hiddenTitlebarTopEdges: Edge.Set {
        #if targetEnvironment(macCatalyst)
        hideWindowTitleBar ? .top : []
        #else
        []
        #endif
    }

    private var sheetBackground: Color {
        themeColors?.background ?? Color(uiColor: .systemBackground)
    }

    private var usesCompactLayout: Bool {
        horizontalSizeClass != .regular
    }

    /// Round the corners on the terminal side. The screen edge stays square.
    private var panelShape: UnevenRoundedRectangle {
        let outer = sidebarCornerRadius
        if edge == .leading {
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: outer,
                topTrailingRadius: outer,
                style: .continuous
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: outer,
            bottomLeadingRadius: outer,
            bottomTrailingRadius: 0,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    @ViewBuilder
    private var panelBackground: some View {
#if targetEnvironment(macCatalyst)
        if tabSidebarTranslucent {
            panelShape.fill(.ultraThinMaterial)
            panelShape.fill(sheetBackground.opacity(0.3))
        } else {
            panelShape.fill(sheetBackground)
        }
#else
        Rectangle().fill(sheetBackground)
#endif
    }

    var body: some View {
        ZStack {
            sidebarContent()
                .environment(\.sheetThemeColors, themeColors)
                .padding(.top, sidebarVerticalContentPadding)
                .padding(.bottom, sidebarVerticalContentPadding)

            Button("") {
                onClose()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: sidebarMaxWidth)
        .frame(maxHeight: .infinity)
#if targetEnvironment(macCatalyst)
        .modifier(TabSidebarPanelClip(shape: panelShape, isEnabled: true))
        // Keep the fill behind the content so it can bleed under the home
        // indicator independently of the side-panel content clip above.
        .background {
            panelBackground
                .compositingGroup()
                .shadow(color: .black.opacity(0.3), radius: 20, x: edge == .leading ? 5 : -5, y: 0)
                .ignoresSafeArea(.container, edges: usesCompactLayout ? .bottom : [])
        }
#else
        // The drawer is a flush part of the shared surface. Only the terminal
        // content receives the floating rounded-card treatment.
        .background {
            panelBackground.ignoresSafeArea(.container, edges: .all)
        }
#endif
        .optionalColorSchemeEnvironment(colorScheme)
        .tint(accentColor)
        .ignoresSafeArea(.keyboard)
        .ignoresSafeArea(.container, edges: hiddenTitlebarTopEdges)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }
}

private struct TabSidebarPanelClip: ViewModifier {
    let shape: UnevenRoundedRectangle
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.clipShape(shape)
        } else {
            content
        }
    }
}

#endif
