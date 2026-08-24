//
//  ExternalDisplayWindow.swift
//  rootshell
//
//  Window stack for external (non-interactive) display support. The
//  ExternalWindow lives natively in the external scene and hosts the real
//  MainView through a zoom container. Control mode re-parents the hosted
//  controller's view into a ControlSurfaceWindow on the device (view
//  re-parenting is reliable; window-layer re-attachment is not).
//

import SwiftUI
import UIKit

#if !targetEnvironment(macCatalyst)
/// The window attached to the external display's scene. Never key.
final class ExternalWindow: UIWindow {}

/// Interactive device window shown during control mode. Hosts the real
/// external content, aspect-fit scaled, above the device UI. It MUST be key
/// while active: hardware key events route through the key window's
/// responder chain.
final class ControlSurfaceWindow: UIWindow {}

/// Hosts the external MainView. Named without "HostingController" on purpose:
/// StatusBarStyleController/ImmersiveChromeManager swizzle by that substring.
final class ExternalDisplayRootController: UIHostingController<ExternalDisplayRootView> {
    override var canBecomeFirstResponder: Bool { false }
    override var prefersStatusBarHidden: Bool { true }

    override init(rootView: ExternalDisplayRootView) {
        super.init(rootView: rootView)
        // The hosted UI lays out for the external screen (no safe areas).
        // Device-window insets during control mode must not reflow it.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Root VC implementing display zoom: hosts the SwiftUI content as a child at
/// reduced logical bounds (native / zoomFactor) scaled back up by a transform
/// on the child (never the window). Terminals compensate via effectiveScale.
final class ExternalZoomContainerController: UIViewController {
    enum FitMode {
        /// Parked: fill the external screen (scale = zoom).
        case externalZoom
        /// Control mode: aspect-fit the same reduced-logical content onto the
        /// device screen. Child bounds never change, so zero terminal reflow.
        case deviceFit
    }

    /// Nil while control mode has moved the content into another container.
    private(set) var hostingController: ExternalDisplayRootController?

    /// External display's native logical size (not the window frame, which
    /// is device-sized in control mode).
    var externalNativeSize: CGSize {
        didSet {
            guard externalNativeSize != oldValue else { return }
            view.setNeedsLayout()
        }
    }

    var fitMode: FitMode = .externalZoom {
        didSet {
            guard fitMode != oldValue else { return }
            view.setNeedsLayout()
        }
    }

    var zoomFactor: CGFloat {
        didSet {
            guard zoomFactor != oldValue else { return }
            applyDisplayScaleTraitOverride()
            view.setNeedsLayout()
        }
    }

    /// The reduced-logical coordinate space all external UI lives in.
    var contentView: UIView? { hostingController?.view }

    init(hostingController: ExternalDisplayRootController?, zoomFactor: CGFloat, externalNativeSize: CGSize) {
        self.hostingController = hostingController
        self.zoomFactor = zoomFactor
        self.externalNativeSize = externalNativeSize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { false }
    override var prefersStatusBarHidden: Bool { true }

    private var keyboardOverlap: CGFloat = 0
    private var controlBar: UIView?
    // nonisolated(unsafe): only mutated on main; deinit must remove them.
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private static let controlBarHeight: CGFloat = 44

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.insetsLayoutMarginsFromSafeArea = false
        if let hostingController {
            addChild(hostingController)
            view.addSubview(hostingController.view)
            hostingController.didMove(toParent: self)
        }
        applyDisplayScaleTraitOverride()
        observeKeyboard()
    }

    private func observeKeyboard() {
        let apply: (CGRect?) -> Void = { [weak self] endFrame in
            guard let self, self.isViewLoaded, let window = self.view.window else { return }
            var overlap: CGFloat = 0
            if let endFrame {
                let frameInWindow = window.convert(endFrame, from: nil)
                overlap = max(0, window.bounds.maxY - frameInWindow.minY)
            }
            if self.keyboardOverlap != overlap {
                self.keyboardOverlap = overlap
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
            }
        }
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
        ) { notification in
            let endFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated { apply(endFrame) }
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { apply(nil) }
        })
    }

    /// The keyboard can already be up when control mode starts, so read the
    /// tracker's live frame rather than waiting for a change notification.
    private func refreshKeyboardOverlapFromCurrentFrame() {
        guard fitMode == .deviceFit, let window = view.window else { return }
        let frame = KeyboardTracker.shared.keyboardFrame
        var overlap: CGFloat = 0
        if !frame.isNull, !frame.isEmpty, KeyboardTracker.shared.isSoftwareKeyboardVisible {
            let frameInWindow = window.convert(frame, from: nil)
            overlap = max(0, window.bounds.maxY - frameInWindow.minY)
        }
        keyboardOverlap = overlap
    }

