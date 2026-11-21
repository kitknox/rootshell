//
//  RemoteScreenSnapshotRecorder.swift
//  rootshell
//
//  One remote-screen pane's last-seen picture: taken from the live session
//  now and then, kept for the pane's reconnects, and saved for its profile.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Observation

@MainActor
@Observable
final class RemoteScreenSnapshotRecorder {
    /// What a session presents: a framebuffer image, or one video surface
    /// per display with its place in the picture (top-left origin).
    nonisolated enum Frame {
        case image(CGImage)
        case surfaces([Surface])
    }

    nonisolated struct Surface {
        let pixelBuffer: CVPixelBuffer
        let region: CGRect
    }

    /// The last screen seen, drawn while there is no live picture. Released
    /// once the session is live; `latest` brings it back.
    private(set) var placeholder: RemoteScreenSnapshot?
    /// The session is connected and has drawn a frame.
    private(set) var isLive = false

    /// Only a saved profile's screen is written to disk; other connections
    /// keep theirs for this pane's lifetime.
    @ObservationIgnored var profileID: UUID? {
        didSet {
            guard profileID != oldValue else { return }
            restorePlaceholder()
        }
    }

    /// The computer the session reaches, jump route included; nil while
    /// that is unknown. A pane's route can move between attempts, and a
    /// picture of the old route's computer must not carry over.
    @ObservationIgnored var endpoint: String? {
        didSet {
            guard endpoint != oldValue else { return }
            forget()
            restorePlaceholder()
        }
    }

    /// Whether this connection has drawn anything. Separate from
    /// `currentFrame`: one display of two can be live before a complete
    /// frame exists, and the placeholder must not cover it.
    @ObservationIgnored private let hasLivePicture: @MainActor () -> Bool
    /// The session's newest complete frame, or nil while it has none.
    @ObservationIgnored private let currentFrame: @MainActor () -> Frame?
    /// Whether a profile still exists and still points at an endpoint.
    @ObservationIgnored private let canPersist: @MainActor (UUID, String) -> Bool
    @ObservationIgnored private var isConnected = false
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    /// Counts `forget` calls, so a capture that was already rendering
    /// cannot bring a forgotten picture back.
    @ObservationIgnored private var forgetCount = 0
    /// The closing frame is taken: nothing later in this connection
    /// replaces it.
    @ObservationIgnored private var holdsClosingFrame = false
    /// This session's newest capture, still encoded: a few hundred
    /// kilobytes against several megabytes decoded.
    @ObservationIgnored private var latest: (jpeg: Data, capturedAt: Date)?

    /// Let the first frames settle: a login transition or a partial first
    /// update makes a poor keepsake. Also outlasts the placeholder's fade.
    private static let firstCaptureDelay: Duration = .seconds(2)
    private static let captureInterval: Duration = .seconds(45)
    /// While the picture is live but not complete, as before a second
    /// display's first frame.
    private static let incompleteFrameRetryInterval: Duration = .seconds(2)
    private static let framePollInterval: Duration = .milliseconds(120)
    private static let idleFramePollInterval: Duration = .milliseconds(500)

    init(
        endpoint: String?,
        canPersist: @escaping @MainActor (UUID, String) -> Bool,
        hasLivePicture: @escaping @MainActor () -> Bool,
        currentFrame: @escaping @MainActor () -> Frame?
    ) {
        self.endpoint = endpoint
        self.canPersist = canPersist
        self.hasLivePicture = hasLivePicture
        self.currentFrame = currentFrame
        RemoteScreenSnapshotStore.shared.register(self)
    }

    // MARK: Session state

    /// Call on every connection-state change. Connected starts watching for
    /// the first frame; anything else brings the placeholder back.
    func sessionConnectionChanged(isConnected connected: Bool) {
        guard connected != isConnected else { return }
        isConnected = connected
        liveTask?.cancel()
        liveTask = nil
        guard connected else {
            // The session may still hold its last frame; a reset one is nil.
            captureNow()
            isLive = false
            restorePlaceholder()
            return
        }
        holdsClosingFrame = false
        // Weak at every step, so a pane that never calls `stop` still lets go.
        liveTask = Task { [weak self] in
            // A KVM whose computer sleeps can stay frameless for hours.
            var polls = 0
            while !Task.isCancelled, self?.hasLivePicture() == false {
                polls += 1
                try? await Task.sleep(for: polls < 40
                    ? RemoteScreenSnapshotRecorder.framePollInterval
                    : RemoteScreenSnapshotRecorder.idleFramePollInterval)
            }
            guard !Task.isCancelled else { return }
            self?.isLive = true
            try? await Task.sleep(for: RemoteScreenSnapshotRecorder.firstCaptureDelay)
            guard !Task.isCancelled else { return }
            self?.placeholder = nil
            while !Task.isCancelled, let waitsForCompleteFrame = self?.captureIfComplete() {
                try? await Task.sleep(for: waitsForCompleteFrame
                    ? RemoteScreenSnapshotRecorder.incompleteFrameRetryInterval
                    : RemoteScreenSnapshotRecorder.captureInterval)
            }
        }
    }

    /// Take the session's current frame. Called on a timer and just before
    /// a close, a disconnect or a trip to the background. Only a frame this
    /// connection drew counts: a session can hold an earlier one.
    func captureNow() {
        _ = captureIfComplete()
    }

    /// Take the screen as the user leaves it, and keep it. Called before a
    /// pre-disconnect action: what that leaves behind is a lock screen, a
    /// login window or a dark display, not what was being worked on.
    func captureClosingFrame() {
        captureNow()
        holdsClosingFrame = true
    }

    /// The close was abandoned and the session goes on.
    func resumeCaptures() {
        holdsClosingFrame = false
    }

