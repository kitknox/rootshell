//
//  SidePanelOverlay.swift
//  rootshell
//
//  ONE deterministic side-panel presentation, shared by the settings,
//  connection, and tab sidebars. Deliberately NOT a fullScreenCover/sheet on
//  iPad/Catalyst: covers share UIKit's single-presentation slot, and a
//  present-while-dismissing race wedges the binding `true` with no presenter
//  mounted — the toggle then appears dead and rapid back-to-back presses get
//  eaten. The connection and tab sidebars already moved to this overlay model
//  for exactly that reason; this file is the common core they (and settings)
//  now share.
//
//  Determinism comes from three things, all inherited by every adopter:
//   1. The overlay view controller is mounted for the whole lifetime of the
//      host view (it lives in `.overlay { }`), so there is never a "no
//      presenter mounted" window.
//   2. `update(isPresented:)` is driven straight off a Bool binding that the
//      caller flips IMMEDIATELY — there is no gate and no deferred flip, so a
//      second press always registers.
//   3. Present/dismiss animate with `.beginFromCurrentState`, and the dismiss
//      completion is guarded on `currentPresented`, so a rapid re-open mid
//      dismiss reverses smoothly instead of stranding the panel.
//
//  Panels differ only by which edge they slide from (tab = leading, settings
//  and connection = trailing) plus a few flags — captured by `SidePanelEdge`
//  and the config properties below. Gesture-rich adopters (the tab sidebar)
//  subclass `SidePanelOverlayViewController` and layer their recognizers on
//  top of this core; gesture-free adopters use `SidePanelOverlay` directly.
//

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Which screen edge a panel anchors to and slides in from. On phone, an
/// adopter may opt into a bottom-sheet slide instead (see `allowPhoneBottom`).
enum SidePanelEdge {
    case leading
    case trailing
}

#if !os(visionOS)

// MARK: - Generic Representable (gesture-free panels)

/// Drop-in overlay for panels that need no custom gestures (settings,
/// connection). Place in `.overlay { }` on iPad/Catalyst; callers keep their
/// own `.sheet` for phone/visionOS.
struct SidePanelOverlay<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var edge: SidePanelEdge = .trailing
    var panelWidth: CGFloat = 420
    var backdropAlpha: CGFloat = 0.4
    /// Stable identity for the presented content; changing it while presented
    /// resets the hosted view (clears transient state like search text). Pass
    /// a constant when the panel has no such notion.
    var contentID: AnyHashable = 0
    var preventDismissal: Bool = false
    var resignFirstResponderOnDismiss: Bool = false
    /// Close the panel on the ESC key via a UIKit key command. Opt-in because
    /// the tab sidebar's search field must keep first responder. See the
    /// controller property for why this lives at the UIKit layer.
    var escapeDismisses: Bool = false
    @ViewBuilder var content: () -> Content

    private func makeOnCloseAction() -> () -> Void {
        let isPresented = $isPresented
        let preventDismissal = preventDismissal
        return {
            guard !preventDismissal else { return }
            isPresented.wrappedValue = false
        }
    }

    func makeUIViewController(context: Context) -> SidePanelOverlayViewController {
        let controller = SidePanelOverlayViewController()
        controller.edge = edge
        controller.resignFirstResponderOnDismiss = resignFirstResponderOnDismiss
        controller.escapeDismisses = escapeDismisses
        controller.onClose = makeOnCloseAction()
        // Gesture-free panels have no interactive open, so nothing needs the
        // content alive before the binding flips — safe to unmount when hidden.
        controller.unmountsContentWhenHidden = true
        return controller
    }

    func updateUIViewController(_ controller: SidePanelOverlayViewController, context: Context) {
        controller.edge = edge
        controller.resignFirstResponderOnDismiss = resignFirstResponderOnDismiss
        controller.escapeDismisses = escapeDismisses
        let onClose = makeOnCloseAction()
        controller.onClose = onClose

        controller.update(
            isPresented: isPresented,
            contentID: contentID,
            preventDismissal: preventDismissal,
            backdropAlpha: backdropAlpha,
            panelWidth: panelWidth,
            rootView: AnyView(content())
        )
    }
}

// MARK: - Core View Controller

/// The shared, deterministic overlay core. Gesture-free adopters use it via
/// `SidePanelOverlay`; gesture-rich adopters subclass it. Members the tab
/// subclass needs are `internal` (the default) rather than `private`.
class SidePanelOverlayViewController: UIViewController {
    let backdropView = UIControl()
    let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
    private var widthConstraint: NSLayoutConstraint?
    /// The VC's own notion of presented-ness, distinct from the binding. Only
    /// a genuine transition animates (`guard isPresented != currentPresented`).
    var currentPresented = false
    var panelWidth: CGFloat = 420
    private var presentationVersion = 0
    private var lastContentID: AnyHashable?