    /// Always-visible bar on the control surface: identifies the mode and
    /// guarantees a reachable exit even when the scaled chrome is tiny.
    private func ensureControlBar() -> UIView {
        if let controlBar { return controlBar }
        let bar = UIView()
        bar.backgroundColor = UIColor(white: 0.1, alpha: 1)

        let icon = UIImageView(image: UIImage(systemName: "tv.fill"))
        icon.tintColor = .systemBlue
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = String(localized: "External Display", comment: "Control surface bar: mode label")
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontSizeToFitWidth = true

        var config = UIButton.Configuration.filled()
        config.title = String(localized: "Back to Device", comment: "Control surface bar: return typing focus to the device")
        config.buttonSize = .small
        config.cornerStyle = .capsule
        let back = UIButton(configuration: config, primaryAction: UIAction { _ in
            ExternalDisplayManager.shared.setFocus(.device)
        })
        back.setContentHuggingPriority(.required, for: .horizontal)
        back.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [icon, title, back])
        stack.axis = .horizontal
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        view.addSubview(bar)
        controlBar = bar
        return bar
    }

    /// Control-mode handoff: release the hosted content so another container
    /// can adopt it.
    func detachHostedContent() -> ExternalDisplayRootController? {
        guard let hosted = hostingController else { return nil }
        hostingController = nil
        hosted.willMove(toParent: nil)
        hosted.view.removeFromSuperview()
        hosted.removeFromParent()
        return hosted
    }

    func attachHostedContent(_ hosted: ExternalDisplayRootController) {
        guard hostingController == nil else { return }
        hostingController = hosted
        loadViewIfNeeded()
        addChild(hosted)
        view.addSubview(hosted.view)
        hosted.didMove(toParent: self)
        applyDisplayScaleTraitOverride()
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        guard let hostingController else { return }
        let native = externalNativeSize
        guard native.width > 0, native.height > 0, zoomFactor > 0 else { return }
        // Pixel-align the reduced size on the effective-scale grid so the
        // scaled-up composite lands on integral panel pixels.
        let effScale = ExternalDisplayManager.shared.externalScreenScale * zoomFactor
        let reduced = CGSize(
            width: (native.width / zoomFactor * effScale).rounded(.down) / effScale,
            height: (native.height / zoomFactor * effScale).rounded(.down) / effScale
        )
        let child = hostingController.view!
        child.bounds = CGRect(origin: .zero, size: reduced)
        switch fitMode {
        case .externalZoom:
            controlBar?.isHidden = true
            child.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            child.transform = CGAffineTransform(scaleX: zoomFactor, y: zoomFactor)
        case .deviceFit:
            guard reduced.width > 0, reduced.height > 0 else { return }
            // A first pass before the window has real bounds would bake a
            // degenerate zero-scale transform; UIKit lays out again once sized.
            guard view.bounds.width > 1, view.bounds.height > 1 else { return }
            refreshKeyboardOverlapFromCurrentFrame()
            let safeTop = view.safeAreaInsets.top
            let bar = ensureControlBar()
            bar.isHidden = false
            let available = CGRect(
                x: 0,
                y: safeTop,
                width: view.bounds.width,
                height: max(1, view.bounds.height - safeTop - keyboardOverlap - Self.controlBarHeight)
            )
            let scale = min(available.width / reduced.width, available.height / reduced.height)
            child.transform = CGAffineTransform(scaleX: scale, y: scale)
            let fitHeight = reduced.height * scale
            child.center = CGPoint(
                x: available.midX,
                y: available.minY + fitHeight / 2
            )
            bar.frame = CGRect(
                x: 0,
                y: available.minY + fitHeight,
                width: view.bounds.width,
                height: Self.controlBarHeight
            )
        }
    }

    /// Chrome rasterizes at the trait displayScale; overriding it to the
    /// composited density keeps it crisp under the zoom transform and makes
    /// traitCollection.displayScale inside the external tree equal
    /// effectiveScale.
    private func applyDisplayScaleTraitOverride() {
        guard let hostingController else { return }
        let scale = ExternalDisplayManager.shared.externalScreenScale * zoomFactor
        setOverrideTraitCollection(
            UITraitCollection(displayScale: scale),
            forChild: hostingController
        )
    }
}

struct ExternalDisplayRootView: View {
    @ObservedObject var ghosttyApp: Ghostty.App
    @StateObject private var appearanceManager = AppearanceManager.shared

    var body: some View {
        MainView(overrideWindowId: ExternalDisplay.windowId)
            .environmentObject(ghosttyApp)
            .preferredColorScheme(appearanceManager.colorScheme)
            .ignoresSafeArea()
    }
}
#endif