    /// True when the only thing missing was a complete frame, so it is
    /// worth asking again soon.
    private func captureIfComplete() -> Bool {
        guard isLive, !holdsClosingFrame,
              RemoteScreenSnapshotStore.shared.isEnabled, let endpoint else { return false }
        guard let frame = currentFrame() else { return true }
        let box = FrameBox(frame: frame)
        let date = Date()
        let profileID = profileID
        let canPersist = canPersist
        let forgetCount = forgetCount
        let removals = profileID.map { RemoteScreenSnapshotStore.shared.removals(of: $0) }
        Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                RemoteScreenSnapshotRecorder.render(box.frame)
            }.value
            guard let rendered, RemoteScreenSnapshotStore.shared.isEnabled else { return }
            // Saved even if the pane is gone: this is often its closing
            // frame. Not for a profile deleted or repointed meanwhile, nor
            // one whose screen was forgotten while this was rendering.
            if let profileID, let removals, canPersist(profileID, endpoint) {
                RemoteScreenSnapshotStore.shared.save(
                    jpeg: rendered.jpeg, profileID: profileID, endpoint: endpoint,
                    capturedAt: date, ifRemovalsAre: removals)
            }
            guard let self, self.endpoint == endpoint, self.forgetCount == forgetCount else { return }
            if date >= (self.latest?.capturedAt ?? .distantPast) {
                self.latest = (rendered.jpeg, date)
            }
            self.show(RemoteScreenSnapshot(image: rendered.image.image, capturedAt: date))
        }
        return false
    }

    /// Let go of every picture this pane holds: the setting was turned off,
    /// the saved screen was deleted, or the route moved.
    func forget() {
        forgetCount += 1
        latest = nil
        placeholder = nil
    }

    func stop() {
        liveTask?.cancel()
        liveTask = nil
        isConnected = false
        isLive = false
    }

    // MARK: Internals

    /// Newest wins: a capture, a decode and a disk load can finish in any order.
    private func show(_ snapshot: RemoteScreenSnapshot) {
        guard !isLive, RemoteScreenSnapshotStore.shared.isEnabled,
              snapshot.capturedAt >= (placeholder?.capturedAt ?? .distantPast) else { return }
        placeholder = snapshot
    }

    /// This session's newest capture, else the profile's saved screen.
    private func restorePlaceholder() {
        guard !isLive, RemoteScreenSnapshotStore.shared.isEnabled, let endpoint else { return }
        if let latest {
            let jpeg = latest.jpeg
            let date = latest.capturedAt
            Task { [weak self] in
                let decoded = await Task.detached(priority: .userInitiated) {
                    RemoteScreenSnapshotCodec.decodeImage(jpeg).map(ImageBox.init)
                }.value
                // Forgotten or repointed while decoding.
                guard let self, let decoded, self.latest?.capturedAt == date else { return }
                self.show(RemoteScreenSnapshot(image: decoded.image, capturedAt: date))
            }
        } else if let profileID {
            Task { [weak self] in
                let saved = await RemoteScreenSnapshotStore.shared.load(profileID: profileID, endpoint: endpoint)
                guard let self, let saved, self.profileID == profileID, self.endpoint == endpoint else { return }
                self.show(saved)
            }
        }
    }

    private nonisolated struct FrameBox: @unchecked Sendable {
        let frame: Frame
    }

    private nonisolated struct ImageBox: @unchecked Sendable {
        let image: CGImage
    }

    /// Scale to the stored size and encode. Nil for a blank frame.
    private nonisolated static func render(_ frame: Frame) -> (image: ImageBox, jpeg: Data)? {
        guard let source = compose(frame) else { return nil }
        let extent = source.extent.integral
        let target = RemoteScreenSnapshotCodec.scaledSize(
            width: Int(extent.width),
            height: Int(extent.height),
            maxDimension: RemoteScreenSnapshotCodec.maxPixelDimension)
        guard target.width > 0, target.height > 0 else { return nil }

        var output = source
        if target.width != Int(extent.width) || target.height != Int(extent.height) {
            output = source.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: Double(target.height) / Double(extent.height),
                kCIInputAspectRatioKey: 1.0,
            ])
        }
        // One capture every so often: not worth holding a context between them.
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let image = context.createCGImage(
            output,
            from: CGRect(x: 0, y: 0, width: target.width, height: target.height),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)),
              !RemoteScreenSnapshotCodec.isBlank(image),
              let jpeg = RemoteScreenSnapshotCodec.encodeJPEG(image) else { return nil }
        return (ImageBox(image: image), jpeg)
    }

    /// One picture at the origin: the image itself, or every display's
    /// surface placed in its region over black.
    private nonisolated static func compose(_ frame: Frame) -> CIImage? {
        switch frame {
        case .image(let image):
            return CIImage(cgImage: image)
        case .surfaces(let surfaces):
            guard let first = surfaces.first else { return nil }
            let canvas = surfaces.dropFirst().reduce(first.region) { $0.union($1.region) }.integral
            guard canvas.width > 0, canvas.height > 0 else { return nil }
            var picture = CIImage(color: .black).cropped(
                to: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            for surface in surfaces {
                let image = CIImage(cvPixelBuffer: surface.pixelBuffer)
                guard image.extent.width > 0, image.extent.height > 0,
                      surface.region.width > 0, surface.region.height > 0 else { continue }
                // Regions count down from the top; Core Image counts up.
                let placed = image
                    .transformed(by: CGAffineTransform(
                        scaleX: surface.region.width / image.extent.width,
                        y: surface.region.height / image.extent.height))
                    .transformed(by: CGAffineTransform(
                        translationX: surface.region.minX - canvas.minX,
                        y: canvas.maxY - surface.region.maxY))
                picture = placed.composited(over: picture)
            }
            return picture.cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        }
    }
}
