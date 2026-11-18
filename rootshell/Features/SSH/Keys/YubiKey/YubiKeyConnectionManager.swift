//
//  YubiKeyConnectionManager.swift
//  rootshell
//
//  Manages YubiKey connections across Lightning, NFC, and USB-C transports
//  Migrated to yubikit-swift SDK with factory-based connections
//
//  Copyright (c) 2026 Kit Knox / Rootshell LLC
//

import Foundation
import Combine
import os
import YubiKit
#if os(iOS) && !os(visionOS)
import CoreNFC
#endif
#if os(iOS) && !DISABLE_MFI_LIGHTNING
import ExternalAccessory
#endif

/// Manages YubiKey connections across all transport types
///
/// This implementation uses the yubikit-swift SDK with factory-based connections:
/// - NFCSmartCardConnection (iOS NFC)
/// - LightningSmartCardConnection (iOS Lightning port)
/// - USBSmartCardConnection (macOS/iOS USB-C)
///
/// Connections are created on-demand rather than using persistent listeners.
@MainActor
@Observable
final class YubiKeyConnectionManager {
    @ObservationIgnored private nonisolated static let logger = Logger(
        subsystem: "com.rootshell",
        category: "YubiKeyConnection"
    )

    static let shared = YubiKeyConnectionManager()

    // MARK: - Observable State

    /// Current connection state
    private(set) var connectionState: YubiKeyConnectionState = .disconnected

    /// Available transport methods on this device
    private(set) var availableTransports: Set<YubiKeyConnectionMethod> = []

    /// Pending PIN request for UI to display
    var pendingPINRequest: YubiKeyPINRequest?

    // MARK: - Connection Storage (internal, not observed)

    /// A live connection with the transport it runs on and the serial that was
    /// read over it when it opened. One record, so the three can't drift apart.
    private struct LiveConnection {
        /// The connect attempt that opened it.
        let id: Int
        let connection: any SmartCardConnection
        let method: YubiKeyConnectionMethod
        let serial: UInt32
    }

    /// The one connection in use, if any.
    @ObservationIgnored private var live: LiveConnection?

    /// Bumped by every connect() and disconnect(). An attempt publishes its
    /// connection only while its number is still current, so a tap or insert
    /// that lands after a newer attempt began is closed instead of going live.
    @ObservationIgnored private var connectAttempt = 0

    /// Firmware version of the connected YubiKey (e.g., "5.7.0")
    private(set) var connectedFirmwareVersion: String?

    /// Form factor/model of the connected YubiKey
    private(set) var connectedFormFactor: FormFactor?

    /// The key most recently read, kept after an NFC session ends so the UI can
    /// still show it and offer actions that reconnect on demand.
    private(set) var lastReadDevice: YubiKeyDeviceSnapshot?

    /// Whether an NFC session is currently active
    @ObservationIgnored private var isNFCSessionActive = false

    /// The in-flight connect attempt on any transport. A later connect() joins
    /// it (NFC to NFC) or cancels and drains it before opening its own, so the
    /// SDK never sees two opens at once.
    @ObservationIgnored private var pendingConnect: (task: Task<Void, Error>, method: YubiKeyConnectionMethod, attempt: Int)?

    /// Bumped whenever we deliberately close connections. Disconnection
    /// monitors capture the value they were spawned under; a monitor whose
    /// generation is stale reports the close of an old connection and must not
    /// tear down state belonging to a newer one (the SDK connections are
    /// structs, so there's no reference identity to compare instead).
    @ObservationIgnored private var connectionGeneration = 0

    /// Whether an operation currently has exclusive use of the YubiKey.
    @ObservationIgnored private var isInUse = false

    /// An operation queued for exclusive use, with what it asked for on arrival.
    /// Whether a queued operation's task has been cancelled. Set from the
    /// task's cancellation handler on whatever thread cancels it, so the
    /// preemption check sees it at once instead of after a hop to the main actor.
    private nonisolated final class WaiterCancellation: Sendable {
        private let flag = OSAllocatedUnfairLock(initialState: false)

        var isCancelled: Bool {
            flag.withLock { $0 }
        }

        func cancel() {
            flag.withLock { $0 = true }
        }
    }

    private struct UseWaiter {
        /// Resumed with whether the waiter now owns exclusive use.
        let continuation: CheckedContinuation<Bool, Never>
        /// The operation ahead of it should stop waiting for a key, unless
        /// this waiter's task has since been cancelled.
        let preempts: Bool
        let cancellation: WaiterCancellation
        /// Serial of the YubiKey whose live NFC session it can take over and
        /// will end itself; nil if it opens its own.
        let nfcSessionSerial: UInt32?
    }

    /// Operations waiting for exclusive use, oldest first.
    @ObservationIgnored private var useWaiters: [UseWaiter] = []

