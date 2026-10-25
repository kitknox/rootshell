//
//  TabSidebarPresentation.swift
//  rootshell
//
//  Presents an edge sidebar:
//  - iPhone and iPad/Catalyst: UIKit overlay on the leading or trailing
//    edge. The phone drawer leaves a peek of the terminal. Deliberately
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

    func makeUIViewController(context: Context) -> TabSidebarOverlayInstallerViewController {
        let overlayController = TabSidebarOverlayViewController()
        // Slide in from this edge. Compact width keeps a peek of the terminal.
        // Only a leading panel clears the top-leading window controls.
        overlayController.edge = edge
        overlayController.allowPhoneBottom = false
        overlayController.compactPeek = 48
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

        controller.update(
            isPresented: showSidebar,
            contentID: 0,
            preventDismissal: preventDismissal,
            backdropAlpha: tabSidebarTranslucent ? 0.12 : (themeColors != nil ? 0.4 : 0.5),
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

/// The representable itself remains in MainView's hierarchy, but its visible
/// overlay is installed directly on the host window. This makes the sidebar a
/// sibling of window-level takeovers (notably VNC full screen), so it can be
/// raised above them without detaching or resizing the live pane underneath.
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
        if installedWindow === window, overlayController.view.superview === window {
            overlayController.view.frame = window.bounds
            return
        }

        detachOverlay()
        overlayController.view.frame = window.bounds
        overlayController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        installedWindow = window
        window.addSubview(overlayController.view)
    }

    func detachOverlay() {
        guard overlayController.view.superview != nil else {
            installedWindow = nil
            return
        }
        overlayController.view.removeFromSuperview()
        installedWindow = nil
    }
}

private final class TabSidebarOverlayViewController: SidePanelOverlayViewController, UIGestureRecognizerDelegate {
    /// True while a left-edge swipe is interactively dragging the panel in.
    /// Suppresses the auto-spring in `applyPresentationChange`.
    private var interactiveOpenActive = false
    /// Drag the open panel back off its edge. The recognizer sits on the
    /// overlay, not the panel, so the panel transform does not move the
    /// gesture's coordinate space.
    private var closePanGesture: UIPanGestureRecognizer?

    override func viewDidLoad() {
        // The shared core mounts the backdrop + hosting view, wires the
        // backdrop tap, and applies the hidden state. Layer this panel's
        // interactive gestures on top.
        super.viewDidLoad()

        // Keep the recognizer installed through resizes; its delegate gates
        // side dismissal on the current width class.
        let closePan = UIPanGestureRecognizer(target: self, action: #selector(handleClosePan(_:)))
        closePan.delegate = self
        closePan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(closePan)
        self.closePanGesture = closePan

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
            elevateAboveWindowContent()
        }
        if interactiveOpenActive {
            view.isUserInteractionEnabled = false
            return
        }
        super.applyPresentationChange(isPresented)
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
        elevateAboveWindowContent()
        interactiveOpenActive = true
        // Sit fully hidden; the drag notifications drive the panel in. Content
        // is (re)populated by `update(isPresented:)` when the coordinator flips
        // the binding true immediately after this post.
        hostingController.view.transform = panelTransform(progress: 0)
        backdropView.alpha = 0
        // Visual-only during the drag — the window edge-pan owns the finger.
        view.isUserInteractionEnabled = false
    }

    /// The VNC full-screen container is another direct child of this window.
    /// Raising this transparent overlay keeps the pane live and full-sized
    /// while the panel and its backdrop render and receive input above it.
    private func elevateAboveWindowContent() {
        guard let window = view.window, view.superview === window else { return }
        window.bringSubviewToFront(view)
    }

    @objc
    private func handleOpenDragChanged(_ note: Notification) {
        guard interactiveOpenActive, matchesEdge(note),
              let progress = note.userInfo?["progress"] as? CGFloat else { return }
        let p = max(0, min(1, progress))
        hostingController.view.transform = panelTransform(progress: p)
        backdropView.alpha = p
    }

    @objc
    private func handleOpenDragCommit(_ note: Notification) {
        guard interactiveOpenActive, matchesEdge(note) else { return }
        interactiveOpenActive = false
        currentPresented = true
        view.isUserInteractionEnabled = true
        UIView.animate(
            withDuration: 0.4,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) {
            self.hostingController.view.transform = .identity
            self.backdropView.alpha = 1
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
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseIn]
        ) {
            self.hostingController.view.transform = self.hiddenTransform
            self.backdropView.alpha = 0
        } completion: { _ in
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
        case .changed:
            let progress = max(0, min(1, closingDistance(translation.x) / width))
            hostingController.view.transform = panelTransform(progress: 1 - progress)
            backdropView.alpha = 1 - progress

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
            self.hostingController.view.transform = .identity
            self.backdropView.alpha = 1
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Positive when the drag moves the panel back off its edge.
    private func closingDistance(_ x: CGFloat) -> CGFloat {
        edge == .leading ? -x : x
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === closePanGesture else { return true }
        let insideHostedPanel = touch.view?.isDescendant(of: hostingController.view) == true
        Ghostty.logger.debug("Edge sidebar close touch edge=\(self.edge == .leading ? "leading" : "trailing", privacy: .public) insidePanel=\(insideHostedPanel)")
        return !insideHostedPanel
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
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
        if tabSidebarTranslucent {
            panelShape.fill(.ultraThinMaterial)
            panelShape.fill(sheetBackground.opacity(0.3))
        } else {
            panelShape.fill(sheetBackground)
        }
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
        .modifier(TabSidebarPanelClip(shape: panelShape, isEnabled: true))
        // Keep the fill behind the content so it can bleed under the home
        // indicator independently of the side-panel content clip above.
        .background {
            panelBackground
                .compositingGroup()
                .shadow(color: .black.opacity(0.3), radius: 20, x: edge == .leading ? 5 : -5, y: 0)
                .ignoresSafeArea(.container, edges: usesCompactLayout ? .bottom : [])
        }
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