    // MARK: Config (set by the representable / subclass before the view loads)

    var edge: SidePanelEdge = .trailing
    /// Phone slides up from the bottom instead of in from `edge`.
    var allowPhoneBottom = false
    /// Width left visible on the other side of a compact drawer, so the
    /// terminal peeks out beside the panel.
    var compactPeek: CGFloat = 0
    /// Resign first responder at the UIKit layer the instant dismissal begins
    /// (a search field inside the still-mounted panel would otherwise keep the
    /// keyboard after the panel slides away).
    var resignFirstResponderOnDismiss = false
    /// Clear the iPadOS window controls (stoplights, top-leading) so a leading
    /// panel's header does not collide with them. Trailing panels never do.
    var clearsWindowControls = false

    /// Optional in-hierarchy view whose corner-adapted safe area should drive
    /// the panel's traffic-light clearance. The tab sidebar supplies its
    /// representable installer's view because its visible controller view is
    /// reparented directly onto UIWindow (above full-screen VNC content), where
    /// Catalyst no longer reports the original corner-adapted safe area.
    weak var windowControlsClearanceSourceView: UIView?

    /// Close on the ESC key via a UIKit key command. This lives at the UIKit
    /// layer (not SwiftUI) on purpose: the panel content's `.onKeyPress`/
    /// `.keyboardShortcut(.escape)` only fire while a SwiftUI view inside the
    /// panel owns focus, and an in-window overlay (unlike a fullScreenCover)
    /// has no first responder of its own when it opens — the terminal has just
    /// resigned and nothing in the overlay takes over. A UIKeyCommand on this
    /// VC, with the VC made first responder on present, works regardless of
    /// SwiftUI focus and on Mac Catalyst (where forcing hosting-controller
    /// focus is unreliable — see SidebarSearchField).
    var escapeDismisses = false

    /// Host `EmptyView` while the panel is fully dismissed. A "closed" panel
    /// is only translated offscreen — its hosting view stays in the window,
    /// fully live — so hidden content keeps ticking TimelineViews and
    /// re-rendering on `objectWillChange` churn, burning idle CPU. Gesture-free
    /// adopters opt in; the tab sidebar must stay false because its edge-swipe
    /// drags the panel in before the binding flips, so content has to exist
    /// while hidden. Behaviorally free for adopters: `presentationVersion`
    /// already resets hosted @State on every fresh open.
    var unmountsContentWhenHidden = false
    /// Whether the hosting controller currently holds caller content (vs the
    /// EmptyView placeholder).
    private var hostsLiveContent = false

    var onClose: (() -> Void)?

    private var usesCompactLayout: Bool {
        view.traitCollection.horizontalSizeClass != .regular
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.insetsLayoutMarginsFromSafeArea = false

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        backdropView.alpha = 0
        backdropView.addTarget(self, action: #selector(handleBackdropTap), for: .touchUpInside)
        view.addSubview(backdropView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleTextDidEndEditing(_:)),
            name: UITextField.textDidEndEditingNotification, object: nil
        )

        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.0, tvOS 16.0, *) {
            // The panel ignores keyboard safe-area changes, including iPad
            // floating/detached keyboards.
            hostingController.safeAreaRegions.remove(.keyboard)
        }
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        let widthConstraint = hostingController.view.widthAnchor.constraint(equalToConstant: effectiveWidth)
        self.widthConstraint = widthConstraint

