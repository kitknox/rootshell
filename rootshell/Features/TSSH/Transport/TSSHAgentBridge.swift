//
//  TSSHAgentBridge.swift
//  rootshell
//
//  Bridges Go agent callbacks to SSHAgentManager on MainActor.
//  Go goroutines call this synchronously via gomobile; the bridge
//  dispatches to MainActor and blocks the goroutine until complete.
//

import Citadel
import Foundation
import NIOCore
import NIOFoundationCompat
import os
import OSLog
#if CHINA_BUILD || targetEnvironment(macCatalyst)
@preconcurrency import TrzszSSH
#else
@preconcurrency import TsshKit
#endif

/// Bridges Go's `AgentCallback` interface to Swift's `SSHAgentManager`.
///
/// Go's `agent.ServeAgent` calls `ListIdentities()` and `SignData()` from
/// per-channel goroutines. These methods block the goroutine using a
/// `DispatchSemaphore` while async MainActor work completes. This is safe
/// because gomobile calls always originate from background goroutine threads,
/// never the main thread.
///
/// Background-suspension safety: while the app is backgrounded the goroutine
/// MUST NOT park on the semaphore — a wedged goroutine holding Go-side mutexes
/// can make later Swift calls into Go stall. Both entry points refuse fast on
/// background; the wait itself has a 2 s defensive cap.
nonisolated final class TrzszAgentBridge: NSObject, IosbridgeAgentCallbackProtocol, @unchecked Sendable {

    private let agentManager: SSHAgentManager

    /// In-flight `@MainActor` Tasks spawned by `listIdentities`/`sign`. Tracked
    /// so `cancelInFlightTasks()` (called on app background) can cancel them —
    /// the Tasks then signal their semaphores immediately so the goroutines
    /// unwedge before the Go side accumulates back-pressure.
    private nonisolated let inFlightTasks = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

    private nonisolated static let logger = Logger(
        subsystem: "com.kk2.rootshell",
        category: "TrzszAgentBridge"
    )

    /// Defensive upper bound on goroutine parking time. The fix is "don't park
    /// at all when backgrounded" (see early-return); this just prevents an
    /// unknown bug from holding the goroutine forever.
    private static let waitTimeoutSeconds: Double = 2.0

    private nonisolated static var shouldDenyForLifecycle: Bool {
        Ghostty.isAppBackgroundedAtomic
    }

    private nonisolated static var lifecycleDenyMessage: String {
        "app backgrounded"
    }

    init(agentManager: SSHAgentManager) {
        self.agentManager = agentManager
        super.init()
    }

    /// Cancel all in-flight bridge Tasks. Called from `MainViewLifecycle.handleAppBackgrounded()`.
    /// The cancelled Tasks fall through their bodies and signal their semaphores,
    /// unwedging the calling Go goroutines immediately.
    nonisolated func cancelInFlightTasks() {
        let tasks = inFlightTasks.withLock { dict -> [Task<Void, Never>] in
            let values = Array(dict.values)
            dict.removeAll()
            return values
        }
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - IosbridgeAgentCallbackProtocol
    //
    // ObjC: - (NSString* _Nonnull)listIdentities:(NSError**)error
    // Returns _Nonnull so Swift imports with NSErrorPointer (can't use throws).
    //
    // ObjC: - (NSData* _Nullable)signData:(NSData*)pub data:(NSData*)data flags:(int32_t)f error:(NSError**)error
    // Returns _Nullable so Swift imports as throws.

    func listIdentities(_ error: NSErrorPointer) -> String {
        // Refuse fast while backgrounded — never let the goroutine park while
        // the user cannot answer an approval sheet.
        if Self.shouldDenyForLifecycle {
            let message = Self.lifecycleDenyMessage
            Self.logger.info("listIdentities denied: \(message)")
            error?.pointee = Self.deniedError(message: message)
            return "[]"
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: String = "[]"
        var listError: (any Error)?

        let manager = self.agentManager
        let taskID = UUID()
        let task = Task { @MainActor in
            defer {
                self.inFlightTasks.withLock { _ = $0.removeValue(forKey: taskID) }
                semaphore.signal()
            }
            // Re-check inside the Task: the app may have backgrounded between
            // the entry guard and now. Auto-deny rather than fire UI prompts.
            if Ghostty.isAppBackgrounded || Task.isCancelled {
                listError = Self.deniedError(message: "cancelled or backgrounded")
                return
            }
            do {
                let identities = try await manager.listIdentities()
                var jsonArray: [[String: String]] = []
                for identity in identities {
                    var blob = identity.publicKeyBlob
                    let blobData = blob.readData(length: blob.readableBytes) ?? Data()
                    jsonArray.append([
                        "blob": blobData.base64EncodedString(),
                        "comment": identity.comment,
                    ])
                }
                let jsonData = try JSONSerialization.data(withJSONObject: jsonArray)
                result = String(data: jsonData, encoding: .utf8) ?? "[]"
            } catch {
                listError = error
            }
        }
        inFlightTasks.withLock { $0[taskID] = task }

        let waitResult = semaphore.wait(timeout: .now() + Self.waitTimeoutSeconds)
        if waitResult == .timedOut {
            // Cancel the still-running Task so it unblocks the next time main
            // actor runs; abandon the result here so the goroutine returns.
            task.cancel()
            inFlightTasks.withLock { _ = $0.removeValue(forKey: taskID) }
            Self.logger.warning("listIdentities timed out after \(Self.waitTimeoutSeconds)s — denying")
            error?.pointee = Self.deniedError(message: "timed out")
            return "[]"
        }
        if let err = listError {
            error?.pointee = err as NSError
            return "[]"
        }
        Self.logger.info("Listed \(result.count) bytes of identity JSON")
        return result
    }

    func sign(_ publicKeyBlob: Data?, data: Data?, flags: Int32) throws -> Data {
        guard let publicKeyBlob, let data else {
            throw Self.deniedError(message: "nil parameters in signData")
        }

        // Refuse fast while backgrounded — never let the goroutine park, and
        // never trigger an approval sheet the user cannot answer.
        if Self.shouldDenyForLifecycle {
            let message = Self.lifecycleDenyMessage
            Self.logger.info("sign denied: \(message)")
            throw Self.deniedError(message: message)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var signatureData: Data?
        var signError: (any Error)?

        let manager = self.agentManager
        let blobCopy = publicKeyBlob
        let dataCopy = data
        let taskID = UUID()
        let task = Task { @MainActor in
            defer {
                self.inFlightTasks.withLock { _ = $0.removeValue(forKey: taskID) }
                semaphore.signal()
            }
            if Ghostty.isAppBackgrounded || Task.isCancelled {
                signError = Self.deniedError(message: "cancelled or backgrounded")
                return
            }
            do {
                let blobBuffer = ByteBuffer(data: blobCopy)
                let dataBuffer = ByteBuffer(data: dataCopy)
                if let sigBuffer = try await manager.sign(
                    publicKeyBlob: blobBuffer,
                    data: dataBuffer,
                    flags: UInt32(bitPattern: flags)
                ) {
                    var mutableSig = sigBuffer
                    signatureData = mutableSig.readData(length: mutableSig.readableBytes)
                }
            } catch {
                signError = error
            }
        }
        inFlightTasks.withLock { $0[taskID] = task }

        let waitResult = semaphore.wait(timeout: .now() + Self.waitTimeoutSeconds)
        if waitResult == .timedOut {
            task.cancel()
            inFlightTasks.withLock { _ = $0.removeValue(forKey: taskID) }
            Self.logger.warning("sign timed out after \(Self.waitTimeoutSeconds)s — denying")
            throw Self.deniedError(message: "timed out")
        }
        if let error = signError {
            throw error
        }
        guard let sig = signatureData else {
            throw Self.deniedError(message: "signing denied or no matching key")
        }
        Self.logger.info("Signed data successfully (\(sig.count) bytes)")
        return sig
    }

    // MARK: - Helpers

    private static func deniedError(message: String) -> NSError {
        NSError(
            domain: "TrzszAgentBridge",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