    /// Outer safety bound for a wired connect. The real gate is the user's
    /// Cancel in the hardware-key overlay (wait-until-cancel UX); this large
    /// value just backstops a wedged SDK call so a detached signing task can't
    /// hang forever. Kept below the NIOSSH signing timeout so the friendlier
    /// `.noDeviceDetected` error wins over a generic semaphore timeout.
    private static let wiredConnectTimeout: Duration = .seconds(600)

    // MARK: - Initialization

    private init() {
        checkAvailableTransports()
    }

    // MARK: - Transport Detection

    private func checkAvailableTransports() {
        var transports: Set<YubiKeyConnectionMethod> = []

        #if os(iOS) && !os(visionOS)
        // NFC is available on iPhone 7+ and newer iPads with NFC
        if NFCReaderSession.readingAvailable {
            transports.insert(.nfc)
        }
        #endif

        #if os(iOS) && !DISABLE_MFI_LIGHTNING
        // Lightning accessory (MFI key) - always available on iOS
        transports.insert(.lightning)
        #endif

        // USB-C Smart Card is always available on iOS 16+ and macOS 13+
        transports.insert(.usbc)

        availableTransports = transports
        Self.logger.info("Available YubiKey transports: \(transports.map { $0.rawValue }.joined(separator: ", "))")
    }

    // MARK: - Exclusive Use

