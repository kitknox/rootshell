//
//  PaneFullScreenController.swift
//  rootshell
//
//  In-window full-screen takeover for VNC panes: reparents the live pane
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

    private(set) weak var pane: VNCPaneView?
    private var container: PaneFullScreenContainerView?
    /// The pane's split hosting view at enter time; exit re-attaches through
    /// its normal layout once the detach flag clears.
    private weak var formerHost: SplitTreeHostingView?
    private weak var tabsModel: TabsModel?
    private var onDidExit: ((VNCPaneView) -> Void)?
    private var failureOverlayHost: UIHostingController<VNCPaneThemedSurface<VNCConnectionFailureCard>>?
    private var observationActive = false
    private var isExitAnimating = false

    var isActive: Bool { container != nil }

    // MARK: - Enter

    /// Check the pane out of split layout and take over the window.
    /// `onDidExit` runs after every exit that leaves the pane alive in a tab
    /// (focus restoration); teardown paths (pane closed, retargeted) skip it.
    func enter(_ pane: VNCPaneView, tabsModel: TabsModel, onDidExit: ((VNCPaneView) -> Void)?) {
        guard container == nil else { return }
        guard !pane.isDetachedForFullScreen, let window = pane.window else { return }

        Self.logger.info("Entering full screen for VNC pane \(pane.uuid)")
        self.pane = pane
        self.tabsModel = tabsModel
        self.onDidExit = onDidExit
        formerHost = pane.superview as? SplitTreeHostingView

        let startFrame = pane.convert(pane.bounds, to: window)

        let container = PaneFullScreenContainerView(frame: window.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.onExitRequested = { [weak self] in self?.exit(animated: true) }
        window.addSubview(container)
        self.container = container

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
        // clearing any split focus border, then grow it to the full window.
        pane.layer.borderWidth = 0
        pane.layer.borderColor = UIColor.clear.cgColor
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

        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            pane.frame = container.bounds
            pane.layoutIfNeeded()
        } completion: { [weak self, weak pane] _ in
            // Track window resize/rotation from here on, re-snapping to the
            // live container bounds in case a rotation landed mid-animation.
            // Skip when an exit raced the enter animation and already
            // re-attached the pane.
            guard let pane, pane.isDetachedForFullScreen else { return }
            if let container = self?.container, pane.superview === container {
                pane.frame = container.bounds
            }
            pane.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }

        formerHost?.setNeedsLayout()
        startSessionObservation()
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
    func paneDidClose(_ pane: VNCPaneView) {
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

    private func finishExit() {
        guard let container else { return }
        isExitAnimating = false
        observationActive = false
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
        let state = withObservationTracking {
            pane.session.connectionState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSessionState()
            }
        }
        applyFailureOverlay(for: state)
    }

    /// Re-evaluated by the pane when a launcher (pre-session) failure is set
    /// or cleared, since those never move `connectionState`.
    func refreshFailureOverlay() {
        guard observationActive, let pane else { return }
        applyFailureOverlay(for: pane.session.connectionState)
    }

    private func applyFailureOverlay(for state: VNCConnectionState) {
        guard observationActive, !isExitAnimating, let pane, let container else { return }

        var message: String?
        if case .failed(let reason) = state {
            message = reason
        }
        message = message ?? pane.launchErrorMessage

        guard let message else {
            removeFailureOverlay()
            return
        }

        let overlay = VNCPaneThemedSurface(pane: pane) {
            VNCConnectionFailureCard(
                subtitle: pane.config.displayName,
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
            pane.session.retryConnection()
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
