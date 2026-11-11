//
//  KVMH264Decoder.swift
//  rootshell
//
//  Hardware H.264 decode of kvmd-media access units into BGRA IOSurface
//  buffers for the shared video layer. Frames are submitted from one serial
//  queue and decoded asynchronously, so the hardware works on several at once.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

nonisolated struct KVMDecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}

nonisolated struct KVMVideoFormat: Equatable, Sendable {
    let width: Int
    let height: Int
    let profileLevel: String?
}

nonisolated final class KVMH264Decoder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "KVM")
    /// Frames waiting on the queue before P-frames are dropped for a fresh
    /// keyframe. Only a decoder that can't keep up gets here: Wi-Fi delivers
    /// frames in clumps, and each requested keyframe costs the KVM a large
    /// frame, so GL's own client never asks for one.
    private static let maximumBacklog = 120
    /// Hard caps that keyframes obey too, so a server can't grow the queue
    /// without bound.
    private static let maximumQueuedFrames = maximumBacklog + 16
    private static let maximumQueuedBytes = 64 * 1024 * 1024
    /// Re-ask while frames arrive without a keyframe; longer than
    /// KVMSession's 0.5 s request throttle, which drops rather than delays.
    private static let keyframeRetryInterval: Duration = .seconds(1)

    private let queue = DispatchQueue(label: "com.rootshell.kvm.decode", qos: .userInteractive)
    private let onFrame: @Sendable (KVMDecodedFrame) -> Void
    private let onFormat: @Sendable (KVMVideoFormat) -> Void
    private let onNeedsKeyframe: @Sendable () -> Void

    private let backlogLock = NSLock()
    private var backlog = 0
    private var backlogBytes = 0
    private var decodeErrors = 0

    // Queue-confined.
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var format: KVMVideoFormat?
    private var awaitingKeyframe = true
    private var lastKeyframeRequest: ContinuousClock.Instant?
    private var frameNumber: Int64 = 0

    init(
        onFrame: @escaping @Sendable (KVMDecodedFrame) -> Void,
        onFormat: @escaping @Sendable (KVMVideoFormat) -> Void,
        onNeedsKeyframe: @escaping @Sendable () -> Void
    ) {
        self.onFrame = onFrame
        self.onFormat = onFormat
        self.onNeedsKeyframe = onNeedsKeyframe
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    var errorCount: Int {
        backlogLock.withLock { decodeErrors }
    }

    func submit(_ accessUnit: Data, isKeyframe: Bool) {
        let size = accessUnit.count
        let admitted: Bool = backlogLock.withLock {
            let frameLimit = isKeyframe ? Self.maximumQueuedFrames : Self.maximumBacklog
            guard backlog < frameLimit,
                  backlogBytes == 0 || backlogBytes + size <= Self.maximumQueuedBytes else { return false }
            backlog += 1
            backlogBytes += size
            return true
        }
        guard admitted else {
            // A dropped keyframe may be the one already requested; ask again.
            queue.async { [self] in
                if isKeyframe || !awaitingKeyframe { requestKeyframe() }
            }
            return
        }
        queue.async { [self] in
            defer {
                backlogLock.withLock {
                    backlog -= 1
                    backlogBytes -= size
                }
            }
            decode(accessUnit)
        }
    }

    /// Drops the session, e.g. after backgrounding; the next IDR rebuilds it.
    func reset() {
        queue.async { [self] in
            invalidateSession()
            formatDescription = nil
            sps = nil
            pps = nil
            awaitingKeyframe = true
        }
    }

    // MARK: Decode

    private func decode(_ accessUnit: Data) {
        let nals = AnnexB.nalUnits(in: accessUnit)
        var slices: [Data] = []
        var containsIDR = false
        var newSPS: Data?
        var newPPS: Data?
        for nal in nals {
            switch AnnexB.type(of: nal) {
            case AnnexB.NALType.sps.rawValue: newSPS = nal
            case AnnexB.NALType.pps.rawValue: newPPS = nal
            case AnnexB.NALType.idr.rawValue:
                containsIDR = true
                slices.append(nal)
            case 1...4:
                slices.append(nal)
            default:
                break
            }
        }

        if let newSPS, let newPPS, newSPS != sps || newPPS != pps {
            guard updateFormat(sps: newSPS, pps: newPPS) else {
                requestKeyframe()
                return
            }
        }

        // An invalidated session keeps its parameter sets; rebuild from them.
        if session == nil, let formatDescription {
            guard createSession(for: formatDescription) else {
                requestKeyframe()
                return
            }
        }

        guard !slices.isEmpty else { return }
        if awaitingKeyframe {
            guard containsIDR, session != nil else {
                // The last request may have been throttled or its answer dropped.
                if let lastKeyframeRequest, .now - lastKeyframeRequest < Self.keyframeRetryInterval { return }
                requestKeyframe()
                return
            }
            awaitingKeyframe = false
        }
        guard let session, let formatDescription else { return }

        guard let sample = Self.sampleBuffer(
            AnnexB.lengthPrefixed(slices),
            format: formatDescription,
            frameNumber: frameNumber) else {
            requestKeyframe()
            return
        }
        frameNumber += 1

        // Waiting for each frame before the next held a busy screen's video
        // seconds behind. A clump catches up without producing older images.
        let isStale = backlogLock.withLock { backlog } > 1
        var flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        if isStale { flags.insert(._DoNotOutputFrame) }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: flags,
            infoFlagsOut: nil
        ) { [weak self, onFrame] status, _, imageBuffer, _, _ in
            guard status == noErr else {
                self?.outputFailed(status)
                return
            }
            guard let imageBuffer else { return }
            onFrame(KVMDecodedFrame(pixelBuffer: imageBuffer))
        }
        guard status == noErr else {
            backlogLock.withLock { decodeErrors += 1 }
            Self.logger.error("KVM H.264 decode failed: \(status)")
            if status == kVTInvalidSessionErr {
                invalidateSession()
            }
            requestKeyframe()
            return
        }
    }

    private func requestKeyframe() {
        awaitingKeyframe = true
        lastKeyframeRequest = .now
        onNeedsKeyframe()
    }

    /// Asynchronous decode reports frame errors here, off the queue.
    private func outputFailed(_ status: OSStatus) {
        backlogLock.withLock { decodeErrors += 1 }
        Self.logger.error("KVM H.264 frame decode failed: \(status)")
        queue.async { [self] in requestKeyframe() }
    }

    private func updateFormat(sps: Data, pps: Data) -> Bool {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else {
            Self.logger.error("KVM H.264 parameter sets rejected: \(status)")
            return false
        }
        self.sps = sps
        self.pps = pps
        formatDescription = description

        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            // Same session continues across compatible parameter sets.
        } else {
            invalidateSession()
            guard createSession(for: description) else { return false }
        }

        let size = CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: false,
            useCleanAperture: true)
        let newFormat = KVMVideoFormat(
            width: Int(size.width),
            height: Int(size.height),
            profileLevel: AnnexB.profileLevel(fromSPS: sps))
        if newFormat != format {
            format = newFormat
            Self.logger.info("KVM video \(newFormat.width)x\(newFormat.height) \(newFormat.profileLevel ?? "?", privacy: .public)")
            onFormat(newFormat)
        }
        return true
    }

    private func createSession(for description: CMVideoFormatDescription) -> Bool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession)
        guard status == noErr, let newSession else {
            Self.logger.error("KVM H.264 session creation failed: \(status)")
            return false
        }
        _ = VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        return true
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    private static func sampleBuffer(
        _ data: Data,
        format: CMVideoFormatDescription,
        frameNumber: Int64
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        var sampleSize = data.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frameNumber, timescale: 60),
            decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