        // Anchor the panel to its edge; the backdrop always fills the view.
        let horizontalAnchor: NSLayoutConstraint
        switch edge {
        case .leading:
            horizontalAnchor = hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor)
        case .trailing:
            horizontalAnchor = hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        }

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            horizontalAnchor,
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            widthConstraint
        ])

        applyHiddenState()
    }

    func update(
        isPresented: Bool,
        contentID: AnyHashable,
        preventDismissal: Bool,
        backdropAlpha: CGFloat,
        panelWidth: CGFloat,
        rootView: AnyView
    ) {
        backdropView.isEnabled = !preventDismissal
        backdropView.backgroundColor = UIColor.black.withAlphaComponent(backdropAlpha)

        if self.panelWidth != panelWidth {
            self.panelWidth = panelWidth
        }
        updateEffectiveWidth()

        // Bump the per-presentation identity on each fresh open, or when the
        // content identity changes while presented.
        if (!currentPresented && isPresented) || (currentPresented && lastContentID != contentID) {
            presentationVersion += 1
        }
        lastContentID = contentID
        // Reassign the hosted root view on EVERY update so live value inputs —
        // theme, tint, colour scheme, `onClose`, `preventDismissal` — propagate
        // while the panel is open (these are plain values; unlike @Observable
        // models they don't flow on their own). The stable `.id(identity)`
        // preserves the hosted view's own @State / navigation across benign
        // updates and resets it only when the identity bumps above (a fresh
        // open or a content-ID change).
        //
        // Unmounting adopters skip the assignment while steady-closed so the
        // hidden panel hosts only EmptyView. The `currentPresented` term keeps
        // content mounted through a dismiss slide-out (cleared by the dismiss
        // animation completion, not here, so mid-animation host updates can't
        // blank the departing panel).
        let identity = SidePanelPresentationIdentity(contentID: contentID, presentationVersion: presentationVersion)
        if !unmountsContentWhenHidden || isPresented || currentPresented {
            hostingController.rootView = AnyView(rootView.id(identity))
            hostsLiveContent = true
        }

        guard isPresented != currentPresented else { return }
        if !isPresented { dismissAnimationActive = true }
        currentPresented = isPresented
        applyPresentationChange(isPresented)
    }

    /// Overridable so gesture-rich subclasses can intercept (e.g. suppress the
    /// auto-spring while an interactive drag owns the transform).
    func applyPresentationChange(_ isPresented: Bool) {
        animatePresentationChange(isPresented)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateEffectiveWidth()
        if clearsWindowControls {
            updateWindowControlsClearance()
        }
        // A dismiss slide starts from the finger. Snapping here would jump the
        // panel to its hidden transform before that animation can run.
        if !currentPresented && !dismissAnimationActive {
            applyHiddenState()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if clearsWindowControls {
            updateWindowControlsClearance()
        }
    }

    /// iPadOS window controls (the stoplights, shown whenever the app is not
    /// full screen) float over the top-leading corner — where a leading
    /// panel's header sits. They are not part of the plain safe area; the
    /// corner-adapted layout region is the only public way to learn their
    /// extent. Full screen (and the phone) computes zero and nothing moves.
    func updateWindowControlsClearance() {
        guard #available(iOS 26.0, macCatalyst 26.0, *) else { return }
        guard let sourceView = windowControlsClearanceSourceView ?? viewIfLoaded else { return }
        #if targetEnvironment(macCatalyst)
        // Hidden-titlebar mode hides the window controls behind UIKit's back,
        // so the corner-adapted region still reports clearance for buttons
        // that aren't there. Force zero.
        let adaptedTop = SettingsStore.shared.get(Settings.Window.hideTitleBar)
            ? 0 : sourceView.edgeInsets(for: .safeArea(cornerAdaptation: .vertical)).top
        #else
        let adaptedTop = sourceView.edgeInsets(for: .safeArea(cornerAdaptation: .vertical)).top
        #endif
        // additionalSafeAreaInsets is added on top of the hosted view's plain
        // safe area. Remove our current contribution before comparing it with
        // the desired corner-adapted total; the source and destination views
        // need not have the same plain safe area after UIWindow reparenting.
        let currentExtra = hostingController.additionalSafeAreaInsets.top
        let hostedBaseTop = max(0, hostingController.view.safeAreaInsets.top - currentExtra)
        let extra = max(0, adaptedTop - hostedBaseTop)
        if hostingController.additionalSafeAreaInsets.top != extra {
            hostingController.additionalSafeAreaInsets.top = extra
        }
    }

    var effectiveWidth: CGFloat {
        let limit = view.bounds.width
        let available = usesCompactLayout ? max(0, limit - compactPeek) : limit
        return min(panelWidth, available)
    }

    private func updateEffectiveWidth() {
        if widthConstraint?.constant != effectiveWidth {
            widthConstraint?.constant = effectiveWidth
        }
    }

    @objc
    private func handleBackdropTap() {
        onClose?()
    }

    // MARK: - ESC key command

    override var canBecomeFirstResponder: Bool {
        escapeDismisses && currentPresented
    }

    override var keyCommands: [UIKeyCommand]? {
        guard escapeDismisses else { return super.keyCommands }
        return [
            UIKeyCommand(
                action: #selector(handleEscapeKeyCommand),
                input: UIKeyCommand.inputEscape,
                modifierFlags: []
            )
        ]
    }

    @objc
    private func handleEscapeKeyCommand() {
        onClose?()
    }

    /// Takes first responder for the ESC command only when nothing in the panel
    /// holds it; a focused field (e.g. a profile search) keeps its own keys.
    private func claimEscapeResponderIfUnfocused() {
        guard escapeDismisses, currentPresented, !panelHoldsFirstResponder else { return }
        // Pointless work while backgrounded. Not a secure-draw guard: this
        // controller has no inputView and only wires up ESC, so it cannot
        // present a keyboard. The panel's own keyboard-bearing field
        // (SidebarSearchField) carries that gate.
        guard UIApplication.shared.applicationState != .background else { return }
        becomeFirstResponder()
    }

    private var panelHoldsFirstResponder: Bool {
        func holds(_ view: UIView) -> Bool { view.isFirstResponder || view.subviews.contains(where: holds) }
        return holds(hostingController.view)
    }

    /// A panel field losing focus (tab switch, Return) leaves no responder; reclaim ESC.
    @objc
    private func handleTextDidEndEditing(_ notification: Notification) {
        guard escapeDismisses,
              let field = notification.object as? UIView,
              field.isDescendant(of: hostingController.view) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.claimEscapeResponderIfUnfocused()
        }
    }

    /// Fully-hidden transform for the current edge. Phone bottom-sheet adopters
    /// drop the panel off the bottom; everyone else slides it past its edge.
    var hiddenTransform: CGAffineTransform {
        if allowPhoneBottom && usesCompactLayout {
            return CGAffineTransform(translationX: 0, y: view.bounds.height + 40)
        }
        switch edge {
        case .leading:
            return CGAffineTransform(translationX: -(effectiveWidth + 40), y: 0)
        case .trailing:
            return CGAffineTransform(translationX: effectiveWidth + 40, y: 0)
        }
    }

    /// Interpolates the panel between fully hidden (`progress` 0) and identity
    /// (`progress` 1). Shared by interactive open/close drags.
    func panelTransform(progress: CGFloat) -> CGAffineTransform {
        let hidden = hiddenTransform
        let inverse = 1 - max(0, min(1, progress))
        return CGAffineTransform(translationX: hidden.tx * inverse, y: hidden.ty * inverse)
    }

    /// True while a dismiss animation owns the panel transform.
    private var dismissAnimationActive = false

    func animatePresentationChange(_ isPresented: Bool) {
        let hiddenTransform = self.hiddenTransform

        if isPresented {
            view.isUserInteractionEnabled = true
            hostingController.view.transform = hiddenTransform
            backdropView.alpha = 0

            UIView.animate(
                withDuration: 0.4,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.backdropView.alpha = 1
                self.hostingController.view.transform = .identity
            }

            // Become first responder so the ESC key command above is on the
            // active responder chain. Deferred a runloop turn so it lands AFTER
            // the host's synchronous `resignFirstResponder` broadcast (settings
            // opening resigns the terminal in the same update cycle); grabbing
            // it synchronously here would just be resigned again. The guard
            // cancels the pending grab if a rapid re-close already happened.
            if escapeDismisses {
                DispatchQueue.main.async { [weak self] in
                    self?.claimEscapeResponderIfUnfocused()
                }
            }
        } else {
            dismissAnimationActive = true
            if escapeDismisses && isFirstResponder {
                // Release first responder so the host can reconcile it back to
                // the terminal (restoreFirstResponderAfterSheetDismissal).
                resignFirstResponder()
            }
            if resignFirstResponderOnDismiss {
                hostingController.view.endEditing(true)
            }
            let continuingDrag = hostingController.view.transform != .identity
            let animations = {
                self.backdropView.alpha = 0
                self.hostingController.view.transform = hiddenTransform
            }
            let completion: (Bool) -> Void = { _ in
                self.dismissAnimationActive = false
                // A rapid re-open can land before the dismiss animation
                // finishes; ignore that stale completion so the reopened panel
                // does not become visually present but non-interactive.
                if !self.currentPresented {
                    self.view.isUserInteractionEnabled = false
                    self.applyHiddenState()
                    self.clearHostedContentIfUnmounting()
                }
            }
            if continuingDrag {
                UIView.animate(
                    withDuration: 0.4,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
                    animations: animations,
                    completion: completion
                )
            } else {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseIn],
                    animations: animations,
                    completion: completion
                )
            }
        }
    }

    func applyHiddenState() {
        hostingController.view.transform = hiddenTransform
        backdropView.alpha = 0
    }

    /// Swap the hosted content for `EmptyView` once a dismissal has fully
    /// settled, so the offscreen panel stops rendering. Guarded on
    /// `currentPresented` for the same rapid-reopen race as the caller.
    func clearHostedContentIfUnmounting() {
        guard unmountsContentWhenHidden, hostsLiveContent, !currentPresented else { return }
        hostingController.rootView = AnyView(EmptyView())
        hostsLiveContent = false
    }
}

private struct SidePanelPresentationIdentity: Hashable {
    let contentID: AnyHashable
    let presentationVersion: Int
}

#endif