    /// Wait for exclusive use of the YubiKey. Every operation that connects,
    /// talks to the key or ends an NFC session holds this for its whole run, so
    /// one can't close or reuse a session another is still working on.
    /// - Returns: Whether the caller now owns exclusive use. False if its task
    ///   was cancelled before or while it queued: it then left the queue at
    ///   once, owns nothing, and must not call `endExclusiveUse()`. On true,
    ///   pair with `endExclusiveUse()` in a defer.
    /// - Parameters:
    ///   - preemptingPendingConnect: Settings actions pass true. The operation
    ///     ahead then gives way instead of waiting for a key: a wired wait
    ///     already running is cancelled, and one not yet started is refused
    ///     in connect(). Signing passes false and simply queues.
    ///   - serial: Signing passes the serial its key lives on: it can take
    ///     over an NFC session to that YubiKey left open by the operation
    ///     ahead, and ends it itself.
    func beginExclusiveUse(
        preemptingPendingConnect: Bool = false,
        reusingNFCSessionOf serial: UInt32? = nil
    ) async -> Bool {
        // A caller that has already given up neither queues nor preempts.
        guard !Task.isCancelled else { return false }
        guard isInUse else {
            isInUse = true
            return true
        }
        let preempts = preemptingPendingConnect
        if preempts {
            cancelPendingConnection()
        }
        Self.logger.info("Waiting for the current YubiKey operation to finish")
        let cancellation = WaiterCancellation()
        // The queue entry is also the record of the preemption request: the
        // operation ahead checks it before it starts waiting for a key.
        // Resumed with true by handOffExclusiveUse(), isInUse still set, or
        // with false by abandonWait() once its task is cancelled.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                useWaiters.append(UseWaiter(
                    continuation: continuation,
                    preempts: preempts,
                    cancellation: cancellation,
                    nfcSessionSerial: serial
                ))
            }
        } onCancel: {
            // The caller gave up while queued. From this instant it no longer
            // makes the operation ahead give way; it leaves the queue on the
            // next main-actor turn rather than holding its place and its data
            // until every operation ahead has finished.
            cancellation.cancel()
            Task { @MainActor in
                self.abandonWait(cancellation)
            }
        }
    }

    /// Take a cancelled waiter out of the queue and tell it that it owns
    /// nothing. No-op if it was handed exclusive use first.
    private func abandonWait(_ cancellation: WaiterCancellation) {
        guard let index = useWaiters.firstIndex(where: { $0.cancellation === cancellation }) else { return }
        useWaiters.remove(at: index).continuation.resume(returning: false)
    }

    /// Give up exclusive use. An NFC session still open is ended first unless
    /// the next operation takes it over, so the sheet never outlives the
    /// operations that use it.
    func endExclusiveUse() {
        #if os(iOS) && !os(visionOS)
        if live?.method == .nfc, !nextOperationReusesNFCSession {
            Task {
                // Still held during the close, so nothing starts on this session.
                await closeNFCSessionImmediately()
                handOffExclusiveUse()
            }
            return
        }
        #endif
        handOffExclusiveUse()
    }

    /// Hand exclusive use straight to the next waiter. The flag clears only
    /// when nobody is queued: clearing it first would let a new arrival run
    /// alongside the resumed waiter.
    private func handOffExclusiveUse() {
        guard !useWaiters.isEmpty else {
            isInUse = false
            return
        }
        useWaiters.removeFirst().continuation.resume(returning: true)
    }

    /// Whether the operation queued next takes over the live NFC session and
    /// ends it itself: it must be for the YubiKey that session is connected
    /// to. Only then may the current operation leave the session open.
    var nextOperationReusesNFCSession: Bool {
        guard let live, live.method == .nfc, live.serial != 0,
              let next = useWaiters.first, !next.cancellation.isCancelled,
              let serial = next.nfcSessionSerial else {
            return false
        }
        return serial == live.serial
    }

    /// A queued operation asked the current one to stop waiting for a key.
    private var isPreempted: Bool {
        useWaiters.contains { $0.preempts && !$0.cancellation.isCancelled }
    }

    // MARK: - Connection Methods

    /// Connect to YubiKey using the best available method
    /// - Parameter preferredMethod: Optional preferred connection method
    /// - Throws: YubiKeyError if connection fails
    func connect(preferredMethod: YubiKeyConnectionMethod? = nil) async throws {
        // If already connected, return
        if case .connected = connectionState, live != nil {
            Self.logger.info("Already connected to YubiKey")
            return
        }

        // Requests are ordered by when they arrive, not by when their
        // transport query returns.
        let generationAtEntry = connectAttempt

        let method: YubiKeyConnectionMethod
        if let preferredMethod {
            method = preferredMethod
        } else {
            method = await selectBestTransport()
            // An attempt that was pending may have gone live meanwhile.
            if case .connected = connectionState, live != nil {
                Self.logger.info("Already connected to YubiKey")
                return
            }
            // A newer connect() or a disconnect arrived during the query. This
            // older request must not cancel it or start over it.
            guard connectAttempt == generationAtEntry else { throw YubiKeyError.userCancelled }
        }

        // One NFC scan runs at a time, and it belongs to the operation that
        // started it. A second request neither shares the session, where one
        // caller could close it under the other, nor discards the pending tap.
        if method == .nfc, let pending = pendingConnect, pending.method == .nfc, !pending.task.isCancelled {
            throw YubiKeyError.operationInProgress
        }

        // Supersede every earlier attempt: one still waiting on a tap or
        // insert must not publish its connection later.
        connectAttempt += 1
        let attempt = connectAttempt

        // If a previous attempt is still waiting for a key, cancel it and wait
        // for it to unwind, so the user can switch transports without waiting
        // for the timeout and the SDK never has two opens in flight.
        if let prior = pendingConnect {
            prior.task.cancel()
            _ = try? await prior.task.value
            guard attempt == connectAttempt else { throw YubiKeyError.userCancelled }
            if pendingConnect?.attempt == prior.attempt {
                pendingConnect = nil
            }
        }

        // Self-heal: a connection left behind by a failed operation (state no
        // longer .connected) still occupies the SDK's per-transport slot, so
        // opening a new one would fail with "another connection in progress".
        // Close it before reconnecting — unless a live operation owns it.
        if live != nil {
            switch connectionState {
            case .connected:
                // The drained connect attempt above finished successfully
                // (cancel lost the race) — reuse its connection.
                Self.logger.info("Pending connect completed while draining — reusing connection")
                return
            case .authenticating, .signing:
                // An in-flight PIN check or signature is using this connection;
                // closing it here would fail that operation mid-flight.
                throw YubiKeyError.connectionFailed("A YubiKey operation is already in progress")
            default:
                Self.logger.warning("Stale YubiKey connection detected — closing before reconnect")
                await closeAllConnections()
            }
        }

        // A newer connect() or a disconnect arrived during the awaits above.
        guard attempt == connectAttempt else { throw YubiKeyError.userCancelled }
        // A queued Settings action asked this operation to give way, possibly
        // before it had a pending connect to cancel. Don't start a wait for a
        // key that the action would be stuck behind.
        guard !isPreempted else { throw YubiKeyError.userCancelled }
        setState(.connecting(method: method))

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performConnect(method: method, attempt: attempt)
        }
        pendingConnect = (task, method, attempt)
        defer {
            if pendingConnect?.attempt == attempt {
                pendingConnect = nil
            }
        }

        do {
            try await Self.waitForConnect(task)
        } catch {
            // Cancelled through its caller, the attempt has nobody else to
            // reset the state it left at connecting.
            if attempt == connectAttempt, connectionState.connectingTransport != nil {
                setState(.disconnected)
            }
            throw error
        }
    }

    /// Await a connect attempt, reporting cancellation as userCancelled. If the
    /// caller is cancelled, so is the attempt, and this still waits for it to
    /// unwind: the wait for a key ends, and the caller releases the queue only
    /// once the SDK connection is gone.
    private static func waitForConnect(_ task: Task<Void, Error>) async throws {
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            // Cancelled by cancelPendingConnection() or a subsequent connect call.
            // State has already been reset by the canceller; surface as userCancelled.
            throw YubiKeyError.userCancelled
        }
    }

    /// Perform the actual connect work. Split out from connect() so the outer
    /// function can wrap it in a cancellable Task.
    private func performConnect(method: YubiKeyConnectionMethod, attempt: Int) async throws {
        // Held here, not in `live`, until its identity is read and the attempt
        // is confirmed current.
        var opened: (any SmartCardConnection)?
        do {
            let connection: any SmartCardConnection
            switch method {
            case .nfc:
                #if os(iOS) && !os(visionOS)
                connection = try await connectNFC()
                #else
                throw YubiKeyError.nfcNotAvailable
                #endif
            case .lightning:
                #if os(iOS) && !DISABLE_MFI_LIGHTNING
                connection = try await connectLightning(attempt: attempt)
                #else
                throw YubiKeyError.unsupportedFeature("Lightning disabled (MFI approval pending)")
                #endif
            case .usbc:
                connection = try await connectUSBC(attempt: attempt)
            }
            opened = connection

            // Read the identity over this connection itself, so the serial
            // can't come from another one that opened in the meantime.
            let deviceInfo = try await readDeviceInfo(over: connection)

            // Superseded or cancelled while waiting on the tap, insert or
            // device info: this connection must not go live.
            guard attempt == connectAttempt, !Task.isCancelled else { throw CancellationError() }

            let record = LiveConnection(
                id: attempt,
                connection: connection,
                method: method,
                serial: UInt32(truncatingIfNeeded: deviceInfo.serialNumber)
            )
            publish(record, deviceInfo: deviceInfo)
            opened = nil
            Self.logger.info("Connected to YubiKey (SN: \(record.serial)) via \(method.rawValue)")

            // Start monitoring for disconnection
            monitorConnection(record)

        } catch {
            // Never published, so nothing else will close it; left open it
            // would hold the SDK's transport slot.
            if let opened {
                await opened.close(error: attempt == connectAttempt ? error : nil)
            }
            // Checked after the awaited close, right before shared state is
            // touched: a newer attempt may have begun while this one closed.
            let superseded = attempt != connectAttempt
            if method == .nfc {
                isNFCSessionActive = live?.method == .nfc
            }
            // A superseded attempt must not touch state that now belongs to a
            // newer one. connect() reports cancellation as userCancelled.
            if superseded || error is CancellationError || Task.isCancelled {
                // Don't overwrite state here: cancelPendingConnection() or the
                // superseding connect() already set it.
                throw CancellationError()
            }
            if let yubiKeyError = error as? YubiKeyError, case .userCancelled = yubiKeyError {
                // A cancelled wired wait surfaces from the SDK as
                // SmartCardConnectionError.cancelled, already mapped to
                // userCancelled. Settle on .disconnected, never .error.
                setState(.disconnected)
                throw YubiKeyError.userCancelled
            }
            setState(.error(error.localizedDescription))
            if let yubiKeyError = error as? YubiKeyError {
                throw yubiKeyError
            }
            throw YubiKeyError.connectionFailed(error.localizedDescription)
        }
    }

    /// Make a connection live: the record, the values the UI shows, and the
    /// state, in one step with no await in between.
    private func publish(_ record: LiveConnection, deviceInfo: DeviceInfo) {
        live = record
        connectedFormFactor = deviceInfo.formFactor
        connectedFirmwareVersion = deviceInfo.version.description
        lastReadDevice = YubiKeyDeviceSnapshot(
            serial: record.serial,
            firmwareVersion: deviceInfo.version.description,
            formFactor: deviceInfo.formFactor,
            method: record.method
        )
        setState(.connected(serial: record.serial, method: record.method))
    }

    /// Drop the live record and the values shown for it.
    private func clearLive() {
        if live?.method == .nfc {
            isNFCSessionActive = false
        }
        live = nil
        connectedFormFactor = nil
        connectedFirmwareVersion = nil
    }

    #if os(iOS) && !os(visionOS)
    /// Connect via NFC
    private func connectNFC() async throws -> NFCSmartCardConnection {
        Self.logger.info("Starting NFC connection")
        isNFCSessionActive = true

        do {
            return try await NFCSmartCardConnection(
                alertMessage: "Hold YubiKey against the top of your iPhone"
            )
        } catch {
            // SDK uses typed throws(SmartCardConnectionError)
            throw YubiKeyError.from(error)
        }
    }
    #endif

    #if os(iOS) && !DISABLE_MFI_LIGHTNING
    /// Connect via Lightning port
    private func connectLightning(attempt: Int) async throws -> LightningSmartCardConnection {
        Self.logger.info("Starting Lightning connection")
        // Surface the indefinite "Insert your YubiKey" prompt while the SDK
        // blocks waiting for a key on the port (wait-until-cancel).
        if attempt == connectAttempt {
            setState(.waitingForDevice(transport: .lightning))
        }

        do {
            return try await openWiredConnection(transport: .lightning) {
                try await LightningSmartCardConnection()
            }
        } catch let error as YubiKeyError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SmartCardConnectionError {
            throw YubiKeyError.from(error)
        } catch {
            throw YubiKeyError.connectionFailed(error.localizedDescription)
        }
    }
    #endif

    /// Connect via USB-C
    private func connectUSBC(attempt: Int) async throws -> USBSmartCardConnection {
        Self.logger.info("Starting USB-C connection")
        // Surface the indefinite "Insert your YubiKey" prompt while the SDK
        // blocks waiting for a key on the port (wait-until-cancel).
        if attempt == connectAttempt {
            setState(.waitingForDevice(transport: .usbc))
        }

        // A key whose USB smart card (CCID) interface is off never appears as a
        // slot, so record everything iOS reports for diagnosis.
        let slots = (try? await USBSmartCardConnection.availableDevices(matching: nil)) ?? []
        Self.logger.info("USB smart card slots: [\(slots.map(\.name).joined(separator: ", "), privacy: .public)]")

        do {
            return try await openWiredConnection(transport: .usbc) {
                try await USBSmartCardConnection()
            }
        } catch let error as YubiKeyError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SmartCardConnectionError {
            throw YubiKeyError.from(error)
        } catch {
            throw YubiKeyError.connectionFailed(error.localizedDescription)
        }
    }

    /// Open a wired SDK connection, recovering once from a stale-slot `.busy`.
    /// The SDK allows one connection per transport, released only by close()
    /// or physical key removal — so a connection leaked by an earlier failure
    /// makes every new open throw `.busy` until app restart. On `.busy`, close
    /// whatever we still hold, give the SDK a beat to deregister the slot, and
    /// retry a single time.
    private func openWiredConnection<T: SmartCardConnection>(
        transport: YubiKeyConnectionMethod,
        make: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await Self.awaitWithTimeout(Self.wiredConnectTimeout, transport: transport, operation: make)
        } catch SmartCardConnectionError.busy {
            Self.logger.warning("SDK transport slot busy — closing stale connections and retrying once")
            await closeAllConnections()
            try? await Task.sleep(for: .milliseconds(300))
            return try await Self.awaitWithTimeout(Self.wiredConnectTimeout, transport: transport, operation: make)
        }
    }

    /// Race an async operation against a timer. On timeout, cancels the
    /// operation and throws `YubiKeyError.noDeviceDetected(transport:)`.
    /// On Task cancellation by the caller, throws either CancellationError
    /// (timer child) or the operation's own cancellation error
    /// (`SmartCardConnectionError.cancelled`), whichever loses the race first.
    /// `operation` must be cancellation-responsive — a non-cancellable
    /// operation stalls the task group past cancel/timeout.
    private nonisolated static func awaitWithTimeout<T: SmartCardConnection>(
        _ timeout: Duration,
        transport: YubiKeyConnectionMethod,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self, returning: T.self) { group in
            group.addTask {
                let connection = try await operation()
                // If the timer (or the caller) already cancelled us, nobody
                // will consume this connection — close it, or it occupies the
                // SDK's transport slot forever ("another connection in
                // progress" on every subsequent open).
                if Task.isCancelled {
                    await connection.close(error: nil)
                    throw CancellationError()
                }
                return connection
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }

            defer { group.cancelAll() }

            // The first task to return wins. If the timer wins it returns nil
            // (the operation hasn't produced a value), so we throw the
            // no-device error. If the operation wins with a real value, return it.
            // If the operation throws, propagate.
            guard let result = try await group.next() else {
                throw YubiKeyError.noDeviceDetected(transport: transport)
            }
            if let value = result {
                return value
            }
            throw YubiKeyError.noDeviceDetected(transport: transport)
        }
    }

    /// Monitor connection for disconnection events
    private func monitorConnection(_ record: LiveConnection) {
        let generation = connectionGeneration
        Task {
            let error = await record.connection.waitUntilClosed()
            self.handleDisconnection(of: record, generation: generation, error: error)
        }
    }

    /// Get the current active SmartCard connection
    var activeSmartCardConnection: (any SmartCardConnection)? {
        live?.connection
    }

    /// Cancel an in-flight wired connect attempt (USB-C / Lightning).
    /// Does nothing if no attempt is pending or if a connection has already
    /// succeeded — use disconnect() to tear down a successful connection.
    func cancelPendingConnection() {
        // An NFC scan is cancelled from its own system sheet.
        guard let pending = pendingConnect, pending.method != .nfc else { return }
        let task = pending.task
        Self.logger.info("Cancelling pending YubiKey connect attempt")
        // Request cancellation but KEEP the task tracked. `cancel()` only
        // signals — the SDK connection keeps unwinding asynchronously. If we
        // cleared `pendingConnect` here, a quick retry's `connect()` would
        // skip its drain (`if let prior = pendingConnect { await
        // prior.task.value }`) and open a SECOND SDK connection while this one is
        // still tearing down → "another connection is in progress". The next
        // connect() drains it; if no retry comes, this connect()'s own defer
        // clears it once it finishes unwinding.
        task.cancel()
        // Reset visible state so the UI re-enables transport buttons. Covers
        // both the brief `.connecting` window and the indefinite
        // `.waitingForDevice` wait (wait-until-cancel), since Cancel can arrive
        // during either.
        switch connectionState {
        case .connecting, .waitingForDevice:
            setState(.disconnected)
        default:
            break
        }
    }

    /// Cancel whatever operation is currently in flight, picking the right
    /// teardown for the phase. A pending connect (waiting for the key) is simply
    /// cancelled; an established connection (PIN/signing) is disconnected.
    /// Calling BOTH races the SDK — `disconnect()` runs an async close that can
    /// collide with the cancellation and a subsequent connect, surfacing
    /// "another connection is in progress". So pick exactly one.
    func cancelCurrentOperation() {
        switch connectionState {
        case .connecting, .waitingForDevice:
            cancelPendingConnection()
        case .connected, .authenticating, .signing:
            disconnect()
        case .disconnected, .error:
            break
        }
    }

    /// Disconnect and clean up
    func disconnect() {
        Self.logger.info("Disconnecting YubiKey")

        // An attempt still waiting on a tap or insert must not go live afterwards.
        connectAttempt += 1

        Task {
            await closeAllConnections()

            isNFCSessionActive = false
            lastReadDevice = nil
            connectedFormFactor = nil
            connectedFirmwareVersion = nil
            setState(.disconnected)
        }
    }

    /// Close the held SDK connection and drop the record. Releasing the
    /// connection is what frees the SDK's per-transport slot for the next
    /// connect; the slot stays occupied until close() (or key removal).
    private func closeAllConnections() async {
        // Invalidate the monitor watching the connection we're about to
        // close so its callback can't stomp on a subsequent reconnect.
        connectionGeneration += 1

        guard let record = live else { return }
        await record.connection.close(error: nil)

        // Tear down only the record that was closed.
        guard live?.id == record.id else { return }
        clearLive()

        // The superseded monitor would have posted this; YubiKeySigner
        // relies on the wired one to drop its cached PIN.
        NotificationCenter.default.post(
            name: .yubiKeyDidDisconnect,
            object: nil,
            userInfo: ["method": record.method.rawValue]
        )
    }

    // MARK: - NFC Session Management

    #if os(iOS) && !os(visionOS)
    /// Close NFC session immediately without showing a message (fastest dismissal)
    func closeNFCSessionImmediately() async {
        await closeLiveNFC(.silently)
    }

    /// Close NFC session with success message
    func closeNFCSession(withMessage message: String) async {
        await closeLiveNFC(.message(message))
    }

    /// Close NFC session with error message
    func closeNFCSession(withError message: String) async {
        await closeLiveNFC(.error(message))
    }

    private enum NFCClose {
        case silently
        case message(String)
        case error(String)
    }

    /// Deliberately close the live NFC session and do the cleanup its
    /// disconnection monitor would have done. The generation bump supersedes
    /// that monitor, and happens only when the live connection is NFC, to
    /// leave a wired monitor alone.
    private func closeLiveNFC(_ style: NFCClose) async {
        guard let record = live, let connection = record.connection as? NFCSmartCardConnection else { return }
        connectionGeneration += 1
        switch style {
        case .silently:
            Self.logger.info("Closing NFC session immediately (no message)")
            await connection.close(error: nil)
        case .message(let message):
            Self.logger.info("Closing NFC session with message: \(message)")
            await connection.close(message: message)
        case .error(let message):
            Self.logger.info("Closing NFC session with error: \(message)")
            await connection.close(error: YubiKeyError.nfcSessionInvalidated(message))
        }

        // Tear down only the record that was closed.
        guard live?.id == record.id else { return }
        clearLive()
        setState(.disconnected)
        NotificationCenter.default.post(
            name: .yubiKeyDidDisconnect,
            object: nil,
            userInfo: ["method": YubiKeyConnectionMethod.nfc.rawValue]
        )
    }
    #endif

    /// Whether an NFC session is currently active
    var isNFCActive: Bool {
        isNFCSessionActive
    }

    /// Check if the next connection will use NFC
    func willUseNFC() async -> Bool {
        // If already connected, check current method
        if case .connected = connectionState, let live {
            return live.method == .nfc
        }
        // Otherwise check what selectBestTransport would return
        return await selectBestTransport() == .nfc
    }

    // MARK: - Device Identity

    /// Serial of the key the UI is showing (the live connection, else the last
    /// key read), for an action that will be bound to it. Throws when no key is
    /// shown or the key reported no serial to bind to.
    func confirmableSerial() throws -> UInt32 {
        let serial: UInt32?
        if case .connected = connectionState, let live {
            serial = live.serial
        } else {
            serial = lastReadDevice?.serial
        }
        guard let serial else { throw YubiKeyError.notConnected }
        guard serial != 0 else { throw YubiKeyError.unverifiedDevice }
        return serial
    }

    /// Open a PIV session on the YubiKey with serial `expected`. The connection,
    /// its transport and the serial read over it when it opened come from one
    /// record, and the session runs on that connection, so a key that connects
    /// afterwards can never receive the session's commands. Ends an NFC
    /// session on a serial refusal or if the PIV session can't be opened; a
    /// wired key stays connected.
    /// - Parameter nfcRefusal: For wired-only callers: thrown when the live
    ///   connection is NFC. That session belongs to another operation, so it
    ///   is left open.
    /// - Returns: The session, its transport, and an ID unique to the
    ///   connection it runs on, for state that must not outlive that connection.
    func verifiedPIVSession(
        serial expected: UInt32,
        nfcRefusal: YubiKeyError? = nil
    ) async throws -> (session: PIVSession, method: YubiKeyConnectionMethod, connectionID: Int) {
        guard case .connected = connectionState, let active = live else {
            throw YubiKeyError.notConnected
        }
        if let nfcRefusal, active.method == .nfc {
            throw nfcRefusal
        }
        let serial = active.serial

        // YubiKit reports a missing serial as 0, which identifies no key.
        let refusal: (error: YubiKeyError, nfcMessage: String)?
        if expected == 0 || serial == 0 {
            refusal = (YubiKeyError.unverifiedDevice, "Unidentified YubiKey")
        } else if serial != expected {
            refusal = (YubiKeyError.wrongDevice(expected: expected, connected: serial), "Different YubiKey")
        } else {
            refusal = nil
        }
        if let refusal {
            Self.logger.warning("Refusing PIV session: \(refusal.nfcMessage, privacy: .public)")
            #if os(iOS) && !os(visionOS)
            if active.method == .nfc {
                await closeNFCSession(withError: refusal.nfcMessage)
            }
            #endif
            throw refusal.error
        }

        do {
            let session = try await PIVSession.makeSession(connection: active.connection)
            return (session, active.method, active.id)
        } catch {
            // No caller holds a session yet, so nothing else would end this scan.
            #if os(iOS) && !os(visionOS)
            if active.method == .nfc, live?.id == active.id {
                await closeNFCSession(withError: "Couldn't open PIV")
            }
            #endif
            throw YubiKeyError.from(error)
        }
    }

    /// The wired transport the next connection would use, or nil when it
    /// would be NFC. Pass the result to `connect(preferredMethod:)` so the
    /// transport isn't chosen a second time.
    func wiredTransportForNextConnection() async -> YubiKeyConnectionMethod? {
        let method: YubiKeyConnectionMethod
        if case .connected = connectionState, let live {
            method = live.method
        } else {
            method = await selectBestTransport()
        }
        return method == .nfc ? nil : method
    }

    // MARK: - Session Access

    /// Get a fresh PIV session for the current connection
    func getPIVSession() async throws -> PIVSession {
        guard let connection = activeSmartCardConnection else {
            throw YubiKeyError.notConnected
        }

        Self.logger.info("Requesting fresh PIV session")

        do {
            return try await PIVSession.makeSession(connection: connection)
        } catch {
            // SDK uses typed throws(PIVSessionError)
            throw YubiKeyError.from(error)
        }
    }

    // MARK: - Device Info

    /// Read device info over `connection` itself, never over whichever one is
    /// live, so the serial vouches for exactly this connection.
    private func readDeviceInfo(over connection: any SmartCardConnection) async throws -> DeviceInfo {
        Self.logger.info("Getting device info")

        let session: Management.Session
        do {
            session = try await Management.Session.makeSession(connection: connection)
        } catch {
            // SDK uses typed throws(ManagementSessionError)
            throw YubiKeyError.yubiKitError(String(describing: error))
        }
        let deviceInfo = try await session.getDeviceInfo()
        Self.logger.info("Device info: formFactor=\(String(describing: deviceInfo.formFactor)), firmware=\(deviceInfo.version.description)")

        return deviceInfo
    }

    // MARK: - Transport Selection

    private func selectBestTransport() async -> YubiKeyConnectionMethod {
        let transportsStr = availableTransports.map { $0.rawValue }.joined(separator: ", ")
        Self.logger.info("selectBestTransport: availableTransports=[\(transportsStr)]")

        // Check for USB-C YubiKey (TKSmartCardSlotManager query, instant)
        if availableTransports.contains(.usbc),
           let devices = try? await USBSmartCardConnection.availableDevices(),
           !devices.isEmpty {
            Self.logger.info("USB YubiKey detected, selecting USB-C")
            return .usbc
        }

        // Check for Lightning YubiKey (EAAccessoryManager query, instant)
        #if os(iOS) && !DISABLE_MFI_LIGHTNING
        if availableTransports.contains(.lightning) {
            let hasLightningYubiKey = EAAccessoryManager.shared().connectedAccessories.contains {
                $0.protocolStrings.contains("com.yubico.ylp") && $0.manufacturer == "Yubico"
            }
            if hasLightningYubiKey {
                Self.logger.info("Lightning YubiKey detected, selecting Lightning")
                return .lightning
            }
        }
        #endif

        // No wired device detected — NFC on iPhone, USB-C on iPad
        #if os(iOS) && !os(visionOS)
        if availableTransports.contains(.nfc) {
            Self.logger.info("No wired device detected, selecting NFC")
            return .nfc
        }
        #endif

        if availableTransports.contains(.usbc) {
            return .usbc
        }

        #if os(iOS) && !DISABLE_MFI_LIGHTNING
        if availableTransports.contains(.lightning) {
            return .lightning
        }
        #endif

        Self.logger.info("Selecting NFC (fallback)")
        return .nfc
    }

    // MARK: - PIN Management

    /// Request PIN from user via published pendingPINRequest. If the
    /// requesting task is cancelled, the prompt is taken down and this throws,
    /// so a request that has already failed doesn't keep collecting a PIN.
    func requestPIN(for keyName: String, attemptsRemaining: Int? = nil) async throws -> String {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = YubiKeyPINRequest(
                    id: id,
                    keyName: keyName,
                    attemptsRemaining: attemptsRemaining
                ) { pin in
                    if let pin = pin {
                        continuation.resume(returning: pin)
                    } else {
                        continuation.resume(throwing: YubiKeyError.userCancelled)
                    }
                }

                pendingPINRequest = request
            }
        } onCancel: {
            // Withdraw this request's prompt, if it is still the one shown.
            Task { @MainActor in
                self.completePINRequest(id: id, with: nil)
            }
        }
    }

    /// Complete the pending PIN request (called by UI). `id` is the request
    /// the caller displayed: a sheet still showing a withdrawn request must
    /// not answer the one that replaced it.
    func completePINRequest(id: UUID, with pin: String?) {
        guard let request = pendingPINRequest, request.id == id else { return }
        pendingPINRequest = nil
        request.completion(pin)
    }

    // MARK: - State Helpers

    /// Update connection state (for use by other YubiKey classes)
    func updateState(_ state: YubiKeyConnectionState) {
        setState(state)
    }

    /// Return to `.connected` after an operation, from the live record. No-op
    /// if that connection is gone or one on another transport replaced it.
    func restoreConnectedState(for method: YubiKeyConnectionMethod) {
        guard let live, live.method == method else { return }
        setState(.connected(serial: live.serial, method: live.method))
    }

    /// Single funnel for connection-state changes. Mirrors every change into
    /// `HardwareKeyActivityCoordinator` so the terminal overlay can reflect the
    /// current phase. All mutations of `connectionState` go through here.
    private func setState(_ newState: YubiKeyConnectionState) {
        connectionState = newState
        HardwareKeyActivityCoordinator.shared.connectionStateChanged(newState, isNFCActive: isNFCSessionActive)
    }

    private func handleDisconnection(of record: LiveConnection, generation: Int, error: Error?) {
        // A deliberate close (disconnect/self-heal) bumped the generation and
        // handles its own cleanup; this callback is about a connection that no
        // longer matters and may run after a NEW connection was established.
        guard generation == connectionGeneration, live?.id == record.id else {
            Self.logger.info("Ignoring disconnection of superseded \(record.method.rawValue) connection")
            return
        }
        Self.logger.info("Handling YubiKey disconnection for \(record.method.rawValue)")

        clearLive()
        setState(.disconnected)

        // Notify listeners that YubiKey was disconnected
        NotificationCenter.default.post(
            name: .yubiKeyDidDisconnect,
            object: nil,
            userInfo: ["method": record.method.rawValue]
        )
    }
}
