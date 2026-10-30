//
//  TabSidebarEdgeSwipe.swift
//  rootshell
//
//  Pull a sidebar in from a screen edge on iPhone and iPad. Built on
//  `InteractiveEdgePanRecognizer` (a window-level pan, since the overlay is
//  `isUserInteractionEnabled = false` while closed and cannot catch the edge
//  touch itself). iPhone and iPad defer the system edge via `.defersSystemGestures`.
//
//  A floating drawer tracks the finger through the `tabSidebarOpenDrag*`
//  notifications. A docked column, and a file manager that is not a drawer,
//  cannot track the finger, so the gesture only opens them.
//

import SwiftUI
import os

#if canImport(UIKit)
import UIKit
#endif

#if !os(visionOS)

/// How far inside the safe content edge a drag may start and open the drawer.
private let edgeActivationWidth: CGFloat = 32
private let edgeCompactPeek: CGFloat = 48

struct TabSidebarEdgeSwipe: UIViewRepresentable {
    var edge: SidePanelEdge
    /// True only when an edge swipe may open this side.
    var canOpen: () -> Bool
    /// The open is a floating drawer that tracks the finger. A docked column
    /// or a non-drawer panel opens without tracking.
    var tracksFinger: Bool
    var panelWidth: CGFloat
    var onOpen: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            edge: edge,
            canOpen: canOpen,
            tracksFinger: tracksFinger,
            panelWidth: panelWidth,
            onOpen: onOpen,
            onCancel: onCancel
        )
    }

    func makeUIView(context: Context) -> EdgeSwipeInstallerView {
        let view = EdgeSwipeInstallerView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: EdgeSwipeInstallerView, context: Context) {
        context.coordinator.edge = edge
        context.coordinator.canOpen = canOpen
        context.coordinator.tracksFinger = tracksFinger
        context.coordinator.panelWidth = panelWidth
        context.coordinator.onOpen = onOpen
        context.coordinator.onCancel = onCancel
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    @MainActor
    final class Coordinator {
        var edge: SidePanelEdge
        var canOpen: () -> Bool
        var tracksFinger: Bool
        var panelWidth: CGFloat
        var onOpen: () -> Void
        var onCancel: () -> Void

        private var interactiveOpenInProgress = false
        private weak var window: UIWindow?
        private(set) lazy var recognizer: InteractiveEdgePanRecognizer = makeRecognizer()

        private func makeRecognizer() -> InteractiveEdgePanRecognizer {
            var configuration = InteractiveEdgePanRecognizer.Configuration(
                axis: .horizontal,
                idioms: [.phone, .pad]
            )
            configuration.touchCounts = [1]
            configuration.beatsSiblingRecognizers = { $0 is UISwipeGestureRecognizer }

            let isInBand: (CGPoint, UIWindow, Int) -> Bool = { [weak self] start, window, _ in
                guard let self else { return false }
                switch self.edge {
                case .leading:
                    return start.x <= window.safeAreaInsets.left + edgeActivationWidth
                case .trailing:
                    return start.x >= window.bounds.width - window.safeAreaInsets.right - edgeActivationWidth
                }
            }
            let shouldBegin: (CGPoint, CGPoint, UIWindow, Int) -> Bool = { [weak self] start, translation, window, _ in
                guard let self else { return false }
                let canOpen = self.canOpen()
                Ghostty.logger.debug("Sidebar edge gate edge=\(self.edge == .leading ? "leading" : "trailing", privacy: .public) x=\(start.x) dx=\(translation.x) dy=\(translation.y) width=\(window.bounds.width) safeLeft=\(window.safeAreaInsets.left) safeRight=\(window.safeAreaInsets.right) canOpen=\(canOpen)")
                guard canOpen else { return false }
                let horizontal = abs(translation.x) >= abs(translation.y)
                switch self.edge {
                case .leading:
                    return horizontal && translation.x > 0
                case .trailing:
                    return horizontal && translation.x < 0
                }
            }
            let callbacks = InteractiveEdgePanRecognizer.Callbacks(
                isInActivationBand: isInBand,
                shouldBegin: shouldBegin,
                length: { [weak self] in self?.openLength() ?? 1 },
                onBegin: { [weak self] window in self?.begin(window: window) },
                onChange: { [weak self] progress in self?.change(progress: progress) },
                onEnd: { [weak self] progress, velocity in self?.end(progress: progress, velocity: velocity) },
                onCancel: { [weak self] in self?.cancel() }
            )
            return InteractiveEdgePanRecognizer(configuration: configuration, callbacks: callbacks)
        }

        init(
            edge: SidePanelEdge,
            canOpen: @escaping () -> Bool,
            tracksFinger: Bool,
            panelWidth: CGFloat,
            onOpen: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.edge = edge
            self.canOpen = canOpen
            self.tracksFinger = tracksFinger
            self.panelWidth = panelWidth
            self.onOpen = onOpen
            self.onCancel = onCancel
        }

        private func openLength() -> CGFloat {
            let width = window?.bounds.width ?? panelWidth
            let compact = window?.traitCollection.horizontalSizeClass != .regular
            let available = compact == true ? max(0, width - edgeCompactPeek) : width
            return max(min(panelWidth, available > 0 ? available : panelWidth), 1)
        }

        /// The recognizer's progress is positive to the right. The overlay
        /// wants 0 at hidden and 1 at open, for either edge.
        private func openAmount(_ signed: CGFloat) -> CGFloat {
            switch edge {
            case .leading: return signed
            case .trailing: return -signed
            }
        }

        private func post(_ name: Notification.Name, extra: [String: Any] = [:]) {
            var info = extra
            info["edge"] = edge == .leading ? "leading" : "trailing"
            NotificationCenter.default.post(name: name, object: window, userInfo: info)
        }

        private func begin(window: UIWindow) {
            self.window = window
            guard canOpen() else {
                interactiveOpenInProgress = false
                return
            }
            Ghostty.logger.debug("Edge sidebar gesture begin edge=\(String(describing: self.edge), privacy: .public) tracksFinger=\(self.tracksFinger) window=\(String(describing: ObjectIdentifier(window)), privacy: .public)")
            if tracksFinger {
                interactiveOpenInProgress = true
                post(.tabSidebarBeginInteractiveOpen)
                onOpen()
            } else {
                interactiveOpenInProgress = false
                onOpen()
            }
        }

        private func change(progress: CGFloat) {
            guard interactiveOpenInProgress else { return }
            post(.tabSidebarOpenDragChanged, extra: ["progress": max(0, min(1, openAmount(progress)))])
        }

        private func end(progress: CGFloat, velocity: CGFloat) {
            Ghostty.logger.debug("Edge sidebar gesture end edge=\(String(describing: self.edge), privacy: .public) progress=\(self.openAmount(progress)) velocity=\(self.openAmount(velocity))")
            guard interactiveOpenInProgress else { return }
            interactiveOpenInProgress = false
            if openAmount(progress) > 1 / 3 || openAmount(velocity) > 800 {
                Ghostty.logger.debug("Edge sidebar gesture commit")
                post(.tabSidebarOpenDragCommit)
            } else {
                Ghostty.logger.debug("Edge sidebar gesture cancel")
                post(.tabSidebarOpenDragCancel)
                onCancel()
            }
        }

        private func cancel() {
            Ghostty.logger.debug("Edge sidebar gesture interrupted edge=\(String(describing: self.edge), privacy: .public)")
            guard interactiveOpenInProgress else { return }
            interactiveOpenInProgress = false
            post(.tabSidebarOpenDragCancel)
            onCancel()
        }
    }

    final class EdgeSwipeInstallerView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            coordinator?.recognizer.install(on: window)
        }
    }
}

#endif
