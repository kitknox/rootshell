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
import os.log
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

    /// Current active Lightning connection
    #if os(iOS) && !DISABLE_MFI_LIGHTNING
    @ObservationIgnored private var lightningConnection: LightningSmartCardConnection?
    #endif

    /// Current active NFC connection
    #if os(iOS) && !os(visionOS)
    @ObservationIgnored private var nfcConnection: NFCSmartCardConnection?
    #endif

    /// Current active USB-C connection
    @ObservationIgnored private var usbConnection: USBSmartCardConnection?

    /// Serial number of the connected YubiKey (cached for display purposes only)
    private(set) var connectedSerial: UInt?

    /// Firmware version of the connected YubiKey (e.g., "5.7.0")
    private(set) var connectedFirmwareVersion: String?

    /// Form factor/model of the connected YubiKey
    private(set) var connectedFormFactor: FormFactor?

    /// The key most recently read, kept after an NFC session ends so the UI can
    /// still show it and offer actions that reconnect on demand.
    private(set) var lastReadDevice: YubiKeyDeviceSnapshot?

    /// Current connection method
    @ObservationIgnored private var currentConnectionMethod: YubiKeyConnectionMethod?

    /// Whether an NFC session is currently active
    @ObservationIgnored private var isNFCSessionActive = false

    /// In-flight wired-transport connect task (USB-C or Lightning). NFC is excluded
    /// because the system NFC sheet provides its own cancel affordance.
    @ObservationIgnored private var pendingConnectTask: Task<Void, Error>?

    /// Bumped whenever we deliberately close connections. Disconnection
    /// monitors capture the value they were spawned under; a monitor whose
    /// generation is stale reports the close of an old connection and must not
    /// tear down state belonging to a newer one (the SDK connections are
    /// structs, so there's no reference identity to compare instead).
    @ObservationIgnored private var connectionGeneration = 0

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

    // MARK: - Connection Methods

    /// Connect to YubiKey using the best available method
    /// - Parameter preferredMethod: Optional preferred connection method
    /// - Throws: YubiKeyError if connection fails
    func connect(preferredMethod: YubiKeyConnectionMethod? = nil) async throws {
        // If already connected, return
        if case .connected = connectionState, activeSmartCardConnection != nil {
            Self.logger.info("Already connected to YubiKey")
            return
        }

        // If a previous wired attempt is still polling for a key, cancel it
        // so the user can switch transports without waiting for the timeout.
        if let prior = pendingConnectTask {
            prior.cancel()
            _ = try? await prior.value
            pendingConnectTask = nil
        }

        // Self-heal: a connection left behind by a failed operation (state no
        // longer .connected) still occupies the SDK's per-transport slot, so
        // opening a new one would fail with "another connection in progress".
        // Close it before reconnecting — unless a live operation owns it.
        if activeSmartCardConnection != nil {
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

        let method: YubiKeyConnectionMethod
        if let preferredMethod {
            method = preferredMethod
        } else {
            method = await selectBestTransport()
        }
        currentConnectionMethod = method
        setState(.connecting(method: method))

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performConnect(method: method)
        }
        if method != .nfc {
            pendingConnectTask = task
        }
        defer {
            if pendingConnectTask == task {
                pendingConnectTask = nil
            }
        }

        do {
            try await task.value
        } catch is CancellationError {
            // Cancelled by cancelPendingConnection() or a subsequent connect call.
            // State has already been reset by the canceller; surface as userCancelled.
            throw YubiKeyError.userCancelled
        } catch {
            throw error
        }
    }

    /// Perform the actual connect work. Split out from connect() so the outer
    /// function can wrap it in a cancellable Task.
    private func performConnect(method: YubiKeyConnectionMethod) async throws {
        do {
            switch method {
            case .nfc:
                #if os(iOS) && !os(visionOS)
                try await connectNFC()
                #else
                throw YubiKeyError.nfcNotAvailable
                #endif
            case .lightning:
                #if os(iOS) && !DISABLE_MFI_LIGHTNING
                try await connectLightning()
                #else
                throw YubiKeyError.unsupportedFeature("Lightning disabled (MFI approval pending)")
                #endif
            case .usbc:
                try await connectUSBC()
            }

            // Get device info to confirm connection
            let serial = try await getSerialNumber()
            connectedSerial = serial
            setState(.connected(serial: UInt32(truncatingIfNeeded: serial), method: method))
            Self.logger.info("Connected to YubiKey (SN: \(serial)) via \(method.rawValue)")

            // Start monitoring for disconnection
            monitorConnection(method: method)

        } catch is CancellationError {
            // Caller will translate this into userCancelled. Don't overwrite
            // state here — cancelPendingConnection() already set it.
            throw CancellationError()
        } catch YubiKeyError.userCancelled {
            // A cancelled wired wait surfaces from the SDK as
            // SmartCardConnectionError.cancelled, already mapped to
            // userCancelled. Settle on .disconnected like the
            // CancellationError path — never .error.
            setState(.disconnected)
            throw YubiKeyError.userCancelled
        } catch {
            setState(.error(error.localizedDescription))
            isNFCSessionActive = false
            if let yubiKeyError = error as? YubiKeyError {
                throw yubiKeyError
            }
            throw YubiKeyError.connectionFailed(error.localizedDescription)
        }
    }

    #if os(iOS) && !os(visionOS)
    /// Connect via NFC
    private func connectNFC() async throws {
        Self.logger.info("Starting NFC connection")
        isNFCSessionActive = true

        do {
            let conn = try await NFCSmartCardConnection(
                alertMessage: "Hold YubiKey against the top of your iPhone"
            )
            nfcConnection = conn
        } catch {
            isNFCSessionActive = false
            // SDK uses typed throws(SmartCardConnectionError)
            throw YubiKeyError.from(error)
        }
    }
    #endif

    #if os(iOS) && !DISABLE_MFI_LIGHTNING
    /// Connect via Lightning port
    private func connectLightning() async throws {
        Self.logger.info("Starting Lightning connection")
        // Surface the indefinite "Insert your YubiKey" prompt while the SDK
        // blocks waiting for a key on the port (wait-until-cancel).
        setState(.waitingForDevice(transport: .lightning))

        do {
            lightningConnection = try await openWiredConnection(transport: .lightning) {
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
    private func connectUSBC() async throws {
        Self.logger.info("Starting USB-C connection")
        // Surface the indefinite "Insert your YubiKey" prompt while the SDK
        // blocks waiting for a key on the port (wait-until-cancel).
        setState(.waitingForDevice(transport: .usbc))

        // A key whose USB smart card (CCID) interface is off never appears as a
        // slot, so record everything iOS reports for diagnosis.
        let slots = (try? await USBSmartCardConnection.availableDevices(matching: nil)) ?? []
        Self.logger.info("USB smart card slots: [\(slots.map(\.name).joined(separator: ", "), privacy: .public)]")

        do {
            usbConnection = try await openWiredConnection(transport: .usbc) {
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
    private func monitorConnection(method: YubiKeyConnectionMethod) {
        let generation = connectionGeneration
        Task {
            let error: Error?

            switch method {
            case .nfc:
                #if os(iOS) && !os(visionOS)
                error = await nfcConnection?.waitUntilClosed()
                #else
                error = nil
                #endif
            case .lightning:
                #if os(iOS) && !DISABLE_MFI_LIGHTNING
                error = await lightningConnection?.waitUntilClosed()
                #else
                error = nil
                #endif
            case .usbc:
                error = await usbConnection?.waitUntilClosed()
            }

            await MainActor.run {
                self.handleDisconnection(method: method, generation: generation, error: error)
            }
        }
    }

    /// Get the current active SmartCard connection
    var activeSmartCardConnection: (any SmartCardConnection)? {
        #if os(iOS) && !os(visionOS)
        if let nfc = nfcConnection { return nfc }
        #endif
        #if os(iOS) && !DISABLE_MFI_LIGHTNING
        if let lightning = lightningConnection { return lightning }
        #endif
        return usbConnection
    }

    /// Cancel an in-flight wired connect attempt (USB-C / Lightning).
    /// Does nothing if no attempt is pending or if a connection has already
    /// succeeded — use disconnect() to tear down a successful connection.
    func cancelPendingConnection() {
        guard let task = pendingConnectTask else { return }
        Self.logger.info("Cancelling pending YubiKey connect attempt")
        // Request cancellation but KEEP the task tracked. `cancel()` only
        // signals — the SDK connection keeps unwinding asynchronously. If we
        // cleared `pendingConnectTask` here, a quick retry's `connect()` would
        // skip its drain (`if let prior = pendingConnectTask { await
        // prior.value }`) and open a SECOND SDK connection while this one is
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
            currentConnectionMethod = nil
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

        Task {
            await closeAllConnections()

            isNFCSessionActive = false
            lastReadDevice = nil
            connectedSerial = nil
            connectedFormFactor = nil
            connectedFirmwareVersion = nil
            currentConnectionMethod = nil
            setState(.disconnected)
        }
    }

    /// Close every held SDK connection and drop the references. Releasing the
    /// connection is what frees the SDK's per-transport slot for the next
    /// connect; the slot stays occupied until close() (or key removal).
    private func closeAllConnections() async {
        // Invalidate any monitors watching the connections we're about to
        // close so their callbacks can't stomp on a subsequent reconnect.
        connectionGeneration += 1

        var closedMethods: [YubiKeyConnectionMethod] = []
        #if os(iOS) && !os(visionOS)
        if nfcConnection != nil {
            await nfcConnection?.close(error: nil)
            nfcConnection = nil
            closedMethods.append(.nfc)
        }
        #endif
        #if os(iOS) && !DISABLE_MFI_LIGHTNING
        if lightningConnection != nil {
            await lightningConnection?.close(error: nil)
            lightningConnection = nil
            closedMethods.append(.lightning)
        }
        #endif
        if usbConnection != nil {
            await usbConnection?.close(error: nil)
            usbConnection = nil
            closedMethods.append(.usbc)
        }

        guard !closedMethods.isEmpty else { return }

        isNFCSessionActive = false
        connectedSerial = nil
        connectedFormFactor = nil
        connectedFirmwareVersion = nil
        currentConnectionMethod = nil

        // The superseded monitors would have posted these; YubiKeySigner
        // relies on the wired one to drop its cached PIN.
        for method in closedMethods {
            NotificationCenter.default.post(
                name: .yubiKeyDidDisconnect,
                object: nil,
                userInfo: ["method": method.rawValue]
            )
        }
    }

    // MARK: - NFC Session Management

    #if os(iOS) && !os(visionOS)
    /// Close NFC session immediately without showing a message (fastest dismissal)
    func closeNFCSessionImmediately() async {
        guard let connection = nfcConnection else { return }
        Self.logger.info("Closing NFC session immediately (no message)")
        connectionGeneration += 1
        await connection.close(error: nil)
        finishDeliberateNFCClose()
    }

    /// Close NFC session with success message
    func closeNFCSession(withMessage message: String) async {
        guard let connection = nfcConnection else { return }
        Self.logger.info("Closing NFC session with message: \(message)")
        connectionGeneration += 1
        await connection.close(message: message)
        finishDeliberateNFCClose()
    }

    /// Close NFC session with error message
    func closeNFCSession(withError message: String) async {
        guard let connection = nfcConnection else { return }
        Self.logger.info("Closing NFC session with error: \(message)")
        connectionGeneration += 1
        await connection.close(error: YubiKeyError.nfcSessionInvalidated(message))
        finishDeliberateNFCClose()
    }

    /// Cleanup shared by the deliberate NFC close paths above. Mirrors what
    /// the session's disconnection monitor would have done; the generation
    /// bump supersedes that monitor so its late callback can't tear down a
    /// newer session's state. The bump happens before the awaited close (and
    /// only when we actually hold an NFC connection, to leave wired monitors
    /// alone).
    private func finishDeliberateNFCClose() {
        nfcConnection = nil
        isNFCSessionActive = false
        connectedSerial = nil
        connectedFormFactor = nil
        connectedFirmwareVersion = nil
        currentConnectionMethod = nil
        if activeSmartCardConnection == nil {
            setState(.disconnected)
            NotificationCenter.default.post(
                name: .yubiKeyDidDisconnect,
                object: nil,
                userInfo: ["method": YubiKeyConnectionMethod.nfc.rawValue]
            )
        }
    }
    #endif

    /// Whether an NFC session is currently active
    var isNFCActive: Bool {
        isNFCSessionActive
    }

    /// Check if the next connection will use NFC
    func willUseNFC() async -> Bool {
        // If already connected, check current method
        if case .connected(_, let method) = connectionState {
            return method == .nfc
        }
        // Otherwise check what selectBestTransport would return
        return await selectBestTransport() == .nfc
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

    /// Get a fresh Management session for device info
    func getManagementSession() async throws -> Management.Session {
        guard let connection = activeSmartCardConnection else {
            throw YubiKeyError.notConnected
        }

        Self.logger.info("Requesting fresh Management session")

        do {
            return try await Management.Session.makeSession(connection: connection)
        } catch {
            // SDK uses typed throws(ManagementSessionError)
            throw YubiKeyError.yubiKitError(String(describing: error))
        }
    }

    // MARK: - Device Info

    /// Get serial number of connected YubiKey and cache device info
    private func getSerialNumber() async throws -> UInt {
        if let serial = connectedSerial {
            return serial
        }

        Self.logger.info("Getting device info")

        let session = try await getManagementSession()
        let deviceInfo = try await session.getDeviceInfo()
        let serial = deviceInfo.serialNumber

        self.connectedSerial = serial
        self.connectedFormFactor = deviceInfo.formFactor
        self.connectedFirmwareVersion = deviceInfo.version.description
        if let method = currentConnectionMethod {
            self.lastReadDevice = YubiKeyDeviceSnapshot(
                serial: UInt32(truncatingIfNeeded: serial),
                firmwareVersion: deviceInfo.version.description,
                formFactor: deviceInfo.formFactor,
                method: method
            )
        }
        Self.logger.info("Device info: formFactor=\(String(describing: deviceInfo.formFactor)), firmware=\(deviceInfo.version.description)")

        return serial
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

    /// Request PIN from user via published pendingPINRequest
    func requestPIN(for keyName: String, attemptsRemaining: Int? = nil) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = YubiKeyPINRequest(
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
    }

    /// Complete a pending PIN request (called by UI)
    func completePINRequest(with pin: String?) {
        guard let request = pendingPINRequest else { return }
        pendingPINRequest = nil
        request.completion(pin)
    }

    // MARK: - State Helpers

    /// Update connection state (for use by other YubiKey classes)
    func updateState(_ state: YubiKeyConnectionState) {
        setState(state)
    }

    /// Single funnel for connection-state changes. Mirrors every change into
    /// `HardwareKeyActivityCoordinator` so the terminal overlay can reflect the
    /// current phase. All mutations of `connectionState` go through here.
    private func setState(_ newState: YubiKeyConnectionState) {
        connectionState = newState
        HardwareKeyActivityCoordinator.shared.connectionStateChanged(newState, isNFCActive: isNFCSessionActive)
    }

    private func handleDisconnection(method: YubiKeyConnectionMethod, generation: Int, error: Error?) {
        // A deliberate close (disconnect/self-heal) bumped the generation and
        // handles its own cleanup; this callback is about a connection that no
        // longer matters and may run after a NEW connection was established.
        guard generation == connectionGeneration else {
            Self.logger.info("Ignoring disconnection of superseded \(method.rawValue) connection")
            return
        }
        Self.logger.info("Handling YubiKey disconnection for \(method.rawValue)")

        // Clear the specific connection reference
        switch method {
        case .lightning:
            #if os(iOS) && !DISABLE_MFI_LIGHTNING
            lightningConnection = nil
            #endif
        case .nfc:
            #if os(iOS) && !os(visionOS)
            nfcConnection = nil
            #endif
            isNFCSessionActive = false
        case .usbc:
            usbConnection = nil
        }

        // Clear cached device info
        connectedSerial = nil
        connectedFormFactor = nil
        connectedFirmwareVersion = nil
        currentConnectionMethod = nil

        // Update state only if this was our active connection
        if activeSmartCardConnection == nil {
            setState(.disconnected)

            // Notify listeners that YubiKey was disconnected
            NotificationCenter.default.post(
                name: .yubiKeyDidDisconnect,
                object: nil,
                userInfo: ["method": method.rawValue]
            )
        }
    }
}
