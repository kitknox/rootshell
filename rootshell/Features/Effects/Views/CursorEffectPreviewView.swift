//
//  CursorEffectPreviewView.swift
//  rootshell
//
//  Lightweight Ghostty surface that animates cursor movement to preview cursor shader effects.
//

import UIKit
import SwiftUI
import GhosttyKit
import os

extension Ghostty {

    /// A minimal UIView hosting a Ghostty surface that animates cursor movement
    /// to demonstrate cursor shader trail effects in the settings preview.
    class CursorEffectPreviewView: UIView, PreviewRenderingParticipant {

        private nonisolated static let logger = Logger(
            subsystem: "com.rootshell",
            category: "CursorEffectPreview"
        )

        private weak var ghosttyApp: Ghostty.App?
        private var surface: ghostty_surface_t?
        private var slaveFd: Int32 = -1
        private var hasSized = false
        private var renderingSuspended = false
        private var needsRendererResume = false
        private var cleanedUp = false

        private var canRender: Bool {
            !cleanedUp && !renderingSuspended && !Ghostty.isSecureDrawProhibitedAtomic && window != nil
        }

        // Animation
        private var moveTimer: Timer?
        private var currentWaypointIndex: Int = 0
        private var shaderObserver: NSObjectProtocol?
        private var animationGeneration: UInt64 = 0

        // Waypoints for cursor movement — mix of horizontal, vertical, diagonal jumps
        // Kept within ~25 cols to avoid issues in narrow sidebars
        private let waypoints: [(row: Int, col: Int)] = [
            (1, 6),
            (3, 18),
            (5, 12),
            (2, 1),
            (6, 22),
            (4, 8),
            (7, 3),
            (1, 1),
        ]

        override class var layerClass: AnyClass { CAMetalLayer.self }

        init(ghosttyApp: Ghostty.App) {
            self.ghosttyApp = ghosttyApp
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isOpaque = false
            PreviewRenderingLifecycle.register(self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                // A lifecycle-paused surface waits for the deferred activation
                // pass, even if UIKit reattaches it earlier in the transaction.
                guard canRender else { return }
                if surface == nil {
                    createSurface()
                } else if let surface {
                    ghostty_surface_set_occlusion(surface, true)
                    needsRendererResume = false
                    if hasSized { scheduleContentAndAnimation(after: 0.15) }
                }
            } else {
                if Ghostty.isSecureDrawProhibitedAtomic { suspendPreviewRendering() }
                if let surface {
                    ghostty_surface_set_occlusion(surface, false)
                    needsRendererResume = true
                }
                stopAnimation()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard canRender else { return }

            if let sublayers = layer.sublayers {
                for sublayer in sublayers {
                    if sublayer.frame != bounds {
                        sublayer.frame = bounds
                    }
                }
            }

            guard let surface else { return }
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }

            let scale = contentScaleFactor
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(surface, UInt32(size.width * scale), UInt32(size.height * scale))

            if !hasSized {
                hasSized = true
                // Populate content and start animation after first layout
                scheduleContentAndAnimation(after: 0.15)
            }
        }

        // MARK: - Surface Creation

        private func createSurface() {
            guard canRender else { return }
            guard let app = ghosttyApp?.app else {
                Self.logger.error("Cannot create preview surface: app pointer is nil")
                return
            }

            var cfg = ghostty_surface_config_new()
            cfg.platform_tag = GHOSTTY_PLATFORM_IOS
            cfg.platform = ghostty_platform_u(ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(self).toOpaque()
            ))
            cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
            cfg.scale_factor = contentScaleFactor
            cfg.use_external_io = true

            guard let newSurface = ghostty_surface_new(app, &cfg) else {
                Self.logger.error("Failed to create cursor effect preview surface")
                return
            }

            self.surface = newSurface
            self.slaveFd = ghostty_surface_get_slave_fd(newSurface)
            ghosttyApp?.registerSurface(newSurface)
            ghostty_surface_set_focus(newSurface, true)

            // Observe shader config changes to restart animation with new effect
            shaderObserver = NotificationCenter.default.addObserver(
                forName: .shaderConfigChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.restartAnimation()
            }

            let fd = self.slaveFd
            Self.logger.debug("Cursor effect preview surface created, slaveFd=\(fd)")
        }

        // MARK: - Secure-draw Lifecycle

        func suspendPreviewRendering() {
            stopAnimation()
            guard !cleanedUp, !renderingSuspended else { return }
            renderingSuspended = true
            guard let surface else { return }
            needsRendererResume = true
            ghostty_surface_set_occlusion(surface, false)
            let drained = ghostty_surface_drain_renderer_to_idle(surface, 100_000_000)
            LifecycleDebugLogger.shared.checkpoint("SECURE.cursorPreview.pause", ms: nil, [
                ("surface", UInt(bitPattern: surface)), ("drained", drained),
            ])
            if !drained {
                LifecycleDebugLogger.shared.criticalCheckpoint("SECURE.cursorPreview.drain.timeout", [
                    ("surface", UInt(bitPattern: surface)),
                ])
            }
        }

