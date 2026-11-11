//
//  PaneFullScreenController.swift
//  rootshell
//
//  In-window full-screen takeover for remote-screen panes (VNC, KVM): reparents the live pane
//  into a window-bounds black container (hosting controller, viewport state,
//  single-parented HEVC layer, and session all preserved) and hands it back
//  to normal split layout on exit.
//

import SwiftUI
import UIKit
import os
import rootshellVNC

/// One per window (held as MainView @State, like MainAlertController).
/// Owns the takeover container and every exit path: HUD toggle, Cmd-Shift-F,
/// connection-failure overlay, pane close, tab switch, pane orphaned, and
/// window retarget.
@MainActor
final class PaneFullScreenController {

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "PaneFullScreen")

    private(set) weak var pane: (any RemoteScreenPane)?
    private var container: PaneFullScreenContainerView?
    /// The pane's split hosting view at enter time; exit re-attaches through
    /// its normal layout once the detach flag clears.
    private weak var formerHost: SplitTreeHostingView?
    private weak var tabsModel: TabsModel?
    private var onDidExit: ((any RemoteScreenPane) -> Void)?
    private var failureOverlayHost: UIHostingController<RemoteScreenThemedSurface<VNCConnectionFailureCard>>?
    private var observationActive = false
    private var isEnterAnimating = false
    /// One keyboard observation loop per takeover; a stale one ends itself.
    private var keyboardObservationGeneration = 0
    private var isExitAnimating = false

    var isActive: Bool { container != nil }

    // MARK: - Enter

    /// Check the pane out of split layout and take over the window.
    /// `onDidExit` runs after every exit that leaves the pane alive in a tab
    /// (focus restoration); teardown paths (pane closed, retargeted) skip it.
    func enter(_ pane: any RemoteScreenPane, tabsModel: TabsModel, onDidExit: ((any RemoteScreenPane) -> Void)?) {
        guard container == nil else { return }
        guard !pane.isDetachedForFullScreen, let window = pane.window else { return }

        Self.logger.info("Entering full screen for pane \(pane.uuid)")
        self.pane = pane
        self.tabsModel = tabsModel
        self.onDidExit = onDidExit
        formerHost = pane.superview as? SplitTreeHostingView

        let startFrame = pane.convert(pane.bounds, to: window)

        let container = PaneFullScreenContainerView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.onExitRequested = { [weak self] in self?.exit(animated: true) }
        container.onLayout = { [weak self] in self?.layoutPane(animated: false) }
        window.addSubview(container)
        self.container = container
        isEnterAnimating = true
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        // A detached keyboard card is a window subview too and stays on top.
        if let card = TerminalTouchKeyboardWindowState.forWindow(window).overlay {
            window.bringSubviewToFront(card)
        }
        #endif

        pane.isDetachedForFullScreen = true
        pane.fullScreenController = self
        tabsModel.fullScreenPaneID = pane.uuid

        // True edge-to-edge: hide the status bar and home indicator for the
        // duration of the takeover (transient hold, independent of the
        // persistent Full Screen setting).
        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        ImmersiveChromeManager.shared.beginTransientImmersion()
        #endif

        // Reparent the live pane into the container at its captured frame,
        // clearing any split focus border and Rounded Panes card clip, then
        // grow it to the full window. Exit re-applies both through layout.
        pane.layer.borderWidth = 0
        pane.layer.borderColor = UIColor.clear.cgColor
        pane.applyPaneCorners(rounded: false)
        pane.clipsToBounds = false
        pane.autoresizingMask = []
        container.insertSubview(pane, at: 0)
        pane.frame = container.convert(startFrame, from: window)

        // The child hosting controller's parent VC was discovered from the
        // responder chain at attach time and is no longer an ancestor once
        // the pane sits in a window-level container. Re-home it under the
        // window's root VC so Menu presentation and the input responder keep
        // a valid VC chain.
        if let root = window.rootViewController {
            pane.rehostHostingController(under: root)
        }

        let target = paneFrame(for: pane, in: container)
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            pane.frame = target
            pane.layoutIfNeeded()
        } completion: { [weak self] _ in
            // Re-snap in case a rotation or keyboard change landed
            // mid-animation; a no-op once an exit has taken the pane back.
            self?.isEnterAnimating = false
            self?.layoutPane(animated: false)
        }

        formerHost?.setNeedsLayout()
        startSessionObservation()
        keyboardObservationGeneration &+= 1
        observeKeyboardLayout(generation: keyboardObservationGeneration)
    }

    // MARK: - Pane layout

    /// The window, less what a docked keyboard or keyboard toolbar covers.
    /// The pane owns its keyboard clearance here as it does in a tab, from
    /// the same frames, so the terminal keyboard counts wherever it is hosted.
    private func paneFrame(for pane: any RemoteScreenPane, in container: UIView) -> CGRect {
        let bounds = container.bounds
        #if !os(visionOS) && !targetEnvironment(macCatalyst)
        guard let window = container.window else { return bounds }
        func local(_ frame: CGRect) -> CGRect {
            container.convert(frame, from: window.screen.coordinateSpace)
        }
        let keyboard = pane.dockedTouchKeyboardFrameInScreen.map(local)
            ?? TerminalKeyboardGeometry.includingAccessory(
                keyboard: local(EffectManager.shared.keyboardFrame),
                accessory: pane.keyboardAccessoryFrameInScreen.map(local),
                container: bounds)
        // Full width and on the bottom edge: floating and split keyboards
        // sit over the remote screen instead.
        let keyboardCover = keyboard.maxY >= bounds.maxY - 50
            ? TerminalKeyboardGeometry.overlapHeight(keyboard: keyboard, container: bounds) : 0
        // A toolbar with no keyboard under it stands on the bottom edge.
        let cover = max(keyboardCover, pane.reservedKeyboardToolbarHeightAtBottom)
        // Never collapse the screen for a frame that makes no sense.
        guard cover > 0, cover < bounds.height - 80 else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height - cover)
        #else
        return bounds
        #endif
    }

    private func layoutPane(animated: Bool) {
        guard let container, let pane, pane.superview === container,
              !isEnterAnimating, !isExitAnimating else { return }
        let target = paneFrame(for: pane, in: container)
        guard pane.frame != target else { return }
        guard animated else {
            pane.frame = target
            return
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            pane.frame = target
            pane.layoutIfNeeded()
        }
    }

    /// Keyboard frame and toolbar changes both land on EffectManager.
    private func observeKeyboardLayout(generation: Int) {
        guard container != nil, generation == keyboardObservationGeneration else { return }
        withObservationTracking {
            _ = EffectManager.shared.keyboardFrame
            _ = EffectManager.shared.keyboardStateVersion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeKeyboardLayout(generation: generation)
                self.layoutPane(animated: true)
            }
        }
    }

    // MARK: - Exit

    /// Hand the pane back to split layout. Animated exit shrinks it to its
    /// slot frame first; anything that can't be computed (host gone, pane no
    /// longer in the tree) falls back to an instant handback.
    func exit(animated: Bool) {
        guard let container, let pane else { return }
        if isExitAnimating {
            // A watchdog fired mid-animation: force-complete now; the
            // animation's completion becomes a no-op.
            if !animated { finishExit() }
            return
        }

        observationActive = false
        removeFailureOverlay()
        container.beginExitTransition()

        let target: CGRect? = {
            guard animated,
                  let host = formerHost,
                  host.window === container.window,
                  let slot = host.slotFrame(for: pane) else { return nil }
            return container.convert(slot, from: host)
        }()

        if let target {
            isExitAnimating = true
            pane.autoresizingMask = []
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                pane.frame = target
                container.backgroundColor = .clear
                pane.layoutIfNeeded()
            } completion: { [weak self] _ in
                self?.finishExit()
            }
        } else {
            finishExit()
        }
    }

    /// Watchdog: the selected tab changed under a full-screen pane.
    func exitForTabChange() {
        guard isActive, let pane else { return }
        // This is a temporary suspension, not a user request to leave full
        // screen. The pane consumes the flag only after it successfully
        // re-enters when its tab becomes focused again.
        pane.fullScreenDidSuspendForTabChange()
        exit(animated: false)
    }

    /// Watchdog: teardown when the pane is no longer in any of this window's
    /// tabs (tab closed or transferred without the close funnel firing).
    func exitIfPaneOrphaned() {
        guard isActive, let pane else { return }
        let stillHosted = tabsModel?.tabs.contains { tab in
            tab.splitTree.contains(where: { $0 === pane })
        } ?? false
        if !stillHosted {
            onDidExit = nil
            exit(animated: false)
        }
    }

    /// The pane is closing (prepareForClose funnel): tear the container down
    /// without focus restoration; the close path owns the rest.
    func paneDidClose(_ pane: any RemoteScreenPane) {
        guard pane === self.pane else { return }
        onDidExit = nil
        finishExit()
    }

    /// The pane's tab is moving to another window: hand back instantly so
    /// the destination window's layout can adopt it (a still-set detach flag
    /// would strand the pane forever).
    func exitForWindowRetarget() {
        guard isActive else { return }
        onDidExit = nil
        exit(animated: false)
    }

    /// Another pane in the same tab is being focused: hand back without
    /// restoring focus to the full-screen pane.
    func exitForSiblingFocus() {
        guard isActive else { return }
        onDidExit = nil
        exit(animated: false)
    }

    private func finishExit() {
        guard let container else { return }
        isEnterAnimating = false
        isExitAnimating = false
        observationActive = false
        keyboardObservationGeneration &+= 1
        removeFailureOverlay()

        #if !targetEnvironment(macCatalyst) && !os(visionOS)
        ImmersiveChromeManager.shared.endTransientImmersion()
        #endif

        let pane = self.pane
        self.container = nil
        self.pane = nil

        if let pane {
            pane.isDetachedForFullScreen = false
            pane.fullScreenController = nil
            // Reattach through normal layout: with the detach flag cleared,
            // the hosting view re-adopts the pane at its slot frame.
            if let host = formerHost {
                host.setNeedsLayout()
                host.layoutIfNeeded()
            }
            // Layout didn't re-adopt it (host gone, pane left the tree, or
            // another pane is zoomed): don't leave it inside the dying
            // container; the next layout that includes it picks it up.
            if pane.superview === container {
                pane.removeFromSuperview()
            }
            pane.rehostHostingControllerToCurrentAncestor()
        }

        container.removeFromSuperview()
        formerHost = nil
        tabsModel?.fullScreenPaneID = nil

        if let pane {
            onDidExit?(pane)
        }
        onDidExit = nil
    }

    // MARK: - Connection-failure overlay

    /// Observe the package session's @Observable state while full screen so
    /// a dead connection always leaves the user an exit (`.disconnected`
    /// closes the pane through the existing funnel; `.failed` gets an
    /// overlay with Retry + Exit).
    private func startSessionObservation() {
        observationActive = true
        observeSessionState()
    }

    private func observeSessionState() {
        guard observationActive, let pane else { return }
        let failure = withObservationTracking {
            pane.fullScreenFailureMessage
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSessionState()
            }
        }
        applyFailureOverlay(failure: failure)
    }

    /// Re-evaluated by the pane when a launcher (pre-session) failure is set
    /// or cleared, since those never move `connectionState`.
    func refreshFailureOverlay() {
        guard observationActive, let pane else { return }
        applyFailureOverlay(failure: pane.fullScreenFailureMessage)
    }

    private func applyFailureOverlay(failure: String?) {
        guard observationActive, !isExitAnimating, let pane, let container else { return }

        let message = failure ?? pane.launchErrorMessage

        guard let message else {
            removeFailureOverlay()
            return
        }

        let subtitle = pane.paneDisplayName
        let overlay = RemoteScreenThemedSurface(
            tabId: pane.containingTabID,
            windowId: pane.windowId
        ) { [weak self, weak pane] in
            VNCConnectionFailureCard(
                subtitle: subtitle,
                message: message,
                onRetry: { [weak self] in self?.retryConnection() },
                onCancel: { [weak pane] in pane?.cancelFailedConnection() },
                onExitFullScreen: { [weak self] in self?.exit(animated: true) }
            )
        }

        if let host = failureOverlayHost {
            host.rootView = overlay
            return
        }

        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = UIColor.clear
        // Add the view while the controller is still parentless: the container
        // is a window-level sibling of the root VC's view, and iOS 26's
        // hierarchy check aborts if a parented child VC's view enters a window
        // outside its parent's hierarchy. Adopting VC parentage afterwards
        // moves no views, so no check runs (same order as
        // rehostHostingController on the pane itself).
        container.addOverlay(host.view)
        if let root = container.window?.rootViewController {
            root.addChild(host)
            host.didMove(toParent: root)
        }
        failureOverlayHost = host
    }

    private func retryConnection() {
        guard let pane else { return }
        if pane.launchErrorMessage != nil {
            pane.retryLaunch()
        } else {
            pane.retryRemoteConnection()
        }
        refreshFailureOverlay()
    }

    private func removeFailureOverlay() {
        guard let host = failureOverlayHost else { return }
        // Detach VC parentage first so the view never changes windows while
        // parented (mirror of the add order in applyFailureOverlay).
        host.willMove(toParent: nil)
        host.removeFromParent()
        host.view.removeFromSuperview()
        failureOverlayHost = nil
    }
}

// MARK: - Container View

/// Black window-bounds container hosting the checked-out pane. Carries the
/// Cmd-Shift-F exit key command (resolved through the responder chain while
/// the remote input view, a descendant, is first responder; Esc is
/// deliberately not used, it belongs to the remote).
final class PaneFullScreenContainerView: UIView {

    var onExitRequested: (() -> Void)?
    /// Window resize and rotation: the controller re-fits the pane.
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(
            title: String(localized: "Exit Full Screen"),
            action: #selector(handleExitKeyCommand),
            input: "f",
            modifierFlags: [.command, .shift]
        )
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    @objc private func handleExitKeyCommand() {
        onExitRequested?()
    }

    /// Full-bleed overlay (failure card) above the pane.
    func addOverlay(_ view: UIView) {
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
    }

    /// Freeze interaction while the exit animation runs.
    func beginExitTransition() {
        isUserInteractionEnabled = false
    }
}

// The full-screen failure overlay is the shared VNCConnectionFailureCard
// (VNCPaneView.swift) with the Exit Full Screen action supplied.