        func resumePreviewRendering() {
            guard !cleanedUp, !Ghostty.isSecureDrawProhibitedAtomic else { return }
            renderingSuspended = false
            guard window != nil else { return }
            if surface == nil { createSurface() }
            setNeedsLayout()
            layoutIfNeeded()
            if needsRendererResume, let surface {
                needsRendererResume = false
                ghostty_surface_set_occlusion(surface, true)
            }
            // Also recovers a first-layout population interrupted by lock.
            scheduleContentAndAnimation(after: 0.15)
        }

        // MARK: - Content

        /// Write fake terminal content so the cursor trail is visible against text.
        private func populateContent() {
            guard canRender, hasSized, slaveFd >= 0 else { return }

            // Short lines (<25 chars) to avoid wrapping in narrow sidebars
            let content = [
                "\u{1b}[2J\u{1b}[H",                      // clear + home
                "\u{1b}[32m$\u{1b}[0m ls\r\n",
                "\u{1b}[34mdocs/\u{1b}[0m  src/  README\r\n",
                "\u{1b}[32m$\u{1b}[0m cat config\r\n",
                "port: \u{1b}[33m8080\u{1b}[0m\r\n",
                "host: \u{1b}[36mlocalhost\u{1b}[0m\r\n",
                "\u{1b}[32m$\u{1b}[0m echo hello\r\n",
                "hello\r\n",
                "\u{1b}[32m$\u{1b}[0m ",
            ].joined()

            writeToSlaveFd(content)

            // Tick + draw to render the initial content
            ghosttyApp?.appTick()
            let generation = animationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.animationGeneration == generation, self.canRender,
                      let surface = self.surface,
                      self.ghosttyApp?.isInBackground != true,
                      !Ghostty.isSecureDrawProhibitedAtomic else { return }
                self.ghosttyApp?.appTick()
                ghostty_surface_draw(surface)
            }
        }

        private func writeToSlaveFd(_ text: String) {
            guard canRender, hasSized, slaveFd >= 0, let data = text.data(using: .utf8) else { return }
            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress else { return }
                var written = 0
                let total = buffer.count
                while written < total {
                    let n = write(slaveFd, ptr.advanced(by: written), total - written)
                    if n <= 0 { break }
                    written += n
                }
            }
        }

        // MARK: - Animation

        func startAnimation() {
            guard canRender, hasSized, moveTimer == nil, surface != nil else { return }

            // Ghostty owns frame cadence and parks its display link after the
            // finite cursor effect. This timer only supplies demo movement.
            moveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.moveCursorToNextWaypoint()
            }

            // Trigger first move immediately
            moveCursorToNextWaypoint()
        }

        func stopAnimation() {
            animationGeneration &+= 1
            moveTimer?.invalidate()
            moveTimer = nil
        }

        func restartAnimation() {
            stopAnimation()
            currentWaypointIndex = 0
            // Short delay to let config propagate
            scheduleContentAndAnimation(after: 0.25)
        }

        private func scheduleContentAndAnimation(after delay: TimeInterval) {
            stopAnimation()
            guard canRender, hasSized, surface != nil else { return }
            let generation = animationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.animationGeneration == generation, self.canRender else { return }
                self.populateContent()
                self.startAnimation()
            }
        }

        private func moveCursorToNextWaypoint() {
            guard canRender, hasSized else { return }
            let wp = waypoints[currentWaypointIndex]
            currentWaypointIndex = (currentWaypointIndex + 1) % waypoints.count
            // ANSI CSI cursor position: ESC [ row ; col H
            writeToSlaveFd("\u{1b}[\(wp.row);\(wp.col)H")
        }

        // MARK: - Cleanup

        func cleanup() {
            if Ghostty.isSecureDrawProhibitedAtomic { suspendPreviewRendering() }
            cleanedUp = true
            stopAnimation()

            if let observer = shaderObserver {
                NotificationCenter.default.removeObserver(observer)
                shaderObserver = nil
            }

            guard let surface else { return }
            ghosttyApp?.unregisterSurface(surface)
            self.surface = nil
            self.slaveFd = -1

            TerminalView.ghosttyAPIQueue.async {
                Self.logger.debug("Freeing cursor effect preview surface on background queue")
                ghostty_surface_free(surface)
            }
        }

        deinit {
            if surface != nil {
                Self.logger.warning("CursorEffectPreviewView deallocated without cleanup()")
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

struct CursorEffectPreviewContainer: UIViewRepresentable {
    let effect: CursorEffect
    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeUIView(context: Context) -> Ghostty.CursorEffectPreviewView {
        Ghostty.CursorEffectPreviewView(ghosttyApp: ghosttyApp)
    }

    func updateUIView(_ uiView: Ghostty.CursorEffectPreviewView, context: Context) {
        if context.coordinator.lastEffect != effect {
            context.coordinator.lastEffect = effect
            uiView.restartAnimation()
        }
    }

    static func dismantleUIView(_ uiView: Ghostty.CursorEffectPreviewView, coordinator: Coordinator) {
        uiView.cleanup()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastEffect: CursorEffect?
    }
}
